#!/bin/bash

# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the terms described in the LICENSE file in
# the root directory of this source tree.

if [ -z "$RELEASE_VERSION" ]; then
  echo "You must set the RELEASE_VERSION environment variable" >&2
  exit 1
fi

if [ -z "$RC_VERSION" ]; then
  echo "You must set the RC_VERSION environment variable" >&2
  exit 1
fi

if [ -z "$NPM_TOKEN" ]; then
  echo "You must set the NPM_TOKEN environment variable" >&2
  exit 1
fi

GITHUB_TOKEN=${GITHUB_TOKEN:-}
LLAMA_STACK_ONLY=${LLAMA_STACK_ONLY:-false}
DRY_RUN=${DRY_RUN:-false}

source $(dirname $0)/../common.sh

npm config set '//registry.npmjs.org/:_authToken' "$NPM_TOKEN"

set -euo pipefail

is_truthy() {
  case "$1" in
  true | 1) return 0 ;;
  false | 0) return 1 ;;
  *) return 1 ;;
  esac
}

# Parse version to derive release branch name
# Examples: 0.1.0 -> release-0.1.x, 1.2.3 -> release-1.2.x, 0.2.10.1 -> release-0.2.x
parse_version_and_branch() {
  local version=$1

  # Validate version format (X.Y.Z or X.Y.Z.W, no rc suffix for final releases)
  if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "ERROR: Invalid version format: $version" >&2
    echo "Expected format: X.Y.Z[.W] (e.g., 0.1.0, 1.2.3, 0.2.10.1)" >&2
    exit 1
  fi

  # Extract major.minor (e.g., 0.1.0 -> 0.1)
  local major=$(echo "$version" | cut -d. -f1)
  local minor=$(echo "$version" | cut -d. -f2)

  # Derive branch name: release-{major}.{minor}.x
  local branch_name="release-${major}.${minor}.x"

  echo "$branch_name"
}

RELEASE_BRANCH=$(parse_version_and_branch "$RELEASE_VERSION")
echo "Derived release branch: $RELEASE_BRANCH"

# Yell loudly if RELEASE is already on pypi, but keep going anyway
version_tag=$(curl -s https://pypi.org/pypi/llama-stack/json | jq -r '.info.version')
if [ x"$version_tag" = x"$RELEASE_VERSION" ]; then
  echo "WARNING: RELEASE_VERSION $RELEASE_VERSION is already on pypi" >&2
fi

# OTOH, if the RC is _not_ on test.pypi, we should yell
# we should look at all releases, not the latest
version_tags=$(curl -s https://test.pypi.org/pypi/llama-stack/json | jq -r '.releases | keys[]')
found_rc=0
for version_tag in $version_tags; do
  if [ x"$version_tag" = x"$RC_VERSION" ]; then
    found_rc=1
    break
  fi
done

if [ $found_rc -eq 0 ]; then
  echo "RC_VERSION $RC_VERSION not found on test.pypi" >&2
  exit 1
fi

CLIENT_REPOS=(stack-client-python stack-client-typescript)
STACK_REPOS=(stack)

# For LLAMA_STACK_ONLY mode, skip clients
if is_truthy "$LLAMA_STACK_ONLY"; then
  CLIENT_REPOS=()
  STACK_REPOS=(stack)
fi

# Combined list for validation
REPOS=("${CLIENT_REPOS[@]}" "${STACK_REPOS[@]}")

# check that tag v$RC_VERSION exists for all repos. each repo is remote
# github.com/meta-llama/llama-$repo.git
for repo in "${REPOS[@]}"; do
  org=$(github_org $repo)
  if ! git ls-remote --tags https://github.com/$org/llama-$repo.git "refs/tags/v$RC_VERSION" | grep -q .; then
    echo "Tag v$RC_VERSION does not exist for $repo" >&2
    exit 1
  fi
done

set -x

# Verify that a package is available on npm registry
verify_npm_package() {
  local package_name=$1
  local version=$2
  local max_attempts=30
  local attempt=1

  echo "Verifying $package_name@$version is available on npm..."
  while [ $attempt -le $max_attempts ]; do
    if npm view "$package_name@$version" version &>/dev/null; then
      echo "✅ $package_name@$version is available on npm"
      return 0
    fi
    echo "Attempt $attempt/$max_attempts: $package_name@$version not yet available, waiting 10 seconds..."
    sleep 10
    ((attempt++))
  done

  echo "ERROR: $package_name@$version not available on npm after $max_attempts attempts" >&2
  return 1
}

# Verify that a package is available on PyPI registry
verify_pypi_package() {
  local package_name=$1
  local version=$2
  local max_attempts=30
  local attempt=1

  echo "Verifying $package_name==$version is available on PyPI..."
  while [ $attempt -le $max_attempts ]; do
    if curl -s "https://pypi.org/pypi/$package_name/json" | jq -e ".releases.\"$version\"" &>/dev/null; then
      echo "✅ $package_name==$version is available on PyPI"
      return 0
    fi
    echo "Attempt $attempt/$max_attempts: $package_name==$version not yet available, waiting 10 seconds..."
    sleep 10
    ((attempt++))
  done

  echo "ERROR: $package_name==$version not available on PyPI after $max_attempts attempts" >&2
  return 1
}

run_precommit_lockfile_update() {
  # Use pre-commit to update lockfiles (uv.lock and package-lock.json)
  # LLAMA_STACK_RELEASE_MODE=true signals hooks to update lockfiles
  # Note: pre-commit exits with non-zero when it modifies files, which is expected
  if ! command -v pre-commit &> /dev/null; then
    echo "ERROR: pre-commit is not installed" >&2
    exit 1
  fi
  echo "Running pre-commit to update lockfiles..."
  LLAMA_STACK_RELEASE_MODE=true pre-commit run --all-files || true
  echo "pre-commit run completed."
}

add_bump_version_commit() {
  local repo=$1
  local version=$2
  local should_update_lockfiles=$3

  if [ "$repo" == "stack-client-typescript" ]; then
    perl -pi -e "s/\"version\": \".*\"/\"version\": \"$version\"/" package.json
    npx yarn install
    npx yarn build
  else
    # TODO: this is dangerous use uvx toml-cli toml set project.version $RELEASE_VERSION instead of this
    # cringe perl code
    perl -pi -e "s/^version = .*$/version = \"$version\"/" pyproject.toml

    # Also bump llama_stack_api version if this is the stack repo
    if [ "$repo" == "stack" ]; then
      bump_version_llama_stack_api "$version"
    fi

    if ! is_truthy "$LLAMA_STACK_ONLY"; then
      # Only update client dependency for non-dev versions
      # Dev versions (e.g., 0.1.1.dev0) should keep the last stable client dependency
      if [[ ! "$version" =~ \.dev ]]; then
        perl -pi -e "s/llama-stack-client>=.*,/llama-stack-client>=$version\",/" pyproject.toml

        if [ "$repo" == "stack" ]; then
          # Handle both old (llama_stack/ui) and new (src/llama_stack_ui) paths
          if [ -f "src/llama_stack_ui/package.json" ]; then
            UI_PATH="src/llama_stack_ui"
          elif [ -f "llama_stack/ui/package.json" ]; then
            UI_PATH="llama_stack/ui"
          else
            echo "ERROR: Could not find llama_stack_ui/package.json" >&2
            exit 1
          fi

          perl -pi -e "s/(\"llama-stack-client\": \").+\"/\1^$version\"/" "$UI_PATH/package.json"
          # Update package-lock.json to match the new package.json
          (cd "$UI_PATH" && npm install)
        fi
      fi

      if [ -f "src/llama_stack_client/_version.py" ]; then
        perl -pi -e "s/__version__ = .*$/__version__ = \"$version\"/" src/llama_stack_client/_version.py
      fi
    fi

    if is_truthy "$should_update_lockfiles"; then
      run_precommit_lockfile_update
    fi
  fi

  # Only commit if there are changes
  if [ -n "$(git status --porcelain)" ]; then
    git commit -am "build: Bump version to $version"
  else
    echo "No changes to commit for version bump to $version"
  fi
}

# Function to handle llama_stack_api subdirectory
bump_version_llama_stack_api() {
  local version=$1
  if [ -d "src/llama_stack_api" ] && [ -f "src/llama_stack_api/pyproject.toml" ]; then
    echo "Bumping version for llama_stack_api to $version"
    perl -pi -e "s/^version = .*$/version = \"$version\"/" src/llama_stack_api/pyproject.toml
  fi
}

TMPDIR=$(mktemp -d)
cd $TMPDIR
uv venv build-env
source build-env/bin/activate

uv pip install twine
npm install -g yarn

# ============================================================================
# PHASE 1: Build client packages (stack-client-python, stack-client-typescript)
# ============================================================================
echo "========================================="
echo "PHASE 1: Building client packages"
echo "========================================="

for repo in "${CLIENT_REPOS[@]}"; do
  org=$(github_org $repo)
  git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git"
  cd llama-$repo
  git fetch origin refs/tags/v${RC_VERSION}:refs/tags/v${RC_VERSION}
  git checkout -b release-$RELEASE_VERSION refs/tags/v${RC_VERSION}
  git fetch origin --prune

  # don't run uv lock here because the dependency isn't pushed upstream so uv will fail
  add_bump_version_commit $repo $RELEASE_VERSION false

  # Only create the tag if it doesn't already exist
  if ! git tag -l "v$RELEASE_VERSION" | grep -q .; then
    git tag -a "v$RELEASE_VERSION" -m "Release version $RELEASE_VERSION"
  else
    echo "Tag v$RELEASE_VERSION already exists, skipping tag creation"
  fi

  if [ "$repo" == "stack-client-typescript" ]; then
    npx yarn install
    npx yarn build
  else
    uv build -q
    uv pip install dist/*.whl
  fi

  cd ..
done

# ============================================================================
# PHASE 2: Publish client packages
# ============================================================================
if ! is_truthy "$DRY_RUN"; then
  echo "========================================="
  echo "PHASE 2: Publishing client packages"
  echo "========================================="

  for repo in "${CLIENT_REPOS[@]}"; do
    cd llama-$repo
    if [ "$repo" == "stack-client-typescript" ]; then
      echo "Uploading llama-$repo to npm"
      cd dist

      # Check if version already exists on npm
      if npm view llama-stack-client@$RELEASE_VERSION version &>/dev/null; then
        echo "Version $RELEASE_VERSION already exists on npm for llama-stack-client, skipping publish"
      else
        npx yarn publish --access public --tag $RELEASE_VERSION --registry https://registry.npmjs.org/
      fi

      # Always try to add latest tag since this operation is idempotent
      npx yarn tag add llama-stack-client@$RELEASE_VERSION latest || true
      cd ..
    else
      echo "Uploading llama-$repo to pypi"
      python -m twine upload \
        --skip-existing \
        --non-interactive \
        "dist/*.whl" "dist/*.tar.gz"
    fi
    cd ..
  done

  # ============================================================================
  # PHASE 3: Verify client packages are available on registries
  # ============================================================================
  echo "========================================="
  echo "PHASE 3: Verifying client packages"
  echo "========================================="

  for repo in "${CLIENT_REPOS[@]}"; do
    if [ "$repo" == "stack-client-typescript" ]; then
      verify_npm_package "llama-stack-client" "$RELEASE_VERSION"
    elif [ "$repo" == "stack-client-python" ]; then
      verify_pypi_package "llama-stack-client" "$RELEASE_VERSION"
    fi
  done
else
  echo "DRY RUN: skipping client package upload and verification"
fi

# ============================================================================
# PHASE 4: Build stack package (now that client dependencies are available)
# ============================================================================
echo "========================================="
echo "PHASE 4: Building stack package"
echo "========================================="

for repo in "${STACK_REPOS[@]}"; do
  org=$(github_org $repo)
  git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git"
  cd llama-$repo
  git fetch origin refs/tags/v${RC_VERSION}:refs/tags/v${RC_VERSION}
  git checkout -b release-$RELEASE_VERSION refs/tags/v${RC_VERSION}
  git fetch origin --prune

  # don't run uv lock here because the dependency isn't pushed upstream so uv will fail
  add_bump_version_commit "$repo" "$RELEASE_VERSION" false

  # Only create the tag if it doesn't already exist
  if ! git tag -l "v$RELEASE_VERSION" | grep -q .; then
    git tag -a "v$RELEASE_VERSION" -m "Release version $RELEASE_VERSION"
  else
    echo "Tag v$RELEASE_VERSION already exists, skipping tag creation"
  fi

  # Build llama_stack_api first if it exists (it's a dependency of llama-stack)
  if [ "$repo" == "stack" ] && [ -d "src/llama_stack_api" ] && [ -f "src/llama_stack_api/pyproject.toml" ]; then
    echo "Building llama_stack_api"
    cd src/llama_stack_api
    uv build -q
    uv pip install dist/*.whl
    cd -
  fi

  uv build -q
  uv pip install dist/*.whl

  cd ..
done

which llama
llama stack list-apis
llama stack list-providers inference

# just check if llama stack list-deps works
llama stack list-deps starter

# ============================================================================
# PHASE 5: Publish stack package
# ============================================================================
if ! is_truthy "$DRY_RUN"; then
  echo "========================================="
  echo "PHASE 5: Publishing stack package"
  echo "========================================="

  for repo in "${STACK_REPOS[@]}"; do
    cd llama-$repo
    echo "Uploading llama-$repo to pypi"
    python -m twine upload \
      --skip-existing \
      --non-interactive \
      "dist/*.whl" "dist/*.tar.gz"

    # Upload llama_stack_api if it exists
    if [ "$repo" == "stack" ] && [ -d "src/llama_stack_api" ] && [ -f "src/llama_stack_api/pyproject.toml" ]; then
      echo "Uploading llama_stack_api to pypi"
      cd src/llama_stack_api
      python -m twine upload \
        --skip-existing \
        --non-interactive \
        "dist/*.whl" "dist/*.tar.gz"
      cd -
    fi
    cd ..
  done
else
  echo "DRY RUN: skipping stack package upload"
  # In dry run mode, exit before lockfile updates and git push
  exit 0
fi

deactivate
rm -rf build-env

# Update lockfiles now that packages are published to PyPI/npm
# We'll force-move the tag after this to include lockfiles in the release
echo "Updating lockfiles after publishing packages..."
for repo in "${REPOS[@]}"; do
  if [ "$repo" == "stack-client-typescript" ]; then
    # TypeScript client doesn't need lockfile updates in this step
    continue
  fi

  cd $TMPDIR/llama-$repo

  # Set up a temporary venv to ensure we have uv and pre-commit
  uv venv lockfile-update-env
  source lockfile-update-env/bin/activate

  # Install pre-commit if not already available
  if ! command -v pre-commit &> /dev/null; then
    uv pip install pre-commit
  fi

  echo "Running pre-commit to update lockfiles for $repo..."
  run_precommit_lockfile_update

  # Commit lockfile changes if any
  if [ -n "$(git status --porcelain)" ]; then
    git commit -am "chore: update lockfiles for ${RELEASE_VERSION}"
    echo "✅ Lockfiles updated and committed for $repo"

    # Force-move the tag to include the lockfile commit
    echo "Force-moving tag v$RELEASE_VERSION to include lockfiles..."
    git tag -f -a "v$RELEASE_VERSION" -m "Release version $RELEASE_VERSION"
  else
    echo "No lockfile changes for $repo"
  fi

  deactivate
  rm -rf lockfile-update-env

  cd $TMPDIR
done

# Push release branch and tags to remote
for repo in "${REPOS[@]}"; do
  cd $TMPDIR/llama-$repo

  echo "Pushing release branch and tag v$RELEASE_VERSION for $repo"
  org=$(github_org $repo)

  # Push the release branch with the version bump commit
  git push -f "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git" "release-$RELEASE_VERSION:$RELEASE_BRANCH"

  # Push the tag
  git push -f "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git" "v$RELEASE_VERSION"

  cd $TMPDIR
done

echo "Release $RELEASE_VERSION published successfully"

# Auto-bump main branch version (create PR)
# Only bump the stack repo, not client libraries
if ! is_truthy "$LLAMA_STACK_ONLY"; then
  echo "Creating PR to bump main branch version for stack repo"

  # Calculate next dev version: 0.1.0 -> 0.1.1.dev0
  MAJOR=$(echo $RELEASE_VERSION | cut -d. -f1)
  MINOR=$(echo $RELEASE_VERSION | cut -d. -f2)
  PATCH=$(echo $RELEASE_VERSION | cut -d. -f3)
  NEXT_PATCH=$((PATCH + 1))
  NEXT_DEV_VERSION="${MAJOR}.${MINOR}.${NEXT_PATCH}.dev0"

  echo "Next dev version: $NEXT_DEV_VERSION"

  for repo in "stack"; do
    cd $TMPDIR

    if [ "$repo" != "stack-client-typescript" ]; then
      uv venv -p python3.12 bump-main-$repo-env
      source bump-main-$repo-env/bin/activate
      uv pip install pre-commit
    fi

    cd llama-$repo

    org=$(github_org $repo)

    # Checkout main branch
    git fetch origin main
    git checkout -B main origin/main

    # Bump version to next dev version
    add_bump_version_commit $repo $NEXT_DEV_VERSION true

    # Push to a new branch for PR
    BUMP_BRANCH="release-automation/bump-to-${NEXT_DEV_VERSION}"
    git push -f "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git" "main:${BUMP_BRANCH}"

    # Create PR using gh CLI
    GH_TOKEN=$GITHUB_TOKEN gh pr create \
      --repo "$org/llama-$repo" \
      --base main \
      --head "${BUMP_BRANCH}" \
      --title "chore: bump version to ${NEXT_DEV_VERSION}" \
      --body "Automated version bump after releasing ${RELEASE_VERSION}" || echo "PR creation failed or PR already exists"

    if [ "$repo" != "stack-client-typescript" ]; then
      deactivate
    fi

    cd $TMPDIR
  done
fi

echo "Done"
