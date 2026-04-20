#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

display_name="Deep Display"
product_name="DeepDisplay"
bundle_id="bio.jas.DeepDisplay"
minimum_system_version="14.0"

marketing_version="${DEEPDISPLAY_MARKETING_VERSION:-$("${script_dir}/read_version.sh")}"
build_version="${DEEPDISPLAY_BUILD_VERSION:-$("${script_dir}/read_build_version.sh")}"
dist_dir="${repo_root}/.dist"
build_dir="${repo_root}/.build/release"
app_bundle="${dist_dir}/${display_name}.app"
app_contents="${app_bundle}/Contents"
app_macos="${app_contents}/MacOS"
app_resources="${app_contents}/Resources"
app_binary="${app_macos}/${product_name}"
info_plist="${app_contents}/Info.plist"
iconset_dir="${dist_dir}/AppIcon.iconset"
icns_path="${app_resources}/${display_name}.icns"

swift build -c release

rm -rf "${app_bundle}" "${iconset_dir}"
mkdir -p "${app_macos}" "${app_resources}"

cp "${build_dir}/${product_name}" "${app_binary}"
chmod +x "${app_binary}"

"${script_dir}/render_icon.swift" "${iconset_dir}"
/usr/bin/iconutil -c icns "${iconset_dir}" -o "${icns_path}"

cat > "${info_plist}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${display_name}</string>
  <key>CFBundleExecutable</key>
  <string>${product_name}</string>
  <key>CFBundleIconFile</key>
  <string>${display_name}</string>
  <key>CFBundleIdentifier</key>
  <string>${bundle_id}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${display_name}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${marketing_version}</string>
  <key>CFBundleSpokenName</key>
  <string>${display_name}</string>
  <key>CFBundleVersion</key>
  <string>${build_version}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${minimum_system_version}</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

printf '%s\n' "${app_bundle}"

