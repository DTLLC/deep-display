cask "deep-display" do
  version "0.2.4,4"
  sha256 "598cf4218f1ae64372f92aac9155eaa1b63ea8af9529f7bfdbbcd847878a19b7"

  github_token = ENV["HOMEBREW_GITHUB_API_TOKEN"]
  github_token ||= `gh auth token 2>/dev/null`.strip if system("command -v gh >/dev/null 2>&1")
  github_token = nil if github_token&.empty?

  url "https://github.com/JasCodes/deepdisplay/releases/download/v#{version.before_comma}-build.#{version.after_comma}/Deep-Display-latest.dmg",
      verified: "github.com/JasCodes/deepdisplay/",
      header: github_token ? ["Authorization: Bearer #{github_token}"] : []
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
