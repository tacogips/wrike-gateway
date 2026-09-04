# Implementation plan: `WrikeGatewaySDK` facade on `GatewaySDKKit`

**Status**: Regex safety follow-up verified and pending its authorized commit after security remediation implementation `1982392d58c3b0e0314775c5a9efc04cd0b7af2b`, following implementation commit `792c0054f368e0e4a32d8ecd602bf51a9b6c5303`; both follow reviewed revision `92085a37a24b278165abf0a9a80bae7989d750e4` over baseline implementation `bcc2da8e6e9b6ab811e89fe1efb060445c08bf27`. SwiftLint remains externally blocked by SourceKitten framework loading.
**Workflow Mode**: `issue-resolution`
**Workflow Execution**: `codex-design-and-implement-review-loop-session-90`
**Issue Reference**: `comm-001038`, `Add WrikeGatewaySDK facade on GatewaySDKKit`, branch `feat/gateway-sdk`
**Design Review**: `comm-001042`, decision `accepted_independent_design_review`; Step 3 handoff `comm-001044`; no findings or requested revisions
**Design Reference**: `design-docs/specs/design-gateway-sdk.md`
**Delivery Contract**: `design-docs/briefs/gateway-sdk-2026-09-04.md`

## Purpose

Finish exactly phase 1a of the gateway SDK brief by adding a tier-safe
`WrikeGatewaySDK` facade over the read-only `GatewaySDKKit`, a catalog exporter,
raw and named-operation execution, schema search, CLI access, focused tests, and
user documentation. Preserve existing Wrike runtime, authentication, transport,
typed-client, executable-link, and GraphQL CLI behavior.

Implementation is confined to
`/Users/taco/gits/tacogips/wrike-gateway-worktrees/gateway-sdk`. Do not modify or
build the main checkout at `/Users/taco/gits/tacogips/wrike-gateway`. Treat
`/Users/taco/gits/tacogips/gateway-sdk-kit` as a read-only local path dependency.
Do not push.

## Accepted behavior and divergences

The accepted design is authoritative if this plan and an older brief statement
differ. In particular:

- The facade receives environment values per `execute`/`invoke` call; it does not
  retain a construction-time environment and must not fall back to process values.
- Tier constructors remain in tier modules: `.reader()` in `WrikeGatewayRead`,
  `.writer()` in `WrikeGatewayWrite`, and `.admin()` in `WrikeGatewayAdmin`.
- The local CLI command is `graphql search`, not `schema search`.
- `graphql operation` uses the same kit catalog/document builder as facade
  invocation, then executes through the existing `CommandFrame.runGraphQL` path to
  preserve process-environment and kinko credential behavior.
- Reader raw `execute` of a known higher-tier operation reaches the full runtime
  schema and returns `CAPABILITY_DENIED`; reader named `invoke("createTask")` fails
  earlier against the tier-filtered catalog as unknown operation with exit code 2.
- No Cursor runtime, command protocol, configuration, or repository participates.
- The local path dependency is temporary. URL/revision pinning, publication, pull
  requests, and pushes are outside this work package.

## Deliverables

- [x] `Package.swift` links `GatewaySDKKit` only to `WrikeGatewayCore`.
- [x] `Sources/WrikeGatewayCore/SDK/WrikeValueBridging.swift` provides lossless,
  exhaustive `WrikeValue`/`GatewayJSONValue` conversion.
- [x] `Sources/WrikeGatewayCore/SDK/WrikeSchemaCatalogExporter.swift` exports a
  deterministic, tier-filtered, structurally typed catalog matching runtime SDL.
- [x] `Sources/WrikeGatewayCore/CLI/GatewayComposition.swift` exposes
  `makeRuntime` without changing `makeCommandFrame` behavior.
- [x] `Sources/WrikeGatewayCore/SDK/WrikeGatewaySDK.swift` conforms to `GatewaySDK`
  and maps runtime responses and failures to `GatewayEnvelope`.
- [x] Tier modules expose `.reader()`, `.writer()`, and `.admin()` without widening
  executable link boundaries.
- [x] CLI parsing and handlers support `graphql search` and `graphql operation`
  while preserving existing query, query-file, schema, auth, help, and output rules.
- [x] Core, tier, and CLI tests cover exporter correctness, SDL parity, invocation,
  tier enforcement, passthrough parity, grammar, and link boundaries.
- [x] `README.md` documents SDK construction, schema search, named invocation, raw
  execution, and the two CLI subcommands.
- [ ] All verification gates pass; Swift files remain below 1000 lines; authorized
  changes are committed on `feat/gateway-sdk`; the worktree is clean and unpushed.

## Task breakdown

### TASK-001 — Add the read-only kit dependency

**Write scope**: `Package.swift`; `Tests/WrikeGatewayCLITests/BinaryBoundaryTests.swift`
only if its manifest assertion explicitly requires the additive dependency.
**Depends on**: none.
**Parallelizable**: No; it establishes imports for later tasks.

Actions:

1. Add `.package(path: "../../gateway-sdk-kit")` with the accepted one-line note
   that an operator will replace it with a URL/revision pin later.
2. Add `.product(name: "GatewaySDKKit", package: "gateway-sdk-kit")` to the
   `WrikeGatewayCore` target only. Do not add it to tier or executable targets.
3. Inspect any boundary-test failure before changing tests; update only an obsolete
   dependency-list assertion, never the tier-symbol boundary.

Completion criteria:

- [x] The relative path resolves to the read-only sibling kit.
- [x] Core can import `GatewaySDKKit`; tier executables retain cumulative gateway-only
  dependencies and existing forbidden-symbol checks.
- [x] Build and `BinaryBoundaryTests` pass.

### TASK-002 — Add lossless value bridges

**Write scope**:
`Sources/WrikeGatewayCore/SDK/WrikeValueBridging.swift` and
`Tests/WrikeGatewayCoreTests/SDK/WrikeValueBridgingTests.swift`.
**Depends on**: TASK-001.
**Parallelizable**: Yes, with TASK-003 and TASK-004; write scopes are disjoint.

Actions:

1. Add public, total initializers in both directions for null, Boolean, integer,
   double, string, array, and object cases.
2. Preserve exact numeric cases; do not coerce `.int(3)` to `.double(3.0)` or the
   reverse.
3. Test both directional round trips for all cases, nested arrays/objects, and the
   integer/double edge.

Completion criteria:

- [x] The switch mappings are exhaustive and contain no lossy serialization hop.
- [x] All bridge tests pass under Swift 6 concurrency checking.

### TASK-003 — Export the tier-filtered schema catalog

**Write scope**:
`Sources/WrikeGatewayCore/SDK/WrikeSchemaCatalogExporter.swift`, an optional
responsibility-based helper such as
`Sources/WrikeGatewayCore/SDK/WrikeSchemaCatalogTypeRefs.swift`, and
`Tests/WrikeGatewayCoreTests/SDK/WrikeSchemaCatalogExporterTests.swift`.
**Depends on**: TASK-001.
**Parallelizable**: Yes, with TASK-002 and TASK-004; write scopes are disjoint.

Actions:

1. Add non-throwing
   `GatewaySchemaCatalog.wrike(tier:definitions:)`, filtering definitions with
   `tier.includes(definition.tier)`.
2. Map operation name, kind, minimum tier, sorted arguments, result, summary, and
   destructive flag exactly as accepted in design section 2.
3. Construct every `GatewayTypeRef` structurally with `.named`, `.list`, and
   `.nonNull`; do not call `GatewayTypeRef.parse`.
4. Apply requiredness once as the outer `.nonNull` and also set
   `GatewayArgument.isRequired` for operation/input arguments. Map optional forms
   without an outer non-null marker.
5. Emit deterministic, name-deduplicated and name-sorted types matching
   `GraphQLSchemaPrinter`: always `PageInfo`; conditional `DeletionPayload`,
   `PageInput`, and `ScopeInput`; recursive enums and input objects; reachable result
   objects; connection and payload wrappers. Preserve raw enum values and sorted
   field/argument order.
6. Add fixture tests for every argument/result-shape family, conditional emission,
   recursive discovery, deduplication, exact required/optional type spellings,
   document variable declarations, and `catalog.validate().isEmpty`.
7. Split helpers before a file approaches the 1000-line limit; keep responsibilities
   named rather than using numbered file fragments.

Completion criteria:

- [x] Catalog root is `provider: "wrike-gateway"`, `tier: tier.rawValue`.
- [x] Fixture catalogs validate with no findings and have no dangling type reference.
- [x] Required types include exactly one outer `!`; optional counterparts include none.
- [x] No parser-based type construction or order-dependent duplicate behavior exists.

### TASK-004 — Expose runtime composition without CLI drift

**Write scope**: `Sources/WrikeGatewayCore/CLI/GatewayComposition.swift` and focused
composition tests only if needed.
**Depends on**: TASK-001.
**Parallelizable**: Yes, with TASK-002 and TASK-003; write scopes are disjoint.

Actions:

1. Extract the existing registry/planner/transport/store/clock/token-exchange/
   resolver/executor/runtime wiring into a private `ComposedGraph` and private
   `compose(role:definitions:environment:)`.
2. Add public `makeRuntime(role:definitions:environment:)` returning only the runtime.
3. Keep callback-port resolution and `AuthCommands` construction inside
   `makeCommandFrame`; `makeRuntime` must not resolve a login-only callback port.
4. Preserve the existing OAuth-host transport separation, comments, credential
   resolver, and command-frame output behavior.

Completion criteria:

- [x] `makeRuntime` and `makeCommandFrame` share exactly one production object graph.
- [x] Existing CLI/core end-to-end tests remain byte-compatible.
- [x] Malformed callback-port handling remains a command/login concern, not an SDK
  runtime construction concern.

### TASK-005 — Implement the facade and tier constructors

**Write scope**:
`Sources/WrikeGatewayCore/SDK/WrikeGatewaySDK.swift`,
`Sources/WrikeGatewayRead/SDK/WrikeGatewaySDKReader.swift`,
`Sources/WrikeGatewayWrite/SDK/WrikeGatewaySDKWriter.swift`, and
`Sources/WrikeGatewayAdmin/SDK/WrikeGatewaySDKAdmin.swift`.
**Depends on**: TASK-002, TASK-003, TASK-004.
**Parallelizable**: Yes, with TASK-007 after both tasks' dependencies are met; scopes
are disjoint.

Actions:

1. Conform `WrikeGatewaySDK` to `GatewaySDK` with public provider, tier, catalog,
   public `init(role:definitions:)`, and `execute(document:variables:environment:)`.
2. Validate definitions through `CapabilityRegistry`; retain its accepted definitions
   for both catalog and runtime so schema and dispatch cannot drift.
3. Keep a private `@Sendable` runtime factory and an internal initializer exposing it
   only as an `@testable` deterministic seam.
4. Construct each call with `StaticEnvironmentReader(extra: environment)` so only
   caller-supplied values can be observed.
5. Bridge variables, await `GraphQLRuntime.execute`, and map data, error message/code,
   request ID, exit code, and compact `rendered(pretty: false)` output case-for-case.
6. Convert composition throws to `GatewayEnvelope.failure`; use a `GatewayError` exit
   code when available and internal-failure code 70 otherwise.
7. Rely on the kit protocol defaults for `invoke`, `schemaSDL`, and `searchSchema`.
8. Add constructors in their owning tier modules using cumulative capability arrays;
   do not add a Core-level tier switch.

Completion criteria:

- [x] Public API matches accepted design section 5 and contains no public test seam.
- [x] The runtime and catalog use the same registry-accepted definition set.
- [x] Per-call environment isolation and Sendable conformance compile cleanly.
- [x] Reader, writer, and admin constructors exist only in their permitted modules.

### TASK-006 — Prove parity, invocation, enforcement, and passthrough

**Write scope**:
`Tests/WrikeGatewayTestSupport/SchemaNameSets.swift`,
`Tests/WrikeGatewayReadTests/ReaderSDKTests.swift`,
`Tests/WrikeGatewayWriteTests/WriterSDKTests.swift`, and
`Tests/WrikeGatewayAdminTests/AdminSDKTests.swift`.
**Depends on**: TASK-005.
**Parallelizable**: Yes, with TASK-007; scopes are disjoint.

Actions:

1. Add a pure SDL name-set extractor for Query/Mutation fields and object/input/enum
   type names, usable against both runtime and kit SDL.
2. For reader, writer, and admin, compare runtime and catalog name sets for equality in
   both directions and assert `catalog.validate().isEmpty`.
3. Through `RecordingTransport`, `StubCredentialProvider`, `TestClock`, and fixed
   request IDs, invoke at least one query in every tier plus one writer mutation and
   one admin mutation. Assert variable declarations, HTTP method/path/query, successful
   envelope, and no unexpected transport call.
4. For reader tier, separately assert raw higher-tier execution returns
   `CAPABILITY_DENIED`, while named invocation returns unknown operation/exit 2 before
   runtime use.
5. Execute the same document and variables through the facade and existing
   `graphql query` command frame with identical seams; assert equal exit code and
   `facade.rawOutput + "\n" == cli.standardOutput`.

Completion criteria:

- [x] Parity covers query, mutation, object, input-object, and enum names for all tiers.
- [x] Default selections built by the kit are accepted by Wrike's runtime for the
  required query/mutation coverage.
- [x] Tier behavior and CLI/facade output parity match the intentional divergence.

### TASK-007 — Add catalog-backed CLI search and operation commands

**Write scope**:
`Sources/WrikeGatewayCore/CLI/CommandArguments.swift`,
`Sources/WrikeGatewayCore/CLI/CommandFrame.swift`,
`Sources/WrikeGatewayCore/CLI/CommandFrameSDKCommands.swift`,
`Tests/WrikeGatewayCLITests/SDKCommandTests.swift`, and focused parser tests under
`Tests/WrikeGatewayCoreTests/CLI/`.
**Depends on**: TASK-002, TASK-003.
**Parallelizable**: Yes, with TASK-005 and TASK-006 when their dependencies are met;
the declared source and test scopes are disjoint.

Actions:

1. Extend `ParsedCommand` and parsing for the exact accepted grammars:
   `graphql search <regex>` with `--kinds`, `--include-referenced-types`, `--limit`;
   and `graphql operation <name>` with one of `--variables`/`--variables-file` plus
   optional `--select`.
2. Replace the current global variable-option collection with explicit subcommand
   allowlists. Preserve global `--pretty`; reject duplicate flags, missing values,
   irrelevant/unknown options, extra positionals, non-positive limits, mutually
   exclusive variable sources, unknown/empty kind entries, and empty selection paths.
   Keep the forbidden-flag policy unchanged.
3. Map accepted kind strings through `GatewayDefinitionKind`. Convert invalid regex
   and all kit builder errors to `GatewayError.validation`/exit 2 with useful accepted
   values in diagnostics.
4. Produce search output as sorted-key JSON `{matches,count}`, optionally pretty, with
   one trailing newline and no credential or network access.
5. Decode operation variables through the existing decoder, build the document with
   the exported catalog and `GatewayDocumentBuilder`, bridge values back, and call the
   existing `runGraphQL` path. Widen only module-internal visibility required by the
   split-file extension; expose no new public CLI internals.
6. Add exactly the two accepted help lines. Do not change existing command text,
   version, output envelopes, or exit-code mapping.
7. Test happy paths and every parser/error rule, search filters/limit/invalid regex,
   operation selection and variable-file behavior, unknown operation, sorted/pretty
   output, help text, and regression behavior of query/query-file/schema/auth.

Completion criteria:

- [x] Search is deterministic, local, and tier-filtered.
- [x] Operation execution preserves `graphql query` credentials and envelope behavior.
- [x] Recognizing a new option never makes it legal for an unrelated subcommand.

### TASK-008 — Document the client SDK and CLI

**Write scope**: `README.md`.
**Depends on**: TASK-005, TASK-007.
**Parallelizable**: No; examples must reflect the final API and grammar.

Actions:

1. Add a Client SDK section with the constructor/product matrix and a Swift example
   covering catalog access, `searchSchema`, named `invoke`, variables, selection, and
   caller-scoped environment.
2. Add a raw `execute` example and explain its tier enforcement and envelope output.
3. Document `graphql search` and `graphql operation` with representative invocations
   and output, while retaining existing CLI/auth guidance.
4. State that the checked-in path dependency is development-only if dependency setup
   is shown; do not document URL pinning as already delivered.

Completion criteria:

- [x] Every brief deliverable has discoverable user-facing documentation.
- [x] Examples compile conceptually against the implemented API and do not expose
  credentials in output.

### TASK-009 — Run the full gate and finalize the authorized commit

**Write scope**: only fixes within TASK-001 through TASK-008 scopes, plus this plan's
progress log.
**Depends on**: TASK-006, TASK-007, TASK-008.
**Parallelizable**: No.

Actions:

1. Run focused tests after each task, then the exact full verification commands below.
2. Fix work-introduced build, test, lint, whitespace, boundary, and file-size failures.
3. Inspect the final diff for non-goals, secrets, accidental kit/main-checkout edits,
   and changes outside the authorized feature.
4. Update the progress log with each task's result, exact commands, and commit hashes or
   blockers. Mark this plan complete only when every completion criterion is evidenced.
5. Stage only authorized paths, create focused commit(s) on `feat/gateway-sdk`, verify
   clean status, and do not push.

Completion criteria:

- [ ] All focused and full gates pass with zero new lint violations.
- [x] Every non-generated Swift file is below 1000 lines.
- [x] The committed diff contains only the accepted feature, design, active/completed
  plan lifecycle update, tests, and README documentation.
- [x] `HEAD` is on `feat/gateway-sdk`, worktree is clean, and no push occurred.

## Dependencies and execution order

```text
TASK-001
  ├─ TASK-002 ─┐
  ├─ TASK-003 ─┼─ TASK-005 ─ TASK-006 ─┐
  └─ TASK-004 ─┘                       │
       TASK-002 + TASK-003 ─ TASK-007 ─┼─ TASK-008 ─ TASK-009
                                      └──────────────┘
```

Allowed parallel waves, only with separate implementers or carefully isolated edits:

1. After TASK-001: TASK-002, TASK-003, and TASK-004.
2. After TASK-002/TASK-003/TASK-004: TASK-005 and TASK-007.
3. After TASK-005: TASK-006 may overlap TASK-007.

Do not parallelize TASK-008 or TASK-009. If a task needs to touch another task's
declared write scope, serialize the work and record the dependency in the progress log.

## Verification commands

Run from
`/Users/taco/gits/tacogips/wrike-gateway-worktrees/gateway-sdk` in an arm64 shell
with the Xcode Swift toolchain explicit.

Focused gates:

```bash
/usr/bin/arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/wrike-gateway-worktrees/gateway-sdk && /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build'
/usr/bin/arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/wrike-gateway-worktrees/gateway-sdk && /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter BinaryBoundaryTests'
/usr/bin/arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/wrike-gateway-worktrees/gateway-sdk && /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WrikeValueBridgingTests'
/usr/bin/arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/wrike-gateway-worktrees/gateway-sdk && /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WrikeSchemaCatalogExporterTests'
/usr/bin/arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/wrike-gateway-worktrees/gateway-sdk && /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter SDKTests'
/usr/bin/arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/wrike-gateway-worktrees/gateway-sdk && /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter SDKCommandTests'
```

Full gates:

```bash
/usr/bin/arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/wrike-gateway-worktrees/gateway-sdk && /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build'
/usr/bin/arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/wrike-gateway-worktrees/gateway-sdk && /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test'
/usr/bin/arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/wrike-gateway-worktrees/gateway-sdk && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --no-cache'
git diff --check
git diff --cached --check
find Sources Tests -name '*.swift' -print0 | xargs -0 wc -l | sort -n | tail -20
git status --short --branch
git log -1 --oneline
```

If an exact Swift Testing filter matches no test, record that fact and rerun the
smallest matching suite by its emitted suite/test name; the unfiltered `swift test`
remains mandatory.

## Overall completion criteria

- [x] All accepted design requirements and brief deliverables 1–6 are implemented.
- [x] Catalog/runtime parity and empty catalog validation are proven for every tier.
- [x] Facade named and raw paths, environment isolation, error mapping, and tier
  divergence are verified through deterministic seams.
- [x] Existing typed clients, capability definitions, transport/auth policies,
  packaging, version, and legacy CLI output remain unchanged.
- [ ] `BinaryBoundaryTests`, full build/test, SwiftLint, whitespace, and file-size gates
  pass.
- [x] README and plan progress evidence are current.
- [x] Authorized commits exist on `feat/gateway-sdk`; the worktree is clean; no push or
  publication occurred.

## Risks and controls

- **Catalog/runtime drift**: export only registry-accepted definitions and compare SDL
  names bidirectionally for all tiers.
- **Invalid type graphs or double requiredness**: construct type refs structurally,
  test exact `!` spellings/document declarations, and require empty validation.
- **Tier widening**: keep the kit dependency in Core, constructors in tier modules,
  retain registry/planner enforcement, and run binary-boundary tests.
- **Credential leakage or fallback**: use only `StaticEnvironmentReader(extra:)` in
  facade calls; keep schema search local; assert secrets do not appear in outputs or
  recorded requests.
- **Caller-controlled regex CPU exhaustion**: validate the bounded schema-search
  subset before matching in both SDK and CLI paths; reject oversized patterns,
  backreferences, lookaround, inline options, and ambiguous quantification.
- **OAuth refresh-token rotation races**: coordinate refresh by durable credential
  record identity in the composition root, re-read the store inside the single-flight
  operation, and test separate facade runtime construction concurrently.
- **Uncertain mutation retries**: preserve a stable outcome-unknown error signal and
  recovery warning in `GatewayEnvelopeError`; retain the complete safe runtime error
  extensions in `rawOutput`. A future additive typed metadata field belongs in
  `GatewaySDKKit`, which this work package must not modify.
- **CLI regression**: use explicit option allowlists and the existing runtime/output
  path; retain focused regression coverage for every existing subcommand.
- **Numeric coercion**: map value cases directly and test integer/double identity.
- **Large exporter/parser edits**: split by responsibility before 1000 lines and run
  SwiftLint plus full tests.
- **Dependency portability**: keep the accepted local path and document later URL pin
  ownership; do not modify the kit or claim publication.
- **Dirty-worktree loss**: preserve the accepted untracked design document and this
  plan; stage only reviewed feature paths during finalization.

## Progress log expectations

Every implementation task must append a dated entry containing: task ID and status;
files changed; decisions or accepted-design interpretation; exact verification commands
and results; commit hash when committed; and any remaining blocker or risk. Never mark
a task complete on code inspection alone when its completion criteria require execution.

- 2026-09-04: TASK-PLAN completed. Step 3 acceptance `comm-001044` reviewed; active
  implementation plan created from `design-docs/specs/design-gateway-sdk.md`. No Step 5
  feedback existed to address. Implementation has not started.
- 2026-09-04: TASK-001 through TASK-008 completed. Added the Core-only local
  `GatewaySDKKit` dependency; lossless `WrikeValue`/`GatewayJSONValue` bridges;
  structural tier-filtered catalog export; shared `GatewayComposition` runtime graph;
  facade plus tier-module constructors; catalog-backed `graphql search` and
  `graphql operation`; focused bridge/exporter/parser tests; and README SDK/CLI docs.
  Focused verification passed:
  `/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
  and
  `/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WrikeValueBridgingTests|WrikeSchemaCatalogExporterTests|CommandGrammarTests'`.
- 2026-09-04: TASK-009 verification passed for the explicit arm64 build and full
  test suite (`325` tests, zero failures), targeted parser/exporter/bridge tests,
  manual reader `graphql search`, and manual unknown `graphql operation` validation.
  SwiftLint was attempted both through Xcode `xcrun swiftlint --no-cache` and
  `mise run lint`, but the installed SourceKitten process aborts before analysis with
  `sourcekitdInProc.framework` load failure; this is an environment/tooling blocker,
  not a reported source finding. Whitespace, file-size, diff, status, and commit
  evidence are recorded with finalization.
- 2026-09-04: Step 6 self-review revision: restricted `graphql search --kinds` to
  query, mutation, object, inputObject, and enumeration; added deterministic SDL
  parity, facade invocation, raw-envelope, environment-isolation, and CLI command
  suites; completed the SDK documentation examples and output; and reconciled the
  completion criteria above. `TASK-009` remains pending only on the recorded
  SourceKitten/SwiftLint environment failure; it is not marked complete until lint
  can execute or the workflow accepts that external blocker.
- 2026-09-04: Revision verification passed:
  `/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
  `/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test`
  (334 tests, zero failures), and focused `BinaryBoundaryTests`, `SDKTests`,
  `SDKCommandTests`, `WrikeValueBridgingTests`, and `WrikeSchemaCatalogExporterTests`.
  Invalid `command` and `scalar` search kinds now exit 2. SwiftLint was retried with
  `mise exec` plus the Xcode toolchain and remains externally blocked by
  `sourcekitdInProc.framework` loading before source analysis.
- 2026-09-04: Step 6 self-review follow-up completed the previously incomplete
  evidence. TASK-003 now fixtures every argument and result family, recursive
  input/object discovery, type-name deduplication, required/optional spellings,
  and built variable declarations. TASK-006 now invokes reader, writer, and admin
  queries plus writer/admin mutations with deterministic request/document checks.
  TASK-007 now covers invalid regexes, kinds, limits, duplicate/missing/irrelevant
  options, empty CSV values, variable-source conflicts, reference expansion,
  pretty/deterministic output, variable failures, and existing command regressions.
  Follow-up verification passed: explicit arm64 `swift build`; full `swift test`
  (`338` tests, zero failures); and focused `BinaryBoundaryTests`,
  `WrikeValueBridgingTests`, `WrikeSchemaCatalogExporterTests`, `SDKTests`, and
  `SDKCommandTests`. `git diff --check`, staged whitespace validation, and the
  Swift-file size gate also passed. SwiftLint again reached source enumeration but
  SourceKitten aborted before analysis while loading `sourcekitdInProc.framework`.
  TASK-009 remains pending only on that external SwiftLint blocker.
- 2026-09-04: Step 7 review follow-up corrected the public SDK documentation by
  importing `WrikeGatewayCore`, added smoke coverage for `.reader()`, `.writer()`,
  and `.admin()`, and aligned the search example with `^task$`, `query`, and
  `--limit 1` while labeling shortened SDL output. The baseline implementation
  commit is `bcc2da8e6e9b6ab811e89fe1efb060445c08bf27`; reviewed revision commit
  `92085a37a24b278165abf0a9a80bae7989d750e4` contains that follow-up. The explicit
  README typecheck probe, focused SDK suite, full Swift suite (`341` tests, zero
  failures), whitespace checks, and clean-worktree check are rerun for the reviewed
  revision. TASK-009 stays incomplete until the external SourceKitten/SwiftLint
  blocker is accepted or resolved.
- 2026-09-04: Step 7 credential and failure-envelope follow-up added the required
  `WRIKE_GATEWAY_API_BASE_URL` beside both documented permanent-token maps and a
  deterministic throwing-runtime-factory assertion for the facade envelope. This
  follow-up is applied after reviewed revision
  `92085a37a24b278165abf0a9a80bae7989d750e4`, which remains explicitly distinct
  from baseline implementation `bcc2da8e6e9b6ab811e89fe1efb060445c08bf27`. Full
  Swift tests pass (`342` tests in `51` suites, zero failures) and the README
  typecheck passes with both permanent-token values; whitespace and file-size gates,
  status, and SwiftLint are rerun. TASK-009 remains incomplete only because
  SourceKitten aborts before SwiftLint source analysis while loading
  `sourcekitdInProc.framework`.
- 2026-09-04: Adversarial-review security remediation after implementation commit
  `792c0054f368e0e4a32d8ecd602bf51a9b6c5303`: added bounded schema-regex admission
  to both CLI and SDK search; process-wide OAuth refresh single-flight coordination
  by credential record for facade-created runtimes; and a stable
  `*_OUTCOME_UNKNOWN` envelope-error code plus recovery warning while retaining full
  safe runtime extensions in `rawOutput`. Added deterministic CLI/SDK regex tests,
  separate-runtime OAuth concurrency coverage, writer/admin mutation transport-failure
  assertions, selection omission, and option-value validation coverage. TASK-009
  remains incomplete solely because SourceKitten aborts before SwiftLint source
  analysis. The completed remediation implementation is committed in
  `1982392d58c3b0e0314775c5a9efc04cd0b7af2b`.
- 2026-09-04: Step 6 self-review found that the initial regex policy still admitted
  separated overlapping quantifiers such as `.*.*.*.*.*.*.*.*Z`. The follow-up now
  allows at most one unbounded quantifier, so that family fails locally in both SDK
  and CLI search before catalog evaluation; 257-byte inputs also fail locally.
  Focused `ReaderSDKTests|SDKCommandTests`, explicit arm64 `swift build`, full
  explicit arm64 `swift test` (`346` tests in `51` suites), and the admin CLI timing
  probe pass. SwiftLint was retried but SourceKitten again aborted before source
  analysis; TASK-009 remains incomplete only for that external lint gate. The
  authorized follow-up commit remains pending.
