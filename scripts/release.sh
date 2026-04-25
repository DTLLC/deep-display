#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

usage() {
  cat <<'EOF'
usage: ./scripts/release.sh [--patch|--minor|--major] [--dry-run]

Defaults to --patch.

This script:
1. bumps VERSION on the current branch,
2. commits that version bump on the current branch,
3. pushes the current branch,
4. pushes the same HEAD commit to origin/release,
5. waits for the Release DMG workflow on that commit by default.

Hard policy:
- releases require a clean worktree, including untracked files
- releases integrate origin before bumping so CI tap updates are included
- --dry-run reports the stop condition without mutating anything
- after pushing, interactive runs can press Enter at any time while waiting to stop watching locally
EOF
}

bump_kind="patch"
dry_run=0

find_release_run_id() {
  local release_sha="$1"
  local attempt output run_id

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    output="$(gh run list \
      --workflow "Release DMG" \
      --branch release \
      --commit "${release_sha}" \
      --limit 1 \
      --json databaseId 2>/dev/null || true)"
    run_id="$(printf '%s' "${output}" | sed -n 's/.*"databaseId":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"
    if [[ -n "${run_id}" ]]; then
      printf '%s\n' "${run_id}"
      return 0
    fi
    sleep 3
  done

  return 1
}

github_repo_slug() {
  local remote_url slug

  remote_url="$(git config --get remote.origin.url || true)"
  case "${remote_url}" in
    git@github.com:*.git)
      slug="${remote_url#git@github.com:}"
      printf '%s\n' "${slug%.git}"
      ;;
    git@github.com:*)
      printf '%s\n' "${remote_url#git@github.com:}"
      ;;
    https://github.com/*.git)
      slug="${remote_url#https://github.com/}"
      printf '%s\n' "${slug%.git}"
      ;;
    https://github.com/*)
      printf '%s\n' "${remote_url#https://github.com/}"
      ;;
  esac
}

github_actions_run_url() {
  local run_id="$1"
  local repo_slug

  repo_slug="$(github_repo_slug)"
  if [[ -n "${repo_slug}" ]]; then
    printf 'https://github.com/%s/actions/runs/%s\n' "${repo_slug}" "${run_id}"
  fi
}

maybe_wait_for_release() {
  local release_sha="$1"
  local run_id run_url watcher_pid skip_pid watcher_status skip_file

  if ! command -v gh >/dev/null 2>&1; then
    echo "Release pushed, but GitHub CLI is not installed so the workflow watch was skipped." >&2
    return 0
  fi

  if ! gh auth status >/dev/null 2>&1; then
    echo "Release pushed, but GitHub CLI is not authenticated so the workflow watch was skipped." >&2
    return 0
  fi

  echo "Looking for the Release DMG workflow run on ${release_sha}..."
  if ! run_id="$(find_release_run_id "${release_sha}")"; then
    echo "Release pushed, but no matching Release DMG workflow run was found yet." >&2
    return 0
  fi

  run_url="$(github_actions_run_url "${run_id}")"
  if [[ -n "${run_url}" ]]; then
    echo "GitHub Actions: ${run_url}"
  fi

  if [[ -t 1 && -r /dev/tty ]]; then
    echo "Watching Release DMG workflow run ${run_id}. Press Enter at any time to stop waiting locally."
    gh run watch "${run_id}" --exit-status &
    watcher_pid=$!
    skip_file="$(mktemp)"

    (
      IFS= read -r _skip_wait </dev/tty
      : > "${skip_file}"
      kill "${watcher_pid}" 2>/dev/null || true
    ) &
    skip_pid=$!

    set +e
    wait "${watcher_pid}"
    watcher_status=$?
    set -e

    if kill -0 "${skip_pid}" 2>/dev/null; then
      kill "${skip_pid}" 2>/dev/null || true
      wait "${skip_pid}" 2>/dev/null || true
    fi

    if [[ -s "${skip_file}" ]]; then
      rm -f "${skip_file}"
      echo
      echo "Stopped waiting locally. The GitHub Actions run will continue on GitHub."
      return 0
    fi
    rm -f "${skip_file}"

    if [[ "${watcher_status}" -eq 0 ]]; then
      echo "Release DMG workflow completed successfully."
    else
      echo "Release DMG workflow finished with status ${watcher_status}." >&2
    fi
    return "${watcher_status}"
  fi

  echo "Watching Release DMG workflow run ${run_id}..."
  set +e
  gh run watch "${run_id}" --exit-status
  watcher_status=$?
  set -e

  if [[ "${watcher_status}" -eq 0 ]]; then
    echo "Release DMG workflow completed successfully."
  else
    echo "Release DMG workflow finished with status ${watcher_status}." >&2
  fi
  return "${watcher_status}"
}

sync_current_branch() {
  local current_branch="$1"
  local remote_ref="origin/${current_branch}"
  local local_head remote_head base

  echo "Fetching origin/${current_branch}..."
  git fetch origin "${current_branch}"

  if ! git show-ref --verify --quiet "refs/remotes/${remote_ref}"; then
    echo "No ${remote_ref} ref found; continuing without a pre-release fast-forward."
    return 0
  fi

  local_head="$(git rev-parse HEAD)"
  remote_head="$(git rev-parse "${remote_ref}")"
  base="$(git merge-base HEAD "${remote_ref}")"

  if [[ "${local_head}" == "${remote_head}" ]]; then
    return 0
  fi

  if [[ "${base}" == "${local_head}" ]]; then
    echo "Fast-forwarding ${current_branch} to ${remote_ref}..."
    git merge --ff-only "${remote_ref}"
    return 0
  fi

  if [[ "${base}" == "${remote_head}" ]]; then
    return 0
  fi

  echo "${current_branch} has diverged from ${remote_ref}; merging ${remote_ref} before release bump..."
  git merge --no-edit "${remote_ref}"
}

for arg in "$@"; do
  case "$arg" in
    --patch)
      bump_kind="patch"
      ;;
    --minor)
      bump_kind="minor"
      ;;
    --major)
      bump_kind="major"
      ;;
    --dry-run)
      dry_run=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cd "${repo_root}"

dirty_state="$(git status --porcelain)"
dirty_handling_summary="clean worktree required"
if [[ -n "${dirty_state}" ]]; then
  dirty_handling_summary="dirty worktree: release would stop until the tree is clean"
fi

if [[ -n "${dirty_state}" && "${dry_run}" -eq 0 ]]; then
  cat >&2 <<'EOF'
release.sh requires a clean worktree, including untracked files.

Commit, stash, or remove local changes before running a release.
EOF
  exit 1
fi

current_branch="$(git branch --show-current)"
if [[ -z "${current_branch}" ]]; then
  echo "release.sh requires a named branch, not detached HEAD." >&2
  exit 1
fi

if [[ "${current_branch}" == "release" ]]; then
  echo "release.sh is intended to run from a working branch such as main, not from release itself." >&2
  exit 1
fi

if [[ "${dry_run}" -eq 0 ]]; then
  sync_current_branch "${current_branch}"
fi

current_version="$(./scripts/read_version.sh)"
next_version="$(./scripts/bump_version.sh "${bump_kind}" --print-only)"

if [[ "${dry_run}" -eq 1 ]]; then
  cat <<EOF
Current branch: ${current_branch}
Current version: ${current_version}
Next version: ${next_version}
Dirty tree handling: ${dirty_handling_summary}
Release workflow wait: enabled

Would run:
  git fetch origin ${current_branch}
  git merge origin/${current_branch} # when origin has CI tap updates
  ./scripts/bump_version.sh ${bump_kind}
  git add VERSION
  git commit -m "Bump version to ${next_version}"
  git push origin ${current_branch}
  git push origin HEAD:release
  gh run list --workflow "Release DMG" --branch release --commit <release-sha>
  gh run watch <run-id> --exit-status
  allow Enter at any time to stop waiting locally
EOF
  exit 0
fi

./scripts/bump_version.sh "${bump_kind}" >/dev/null

git add VERSION
git commit -m "Bump version to ${next_version}"
git push origin "${current_branch}"
git push origin HEAD:release

release_sha="$(git rev-parse HEAD)"
maybe_wait_for_release "${release_sha}"

cat <<EOF
Released ${next_version} from ${current_branch}.
Pushed ${current_branch} and updated origin/release to the same commit.
EOF
