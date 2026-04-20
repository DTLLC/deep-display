#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: ./scripts/cleanup_releases.sh [--repo owner/repo] [--dry-run]

Keep only the newest patch release for each major.minor line and delete older
patch releases and their tags.
EOF
}

repo="${GITHUB_REPOSITORY:-}"
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${repo}" ]]; then
  echo "cleanup_releases.sh requires --repo or GITHUB_REPOSITORY." >&2
  exit 1
fi

mapfile -t release_lines < <(
  gh api "repos/${repo}/releases?per_page=100" --paginate \
    --jq '.[] | [.tag_name, .draft, .prerelease] | @tsv'
)

declare -A keep_patch_by_line
declare -A keep_build_by_line
declare -A keep_tag_by_line
declare -a candidate_tags=()

for line in "${release_lines[@]}"; do
  IFS=$'\t' read -r tag_name is_draft is_prerelease <<< "${line}"

  if [[ "${is_draft}" == "true" || "${is_prerelease}" == "true" ]]; then
    continue
  fi

  if [[ "${tag_name}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)-build\.([0-9]+)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    build="${BASH_REMATCH[4]}"
    line_key="${major}.${minor}"
    candidate_tags+=("${tag_name}")

    current_keep_patch="${keep_patch_by_line[$line_key]:--1}"
    current_keep_build="${keep_build_by_line[$line_key]:--1}"
    if (( patch > current_keep_patch )) || { (( patch == current_keep_patch )) && (( build > current_keep_build )); }; then
      keep_patch_by_line["${line_key}"]="${patch}"
      keep_build_by_line["${line_key}"]="${build}"
      keep_tag_by_line["${line_key}"]="${tag_name}"
    fi
  fi
done

declare -a delete_tags=()
for tag_name in "${candidate_tags[@]}"; do
  if [[ "${tag_name}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)-build\.([0-9]+)$ ]]; then
    line_key="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    if [[ "${keep_tag_by_line[$line_key]}" != "${tag_name}" ]]; then
      delete_tags+=("${tag_name}")
    fi
  fi
done

if [[ "${#delete_tags[@]}" -eq 0 ]]; then
  echo "No older patch releases to delete."
  exit 0
fi

printf 'Keeping latest patch per minor line:\n'
for line_key in "${!keep_tag_by_line[@]}"; do
  printf '  %s -> %s\n' "${line_key}" "${keep_tag_by_line[$line_key]}"
done | sort

printf 'Deleting old releases:\n'
printf '  %s\n' "${delete_tags[@]}"

if [[ "${dry_run}" -eq 1 ]]; then
  exit 0
fi

for tag_name in "${delete_tags[@]}"; do
  gh release delete "${tag_name}" --cleanup-tag --yes --repo "${repo}"
done

