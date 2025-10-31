#!/usr/bin/env bash

# Extracted functions from release workflows for testing

is_truthy() {
  case "$1" in
  true | 1) return 0 ;;
  false | 0) return 1 ;;
  *) return 1 ;;
  esac
}

parse_version_and_branch() {
  local version=$1

  # Validate version format (basic check for X.Y.Z or X.Y.Z.W pattern)
  if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?(rc[0-9]+)?$ ]]; then
    echo "ERROR: Invalid version format: $version" >&2
    echo "Expected format: X.Y.Z[.W][rcN] (e.g., 0.1.0rc1, 1.2.3, 0.2.10.1)" >&2
    return 1
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

github_org() {
  echo "llamastack"
}
