# Wrike API Client Design

## Status

Implemented. The transport contract, host policy, pagination, error mapping,
retry policy, and mock/contract test strategy described below are in place and
covered by tests.

## Scope

This document defines the shared Wrike API v4 client used by the SDK and all
three executables. The initial reviewed resource scope is contacts, users,
groups, accounts/spaces, folders/projects, tasks, comments, attachments,
timelogs, custom fields, workflows, and webhooks.

The upstream inventory baseline was checked against Wrike's official API v4
reference on 2026-08-05. The implementation must re-check the downloadable
OpenAPI description before marking a capability implemented because methods,
scopes, fields, and plan restrictions can change.

## Endpoint and Host Model

- OAuth authorization starts at Wrike's login host.
- API requests use HTTPS and a data-center-aware `/api/v4` base URL resolved
  from OAuth host metadata or explicit permanent-token configuration.
- The base URL is parsed and validated once. Credentials may be sent only to
  an approved HTTPS Wrike host; redirects to a different host strip the
  authorization header and fail unless the auth flow explicitly approves it.
- Resource adapters provide relative paths and typed parameters. Public SDK or
  GraphQL callers cannot provide raw URLs.

## Transport Contract

`WrikeGatewayCore` owns the protocol boundary with these conceptual values:

- request: method, relative path, ordered query items, headers, body kind,
  timeout, stable capability id, and response sink;
- response: HTTP status, normalized headers, response bytes, and the written
  file description when the request selected a file sink;
- failure: cancelled, timed out, connectivity, TLS, malformed response, or
  local I/O.

The live transport uses `URLSession`. Capability adapters depend on the
protocol rather than on `URLSession`, global state, or singleton clients.
Authentication is a request decorator; response decoding is owned by the
resource adapter. This separation allows tests to distinguish request mapping,
network behavior, auth behavior, and model decoding.

## Request Construction

- Use `Authorization: Bearer <token>`; never place tokens in URLs.
- Encode query values according to Wrike API v4 expectations while preserving
  caller input as typed values until the final adapter step.
- Use JSON or form encoding only where the reviewed endpoint requires it.
- Attachment uploads stream bytes from a validated regular file and set the
  required content headers without buffering the entire file unnecessarily.
- DELETE is unavailable outside `WrikeGatewayAdmin`, even though the core
  transport can represent the HTTP method.
- Every request carries a local request id for diagnostics. It must not be
  confused with an upstream idempotency key.

## Response Decoding

Most Wrike API v4 success responses contain a `kind` and `data` collection.
Adapters decode the upstream envelope and map it to stable project models.
Unexpected `kind`, missing required data, incompatible field types, and invalid
pagination metadata are decoding errors rather than silently empty results.

Models preserve unknown future fields by ignoring them during decoding, but
public projection exposes only registered stable fields. Wrike identifiers are
opaque strings. Date/time values are decoded as ISO-8601 instants or explicit
calendar dates according to the endpoint contract.

### Binary Response Bodies

`GET /attachments/{attachmentId}/download` and
`GET /attachments/{attachmentId}/preview` answer with an
`application/octet-stream` body, which has no place in the `kind`/`data`
envelope. These are the only two routes with that shape, and they are handled
by a response sink rather than by a second decoding path:

- A capability declares a required `destinationPath`-bound argument and a
  `fileOutput` result. Declaring one without the other is a registry coherence
  failure, so a sink can never be selected without a result that describes it,
  and no mutation may write a local file.
- The destination is validated locally before the request is planned. An
  existing path, a directory, a missing parent directory, and a non-writable
  parent are each reported as `FILE_OPERATION_FAILED` with exit `6`, and no
  credential is resolved and no request is sent.
- Only a `2xx` body is content. A `4xx`/`5xx` body is the documented JSON error
  envelope, so it stays in memory for the error mapper and is never written to
  the caller's path. A refused download leaves no file behind, including no
  temporary file.
- A download never replaces an existing file. The local pre-check and the write
  itself both refuse, so a file that appears in the window between them is still
  not clobbered.
- The written file is created with `0600` permissions.
- The success body is never held in a `WrikeResponse`, an error description, a
  log line, or a snapshot. The response carries the path, the byte count, and
  the upstream content type only.

One core type, `ResponseSinkDelivery`, makes this decision for every transport.
The live `URLSession` transport streams into a temporary file and the test
transports hold canned bytes in memory, but both call the same delivery, so the
write rule under test is the write rule in production. A test asserts the two
entry points agree on every status code.

## Pagination

Pagination inputs are modeled as `pageSize` and opaque `nextPageToken` where
the endpoint supports them. A returned token is passed through without
inspection. The SDK offers explicit single-page calls first; any convenience
sequence must enforce caller-provided page and item limits.

The client must not:

- fetch all pages by default;
- combine a token with changed filters or optional field selections;
- assume all resource families share the same maximum page size; or
- synthesize a cross-resource token from an upstream token.

## Error Mapping

| Upstream condition | Stable code | Retry guidance |
| --- | --- | --- |
| invalid request or parameter | `VALIDATION_ERROR` | do not retry unchanged |
| invalid or expired bearer credential | `AUTHENTICATION_FAILED` | refresh once when OAuth state permits |
| forbidden or plan/scope restricted | `AUTHORIZATION_FAILED` | do not retry; report required scope/tier when known |
| resource not found | `NOT_FOUND` | do not retry unchanged |
| HTTP 429 | `RATE_LIMITED` | honor `Retry-After`; bounded GET retry only |
| HTTP 5xx | `UPSTREAM_UNAVAILABLE` | bounded GET retry with jitter |
| transport timeout/connectivity | `TRANSPORT_FAILED` | bounded GET retry with jitter |
| incompatible success payload | `UPSTREAM_RESPONSE_INVALID` | do not retry automatically |

`TRANSPORT_FAILED` remains distinct in the public GraphQL error contract so a
caller can distinguish a local connectivity failure from an HTTP response from
Wrike. Both `TRANSPORT_FAILED` and transient `UPSTREAM_UNAVAILABLE` map to CLI
exit code `5`.

Public errors contain a stable code, safe message, request id, HTTP status when
available, and non-secret recovery guidance. Raw bodies are available only to
redacted debug instrumentation and never when they might contain credentials
or user content.

## Retry and Rate-Limit Policy

Wrike documents a token/IP request limit and returns HTTP 429 for exhaustion.
The client honors `Retry-After` when present and otherwise uses capped
exponential backoff with jitter. Retry count and total elapsed time are
bounded.

Only GET operations retry automatically. Create, update, delete, OAuth token
exchange, refresh-token rotation, and attachment upload require an explicit
operation-specific idempotency design before retries can be enabled. A failed
mutation is reported as outcome-unknown when the transport cannot prove that
Wrike did not apply it.

## Resource Adapter Boundaries

Each resource family owns:

- typed request inputs and stable response models;
- endpoint path and HTTP method mapping;
- scope and capability metadata;
- upstream envelope decoding;
- pagination constraints;
- safe error context; and
- canned success and error fixtures.

Cross-resource hydration is explicit. For example, a task response containing
assignee ids does not automatically trigger contact calls unless the public
field requests hydrated assignees and the planner budgets the additional
requests.

## Mock and Contract Test Strategy

### Recording Transport

Fast unit tests inject an in-memory transport that records requests and returns
canned responses. Every capability verifies its method, path, parameter/body
mapping, selected credential context, decoded stable model, and mapped error.
Tests assert that authorization headers are present when required but never
snapshot their values.

### Loopback Mock Server

A process-local loopback HTTP server verifies URL encoding, HTTP headers,
streamed uploads, redirect rejection, pagination, response headers, and retry
timing. Fixtures cover at least:

- representative success envelopes for all twelve resource areas;
- empty and multi-page results;
- OAuth expiry followed by one successful refresh;
- rotating refresh-token concurrency;
- 400, 401, 403, 404, 429, and 500 errors;
- malformed JSON, wrong `kind`, and partial data;
- attachment upload/download without logging bytes; and
- non-idempotent mutation failures without automatic replay.

The server binds only to loopback on an ephemeral port. Production executables
have no flag for selecting it.

### Boundary Tests

Package tests verify that reader fixtures cannot dispatch write or delete
capabilities and writer fixtures cannot dispatch delete capabilities. CLI
tests run all three binaries against injected test composition roots and
compare the role-specific schemas.

## Observability and Redaction

Safe diagnostics may include request id, capability id, HTTP method, normalized
path template, status, attempt count, elapsed time, and rate-limit metadata.
They must exclude authorization headers, tokens, client secrets, authorization
codes, webhook secrets/signatures, file contents, raw comment text, and raw
request/response bodies.

## Verification Requirements

- Every implemented capability has a recording-transport success and failure
  test.
- Every resource family has at least one loopback canned-response contract
  test.
- Pagination, rate limits, refresh concurrency, attachment streaming, and
  redaction have dedicated tests.
- `task build`, `task test`, and `swiftlint` pass after implementation.

## References

- `design-docs/specs/architecture.md`
- `design-docs/specs/design-capability-matrix.md`
- `design-docs/specs/design-authentication.md`
- Wrike API v4 overview: `https://developers.wrike.com/overview/`
- Wrike API v4 reference index: `https://developers.wrike.com/reference/`
- Wrike error reference: `https://developers.wrike.com/docs/errors-api-reference-v4`
