# Wrike Gateway Review and Improve

**Status**: Completed
**Design Reference**: `design-docs/specs/design-wrike-api-client.md#binary-response-bodies`,
`design-docs/specs/design-wrike-api-client.md#error-mapping`,
`design-docs/specs/design-graphql-contract.md#initial-parser-scope`
**Created**: 2026-08-05
**Last Updated**: 2026-08-05

## Purpose

Review the completed initial implementation
(`impl-plans/completed/wrike-gateway-initial-implementation.md`, 15 commits,
269 tests) for defects and worthwhile improvements, decide each of the four
residual risks that plan recorded rather than closed, and implement the accepted
findings with covering tests.

This is a review-and-improve pass over working code. The accepted architecture
is not restructured: four cumulative library targets, three tier-scoped
executables, protocol-based `WrikeTransport` injection, and the project-owned
GraphQL contract are all unchanged.

## Scope

### Included

- The four recorded residual-risk candidates, each with an explicit decision.
- A correctness, concurrency, parser, error-mapping, redaction, coverage, and
  doc-drift sweep over `Sources/` and `Tests/`.
- Covering tests for every accepted finding.
- `design-docs/specs/design-wrike-api-client.md` and `README.md` updates where
  behavior changed.

### Excluded

- Any change to a GraphQL field name, argument name, error code, exit code, or
  environment variable name.
- Any weakening of a capability-tier boundary, a redaction rule, or a
  destructive-operation safeguard.
- Live Wrike account or OAuth exercise, which still needs an operator session
  and a registered application.
- The pre-existing staged `flake.lock`, which is untouched.

## Findings

Severity is the effect on a caller: **high** silently misreports an outcome,
**medium** costs an operator a diagnosis, **low** is correctness or hygiene with
no wrong answer reaching a caller.

### R1: A body-less success wrote a zero-byte file (high, fixed)

`ResponseSinkDelivery` treated every `2xx` with a file sink as content, so a
`204` produced a zero-byte file and a `DownloadedFile` reporting `byteCount: 0`.
A caller could not distinguish that from a completed transfer of an empty
attachment. Wrike documents binary content on both file-output routes, so a
body-less success is a contract violation.

Fixed: `204` and `205` with a file sink now write no file and attach no
`downloadedFile`, and `ResponseProjection` reports the existing
`UPSTREAM_RESPONSE_INVALID` (exit `4`) with guidance naming that nothing was
written. No new error code was introduced. The rule is deliberately limited to
the statuses that *define* an absent body rather than to any empty success body,
because an attachment whose stored content is genuinely empty must still be
delivered as a `200`.

Tests: `ResponseSinkDeliveryTests.noContentSuccessWritesNothing` (both entry
points, `204` and `205`), the delivery status table (now three outcomes:
written, refused-and-retained, body-less), and
`AttachmentTransferTests.noContentSuccessIsReported` end to end for both
file-output capabilities.

### R2: A truncated download was accepted as complete (high, fixed)

The gateway did not compare a download's declared length against the bytes
written; it relied on the transport to surface truncation. A short body that
still completed at the socket level therefore landed as a complete file.

Fixed: both delivery entry points compare `Content-Length` against the bytes
delivered and refuse a mismatch as `TransportFailure.malformedResponse`, mapped
to `TRANSPORT_FAILED` (exit `5`). Nothing is written and the streamed temporary
copy is removed, so a refused transfer leaves no partial file.

The check is guarded so it cannot reject a complete download. It is off when the
header is absent, unparsable, or negative, which is what a chunked response looks
like, and off for a content-encoded body, whose declared length counts encoded
bytes while the delivered file holds decoded ones.

Tests: `ResponseSinkDeliveryTests.refusesTruncatedDownload`,
`.truncationRefusalIsSafe` (the refusal is non-transient and quotes no body
content), `.tolerateIncomparableLength` over five header shapes,
`.acceptsMatchingLength`, and `AttachmentTransferTests.truncatedBodyIsRefused`
end to end for both capabilities.

### R3: A refused preview named the wrong cause (medium, fixed)

`attachments.preview` for a type that has no preview is refused upstream exactly
as a missing attachment is, so `NOT_FOUND` on its own sent an operator looking
for a wrong identifier with no hint that the type was the cause.

Fixed as guidance only. `CapabilityDefinition` gained an optional
`upstreamRejectionGuidance`, applied by the executor to `NOT_FOUND` and
`VALIDATION_ERROR` when the mapped error carries no guidance of its own.
`attachments.preview` declares it; it names the preview-less type and points at
`attachmentDownload`. No response state, field, code, or status changed.

Tests: `AttachmentTransferTests.refusedPreviewGuidesTheOperator` (guidance
reaches the stable `extensions.recovery` payload) and `.previewGuidanceStaysScoped`
(a `404` on `attachmentDownload` gets none, and a `429` on preview keeps the
rate-limit remedy the mapper already supplied).

### R4: A machine-local path in the completed plan (low, fixed)

`impl-plans/completed/wrike-gateway-initial-implementation.md:1113` recorded
`kinko_dir="/Users/taco/.local/kinko"`. Generalized to `$HOME/.local/kinko`. The
factual record is otherwise untouched. A repository-wide grep for `/Users/` and
`/home/` now returns only `Tests/.../KinkoCredentialStoreTests.swift:105`, a
synthetic `/Users/fixture` string that names no real machine.

### R5: Surrogate-pair escapes were rejected (low, fixed)

`GraphQLLexer` decoded a `\u` escape as a single scalar, so `Unicode.Scalar`
returned `nil` for either half of a surrogate pair and a document containing an
escaped non-BMP character, such as an emoji in a task title, was rejected as
invalid. GraphQL requires that syntax.

Fixed: `readUnicodeEscape` pairs a leading surrogate with the escape that
follows it and combines them. A lone surrogate, a mismatched pair, and a
truncated or non-hex escape all remain rejected.

Tests: `GraphQLParserScopeTests.decodesStringEscapes` and
`.rejectsMalformedUnicodeEscape` over six malformed shapes.

### R6: Variable-rejection messages were nondeterministic (low, fixed)

`GraphQLRuntime.validateVariables` reported the first name from a `Set`
difference. Set iteration order varies between processes, so the same rejected
document could name a different offending variable on each run, which makes an
error report irreproducible.

Fixed: each set is sorted before it is reported. Test:
`GraphQLPreNetworkValidationTests.variableRejectionIsDeterministic` runs the same
three-variable document eight times and requires the same name each time.

### R7: `await try` ordering produced 22 build warnings (low, fixed)

Four test files wrote `await try` where Swift wants `try await`. Mechanical
reordering with no behavior change; the build is now warning-free.

### R8: Single-flight refresh (reviewed, no change needed)

`CredentialResolver.refreshState` was checked for the reentrancy hazard the
pattern invites. The `refreshInFlight` task is assigned synchronously after
creation with no suspension between, so a second caller entering the actor always
observes it and awaits the same result rather than spending the rotated refresh
token twice. The `defer` that clears it cannot clear a newer task, because a newer
one can only be created while the slot is `nil`. No change.

### R9: Parser loop termination (reviewed, no change needed)

Every `while token != .punctuator(...)` loop in `GraphQLParser` was checked for a
non-terminating path on a truncated document. Each either tests `.endOfDocument`
explicitly or fails its next `guard` at end of input, so a malformed document
always terminates in a validation error. No change.

### R10: Redirect and host policy (reviewed, no change needed)

`RedirectGuard` re-sets the authorization header only for a same-host HTTPS
redirect to an approved host and otherwise refuses the redirect, which drops the
credential with it. `WrikeHostPolicy` rejects user information, query, and
fragment in a configured base URL. No change.

### R11: Query-item ordering with repeated names (low, deferred)

`RequestBuilder` sorts query items by name only, and Swift's sort is not
documented as stable, so two items sharing a name could in principle be emitted
in either order. No current capability binds a list to a non-joined `.query`
parameter, so no registered capability can produce same-name items today, and the
recorded-request assertions cannot observe it. Deferred rather than fixed: adding
a value tiebreak now would change the sort for a case that cannot arise, and the
coherence tests would not prove the change was needed. Revisit if a capability
ever binds a repeated query parameter.

### R12: Credential-state caching across processes (low, rejected)

`CredentialResolver.loadState` caches the loaded record for the process lifetime
and does not invalidate when another process rewrites the store. Rejected as a
speculative fix: each CLI invocation is a short-lived process, `refreshedCredential`
already re-reads the store before spending a refresh token and reuses a newer
committed record when it finds one, and adding invalidation would need a change
detection mechanism the store does not expose. No behavior is wrong today.

### R13: Preview guidance in the printed schema (rejected)

Adding the preview-availability caveat to `attachments.preview`'s `summary` was
considered and rejected. `summary` is printed as the field's schema description,
so it would change the schema output the acceptance criteria require to be
comparable. The guidance was put where it is actually read, at failure time in
the error's `recovery` extension, and all three schemas stay byte-identical.

## Deliverables

- [x] `Sources/WrikeGatewayCore/Transport/ResponseSinkDelivery.swift`: truncation
      check and body-less-success refusal, both entry points.
- [x] `Sources/WrikeGatewayCore/Capabilities/ResponseProjection.swift`: guidance
      on the no-content projection failure.
- [x] `Sources/WrikeGatewayCore/Errors/GatewayError.swift`:
      `withRecoveryGuidance(_:)`, which never overwrites existing guidance.
- [x] `Sources/WrikeGatewayCore/Capabilities/CapabilityDefinition.swift`:
      `upstreamRejectionGuidance` and its code-scoped accessor.
- [x] `Sources/WrikeGatewayCore/Capabilities/CapabilityExecutor.swift`: applies
      declared guidance to a mapped upstream error.
- [x] `Sources/WrikeGatewayRead/Attachments/AttachmentCapabilities.swift`:
      preview guidance.
- [x] `Sources/WrikeGatewayCore/GraphQL/GraphQLLexer.swift`: surrogate-pair
      escapes.
- [x] `Sources/WrikeGatewayCore/GraphQL/GraphQLRuntime.swift`: deterministic
      variable rejection.
- [x] Tests in `WrikeGatewayCoreTests` and `WrikeGatewayReadTests` for every
      accepted finding.
- [x] `design-docs/specs/design-wrike-api-client.md` and `README.md` updated.

## Completion Criteria

- [x] Every finding has a severity and a disposition of fixed, rejected with
      rationale, or deferred with reason.
- [x] Each of the four recorded residual risks has an explicit decision: R1, R2,
      R3, and R4 above.
- [x] Every accepted fix has a covering test.
- [x] `task build`, `task test`, `swift test`, and `swiftlint` pass.
- [x] Reader, writer, and admin schema output is byte-identical to the
      pre-change snapshot; the writer schema contains no delete mutation.
- [x] No error code, exit code, or environment variable name changed.
- [x] The staged `flake.lock` is unmodified and nothing is pushed.

## Progress Log

- 2026-08-05: Review-and-improve pass completed.

  **Baseline.** `task build`, `task test` (269 tests in 40 suites passed),
  `swiftlint` (0 violations in 95 files) on `d7e1a26`. Schema output captured for
  all three executables as the pre-change contract snapshot.

  **Findings.** 13 recorded: 7 fixed (R1, R2, R3, R4, R5, R6, R7), 3 reviewed
  with no change needed (R8, R9, R10), 1 deferred (R11), 2 rejected (R12, R13).
  Two were rated high severity, both silent misreports of a download outcome.

  **Verification.** `task build` and `swift build --build-tests` clean with 0
  warnings, down from 22. `task test` and `swift test`: 281 tests in 40 suites
  passed, up from 269; the 12 added tests are the covering tests for R1, R2, R3,
  R5, and R6. `swiftlint`: 0 violations in 95 files. Schema comparison:
  `swift run wrike-gateway-reader|writer|admin graphql schema` diffed against the
  step-1 snapshot, all three byte-identical; `grep -cE '^\s+delete[A-Z]'` reports
  0 delete mutations in the writer schema and 9 in the admin schema, unchanged.
  Repository-wide grep for `/Users/` and `/home/` returns only the synthetic
  `/Users/fixture` test constant. `git status --short` shows the pre-existing
  staged `flake.lock` unmodified.

  **Contract impact.** None. No field name, argument name, error code, exit code,
  or environment variable name changed. Two conditions that previously produced a
  wrong success now produce existing codes: a body-less binary success reports
  `UPSTREAM_RESPONSE_INVALID` and a length-mismatched download reports
  `TRANSPORT_FAILED`. `CapabilityDefinition` gained one optional initializer
  parameter with a default, so no existing registration changed.

  **Residual risks, still recorded rather than closed.** The live Wrike
  authorization exchange and refresh rotation against `login.wrike.com` remain
  unexercised, and no capability has been exercised against a real Wrike account:
  every route, envelope kind, and field set is verified against the official
  reference and replayed through canned responses. The truncation check is proved
  against canned and delivered responses, not against a socket that closes early,
  because the loopback server always sends the length it declares; the guarded
  conditions under which the check stays off are proved directly. Wrike's exact
  status for a preview-less attachment type is not confirmed against a live
  account, so R3's guidance is attached to both `NOT_FOUND` and
  `VALIDATION_ERROR` to cover either documented refusal shape. R11 remains open by
  decision.
