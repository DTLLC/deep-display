#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

if [[ -n "${DEEPDISPLAY_BUILD_VERSION:-}" ]]; then
  printf '%s\n' "${DEEPDISPLAY_BUILD_VERSION}"
  exit 0
fi

if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
  printf '%s\n' "${GITHUB_RUN_NUMBER}"
  exit 0
fi

revision_count="$(git -C "${repo_root}" rev-list --count HEAD)"
printf '%s\n' "$((revision_count + 1))"

