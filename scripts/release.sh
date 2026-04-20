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
4. pushes the same HEAD commit to origin/release.

Hard policy:
- releases require a clean worktree, including untracked files
- --dry-run reports the stop condition without mutating anything
EOF
}

bump_kind="patch"
dry_run=0

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

current_version="$(./scripts/read_version.sh)"
next_version="$(./scripts/bump_version.sh "${bump_kind}" --print-only)"

if [[ "${dry_run}" -eq 1 ]]; then
  cat <<EOF
Current branch: ${current_branch}
Current version: ${current_version}
Next version: ${next_version}
Dirty tree handling: ${dirty_handling_summary}

Would run:
  ./scripts/bump_version.sh ${bump_kind}
  git add VERSION
  git commit -m "Bump version to ${next_version}"
  git push origin ${current_branch}
  git push origin HEAD:release
EOF
  exit 0
fi

./scripts/bump_version.sh "${bump_kind}" >/dev/null

git add VERSION
git commit -m "Bump version to ${next_version}"
git push origin "${current_branch}"
git push origin HEAD:release

cat <<EOF
Released ${next_version} from ${current_branch}.
Pushed ${current_branch} and updated origin/release to the same commit.
EOF
