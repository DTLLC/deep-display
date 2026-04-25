#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cask_path="${repo_root}/Casks/deep-display.rb"

usage() {
  cat <<'EOF'
usage: ./scripts/update_cask.sh <marketing-version> <build-version> <sha256>

Updates the Homebrew cask to point at the concrete release asset produced by CI.
EOF
}

if [[ $# -ne 3 ]]; then
  usage >&2
  exit 2
fi

marketing_version="$1"
build_version="$2"
sha256="$3"

if [[ ! "${marketing_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "marketing version must be semantic, got: ${marketing_version}" >&2
  exit 1
fi

if [[ ! "${build_version}" =~ ^[0-9]+$ ]]; then
  echo "build version must be numeric, got: ${build_version}" >&2
  exit 1
fi

if [[ ! "${sha256}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "sha256 must be a 64-character lowercase hex digest, got: ${sha256}" >&2
  exit 1
fi

ruby - "${cask_path}" "${marketing_version}" "${build_version}" "${sha256}" <<'RUBY'
path, marketing_version, build_version, sha256 = ARGV
text = File.read(path)
text = text.sub(/^  version ".*"$/, %(  version "#{marketing_version},#{build_version}"))
text = text.sub(/^  sha256 ".*"$/, %(  sha256 "#{sha256}"))
File.write(path, text)
RUBY

ruby -c "${cask_path}" >/dev/null
printf '%s,%s\n' "${marketing_version}" "${build_version}"
