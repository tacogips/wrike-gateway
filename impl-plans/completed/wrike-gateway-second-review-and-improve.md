# Wrike Gateway Second Review and Improve

**Status**: Completed
**Design Reference**: `design-docs/specs/design-authentication.md#refresh-flow`,
`design-docs/specs/design-authentication.md#oauth-callback-transport`,
`design-docs/specs/design-wrike-api-client.md#pagination`
**Created**: 2026-08-06
**Last Updated**: 2026-08-06

## Purpose

Run a second review-and-improve pass over the repository as it stands on `main`
(`1934c87`), after the first pass
(`impl-plans/completed/wrike-gateway-review-and-improve.md`, findings R1-R13)
and after the live verification
(`design-docs/references/live-verification-2026-08-06.md`).

Four focus areas were named going in, each of which had to be dispositioned
explicitly:

1. the opt-in live E2E runner has never executed against the account, so its
   correctness is unproven;
2. the E2E scenario catalog and its replay runner may have drifted from the
   current schema and from the four defects the live verification fixed;
3. the live-verification record predates the OAuth callback rewrite (`8a45649`)
   and the token-exchange host-policy fix (`1934c87`), so its auth-boundary
   claims need reconciling; and
4. the authorization-code exchange, refresh rotation, and single-flight refresh
   are exercised only through injected transports, so the OAuth flow needs a
   review for gaps only a live run would catch.

Beyond those, a general sweep for correctness, Swift 6 concurrency, GraphQL
parser edge cases, error-mapping consistency, pagination-token misuse, redaction
completeness, coverage gaps, doc drift, and simplification. Findings R1-R13 are
built on, never repeated.

This is a review-and-improve pass over working code. The architecture is
unchanged: four cumulative library targets, three tier-scoped executables,
protocol-based `WrikeTransport` injection, and the project-owned GraphQL
contract.

## Scope

### Included

- The four named focus areas, each with an explicit disposition.
- A correctness, concurrency, parser, error-mapping, pagination, redaction,
  coverage, and doc-drift sweep over `Sources/` and `Tests/`.
- Covering tests for every accepted finding.
- `design-docs/specs/design-authentication.md`,
  `design-docs/references/live-verification-2026-08-06.md`, `README.md`, and
  `Taskfile.yml` updates where behavior or guidance changed.

### Excluded

- Any change to a GraphQL field name, argument name, error code, exit code, or
  environment variable name.
- Any weakening of a capability-tier boundary, a redaction rule, or a
  destructive-operation safeguard.
- Reintroducing any Keychain, `SecIdentity`, or `SecTrust` dependency. The
  loopback HTTP callback is settled.
- A live OAuth login, which is blocked outside the code (S6 below).
- Any live mutation. The live mutation lifecycle was not run.
- The pre-existing staged `flake.lock`, which is untouched.

## Findings

Severity is the effect on a caller: **high** silently misreports an outcome,
**medium** costs an operator a diagnosis or a working session, **low** is
correctness or hygiene with no wrong answer reaching a caller.

### S1: A split callback request line truncated the authorization code (medium, fixed)

`LoopbackCallbackListener` parsed the OAuth callback from whatever the first
`connection.receive` returned. A browser may split the callback `GET` across TCP
segments, and the authorization code plus the 32-byte OAuth state make that
request line long enough for it to happen in practice. When it did, the listener
parsed the partial line as if it were complete: `text.split(separator: "\r\n")`
returns the whole buffer when no terminator is present, so a truncated `code`
value was extracted and delivered as a valid callback. The flow then sent that
truncated code to Wrike's token endpoint, which answers only `invalid_grant`,
with nothing pointing at the real cause. If the split fell before `code`
instead, the login failed as "did not include an authorization code" for a
callback that in fact contained one.

This is exactly the class of defect the focus area asked for: every existing
test wrote the request in one segment, so nothing could observe it.

Fixed: `requestLineOutcome(_:port:)` locates the line terminator in the received
bytes and returns `.complete`, `.incomplete`, or `.invalid`. The connection
handler accumulates across reads while the outcome is `.incomplete` and parses
only a terminated line. Reading is bounded by `maximumRequestLineBytes` (8192)
and by the peer's end of input, so a peer that never sends a terminator is
refused rather than read until the login timeout. A bare `LF` terminator is
accepted alongside `CRLF`; tolerating it cannot truncate anything. The
`parseRequestLine` entry point is retained as a thin wrapper, so the existing
rejection assertions still apply. The single-request, loopback-only, and
bounded-lifetime properties are untouched.

Tests: `LoopbackCallbackListenerTests.refusesPartialRequestLine` (a buffer cut
inside the code value reports `.incomplete` and parses to `nil`; a terminated
buffer decides immediately; a bare-`LF` line parses),
`.reassemblesSplitRequestLine` (a real socket sends the request line in two
segments split inside the code value, and the delivered callback carries the
whole code and validates), and `.refusesTerminatorlessRequest` (a half-closed
connection with no terminator fails with `AUTHENTICATION_FAILED` and quotes no
callback value).

### S2: A refresh response was treated as a full replacement (medium, fixed)

`OAuthTokenExchange.decode` read every field of a token response as if the
server had to repeat it. RFC 6749 section 5.1 makes `scope` optional when it is
unchanged, and section 6 makes reissuing a refresh token optional. Wrike's
refresh response shape is unconfirmed against a live endpoint (S6), so all three
optional fields mattered:

- an omitted `scope` emptied `grantedScopes`, which made `auth status` report no
  scopes for a credential that has them and silently disabled the local scope
  pre-check, because an empty granted list is the documented "no inspectable
  scope metadata" signal;
- an omitted `refresh_token` failed the refresh outright with "did not contain a
  refresh token", sending an operator to a new browser authorization while the
  stored refresh token was still valid; and
- an omitted `host` failed the same way.

Fixed: a refresh response updates the record it was issued against rather than
replacing it. `refresh(_:client:now:)` passes the previous state into `decode`,
which falls back to the stored `refresh_token`, `host`, and `grantedScopes` when
the response omits them. A present but empty `scope` is treated as omitted
rather than as a grant of nothing. The authorization-code exchange passes no
previous state, so it still requires the access token, refresh token, and
data-center host to be present. Host validation against the approved allowlist
runs on the resolved host either way, so the fallback cannot install an
unapproved host.

Tests: `OAuthRefreshTests.refreshPreservesOmittedFields` (a minimal
`access_token` plus `expires_in` response keeps the stored scopes, refresh
token, and host, and rotates only the access token),
`.refreshAppliesReportedFields` (a response that reports its own values still
replaces all three, including a data-center change),
`.refreshIgnoresEmptyScope`, and `.codeExchangeStillRequiresIssuedFields` (the
authorization-code exchange still rejects a response missing either field).

### S3: A credential refresh spent a budgeted retry attempt (low, fixed)

`CapabilityExecutor.send` incremented `attempt` once per loop pass, and the
re-send that follows a 401 refresh took one of those passes. The refresh is not
a retry of a transient upstream condition; it replaces a credential the upstream
refused. Charging it to the retry budget silently shortened every retry sequence
that follows a token expiry, which is the ordinary case for a long-lived OAuth
session: with the default three attempts, a request that refreshed and then met
a 429 got one retry instead of two.

Fixed: the refresh branch decrements `attempt` before continuing, so the
refreshed re-send is the same logical attempt. `didRefresh` already bounds that
branch to one pass, so the loop cannot be extended indefinitely.

Test: `RetryPolicyTests.refreshDoesNotConsumeARetry` drives 401, 500, 500, 200
through a three-attempt policy and requires all four requests plus exactly two
backoffs. Before the fix the sequence stopped after the second 500.

### S4: The only documented live command ran the mutation lifecycle (low, fixed)

`task test:live` filters on `LiveE2EScenarioTests`, which selects both the
read-and-boundary test and the mutation lifecycle that creates a real container
in the account. Every document that told an operator how to run a live check
pointed at that task, so a read-only live verification could not be requested
without also running the mutation half.

Fixed: `task test:live:read` runs
`swift test --filter 'LiveE2EScenarioTests/readsAndBoundaries'`, which was
verified to select exactly one test. `task test:live` keeps its behavior and
now says in its description and in a comment that it includes the mutation
lifecycle. `README.md` and the live-verification record document both.

No unit test covers a Taskfile target. The filter granularity it depends on is
proved directly instead: `swift test --filter 'E2EScenarioReplayTests/catalogInventory'`
reports "1 test in 1 suite", and
`WRIKE_GATEWAY_LIVE_E2E=1 swift test --filter 'LiveE2EScenarioTests/readsAndBoundaries'`
reports one test, skipped, with the mutation test not selected at all.

### S5: The live-verification record's auth-boundary claims were stale (low, fixed)

`design-docs/references/live-verification-2026-08-06.md` predates `8a45649` and
`1934c87`. Three claims no longer described the code: the redirect URI recorded
as `https://localhost:8765/callback`, the "OAuth browser authorization not
exercised" row that no longer named the current blocker, and the 315 tests / 45
suites / 101 files count, which predates the Keychain removal.

Fixed by annotation, not by rewriting the record. The recorded live outcomes are
untouched. A header note names the two commits and their effect. Each stale
forward-looking claim carries an inline reconciliation note: the redirect URI is
now `http://localhost:<port>/callback` per RFC 8252 section 7.3, with the
loopback-only bind as the property that replaces TLS; the test count is
reconciled against the 313/44/99 baseline and the 321/44/99 result of this pass,
with the delta attributed to the Keychain removal. A new "OAuth Login Blocker"
section records S6 and a new "Auth Boundary as of the Reconciliation" section
states the current redirect URI, callback transport, token-exchange policy, and
credential storage in one place.

### S6: The live E2E runner is still unexecuted (recorded, not resolved)

The read-only half was not run against the account, because the credentials are
not available in this environment.
`kinko exec --force --env WRIKE_GATEWAY_ACCESS_TOKEN,WRIKE_GATEWAY_API_BASE_URL`
answers `secret not found for --env key "WRIKE_GATEWAY_ACCESS_TOKEN"`, and
`kinko show` reports no secret in this path scope. Nothing live was sent.

What was proved instead:

- the read-only test can be isolated. `swift test --filter` matches at function
  granularity, confirmed against a control run that reported "1 test in 1
  suite", so `LiveE2EScenarioTests/readsAndBoundaries` cannot pull in
  `mutationLifecycle`. `swift test list --filter` ignores its filter and lists
  everything, so it is not a usable check; the control run is.
- the opt-in guard skips cleanly.
  `WRIKE_GATEWAY_LIVE_E2E=1 swift test --filter 'LiveE2EScenarioTests/readsAndBoundaries'`
  with no credentials reports the suite and test skipped, exit 0, and made no
  request.
- the runner code was reviewed. `LiveE2EPrecondition` requires the flag and both
  non-empty variables; `readsAndBoundaries` sends only catalog read and boundary
  documents and captures ids from responses; `mutationLifecycle` refuses to
  start unless every created id has a matching cleanup step and the container is
  removed last, and it verifies containment with a fresh read before each
  delete.

What remains unproven, precisely: that any catalog document decodes a live 2026
Wrike envelope, that the live-id capture chain resolves against a real account,
and the entire mutation lifecycle. This is a narrower gap than it was before the
live verification, which exercised the same documents manually and fixed four
defects; what is unproven is the runner's automation of them, not the documents
themselves.

**Resolved for the read half after this pass closed.** The credentials turned
out to be present in the kinko home-directory path scope; the earlier lookup
failed only because kinko scopes secrets by path and the check ran under a
different scope. `task test:live:read` was then executed against the real
account. Its first run failed exactly where this finding predicted the risk
lay: the live-id capture chain took the folders list's first element, which on
a real account is the Root pseudo-folder, and Wrike refuses that id on the
by-id endpoint with HTTP 400 `invalid_request`. The capture mechanism gained a
declarative selector (`E2ECaptureSelector`; a `*` path component selects the
first array element matching a semantic field, here `scope == "WsFolder"`,
never an id shape), the folders scenario now requests `scope` and captures the
first real folder, and the rerun passed: 1 test, all catalog read and boundary
documents executed against the live account with the capture chain resolving
end to end. The mutation lifecycle remains unexecuted by this runner, and S7
still blocks a live OAuth login.

### S7: The OAuth login itself is blocked outside the code (resolved after the pass)

With a valid authorization code, Wrike's token endpoint answers
`unauthorized_client`, and a manual `curl` exchange using the same client id,
client secret, and redirect URI reproduces it exactly. The stored client secret
does not match the registered Wrike application, so this is a credential
registration problem rather than a gateway defect and no code change can work
around it. No live OAuth login was attempted during this pass. Recorded in the
live-verification document under "OAuth Login Blocker".

The consequence for focus area 4 is that S2's fix, and the exchange and refresh
paths generally, remain proved against injected transports and RFC 6749 rather
than against `login.wrike.com`. The callback listener is the one part of the
flow now proved over real sockets, including S1's split-segment case.

**Resolved after this pass closed.** The operator updated the client secret in
kinko, and `auth oauth2` then completed end to end against the live endpoint:
loopback HTTP callback received, state validated, authorization code exchanged
at `login.wrike.com`, token state committed (mode `oauth2`, host
`www.wrike.com`, refresh state available), and the stored OAuth credential
served a live `/api/v4` account read. Refresh rotation remains live-unexercised
until a token nears expiry.

### S8: E2E catalog drift (reviewed, no change needed)

The catalog and both runners were audited against the current three schemas and
against the four defects the live verification fixed. No drift was found.

- Schema coherence is enforced, not assumed. Every catalog scenario is
  replayable (none declares a `liveOnlyReason`), and `replaysCatalog` executes
  each one through the real runtime at its declared tier, so a field or argument
  that left the schema would fail the expectation rather than pass unnoticed.
  All three schemas are byte-identical to the pre-change snapshot, so nothing
  moved under the catalog during this pass either.
- `createTimelog` requires `trackedDate` and `comment`: the lifecycle step
  supplies both, and `WriterBoundaryTests.timelogRequiresLiveContractFields`
  rejects each omission locally with zero transport calls.
- The upload sends only the sanitized `X-File-Name`: asserted through
  `LoopbackHTTPServer`, which records that header by name.
- `comments.delete` and `attachments.delete` accept the reviewed empty-`data`
  confirmation while every other delete keeps outcome-unknown: the two lifecycle
  cleanup steps replay `{"kind":...,"data":[]}`, and `DeleteCapabilityTests`
  partitions the nine delete capabilities by `deletionConfirmation` and asserts
  both halves.
- Boundary scenarios expect `CAPABILITY_DENIED` and the raw REST escape expects
  local `VALIDATION_ERROR`: both hold, and `replaysCatalog` additionally
  requires `observedRequests.count == replayResponses.count`, which is zero for
  every boundary case, so a boundary that started reaching the network would
  fail.

### S9: Combining a page token with a page size (low, rejected)

`RequestBuilder` emits `pageSize` and `nextPageToken` together when a caller
supplies both, and `design-docs/specs/design-wrike-api-client.md#pagination`
says the client must not "combine a token with changed filters or optional field
selections". Rejecting the combination locally was considered and rejected.

The live verification paginated with exactly that shape and it worked:
`tasks(page: { pageSize: 1, nextPageToken: $token })` returned a second page, a
different task, and another token. Rejecting it would break a live-verified
path. The spec bullet also does not say what the fix would enforce: it forbids
*changing* a filter between pages, which a stateless gateway cannot detect,
whereas repeating the same `pageSize` alongside the token is not a change. The
current pass-through behavior is what the spec describes, so nothing is wrong
today.

### S10: GraphQL parser edge cases beyond R5 and R9 (reviewed, no change needed)

Swept for gaps the first pass did not cover. Duplicate top-level fields are
already rejected in `parseSelectionSet` ("Field X is selected more than once"),
so the response-key collision that would have discarded one of two executed
requests cannot occur. Aliases, directives, fragment spreads, fragment and
subscription definitions, default variable values, and block strings each fail
with their own named message. `readNumber` rejects `-`, `1-2`, and integers
beyond `Int` range through the `Double`/`Int` initializer guard rather than
silently truncating. `readString` rejects an unterminated literal and a literal
spanning lines. `parseArguments` rejects a repeated argument name. No change.

### S11: Error mapping against the client spec (reviewed, no change needed)

`UpstreamErrorMapper` was compared line by line with the error-mapping table in
`design-docs/specs/design-wrike-api-client.md`. Every row matches: 400 and 422
to `VALIDATION_ERROR`, 401 to `AUTHENTICATION_FAILED`, 403 to
`AUTHORIZATION_FAILED`, 404 to `NOT_FOUND`, 429 to `RATE_LIMITED`, 5xx to
`UPSTREAM_UNAVAILABLE`, anything else to `UPSTREAM_RESPONSE_INVALID`. Only the
documented `error` enum is read from a failure body, under a length and
character allowlist, and `errorDescription` is discarded. `Retry-After` is
parsed only as a non-negative integer and capped at 300 seconds.
`outcomeUnknown` is set for a non-retryable method meeting `UPSTREAM_UNAVAILABLE`
or `RATE_LIMITED`. No change.

### S12: Redaction completeness (reviewed, no change needed)

A repository-wide sweep found one `SecretValue.reveal()` call in production code
outside `Auth/`: the `Authorization` header in `URLSessionWrikeTransport`, which
is the one place a token must be revealed. `RecordingTransport` records
`hasAuthorization` rather than any header value, so no test snapshot can hold a
token. A grep for `/Users/` and `/home/` across `Sources`, `Tests`,
`design-docs`, `README.md`, and `impl-plans` returns only the synthetic
`/Users/fixture` constant and the first pass's own description of it. The
reconciliation text added to the live-verification record names no account
value, identifier, or token. No change.

### S13: R11, repeated query-parameter ordering (still deferred)

The first pass deferred R11 pending evidence that a capability can bind a
repeated query parameter. Re-checked against the current registry: still no
capability binds a list to a non-joined `.query` parameter, so same-name query
items still cannot arise and the recorded-request assertions still could not
observe the ordering. No new evidence, so the deferral stands unchanged.

## Deliverables

- [x] `Sources/WrikeGatewayCore/Auth/LoopbackCallbackListener.swift`:
      terminated-request-line reading with a bounded accumulator (S1).
- [x] `Sources/WrikeGatewayCore/Auth/OAuthTokenExchange.swift`: refresh
      responses update rather than replace the stored record (S2).
- [x] `Sources/WrikeGatewayCore/Capabilities/CapabilityExecutor.swift`: the
      refreshed re-send does not spend a budgeted retry attempt (S3).
- [x] `Taskfile.yml`: `task test:live:read`, and a mutation warning on
      `task test:live` (S4).
- [x] `Tests/WrikeGatewayCoreTests/Auth/LoopbackCallbackListenerTests.swift`:
      three tests plus a chunked real-socket probe (S1).
- [x] `Tests/WrikeGatewayCoreTests/Auth/OAuthLoginFlowTests.swift`: four tests
      for the refresh merge and the unchanged code exchange (S2).
- [x] `Tests/WrikeGatewayCoreTests/Transport/TransportFailureTests.swift`: the
      refresh-versus-retry-budget test (S3).
- [x] `design-docs/specs/design-authentication.md`: the refresh merge rule, the
      retry-budget rule, and the request-line reading rule.
- [x] `design-docs/references/live-verification-2026-08-06.md`: reconciled (S5)
      with the login blocker (S7) recorded.
- [x] `README.md`: the read-only live command.

## Completion Criteria

- [x] Every finding has a severity and a disposition of fixed, rejected with
      rationale, reviewed with no change needed, or recorded as unresolved with
      the reason.
- [x] Each of the four named focus areas has an explicit disposition: S6 and S7
      for the live runner, S8 for catalog drift, S5 for the stale record, and
      S1, S2, S3, and S7 for the OAuth flow.
- [x] No finding repeats R1-R13, and R11's deferral is respected (S13).
- [x] Every accepted fix has a covering test, except S4 and S5, which are a
      task definition and a document; the filter granularity S4 depends on is
      proved by a control run instead.
- [x] `task build`, `task test`, and `swiftlint` pass.
- [x] Reader, writer, and admin schema output is byte-identical to the
      pre-change snapshot; the writer schema contains no delete mutation.
- [x] No GraphQL field name, error code, exit code, or environment variable name
      changed.
- [x] The staged `flake.lock` is unmodified and nothing is pushed.

## Progress Log

- 2026-08-06: Second review-and-improve pass completed.

  **Baseline.** On `1934c87`: `task build` clean, `task test` 313 tests in 44
  suites passed, `swiftlint` 0 violations in 99 files. Schema output captured
  for all three executables as the pre-change contract snapshot;
  `grep -cE '^\s+delete[A-Z]'` reported 0 delete mutations in the writer schema
  and 9 in the admin schema. `git status` showed only the pre-existing staged
  `flake.lock`.

  **Findings.** 13 recorded: 5 fixed (S1, S2, S3, S4, S5), 2 recorded as
  unresolved with the blocking reason (S6, S7), 1 rejected with rationale (S9),
  4 reviewed with no change needed (S8, S10, S11, S12), and 1 deferral carried
  forward unchanged (S13). Two were rated medium, both in the OAuth flow and
  both of the kind only a live run or a real socket would surface.

  **Live exercise.** None. Wrike credentials are absent from this environment;
  `kinko exec --force --env WRIKE_GATEWAY_ACCESS_TOKEN,WRIKE_GATEWAY_API_BASE_URL`
  answers `secret not found`. No request reached the Wrike account, and no
  create, update, or delete was attempted. The read-only test's isolation and
  the suite's clean skip were both demonstrated locally and are recorded in S6.

  **Verification.** `task build` clean. `task test`: 321 tests in 44 suites
  passed, up from 313; the 8 added tests are the covering tests for S1, S2, and
  S3. `swiftlint`: 0 violations in 99 files. Schema comparison:
  `swift run wrike-gateway-reader|writer|admin graphql schema` diffed against
  the baseline snapshot, all three byte-identical; the writer schema still
  contains 0 delete mutations and the admin schema 9. `git status --short`
  shows the pre-existing staged `flake.lock` unmodified.

  **Contract impact.** None. No field name, argument name, error code, exit
  code, or environment variable name changed. Two conditions that previously
  produced a wrong answer now produce a right one under existing codes: a
  split-segment callback delivers the whole authorization code instead of a
  truncated one, and a refresh response that omits an optional field keeps the
  stored value instead of clearing it or failing. `task test:live:read` is a new
  task, not a new flag or variable; no production binary gained an option.

  **Residual risks, recorded rather than closed.** The live E2E runner is still
  unexecuted end to end (S6), and a live OAuth login is still blocked on the
  client-secret mismatch (S7), so the authorization-code exchange and refresh
  rotation remain proved against injected transports and RFC 6749 rather than
  against `login.wrike.com`. S2's fallback behavior is therefore justified from
  the RFC and not confirmed against Wrike's actual refresh response shape; it is
  strictly safer than the previous behavior in either case, because it can only
  retain a value the record already held. S1's fix is proved over real loopback
  sockets with a deliberately split write, which is the closest available
  approximation of a browser that segments the request; a browser has not been
  observed doing it against this listener. R11 remains open by decision (S13).
</content>
</invoke>
