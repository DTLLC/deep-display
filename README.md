# Deep Display

Deep Display is an open source macOS app for switching display modes, range, and virtual resolutions.

Release builds are signed with a Developer ID certificate, notarized by Apple, and distributed as GitHub release DMGs. Homebrew cask metadata lives in the public `DTLLC/homebrew-tap` repository.

## Homebrew tap

Install from the shared DeepTech Solutions Homebrew tap:

```bash
brew install --cask dtllc/tap/deep-display
```

Or tap once and install by cask token:

```bash
brew tap dtllc/tap
brew install --cask deep-display
```

To upgrade later:

```bash
brew upgrade --cask deep-display
```

## Releases

Push to the `release` branch to build, sign, notarize, and publish the DMG through GitHub Actions. Each release uploads:

- a versioned DMG such as `Deep-Display-0.2.2+23.dmg`
- a `Deep-Display-latest.dmg` asset under the concrete release tag used by the Homebrew cask

The release workflow also prunes older patch releases so only the latest patch in each `major.minor` line remains.
After the DMG is published, the workflow dispatches the release URL, version, build number, and SHA-256 digest to `DTLLC/homebrew-tap`, where the cask is created or updated.

The release workflow expects these GitHub Actions organization secrets:

```text
APPLE_APP_STORE_CONNECT_KEY_ID
APPLE_APP_STORE_CONNECT_ISSUER_ID
APPLE_APP_STORE_CONNECT_PRIVATE_KEY_BASE64
APPLE_MAC_DEVELOPER_ID_CERT_PRIVATE_KEY
HOMEBREW_TAP_DISPATCH_TOKEN
```

`APPLE_MAC_DEVELOPER_ID_CERT_PRIVATE_KEY` is the shared certificate private key used by Codemagic CLI tools to fetch or create the Developer ID Application signing certificate. The workflow maps it to Codemagic's expected `CERTIFICATE_PRIVATE_KEY` environment variable and creates a temporary keychain password at runtime.

`HOMEBREW_TAP_DISPATCH_TOKEN` is a fine-grained GitHub token scoped to `DTLLC/homebrew-tap` with `Contents: Read and write` and `Metadata: Read`. It is used only to send the `update-cask` repository dispatch event.

## Local build

```bash
swift build -c release
make dmg
```

## License

Deep Display is available under the MIT License. See `LICENSE` for details.
