#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

usage() {
  cat <<'EOF'
usage: ./scripts/bump_version.sh [patch|minor|major] [--print-only]

Defaults to patch and updates VERSION in place unless --print-only is passed.
EOF
}

bump_kind="patch"
print_only=0

for arg in "$@"; do
  case "$arg" in
    patch|minor|major)
      bump_kind="$arg"
      ;;
    --print-only)
      print_only=1
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

current_version="$(tr -d '[:space:]' < "${repo_root}/VERSION")"
IFS='.' read -r major minor patch <<< "${current_version}"

if [[ -z "${major:-}" || -z "${minor:-}" || -z "${patch:-}" ]]; then
  echo "VERSION must be in semantic version format, got: ${current_version}" >&2
  exit 1
fi

case "$bump_kind" in
  patch)
    patch=$((patch + 1))
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  major)
    major=$((major + 1))
    minor=0
    patch=0
    ;;
esac

next_version="${major}.${minor}.${patch}"

if [[ "$print_only" -eq 1 ]]; then
  printf '%s\n' "${next_version}"
  exit 0
fi

printf '%s\n' "${next_version}" > "${repo_root}/VERSION"
printf '%s\n' "${next_version}"

