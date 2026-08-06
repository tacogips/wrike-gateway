# Authentication and Credential Handling Design

## Status

Implemented. Credential modes, resolution precedence, the OAuth2 flow, the
HTTP loopback callback boundary, refresh handling, and redaction rules described
below are in place and covered by tests.

Credential storage is implemented, its command contract is pinned against the
verified `kinko` 0.1.8 interface (argv, stdin, scope flags, and exit-code
handling for load, replace, delete, and existence checks), and an opt-in test
replays that exact argv through the installed binary. `load`, `replace`,
`delete`, and the existence check are additionally round-tripped against a real
unlocked vault by `KinkoRoundTripTests` (opt in with
`WRIKE_GATEWAY_KINKO_ROUNDTRIP=1`), which writes a synthetic record into a
disposable vault and asserts that a stored record decodes to what was written,
that a rotation overwrites in place, and that a repeated delete reports the
no-op. What remains unexercised is the live Wrike side of the flow: no
authorization code has been exchanged with, and no refresh token rotated
against, the real `login.wrike.com` endpoint, because that needs an operator
browser session and a registered OAuth application.

## Credential Modes

`wrike-gateway` supports two mutually exclusive bearer-token sources:

1. OAuth2 authorization code plus rotating refresh token, recommended for
   multi-user and production use; or
2. a permanent access token from `WRIKE_GATEWAY_ACCESS_TOKEN`, intended for
   individual integrations and testing.

The same credential resolver is used by the Swift SDK and all three
executables. Capability tiers limit linked code; they do not elevate the
permissions of a Wrike token or bypass Wrike scopes.

## Environment Variables

| Variable | Purpose | Secret |
| --- | --- | --- |
| `WRIKE_GATEWAY_API_CLIENT_ID` | OAuth2 application client id, exported by kinko | sensitive identifier; redact by default |
| `WRIKE_GATEWAY_API_CLIENT_SECRET` | OAuth2 application client secret, exported by kinko | yes |
| `WRIKE_GATEWAY_ACCESS_TOKEN` | permanent bearer-token alternative | yes |
| `WRIKE_GATEWAY_API_BASE_URL` | required data-center API base URL for permanent-token mode | no, but validate host |
| `WRIKE_GATEWAY_OAUTH_CALLBACK_PORT` | loopback port the OAuth callback service binds; defaults to `8765` | no |

OAuth access tokens, refresh tokens, expiry, scopes, and resolved host are
credential-store records, not general environment variables. They are never
written to a repository `.env` file.

## Resolution Precedence

1. If `WRIKE_GATEWAY_ACCESS_TOKEN` is non-empty, use permanent-token mode and
   require a non-empty, validated `WRIKE_GATEWAY_API_BASE_URL`.
2. Otherwise, load OAuth token state from the credential store.
3. If the OAuth access token is near expiry and refresh state is available,
   refresh before the API request.
4. If no usable state exists, return `AUTHENTICATION_FAILED` with safe login
   guidance.

Setting a permanent token together with OAuth client variables is allowed;
the permanent token wins for that process and `auth status` reports the
selected mode without reading token values. CLI flags never accept a token or
client secret because command lines may be visible to other processes.

Permanent-token mode has no implicit `www.wrike.com` or other host default and
does not attempt account discovery with the bearer token. The configured URL
must be an HTTPS Wrike API base URL for the account's data center, include the
`/api/v4` path, contain no user information, query, or fragment, and pass the
approved-host policy. A missing or invalid base URL fails locally with
`AUTHENTICATION_FAILED` before any request or redirect can carry the token.

## OAuth2 Authorization Code Flow

1. Read the kinko-provisioned client id and secret.
2. Generate and retain an unguessable state value for the pending flow.
3. Start the loopback callback listener on the configured port.
4. Open the Wrike authorization URL through the operating-system browser API
   without emitting the URL to stdout, stderr, or logs.
5. Reject callbacks with mismatched state, unexpected path/host, missing code,
   OAuth error, or elapsed timeout.
6. Exchange the one-time code at the approved Wrike token endpoint.
7. Persist access token, refresh token, expiry, granted scopes, and the
   data-center host atomically through the credential store.
8. Clear transient code and state values from memory as soon as practical.

The redirect is `http://localhost:<port>/callback`. The URI must match one
registered for the Wrike application; Wrike matches registered redirect URIs
exactly, so the port and path registered are the port and path that must be
used.

The scheme, host, and path are fixed; only the port is configurable, through
`WRIKE_GATEWAY_OAUTH_CALLBACK_PORT`, defaulting to `8765`. The registered
redirect URI differs per Wrike application, so a fixed port made the flow
unusable against an application registered on another port. Because only the
port varies, no configuration can send an authorization code anywhere but a
loopback listener on this machine. There is still no redirect URI, host, or
path override, and no CLI flag carries any of them.

A malformed or out-of-range port fails locally, at composition, before the
any listener binding, rather than silently reverting to the
default: a service listening on a port the operator did not intend cannot
receive the redirect, and the reason would not be obvious.

The callback service is bound only for the duration of one login and stops when
the flow returns. If the browser cannot be opened, the command fails with safe
guidance rather than printing the URL, because the URL contains the client id
and OAuth state.

## OAuth Callback Transport

The callback service speaks plain HTTP on the loopback interface. It holds no
certificate, reads nothing from the macOS Keychain, and requires no operator
certificate provisioning or trust change.

This follows RFC 8252 section 7.3: a native application cannot hold a
certificate a browser will trust for `localhost`, so the loopback interface
redirect is specified to use `http`. The security property that replaces TLS is
the bind itself. The listener sets `requiredInterfaceType = .loopback`, so the
socket is reachable only over loopback and the authorization code never
traverses a network the operator does not control.

The service is bound immediately before the browser opens and stops when the
flow returns, so no port is left listening. It accepts exactly one request. The
response body it writes back to the browser is a fixed confirmation string with
a measured `Content-Length`; it carries no OAuth data.

The listener reads until the request line is terminated rather than parsing
whatever the first socket read returns. A browser is free to split the callback
GET across TCP segments, and the authorization code and OAuth state make that
line long enough for it to happen; parsing a partial line would truncate the
code and send the truncated value to Wrike, which reports only `invalid_grant`.
Reading is bounded, so a peer that sends no terminator is refused rather than
read until the login timeout.

What the callback must still prove is unchanged by dropping TLS:

- the request arrived on the expected host, port, and path;
- the `state` matches the pending flow, compared in constant time;
- an OAuth `error` parameter is treated as a failure; and
- an authorization code is present.

Any mismatch fails locally with `AUTHENTICATION_FAILED` and CLI exit code `3`.
A callback that never arrives fails on a bounded timeout, and the listener is
cancelled so the port is released rather than left bound.

The resolved callback strategy is recorded in
`design-docs/user-qa/qa-oauth-callback.md`.

## Refresh Flow

Wrike refresh can rotate both access and refresh tokens, invalidating the old
refresh token. A single-flight coordinator permits only one refresh for a
credential record at a time. Waiters reuse the committed result rather than
submitting the old token again.

The refresh request uses the host/token URL rules returned by Wrike. New token
state is written atomically before the old record is discarded. If persistence
fails, the process does not claim login success and does not print either
token. A 401 after one successful refresh is returned without a second refresh
loop, and the re-send that carries the refreshed credential does not consume one
of the attempts the retry policy budgets for transient upstream conditions.

A refresh response updates the record it was issued against; it does not replace
it. RFC 6749 section 5.1 makes `scope` optional when it is unchanged, and
section 6 makes reissuing a refresh token optional, so a response that omits
`scope`, `refresh_token`, or `host` leaves the stored value in place. Reading an
omitted field as an absent one would empty the granted scopes, which both
misreports `auth status` and disables the local scope pre-check, or would force
a new browser authorization while the stored refresh token is still valid. A
present but empty `scope` is treated as omitted rather than as a grant of
nothing. The authorization-code exchange has no prior record, so it still
requires the access token, refresh token, and data-center host to be present.

Refresh occurs before expiry using a bounded clock-skew allowance. Tests inject
a clock and credential store to cover expiry, rotation, concurrent requests,
failed exchange, and failed persistence.

## Credential Store

The initial required backend is kinko, abstracted behind a credential-store
protocol. The record key is scoped to `wrike-gateway`, the OAuth client id, and
the Wrike account/host so accounts do not overwrite each other.

Required operations are load, atomic replace, metadata-only status, and local
delete. Stored secret records must use kinko's protected storage and restrictive
permissions. Plaintext fallback is not automatic. Per
`design-docs/user-qa/qa-token-storage.md`, the initial release stores one
default account record; the record key remains scoped by client id and
account/host so named multi-account records can be added later without
migration.

### Verified kinko Command Contract

The following was verified against `kinko version` 0.1.8 by reading
`kinko get --help`, `kinko set-key --help`, and `kinko delete --help`, and is
pinned by `Tests/WrikeGatewayCoreTests/Auth/KinkoCredentialStoreTests.swift`:

| Operation | Command |
| --- | --- |
| load | `kinko get KEY --reveal --force --path <home> --profile default` |
| replace | `kinko set-key KEY --confirm=false --path <home> --profile default`, record on stdin |
| delete | `kinko delete KEY --yes --path <home> --profile default` |
| exists | `kinko get KEY --force --path <home> --profile default` (masked, never decrypted) |

Interface constraints that follow from that inventory:

- Record names must be valid environment keys (letter or underscore first, then
  letters, digits, or underscores), so the record name is
  `WRIKE_GATEWAY_OAUTH_<client fingerprint>_<host>`.
- The record body is written on stdin. `--value` would place token material in
  the process listing, where any local user can read it.
- `--force` is required because kinko blocks sensitive output for
  non-tty/redirection, which is every invocation made by this tool.
- `--path` defaults to the working directory and `--profile` is overridable by
  `KINKO_PROFILE`, so both are pinned; the path scope is the user's home
  directory, because the record belongs to the user rather than to a checkout.
- The executable is resolved from `PATH` first, then `/opt/homebrew/bin/kinko`
  and `/usr/local/bin/kinko`, because `Process` does not search `PATH` and the
  install prefix differs between Apple Silicon Homebrew, Intel Homebrew, and
  Nix.
- A vault that kinko cannot open is reported as an unavailable credential store
  with `kinko unlock` guidance, not as a missing record. The marker is recorded
  per subcommand, because kinko 0.1.8 does not answer the same way on every
  path. Verified on 2026-08-05 by running each command against the operator's
  locked vault with a key that does not exist, and against an empty temporary
  `--kinko-dir`:

  | Command | Locked vault | No vault at that directory |
  | --- | --- | --- |
  | `get` | exit 1, `locked` | exit 1, `open <dir>/vault/meta.v1.json: no such file or directory` |
  | `set-key` | exit 1, `locked` | exit 12, `Vault mutation in progress.` |
  | `delete` | exit 13, `Failed to load vault.` | exit 13, `Failed to load vault.` |

  Only `get` and `set-key` print `locked`; `delete` never does. Classification
  matches the exit code together with the exact stderr line, so an unrelated
  failure that happens to mention a vault is not swallowed.
- A record that does not exist is reported by exactly one marker: exit 1 with
  stderr `secret not found`, on both `get` and `delete`. Verified on 2026-08-05
  against an unlocked disposable vault. It shares exit 1 with the locked-vault
  marker, so the stderr line is matched as well.
- Only that marker means "no record". Every other non-zero exit throws:
  `load` returns `nil`, `hasRecord` returns `false`, and `delete` returns
  `false` on the missing-record marker alone, so an unrecognised failure -- a
  kinko upgrade that rewords a status line, a keychain error, a corrupt vault --
  can never be reported as an empty store. `auth logout` therefore cannot report
  `removedLocalRecord: false` while the record is still stored, and `auth
  status` cannot report "no credential" for a vault that failed to answer.

  That invariant holds only if every layer above the store preserves the throw,
  so the enforcing paths are named here as a fixed list to check rather than a
  property to re-derive:

  | Layer | Path | Enforcement |
  | --- | --- | --- |
  | Store | `KinkoCredentialStore.load` | `nil` on the missing-record marker alone; throws otherwise |
  | Store | `KinkoCredentialStore.hasRecord` | `false` on the missing-record marker alone; throws otherwise |
  | Store | `KinkoCredentialStore.delete` | `false` on the missing-record marker alone; throws otherwise |
  | Resolver | `CredentialResolver.loadState` | propagates the store throw; returns `nil` only for no client configuration or no record |
  | Resolver | `CredentialResolver.status(hasCallbackIdentity:)` | `async throws`; a store failure is never mapped to `mode: null` |
  | Resolver | `CredentialResolver.logout` | `async throws`; a store failure is never mapped to `removedLocalRecord: false` |
  | CLI | `AuthCommands.status` | catches `GatewayError` and emits the errors envelope with exit `6` |
  | CLI | `AuthCommands.logout` | catches `GatewayError` and emits the errors envelope with exit `6` |

  No layer on this list may use `try?` on a store call. Doing so restores the
  defect the store-level classification exists to prevent, one level above the
  fix and invisible to the store's own tests.
- `delete` runs as a single command. Because it reports a missing key itself,
  there is no separate existence check and no window between the two in which
  the record can change.

Two kinko behaviors constrain how the round-trip test may be written, both
observed on 2026-08-05 at kinko 0.1.8:

- `kinko init --kinko-dir <dir>` rewrites the bootstrap config at
  `~/.config/kinko/bootstrap.toml` so that every later kinko command defaults to
  `<dir>`. A test that creates a disposable vault must therefore also pass
  `--config <temporary file>`, or it leaves the operator's kinko pointing at a
  directory it then deletes. `KinkoRoundTripTests` passes both flags and asserts
  that the operator's bootstrap config is byte-identical after the run.
- An unlock session is not isolated by `--kinko-dir` or `--path`. Unlocking a
  disposable vault makes `kinko status` report `unlocked` for every scope, and
  locking returns every scope to `locked`. `KinkoRoundTripTests` therefore only
  runs when the operator's own scope reports `locked`, so it can never end a
  session it did not start.

## Redaction Rules

The following values must never appear in stdout, stderr, logs, traces, crash
summaries, test snapshots, or thrown error descriptions:

- client secret;
- access or permanent token;
- refresh token;
- authorization code;
- full Authorization header;
- OAuth state value; and
- webhook signing secret or signature.

Redaction happens structurally before formatting. String replacement after a
message is built is insufficient. Safe auth status contains only mode, host,
scope names, expiry time/status, and booleans indicating whether refresh state
or client configuration exists.

A safe report is not the same as a report that always succeeds. `auth status`
answers only what it actually knows: it reports a state, or it fails naming the
reason. It never fills an unknown with a benign-looking value. Two cases are
therefore reported as errors rather than flattened into the report:

- a credential store that cannot be read (see the enforcement table above); and
- permanent-token mode with a missing or rejected `WRIKE_GATEWAY_API_BASE_URL`,
  which exits `3` with `AUTHENTICATION_FAILED` instead of reporting mode
  `permanentToken` with `host: null`. Permanent-token mode has no host default,
  so that configuration cannot serve a single request; reporting it as usable
  defers a failure the status command already knows about.

## Scope Handling

Each capability declares accepted Wrike scopes and a recommended
least-privilege scope. OAuth requests use the union required by the selected
deployment tier and resource coverage. Granted scopes are stored as metadata.
Known missing scopes fail locally before API dispatch with recovery guidance.

Permanent tokens inherit the authorizing user's permissions and may not expose
scope metadata. In that mode, upstream 403 responses map to
`AUTHORIZATION_FAILED` without claiming that the binary can elevate access.

## Logout and Revocation

`auth logout` deletes local OAuth token state only and returns whether a local
record was removed. It does not revoke a permanent token and does not call a
Wrike resource DELETE endpoint. Permanent-token revocation is performed in
Wrike's application console and documented in the command guidance.

## Verification Requirements

- Unit tests cover precedence, empty values, required permanent-token base URL,
  host and `/api/v4` path validation, redaction, clock skew, scope checks,
  refresh rotation, single-flight behavior, and atomic storage failure.
- Loopback tests cover callback state validation, timeout, and code exchange
  without live credentials. Tests also prove that no redirect URI, host, or
  path flag or environment override is accepted.
- Real-socket tests drive the production listener rather than a stub, because
  the properties under test live in the socket layer: an end-to-end HTTP
  callback delivery, loopback-only reachability with no routable interface
  address answering, a bounded timeout that releases the port, a port already
  in use reported with actionable guidance, an out-of-range port refused before
  any socket is created, and a non-GET or unparsable request refused rather
  than delivered.
- Test fixtures use unmistakably fake values and assert that none appear in
  captured stdout or stderr.
- `task build`, `task test`, and `swiftlint` pass after implementation.

## References

- `design-docs/specs/architecture.md`
- `design-docs/specs/command.md`
- `design-docs/specs/design-wrike-api-client.md`
- Wrike OAuth2 guide: `https://developers.wrike.com/docs/oauth-20-authorization`
