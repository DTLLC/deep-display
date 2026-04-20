cask "deep-display" do
  version :latest
  sha256 :no_check

  github_token = ENV["HOMEBREW_GITHUB_API_TOKEN"]

  url "https://github.com/JasCodes/deepdisplay/releases/latest/download/Deep-Display-latest.dmg",
      verified: "github.com/JasCodes/deepdisplay/",
      header: github_token ? ["Authorization: Bearer #{github_token}"] : []
  name "Deep Display"
  desc "Switch display modes, range, and virtual resolutions on macOS"
  homepage "https://github.com/JasCodes/deepdisplay"

  livecheck do
    skip "Uses the latest private release asset."
  end

  app "Deep Display.app"

  caveats do
    <<~EOS
      This cask downloads a private GitHub release asset.

      Set HOMEBREW_GITHUB_API_TOKEN to a GitHub token with read access to
      JasCodes/deepdisplay before installing or upgrading:

        export HOMEBREW_GITHUB_API_TOKEN=YOUR_TOKEN
        brew install --cask JasCodes/deepdisplay/deep-display
    EOS
  end
end
