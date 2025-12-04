#!/bin/bash

# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the terms described in the LICENSE file in
# the root directory of this source tree.

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi

GITHUB_TOKEN=${GITHUB_TOKEN:-}
CUT_MODE=${CUT_MODE:-test-and-cut}
LLAMA_STACK_ONLY=${LLAMA_STACK_ONLY:-false}
COMMIT_HASH=${COMMIT_HASH:-}

source $(dirname $0)/../common.sh

set -euo pipefail
set -x

if [ "$CUT_MODE" != "test-and-cut" ] && [ "$CUT_MODE" != "test-only" ] && [ "$CUT_MODE" != "cut-only" ]; then
  echo "Invalid mode: $CUT_MODE" >&2
  exit 1
fi

is_truthy() {
  case "$1" in
  true | 1) return 0 ;;
  false | 0) return 1 ;;
  *) return 1 ;;
  esac
}

# Detect if this is a dev version (e.g., 0.0.0.dev20251031001530)
# Dev versions are built from main and don't use release branches
if [[ "$VERSION" =~ \.dev[0-9]+$ ]]; then
  IS_DEV_BUILD=true
  RELEASE_BRANCH=""
  echo "Detected dev version: $VERSION (will build from main, no release branch)"
else
  IS_DEV_BUILD=false

  # Parse version to extract base version and derive release branch name
  # Examples:
  #   0.1.0rc1 -> base=0.1.0, branch=release-0.1.x
  #   0.1.1rc2 -> base=0.1.1, branch=release-0.1.x
  #   1.2.3 -> base=1.2.3, branch=release-1.2.x
  #   0.2.10.1rc1 -> base=0.2.10.1, branch=release-0.2.x
  parse_version_and_branch() {
    local version=$1

    # Validate version format (basic check for X.Y.Z or X.Y.Z.W pattern)
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?(rc[0-9]+)?$ ]]; then
      echo "ERROR: Invalid version format: $version" >&2
      echo "Expected format: X.Y.Z[.W][rcN] (e.g., 0.1.0rc1, 1.2.3, 0.2.10.1)" >&2
      exit 1
    fi

    # Remove rc suffix if present (e.g., 0.1.0rc1 -> 0.1.0)
    local base_version=$(echo "$version" | sed 's/rc[0-9]*$//')

    # Extract major.minor (e.g., 0.1.0 -> 0.1)
    local major=$(echo "$base_version" | cut -d. -f1)
    local minor=$(echo "$base_version" | cut -d. -f2)

    # Derive branch name: release-{major}.{minor}.x
    local branch_name="release-${major}.${minor}.x"

    echo "$branch_name"
  }

  RELEASE_BRANCH=$(parse_version_and_branch "$VERSION")
  echo "Derived release branch: $RELEASE_BRANCH"
fi

DISTRO=starter

# Save the original working directory (GitHub workspace) for log uploads
WORKSPACE_DIR=$(pwd)

TMPDIR=$(mktemp -d)
cd $TMPDIR

uv venv --python 3.12
source .venv/bin/activate

determine_source_commit_for_repo() {
  local repo=$1
  local org=$(github_org $repo)

  # Check if release branch exists for this repo
  if git ls-remote --heads "https://github.com/$org/llama-$repo.git" "$RELEASE_BRANCH" | grep -q .; then
    echo "Release branch $RELEASE_BRANCH exists for $repo" >&2

    if [ -n "$COMMIT_HASH" ]; then
      # COMMIT_HASH override provided - validate it
      echo "Validating commit override: $COMMIT_HASH" >&2

      # Fetch both the commit and the branch
      git fetch origin "$COMMIT_HASH" || {
        echo "ERROR: Commit $COMMIT_HASH does not exist in $repo" >&2
        exit 1
      }

      git fetch origin "$RELEASE_BRANCH"

      # Check if commit is related to the branch (ancestor or descendant)
      if ! git merge-base --is-ancestor "$COMMIT_HASH" "origin/$RELEASE_BRANCH" &&
        ! git merge-base --is-ancestor "origin/$RELEASE_BRANCH" "$COMMIT_HASH"; then
        echo "ERROR: Commit $COMMIT_HASH is not related to branch $RELEASE_BRANCH" >&2
        echo "ERROR: The commit must be an ancestor or descendant of the release branch" >&2
        exit 1
      fi

      echo "Using commit override: $COMMIT_HASH" >&2
      echo "$COMMIT_HASH"
    else
      # Use HEAD of release branch
      echo "Using HEAD of existing release branch" >&2
      echo "origin/$RELEASE_BRANCH"
    fi
  else
    echo "Release branch $RELEASE_BRANCH does not exist for $repo - will create it" >&2

    if [ -n "$COMMIT_HASH" ]; then
      # Creating new branch from commit override
      echo "Creating new release branch from commit: $COMMIT_HASH" >&2

      # Validate commit exists
      git fetch origin "$COMMIT_HASH" || {
        echo "ERROR: Commit $COMMIT_HASH does not exist in $repo" >&2
        exit 1
      }

      echo "$COMMIT_HASH"
    else
      # Creating new branch from main
      echo "Creating new release branch from origin/main" >&2
      echo "origin/main"
    fi
  fi
}

build_packages() {
  npm install -g yarn

  REPOS=(stack-client-python stack-client-typescript stack)
  if is_truthy "$LLAMA_STACK_ONLY"; then
    REPOS=(stack)
  fi

  for repo in "${REPOS[@]}"; do
    org=$(github_org $repo)
    git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git"
    cd llama-$repo

    if [ "$IS_DEV_BUILD" = "true" ]; then
      # For dev builds, always build from main
      git fetch origin main
      git checkout -b "dev-build-$VERSION" origin/main
    else
      # Determine which commit to use as the base for release builds
      SOURCE_COMMIT=$(determine_source_commit_for_repo "$repo")

      # Checkout/create the release branch
      if [[ "$SOURCE_COMMIT" == origin/* ]]; then
        # It's a remote ref (either origin/release-X.Y.x or origin/main)
        REF="${SOURCE_COMMIT#origin/}"
        git fetch origin "$REF"

        if [ "$REF" == "$RELEASE_BRANCH" ]; then
          # Branch already exists, check it out
          git checkout -b "$RELEASE_BRANCH" FETCH_HEAD
        else
          # Creating new release branch from main or other ref
          git checkout -b "$RELEASE_BRANCH" FETCH_HEAD
        fi
      else
        # It's a commit hash, create release branch from it
        git checkout -b "$RELEASE_BRANCH" "$SOURCE_COMMIT"
      fi
    fi

    # TODO: this is dangerous use uvx toml-cli toml set project.version $VERSION instead of this
    perl -pi -e "s/^version = .*$/version = \"$VERSION\"/" pyproject.toml

    # Handle llama_stack_api version bump
    if [ "$repo" == "stack" ] && [ -d "src/llama_stack_api" ] && [ -f "src/llama_stack_api/pyproject.toml" ]; then
      echo "Bumping version for llama_stack_api to $VERSION"
      perl -pi -e "s/^version = .*$/version = \"$VERSION\"/" src/llama_stack_api/pyproject.toml
    fi

    if ! is_truthy "$LLAMA_STACK_ONLY"; then
      # this one is only applicable for llama-stack-client-python
      if [ -f "src/llama_stack_client/_version.py" ]; then
        perl -pi -e "s/__version__ = .*$/__version__ = \"$VERSION\"/" src/llama_stack_client/_version.py
      fi
      if [ -f "package.json" ]; then
        perl -pi -e "s/\"version\": \".*\"/\"version\": \"$VERSION\"/" package.json
      fi

      # this is applicable for llama-stack repo but we should not do it when
      # LLAMA_STACK_ONLY is true
      perl -pi -e "s/llama-stack-client>=.*/llama-stack-client>=$VERSION\",/" pyproject.toml
    fi

    if [ "$repo" == "stack-client-typescript" ]; then
      npx yarn install
      npx yarn build
    else
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
    fi

    # Only commit if there are changes
    if ! git diff --quiet || ! git diff --cached --quiet; then
      if [ "$IS_DEV_BUILD" = "true" ]; then
        git commit -am "Dev build $VERSION"
      else
        git commit -am "Release candidate $VERSION"
      fi
    else
      echo "No version changes detected for $repo (version already set to $VERSION)"
    fi
    cd ..
  done
}

test_library_client() {
  echo "Installing distribution dependencies"
  llama stack list-deps $DISTRO | xargs -L1 uv pip install

  echo "Running integration tests before uploading"
  run_integration_tests $DISTRO
}

test_docker() {
  echo "Testing docker"

  if is_truthy "$LLAMA_STACK_ONLY"; then
    LLAMA_STACK_CLIENT_ARG=""
  else
    LLAMA_STACK_CLIENT_ARG="--build-arg LLAMA_STACK_CLIENT_DIR=/workspace/llama-stack-client-python"
  fi

  docker build . \
    -f llama-stack/containers/Containerfile \
    --build-arg DISTRO_NAME=$DISTRO \
    --build-arg INSTALL_MODE=editable \
    --build-arg LLAMA_STACK_DIR=/workspace/llama-stack \
    $LLAMA_STACK_CLIENT_ARG \
    -t distribution-$DISTRO:dev

  docker images

  # run the container in the background
  export LLAMA_STACK_PORT=8321

  docker run -d --network host --name llama-stack-$DISTRO -p $LLAMA_STACK_PORT:$LLAMA_STACK_PORT \
    -e OLLAMA_URL=http://localhost:11434/v1 \
    -e SAFETY_MODEL=ollama/llama-guard3:1b \
    -e LLAMA_STACK_TEST_INFERENCE_MODE=replay \
    -e LLAMA_STACK_TEST_STACK_CONFIG_TYPE=server \
    -e LLAMA_STACK_TEST_MCP_HOST=localhost \
    -e LLAMA_STACK_TEST_DEBUG=1 \
    -e LLAMA_STACK_TEST_RECORDING_DIR=/app/llama-stack-source/tests/integration/common \
    -v $(pwd)/llama-stack:/app/llama-stack-source \
    distribution-$DISTRO:dev \
    --port $LLAMA_STACK_PORT

  # Ensure docker logs are saved even if tests fail
  trap 'docker logs llama-stack-'"$DISTRO"' > "'"$WORKSPACE_DIR"'/docker-'"$DISTRO"'.log" 2>&1 || true; docker stop llama-stack-'"$DISTRO"' || true' EXIT

  # check localhost:$LLAMA_STACK_PORT/health repeatedly until it returns 200
  iterations=0
  max_iterations=20
  while [ $(curl -s -o /dev/null -w "%{http_code}" localhost:$LLAMA_STACK_PORT/v1/health) -ne 200 ]; do
    sleep 2
    iterations=$((iterations + 1))
    if [ $iterations -gt $max_iterations ]; then
      echo "Failed to start the container"
      docker logs llama-stack-$DISTRO
      exit 1
    fi
  done

  run_integration_tests http://localhost:$LLAMA_STACK_PORT

  # save docker logs and stop the container (trap will also handle cleanup on failure)
  docker logs llama-stack-$DISTRO >"$WORKSPACE_DIR/docker-$DISTRO.log" 2>&1
  docker stop llama-stack-$DISTRO

  # Clear the trap since we've completed successfully
  trap - EXIT
}

build_packages

install_dependencies

if [ "$CUT_MODE" != "cut-only" ]; then
  test_llama_cli
  test_library_client
  test_docker
fi

# if MODE is test-only, don't cut the branch
if [ "$CUT_MODE" == "test-only" ]; then
  echo "Not cutting (i.e., pushing the branch) because MODE is test-only"
  exit 0
fi

# Dev builds don't push branches (they build from main)
if [ "$IS_DEV_BUILD" = "true" ]; then
  echo "Dev build $VERSION completed successfully"
  echo "Built from main branch, packages published to test.pypi"
  echo "No branches pushed (dev builds are ephemeral)"
  exit 0
fi

for repo in "${REPOS[@]}"; do
  echo "Pushing release branch $RELEASE_BRANCH for llama-$repo"
  cd llama-$repo
  org=$(github_org $repo)
  git push -f "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git" "$RELEASE_BRANCH"
  cd ..
done

echo "Successfully cut release candidate $VERSION on branch $RELEASE_BRANCH"
