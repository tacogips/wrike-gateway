# Public GraphQL Contract Design

## Status

Draft

## Goal

Provide a stable GraphQL-shaped contract for Wrike work management without
exposing arbitrary REST requests. The contract mirrors x-gateway's direct
`graphql query` command approach while adapting fields and relationships to
Wrike's account, space, folder/project, and task hierarchy.

## Ownership Boundary

- The schema is owned and versioned by `wrike-gateway`, not by Wrike.
- Top-level fields map to stable capability ids before any transport request.
- REST paths, HTTP methods, query encodings, optional upstream field lists,
  and response `kind` values remain adapter details.
- There is no raw REST, arbitrary URL, or arbitrary GraphQL passthrough.
- SDK methods execute the same capability planner and adapters as GraphQL.

## Role-Specific Schemas

`WrikeGatewayRead` registers Query fields.
`WrikeGatewayWrite` registers create/update Mutation fields.
`WrikeGatewayAdmin` registers delete Mutation fields. The schema printed by a
binary contains only fields linked into that binary.

The registry has two mechanically checked views:

1. public field definition: name, arguments, selection shape, and stable
   capability id; and
2. capability route: tier, auth scopes, endpoint adapter, and implementation
   status.

A mismatch in either direction is an internal error detected by tests.

## Initial Query Families

The initial full design reserves these field families, implemented in phases:

- `contact(id:)`, `contacts(filter:page:)`
- `user(id:)`, `userTypes`
- `group(id:)`, `groups(filter:page:)`
- `account`, `spaces(filter:page:)`, `space(id:)`
- `folder(id:)`, `folders(scope:filter:page:)`, `project(id:)`,
  `projects(scope:filter:page:)`
- `task(id:)`, `tasks(scope:filter:page:)`
- `comment(id:)`, `comments(scope:filter:page:)`
- `attachment(id:)`, `attachments(scope:filter:page:)`
- `timelog(id:)`, `timelogs(scope:filter:page:)`
- `customField(id:)`, `customFields(scope:filter:page:)`
- `workflow(id:)`, `workflows(filter:page:)`
- `webhook(id:)`, `webhooks(filter:page:)`

`scope` is a typed input that selects a reviewed account, space, folder,
project, task, user, or category relation. It does not accept a path string.

Wrike API v4 has no reviewed paginated user-list operation in the Users
resource family. Account people remain available through `contacts` with a
person-type filter; the initial contract does not alias that data as `users`.
Adding a `users` collection later requires a separately registered capability
with explicit Contacts-to-User mapping and pagination semantics.

## Initial Mutation Families

Writer fields include reviewed `create<Resource>` and `update<Resource>`
forms from the capability matrix, plus precise names for attachment upload and
webhook state changes. Examples include `createTask`, `updateTask`,
`createComment`, `uploadTaskAttachment`, `createTimelog`, `updateSpace`,
`createWebhook`, and `updateWebhookStatus`.

Admin fields include only supported upstream deletes: `deleteGroup`,
`deleteSpace`, `deleteFolder`, `deleteProject`, `deleteTask`, `deleteComment`,
`deleteAttachment`, `deleteTimelog`, and `deleteWebhook`. If the official API
adds another DELETE operation, it remains unavailable until an admin field is
separately reviewed.

`deleteFolder` and `deleteProject` preserve distinct public intent and stable
capability ids while mapping to Wrike's shared folders/projects endpoint
family. Their input objects use `folderId` and `projectId`, respectively; the
adapter does not expose the shared raw path to callers.

## Input Design

- Create and update mutations accept one named `input` object.
- Update and delete inputs require the resource id explicitly.
- Create inputs require the parent scope when Wrike requires it, such as
  `folderId` for task creation.
- Omitted optional fields mean "leave unchanged" for updates; explicit `null`
  is accepted only when the upstream capability has reviewed clear semantics.
- Local file inputs use `filePath`; arbitrary byte strings and remote URLs are
  not accepted for upload.
- Enums are project-owned and map explicitly to upstream values.
- Unknown input fields fail validation rather than being ignored.

## Pagination Contract

Collections return a stable connection-like shape:

```graphql
type TaskConnection {
  nodes: [Task!]!
  pageInfo: PageInfo!
}

type PageInfo {
  resultCount: Int!
  nextPageToken: String
}
```

`nextPageToken` is opaque. `pageSize` is clamped only by rejecting values above
the capability maximum, never by silently changing them. The returned token
can be used only with the same scope, filters, and optional field contract.

## Selection and Hydration

Projection occurs after stable model mapping. Unsupported selected fields fail
before transport. Relationship fields that require additional Wrike calls,
such as hydrated task assignees, declare that cost in the planner. The planner
deduplicates ids, batches only where a reviewed endpoint supports it, and
enforces per-request call limits.

Nested hierarchy traversal is bounded. No query implicitly walks an entire
account, space, folder tree, or task subtree.

## Error Contract

GraphQL errors use stable extension codes:

- `VALIDATION_ERROR`
- `CAPABILITY_DENIED`
- `AUTHENTICATION_FAILED`
- `AUTHORIZATION_FAILED`
- `NOT_FOUND`
- `RATE_LIMITED`
- `UPSTREAM_UNAVAILABLE`
- `TRANSPORT_FAILED`
- `UPSTREAM_RESPONSE_INVALID`
- `FILE_OPERATION_FAILED`
- `INTERNAL_ERROR`

Partial data is allowed only when independent top-level read fields are
executed and one fails. Mutations execute one top-level field per document in
the initial contract, avoiding ambiguous partial side effects.

## Initial Parser Scope

The first implementation may support a constrained GraphQL subset:

- exactly one named or anonymous operation;
- one top-level mutation field, or bounded multiple top-level query fields;
- variables from a JSON object;
- scalar, enum, null, list, and input-object values;
- nested selection sets;
- no fragments, directives, aliases, subscriptions, or introspection beyond
  the explicit local `graphql schema` command.

Unsupported syntax fails before credential resolution or network access.
Expanding parser syntax must not expand capability access.

## Example Hierarchy Query

```graphql
query ProjectWork($projectId: ID!, $page: PageInput) {
  project(id: $projectId) {
    id
    title
    tasks(page: $page) {
      nodes { id title status }
      pageInfo { resultCount nextPageToken }
    }
  }
}
```

Nested `Project.tasks` maps to the same reviewed task-list capability used by
the top-level `tasks(scope:)` field; it is not a distinct raw endpoint escape.

## Intentional Divergence from x-gateway

- Wrike hierarchy is modeled with typed scopes and relationships rather than
  X timelines or social graph fields.
- Role separation has three tiers instead of x-gateway's reader/writer split.
- Writer intentionally excludes all DELETE-backed mutations; admin owns them.
- The public contract supports JSON variables and query files from the first
  planned CLI frame because work-management inputs are often structured.
- No X transport fallback, persisted-query id, feature flag, or Cursor/Codex
  agent behavior appears in this contract.

## References

- `design-docs/specs/command.md`
- `design-docs/specs/design-capability-matrix.md`
- `design-docs/specs/design-wrike-api-client.md`
