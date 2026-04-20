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

temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

candidates_file="${temp_dir}/candidates.tsv"
sorted_file="${temp_dir}/sorted.tsv"
keep_file="${temp_dir}/keep.txt"
delete_file="${temp_dir}/delete.txt"

gh api "repos/${repo}/releases?per_page=100" --paginate \
  --jq '.[] | [.tag_name, .draft, .prerelease] | @tsv' |
while IFS=$'\t' read -r tag_name is_draft is_prerelease; do
  if [[ "${is_draft}" == "true" || "${is_prerelease}" == "true" ]]; then
    continue
  fi

  if [[ "${tag_name}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)-build\.([0-9]+)$ ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "${BASH_REMATCH[1]}" \
      "${BASH_REMATCH[2]}" \
      "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[4]}" \
      "${tag_name}" >> "${candidates_file}"
  fi
done

if [[ ! -f "${candidates_file}" ]]; then
  echo "No matching patch releases found."
  exit 0
fi

sort -t $'\t' -k1,1n -k2,2n -k3,3nr -k4,4nr "${candidates_file}" > "${sorted_file}"

last_line_key=""
while IFS=$'\t' read -r major minor patch build tag_name; do
  line_key="${major}.${minor}"
  if [[ "${line_key}" != "${last_line_key}" ]]; then
    printf '%s\t%s\n' "${line_key}" "${tag_name}" >> "${keep_file}"
    last_line_key="${line_key}"
  else
    printf '%s\n' "${tag_name}" >> "${delete_file}"
  fi
done < "${sorted_file}"

if [[ ! -f "${delete_file}" ]]; then
  echo "No older patch releases to delete."
  exit 0
fi

printf 'Keeping latest patch per minor line:\n'
sort "${keep_file}" | while IFS=$'\t' read -r line_key tag_name; do
  printf '  %s -> %s\n' "${line_key}" "${tag_name}"
done

printf 'Deleting old releases:\n'
while IFS= read -r tag_name; do
  printf '  %s\n' "${tag_name}"
done < "${delete_file}"

if [[ "${dry_run}" -eq 1 ]]; then
  exit 0
fi

while IFS= read -r tag_name; do
  gh release delete "${tag_name}" --cleanup-tag --yes --repo "${repo}"
done < "${delete_file}"
