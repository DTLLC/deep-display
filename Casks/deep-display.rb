cask "deep-display" do
  version "0.2.8,7"
  sha256 "de7be3dc7423675a6b5395f7d6cce1390d0ee6227fa2b7a34d21acfa18015399"

  url "https://github.com/dtllc/deep-display/releases/download/v#{version.before_comma}-build.#{version.after_comma}/Deep-Display-latest.dmg",
      verified: "github.com/dtllc/deep-display/"
  name "Deep Display"
  desc "Switch display modes, range, and virtual resolutions on macOS"
  homepage "https://github.com/dtllc/deep-display"

  livecheck do
    url "https://github.com/dtllc/deep-display/releases"
    regex(/^v?(\d+(?:\.\d+)+)-build[._-]?(\d+)$/i)
    strategy :github_latest do |json, regex|
      match = json["tag_name"]&.match(regex)
      next if match.nil?

      "#{match[1]},#{match[2]}"
    end
  end

  app "Deep Display.app"
end
