# Architecture

## Status

Implemented. The SwiftPM target layout, product map, capability enforcement,
transport injection, and authentication boundary described below are in place
and covered by tests. See
`design-docs/specs/design-capability-matrix.md#implementation-status` for
per-capability state.

## Overview

`wrike-gateway` is a Swift Package Manager project that exposes Wrike API v4
through a Swift SDK and three GraphQL-style command-line executables. The
public contract is owned by this project; Wrike REST paths, query parameters,
and response envelopes remain transport details.

Capabilities are separated at SwiftPM link boundaries. A reader executable
cannot import or link create, update, or delete resolvers. A writer adds
create and update behavior but cannot link delete resolvers. An admin adds
the reviewed delete operations supported by Wrike API v4.

The design adapts the useful boundaries from `x-gateway` rather than copying
its X-specific schema. Wrike folders, projects, spaces, and tasks retain their
native hierarchy in the project-owned contract.

## Design Principles

- Keep Wrike API v4 transport details behind typed client protocols.
- Use one stable capability identifier for GraphQL registration, tier
  authorization, SDK dispatch, and test assertions.
- Enforce capability tiers through target dependencies as well as runtime
  schema validation.
- Treat all Wrike identifiers as opaque strings of up to 256 supported text
  characters; do not decode, normalize, order, or derive values from them.
- Never expose credential values in logs, diagnostics, process listings, or
  command output.
- Keep executable entry points thin so parsing, validation, and response
  shaping do not drift between binaries.

## SwiftPM Target Layout

| Target | Kind | Responsibility |
| --- | --- | --- |
| `WrikeGatewayCore` | library target | HTTP primitives, authentication, shared DTOs, GraphQL parser/projection, error envelopes, capability metadata |
| `WrikeGatewayRead` | library target | GET-backed API adapters, query schema, read SDK methods |
| `WrikeGatewayWrite` | library target | POST/PUT-backed create and update adapters, non-delete mutation schema, write SDK methods |
| `WrikeGatewayAdmin` | library target | DELETE-backed adapters, delete mutation schema, admin SDK methods |
| `WrikeGatewayReaderCLI` | executable target | entry point for `wrike-gateway-reader` |
| `WrikeGatewayWriterCLI` | executable target | entry point for `wrike-gateway-writer` |
| `WrikeGatewayAdminCLI` | executable target | entry point for `wrike-gateway-admin` |
| `WrikeGatewayCoreTests` | test target | core parser, auth, transport, error, and projection tests |
| `WrikeGatewayReadTests` | test target | read capability and canned-response contract tests |
| `WrikeGatewayWriteTests` | test target | create/update capability and tier-rejection tests |
| `WrikeGatewayAdminTests` | test target | delete capability and destructive-operation tests |
| `WrikeGatewayCLITests` | test target | command grammar, executable-role, stdout, stderr, and exit-code tests |

The existing `AppCore`, `AppCLI`, and `AppCoreTests` scaffold is replaced in
the implementation phase. It is not an additional compatibility layer.

## SwiftPM Product and Import Map

The package publishes cumulative SDK products while retaining separate Swift
modules. Product membership and consumer imports are explicit:

| Product | Product targets | Consumer imports |
| --- | --- | --- |
| `WrikeGatewayCore` | `WrikeGatewayCore` | `WrikeGatewayCore` |
| `WrikeGatewayRead` | `WrikeGatewayCore`, `WrikeGatewayRead` | `WrikeGatewayCore`, `WrikeGatewayRead` |
| `WrikeGatewayWrite` | `WrikeGatewayCore`, `WrikeGatewayRead`, `WrikeGatewayWrite` | `WrikeGatewayCore`, `WrikeGatewayRead`, `WrikeGatewayWrite` |
| `WrikeGatewayAdmin` | `WrikeGatewayCore`, `WrikeGatewayRead`, `WrikeGatewayWrite`, `WrikeGatewayAdmin` | `WrikeGatewayCore`, `WrikeGatewayRead`, `WrikeGatewayWrite`, `WrikeGatewayAdmin` |
| `wrike-gateway-reader` | `WrikeGatewayReaderCLI` | executable product; no consumer import |
| `wrike-gateway-writer` | `WrikeGatewayWriterCLI` | executable product; no consumer import |
| `wrike-gateway-admin` | `WrikeGatewayAdminCLI` | executable product; no consumer import |

The product name does not create a same-named umbrella Swift module. Public
types shared across tiers remain in `WrikeGatewayCore`; SDK consumers import
the core module and every capability module included by the selected product.
The design does not rely on implicit or underscored module re-export.

## Dependency Graph

```text
Library targets:
  WrikeGatewayCore  -> no capability target
  WrikeGatewayRead  -> WrikeGatewayCore
  WrikeGatewayWrite -> WrikeGatewayCore + WrikeGatewayRead
  WrikeGatewayAdmin -> WrikeGatewayCore + WrikeGatewayRead + WrikeGatewayWrite

Executable targets:
  WrikeGatewayReaderCLI -> WrikeGatewayCore + WrikeGatewayRead
  WrikeGatewayWriterCLI -> WrikeGatewayCore + WrikeGatewayRead + WrikeGatewayWrite
  WrikeGatewayAdminCLI  -> WrikeGatewayCore + WrikeGatewayRead + WrikeGatewayWrite + WrikeGatewayAdmin
```

Executable dependencies are direct because each entry point imports every
listed module; the design does not rely on transitive imports. Reader never
depends on write or admin, and writer never depends on admin.

## Capability Enforcement

The capability registry records a stable capability id, GraphQL field,
operation class, required tier, Wrike endpoint family, required scopes, and
implementation status. Registration is valid only when the GraphQL field,
SDK method, and adapter all refer to the same capability id.

The CLI assembles a role-specific schema from linked modules:

- reader: Query fields only;
- writer: all reader Query fields plus create/update Mutation fields;
- admin: the writer schema plus delete Mutation fields.

Runtime tier checks remain mandatory as defense in depth, but they are not the
primary boundary. A build inspection test must prove that
`wrike-gateway-reader` does not link `WrikeGatewayWrite` or
`WrikeGatewayAdmin`, and that `wrike-gateway-writer` does not link
`WrikeGatewayAdmin`.

## Request Data Flow

```text
CLI arguments or Swift SDK call
  -> project-owned GraphQL/SDK request
  -> syntax and input validation
  -> role-specific capability lookup
  -> credential and scope resolution
  -> typed Wrike request adapter
  -> WrikeTransport protocol
  -> Wrike API v4
  -> upstream envelope decoding
  -> stable model mapping and selection projection
  -> project-owned JSON response
```

No public GraphQL field accepts raw paths, arbitrary HTTP methods, arbitrary
query parameters, or an unreviewed upstream response passthrough.

## Transport Dependency Injection

`WrikeGatewayCore` owns a `WrikeTransport` protocol expressed in request and
response value types. The live implementation uses `URLSession`; capability
adapters receive the protocol through initializer injection. Authentication
decorates a request before transport execution and is independently
replaceable in tests.

Tests use two substitutes:

- an in-memory recording transport for exact method, path, headers, query,
  and body assertions; and
- a loopback mock HTTP server serving canned Wrike success, pagination,
  authentication, rate-limit, and malformed-response fixtures.

No test mode, fixture path, or credential override is exposed by a production
binary. See `design-wrike-api-client.md` for the protocol contract.

## Authentication Boundary

`WrikeGatewayCore` resolves one bearer credential from either OAuth2 token
state or `WRIKE_GATEWAY_ACCESS_TOKEN`. Permanent-token mode also requires
`WRIKE_GATEWAY_API_BASE_URL`; it has no implicit host default. OAuth2 client
credentials are supplied by kinko-managed environment variables
`WRIKE_GATEWAY_API_CLIENT_ID` and
`WRIKE_GATEWAY_API_CLIENT_SECRET`. OAuth2 access and rotating refresh tokens
are stored through a credential-store protocol, with kinko as the required
initial backend.

The OAuth callback is a plain HTTP service bound to the loopback interface for
the duration of one login, per RFC 8252 section 7.3. It holds no certificate
and reads nothing from the Keychain; loopback-only reachability is the property
that keeps the authorization code on this machine. The port comes from
`WRIKE_GATEWAY_OAUTH_CALLBACK_PORT` and defaults to `8765`, so the redirect URI
can match the one registered for the Wrike application.

The resolved Wrike data-center host is stored with token state. Requests must
not assume that every account uses `www.wrike.com`. See
`design-authentication.md` for precedence, refresh, and redaction rules.

## Concurrency and Retry Boundaries

- Shared models and protocol values must be `Sendable` under Swift 6.
- A single-flight refresh coordinator prevents concurrent requests from using
  the same rotating refresh token.
- GET requests may retry bounded transient failures and honor `Retry-After`.
- POST, PUT, DELETE, and attachment upload requests do not retry
  automatically unless the operation has a reviewed idempotency guarantee.
- Pagination is explicit and bounded; the SDK does not silently fetch an
  unbounded account.

## Release Surfaces

- Homebrew formula archives under `dist/homebrew/` install
  `wrike-gateway-reader`, `wrike-gateway-writer`, and
  `wrike-gateway-admin`.
- Signed and notarized Cask DMGs under `dist/homebrew-cask/` contain the same
  three executables.
- Packaging changes are outside this documentation-only work and occur only
  after all three products exist and pass their capability-boundary tests.

## Rollout Constraints

1. Establish `WrikeGatewayCore` and the transport/auth seams.
2. Add the read target and reader executable before any mutation module.
3. Add writer create/update capabilities with explicit reader rejection.
4. Add admin delete capabilities only after destructive-operation tests exist.
5. Expand resource coverage only when the capability registry, GraphQL field,
   SDK method, adapter, scopes, and canned-response tests move together.

## References

- `design-docs/specs/command.md`
- `design-docs/specs/design-wrike-api-client.md`
- `design-docs/specs/design-graphql-contract.md`
- `design-docs/specs/design-capability-matrix.md`
- `design-docs/specs/design-authentication.md`
