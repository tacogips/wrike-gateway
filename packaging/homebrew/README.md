# Homebrew Packaging

This project ships two Homebrew release paths:

- Formula: unsigned tarballs containing `bin/wrike-gateway`.
- Cask: signed, notarized, and stapled macOS DMGs containing the command line tool.

Swift formula archives are macOS-only by default. Add Linux archives only after
the project has a reviewed Swift Linux build and runtime contract.

## Formula

Build release archives:

```bash
scripts/build-homebrew-release.sh darwin-arm64 darwin-x64
```

The command writes archives and checksums under `dist/homebrew/`:

```text
dist/homebrew/wrike-gateway-<version>-darwin-arm64.tar.gz
dist/homebrew/wrike-gateway-<version>-darwin-arm64.tar.gz.sha256
dist/homebrew/wrike-gateway-<version>-darwin-x64.tar.gz
dist/homebrew/wrike-gateway-<version>-darwin-x64.tar.gz.sha256
```

Publish those assets to the GitHub release named `v<version>`, then render the
formula into a tap checkout:

```bash
scripts/render-homebrew-formula.sh <version> ../homebrew-tap/Formula/wrike-gateway.rb
```

## Cask

Build signed and notarized DMGs on macOS:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  scripts/build-homebrew-cask-release.sh darwin-arm64 darwin-x64
```

This writes:

```text
dist/homebrew-cask/wrike-gateway-<version>-darwin-arm64.dmg
dist/homebrew-cask/wrike-gateway-<version>-darwin-arm64.dmg.sha256
dist/homebrew-cask/wrike-gateway-<version>-darwin-x64.dmg
dist/homebrew-cask/wrike-gateway-<version>-darwin-x64.dmg.sha256
```

Render the Cask:

```bash
scripts/render-homebrew-cask.sh <version> ../homebrew-tap/Casks/wrike-gateway.rb
```

For a tagged release, the local wrapper verifies the tag, builds DMGs, uploads
release assets, and renders the tap Cask:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  scripts/release-homebrew-cask-local.sh v<version>
```

## Verification

From the tap checkout:

```bash
ruby -c Formula/wrike-gateway.rb
brew audit --strict wrike-gateway || brew audit --strict --formula wrike-gateway
brew fetch --cask user/tap/wrike-gateway
HOMEBREW_NO_GITHUB_API=1 brew audit --cask user/tap/wrike-gateway
```

If online audit fails due local GitHub credentials or rate limits, run the
non-online audit and record the limitation.
