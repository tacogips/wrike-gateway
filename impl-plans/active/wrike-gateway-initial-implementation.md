# Wrike Gateway Initial Implementation

**Status**: In Progress
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

- [ ] Updated `Package.swift` with four cumulative library products, three
      executable products, and role-specific test targets.
- [ ] `Sources/WrikeGatewayCore/` with transport, authentication, stable
      models, GraphQL runtime, capability metadata, command frame, and errors.
- [ ] `Sources/WrikeGatewayRead/`, `Sources/WrikeGatewayWrite/`, and
      `Sources/WrikeGatewayAdmin/` with tier-owned adapters and schema
      registrations.
- [ ] `Sources/WrikeGatewayReaderCLI/main.swift`,
      `Sources/WrikeGatewayWriterCLI/main.swift`, and
      `Sources/WrikeGatewayAdminCLI/main.swift`.
- [ ] `Tests/WrikeGatewayCoreTests/`, `Tests/WrikeGatewayReadTests/`,
      `Tests/WrikeGatewayWriteTests/`, `Tests/WrikeGatewayAdminTests/`, and
      `Tests/WrikeGatewayCLITests/` with recording-transport, loopback,
      redaction, schema, and binary-link assertions.
- [ ] Canned success and failure fixtures for every resource area.
- [ ] Updated progress and design status records after implementation behavior
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

- [ ] Every planned capability has a verified upstream method or an explicit
      blocked/unsupported state.
- [ ] `deleteProject`, the excluded initial `users` collection,
      `TRANSPORT_FAILED`, required `WRIKE_GATEWAY_API_BASE_URL`, and all four
      pending product decisions remain explicit.
- [ ] No secret value or staged `flake.lock` content is read into logs or
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

- [ ] Four library targets, three executable targets, and five test targets
      match the accepted architecture names.
- [ ] SDK products are cumulative and consumer imports are documented by the
      manifest structure.
- [ ] Shared public values compile under Swift 6 concurrency checking.
- [ ] No source or test target remains named `AppCore`, `AppCLI`, or
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

- [ ] Recording transport and loopback tests cover success, pagination, 400,
      401, 403, 404, 429, 500, malformed payloads, redirects, and timeouts.
- [ ] Only GET operations retry automatically; mutation outcome-unknown errors
      remain explicit.
- [ ] `TRANSPORT_FAILED` remains distinct from `UPSTREAM_UNAVAILABLE`.
- [ ] Permanent-token mode fails locally without a validated
      `WRIKE_GATEWAY_API_BASE_URL`.
- [ ] Authentication tests cover credential precedence and empty values,
      approved-host and `/api/v4` validation, clock skew, scope checks, and
      atomic credential-store failure.
- [ ] OAuth refresh rotation is atomic and single-flight.
- [ ] Loopback OAuth tests cover callback state/path/host validation, missing
      code, OAuth error, timeout, code exchange, TLS redirect rejection, and
      rejection of every redirect URI override.
- [ ] OAuth callback startup accepts only the fixed trusted localhost Keychain
      identity and fails safely before listener or browser activity for every
      invalid identity state documented in the authentication design.
- [ ] TLS identity handling exports neither private-key material nor a
      production override and emits no certificate or Keychain record data.
- [ ] Unsupported GraphQL syntax and fields fail before authentication or
      network access.
- [ ] Core planner contract tests prove typed SDK and GraphQL requests cannot
      select different capability, tier/scope validation, adapter, or stable
      error mapping for the same operation.
- [ ] Secret-bearing values are absent from stdout, stderr, logs, snapshots,
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

- [ ] All assigned work-hierarchy matrix rows have typed SDK and Query coverage
      across the eight resource adapter namespaces, matching verified
      capability ids.
- [ ] Reader adapters use only GET-backed reviewed operations.
- [ ] Folder/project semantics and the excluded `users` collection match the
      accepted GraphQL contract.
- [ ] Every capability has recording-transport success and failure tests.
- [ ] Paired SDK/GraphQL tests prove planner and adapter parity for every
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

- [ ] All six assigned resource families have typed SDK and Query coverage
      matching verified capability ids.
- [ ] Reader behavior performs no create, update, delete, upload, or webhook
      state change.
- [ ] Attachment bytes, comment text, and webhook secrets are absent from
      diagnostics and snapshots.
- [ ] Every capability has recording-transport success and failure tests.
- [ ] Paired SDK/GraphQL tests prove planner and adapter parity for every
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

- [ ] Reader schema covers all twelve accepted resource areas without mutation
      fields.
- [ ] Reader help, schema, SDK imports, and binary linkage expose no write or
      admin capability.
- [ ] Reader end-to-end responses use the documented JSON and error envelopes.

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

- [ ] Writer is cumulative with reader and exposes every implemented reviewed
      create/update capability.
- [ ] Writer schema and linkage contain no delete mutation or admin target.
- [ ] File, membership, copy, and webhook-state inputs are bounded and
      explicitly validated.
- [ ] Mutations do not retry automatically and report ambiguous transport
      outcomes safely.
- [ ] Paired SDK/GraphQL tests prove planner and adapter parity for every
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

- [ ] All supported reviewed DELETE operations exist only in admin.
- [ ] `deleteProject` is present when its verified upstream mapping is
      supported and remains distinct from `deleteFolder`.
- [ ] Destructive inputs reject wildcard, recursive, implicit descendant, and
      unbounded bulk behavior.
- [ ] Delete operations never retry automatically or infer success from a
      dropped response.
- [ ] Paired SDK/GraphQL tests prove planner and adapter parity for every
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

- [ ] All products build and all unit, contract, loopback, CLI, and boundary
      tests pass.
- [ ] Target names, product names, executable names, environment variables,
      capability ids, fields, tiers, and stable error codes are mutually
      consistent.
- [ ] Reader cannot link or dispatch writes/deletes; writer cannot link or
      dispatch deletes.
- [ ] Redaction and no-production-test-hook assertions pass.
- [ ] `task build`, `task test`, and `swiftlint` pass in one clean verification
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

- [ ] Documentation states only behavior demonstrated by tests.
- [ ] Pending user decisions remain visible and use the repository format.
- [ ] The progress log contains dated results for every verification command.
- [ ] The plan moves to `impl-plans/completed/` only after all global criteria
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

- [ ] The package publishes cumulative SDK products `WrikeGatewayCore`,
      `WrikeGatewayRead`, `WrikeGatewayWrite`, and `WrikeGatewayAdmin`.
- [ ] The three canonical executables build and expose only their linked tier.
- [ ] The capability inventory covers all twelve required resource areas;
      writer has no DELETE operation and every implemented DELETE is admin-only.
- [ ] The SDK and GraphQL paths share capability identifiers, validation,
      the same capability-execution planner and adapters, stable models, and
      error mapping; paired parity tests pass in every tier.
- [ ] OAuth2, refresh rotation, kinko storage, permanent-token precedence,
      data-center host validation, and redaction satisfy the accepted auth
      design.
- [ ] The canonical environment variables are exactly
      `WRIKE_GATEWAY_API_CLIENT_ID`, `WRIKE_GATEWAY_API_CLIENT_SECRET`,
      `WRIKE_GATEWAY_ACCESS_TOKEN`, and `WRIKE_GATEWAY_API_BASE_URL`.
- [ ] Recording transport and loopback canned-response tests cover every
      implemented capability and required failure class.
- [ ] `deleteProject`, `TRANSPORT_FAILED`, the excluded initial `users`
      collection, canonical environment variables, products, executables, and
      capability tiers remain consistent across code, tests, and docs.
- [ ] `task build`, `task test`, `swift test`, and `swiftlint` pass.
- [ ] No unrelated release, packaging, source, or staged `flake.lock` change is
      included.
- [ ] Every task has a dated progress entry, checked completion criteria, and
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
