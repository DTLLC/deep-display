# Deep Display

Deep Display is distributed from this repository as a Homebrew cask and a GitHub release DMG.

## Homebrew tap

This repository is its own tap. Install from it directly:

```bash
export HOMEBREW_GITHUB_API_TOKEN=YOUR_TOKEN
brew tap JasCodes/deepdisplay https://github.com/JasCodes/deepdisplay
brew install --cask deep-display
```

The token is required because the DMG is served from a private GitHub release asset.
If the repository itself is private, authenticate Git first or tap with an SSH URL instead:

```bash
brew tap JasCodes/deepdisplay git@github.com:JasCodes/deepdisplay.git
```

To upgrade later:

```bash
export HOMEBREW_GITHUB_API_TOKEN=YOUR_TOKEN
brew upgrade --cask deep-display
```

## Releases

Push to the `release` branch to build and publish the DMG through GitHub Actions. Each release uploads:

- a versioned DMG such as `Deep-Display-0.2.2+23.dmg`
- a `Deep-Display-latest.dmg` asset under the concrete release tag used by the Homebrew cask

The release workflow also prunes older patch releases so only the latest patch in each `major.minor` line remains.
After the DMG is published, the workflow updates `Casks/deep-display.rb` on `main` with the new build number and SHA-256 digest.
