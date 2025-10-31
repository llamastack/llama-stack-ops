#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK_ROOT=$(mktemp -d)
trap 'rm -rf "$WORK_ROOT"' EXIT

passed=0
failed=0

log_test() { echo "[TEST] $1"; }
log_pass() { echo "[PASS] $1"; passed=$((passed + 1)); }
log_fail() { echo "[FAIL] $1" >&2; failed=$((failed + 1)); }
log_info() { echo "[INFO] $1"; }

# Create a synthetic repo with proper structure
create_synthetic_repo() {
  local repo_name=$1
  local repo_path="$WORK_ROOT/repos/$repo_name.git"

  mkdir -p "$repo_path"
  cd "$repo_path"
  git init --bare -q

  # Create working copy
  local work_dir="$WORK_ROOT/work/$repo_name"
  git clone -q "$repo_path" "$work_dir"
  cd "$work_dir"

  git config user.email "test@example.com"
  git config user.name "Test User"

  # Create initial structure based on repo type
  if [ "$repo_name" = "llama-stack" ]; then
    cat > pyproject.toml <<'EOF'
[project]
name = "llama-stack"
version = "0.0.1"
dependencies = [
    "llama-stack-client>=0.0.1",
]
EOF
    mkdir -p llama_stack/ui
    cat > llama_stack/ui/package.json <<'EOF'
{
  "name": "llama-stack-ui",
  "version": "0.0.1",
  "dependencies": {
    "llama-stack-client": "^0.0.1"
  }
}
EOF
  elif [ "$repo_name" = "llama-stack-client-python" ]; then
    cat > pyproject.toml <<'EOF'
[project]
name = "llama-stack-client"
version = "0.0.1"
EOF
    mkdir -p src/llama_stack_client
    cat > src/llama_stack_client/_version.py <<'EOF'
__version__ = "0.0.1"
EOF
  elif [ "$repo_name" = "llama-stack-client-typescript" ]; then
    cat > package.json <<'EOF'
{
  "name": "llama-stack-client",
  "version": "0.0.1"
}
EOF
  fi

  echo "# $repo_name" > README.md
  git add .
  git commit -q -m "Initial commit"
  git branch -M main
  git push -q -u origin main
}

# Mock github_org function
github_org() {
  local repo=$1
  if [ "$repo" = "stack" ]; then
    echo "meta-llama"
  else
    echo "llamastack"
  fi
}
export -f github_org

echo "========================================"
echo "Integration Test: Cut Release Candidate"
echo "========================================"
echo ""

log_info "Setting up synthetic repos..."

# Create synthetic repos
create_synthetic_repo "llama-stack" 2>&1 >/dev/null
create_synthetic_repo "llama-stack-client-python" 2>&1 >/dev/null
create_synthetic_repo "llama-stack-client-typescript" 2>&1 >/dev/null

log_pass "Created synthetic repos"

# Simulate the workflow logic for cutting an RC
log_test "Cut first RC (0.1.0rc1) - creates release branch"

export VERSION="0.1.0rc1"
export RELEASE_BRANCH="release-0.1.x"
export GITHUB_TOKEN="dummy"
export LLAMA_STACK_ONLY="false"
export COMMIT_HASH=""

# For each repo, simulate what test-and-cut/main.sh does
for repo in llama-stack-client-python llama-stack-client-typescript llama-stack; do
  log_info "Processing $repo..."

  cd "$WORK_ROOT/work/$repo"

  # Check if release branch exists (it shouldn't for first RC)
  if git ls-remote origin "$RELEASE_BRANCH" | grep -q .; then
    log_fail "$repo: Release branch shouldn't exist yet"
    continue
  fi

  # Create release branch from main (simulating first RC)
  git checkout -q main
  git pull -q origin main
  git checkout -q -b "$RELEASE_BRANCH"

  # Bump version to RC version
  if [ "$repo" = "llama-stack-client-typescript" ]; then
    perl -pi -e "s/\"version\": \".*\"/\"version\": \"$VERSION\"/" package.json
  else
    perl -pi -e "s/^version = .*$/version = \"$VERSION\"/" pyproject.toml

    if [ "$repo" = "llama-stack-client-python" ]; then
      perl -pi -e "s/__version__ = .*$/__version__ = \"$VERSION\"/" src/llama_stack_client/_version.py
    fi

    if [ "$repo" = "llama-stack" ]; then
      # Update client dependency
      perl -pi -e "s/llama-stack-client>=.*/llama-stack-client>=$VERSION\",/" pyproject.toml
      perl -pi -e "s/(\"llama-stack-client\": \").+\"/\1^$VERSION\"/" llama_stack/ui/package.json
    fi
  fi

  # Verify version was updated
  if [ "$repo" = "llama-stack-client-typescript" ]; then
    if grep -q "\"version\": \"$VERSION\"" package.json; then
      log_pass "$repo: Version bumped in package.json"
    else
      log_fail "$repo: Version not updated in package.json"
      cat package.json
      continue
    fi
  else
    if grep -q "version = \"$VERSION\"" pyproject.toml; then
      log_pass "$repo: Version bumped in pyproject.toml"
    else
      log_fail "$repo: Version not updated in pyproject.toml"
      cat pyproject.toml
      continue
    fi
  fi

  # Verify client dependency updated for stack
  if [ "$repo" = "llama-stack" ]; then
    if grep -q "llama-stack-client>=$VERSION" pyproject.toml && \
       grep -q "\"llama-stack-client\": \"^$VERSION\"" llama_stack/ui/package.json; then
      log_pass "$repo: Client dependencies updated"
    else
      log_fail "$repo: Client dependencies not updated correctly"
      grep "llama-stack-client" pyproject.toml llama_stack/ui/package.json
      continue
    fi
  fi

  # Commit and push
  git commit -q -am "Release candidate $VERSION"
  git push -q origin "$RELEASE_BRANCH"

  # Verify branch exists remotely
  if git ls-remote origin "$RELEASE_BRANCH" | grep -q .; then
    log_pass "$repo: Release branch pushed to remote"
  else
    log_fail "$repo: Release branch not found on remote"
  fi
done

echo ""
log_test "Cut second RC (0.1.0rc2) - uses existing release branch"

export VERSION="0.1.0rc2"

for repo in llama-stack-client-python llama-stack-client-typescript llama-stack; do
  log_info "Processing $repo for RC2..."

  cd "$WORK_ROOT/work/$repo"

  # Check release branch exists
  if ! git ls-remote origin "$RELEASE_BRANCH" | grep -q .; then
    log_fail "$repo: Release branch should exist"
    continue
  fi

  # Fetch and checkout existing release branch
  git fetch -q origin "$RELEASE_BRANCH"
  git checkout -q "$RELEASE_BRANCH"
  git pull -q origin "$RELEASE_BRANCH"

  # Add a "fix" to simulate cherry-picked changes
  echo "// Fix for RC2" >> README.md
  git commit -q -am "Fix for RC2"

  # Bump version to new RC
  if [ "$repo" = "llama-stack-client-typescript" ]; then
    perl -pi -e "s/\"version\": \".*\"/\"version\": \"$VERSION\"/" package.json
  else
    perl -pi -e "s/^version = .*$/version = \"$VERSION\"/" pyproject.toml

    if [ "$repo" = "llama-stack-client-python" ]; then
      perl -pi -e "s/__version__ = .*$/__version__ = \"$VERSION\"/" src/llama_stack_client/_version.py
    fi

    if [ "$repo" = "llama-stack" ]; then
      perl -pi -e "s/llama-stack-client>=.*/llama-stack-client>=$VERSION\",/" pyproject.toml
      perl -pi -e "s/(\"llama-stack-client\": \").+\"/\1^$VERSION\"/" llama_stack/ui/package.json
    fi
  fi

  # Verify version updated
  if [ "$repo" = "llama-stack-client-typescript" ]; then
    if grep -q "\"version\": \"$VERSION\"" package.json; then
      log_pass "$repo: Version bumped to RC2"
    else
      log_fail "$repo: Version not updated to RC2"
    fi
  else
    if grep -q "version = \"$VERSION\"" pyproject.toml; then
      log_pass "$repo: Version bumped to RC2"
    else
      log_fail "$repo: Version not updated to RC2"
    fi
  fi

  git commit -q -am "Release candidate $VERSION"
  git push -q origin "$RELEASE_BRANCH"
done

echo ""
log_test "Branch history verification"

cd "$WORK_ROOT/work/llama-stack"
git fetch -q origin "$RELEASE_BRANCH"
git checkout -q "$RELEASE_BRANCH"

# Check we have commits for both RCs
commit_count=$(git log --oneline | wc -l | tr -d ' ')
if [ "$commit_count" -ge 3 ]; then
  log_pass "Release branch has expected commit history"
else
  log_fail "Release branch should have at least 3 commits (initial, RC1, fix, RC2)"
fi

# Verify both RC commits exist
log_output=$(git log --oneline)
if echo "$log_output" | grep -q "0.1.0rc1" && \
   echo "$log_output" | grep -q "0.1.0rc2" && \
   echo "$log_output" | grep -q "Fix for RC2"; then
  log_pass "Both RC commits present in history"
else
  log_fail "RC commits not found in history"
  echo "$log_output"
fi

echo ""
echo "========================================"
echo "Summary"
echo "========================================"
echo "Passed: $passed"
echo "Failed: $failed"
echo ""

if [ $failed -eq 0 ]; then
  echo "✓ All integration tests passed!"
  exit 0
else
  echo "✗ Some integration tests failed"
  exit 1
fi
