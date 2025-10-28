#!/bin/bash

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
source $(dirname $0)/../lib/release_utils.sh

npm config set '//registry.npmjs.org/:_authToken' "$NPM_TOKEN"

set -euo pipefail

is_truthy() {
  case "$1" in
  true | 1) return 0 ;;
  false | 0) return 1 ;;
  *) return 1 ;;
  esac
}

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

REPOS=(stack-client-python stack-client-typescript stack)
if is_truthy "$LLAMA_STACK_ONLY"; then
  REPOS=(stack)
fi

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

run_uv_lock() {
  # Retry uv lock as PyPI index might be slow to update
  echo "Attempting to lock dependencies with uv..."
  for i in {1..5}; do
    if uv lock --refresh --no-cache; then
      echo "uv lock successful."
      break
    else
      if [ "$i" -eq 5 ]; then
        echo "uv lock failed after 5 attempts." >&2
        exit 1
      fi
      echo "uv lock failed, retrying in 10 seconds (attempt $i/5)..."
      sleep 10
    fi
  done
}

run_npm_install() {
  echo "Attempting to install dependencies with npm..."
  cd llama_stack/ui
  for i in {1..10}; do
    if npm install --package-lock-only --prefer-online; then
      echo "npm install successful."
      break
    else
      if [ "$i" -eq 5 ]; then
        echo "npm install failed after 5 attempts." >&2
        exit 1
      fi
      echo "npm install failed, retrying in 10 seconds (attempt $i/5)..."
      sleep 10
    fi
  done
  cd ../../
}

add_bump_version_commit() {
  local repo=$1
  local version=$2
  local should_run_uv_lock=$3

  if [ "$repo" == "stack-client-typescript" ]; then
    perl -pi -e "s/\"version\": \".*\"/\"version\": \"$version\"/" package.json
    npx yarn install
    npx yarn build
  else
    # TODO: this is dangerous use uvx toml-cli toml set project.version $RELEASE_VERSION instead of this
    # cringe perl code
    perl -pi -e "s/^version = .*$/version = \"$version\"/" pyproject.toml

    if ! is_truthy "$LLAMA_STACK_ONLY"; then
      perl -pi -e "s/llama-stack-client>=.*,/llama-stack-client>=$RELEASE_VERSION\",/" pyproject.toml

      if [ "$repo" == "stack" ]; then
        perl -pi -e "s/(\"llama-stack-client\": \").+\"/\1^$RELEASE_VERSION\"/" llama_stack/ui/package.json
      fi

      if [ -f "src/llama_stack_client/_version.py" ]; then
        perl -pi -e "s/__version__ = .*$/__version__ = \"$version\"/" src/llama_stack_client/_version.py
      fi
    fi

    if is_truthy "$should_run_uv_lock"; then
      run_uv_lock

      if [ "$repo" == "stack" ]; then
        run_npm_install
      fi
    fi
  fi

  # Only commit if there are changes
  if [ -n "$(git status --porcelain)" ]; then
    git commit -am "build: Bump version to $version"
  else
    echo "No changes to commit for version bump to $version"
  fi
}

TMPDIR=$(mktemp -d)
cd $TMPDIR
uv venv build-env
source build-env/bin/activate

uv pip install twine
npm install -g yarn

BASE_BRANCHES=()

for idx in "${!REPOS[@]}"; do
  repo="${REPOS[$idx]}"
  org=$(github_org $repo)
  git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git"
  cd llama-$repo
  git fetch origin refs/tags/v${RC_VERSION}:refs/tags/v${RC_VERSION}
  git checkout -b release-$RELEASE_VERSION refs/tags/v${RC_VERSION}
  git fetch origin --prune

  if ! base_branch=$(determine_base_branch); then
    echo "Failed to determine base branch for $repo" >&2
    exit 1
  fi

  if ! git ls-remote --heads origin "$base_branch" >/dev/null 2>&1; then
    echo "Base branch $base_branch not found on remote for $repo" >&2
    exit 1
  fi
  BASE_BRANCHES[$idx]="$base_branch"

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

which llama
llama stack list-apis
llama stack list-providers inference

# just check if llama stack list-deps works
llama stack list-deps starter

if is_truthy "$DRY_RUN"; then
  echo "DRY RUN: skipping pypi upload"
  exit 0
fi

for repo in "${REPOS[@]}"; do
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

deactivate
rm -rf build-env

for idx in "${!REPOS[@]}"; do
  repo="${REPOS[$idx]}"
  cd $TMPDIR
  if [ "$repo" != "stack-client-typescript" ]; then
    uv venv -p python3.12 repo-$repo-env
    source repo-$repo-env/bin/activate
  fi

  cd llama-$repo

  # push the release branch/tag and update the source branch
  echo "Pushing branch and tag v$RELEASE_VERSION for $repo"
  org=$(github_org $repo)
  git push -f "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git" "release-$RELEASE_VERSION"
  git push -f "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git" "v$RELEASE_VERSION"

  if ! is_truthy "$LLAMA_STACK_ONLY"; then
    base_branch="${BASE_BRANCHES[$idx]}"
    git fetch origin "$base_branch"
    git checkout -B "$base_branch" "origin/$base_branch"
    add_bump_version_commit $repo $RELEASE_VERSION true
    git push "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git" "$base_branch"
  fi

  if [ "$repo" != "stack-client-typescript" ]; then
    deactivate
  fi

  cd ..
done

echo "Done"
