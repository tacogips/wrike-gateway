# Notes

## Status

Draft

## Design Baseline

- Documentation baseline date: 2026-08-05.
- Workflow mode: issue-resolution.
- Issue reference: workflow-supplied title only; no GitHub repository, number,
  or URL was provided.
- `x-gateway` supplies the project-owned GraphQL command and capability-planner
  reference.
- `apple-gateway` supplies the thin multi-executable command-frame reference.
- No codex-agent reference input applies to this design.

## Reference Traceability

The local reference roots are `../x-gateway` and `../apple-gateway`, relative
to the `wrike-gateway` repository root. Paths below are relative to the named
reference repository root.

| Reference | Concrete paths and modules | Adapted behavior |
| --- | --- | --- |
| `x-gateway` | `design-docs/specs/design-graphql-command-surface.md`; `design-docs/specs/design-public-graphql-contract.md`; `design-docs/specs/design-api-inventory.md`; `Package.swift`; `Sources/XGatewayCore/XGatewayGraphQLSchema.swift`; `Sources/XGatewayRead/main.swift`; `Sources/XGatewayWrite/main.swift` | direct `graphql query` and `graphql schema` commands; project-owned field registry and capability planner; link-separated reader/writer entry points |
| `apple-gateway` | `Package.swift`; `Sources/AppleGatewayCLI/main.swift`; `Sources/AppleGatewayReaderCLI/main.swift`; `Sources/AppleGatewayCore/CLI/Command.swift` | thin executable entry points selecting a role and delegating to shared command handling |

The reference inspection used `sed -n` for the listed Markdown, manifest, and
entry-point files and `rg --files Sources design-docs impl-plans` to inventory
their module and document layouts. No code, schema, or command output is copied
verbatim into this design.

Wrike-specific divergences are intentional: this project adds an admin tier,
uses four capability library targets, models the Wrike hierarchy instead of X
timelines, and publishes three executables. It also avoids apple-gateway's
single-core runtime-role boundary because reader and writer code must be
excluded at link time. GraphQL-specific divergences are detailed in
`design-docs/specs/design-graphql-contract.md#intentional-divergence-from-x-gateway`.

## Canonical Names

- Libraries: `WrikeGatewayCore`, `WrikeGatewayRead`,
  `WrikeGatewayWrite`, `WrikeGatewayAdmin`.
- Executables: `wrike-gateway-reader`, `wrike-gateway-writer`,
  `wrike-gateway-admin`.
- OAuth client environment: `WRIKE_GATEWAY_API_CLIENT_ID`,
  `WRIKE_GATEWAY_API_CLIENT_SECRET`.
- Permanent-token environment: `WRIKE_GATEWAY_ACCESS_TOKEN`.
- Permanent-token data-center environment: `WRIKE_GATEWAY_API_BASE_URL`.
- Capability tiers: reader, writer, admin.

These names are normative across specifications and the implementation plan.

## Resolved User Decisions

All four launch decisions were resolved on 2026-08-05 (user delegated to the
assistant's recommendation); the answers confirm the conservative defaults:

- OAuth callback: registered TLS loopback
  `https://localhost:8765/callback`, with no HTTP downgrade or authorization-URL
  output; the operator provisions one trusted certificate/private-key identity
  in the macOS login Keychain under `wrike-gateway.oauth.localhost`. A future
  release adds an opt-in guided certificate setup command. See
  `design-docs/user-qa/qa-oauth-callback.md`.
- Token storage: kinko-backed records with no plaintext fallback; one default
  account record initially, multi-account representable later. See
  `design-docs/user-qa/qa-token-storage.md`.
- GraphQL rollout: all twelve resource families in the first stable release,
  stabilized capability by capability as each reaches `implemented`; no
  generated full OpenAPI schema. See
  `design-docs/user-qa/qa-graphql-rollout.md`.
- Webhooks: manage registration and state only; no callback delivery hosting.
  See `design-docs/user-qa/qa-webhook-runtime.md`.
