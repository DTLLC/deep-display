# Deep Display

Deep Display is an open source macOS app for switching display modes, range, and virtual resolutions.

Release builds are signed with a Developer ID certificate, notarized by Apple, and distributed from this repository as a Homebrew cask and a GitHub release DMG.

## Homebrew tap

This repository is its own tap. Install from it directly:

```bash
brew tap dtllc/deep-display https://github.com/dtllc/deep-display
brew install --cask deep-display
```

Use the explicit tap URL because this repository is not named `homebrew-deep-display`. The shorthand `brew install --cask dtllc/deep-display/deep-display` would only work for a conventional Homebrew tap repository.

To upgrade later:

```bash
brew upgrade --cask deep-display
```

## Releases

Push to the `release` branch to build, sign, notarize, and publish the DMG through GitHub Actions. Each release uploads:

- a versioned DMG such as `Deep-Display-0.2.2+23.dmg`
- a `Deep-Display-latest.dmg` asset under the concrete release tag used by the Homebrew cask

The release workflow also prunes older patch releases so only the latest patch in each `major.minor` line remains.
After the DMG is published, the workflow updates `Casks/deep-display.rb` on `main` with the new build number and SHA-256 digest.

The release workflow expects these GitHub Actions organization secrets:

```text
APPLE_APP_STORE_CONNECT_KEY_ID
APPLE_APP_STORE_CONNECT_ISSUER_ID
APPLE_APP_STORE_CONNECT_PRIVATE_KEY_BASE64
APPLE_CERTIFICATE_PRIVATE_KEY
```

`APPLE_CERTIFICATE_PRIVATE_KEY` is the shared certificate private key used by Codemagic CLI tools to fetch or create the Developer ID Application signing certificate. The workflow creates a temporary keychain password at runtime.

## Local build

```bash
swift build -c release
make dmg
```

## License

Deep Display is available under the MIT License. See `LICENSE` for details.
