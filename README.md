# wrike-gateway

A Swift SDK and three capability-scoped command line tools for Wrike API v4.

The public contract is a project-owned GraphQL-shaped schema. Wrike REST paths,
query parameters, and response envelopes are transport details that never reach
a caller. There is no raw REST, arbitrary URL, or arbitrary GraphQL passthrough.

## Install

Homebrew (macOS, Apple Silicon and Intel):

```bash
brew tap tacogips/tap
brew install wrike-gateway
```

One formula installs all three executables: `wrike-gateway-reader`,
`wrike-gateway-writer`, and `wrike-gateway-admin`. Verify with:

```bash
wrike-gateway-reader --version
```

From source instead:

```bash
git clone https://github.com/tacogips/wrike-gateway.git
cd wrike-gateway
swift build -c release
```

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
mise install
mise run build
mise run test
mise run lint
swift run wrike-gateway-reader --help
swift run wrike-gateway-reader graphql schema
```

### End-to-end scenarios

The normal `mise run test` suite includes the replay E2E runner. It executes the
shared scenario catalog through a loopback HTTP server with sanitized canned
responses, requires no Wrike credential, and never changes a Wrike account.
The live E2E suite is disabled unless `WRIKE_GATEWAY_LIVE_E2E=1` and both
permanent-token variables are present.

Run only the read and boundary scenarios, which create, update, and delete
nothing:

```bash
kinko exec --force \
  --env WRIKE_GATEWAY_ACCESS_TOKEN,WRIKE_GATEWAY_API_BASE_URL -- \
  mise run test:live:read
```

Run the full live catalog, including the mutation lifecycle:

```bash
kinko exec --force \
  --env WRIKE_GATEWAY_ACCESS_TOKEN,WRIKE_GATEWAY_API_BASE_URL -- \
  mise run test:live
```

The full live suite is destructive by design but bounded: it creates one dedicated
folder named `wrike-gateway verification` under the account root, creates a
task, comment, optional timelog, and attachment only inside that folder,
verifies ownership before each delete, and removes the created objects and
container. It never creates a webhook. A plan- or scope-blocked operation is a
valid live result and is not replaced with a broader operation.

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

### Attachment content

Two reader fields write a file instead of returning data:

```bash
wrike-gateway-reader graphql query \
  'query { attachmentDownload(id: "IEAAAAAAIYAAAAAB", destination: "/tmp/brief.pdf")
           { path byteCount contentType } }'
```

The destination must not already exist: a download never replaces a local file,
and an upstream failure writes nothing at all. The result describes the written
file; attachment content never appears in the JSON envelope, an error message,
or a log line. `attachmentPreview` takes the same arguments plus an optional
`size` from the curated set `w44`, `w100`, `w200`, `w300`, `w400`, `h400`.
`attachmentDownloadUrl` remains available when a time-limited URL is wanted
instead of a transfer.

A transfer is either complete or absent. A body that disagrees with the
`Content-Length` the response declared is refused as `TRANSPORT_FAILED`, and a
body-less success on either route is refused as `UPSTREAM_RESPONSE_INVALID`
rather than written as a zero-byte file; neither leaves a partial file behind.
Not every attachment type has a preview, and Wrike refuses a preview-less type
the same way it refuses a missing attachment, so `attachmentPreview` names that
cause in the error's `recovery` guidance.

## Credentials

Exactly five environment variables are read:

| Variable | Purpose |
| --- | --- |
| `WRIKE_GATEWAY_API_CLIENT_ID` | OAuth2 client id, exported by kinko |
| `WRIKE_GATEWAY_API_CLIENT_SECRET` | OAuth2 client secret, exported by kinko |
| `WRIKE_GATEWAY_ACCESS_TOKEN` | permanent bearer-token alternative |
| `WRIKE_GATEWAY_API_BASE_URL` | required data-center API base URL in permanent-token mode |
| `WRIKE_GATEWAY_OAUTH_CALLBACK_PORT` | optional OAuth callback port; defaults to `8765` |

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

`auth oauth2` redirects to `http://localhost:<port>/callback` and runs a
loopback callback service on that port for the duration of one login. The port
defaults to `8765` and is set with `WRIKE_GATEWAY_OAUTH_CALLBACK_PORT`, so the
redirect URI can match the one registered for your Wrike application:

```bash
WRIKE_GATEWAY_OAUTH_CALLBACK_PORT=49152 wrike-gateway-reader auth oauth2
```

Wrike matches registered redirect URIs exactly, so register the same port and
path the CLI will use. The scheme, host, and path are fixed, and an invalid
port fails before the login starts.

The callback is plain HTTP on the loopback interface, per RFC 8252 section 7.3:
a native application cannot hold a certificate a browser will trust for
`localhost`. The socket binds loopback only, so the authorization code never
leaves the machine. No certificate, no Keychain entry, and no trust change is
required. There is no redirect-URI, host, or path override.

## Homebrew Formula

Build local formula archives:

```bash
mise run build:homebrew -- darwin-arm64 darwin-x64
```

Render a formula after both platform archives exist:

```bash
mise run homebrew:formula -- 0.1.0
```

Render directly into the default sibling tap checkout:

```bash
mise run homebrew:tap-formula -- 0.1.0
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
mise run build:homebrew-cask -- --dry-run darwin-arm64 darwin-x64
```

Build with local signing credentials:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run build:homebrew-cask -- darwin-arm64 darwin-x64
```

Render a Cask:

```bash
mise run homebrew:cask -- 0.1.0
```

For a tagged release, build, upload, and render the tap Cask:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run release:homebrew-cask-local -- v0.1.0
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.
