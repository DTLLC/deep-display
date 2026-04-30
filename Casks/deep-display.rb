cask "deep-display" do
  version "0.2.11,10"
  sha256 "2ce5f12a42933e0b17acd57415dbe5538f2b9d36b11e6ac82c36d1e1ee36bd93"

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
