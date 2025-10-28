determine_base_branch() {
  local parent_commit
  if ! parent_commit=$(git rev-parse HEAD^ 2>/dev/null); then
    echo "Unable to determine parent commit for release candidate tag" >&2
    return 1
  fi

  if git merge-base --is-ancestor "$parent_commit" origin/main >/dev/null 2>&1; then
    echo "main"
    return 0
  fi

  # Collect the origin branches that already contain the parent commit; Git stops
  # walking each branch's history once it finds the commit, so this stays fast even
  # with many remote branches.
  mapfile -t candidates < <(git for-each-ref \
    --format='%(refname:strip=3)' \
    --sort=-committerdate \
    --contains "$parent_commit" \
    "refs/remotes/origin")

  local releases=()
  local main_candidate=""

  for branch in "${candidates[@]}"; do
    if [ "$branch" = "HEAD" ]; then
      continue
    fi
    if [[ "$branch" == rc-* ]]; then
      continue
    fi
    if [[ "$branch" == release-* ]]; then
      releases+=("$branch")
      continue
    fi
    if [ "$branch" = "main" ]; then
      main_candidate="main"
    fi
  done

  if [ ${#releases[@]} -gt 0 ]; then
    local best_branch=""
    local best_distance=""

    for branch in "${releases[@]}"; do
      local distance
      distance=$(git rev-list --count "$parent_commit".. "origin/$branch")
      if [ -z "$best_branch" ]; then
        best_branch="$branch"
        best_distance="$distance"
      elif [ "$distance" -lt "$best_distance" ]; then
        best_branch="$branch"
        best_distance="$distance"
      fi
    done

    if [ -n "$best_branch" ]; then
      echo "$best_branch"
      return 0
    fi
  fi

  if [ -n "$main_candidate" ]; then
    echo "$main_candidate"
    return 0
  fi

  echo "Unable to determine base branch for parent commit $parent_commit" >&2
  return 1
}
