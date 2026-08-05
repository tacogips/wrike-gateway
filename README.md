# wrike-gateway

A Swift SDK and three capability-scoped command line tools for Wrike API v4.

The public contract is a project-owned GraphQL-shaped schema. Wrike REST paths,
query parameters, and response envelopes are transport details that never reach
a caller. There is no raw REST, arbitrary URL, or arbitrary GraphQL passthrough.

## Capability Tiers

Capabilities are separated at SwiftPM link boundaries, not only at runtime.

| Executable | Linked modules | Public schema |
| --- | --- | --- |
| `wrike-gateway-reader` | `WrikeGatewayCore`, `WrikeGatewayRead` | Query only |
| `wrike-gateway-writer` | reader plus `WrikeGatewayWrite` | Query plus create/update Mutation |
| `wrike-gateway-admin` | writer plus `WrikeGatewayAdmin` | Query plus create/update and reviewed delete Mutation |

The reader binary does not link `WrikeGatewayWrite` or `WrikeGatewayAdmin`, and
the writer binary does not link `WrikeGatewayAdmin`. `Tests/WrikeGatewayCLITests`
proves this by inspecting the linked symbols of the built executables.

## Development

```bash
nix develop
task build
task test
task lint
swift run wrike-gateway-reader --help
swift run wrike-gateway-reader graphql schema
```

SwiftPM products:

- Libraries: `WrikeGatewayCore`, `WrikeGatewayRead`, `WrikeGatewayWrite`,
  `WrikeGatewayAdmin`. Products are cumulative; SDK consumers import the core
  module plus every capability module their selected product includes.
- Executables: `wrike-gateway-reader`, `wrike-gateway-writer`,
  `wrike-gateway-admin`.

## Usage

```bash
wrike-gateway-reader graphql query \
  'query { task(id: "IEAAAAAAKQAB5FNY") { id title status } }'

wrike-gateway-reader [--pretty] graphql query-file <path> [--variables-file <path>]
wrike-gateway-reader graphql schema
wrike-gateway-reader auth oauth2 | auth status | auth logout
```

JSON business output goes to stdout; usage diagnostics go to stderr. Exit codes
are `0` success, `2` usage or local validation, `3` credential, `4` rejected
request or not found, `5` rate limit or transient upstream, `6` local file or
credential store, `70` unexpected internal failure.

## Credentials

Exactly four environment variables are read:

| Variable | Purpose |
| --- | --- |
| `WRIKE_GATEWAY_API_CLIENT_ID` | OAuth2 client id, exported by kinko |
| `WRIKE_GATEWAY_API_CLIENT_SECRET` | OAuth2 client secret, exported by kinko |
| `WRIKE_GATEWAY_ACCESS_TOKEN` | permanent bearer-token alternative |
| `WRIKE_GATEWAY_API_BASE_URL` | required data-center API base URL in permanent-token mode |

A permanent token takes precedence for the process and requires a validated
`WRIKE_GATEWAY_API_BASE_URL`; there is no host default and no token-based
account discovery. OAuth2 tokens are stored through kinko's protected storage
with no plaintext fallback. No command line flag accepts a token or secret.

The credential store shells out to `kinko`, resolved from `PATH` and then from
`/opt/homebrew/bin/kinko` and `/usr/local/bin/kinko`. The record is written to
the `default` profile of the home-directory path scope, so the same token is
visible wherever the binary runs, and the record body is passed on stdin rather
than on the command line. The vault must be unlocked (`kinko unlock`) before an
OAuth2 credential can be read or written; a locked vault is reported as a locked
credential store rather than as a missing credential.

`auth oauth2` uses the fixed redirect `https://localhost:8765/callback` and
requires one valid, trusted certificate/private-key identity in the current
user's macOS login Keychain under the label `wrike-gateway.oauth.localhost`.
The operator provisions that identity; the CLI never generates, imports, or
trusts certificates, and it fails before binding a listener or opening a browser
when the identity is missing or invalid. There is no redirect-URI, identity
label, certificate, or trust-bypass override.

## Homebrew Formula

Build local formula archives:

```bash
task build:homebrew -- darwin-arm64 darwin-x64
```

Render a formula after both platform archives exist:

```bash
task homebrew:formula -- 0.1.0
```

Render directly into the default sibling tap checkout:

```bash
task homebrew:tap-formula -- 0.1.0
```

Install from the tap after the formula is published:

```bash
brew tap user/tap
brew install wrike-gateway
```

## Homebrew Cask

The Cask workflow builds signed, notarized, and stapled macOS DMG artifacts.
Apple signing credentials must stay local and must not be committed.

Check the build plan:

```bash
task build:homebrew-cask -- --dry-run darwin-arm64 darwin-x64
```

Build with local signing credentials:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task build:homebrew-cask -- darwin-arm64 darwin-x64
```

Render a Cask:

```bash
task homebrew:cask -- 0.1.0
```

For a tagged release, build, upload, and render the tap Cask:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task release:homebrew-cask-local -- v0.1.0
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.
