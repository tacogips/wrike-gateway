# Design: `WrikeGatewaySDK` facade on `GatewaySDKKit` (2026-09-04)

Implements `design-docs/briefs/gateway-sdk-2026-09-04.md` (one feature). Verified against
HEAD 98aaf40; baseline `arch -arm64 swift build` is green. The kit at
`/Users/taco/gits/tacogips/gateway-sdk-kit` is consumed read-only via a path dependency.

## 0. Scope and authority

This design is the Step 2 output for issue-resolution workflow
`codex-design-and-implement-review-loop-session-90`, intake communication
`comm-001038`. The package-local brief is the delivery contract; sections 2 and 3.1 of
`/Users/taco/gits/tacogips/riela/docs/briefs/gateway-sdk-2026-09-04.md` supply the
cross-repository architecture. `GatewaySDKKit`'s README and package brief define the
available shared API and are read-only references.

The work is exactly phase 1a for wrike-gateway. It does not modify the shared kit, the
main checkout at `/Users/taco/gits/tacogips/wrike-gateway`, typed clients, capability
definitions, transport/authentication policy, or packaging. There is no feature
fanout and no unresolved product decision requiring a user-QA document.

## 1. Package manifest

`Package.swift` adds:

- `dependencies: [.package(path: "../../gateway-sdk-kit")]` with a one-line comment that
  the operator switches this to a URL pin later.
- `.product(name: "GatewaySDKKit", package: "gateway-sdk-kit")` on the
  **`WrikeGatewayCore` target only**. Tier targets and executables see it transitively;
  the kit contains no gateway code, so `BinaryBoundaryTests` (manifest structure and
  linked symbols) must keep passing unchanged.

## 2. Catalog exporter — `Sources/WrikeGatewayCore/SDK/WrikeSchemaCatalogExporter.swift`

```swift
extension GatewaySchemaCatalog {
  public static func wrike(
    tier: CapabilityTier,
    definitions: [CapabilityDefinition]
  ) -> GatewaySchemaCatalog
}
```

Non-throwing: `GatewayTypeRef` values are built **structurally** (`.named`, `.list`,
`.nonNull`) from `ArgumentValueType`, `ModelFieldType`, and `ResultShape` cases — never
via `GatewayTypeRef.parse` — so no failure path exists. Definitions are filtered with
`tier.includes(definition.tier)` to mirror `CapabilityRegistry`.

Requiredness is represented in both places the kit model expects. First map the base
type without an outer required marker; when `ArgumentDefinition.isRequired` or
`ModelField.isRequired` is true, wrap that base reference in `.nonNull`. Operation and
input-object arguments also retain `GatewayArgument.isRequired = true`. This duplication
is intentional: kit validation consults the Boolean, while kit SDL and document variable
declarations render only `GatewayTypeRef.graphQLString`. Base mappers never add the outer
required wrapper, so a source value cannot become double-non-null.

Operations: `name = field`, `kind = operationClass.isMutation ? .mutation : .query`,
`tier = definition.tier.rawValue`, arguments mapped from `ArgumentDefinition`
(`graphQLTypeName` spelling, outer `.nonNull` when required, and the matching
`isRequired` Boolean), `result` from `ResultShape.graphQLTypeName` spellings (`X`,
`XConnection`, `[X!]!`, `XPayload`, `DeletionPayload`, `X!` for fileOutput), `summary`,
`isDestructive`. Arguments are sorted by name (printer order).

Named types (deduped by name, emitted sorted by name), mirroring
`GraphQLSchemaPrinter` emission rules exactly:

| Type | Condition | Shape |
| --- | --- | --- |
| `PageInfo` object | always | `resultCount: Int!`, `nextPageToken: String` |
| `DeletionPayload` object | any `.delete` definition | `deletedId: ID!` |
| `PageInput` input | any `.page` argument | `pageSize: Int`, `nextPageToken: String` |
| `ScopeInput` input | any `.scope` argument | 7 optional `ID` fields, sorted by rawValue |
| enums | `.enumeration` / `.enumerationList`, recursive through input objects | values verbatim |
| input objects | `.inputObject`, recursive | fields sorted by name; required fields use outer `.nonNull` and `isRequired` |
| result objects | `result.elementShape.reachableShapes` | `ModelField` → `GatewayField`; required fields use outer `.nonNull` |
| `<X>Connection` | `.connection` results | `nodes: [X!]!`, `pageInfo: PageInfo!` |
| `<X>Payload` | `.payload(field:_)` results | `<field>: X!` |

Catalog root: `provider = "wrike-gateway"`, `tier = tier.rawValue`
(`CapabilityTier: String` raw values are exactly `reader|writer|admin`).

## 3. Runtime access — `GatewayComposition`

Refactor `GatewayComposition.swift`:

- private `struct ComposedGraph { runtime, resolver, exchange, clock }` built by a
  private `compose(role:definitions:environment:) throws` holding today's exact wiring
  (registry → planner → `URLSessionWrikeTransport` → `KinkoCredentialStore` →
  `SystemClock` → `OAuthTokenExchange(.oauth)` → `CredentialResolver` →
  `CapabilityExecutor` → `GraphQLRuntime`).
- `public static func makeRuntime(role:definitions:environment: = ProcessEnvironmentReader()) throws -> GraphQLRuntime`
  returns `compose(...).runtime`. It does **not** resolve the OAuth callback port — that
  is a login-flow concern.
- `makeCommandFrame` calls `compose`, then resolves the callback port and builds
  `AuthCommands` exactly as today. Behavior byte-identical.

## 4. Value bridging — `Sources/WrikeGatewayCore/SDK/WrikeValueBridging.swift`

`WrikeValue` and `GatewayJSONValue` are case-isomorphic
(null/bool/int/double/string/array/object). Two total initializers:

```swift
extension GatewayJSONValue { public init(_ value: WrikeValue) }
extension WrikeValue { public init(_ value: GatewayJSONValue) }
```

Round-trip tests cover every case including int-vs-double edges (no coercion either way).

## 5. Facade — `Sources/WrikeGatewayCore/SDK/WrikeGatewaySDK.swift`

```swift
public struct WrikeGatewaySDK: GatewaySDK {
  public let provider = "wrike-gateway"
  public let tier: String                 // role.tier.rawValue
  public let catalog: GatewaySchemaCatalog
  public init(role: RoleDescriptor, definitions: [CapabilityDefinition]) throws
  public func execute(document:variables:environment:) async -> GatewayEnvelope
}
```

- `init` constructs a `CapabilityRegistry` (throws on incoherence / tier overflow) and
  builds the catalog from `registry.definitions`, so the catalog describes exactly what
  the runtime dispatches. Stores `role`, `definitions`, and a private
  `makeRuntime: @Sendable (any EnvironmentReader) throws -> GraphQLRuntime` seam
  (default: `GatewayComposition.makeRuntime`). An `internal init` exposing the seam is
  the test hook (`@testable import WrikeGatewayCore`); the public surface matches the
  brief exactly.
- `execute` builds the runtime with `StaticEnvironmentReader(extra: environment)`
  (the only environment the call may observe), bridges variables, awaits
  `GraphQLRuntime.execute`, and maps `GraphQLResponse` →
  `GatewayEnvelope(data: bridged, errors: [{message, code: error.code.rawValue}],
  requestId: requestID, exitCode: response.exitCode.rawValue,
  rawOutput: response.rendered(pretty: false))`. A composition throw becomes
  `GatewayEnvelope.failure(error, exitCode: (error as? GatewayError)?.exitCode.rawValue ?? 70)` —
  never a crash.
- `invoke`, `schemaSDL`, `searchSchema` come from the kit protocol extension
  (witness-dispatched defaults).
- Tier enforcement has two intentionally different entry-point results. A raw
  `execute` document naming a known higher-tier mutation reaches `CapabilityPlanner`
  and returns `CAPABILITY_DENIED`. A named `invoke` request is validated first against
  the tier-filtered catalog; therefore reader `invoke("createTask")` returns the kit's
  unknown-operation failure envelope with exit code 2 and does not reach the runtime.
  This preserves both the tier-filtered catalog and the required kit default methods;
  neither path can execute an unlinked capability.
- Per-tier constructors keep link boundaries:
  - `Sources/WrikeGatewayRead/SDK/WrikeGatewaySDKReader.swift`:
    `public static func reader() throws -> WrikeGatewaySDK` (`role: .reader`,
    `ReadCapabilities.all`).
  - `Sources/WrikeGatewayWrite/SDK/WrikeGatewaySDKWriter.swift`: `.writer()`.
  - `Sources/WrikeGatewayAdmin/SDK/WrikeGatewaySDKAdmin.swift`: `.admin()`.

## 6. CLI subcommands

`ParsedCommand` gains (both honor the existing global `--pretty`):

```swift
case graphQLSearch(pattern: String, kinds: [String]?, includeReferencedTypes: Bool,
                   limit: Int?, pretty: Bool)
case graphQLOperation(name: String, variables: Data?, variablesPath: String?,
                      select: [String]?, pretty: Bool)
```

Grammar (`CommandParser`): `graphql search <regex> [--kinds query,mutation,object,inputObject,enumeration]
[--include-referenced-types] [--limit N]`; `graphql operation <name>
[--variables '<json>' | --variables-file <path>] [--select a.b,c]`. `--limit` must parse
as a positive integer; `--variables` and `--variables-file` are mutually exclusive;
violations are `GatewayError.validation` (exit 2). Forbidden-flag policy unchanged.

The parser uses explicit subcommand option allowlists; recognizing a new option must
not make it legal elsewhere:

| Subcommand | Accepted options |
| --- | --- |
| `graphql query` | `--variables`, global `--pretty` |
| `graphql query-file` | `--variables-file`, global `--pretty` |
| `graphql schema` | global `--pretty` only, preserving its current harmless global behavior |
| `graphql search` | `--kinds`, `--include-referenced-types`, `--limit`, global `--pretty` |
| `graphql operation` | one of `--variables` or `--variables-file`, `--select`, global `--pretty` |
| `auth oauth2|status|logout` | global `--pretty` only, preserving current parsing behavior |

Value-taking options require exactly one following value and reject duplicates.
`--include-referenced-types` is valueless and rejects duplicates. `--kinds` splits a
non-empty comma list, trims entries, rejects empty or unknown entries, and deduplicates
known values as a set. `--select` splits a non-empty comma list, trims entries, and
rejects empty paths. Any recognized option outside its allowlist, any unknown option,
or any extra positional argument is a validation error; nothing is silently ignored.

Handlers live in a new `Sources/WrikeGatewayCore/CLI/CommandFrameSDKCommands.swift`
extension of `CommandFrame`; both derive the catalog from
`GatewaySchemaCatalog.wrike(tier: role.tier, definitions: runtime.registry.definitions)`:

- **search**: kind strings map through `GatewayDefinitionKind(rawValue:)` (unknown value
  → validation error naming the accepted set); `GatewaySchemaSearch.search`;
  `GatewaySDKError.invalidPattern` → validation error. Output
  `{"matches": [Match…], "count": N}` encoded with `JSONEncoder` using `.sortedKeys`
  (+ `.prettyPrinted` when `--pretty`), trailing newline, exit 0.
- **operation**: decode variables via the existing `CommandFrame.decodeVariables`,
  bridge to `GatewayJSONValue`; selection is `.fields(select)` when `--select` given,
  else `.default`; build with `GatewayDocumentBuilder(catalog:)`; any `GatewaySDKError`
  → `GatewayError.validation(String(describing:))` (exit 2). The built document and
  bridged-back variables run through the frame's **existing** `runGraphQL`, so output
  shape, credentials (process environment / kinko), and exit codes are identical to
  `graphql query`.

Decision (analysis open question 1): the CLI goes "through the facade" at the
document-building level (the identical kit code path `invoke` uses) but executes on the
frame's runtime. Routing through `WrikeGatewaySDK.execute` would rebuild the runtime
from a `StaticEnvironmentReader` and silently drop process-environment credential
resolution, breaking CLI credential parity with `graphql query`.

`usage` gains two lines for the new subcommands; existing lines and all existing
subcommand output stay byte-identical. `GatewayVersion` unchanged.

## 7. README

New "Client SDK" section: catalog → `searchSchema` → `invoke` Swift example on
`WrikeGatewaySDK.reader()`, raw `execute` example, per-tier constructor table, and docs
for `graphql search` / `graphql operation` with sample output.

## 8. Tests (swift-testing, existing targets)

- `Tests/WrikeGatewayTestSupport/SchemaNameSets.swift`: extracts root-field names and
  `type|input|enum` names from SDL text (works for both `printedSchema()` and
  `catalog.sdl()`).
- Per tier, in `WrikeGatewayReadTests` / `WriteTests` / `AdminTests` (`ReaderSDKTests.swift`
  etc.): name-set parity **both directions** between `GraphQLRuntime.printedSchema()`
  (runtime built with `RecordingTransport` seams) and `catalog.sdl()`;
  `catalog.validate() == []`; facade `invoke` for one query per tier and one mutation
  for writer/admin through the internal runtime seam with `RecordingTransport` +
  `StubCredentialProvider` + `TestClock`, asserting the built document declares its
  variables and the transport recorded the expected method/path/query; reader tier
  enforcement: raw `execute` of a `createTask` document → envelope error with code
  `CAPABILITY_DENIED`, while named `invoke("createTask")` → unknown-operation envelope
  with exit code 2 and no runtime call; `execute` passthrough: facade `rawOutput + "\n"`
  and exit code equal the `graphql query` CLI outcome for the same document/variables
  with identical seams and fixed request id.
- `Tests/WrikeGatewayCoreTests/SDK/`: bridging round-trips; exporter unit tests on
  small fixture definitions (conditional PageInput/ScopeInput/DeletionPayload emission,
  dedup, structural type refs). Exact assertions cover required operation arguments as
  `TaskCreateInput!`, required list arguments as `[ID!]!`, required input fields and
  model fields with one outer `!`, optional counterparts without `!`, and a built
  operation variable declaration that retains the required type.
- `Tests/WrikeGatewayCLITests/SDKCommandTests.swift`: `graphql search` JSON shape and
  regex/kind/limit errors; `graphql operation` happy path, `--select`, variable errors,
  unknown operation; duplicate, missing-value, irrelevant-option, empty-CSV, and extra-
  positional rejection; `--help` contains the new lines. Existing `graphql query`,
  `graphql query-file`, `graphql schema`, and auth parser/output suites must still pass
  unchanged.

## 9. Edge cases

- Duplicate result-shape names across definitions dedupe by name (printer semantics).
- Reader tier: no mutation ops, no `DeletionPayload`, no `Mutation` root in either SDL.
- `fileOutput` results reference `DownloadedFile` (emitted via `reachableShapes`).
- Enum name collisions between `.enumeration` and `.enumerationList` dedupe.
- `ScopeInput` field order matches the printer's sorted rendering.
- Non-gateway keys in the facade `environment` are ignored (`GatewayEnvironmentKey` is
  the closed read set); secrets never enter catalog, search output, or recorded requests.

## 10. Rollout / compatibility

Additive public API only; no changes to typed clients, capability definitions,
transport/auth, packaging, or existing CLI output. Commits land incrementally on
`feat/gateway-sdk` (no push), each leaving build/test/lint green, files < 1000 lines.

The local path dependency is an implementation-phase constraint, not the publication
shape. A later operator-owned phase replaces it with a URL and revision pin. That later
pin, any push, and any pull request are outside this issue-resolution package.

## 11. Behavioral data flow and trust boundaries

### Library invocation

1. A tier module constructs the facade with its cumulative capability definitions.
2. `CapabilityRegistry` rejects duplicate, incoherent, or above-tier definitions.
3. The catalog is exported from the registry's accepted definitions, so schema search,
   document construction, and runtime dispatch share one authorized name set.
4. `invoke` validates the named operation, variables, and selection through the kit,
   then forwards the built document and unchanged JSON values to `execute`.
5. `execute` creates a runtime for that call from `StaticEnvironmentReader(extra:)`.
   It cannot fall through to process environment values. The existing credential
   resolver, transport policy, capability planner, and GraphQL validator remain the
   enforcement boundary.
6. Runtime data and errors are converted case-for-case into `GatewayEnvelope` while
   preserving the request id, exit code, and compact rendered GraphQL envelope.

### CLI invocation

- `graphql query` and `graphql schema` retain their current parser, runtime, output, and
  credential behavior.
- `graphql operation` uses the exported catalog and kit document builder, then hands
  the built document and variables to the command frame's existing `runGraphQL` path.
  This preserves process-environment and kinko resolution and the established output
  and exit-code contract.
- `graphql search` is local and credential-free: it exports the tier catalog, applies
  the kit regex search, and emits a stable JSON result. It never contacts Wrike.

## 12. Validation and acceptance traceability

| Intake requirement | Design coverage | Required evidence |
| --- | --- | --- |
| Kit dependency belongs to Core only | Sections 1 and 10 | Manifest inspection and `BinaryBoundaryTests` |
| Lossless value bridging | Section 4 | Bidirectional case and nested-value round trips, including int/double identity |
| Tier-filtered structural catalog | Section 2 | Exporter fixtures, empty `validate()` findings, no type-string parser use |
| Runtime/catalog parity | Sections 2 and 8 | Bidirectional query, mutation, object, input, and enum name-set equality for all tiers |
| Raw and built operation execution | Sections 3, 5, and 11 | Recording-transport invocation, tier denial, and CLI/facade envelope parity |
| Existing binary boundaries | Sections 1 and 5 | Reader/writer/admin constructor placement and `BinaryBoundaryTests` |
| CLI grammar and compatibility | Sections 6 and 11 | Search/operation parser and handler tests plus unchanged query/query-file/schema/auth suites |
| User documentation | Section 7 | README examples for search, operation, raw execute, and tier constructors |
| Quality gates | Sections 8 and 10 | arm64 build/test, SwiftLint, line-count gate, and `git diff --check` |
| Authorized clean commit only | Section 10 | branch/status/commit inspection; no push |

## 13. Reference behavior and intentional divergences

No Cursor runtime, command protocol, configuration, or repository is part of this
feature. Shared-kit adaptation is isolated to `Sources/WrikeGatewayCore/SDK/`, while
CLI-specific translation is isolated to
`Sources/WrikeGatewayCore/CLI/CommandFrameSDKCommands.swift`; existing command-frame
behavior remains the compatibility baseline.

Intentional differences from the cross-repository master brief are:

- The public facade does not retain a construction-time environment. Environment is
  supplied per `execute`/`invoke` call, matching the implemented `GatewaySDK` protocol
  and preventing credential reuse across host calls.
- Public convenience construction is `.reader()`, `.writer()`, and `.admin()` in tier
  modules rather than a Core-level tier switch. This preserves binary link boundaries.
- Wrike names the new local search command `graphql search`, not `schema search`, to
  keep all Wrike GraphQL schema operations in the existing `graphql` command family.
- `graphql operation` shares the facade's catalog and document-building behavior but
  executes through the already-composed command-frame runtime. Calling facade
  `execute` here would replace the CLI environment with a fixed per-call reader and
  change credential resolution relative to `graphql query`.
- The brief's “reader SDK invoking `createTask`” shorthand is resolved by entry point:
  raw `execute` returns `CAPABILITY_DENIED`, while named `invoke` fails earlier as an
  unknown operation because the reader catalog is intentionally tier-filtered and the
  kit default is retained. This is an intentional diagnostic difference, not a tier-
  enforcement gap.

## 14. Risks and controls

- Catalog/runtime drift is controlled by exporting accepted registry definitions and
  comparing SDL name sets in both directions for every tier.
- Invalid or dangling catalog type references are controlled by structural type
  construction, explicit outer non-null wrapping, exact signature tests, and mandatory
  empty `catalog.validate()` results.
- Tier widening is controlled by registry validation, tier-owned constructors, a Core-
  only kit dependency, explicit reader denial tests, and existing link-boundary tests.
- Numeric coercion is controlled by exhaustive value bridges and int/double identity
  tests.
- Credential leakage is controlled by the facade's fixed environment reader and the
  closed `GatewayEnvironmentKey` set; search and catalog output contain no secrets.
- CLI behavior drift is controlled by routing built operations into the existing
  runtime/output path, subcommand option allowlists, and regression coverage for query,
  query-file, schema, and auth commands.
- The local dependency path and lack of publication are explicit rollout constraints;
  the worktree must end clean on `feat/gateway-sdk` and nothing is pushed.
