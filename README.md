# Deep Display

Deep Display is distributed from this repository as a Homebrew cask and a GitHub release DMG.

## Homebrew tap

This repository is its own tap. Install from it directly:

```bash
export HOMEBREW_GITHUB_API_TOKEN=YOUR_TOKEN
brew install --cask JasCodes/deepdisplay/deep-display
```

The token is required because the DMG is served from a private GitHub release asset.

To upgrade later:

```bash
export HOMEBREW_GITHUB_API_TOKEN=YOUR_TOKEN
brew upgrade --cask JasCodes/deepdisplay/deep-display
```

## Releases

Push to the `release` branch to build and publish the DMG through GitHub Actions. Each release uploads:

- a versioned DMG such as `Deep-Display-0.2.2+23.dmg`
- a stable `Deep-Display-latest.dmg` asset used by the Homebrew cask

The release workflow also prunes older patch releases so only the latest patch in each `major.minor` line remains.
