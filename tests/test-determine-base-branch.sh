#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/actions/lib/release_utils.sh"

REPO_URL=${REPO_URL:-https://github.com/llamastack/llama-stack.git}
WORK_ROOT=$(mktemp -d)
trap 'rm -rf "$WORK_ROOT"' EXIT

REAL_REPO="$WORK_ROOT/llama-stack"

echo ">>> Cloning $REPO_URL"
git clone --filter=blob:none "$REPO_URL" "$REAL_REPO" >/dev/null
git -C "$REAL_REPO" fetch origin --tags --prune >/dev/null

assert_branch() {
  local repo=$1
  local tag=$2
  local expected=$3

  echo "==> Checking $tag expected $expected"
  git -C "$repo" checkout --detach "$tag" >/dev/null
  git -C "$repo" fetch origin --prune >/dev/null
  pushd "$repo" >/dev/null
  local branch
  branch=$(determine_base_branch)
  popd >/dev/null

  if [ "$branch" != "$expected" ]; then
    echo "[FAIL] $tag resolved to $branch (expected $expected)" >&2
    return 1
  fi

  echo "[PASS] $tag -> $branch"
}

failures=0

# Real history examples should map back to main because release branches are
# materialised after the RC is cut.
assert_branch "$REAL_REPO" "v0.3.0rc6" "main" || failures=$((failures + 1))
assert_branch "$REAL_REPO" "v0.2.10rc2" "main" || failures=$((failures + 1))
assert_branch "$REAL_REPO" "v0.2.10.1rc1" "main" || failures=$((failures + 1))

# Synthetic repo to cover patch release flow (release branch diverges from main)
SYNTH_REMOTE="$WORK_ROOT/synth-origin.git"
SYNTH_CLONE="$WORK_ROOT/synth-work"

git init --bare "$SYNTH_REMOTE" >/dev/null
git clone "$SYNTH_REMOTE" "$SYNTH_CLONE" >/dev/null

pushd "$SYNTH_CLONE" >/dev/null
git config user.email "ci@example.com"
git config user.name "CI"

echo "base" >base.txt
git add base.txt
git commit -m "Initial commit" >/dev/null

git branch -M main
git push -u origin main >/dev/null
git -C "$SYNTH_REMOTE" symbolic-ref HEAD refs/heads/main >/dev/null

git checkout main
echo "feature" >feature.txt
git add feature.txt
git commit -m "Main feature" >/dev/null
git push origin main >/dev/null

git checkout -b release-1
echo "fix1" >fix.txt
git add fix.txt
git commit -m "Release fix prep" >/dev/null
echo "rc content" >rc.txt
git add rc.txt
git commit -m "Release candidate commit" >/dev/null
git tag v1.0.0-rc1
git push origin release-1 >/dev/null
git push origin v1.0.0-rc1 >/dev/null
popd >/dev/null

git -C "$SYNTH_CLONE" checkout --detach v1.0.0-rc1 >/dev/null
git -C "$SYNTH_CLONE" fetch origin --prune >/dev/null
pushd "$SYNTH_CLONE" >/dev/null
branch=$(determine_base_branch)
popd >/dev/null

echo "Synthetic branch resolved: $branch"
if [ "$branch" != "release-1" ]; then
  echo "[FAIL] v1.0.0-rc1 resolved to $branch (expected release-1)" >&2
  failures=$((failures + 1))
else
  echo "[PASS] v1.0.0-rc1 -> $branch"
fi

if [ $failures -ne 0 ]; then
  echo "Detected $failures failing cases." >&2
  exit 1
fi

echo "All cases passed."
