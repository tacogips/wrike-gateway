# Brief: `WrikeGatewaySDK` facade on `GatewaySDKKit` (2026-09-04)

Master design: `/Users/taco/gits/tacogips/riela/docs/briefs/gateway-sdk-2026-09-04.md`
(sections 2 and 3.1 are normative). The shared kit is implemented at
`/Users/taco/gits/tacogips/gateway-sdk-kit` (read its `README.md` and
`design-docs/briefs/gateway-sdk-kit-2026-09-04.md` for the exact API). Treat this whole
brief as exactly ONE feature.

## Goal

Give wrike-gateway a client SDK so that a caller (riela's add-on engine, or any Swift
host) can run an operation by name with variables and an optional selection, run raw
GraphQL with variables, print the schema, and regex-search it, all without writing
GraphQL text by hand and without widening the tier.

## Verified seams (2026-09-04, HEAD d607aaa)

- `Sources/WrikeGatewayCore/CLI/GatewayComposition.swift:20-24`
  `GatewayComposition.makeCommandFrame(role:definitions:environment:)` returns
  `CommandFrame`; `environment: any EnvironmentReader` (`StaticEnvironmentReader(extra:)`
  in `Auth/EnvironmentReader.swift:40-57` for per-call environments).
- `Sources/WrikeGatewayCore/CLI/CommandFrame.swift:66-80` `run(arguments:) async ->
  CommandOutcome { standardOutput, standardError, exitCode }`; `graphql schema` dispatch at
  `:85-91`; `runtime` is private (`:36-39`).
- `Sources/WrikeGatewayCore/GraphQL/GraphQLRuntime.swift:41` `public struct
  GraphQLRuntime`, `:58 printedSchema()`, `:62 execute(document:variables: [String:
  WrikeValue]) async -> GraphQLResponse { data: WrikeValue?, errors: [GatewayError],
  requestID }`; variable validation `:119-148` (declared-unused, used-undeclared, unknown
  supplied, required non-null).
- `Sources/WrikeGatewayCore/GraphQL/GraphQLSchemaPrinter.swift:15-22` prints SDL from the
  registry (header, `PageInfo`/`DeletionPayload`, input types, object types, `Query`,
  `Mutation`).
- `Sources/WrikeGatewayCore/Capabilities/CapabilityDefinition.swift`: `ArgumentBinding`
  (:4), `ArgumentValueType` (:34, incl. `.enumeration(name, values)`,
  `.enumerationList`, `.inputObject(InputObjectShape)`; `graphQLTypeName` :51),
  `ArgumentDefinition` (:69, `name/type/binding/isRequired`), `InputObjectShape` (:96),
  `ScopeInput` (:112), `CapabilityDefinition` (:162: `id, field, tier, operationClass,
  method, pathTemplate, scopeVariants, arguments, result: ResultShape, summary,
  isDestructive`).
- `Capabilities/CapabilityRegistry.swift:18-59` (`init(tier:definitions:)`,
  `queryDefinitions`, `mutationDefinitions`).
- Tier aggregates: `Sources/WrikeGatewayRead/Schema/ReadCapabilities.swift:10-24`
  (`ReadCapabilities.all`, 33 queries), `Sources/WrikeGatewayWrite/Schema/WriteCapabilities.swift:12-15`
  (`WriteCapabilities.all = ReadCapabilities.all + 27 mutations`; `assertNoDestructiveCapability`
  :23-36), `Sources/WrikeGatewayAdmin/Schema/AdminCapabilities.swift:7` (`+ DeleteCapabilities.all`, 9 deletes).
- Typed clients already exist and stay untouched: `WrikeReadClient`
  (`Sources/WrikeGatewayRead/Schema/WrikeReadClient.swift:10`), `WrikeWriteClient`
  (`WriteCapabilities.swift:41`), `WrikeAdminClient` (`AdminCapabilities.swift:20`).
- Link boundaries are asserted by `Tests/WrikeGatewayCLITests/BinaryBoundaryTests.swift`;
  `Package.swift` products are cumulative (Core, Read, Write, Admin) plus three executables.
- Tests are swift-testing; `Tests/WrikeGatewayTestSupport` provides `RecordingTransport`,
  `LoopbackHTTPServer`, `E2EScenarioCatalog`, `ParityHarness`.
- riela calls this package from
  `/Users/taco/gits/tacogips/riela/Sources/RielaCLI/ProductionNodeAdapter+WrikeGatewayAddons.swift:78-101`
  (`makeCommandFrame` + `frame.run(["graphql","query",doc,"--variables",json])`). It will
  switch to the facade; keep `makeCommandFrame` and the CLI unchanged.

## Deliverables

1. **Dependency.** `Package.swift`: add `.package(path: "../../gateway-sdk-kit")`
   (this worktree lives at `/Users/taco/gits/tacogips/wrike-gateway-worktrees/gateway-sdk`,
   so the relative path resolves to `/Users/taco/gits/tacogips/gateway-sdk-kit`) and the
   product `GatewaySDKKit` as a dependency of `WrikeGatewayCore` only (the tier targets
   see it transitively). The operator switches this to a URL pin later; leave a one-line
   comment saying so.
2. **Catalog export** (`Sources/WrikeGatewayCore/SDK/WrikeSchemaCatalogExporter.swift`):
   `extension GatewaySchemaCatalog { static func wrike(tier: CapabilityTier, definitions:
   [CapabilityDefinition]) -> GatewaySchemaCatalog }` mapping each definition to a
   `GatewayOperation` (`name = field`, kind from `operationClass` (query vs mutation),
   `tier` = `tier.rawValue`-style string `reader|writer|admin`, arguments via
   `ArgumentValueType` → `GatewayTypeRef` (use `graphQLTypeName` / `isRequired`),
   `result` from `ResultShape`, `summary`, `isDestructive`), and emitting the named types
   the existing `GraphQLSchemaPrinter` prints (`PageInfo`, `DeletionPayload`, `ScopeInput`,
   `PageInput`, input objects, enums, result objects). The exporter and the printer must
   agree: a test compares the root field names and input/object type names of
   `GraphQLRuntime.printedSchema()` with `catalog.sdl()` for every tier. `catalog.validate()`
   must be empty for every tier.
3. **Runtime access.** `GatewayComposition.makeRuntime(role:definitions:environment:)
   throws -> GraphQLRuntime` (same wiring `makeCommandFrame` uses; `makeCommandFrame`
   is refactored to call it). `WrikeValue` ⇄ `GatewayJSONValue` conversion helpers
   (`Sources/WrikeGatewayCore/SDK/WrikeValueBridging.swift`) with round-trip tests.
4. **Facade** (`Sources/WrikeGatewayCore/SDK/WrikeGatewaySDK.swift`):
   ```swift
   public struct WrikeGatewaySDK: GatewaySDK {
     public let provider = "wrike-gateway"
     public let tier: String                 // "reader" | "writer" | "admin"
     public let catalog: GatewaySchemaCatalog
     public init(role: RoleDescriptor, definitions: [CapabilityDefinition]) throws
     public func execute(document:variables:environment:) async -> GatewayEnvelope
   }
   ```
   `execute` builds the runtime for the given `environment` (via `StaticEnvironmentReader`),
   calls `GraphQLRuntime.execute`, and maps `GraphQLResponse` to `GatewayEnvelope`
   (`data`, `errors` with `code`, `requestId`, `exitCode` from `GraphQLResponse.exitCode`,
   `rawOutput` = `rendered(pretty: false)`). Per-tier constructors live in the tier
   modules so link boundaries hold: `WrikeGatewaySDK.reader()` in `WrikeGatewayRead`,
   `.writer()` in `WrikeGatewayWrite`, `.admin()` in `WrikeGatewayAdmin`.
   `invoke`, `schemaSDL`, `searchSchema` come from the kit defaults.
5. **CLI.** New subcommand `graphql search <regex> [--kinds query,mutation,object,inputObject,enumeration]
   [--include-referenced-types] [--limit N]` printing the kit's matches as JSON (`{matches:
   [...], count}`), and `graphql operation <name> [--variables <json> | --variables-file <path>]
   [--select a.b,c]` running an operation through the facade. `graphql query` and
   `graphql schema` unchanged. Update `--help` and `README.md` (SDK section with a Swift
   example: catalog → search → invoke, plus raw `execute`).
6. **Tests** (swift-testing, existing targets): exporter parity per tier; validate()
   empty; facade `invoke` for one query and one mutation per tier through
   `RecordingTransport` asserting the built document declares variables and the transport
   saw the expected HTTP request; tier enforcement (a reader SDK invoking `createTask`
   yields a `CAPABILITY_DENIED`-style envelope error, not a crash); `execute` passthrough
   equals `graphql query` CLI output for the same document; `graphql search` CLI; link
   boundary tests still pass (the kit contains no tier code, so reader binaries must not
   gain writer symbols).

## Verification

`arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/wrike-gateway-worktrees/gateway-sdk && swift build && swift test && swiftlint'`
green. Commit on `feat/gateway-sdk` in this worktree as work lands; do not push.

## Non-goals

No changes to `WrikeReadClient`/`WriteClient`/`AdminClient`, to capability definitions,
to transport/auth, or to the Homebrew packaging. Do not touch
`/Users/taco/gits/tacogips/wrike-gateway` (the main checkout).
