#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

display_name="Deep Display"
marketing_version="${DEEPDISPLAY_MARKETING_VERSION:-$("${script_dir}/read_version.sh")}"
build_version="${DEEPDISPLAY_BUILD_VERSION:-$("${script_dir}/read_build_version.sh")}"
dist_dir="${repo_root}/.dist"
artifact_basename="Deep-Display-${marketing_version}+${build_version}"
dmg_dir="${dist_dir}/dmg"
dmg_path="${dist_dir}/${artifact_basename}.dmg"

app_bundle="$("${script_dir}/build_app.sh" | tail -n 1)"

rm -rf "${dmg_dir}" "${dmg_path}"
mkdir -p "${dmg_dir}"
/usr/bin/ditto "${app_bundle}" "${dmg_dir}/${display_name}.app"
ln -sfn /Applications "${dmg_dir}/Applications"

/usr/bin/hdiutil create \
  -volname "${display_name}" \
  -srcfolder "${dmg_dir}" \
  -ov \
  -format UDZO \
  "${dmg_path}"

printf '%s\n' "${dmg_path}"
