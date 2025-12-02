#!/usr/bin/env bash

# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the terms described in the LICENSE file in
# the root directory of this source tree.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_ROOT=$(mktemp -d)
trap 'rm -rf "$WORK_ROOT"' EXIT

# Source the functions
source "$ROOT_DIR/tests/lib/release-functions.sh"

passed=0
failed=0

log_test() { echo "[TEST] $1"; }
log_pass() { echo "[PASS] $1"; ((passed++)); }
log_fail() { echo "[FAIL] $1"; ((failed++)); }

echo "==============================="
echo "Release Workflow Tests"
echo "==============================="
echo ""

# Test version parsing
log_test "Version parsing"

result=$(parse_version_and_branch "0.1.0rc1")
if [ "$result" = "release-0.1.x" ]; then
  log_pass "0.1.0rc1 → release-0.1.x"
else
  log_fail "0.1.0rc1 failed: got $result"
fi

result=$(parse_version_and_branch "1.2.3")
if [ "$result" = "release-1.2.x" ]; then
  log_pass "1.2.3 → release-1.2.x"
else
  log_fail "1.2.3 failed: got $result"
fi

result=$(parse_version_and_branch "0.2.10.1rc5")
if [ "$result" = "release-0.2.x" ]; then
  log_pass "0.2.10.1rc5 → release-0.2.x"
else
  log_fail "0.2.10.1rc5 failed: got $result"
fi

# Test invalid versions (expect them to fail)
if parse_version_and_branch "foobar" >/dev/null 2>&1; then
  log_fail "Should reject 'foobar'"
else
  log_pass "Rejected invalid version 'foobar'"
fi

if parse_version_and_branch "0.1" >/dev/null 2>&1; then
  log_fail "Should reject '0.1'"
else
  log_pass "Rejected incomplete version '0.1'"
fi

echo ""

# Test dev version detection
log_test "Dev version detection"

if is_dev_version "0.0.0.dev20251031001530"; then
  log_pass "Detected dev version"
else
  log_fail "Failed to detect dev version"
fi

if is_dev_version "0.1.0rc1"; then
  log_fail "Should not detect rc as dev"
else
  log_pass "RC not detected as dev"
fi

if is_dev_version "1.2.3"; then
  log_fail "Should not detect release as dev"
else
  log_pass "Release not detected as dev"
fi

echo ""

# Test git operations with synthetic repos
log_test "Git branch operations"

test_repo="$WORK_ROOT/test-repo"
git init -q "$test_repo"
cd "$test_repo"
git config user.email "test@example.com"
git config user.name "Test"

echo "initial" > file.txt
git add file.txt
git commit -q -m "Initial"
git branch -M main

# Add more commits
echo "feature1" >> file.txt
git commit -q -am "Feature 1"
echo "feature2" >> file.txt
git commit -q -am "Feature 2"

# Create release branch
git checkout -q -b release-0.1.x
echo "rc prep" >> file.txt
git commit -q -am "RC prep"
rc_commit=$(git rev-parse HEAD)

log_pass "Created synthetic repo with release branch"

# Test branch exists
git checkout -q main
if git show-ref --verify --quiet refs/heads/release-0.1.x; then
  log_pass "Release branch exists"
else
  log_fail "Release branch should exist"
fi

# Test getting HEAD of branch
branch_head=$(git rev-parse release-0.1.x)
[ "$branch_head" = "$rc_commit" ] && log_pass "Can get HEAD of release branch" || log_fail "Branch HEAD mismatch"

echo ""

# Test commit ancestry
log_test "Commit ancestry checking"

old_commit=$(git rev-parse main~1)
if git merge-base --is-ancestor "$old_commit" "release-0.1.x"; then
  log_pass "Old commit is ancestor of release branch"
else
  log_fail "Ancestry check failed"
fi

# Test that main and release have common ancestor
if git merge-base main release-0.1.x >/dev/null 2>&1; then
  log_pass "Main and release branch have common ancestor"
else
  log_fail "Should have common ancestor"
fi

echo ""

# Test version bump operations
log_test "Version bump operations"

bump_test_dir="$WORK_ROOT/bump-test"
mkdir -p "$bump_test_dir"
cd "$bump_test_dir"

cat > pyproject.toml <<'EOF'
[project]
name = "test"
version = "0.1.0rc1"
dependencies = [
    "llama-stack-client>=0.1.0rc1",
]
EOF

perl -pi -e 's/^version = .*$/version = "0.1.0"/' pyproject.toml
perl -pi -e 's/llama-stack-client>=.*/llama-stack-client>=0.1.0",/' pyproject.toml

if grep -q 'version = "0.1.0"' pyproject.toml && grep -q 'llama-stack-client>=0.1.0"' pyproject.toml; then
  log_pass "Version bump RC → final"
else
  log_fail "Version bump failed"
fi

echo ""

# Test dev version calculation
log_test "Dev version calculation"

calc_dev_version() {
  local release=$1
  local major=$(echo "$release" | cut -d. -f1)
  local minor=$(echo "$release" | cut -d. -f2)
  local patch=$(echo "$release" | cut -d. -f3)
  local next_patch=$((patch + 1))
  echo "${major}.${minor}.${next_patch}.dev0"
}

result=$(calc_dev_version "0.1.0")
[ "$result" = "0.1.1.dev0" ] && log_pass "0.1.0 → 0.1.1.dev0" || log_fail "Dev version calc failed"

result=$(calc_dev_version "1.2.5")
[ "$result" = "1.2.6.dev0" ] && log_pass "1.2.5 → 1.2.6.dev0" || log_fail "Dev version calc failed"

echo ""

# Run integration tests
echo "==============================="
echo "Running Integration Tests"
echo "==============================="
echo ""

if bash "$ROOT_DIR/tests/integration/test-cut-rc.sh"; then
  log_pass "Integration test suite passed"
else
  log_fail "Integration test suite failed"
fi

echo ""

# Summary
echo "==============================="
echo "Summary"
echo "==============================="
echo "Passed: $passed"
echo "Failed: $failed"
echo ""

if [ $failed -eq 0 ]; then
  echo "✓ All tests passed!"
  exit 0
else
  echo "✗ Some tests failed"
  exit 1
fi
