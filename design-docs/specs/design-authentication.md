# Authentication and Credential Handling Design

## Status

Draft

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
3. Start a loopback callback listener on the fixed initial redirect URI.
4. Open the Wrike authorization URL through the operating-system browser API
   without emitting the URL to stdout, stderr, or logs.
5. Reject callbacks with mismatched state, unexpected path/host, missing code,
   OAuth error, or elapsed timeout.
6. Exchange the one-time code at the approved Wrike token endpoint.
7. Persist access token, refresh token, expiry, granted scopes, and the
   data-center host atomically through the credential store.
8. Clear transient code and state values from memory as soon as practical.

The initial redirect is fixed at `https://localhost:8765/callback`, matching
Wrike's HTTPS requirement for registered redirect URIs and its localhost
guidance. The URI must match one registered for the Wrike application. The
initial contract accepts no redirect URI flag or environment override. If the
browser cannot be opened, the command fails with safe guidance rather than
printing the URL, because the URL contains the client id and OAuth state.

## OAuth Callback TLS Identity

The initial listener loads exactly one certificate/private-key identity from
the current user's macOS login Keychain using the fixed application label
`wrike-gateway.oauth.localhost`. Creating, signing, trusting, renewing, and
importing that identity are operator-managed prerequisites; the CLI does not
generate certificates, import private keys, or modify trust settings.

Before binding the listener or opening the browser, the identity loader must
verify that:

- exactly one identity matches the fixed label;
- the certificate is currently valid and has `localhost` as a DNS subject
  alternative name;
- the certificate permits TLS server authentication;
- macOS trust evaluation accepts its chain for `https://localhost`; and
- the associated private key is available through the Keychain identity.

A missing, ambiguous, expired, untrusted, hostname-incompatible, or inaccessible
identity fails locally with `AUTHENTICATION_FAILED` and CLI exit code `3` before
the listener or browser starts. Recovery guidance may name the fixed Keychain
label and required certificate properties, but must not include certificate
contents, private-key material, Keychain record data, OAuth state, or the
authorization URL.

The private key never leaves Keychain. Runtime code receives only an opaque
identity handle; it must not export the key to kinko, environment variables,
temporary files, repository files, diagnostics, or test snapshots. Kinko
continues to own OAuth token records, not callback TLS identities. An injected
identity-loader boundary supplies deterministic success and failure fixtures in
tests without adding a production CLI override.

Configurable callbacks, automated certificate provisioning, alternate identity
labels, and manual handoff remain future decisions in
`design-docs/user-qa/pending-oauth-callback.md`.

## Refresh Flow

Wrike refresh can rotate both access and refresh tokens, invalidating the old
refresh token. A single-flight coordinator permits only one refresh for a
credential record at a time. Waiters reuse the committed result rather than
submitting the old token again.

The refresh request uses the host/token URL rules returned by Wrike. New token
state is written atomically before the old record is discarded. If persistence
fails, the process does not claim login success and does not print either
token. A 401 after one successful refresh is returned without a second refresh
loop.

Refresh occurs before expiry using a bounded clock-skew allowance. Tests inject
a clock and credential store to cover expiry, rotation, concurrent requests,
failed exchange, and failed persistence.

## Credential Store

The initial required backend is kinko, abstracted behind a credential-store
protocol. The record key is scoped to `wrike-gateway`, the OAuth client id, and
the Wrike account/host so accounts do not overwrite each other.

Required operations are load, atomic replace, metadata-only status, and local
delete. Stored secret records must use kinko's protected storage and restrictive
permissions. Plaintext fallback is not automatic. The exact multi-account
selection and cache policy remains pending in
`design-docs/user-qa/pending-token-storage.md`.

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
- Loopback tests cover callback state validation, timeout, code exchange, and
  TLS redirect rejection without live credentials. Tests also prove that no
  redirect URI flag or environment override is accepted by the initial
  contract.
- TLS identity tests cover missing, duplicate, expired, untrusted,
  hostname-incompatible, wrong-key-usage, inaccessible-private-key, and valid
  Keychain identity outcomes before browser launch.
- Test fixtures use unmistakably fake values and assert that none appear in
  captured stdout or stderr.
- `task build`, `task test`, and `swiftlint` pass after implementation.

## References

- `design-docs/specs/architecture.md`
- `design-docs/specs/command.md`
- `design-docs/specs/design-wrike-api-client.md`
- Wrike OAuth2 guide: `https://developers.wrike.com/docs/oauth-20-authorization`
