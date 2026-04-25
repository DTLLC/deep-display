cask "deep-display" do
  version "0.2.6,5"
  sha256 "0d491a3ff7410daae01881880dab019876abd202f2c97a93eaa89714fd16f357"

  gh_binary = ENV["GH"]
  gh_binary ||= `/bin/zsh -lc 'command -v gh' 2>/dev/null`.strip
  gh_binary ||= `/bin/bash -lc 'command -v gh' 2>/dev/null`.strip
  gh_binary = nil if gh_binary&.empty?

  github_token = ENV["HOMEBREW_GITHUB_API_TOKEN"]
  github_token ||= `"#{gh_binary}" auth token 2>/dev/null`.strip if gh_binary
  github_token = nil if github_token&.empty?
  raise "Run `gh auth login` before installing this private cask." if github_token.nil?

  ENV["GH_TOKEN"] ||= github_token
  release_tag = "v#{version.before_comma}-build.#{version.after_comma}"
  asset_api_url = `"#{gh_binary}" api repos/JasCodes/deepdisplay/releases/tags/#{release_tag} --jq '.assets[] | select(.name == "Deep-Display-latest.dmg") | .url' 2>/dev/null`.strip if gh_binary
  raise "Could not find Deep-Display-latest.dmg on #{release_tag}." if asset_api_url.empty?

  url asset_api_url,
      verified: "github.com/JasCodes/deepdisplay/",
      header: [
        "Accept: application/octet-stream",
        "Authorization: Bearer #{github_token}",
      ]
  name "Deep Display"
  desc "Switch display modes, range, and virtual resolutions on macOS"
  homepage "https://github.com/JasCodes/deepdisplay"

  livecheck do
    skip "Private release asset."
  end

  app "Deep Display.app"

  caveats do
    <<~EOS
      This cask downloads a private GitHub release asset.

      Authenticate GitHub CLI before installing or upgrading:

        gh auth login
        brew tap JasCodes/deepdisplay https://github.com/JasCodes/deepdisplay
        brew install --cask deep-display

      You can also set HOMEBREW_GITHUB_API_TOKEN directly if you prefer.
    EOS
  end
end
