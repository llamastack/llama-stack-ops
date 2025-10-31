# Release Workflow Design

## Overview

This document describes the standardized release process for llama-stack projects. The goal is to simplify the release workflow by eliminating complex branch logic and making releases always happen from stable release branches.

## Problems with Previous Approach

- Complex `determine_base_branch()` logic trying to figure out where to push changes
- Releases checked out from RC tags but tried to push version bumps back to "source branches"
- Cherry-picks done out-of-band to RC branches
- Unclear relationship between release artifacts and branches

## New Standard Process

### Mental Model

1. **Cut a release branch once** (e.g., `release-0.1.x`)
2. **Land cherry-picks** to that branch (manual, out-of-band)
3. **Cut RCs** from the branch: `0.1.0rc1`, `0.1.0rc2`, `0.1.0rc3`...
4. **Promote RC to final**: Pick a good RC (e.g., `0.1.0rc3`) and release as `0.1.0`
5. **Continue on same branch**: Cherry-pick more fixes, cut `0.1.1rc1`, release `0.1.1`, etc.

### Version Strings

- **RC versions:** `0.1.0rc1`, `0.1.0rc2` (manual, sequential)
- **Final versions:** `0.1.0`, `0.1.1`
- **Main branch version:** `0.1.1.dev0` (auto-bumped after each final release)

## Workflow 1: Cut Release Candidate

**File:** `.github/workflows/cut-release-candidate.yaml`

### Inputs

```yaml
version:
  description: 'Version (e.g. 0.1.0rc1)'
  required: true

commit_hash:
  description: 'Optional: specific commit override (with sanity checks)'
  required: false
```

### Logic

1. **Parse version:** `0.1.0rc1` → base version `0.1.0` → derive branch `release-0.1.x`
   - Pattern: `release-{major}.{minor}.x`
   - Examples:
     - `0.1.0rc1` → `release-0.1.x`
     - `0.1.1rc1` → `release-0.1.x`
     - `1.2.3rc1` → `release-1.2.x`

2. **Determine source commit:**
   - Check if `release-0.1.x` branch exists:
     - **Exists:** Use current HEAD of that branch
     - **Doesn't exist:** Create from `commit_hash` or `origin/main`
   - **If `commit_hash` provided (override):** Use it with sanity checks:
     - Verify commit exists
     - If branch exists, verify commit is related (ancestor/descendant)

3. **Build and test:**
   - Clone repos (stack, stack-client-python, stack-client-typescript)
   - Checkout appropriate commit/branch
   - Create local `rc-$VERSION` branch
   - Bump version strings to RC version
   - Update client dependency (if not `llama_stack_only`)
   - Build packages
   - Run tests (library client, CLI, Docker)

4. **Push RC branch:**
   - Push `rc-$VERSION` branch to remote

5. **Upload packages (separate job):**
   - Upload to test.pypi
   - Create git tag `v$VERSION`

### Client Branch Matching

When testing, match client branches similar to llama-stack CI:
- Detect if working with a release branch: `^release-([0-9]+\.){1,3}[0-9]+$`
- Check if matching branch exists in `llama-stack-client-python`
- Use matching branch if exists, otherwise fail
- Falls back to main for non-release branches

## Workflow 2: Release Final Package

**File:** `.github/workflows/release-final-package.yaml`

### Inputs

```yaml
rc_version:
  description: 'RC version to promote (e.g. 0.1.0rc3)'
  required: true

release_version:
  description: 'Final version name (e.g. 0.1.0)'
  required: true
```

### Logic

1. **Verify RC exists:**
   - Check RC version exists on test.pypi
   - Verify RC tag exists: `v0.1.0rc3`

2. **Parse version and derive branch:**
   - `0.1.0` → `release-0.1.x`

3. **Build final packages:**
   - For each repo:
     - Clone repo
     - Checkout RC tag: `v0.1.0rc3`
     - Create local branch `release-$RELEASE_VERSION`
     - Bump version: `0.1.0rc3` → `0.1.0` in all files (pyproject.toml, package.json, _version.py, etc.)
     - Run `uv lock` and `npm install` to update lockfiles
     - Commit: `"build: Bump version to 0.1.0"`
     - Create tag: `v0.1.0`
     - Build packages

4. **Publish packages:**
   - Upload to PyPI (Python packages)
   - Upload to npm (TypeScript client)

5. **Push to release branch:**
   - Push commit + tag to `release-0.1.x` branch
   - **That's it!** No complex base branch logic

6. **Auto-bump main version (new):**
   - Calculate next dev version: `0.1.0` → `0.1.1.dev0`
     - Parse: major=0, minor=1, patch=0
     - Next: 0.1.(patch+1).dev0 = `0.1.1.dev0`
   - Checkout main branch
   - Update version strings
   - Commit: `"chore: bump version to 0.1.1.dev0"`
   - Push to branch: `release-automation/bump-to-0.1.1.dev0`
   - Create PR to main:
     ```
     Title: chore: bump version to 0.1.1.dev0
     Body: Automated version bump after releasing 0.1.0
     ```
   - Let humans review/merge/close as needed

## Key Simplifications

### What Changed

**Cut RC Workflow:**
- ✅ Smart branch detection based on version parsing
- ✅ `commit_hash` is always an optional override with sanity checks
- ❌ Removed `client_python_commit_id` input (use branch matching instead)

**Release Final Workflow:**
- ✅ Push only to the release branch (derived from version)
- ✅ Auto-bump main via PR (patch + 1 + .dev0)
- ❌ Removed `determine_base_branch()` function
- ❌ Removed pushing to multiple branches
- ❌ Removed complex ancestry checking

### What Was Removed

- `determine_base_branch()` function in `actions/lib/release_utils.sh`
- Logic to push version bumps back to "source" branches
- Complex checking if commits are ancestors of main/release branches

## Examples

### Example 1: Starting a new 0.1.x release series

```bash
# Trigger: cut-release-candidate workflow
version: "0.1.0rc1"
commit_hash: ""  # Optional, will use origin/main

# Result:
# - Creates release-0.1.x branch from main
# - Creates rc-0.1.0rc1 branch
# - Publishes 0.1.0rc1 to test.pypi
```

### Example 2: Iterating on RCs

```bash
# Cherry-pick fixes to release-0.1.x branch (manual)

# Trigger: cut-release-candidate workflow
version: "0.1.0rc2"
commit_hash: ""  # Will use HEAD of release-0.1.x

# Result:
# - Uses existing release-0.1.x branch
# - Creates rc-0.1.0rc2 branch
# - Publishes 0.1.0rc2 to test.pypi
```

### Example 3: Promoting RC to final

```bash
# Trigger: release-final-package workflow
rc_version: "0.1.0rc2"
release_version: "0.1.0"

# Result:
# - Checks out v0.1.0rc2 tag
# - Bumps version to 0.1.0
# - Publishes 0.1.0 to PyPI
# - Pushes to release-0.1.x branch
# - Creates PR to bump main to 0.1.1.dev0
```

### Example 4: Point release on existing branch

```bash
# Cherry-pick more fixes to release-0.1.x branch (manual)

# Trigger: cut-release-candidate workflow
version: "0.1.1rc1"
commit_hash: ""  # Will use HEAD of release-0.1.x

# Result:
# - Uses existing release-0.1.x branch
# - Creates rc-0.1.1rc1 branch
# - Publishes 0.1.1rc1 to test.pypi

# Then promote:
rc_version: "0.1.1rc1"
release_version: "0.1.1"

# Result:
# - Publishes 0.1.1 to PyPI
# - Pushes to release-0.1.x branch
# - Creates PR to bump main to 0.1.2.dev0
```

## Files Modified

1. `.github/workflows/cut-release-candidate.yaml` - Update inputs and logic
2. `actions/test-and-cut/action.yaml` - Update input parameters
3. `actions/test-and-cut/main.sh` - Implement smart branch detection, commit sanity checks
4. `.github/workflows/release-final-package.yaml` - Add main bump PR step
5. `actions/release-final-package/main.sh` - Simplify branch push, add main bump logic
6. `actions/lib/release_utils.sh` - Remove `determine_base_branch()` function
