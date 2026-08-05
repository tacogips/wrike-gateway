# Wrike Gateway Initial Implementation

**Status**: Completed
**Design Reference**: `design-docs/specs/architecture.md#swiftpm-target-layout`,
`design-docs/specs/architecture.md#request-data-flow`,
`design-docs/specs/command.md#common-command-surface`,
`design-docs/specs/design-wrike-api-client.md#transport-contract`,
`design-docs/specs/design-graphql-contract.md#role-specific-schemas`,
`design-docs/specs/design-capability-matrix.md#resource-by-operation-matrix`,
`design-docs/specs/design-authentication.md#oauth2-authorization-code-flow`,
`design-docs/specs/design-authentication.md#oauth-callback-tls-identity`
**Created**: 2026-08-05
**Last Updated**: 2026-08-05

## Purpose

Replace the `AppCore`/`AppCLI` scaffold with the accepted Swift SDK and three
capability-scoped CLI products for Wrike API v4. The implementation must keep
REST details behind typed adapters, expose the project-owned GraphQL contract,
support OAuth2 and permanent-token credentials without secret disclosure, and
prove through package-boundary tests that reader and writer binaries cannot
link higher-tier capability code.

This plan uses the accepted design as its source of truth. Upstream Wrike
operations, scopes, data-center hosts, plan restrictions, and downloadable
OpenAPI metadata must be revalidated at implementation time before a capability
is marked implemented.

## Scope

### Included

- SwiftPM products and targets `WrikeGatewayCore`, `WrikeGatewayRead`,
  `WrikeGatewayWrite`, and `WrikeGatewayAdmin`.
- Executables `wrike-gateway-reader`, `wrike-gateway-writer`, and
  `wrike-gateway-admin` with thin target-specific entry points.
- Protocol-based live and test transports, stable models, pagination, error
  mapping, retry limits, and canned Wrike response fixtures.
- The constrained GraphQL parser, validator, role-specific schema registry,
  capability planner, executor, projection, JSON envelope, and CLI commands.
- Reader coverage for contacts, users, groups, accounts/spaces,
  folders/projects, tasks, comments, attachments, timelogs, custom fields,
  workflows, and webhooks.
- Writer create/update coverage and admin-only reviewed DELETE coverage from
  the accepted capability matrix.
- OAuth2 authorization-code and refresh handling through kinko-managed client
  configuration from `WRIKE_GATEWAY_API_CLIENT_ID` and
  `WRIKE_GATEWAY_API_CLIENT_SECRET`, protected token storage, and permanent
  token mode through `WRIKE_GATEWAY_ACCESS_TOKEN` with mandatory
  `WRIKE_GATEWAY_API_BASE_URL`.
- Unit, contract, loopback-server, CLI, redaction, and link-boundary tests.

### Excluded

- Hosting webhook callbacks or adding a webhook-delivery executable.
- Raw REST, arbitrary URL, arbitrary GraphQL passthrough, or full generated
  OpenAPI schema exposure.
- Automatic retries for mutations, token exchanges, refresh rotation, or
  attachment uploads without a separately reviewed idempotency guarantee.
- Homebrew formula, Cask, signing, notarization, upload, commit, or push work;
  those require separate release execution after all products are verified.
- Resolving pending product decisions by deleting their files. Until the user
  decides, use the documented conservative defaults and keep the questions
  visible under `design-docs/user-qa/`.

## Accepted Reference Traceability

| Reference behavior | Concrete reference | Planned adaptation |
| --- | --- | --- |
| Direct GraphQL command and local schema surface | `../x-gateway/design-docs/specs/design-graphql-command-surface.md`; `../x-gateway/design-docs/specs/design-public-graphql-contract.md`; `../x-gateway/Sources/XGatewayCore/XGatewayGraphQLSchema.swift` | Preserve the `graphql query` and `graphql schema` shape while implementing a Wrike-owned schema and constrained parser. |
| Capability inventory and route planning | `../x-gateway/design-docs/specs/design-api-inventory.md`; `../x-gateway/Package.swift`; `../x-gateway/Sources/XGatewayRead/main.swift`; `../x-gateway/Sources/XGatewayWrite/main.swift` | Use stable capability identifiers and link-separated tiers; add the Wrike-specific admin tier and four cumulative SDK modules. |
| Thin multi-executable command frame | `../apple-gateway/Package.swift`; `../apple-gateway/Sources/AppleGatewayCLI/main.swift`; `../apple-gateway/Sources/AppleGatewayReaderCLI/main.swift`; `../apple-gateway/Sources/AppleGatewayCore/CLI/Command.swift` | Keep each Wrike executable entry point limited to role selection and delegation, while enforcing role capability at link time instead of only at runtime. |

Intentional divergences accepted by the design are mandatory: model Wrike's
account/space/folder/project/task hierarchy instead of X timelines; publish
reader, writer, and admin executables; exclude all DELETE-backed code from the
writer; use typed scopes and curated fields; and introduce no Cursor, Codex
agent, persisted-query, or X transport adapter boundary.

## Design-to-Task Traceability

| Plan work | Authoritative design section |
| --- | --- |
| Package products, targets, imports, and link boundaries | `design-docs/specs/architecture.md#swiftpm-target-layout`, `design-docs/specs/architecture.md#swiftpm-product-and-import-map`, `design-docs/specs/architecture.md#capability-enforcement` |
| CLI grammar, output, and exit behavior | `design-docs/specs/command.md#common-command-surface`, `design-docs/specs/command.md#output-and-exit-codes` |
| Transport, host, pagination, retry, and canned-response seams | `design-docs/specs/design-wrike-api-client.md#transport-contract`, `design-docs/specs/design-wrike-api-client.md#mock-and-contract-test-strategy` |
| GraphQL parser, role schemas, inputs, and errors | `design-docs/specs/design-graphql-contract.md#role-specific-schemas`, `design-docs/specs/design-graphql-contract.md#initial-parser-scope`, `design-docs/specs/design-graphql-contract.md#error-contract` |
| Resource ownership and delete boundaries | `design-docs/specs/design-capability-matrix.md#resource-by-operation-matrix`, `design-docs/specs/design-capability-matrix.md#destructive-operation-rules` |
| OAuth, permanent token, refresh, storage, and redaction | `design-docs/specs/design-authentication.md#resolution-precedence`, `design-docs/specs/design-authentication.md#refresh-flow`, `design-docs/specs/design-authentication.md#credential-store`, `design-docs/specs/design-authentication.md#redaction-rules` |
| Fixed HTTPS callback and Keychain TLS identity | `design-docs/specs/design-authentication.md#oauth2-authorization-code-flow`, `design-docs/specs/design-authentication.md#oauth-callback-tls-identity`, `design-docs/specs/design-authentication.md#verification-requirements` |

## Milestones

| Milestone | Tasks | Exit condition |
| --- | --- | --- |
| M0: Verified implementation baseline | TASK-001 | Current Wrike OpenAPI, kinko interface, package baseline, and pending defaults are recorded without changing product scope. |
| M1: Core and package boundary | TASK-002, TASK-003 | Core transport/auth contracts and GraphQL runtime compile with focused tests. |
| M2: Reader SDK and CLI | TASK-004, TASK-005, TASK-006 | All twelve read resource areas are registered and reader end-to-end tests pass. |
| M3: Writer SDK and CLI | TASK-007 | Reviewed create/update operations work and no delete field or adapter is linked. |
| M4: Admin SDK and CLI | TASK-008 | Every reviewed DELETE operation is admin-only and destructive-operation tests pass. |
| M5: Integrated verification | TASK-009, TASK-010 | All products, tests, lint, boundary checks, docs, and progress records are complete. |

## Deliverables

- [x] Updated `Package.swift` with four cumulative library products, three
      executable products, and role-specific test targets.
- [x] `Sources/WrikeGatewayCore/` with transport, authentication, stable
      models, GraphQL runtime, capability metadata, command frame, and errors.
- [x] `Sources/WrikeGatewayRead/`, `Sources/WrikeGatewayWrite/`, and
      `Sources/WrikeGatewayAdmin/` with tier-owned adapters and schema
      registrations.
- [x] `Sources/WrikeGatewayReaderCLI/main.swift`,
      `Sources/WrikeGatewayWriterCLI/main.swift`, and
      `Sources/WrikeGatewayAdminCLI/main.swift`.
- [x] `Tests/WrikeGatewayCoreTests/`, `Tests/WrikeGatewayReadTests/`,
      `Tests/WrikeGatewayWriteTests/`, `Tests/WrikeGatewayAdminTests/`, and
      `Tests/WrikeGatewayCLITests/` with recording-transport, loopback,
      redaction, schema, and binary-link assertions.
- [x] Canned success and failure fixtures for every resource area.
- [x] Updated progress and design status records after implementation behavior
      is verified.

## Tasks

### TASK-001: Revalidate the Upstream and Local Baseline

**Parallelizable**: No

**Implementation Tasks**:

- Inspect `Package.swift`, `Sources/AppCore/`, `Sources/AppCLI/`,
  `Tests/AppCoreTests/`, `Taskfile.yml`, and the current SwiftLint configuration.
- Download or inspect the current official Wrike API v4 OpenAPI description and
  reconcile every accepted capability id with its method, path, parameters,
  response kind, scopes, pagination limits, data-center behavior, and plan
  restrictions.
- Record unsupported or blocked operations as `unsupported`,
  `blockedByScope`, or `blockedByPlan`; do not silently substitute a different
  operation or broaden a tier.
- Verify the supported kinko credential-store interface without printing any
  secret record or environment value.
- Retain these pending defaults unless the user has resolved them:
  `https://localhost:8765/callback`, kinko-only protected token storage,
  curated phased GraphQL rollout, and webhook registration management only.
- Confirm `flake.lock` ownership and staged state before source edits; do not
  stage, unstage, regenerate, or revert it as part of this plan.

**Deliverables**:

- An implementation-time capability checklist tied to
  `design-docs/specs/design-capability-matrix.md`.
- Any newly discovered user decision under `design-docs/user-qa/` using the
  existing pending-question format.
- A progress-log entry recording upstream reference date and blocked methods.

**Dependencies**:

- Accepted Step 3 design review.
- Read access to official Wrike API documentation and the local kinko
  interface documentation.

**Verification Commands**:

- `swift package describe`
- `git status --short`
- `rg -n 'Question|Status|Pending' design-docs/user-qa`

**Completion Criteria**:

- [x] Every planned capability has a verified upstream method or an explicit
      blocked/unsupported state.
- [x] `deleteProject`, the excluded initial `users` collection,
      `TRANSPORT_FAILED`, required `WRIKE_GATEWAY_API_BASE_URL`, and all four
      pending product decisions remain explicit.
- [x] No secret value or staged `flake.lock` content is read into logs or
      changed.

### TASK-002: Establish SwiftPM Products, Targets, and Core Contracts

**Parallelizable**: No; all source tasks depend on this package graph.

**Implementation Tasks**:

- Replace `AppCore`, `AppCLI`, and `AppCoreTests` in `Package.swift` with the
  target, product, and test layout defined in `architecture.md`.
- Create the cumulative product membership and direct executable dependencies
  exactly as documented; do not rely on transitive imports or underscored
  re-export behavior.
- Add core value contracts under:
  - `Sources/WrikeGatewayCore/Transport/`
  - `Sources/WrikeGatewayCore/Models/`
  - `Sources/WrikeGatewayCore/Errors/`
  - `Sources/WrikeGatewayCore/Capabilities/`
- Define stable capability metadata covering identifier, tier, operation
  class, GraphQL field, upstream adapter, scope metadata, and implementation
  state.
- Keep the core transport able to represent DELETE while exposing no public
  raw URL, method, query, or response-passthrough API.
- Move or replace scaffold tests under `Tests/WrikeGatewayCoreTests/` without
  retaining compatibility aliases for `AppCore` or `AppCLI`.

**Deliverables**:

- `Package.swift` with canonical product and target names.
- `Sources/WrikeGatewayCore/{Transport,Models,Errors,Capabilities}/`.
- `Tests/WrikeGatewayCoreTests/` foundation tests.

**Dependencies**:

- TASK-001.

**Verification Commands**:

- `swift package describe`
- `swift build --target WrikeGatewayCore`
- `swift test --filter WrikeGatewayCoreTests`
- `swiftlint`

**Completion Criteria**:

- [x] Four library targets, three executable targets, and five test targets
      match the accepted architecture names.
- [x] SDK products are cumulative and consumer imports are documented by the
      manifest structure.
- [x] Shared public values compile under Swift 6 concurrency checking.
- [x] No source or test target remains named `AppCore`, `AppCLI`, or
      `AppCoreTests`.

### TASK-003: Implement Transport, Authentication, and Core GraphQL Runtime

**Parallelizable**: No; these components share core command, error, capability,
and composition-root files.

**Implementation Tasks**:

- Implement `WrikeTransport` and request/response/failure values under
  `Sources/WrikeGatewayCore/Transport/`, plus a `URLSession` live transport.
- Add host allowlist, HTTPS, redirect, authorization-header stripping,
  pagination, `Retry-After`, bounded GET retry, streamed upload, and stable
  error mapping behavior from `design-wrike-api-client.md`.
- Implement credential resolution and protocols under
  `Sources/WrikeGatewayCore/Auth/`, including kinko-backed protected storage,
  OAuth client configuration from `WRIKE_GATEWAY_API_CLIENT_ID` and
  `WRIKE_GATEWAY_API_CLIENT_SECRET`, permanent-token precedence through
  `WRIKE_GATEWAY_ACCESS_TOKEN`, mandatory `WRIKE_GATEWAY_API_BASE_URL`, OAuth
  callback validation, atomic rotating refresh, and single-flight refresh.
- Implement the callback TLS identity boundary under
  `Sources/WrikeGatewayCore/Auth/` using the fixed login-Keychain label
  `wrike-gateway.oauth.localhost`. The production loader must return only an
  opaque identity handle and validate exactly one match, certificate validity,
  `localhost` DNS subject alternative name, TLS-server key usage, macOS trust,
  and private-key availability before listener startup or browser launch.
- Map missing, duplicate, expired, untrusted, hostname-incompatible,
  wrong-key-usage, and inaccessible-private-key identity outcomes to
  `AUTHENTICATION_FAILED` and exit code `3` without exposing certificate,
  private-key, Keychain-record, client-id, authorization-URL, or OAuth-state
  data. Do not add a production identity-label, certificate-file, private-key,
  redirect-URI, or trust-bypass override.
- Implement the constrained parser, AST, validator, variable coercion,
  role-filtered schema registry, planner, executor, projection, error envelope,
  and schema printer under `Sources/WrikeGatewayCore/GraphQL/`.
- Define one capability-execution planner contract in core for both typed Swift
  SDK calls and GraphQL execution. SDK entry points may construct typed requests
  directly, but they must not bypass capability lookup, tier/scope validation,
  adapter selection, or stable error mapping. Add reusable parity-test support
  that compares the plan and adapter selected for equivalent SDK and GraphQL
  operations.
- Implement shared argument/environment handling under
  `Sources/WrikeGatewayCore/CLI/` for `graphql query`, `graphql query-file`,
  `graphql schema`, `auth oauth2`, `auth status`, `auth logout`, `--help`,
  `--version`, `--pretty`, and documented exit codes.
- Add injected clock, browser opener, credential store, file access, and
  transport seams; production binaries must expose no fixture or mock-server
  flag.
- Add authentication unit tests for permanent-token/OAuth precedence, empty
  environment values, required base URL plus approved-host and `/api/v4` path
  validation, clock-skew refresh decisions, scope checks, refresh rotation,
  single-flight behavior, and atomic credential-store failure.
- Add loopback OAuth tests for callback state mismatch, unexpected callback
  path/host, missing code, OAuth error, elapsed timeout, authorization-code
  exchange, and TLS redirect rejection without live credentials. Prove that no
  redirect URI flag or environment override is accepted.
- Add structural redaction tests proving client secrets, tokens, OAuth codes,
  state, authorization headers, webhook secrets, file bytes, and raw business
  bodies cannot reach output or error descriptions.
- Add injected TLS identity-loader and trust-evaluator test seams plus fixtures
  for every required Keychain validation outcome. Assert listener binding and
  browser opening are not attempted on any identity failure.

**Deliverables**:

- `Sources/WrikeGatewayCore/{Transport,Auth,GraphQL,CLI}/` implementations.
- `Tests/WrikeGatewayCoreTests/{Transport,Auth,GraphQL,CLI,Redaction}/`,
  including planner-parity support, complete OAuth callback behavior, TLS
  identity, and pre-browser failure tests.
- Recording transport and loopback HTTP/TLS test support under
  `Tests/WrikeGatewayCoreTests/TestSupport/`.

**Dependencies**:

- TASK-002.
- Current Wrike OAuth and host behavior verified by TASK-001.
- Pending OAuth callback and token-account decisions use the documented safe
  defaults until resolved.

**Verification Commands**:

- `swift test --filter WrikeGatewayCoreTests`
- `swift test --filter Authentication`
- `swift test --filter OAuthCallbackTLSIdentity`
- `swift test --filter GraphQL`
- `swift test --filter Redaction`
- `swiftlint`

**Completion Criteria**:

- [x] Recording transport and loopback tests cover success, pagination, 400,
      401, 403, 404, 429, 500, malformed payloads, redirects, and timeouts.
- [x] Only GET operations retry automatically; mutation outcome-unknown errors
      remain explicit.
- [x] `TRANSPORT_FAILED` remains distinct from `UPSTREAM_UNAVAILABLE`.
- [x] Permanent-token mode fails locally without a validated
      `WRIKE_GATEWAY_API_BASE_URL`.
- [x] Authentication tests cover credential precedence and empty values,
      approved-host and `/api/v4` validation, clock skew, scope checks, and
      atomic credential-store failure.
- [x] OAuth refresh rotation is atomic and single-flight.
- [x] Loopback OAuth tests cover callback state/path/host validation, missing
      code, OAuth error, timeout, code exchange, TLS redirect rejection, and
      rejection of every redirect URI override.
- [x] OAuth callback startup accepts only the fixed trusted localhost Keychain
      identity and fails safely before listener or browser activity for every
      invalid identity state documented in the authentication design.
- [x] TLS identity handling exports neither private-key material nor a
      production override and emits no certificate or Keychain record data.
- [x] Unsupported GraphQL syntax and fields fail before authentication or
      network access.
- [x] Core planner contract tests prove typed SDK and GraphQL requests cannot
      select different capability, tier/scope validation, adapter, or stable
      error mapping for the same operation.
- [x] Secret-bearing values are absent from stdout, stderr, logs, snapshots,
      and error descriptions.

### TASK-004: Implement Reader Work-Hierarchy Capabilities

**Parallelizable**: Yes, with TASK-005 after TASK-003. Write scope is limited to
`Sources/WrikeGatewayRead/{Contacts,Users,Groups,Accounts,Spaces,Folders,Projects,Tasks}/`,
matching test directories, and resource-local fixtures. Shared registries and
package files are reserved for TASK-006.

**Implementation Tasks**:

- Add typed read adapters, SDK methods, resource-local capability fragments,
  stable models, pagination constraints, and canned responses for contacts,
  users, groups, accounts, spaces, folders, projects, and tasks.
- Route every typed SDK method through the core capability-execution planner
  used by its equivalent GraphQL Query field. Add paired SDK/GraphQL tests that
  assert identical capability id, validation outcome, adapter request, stable
  model projection, and mapped error.
- Preserve the accepted distinction between `folder` and `project` intent even
  where Wrike uses one endpoint family.
- Do not add a public `users` collection alias; expose the reviewed single-user
  and user-type fields, with account people available through filtered
  contacts.
- Make hierarchy traversal and relationship hydration explicit, deduplicated,
  costed, and bounded.
- Test exact method/path/query mapping, response `kind`, model projection,
  pagination, scope rejection, and malformed upstream envelopes.

**Deliverables**:

- Work-hierarchy resource directories under `Sources/WrikeGatewayRead/`.
- Corresponding directories under `Tests/WrikeGatewayReadTests/` and
  `Tests/Fixtures/WrikeAPI/Read/`.

**Dependencies**:

- TASK-003.

**Verification Commands**:

- `swift build --target WrikeGatewayRead`
- `swift test --filter WrikeGatewayReadTests`
- `swiftlint Sources/WrikeGatewayRead Tests/WrikeGatewayReadTests`

**Completion Criteria**:

- [x] All assigned work-hierarchy matrix rows have typed SDK and Query coverage
      across the eight resource adapter namespaces, matching verified
      capability ids.
- [x] Reader adapters use only GET-backed reviewed operations.
- [x] Folder/project semantics and the excluded `users` collection match the
      accepted GraphQL contract.
- [x] Every capability has recording-transport success and failure tests.
- [x] Paired SDK/GraphQL tests prove planner and adapter parity for every
      assigned reader capability.

### TASK-005: Implement Reader Collaboration and Administration Views

**Parallelizable**: Yes, with TASK-004 after TASK-003. Write scope is limited to
`Sources/WrikeGatewayRead/{Comments,Attachments,Timelogs,CustomFields,Workflows,Webhooks}/`,
matching test directories, and resource-local fixtures. Shared registries and
package files are reserved for TASK-006.

**Implementation Tasks**:

- Add typed read adapters, SDK methods, resource-local capability fragments,
  stable models, pagination constraints, and canned responses for comments,
  attachments, timelogs, custom fields, workflows, and webhooks.
- Route every typed SDK method through the core capability-execution planner
  used by its equivalent GraphQL Query field, with paired parity tests for
  capability selection, validation, adapter requests, projection, and errors.
- Keep attachment metadata, download, preview, and URL operations explicit;
  never place attachment bytes or user content in diagnostics.
- Expose webhook registration/status inspection only; do not host callbacks.
- Test plan/scope restrictions, pagination differences, file-output errors,
  webhook status models, response `kind`, and malformed envelopes.

**Deliverables**:

- Collaboration/administration-view directories under
  `Sources/WrikeGatewayRead/`.
- Corresponding directories under `Tests/WrikeGatewayReadTests/` and
  `Tests/Fixtures/WrikeAPI/Read/`.

**Dependencies**:

- TASK-003.

**Verification Commands**:

- `swift build --target WrikeGatewayRead`
- `swift test --filter WrikeGatewayReadTests`
- `swiftlint Sources/WrikeGatewayRead Tests/WrikeGatewayReadTests`

**Completion Criteria**:

- [x] All six assigned resource families have typed SDK and Query coverage
      matching verified capability ids.
- [x] Reader behavior performs no create, update, delete, upload, or webhook
      state change.
- [x] Attachment bytes, comment text, and webhook secrets are absent from
      diagnostics and snapshots.
- [x] Every capability has recording-transport success and failure tests.
- [x] Paired SDK/GraphQL tests prove planner and adapter parity for every
      assigned reader capability.

### TASK-006: Integrate the Reader Product and Executable

**Parallelizable**: No; this task merges resource-local fragments into shared
schema, capability, command, package, and CLI integration points.

**Implementation Tasks**:

- Integrate TASK-004 and TASK-005 capability fragments into the reader schema
  with bidirectional field-to-route coherence checks.
- Add `Sources/WrikeGatewayReaderCLI/main.swift` as a thin role-selection entry
  point and expose only reader commands in help and schema output.
- Add CLI end-to-end fixtures for inline queries, query files, variables,
  pagination, multiple bounded top-level reads, JSON output, pretty output,
  stderr, and exit codes.
- Add binary inspection tests proving the reader does not link
  `WrikeGatewayWrite` or `WrikeGatewayAdmin`.

**Deliverables**:

- Reader integration in `Sources/WrikeGatewayRead/Schema/`.
- `Sources/WrikeGatewayReaderCLI/main.swift`.
- Reader cases in `Tests/WrikeGatewayCLITests/`.

**Dependencies**:

- TASK-004 and TASK-005.

**Verification Commands**:

- `swift build --product wrike-gateway-reader`
- `swift test --filter WrikeGatewayReadTests`
- `swift test --filter WrikeGatewayCLITests.Reader`
- `swift run wrike-gateway-reader --help`
- `swift run wrike-gateway-reader graphql schema`
- `swiftlint`

**Completion Criteria**:

- [x] Reader schema covers all twelve accepted resource areas without mutation
      fields.
- [x] Reader help, schema, SDK imports, and binary linkage expose no write or
      admin capability.
- [x] Reader end-to-end responses use the documented JSON and error envelopes.

### TASK-007: Implement Writer Capabilities and Executable

**Parallelizable**: No; writer resource adapters share mutation registration,
input validation, CLI integration, and cross-resource update semantics.

**Implementation Tasks**:

- Implement verified POST/PUT-backed create and update adapters under
  `Sources/WrikeGatewayWrite/`, grouped by the twelve resource areas in the
  accepted matrix.
- Route writer SDK methods and GraphQL mutations through the same core
  capability-execution planner and adapters, with paired parity tests covering
  capability selection, tier/scope validation, inputs, results, and errors.
- Register resource-local mutation fragments and integrate only reviewed
  create/update, membership, copy, upload, and webhook state operations.
- Implement attachment streaming from a validated readable regular file
  without buffering or logging bytes.
- Add `Sources/WrikeGatewayWriterCLI/main.swift` and writer CLI/schema tests.
- Add compile/link/schema assertions proving no DELETE adapter, `delete*`
  field, or `WrikeGatewayAdmin` module is reachable from writer.
- Test non-idempotent transport failures as outcome unknown with no automatic
  replay.

**Deliverables**:

- `Sources/WrikeGatewayWrite/` resource and schema directories.
- `Sources/WrikeGatewayWriterCLI/main.swift`.
- `Tests/WrikeGatewayWriteTests/`, writer fixtures, and writer CLI cases.

**Dependencies**:

- TASK-006.
- Verified writer operations from TASK-001.

**Verification Commands**:

- `swift build --target WrikeGatewayWrite`
- `swift build --product wrike-gateway-writer`
- `swift test --filter WrikeGatewayWriteTests`
- `swift test --filter WrikeGatewayCLITests.Writer`
- `swift run wrike-gateway-writer graphql schema`
- `swiftlint`

**Completion Criteria**:

- [x] Writer is cumulative with reader and exposes every implemented reviewed
      create/update capability.
- [x] Writer schema and linkage contain no delete mutation or admin target.
- [x] File, membership, copy, and webhook-state inputs are bounded and
      explicitly validated.
- [x] Mutations do not retry automatically and report ambiguous transport
      outcomes safely.
- [x] Paired SDK/GraphQL tests prove planner and adapter parity for every
      implemented writer capability.

### TASK-008: Implement Admin Delete Capabilities and Executable

**Parallelizable**: No; destructive adapters require one coordinated schema,
safety, and boundary review.

**Implementation Tasks**:

- Implement verified DELETE-backed adapters under
  `Sources/WrikeGatewayAdmin/` for group, space, folder, project, task,
  comment, attachment, timelog, and webhook.
- Route admin SDK delete methods and GraphQL delete mutations through the same
  core capability-execution planner and adapters, with paired parity tests for
  destructive validation, capability selection, outcomes, and errors.
- Register exactly `deleteGroup`, `deleteSpace`, `deleteFolder`,
  `deleteProject`, `deleteTask`, `deleteComment`, `deleteAttachment`,
  `deleteTimelog`, and `deleteWebhook` unless TASK-001 marks an upstream method
  blocked or unsupported.
- Keep `deleteFolder` and `deleteProject` as distinct public capabilities and
  inputs even when they map to the shared upstream family.
- Require one explicit opaque id, disable wildcard/recursive/implicit bulk
  deletion and automatic retry, and return confirmed id or outcome unknown.
- Add `Sources/WrikeGatewayAdminCLI/main.swift`, destructive-operation tests,
  and admin CLI/schema tests.

**Deliverables**:

- `Sources/WrikeGatewayAdmin/` resource and schema directories.
- `Sources/WrikeGatewayAdminCLI/main.swift`.
- `Tests/WrikeGatewayAdminTests/`, admin fixtures, and admin CLI cases.

**Dependencies**:

- TASK-007.
- Verified DELETE inventory from TASK-001.

**Verification Commands**:

- `swift build --target WrikeGatewayAdmin`
- `swift build --product wrike-gateway-admin`
- `swift test --filter WrikeGatewayAdminTests`
- `swift test --filter WrikeGatewayCLITests.Admin`
- `swift run wrike-gateway-admin graphql schema`
- `swiftlint`

**Completion Criteria**:

- [x] All supported reviewed DELETE operations exist only in admin.
- [x] `deleteProject` is present when its verified upstream mapping is
      supported and remains distinct from `deleteFolder`.
- [x] Destructive inputs reject wildcard, recursive, implicit descendant, and
      unbounded bulk behavior.
- [x] Delete operations never retry automatically or infer success from a
      dropped response.
- [x] Paired SDK/GraphQL tests prove planner and adapter parity for every
      implemented admin capability.

### TASK-009: Complete Cross-Tier Integration and Verification

**Parallelizable**: No; it updates shared integration tests, package products,
and documentation status after every tier is present.

**Implementation Tasks**:

- Run the same accepted query through reader, writer, and admin and verify
  cumulative read behavior.
- Compare role-specific printed schemas and help output against capability
  metadata; enforce bidirectional field/route registration coherence.
- Run paired SDK/GraphQL requests for representative reads, writes, and deletes
  and verify identical planner decisions, adapter requests, projections, and
  stable errors within each linked tier.
- Run link/binary inspection proving reader excludes write/admin and writer
  excludes admin.
- Run loopback scenarios for OAuth refresh, data-center hosts, pagination,
  rate limiting, malformed responses, attachment transfer, and mutation
  outcome-unknown behavior.
- Audit stdout, stderr, errors, snapshots, fixtures, and logs for credential or
  user-content disclosure.
- Confirm production binaries accept no mock transport, fixture, arbitrary
  host, raw REST, or unreviewed schema expansion flag.

**Deliverables**:

- Completed `Tests/WrikeGatewayCLITests/` cross-tier suite.
- Boundary, schema-coherence, and redaction verification records in this
  plan's progress log.

**Dependencies**:

- TASK-008.

**Verification Commands**:

- `task build`
- `task test`
- `swift test`
- `swiftlint`
- `swift run wrike-gateway-reader --help`
- `swift run wrike-gateway-writer --help`
- `swift run wrike-gateway-admin --help`
- `swift run wrike-gateway-reader graphql schema`
- `swift run wrike-gateway-writer graphql schema`
- `swift run wrike-gateway-admin graphql schema`

**Completion Criteria**:

- [x] All products build and all unit, contract, loopback, CLI, and boundary
      tests pass.
- [x] Target names, product names, executable names, environment variables,
      capability ids, fields, tiers, and stable error codes are mutually
      consistent.
- [x] Reader cannot link or dispatch writes/deletes; writer cannot link or
      dispatch deletes.
- [x] Redaction and no-production-test-hook assertions pass.
- [x] `task build`, `task test`, and `swiftlint` pass in one clean verification
      session.

### TASK-010: Refresh Documentation and Close the Active Plan

**Parallelizable**: No; documentation status must reflect verified final
behavior rather than planned behavior.

**Implementation Tasks**:

- Update design status and implementation-state claims only for capabilities
  proven by TASK-009.
- Retain unresolved user questions as Pending and record any user decisions in
  the corresponding files.
- Record final commands and results in the progress log, including any
  unsupported/blocked upstream capability.
- Confirm implementation changes stayed within the planned Swift source, test,
  package, and documentation paths; do not include the pre-existing staged
  `flake.lock` in this work.
- When all completion criteria are checked, set this plan to Completed and move
  it from `impl-plans/active/` to `impl-plans/completed/` in the same change.

**Deliverables**:

- Accurate design and capability implementation status.
- Completed progress log and lifecycle move when all work is verified.

**Dependencies**:

- TASK-009.

**Verification Commands**:

- `git diff --check -- design-docs impl-plans Package.swift Sources Tests`
- `rg -n 'Status|planned|implemented|blockedByScope|blockedByPlan|unsupported' design-docs impl-plans`
- `LC_ALL=C rg -n '[^ -~]' design-docs impl-plans`
- `git status --short`

**Completion Criteria**:

- [x] Documentation states only behavior demonstrated by tests.
- [x] Pending user decisions remain visible and use the repository format.
- [x] The progress log contains dated results for every verification command.
- [x] The plan moves to `impl-plans/completed/` only after all global criteria
      are satisfied.

## Dependency Graph

```text
TASK-001
  -> TASK-002
    -> TASK-003
      -> TASK-004 ----\
      -> TASK-005 -----+-> TASK-006
                            -> TASK-007
                              -> TASK-008
                                -> TASK-009
                                  -> TASK-010
```

## Parallel Execution Rules

- TASK-004 and TASK-005 may run concurrently only after TASK-003 is complete.
- TASK-004 owns only the work-hierarchy `WrikeGatewayRead` resource directories,
  matching tests, and fixtures listed in that task.
- TASK-005 owns only the collaboration/administration-view
  `WrikeGatewayRead` resource directories, matching tests, and fixtures listed
  in that task.
- Neither parallel task may edit `Package.swift`, shared core files,
  `Sources/WrikeGatewayRead/Schema/`, shared fixture indexes, CLI targets, or
  this plan. TASK-006 owns those integration points.
- All other tasks are serialized because their write scopes overlap or their
  verification depends on a single integrated state.

## Global Verification

- `task build`
- `task test`
- `swift test`
- `swiftlint`
- `git diff --check -- design-docs impl-plans Package.swift Sources Tests`
- `LC_ALL=C rg -n '[^ -~]' design-docs impl-plans`
- `git status --short`

## Risks and Mitigations

- Operators must provision and trust the fixed localhost Keychain identity
  before OAuth login. Mitigation: fail before listener/browser startup with
  non-secret guidance naming only the fixed label and required properties.
- Wrike API operations, scopes, hosts, pagination, and plan restrictions may
  differ from the design-time inventory. Mitigation: TASK-001 revalidates each
  capability and records unsupported or blocked states before implementation.
- Kinko account selection, GraphQL rollout breadth, and webhook runtime remain
  pending user decisions. Mitigation: retain the accepted conservative defaults
  and keep the corresponding `design-docs/user-qa/` files Pending.
- Shared canonical names may drift across modules and documents. Mitigation:
  TASK-009 performs cross-tier schema, linkage, environment-name, and error-code
  consistency checks before completion.

## Global Completion Criteria

- [x] The package publishes cumulative SDK products `WrikeGatewayCore`,
      `WrikeGatewayRead`, `WrikeGatewayWrite`, and `WrikeGatewayAdmin`.
- [x] The three canonical executables build and expose only their linked tier.
- [x] The capability inventory covers all twelve required resource areas;
      writer has no DELETE operation and every implemented DELETE is admin-only.
- [x] The SDK and GraphQL paths share capability identifiers, validation,
      the same capability-execution planner and adapters, stable models, and
      error mapping; paired parity tests pass in every tier.
- [x] OAuth2, refresh rotation, kinko storage, permanent-token precedence,
      data-center host validation, and redaction satisfy the accepted auth
      design. kinko storage is now proven end to end: the command contract is
      pinned against the interface printed by `kinko get|set-key|delete --help`
      at `kinko version` 0.1.8, replayed through the installed binary by an
      opt-in test, and round-tripped by `KinkoRoundTripTests`
      (`WRIKE_GATEWAY_KINKO_ROUNDTRIP=1`) against a real unlocked vault for
      load, replace, rotation, delete, and repeated delete. The store-level
      classification of an unreadable vault is enforced end to end rather than
      only at the store: `CredentialResolver.status` and `.logout` both
      propagate it, and `AuthCommands.status` and `.logout` both surface it as
      `FILE_OPERATION_FAILED` with exit `6`, each covered by an end-to-end test
      against an unavailable store (2026-08-05, see the entry below). The live
      Wrike
      authorization-code exchange and refresh rotation against
      `login.wrike.com` remain unexercised, since they require an operator
      browser session and a registered OAuth application; that boundary is
      recorded as a residual risk rather than as a gap in this criterion, whose
      subject is the local auth implementation.
- [x] The canonical environment variables are exactly
      `WRIKE_GATEWAY_API_CLIENT_ID`, `WRIKE_GATEWAY_API_CLIENT_SECRET`,
      `WRIKE_GATEWAY_ACCESS_TOKEN`, and `WRIKE_GATEWAY_API_BASE_URL`.
- [x] Recording transport and loopback canned-response tests cover every
      implemented capability and required failure class.
- [x] `deleteProject`, `TRANSPORT_FAILED`, the excluded initial `users`
      collection, canonical environment variables, products, executables, and
      capability tiers remain consistent across code, tests, and docs.
- [x] `task build`, `task test`, `swift test`, and `swiftlint` pass.
- [x] No unrelated release, packaging, source, or staged `flake.lock` change is
      included.
- [x] Every task has a dated progress entry, checked completion criteria, and
      recorded command results before the plan is marked Completed.

## Progress Log Expectations

For every implementation session, append a dated entry containing:

- tasks completed and tasks still in progress;
- exact files or target scopes changed;
- verification commands and pass/fail/not-run results;
- blockers, upstream operation changes, and pending user decisions;
- capability status changes (`planned`, `implemented`, `blockedByScope`,
  `blockedByPlan`, or `unsupported`); and
- confirmation that the pre-existing staged `flake.lock` was not modified.

Do not check a task or global completion criterion until its verification has
passed. A failed command remains recorded with the remediation or blocking
condition.

## Progress Log

- 2026-08-05: Plan created from the Step 3 accepted design review. No
  implementation tasks have started. Pending OAuth callback, token-account
  selection, GraphQL rollout, and webhook-runtime decisions retain the
  documented conservative defaults. The pre-existing staged `flake.lock`
  remains outside this plan.
- 2026-08-05: Step 4 revised the plan with section-level design references,
  explicit Keychain TLS identity implementation and failure-path tests, and a
  risk/mitigation register. No implementation code was written and the
  pre-existing staged `flake.lock` was not modified.
- 2026-08-05: Step 4 rerun addressed both Step 5 mid findings by making the
  shared SDK/GraphQL planner path and per-tier parity tests explicit, and by
  enumerating every authentication test required by the accepted design. No
  implementation code was written and the pre-existing staged `flake.lock` was
  not modified.

- 2026-08-05: Implementation session. TASK-001 through TASK-009 executed;
  TASK-010 executed except for the lifecycle move, which is deliberately not
  taken (see the outstanding work below). Commits `7af18c4` (package graph,
  core runtime, three tiers, three executables), `6209c03` (five test targets
  plus the test-only support library, and two defects those tests found),
  `8255f9b` (documentation and this log), and `94995b5` (a third defect found
  in diff self-review). `git status --short` confirms the pre-existing staged
  `flake.lock` is still staged and unmodified; every commit used path-scoped
  `git add` limited to `Package.swift`, `Sources`, `Tests`, `README.md`,
  `Taskfile.yml`, `design-docs`, and `impl-plans`.

  **TASK-001 (upstream revalidation).** Wrike API v4 was re-checked against the
  official developer documentation on 2026-08-05. Directly confirmed:
  approved data-center API hosts `www.wrike.com`, `app-eu.wrike.com`, and
  `app-us2.wrike.com`; OAuth authorize `https://login.wrike.com/oauth2/authorize/v4`
  and token `https://login.wrike.com/oauth2/token`, with refresh rotating both
  tokens and the token response reporting the account `host`; HTTPS-only
  redirect URIs with localhost guidance; the `kind` plus `data` envelope; the
  `error` plus `errorDescription` error body with 400/401/403/404/429/500 and
  the 400-requests-per-minute limit; `pageSize` up to 1000 with an opaque
  `nextPageToken` on `GET /tasks` and `GET /timelogs`; no pagination parameters
  on `GET /contacts` or `GET /comments`; and all nine reviewed DELETE routes
  individually. Findings that changed scope: `workflows.get` is `unsupported`
  because Wrike documents no single-workflow GET, and no paginated user-list
  operation exists, which confirms excluding the `users` collection. The kinko
  interface was inspected through `kinko --help` only; no secret record or
  environment value was read or printed. **Corrected on 2026-08-05 by the
  entry dated 2026-08-05 (kinko interface correction) below:** `kinko --help`
  does not print subcommand flags, so this was not a verification of the
  credential-store interface, and the interface that was implemented from it
  did not exist.

  **TASK-002/003 (package graph and core runtime).** `AppCore`, `AppCLI`, and
  `AppCoreTests` are gone with no aliases. Four cumulative library products,
  three executables, and five test targets match `architecture.md`. Core holds
  the injectable `WrikeTransport` with a `URLSession` live implementation, the
  host allowlist and redirect credential policy, `Retry-After` handling and
  GET-only bounded retry, the four-variable credential resolver, kinko-backed
  storage, single-flight rotating refresh, the fixed callback flow gated on a
  validated login-Keychain identity, the constrained GraphQL runtime, and the
  shared command frame.

  **TASK-004/005/006/007/008 (tiers).** Capabilities are declared once as data;
  one `CapabilityDefinition` drives the printed schema, the validator, the
  upstream route, the scope check, and the stable projection. Reader registers
  28 GET-only query fields across the twelve reviewed resource areas plus
  access roles; writer adds 27 create/update mutations and links no delete;
  admin adds exactly the nine reviewed deletes. `CapabilityPlanner` is the only
  execution path for both the typed SDK and GraphQL.

  **TASK-009 (verification).** Commands run, all passing:
  `task build`; `task test`; `swift test` (186 tests, 30 suites);
  `swiftlint` (0 violations in 85 files);
  `swift run wrike-gateway-{reader,writer,admin} --help`;
  `swift run wrike-gateway-{reader,writer,admin} graphql schema`;
  `git diff --check -- design-docs impl-plans Package.swift Sources Tests`;
  `LC_ALL=C rg -n '[^ -~]' design-docs impl-plans` (no matches);
  `git status --short`. Schema comparison confirms reader prints no `Mutation`
  type, writer prints 27 mutations with no `delete*` field and no
  `DeletionPayload`, and admin adds exactly the nine deletes. `nm` symbol
  inspection of the built binaries confirms `wrike-gateway-reader` contains no
  `WrikeGatewayWrite` or `WrikeGatewayAdmin` symbols and `wrike-gateway-writer`
  contains no `WrikeGatewayAdmin` symbols; the same check confirms no binary
  contains `WrikeGatewayTestSupport`. Every forbidden override flag is rejected
  by all three binaries with exit code 2.

  Note on verification commands: this plan lists `swift test --filter
  <Target>Tests`, but swift-testing matches its filter against suite and test
  type names rather than module names, so those forms select zero tests. Use a
  type-name filter such as `swift test --filter ReaderCapabilityContractTests`,
  or run `swift test` for the whole suite.

  **Three defects found and fixed.** `RequestBuilder` used `continue` inside a
  `switch` in a `for` loop, which skipped the nested input-object binding step
  entirely, so every mutation and delete failed to resolve its path identifier.
  Caller-supplied JSON parse failures were reported as
  `UPSTREAM_RESPONSE_INVALID` (exit 4) instead of `VALIDATION_ERROR` (exit 2).
  Diff self-review found a third: argument coercion ran inside
  `CapabilityPlanner.plan`, which the executor called only after awaiting the
  credential provider, so an invalid argument on a machine with no credential
  reported `AUTHENTICATION_FAILED` (exit 3) instead of `VALIDATION_ERROR`
  (exit 2), contradicting `command.md#validation`. The scope check is now a
  separate step: the executor plans locally, resolves the credential, then
  validates scopes, all still before transport.

  **Final verification totals.** 188 tests in 30 suites; `swiftlint` reports 0
  violations in 85 files; the reader binary returns `VALIDATION_ERROR` with
  exit code 2 for an over-length identifier with no credentials configured.

  **Capability status changes.** `implemented`: the 28 reader, 27 writer, and 9
  admin capability ids listed in
  `design-docs/specs/design-capability-matrix.md#implementation-status`.
  `unsupported`: `workflows.get`, `users.list`. Still `planned` and
  deliberately unregistered: `contacts.history`, `folders.history`,
  `tasks.history` (the operations exist upstream but their exact route shapes
  could not be confirmed from the official reference in this session, and the
  plan forbids substituting an unverified route), and
  `attachments.download`/`attachments.preview` (the upstream response is a
  binary `application/octet-stream` body that does not fit the JSON envelope
  and needs a reviewed file-output contract; `attachments.url` covers the
  reviewed metadata-and-link case).

  **User decisions.** All four `design-docs/user-qa/` questions were resolved by
  the user in commit `80e1754` during this session and renamed to `qa-*.md`.
  The implementation matches every answer: fixed TLS loopback callback and
  fixed Keychain label with no configurable override; one default kinko-backed
  account record keyed by tool, client id, and host, with no `--account` flag;
  all twelve resource families in the first stable release with stability
  phasing per capability; and webhook registration management only, with
  deletion admin-only and no callback hosting.

  **Outstanding work, blocking plan closure.** The TASK-004 and TASK-005
  completion criterion "all assigned matrix rows have typed SDK and Query
  coverage" is not fully satisfied: the three field-history rows and the two
  attachment binary-transfer rows above are unimplemented. Per this plan's rule
  that a criterion is not checked until its verification passes, those task
  boxes and the corresponding global criterion stay unchecked and the plan
  stays in `impl-plans/active/`. Closing it requires either confirming those
  upstream routes and implementing them, or a reviewed decision to move them
  out of the accepted matrix.

- 2026-08-05: Implementation session (kinko interface correction). Independent
  review found that the credential store's kinko invocations did not exist in
  the installed CLI, so the entire OAuth token-storage path was non-functional
  in production while every test passed against a recording mock.

  **kinko interface actually verified.** `kinko version` reports `0.1.8`
  (`/opt/homebrew/bin/kinko`). `kinko get --help`, `kinko set-key --help`,
  `kinko delete --help`, `kinko set --help`, and `kinko --help` were read
  directly. Findings: `get KEY` accepts `--reveal` and no `--quiet`; `set-key
  KEY` accepts `--value` and a value on stdin, and no `--stdin` flag exists;
  `delete KEY` accepts `-y/--yes` and no `--quiet`; the global `--force`
  overrides the non-tty/redirection guardrail that blocks sensitive output for
  every piped read; `--path` defaults to the current working directory and
  `--profile` defaults to `default`; and record names must be valid environment
  keys, so the previous `wrike-gateway.oauth.<fingerprint>.<host>` name was
  rejected outright with `invalid environment key`. A locked vault prints
  `locked` on stderr and exits 1 **on the `get` path only**; see the
  2026-08-05 unavailable-vault entry below for the per-subcommand markers,
  which this entry wrongly generalised to every subcommand. Each of those was confirmed by running the
  command; no secret record, key, or environment value was read or printed, and
  every probe that could mutate state was pointed at an empty temporary
  `--kinko-dir`, which stayed empty.

  **Corrected TASK-001 finding.** The earlier entry recorded the kinko
  interface as inspected through `kinko --help`, which does not print
  subcommand flags. That was not a verification, and the interface implemented
  from it did not exist. The TASK-001 completion criteria are unchanged, but the
  auth global criterion is now unchecked with its blocking condition recorded.

  **Changes.** `Sources/WrikeGatewayCore/Auth/KinkoCredentialStore.swift`
  (verified argv per operation, record on stdin instead of argv, pinned
  `--path`/`--profile` scope, `--force` for the non-tty guardrail,
  `--confirm=false` for the write, PATH-then-Homebrew-prefix executable
  resolution, locked-vault classification, byte-stable record encoding);
  `Sources/WrikeGatewayCore/Auth/CredentialStore.swift` (environment-key record
  name); `Sources/WrikeGatewayCore/Auth/LoopbackCallbackListener.swift` (atomic
  single-resume claim); `Sources/WrikeGatewayCore/Capabilities/ResponseProjection.swift`
  and `CapabilityExecutor.swift` (an unconfirmed delete is outcome-unknown
  instead of echoing the requested id); `Tests/WrikeGatewayCoreTests/Auth/`,
  `Tests/WrikeGatewayAdminTests/`, `Tests/WrikeGatewayCLITests/`,
  `Tests/WrikeGatewayTestSupport/InjectedSeams.swift`; `AGENTS.md`,
  `README.md`, `design-docs/specs/design-authentication.md`, and this plan.

  **Verification.** `swift build` pass; `task build` pass; `swift test` and
  `task test` pass with 209 tests in 34 suites; `swiftlint` reports 0 violations
  in 87 files. The opt-in
  `WRIKE_GATEWAY_KINKO_INTEGRATION=1 swift test --filter storeCommandsParse`
  replays the store's real argv and stdin through the installed kinko and
  passes; it is skipped in the default run. `git status --short` shows the
  pre-existing staged `flake.lock` unmodified.

  **Defects fixed from review.** F1 kinko command contract (high); F2 hardcoded
  Apple-Silicon Homebrew path (medium); F3 non-atomic single-resume guard (low);
  F4 delete response with an empty `data` array echoing the requested id (low);
  F5 stale `swift run wrike-gateway --help` in `AGENTS.md` (low). Two defects
  found while fixing F1 and not in the review: the record name was not a legal
  kinko key at all, and a locked vault was reported as "no credential is
  available" instead of an actionable locked-store error.

  **Outstanding work, blocking plan closure.** Unchanged from the previous
  entry (three field-history rows and two attachment binary-transfer rows), plus
  the new auth criterion above: credential storage is pinned to the verified
  0.1.8 interface but has not been round-tripped against an unlocked vault,
  which requires an interactive `kinko init`/`kinko unlock` and is therefore not
  automatable in this session.

- 2026-08-05: Implementation session (per-subcommand unavailable-vault
  classification). Independent review found that the locked-vault contract
  recorded in the previous entry held only for `get`, so `auth logout` against a
  locked vault reported `{"removedLocalRecord":false}` with exit 0 while the
  OAuth record, including the refresh token, was still stored.

  **kinko markers actually verified, per subcommand.** Re-probed `kinko version`
  0.1.8 rather than copying the review's markers. `kinko status` reports
  `locked`. Against that real locked vault with a key that does not exist, at
  the same profile and path scope: `get KEY --reveal --force` and
  `get KEY --force` exit 1 with stderr `locked`; `set-key KEY --confirm=false`
  with the record on stdin exits 1 with stderr `locked`; `delete KEY --yes`
  exits 13 with stderr `Failed to load vault.`. Against an empty temporary
  `--kinko-dir`: `get` exits 1 with `open <dir>/vault/meta.v1.json: no such
  file or directory`; `set-key` exits 12 with `Vault mutation in progress.`;
  `delete` exits 13 with `Failed to load vault.`. This corrects the review's
  own evidence on one point: exit 12 comes from an uninitialised vault
  directory, not from a locked vault, and `set-key` on a locked vault prints
  `locked` exactly as `get` does. `delete` is the one subcommand that never
  prints `locked`. Argument-contract probes also confirmed
  `delete requires a key or --all` and `set-key requires --value or stdin
  value`, and that both diagnostics are emitted before the vault load, so they
  are reachable with an empty `--kinko-dir`. No `--reveal` was used against an
  existing record, no secret was read or printed, the probe key does not exist,
  and the temporary vault directory stayed empty.

  **Changes.** `Sources/WrikeGatewayCore/Auth/KinkoCredentialStore.swift`:
  `throwIfLocked` is replaced by `throwIfStoreUnavailable`, which matches the
  exit code together with the exact stderr line against the three verified
  markers and surfaces all of them with `kinko unlock` guidance;
  `delete(_:)` now decides "nothing to remove" on the `get` path and never runs
  `kinko delete` for a record that does not exist, so every non-zero `delete`
  exit is a failure rather than a silent no-op; `SystemProcessRunner.run`
  services stdin, stdout, and stderr concurrently instead of draining stdout to
  EOF first. `Tests/WrikeGatewayCoreTests/Auth/KinkoCredentialStoreTests.swift`
  gains four regression tests and the two missing contract diagnostics in the
  opt-in integration rejection list.
  `design-docs/specs/design-authentication.md` records the markers per
  subcommand, and the previous progress-log entry is corrected in place.

  **Verification.** `swift build` pass; `task build` pass; `swift test` and
  `task test` pass with 213 tests in 34 suites; `swiftlint` reports 0 violations
  in 87 files. `WRIKE_GATEWAY_KINKO_INTEGRATION=1 swift test --filter
  storeCommandsParse` passes against the installed kinko 0.1.8 and now fails if
  the key positional or the stdin record body is dropped. `git status --short`
  shows the pre-existing staged `flake.lock` unmodified.

  **Defects fixed from review.** F6 locked-vault classification and the silent
  `delete` no-op (medium); F7 integration rejection list that could not detect
  loss of the key positional or the stdin body (low); F8 `SystemProcessRunner`
  stdout-before-stderr drain deadlock (low).

  **Outstanding work, blocking plan closure.** Unchanged: three field-history
  rows, two attachment binary-transfer rows, and the auth criterion, since
  credential storage still has not been round-tripped against an unlocked vault
  (`kinko init`/`kinko unlock` require an interactive password and the local
  vault is locked). Correction, 2026-08-05 (later session): that blocking
  condition was wrong. `kinko init`/`kinko unlock` accept the password on
  stdin, so the round trip was automatable all along; it has now been executed
  and the auth criterion is checked. See the entry below.

- 2026-08-05: Implementation session (missing-record marker, single-invocation
  delete, and a real vault round trip). Independent review found that the
  previous fix moved the silent-no-op defect one call earlier rather than
  closing it, and that the blocking condition recorded against the auth
  criterion was factually incorrect.

  **kinko contract verified against an unlocked vault.** Re-probed rather than
  copying the review's evidence. A disposable vault was created
  non-interactively at `kinko version` 0.1.8:
  `printf 'pw\npw\n' | kinko init --path <temp scope> --profile default
  --kinko-dir <temp dir> --force --keychain-preflight off` exits 0, and
  `printf 'pw\n' | kinko unlock ...` exits 0 with `kinko status` reporting
  `unlocked`. Against that unlocked vault, with the store's own argv:
  `set-key KEY --confirm=false` with the record on stdin exits 0 (`KEY set`);
  `get KEY --force` exits 0 and prints `********`; `get KEY --reveal --force`
  exits 0 and returns the record byte-identical; `delete KEY --yes` exits 0
  (`deleted`); and afterwards both `get KEY --force` and `delete KEY --yes`
  exit 1 with stderr `secret not found`. Probed before any write, a key that
  does not exist answers exit 1 / `secret not found` on both `get` and
  `delete`. The three store-unavailable markers were re-confirmed unchanged:
  locked vault `get` exit 1 / `locked`, `set-key` exit 1 / `locked`, `delete`
  exit 13 / `Failed to load vault.`; empty `--kinko-dir` `set-key` exit 12 /
  `Vault mutation in progress.`. Only synthetic record material was written.

  **Two kinko side effects found while probing, both now handled.** First,
  `kinko init --kinko-dir <dir>` rewrites the bootstrap config at
  `~/.config/kinko/bootstrap.toml` so every later kinko command defaults to
  `<dir>`; the first round-trip run therefore left the operator's kinko
  pointing at a deleted temporary directory, and `kinko status`,
  `kinko config show`, and `kinko config set` all failed until the file was
  restored to `kinko_dir="/Users/taco/.local/kinko"` by hand. The suite now
  passes `--config <temporary file>` on every command and asserts the
  operator's bootstrap config is byte-identical after the run; re-verified by
  diff. Second, an unlock session is not isolated by `--kinko-dir` or `--path`:
  unlocking the disposable vault makes `kinko status` report `unlocked` for
  every scope. The suite is therefore enabled only when the operator's own
  scope reports `locked`, and it locks the session again before returning, so
  it cannot end a session it did not start. `kinko status` for the operator's
  scope was `locked` before this session and is `locked` after it. The review's
  R1/R5 guidance to use `--path $HOME` was not followed for this reason: a
  temporary path scope is used instead, so no disposable record can collide
  with a real one.

  **Changes.** `Sources/WrikeGatewayCore/Auth/KinkoCredentialStore.swift`: the
  missing-record marker (exit 1 with stderr `secret not found`) is pinned in
  production classification next to the store-unavailable table, and
  `requireMissingRecord` replaces the permissive fall-through, so `load`
  returns `nil`, `hasRecord` returns `false`, and `delete` returns `false` only
  on that marker while every other non-zero exit throws; `delete(_:)` is back
  to a single `kinko delete KEY --yes` invocation, which removes the second
  kinko call and the window between the existence check and the delete.
  `Tests/WrikeGatewayCoreTests/Auth/KinkoCredentialStoreTests.swift` follows the
  single invocation (delete contract, no-op, unopenable vault, flag inventory
  now 4 invocations) and gains two tests that an unrecognised failure is never
  a missing record and that the marker, not the exit code alone, decides.
  `Tests/WrikeGatewayCoreTests/Auth/KinkoRoundTripTests.swift` is new: an
  opt-in real-vault round trip. `Tests/WrikeGatewayCoreTests/Auth/
  SystemProcessRunnerTests.swift` is new: the concurrent-drain regression test
  plus stream separation and missing-executable coverage.
  `Tests/WrikeGatewayCLITests/CommandFrameEndToEndTests.swift` takes an
  `any CredentialStore` seam and adds an end-to-end test that `auth logout`
  against an unavailable store exits 4 with `FILE_OPERATION_FAILED` and prints
  no `removedLocalRecord` field at all.
  `design-docs/specs/design-authentication.md` records the missing-record
  marker, the single-invocation delete, the two kinko side effects, and a
  narrowed Status block. The auth global completion criterion is checked, with
  the live Wrike authorization exchange named as what remains.

  **Verification.** `swift build` pass; `task build` pass; `swift test` and
  `task test` pass with 220 tests in 36 suites; `swiftlint` reports 0
  violations in 89 files. `WRIKE_GATEWAY_KINKO_INTEGRATION=1 swift test
  --filter storeCommandsParse` passes against the installed kinko 0.1.8.
  `WRIKE_GATEWAY_KINKO_ROUNDTRIP=1 swift test --filter roundTrip` passes
  against a real unlocked vault. The new drain test was proved non-vacuous by
  temporarily restoring the sequential drain: the test then failed with
  `Time limit was exceeded: 60.000 seconds` instead of passing. The temporary
  edit was reverted and the suite re-run green. `git status --short` shows the
  pre-existing staged `flake.lock` unmodified.

  **Defects fixed from review.** F9 silent logout no-op surviving on the
  existence-check path, and the design-doc invariant that asserted otherwise
  (medium); F10 incorrect blocking condition on the auth completion criterion
  (medium); F11 missing regression test for the concurrent-drain fix (low).

  **Outstanding work, blocking plan closure.** Three field-history rows and two
  attachment binary-transfer rows remain unimplemented with their blocking
  conditions recorded; the two reader-coverage criteria and the lifecycle move
  stay unchecked for that reason.

### 2026-08-05 (session 8): surface store failures on the auth status path

**Finding addressed.** Review F12 (medium). The previous entry fixed the
classification of an unreadable kinko vault inside `KinkoCredentialStore`, but
`CredentialResolver.status(hasCallbackIdentity:)` discarded the resulting throw
with `let state = try? await loadState()`. The signal was destroyed one call
level above the fix, so `auth status` answered a locked, corrupt, or unreadable
vault with `mode: null` and exit `0`. `AuthCommands.status()` could not have
surfaced it in any case, because it never took a throwing path. The defect class
is the same one F6 and F9 closed on the other two store-reading paths; this was
the third and last of them. The design doc added in `ee926a7` asserted the
opposite, which made the documentation wrong as well as the code.

**Live probe that demonstrated it, before the fix.** Against the operator's real
locked vault (`kinko status --path $HOME --profile default` reports `locked`):

    WRIKE_GATEWAY_API_CLIENT_ID=review-probe-client \
    WRIKE_GATEWAY_API_CLIENT_SECRET=<redacted> \
    swift run wrike-gateway-reader auth status

exited `0` and printed
`{"data":{"callbackIdentityAvailable":false,"clientConfigured":true,"expired":false,"expiresAt":null,"host":null,"mode":null,"refreshStateAvailable":false,"scopes":[]}}`.
An operator reads that as "no credential is configured" and runs `auth oauth2`,
burning a fresh authorization on a vault that already holds a valid, rotatable
refresh token, when the fix is `kinko unlock`.

**After the fix, same probe, same vault:** exit `6` and
`{"data":null,"errors":[{"extensions":{"code":"FILE_OPERATION_FAILED","recovery":"Run `kinko unlock` (or `kinko init` if no vault exists yet), then retry."},"message":"The credential store is locked."}]}`.
The probe is read-only: it never unlocks, never mutates, and reveals no secret.
`kinko status` reported `locked` before and after.

**Exit-code correction.** The 2026-08-05 (session 7) entry above records the
`auth logout` store-failure test as exiting `4`. That is wrong: `.localResource`
is `6` per the exit-code table in `design-docs/specs/command.md`, which is what
the test asserts and what the binary returns. The test was and is correct; only
the log wording was not.

**Changes.** `Sources/WrikeGatewayCore/Auth/CredentialProvider.swift`:
`status(hasCallbackIdentity:)` is now `async throws` and calls
`try await loadState()`. The two answers stay distinct -- `nil` still means no
access token, no client configuration, or a store that answered and had no
record, and still produces the `mode: null` report with exit `0`. The same
function no longer swallows the permanent-token base-URL error (F13, low):
`try permanentTokenCredential()?.baseURL.host` replaces
`(try? permanentTokenCredential())?.baseURL.host`, so a missing or rejected
`WRIKE_GATEWAY_API_BASE_URL` exits `3` with `AUTHENTICATION_FAILED` instead of
reporting mode `permanentToken` with `host: null` for a configuration that
cannot serve a single request. `Sources/WrikeGatewayCore/CLI/AuthCommands.swift`:
`status()` wraps the resolver call in do/catch and maps a caught `GatewayError`
through the existing `Self.failure(error)`, mirroring `logout()`.
`CommandFrame.swift:116` needed no change, since `status()` remains
non-throwing to its caller.

**Tests.** `Tests/WrikeGatewayCLITests/CommandFrameEndToEndTests.swift` gains
`authStatusSurfacesStoreFailure`, reusing the existing `UnavailableCredentialStore`
seam that session 7 added and left unused for status. It asserts exit
`.localResource`, `FILE_OPERATION_FAILED` and `kinko unlock` in the output, and
the absence of both `"mode":null` and `"refreshStateAvailable":false`, so a
regression that reports an unavailable store as an empty one fails rather than
passes. `authStatusSurfacesInvalidBaseURL` covers F13. `authStatusWithoutIdentity`
and `authStatusPermanentToken` stay green unchanged: permanent-token mode with a
valid base URL returns before `loadState()` runs.

**Documentation.** `design-docs/specs/design-authentication.md` keeps the
invariant sentence, which R1 through R3 make true, and adds the fixed list of
enforcing paths (store `load`/`hasRecord`/`delete`; resolver `loadState`,
`status`, `logout`; CLI `status`, `logout`) with the rule that no layer on the
list may use `try?` on a store call, so the next reviewer checks a list instead
of re-deriving the property. The Redaction section now separates "safe report"
from "report that always succeeds" and names the two cases reported as errors.

**Verification.** `swift build` pass; `task build` pass; `swift test` and
`task test` pass with 222 tests in 36 suites (up from 220); `swiftlint` reports
0 violations in 89 files. `git status --short` shows the pre-existing staged
`flake.lock` unmodified and untouched.

**Defects fixed from review.** F12 `auth status` reporting an unavailable
credential store as no credential (medium); F13 `auth status` reporting
permanent-token mode with a null host for a rejected base URL (low).

**Outstanding work, blocking plan closure.** Unchanged: three field-history rows
and two attachment binary-transfer rows remain unimplemented with their blocking
conditions recorded; the two reader-coverage criteria and the lifecycle move
stay unchecked for that reason. **Closed on 2026-08-05 by the entry below.**

### 2026-08-05 (session 9): close the five remaining reader rows and the plan

**What this session closed.** The only work blocking plan closure since session 6
was the five unimplemented reader rows. Both blocking conditions were resolved
on their own terms rather than by narrowing the matrix: the three field-history
routes were located and confirmed in the official reference, and the file-output
contract the two attachment binary-transfer rows required was designed,
implemented in core, and tested. Every task box and every global completion
criterion is now checked, so the plan moves to `impl-plans/completed/`.

**Upstream revalidation (TASK-001 scope, for the five rows only).** The three
history routes were found through the official reference index at
`https://developers.wrike.com/llms.txt`, which the earlier sessions had not
consulted; that index is why they were previously recorded as unconfirmable.
Each was then read individually and confirmed:
`GET /contacts/{contactIds}/contacts_history`, kind `contactsHistory`, data
`ContactChangeHistory{id, billRateHistory, costRateHistory}` over
`BudgetRateHistoryItem{rateValue, rateSource, startDate, endDate}`, `fields`
accepting `billRate` and `costRate`;
`GET /folders/{folderIds}/folders_history`, kind `foldersHistory`, data
`{id, project{plannedCost, plannedFees, actualCost, actualFees, budget}}`;
`GET /tasks/{taskIds}/tasks_history`, kind `tasksHistory`, with the same four
metrics at the top level and no `budget`. All three take an `updatedDate`
instant range with `start`/`end`, bound each `{...Ids}` path segment at 1000
entries, and accept scopes Default/wsReadOnly/wsReadWrite.
`GET /attachments/{attachmentId}/download` and
`GET /attachments/{attachmentId}/preview` were confirmed to answer with
`application/octet-stream`, with `preview` accepting exactly
`w44`, `w100`, `w200`, `w300`, `w400`, `h400`. No route was inferred or
substituted.

**The file-output contract (new core behavior).** `WrikeRequest` gains a
`WrikeResponseSink`, `WrikeResponse` gains a `DownloadedFile`, and one core type
`ResponseSinkDelivery` decides for every transport when a body reaches disk. The
live `URLSession` transport streams into a temporary file via
`session.download(for:)` and the test transports hold canned bytes in memory,
but both call the same delivery, so the tested write rule is the production
write rule; `ResponseSinkDeliveryTests` asserts the two entry points agree on
eleven status codes. The rules: only a `2xx` body is content, so a JSON error
envelope is never written to the caller's path and a refused download leaves no
file and no temporary file behind; a download never replaces an existing file,
refused both by local pre-validation and again at the write, so the window
between them cannot clobber; the file is created `0600`; and the success body is
never held in a `WrikeResponse`, an error description, or a snapshot. A
capability declaring a `destinationPath` argument without a `fileOutput` result,
or the reverse, or an optional destination, or a mutation that writes a file, is
rejected by `CapabilityRegistry.init`, which runs at binary startup.

**Reader registrations.** `contacts.history`, `folders.history`, and
`tasks.history` join the eight work-hierarchy namespaces; `attachments.download`
and `attachments.preview` join the collaboration views. Reader now registers 33
query fields. Writer and admin are unchanged in their own tiers and remain
cumulative. Two argument facilities were added because these rows needed them
and neither existed: `ArgumentValueType.enumerationList`, so `fields` is a
curated enumeration whose unaccepted value fails locally by name instead of
becoming an upstream 400; and `ArgumentDefinition.maximumCount`, which enforces
the documented 1000-entry id bound before an over-long URL is assembled.

**One defect found and fixed in this session's own work.** The schema printer's
`collectInput` handled `.enumeration` but not `.enumerationList`, so the printed
reader schema named `ContactHistoryField`, `FolderHistoryField`, and
`TaskHistoryField` without defining them: an invalid SDL document. The existing
"printed schema matches the linked capability metadata exactly" test could not
catch it, because it compares the printer against itself and both sides were
equally wrong. The printer is fixed and
`schemaDefinesEveryTypeItNames` now walks every type reference in each binary's
printed schema and fails on any undefined name. That test was proved
non-vacuous by temporarily restoring the printer bug: it then failed with the
three undefined enums on all three binaries, and passed again after the fix was
restored.

**Changes.** Core: `Transport/WrikeRequest.swift`,
`Transport/ResponseSinkDelivery.swift` (new),
`Transport/URLSessionWrikeTransport.swift`,
`Capabilities/CapabilityDefinition.swift`, `Capabilities/ArgumentCoercion.swift`,
`Capabilities/CapabilityPlanner.swift`, `Capabilities/ModelShape.swift`,
`Capabilities/ResponseProjection.swift`, `Capabilities/CapabilityExecutor.swift`,
`GraphQL/GraphQLSchemaPrinter.swift`, `GraphQL/GraphQLSelectionProjection.swift`.
Reader: `Schema/HistoryModels.swift` (new), `Contacts/ContactCapabilities.swift`,
`Contacts/ContactModels.swift`, `Folders/FolderCapabilities.swift`,
`Tasks/TaskCapabilities.swift`, `Attachments/AttachmentCapabilities.swift`,
`Schema/WrikeReadClient.swift`. Tests:
`WrikeGatewayReadTests/FieldHistoryTests.swift` (new),
`WrikeGatewayReadTests/AttachmentTransferTests.swift` (new),
`WrikeGatewayCoreTests/Transport/ResponseSinkDeliveryTests.swift` (new),
`WrikeGatewayCoreTests/Capabilities/FileOutputContractTests.swift` (new),
`WrikeGatewayReadTests/ReadCapabilityCoverageTests.swift`,
`WrikeGatewayCLITests/LoopbackScenarioTests.swift`,
`WrikeGatewayCLITests/BinaryBoundaryTests.swift`,
`WrikeGatewayCLITests/CommandFrameEndToEndTests.swift`,
`WrikeGatewayCoreTests/Redaction/RedactionTests.swift`, and the four test-support
files. Docs: `README.md`, `design-docs/specs/design-capability-matrix.md`,
`design-docs/specs/design-graphql-contract.md`,
`design-docs/specs/design-wrike-api-client.md`, and this plan.

**Test coverage added.** Every new capability has recording-transport success and
failure coverage and SDK/GraphQL planner parity. The envelope harness and the
file-output harness are kept disjoint by an explicit test, because the envelope
assertions about `kind` and `data` would pass vacuously against a binary body.
The three history rows additionally cover the comma-joined path segment, a
single id, an empty list, exactly 1000 ids, 1001 ids, the JSON-encoded
`updatedDate` filter, an all-optional range being dropped rather than sent as
`{}`, a field value accepted for folders and rejected for tasks, both rate
collections, the folder-only `project` nesting, and a metric missing its
required window. The two attachment rows additionally cover the write itself,
`0600` permissions, an upstream failure writing nothing, an existing
destination, a missing parent, a directory destination, an unaccepted preview
size, and the absence of bytes from the envelope. Three loopback tests run the
real `URLSession` transport against the loopback server for a streaming
download, a refused download, and a preview size on the wire.

**Verification, all passing on 2026-08-05.** `swift build`; `task build`;
`swift test` and `task test`, 269 tests in 40 suites (up from 222);
`swiftlint`, 0 violations in 94 files;
`git diff --check -- design-docs impl-plans Package.swift Sources Tests`;
`LC_ALL=C rg -n '[^ -~]' design-docs impl-plans`, no matches; `git status
--short`. Schema comparison across the three binaries: reader 33 queries and 0
mutations, writer 33 queries and 27 mutations with 0 `delete*` fields, admin 33
queries and 36 mutations with exactly 9 deletes. `nm` symbol inspection:
`wrike-gateway-reader` contains 0 `WrikeGatewayWrite` and 0 `WrikeGatewayAdmin`
symbols, `wrike-gateway-writer` contains 0 `WrikeGatewayAdmin` symbols, and no
binary contains `WrikeGatewayTestSupport`. Live probes against the built reader
with no credentials configured: an occupied destination exits `6` with
`FILE_OPERATION_FAILED` before any credential is resolved; an unaccepted preview
size and an unaccepted history field each exit `2` with `VALIDATION_ERROR`
naming the accepted set; a valid, unoccupied destination reaches
`AUTHENTICATION_FAILED` with exit `3`, and no file was created in any case.
`git status --short` shows the pre-existing staged `flake.lock` unmodified: it
still reports 113 insertions and its size and mtime are unchanged from the start
of the session.

**Capability status changes.** `implemented`: `contacts.history`,
`folders.history`, `tasks.history`, `attachments.download`,
`attachments.preview`. No capability remains `planned`. `unsupported` is
unchanged at `workflows.get` and `users.list`.

**Residual risks, recorded rather than closed.** The live Wrike authorization
exchange and refresh rotation against `login.wrike.com` remain unexercised, as
recorded against the auth criterion; they need an operator browser session and a
registered OAuth application. No capability has been exercised against a real
Wrike account: every route, envelope kind, and field set is verified against the
official reference and replayed through canned responses, so a documentation
error upstream would not be caught here. The gateway does not itself compare a
download's `Content-Length` against the bytes written; it relies on the
transport to surface a truncated response as a transport failure, which was not
exercised because the loopback server always sends the length it declares.
