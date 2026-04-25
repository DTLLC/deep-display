cask "deep-display" do
  version "0.2.3,3"
  sha256 "c57d2ebedb3ee6654062d080cd8d677ce2d10de7cbae9656dda2d90561d9ee0e"

  github_token = ENV["HOMEBREW_GITHUB_API_TOKEN"]

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

      Set HOMEBREW_GITHUB_API_TOKEN to a GitHub token with read access to
      JasCodes/deepdisplay before installing or upgrading:

        export HOMEBREW_GITHUB_API_TOKEN=YOUR_TOKEN
        brew tap JasCodes/deepdisplay https://github.com/JasCodes/deepdisplay
        brew install --cask deep-display
    EOS
  end
end
