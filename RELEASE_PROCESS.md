# Release Process

Releases are managed through long-lived release branches. Each minor version (e.g., `0.1.x`) has one branch containing all patch releases for that series.

```
main
  ↓
release-0.1.x ← v0.1.0rc1, v0.1.0rc2, v0.1.0, v0.1.1rc1, v0.1.1, ...
  ↓
release-0.2.x ← v0.2.0rc1, v0.2.0, ...
```

## Workflows

**Cut Release Candidate** (`cut-release-candidate.yaml`)

Creates an RC for testing. Provide the RC version (e.g., `0.1.0rc1`) and optionally a specific commit hash. The workflow derives the release branch from the version (`0.1.0rc1` → `release-0.1.x`). If the branch exists, it uses HEAD; otherwise it creates the branch from main (or the specified commit). It then bumps the version, builds packages, runs tests, and publishes to test.pypi.

**Release Final Package** (`release-final-package.yaml`)

Promotes an RC to final. Provide the RC version to promote (e.g., `0.1.0rc2`) and the final version name (e.g., `0.1.0`). The workflow checks out the RC tag, bumps version strings, updates lockfiles, publishes to PyPI/npm, and creates a PR to bump main to the next dev version (`0.1.1.dev0`).

**Test Published Package** (`test-published-package.yaml`)

Manually tests any published package version.

## Examples

**New minor version (0.1.0):**

1. Cut first RC: `version=0.1.0rc1` (creates `release-0.1.x` from main)
2. Test, find bugs, cherry-pick fixes to `release-0.1.x`
3. Cut another RC: `version=0.1.0rc2` (uses HEAD of `release-0.1.x`)
4. Promote to final: `rc_version=0.1.0rc2`, `release_version=0.1.0`

**Patch release (0.1.1):**

1. Cherry-pick fixes to `release-0.1.x`
2. Cut RC: `version=0.1.1rc1`
3. Promote to final: `rc_version=0.1.1rc1`, `release_version=0.1.1`

## Version Naming

- RC: `X.Y.Zrc1`, `X.Y.Zrc2` (manual, sequential)
- Final: `X.Y.Z`
- Dev: `X.Y.Z.dev0` (auto-generated for main)
- Branches: `release-X.Y.x`

## Notes

Release branches are created on the first RC, not on final release. Main is automatically bumped via PR after each final release (patch + 1). Cherry-picking is done manually between RCs. The `commit_hash` parameter is optional and validates against branch ancestry if provided.
