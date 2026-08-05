# Capability Matrix Design

## Status

Draft

## Tier Rules

Capabilities are cumulative:

- `reader` contains read-only GET operations and local schema/auth inspection;
- `writer` contains reader plus reviewed create and update operations, including
  membership changes and attachment upload, but no HTTP DELETE operation; and
- `admin` contains writer plus reviewed HTTP DELETE operations.

"None in v4 baseline" means the official API v4 reference inspected on
2026-08-05 does not list that operation for the resource family. It does not
authorize inventing an equivalent destructive update. The implementation must
validate each row against the current official OpenAPI description.

## Resource-by-Operation Matrix

| Resource area | Reader operations | Writer additions, no delete | Admin-only delete operations | Representative capability ids |
| --- | --- | --- | --- | --- |
| Contacts | list/query contacts; query field history | modify contact | None in v4 baseline | `contacts.list`, `contacts.get`, `contacts.history`, `contacts.update` |
| Users | query user and user types | modify user | None in v4 baseline | `users.get`, `users.types.list`, `users.update` |
| Groups | list/query groups | create group; modify group or membership; bulk modify | delete group | `groups.list`, `groups.get`, `groups.create`, `groups.update`, `groups.delete` |
| Accounts / spaces | query account, access roles, spaces, and space details | modify account; create/update space and membership | delete space | `account.get`, `account.update`, `spaces.list`, `spaces.get`, `spaces.create`, `spaces.update`, `spaces.delete` |
| Folders / projects | list tree/search; query by id and field history | create folder/project; copy; bulk update; update | delete folder/project | `folders.list`, `folders.get`, `folders.history`, `folders.create`, `folders.copy`, `folders.update`, `folders.delete`, `projects.list`, `projects.get`, `projects.create`, `projects.update`, `projects.delete` |
| Tasks | search by account/folder/space; query by ids and field history | create; update; bulk update | delete task | `tasks.list`, `tasks.get`, `tasks.history`, `tasks.create`, `tasks.update`, `tasks.delete` |
| Comments | list by account/folder/task; query by ids | create on folder/task; update | delete comment | `comments.list`, `comments.get`, `comments.create`, `comments.update`, `comments.delete` |
| Attachments | list by account/folder/task; query metadata; download, preview, or obtain URL | upload to folder/task; update metadata or version | delete attachment | `attachments.list`, `attachments.get`, `attachments.download`, `attachments.upload`, `attachments.update`, `attachments.delete` |
| Timelogs | list by account/user/folder/task/category; query by ids | create; update | delete timelog | `timelogs.list`, `timelogs.get`, `timelogs.create`, `timelogs.update`, `timelogs.delete` |
| Custom fields | list by account/space; query by ids | create account custom field; modify | None in v4 baseline | `customFields.list`, `customFields.get`, `customFields.create`, `customFields.update` |
| Workflows | list account workflows; query by ids | create; modify | None in v4 baseline | `workflows.list`, `workflows.get`, `workflows.create`, `workflows.update` |
| Webhooks | list/query webhooks and status | create account/folder/space webhook; suspend/resume state | delete webhook | `webhooks.list`, `webhooks.get`, `webhooks.create`, `webhooks.update`, `webhooks.delete` |

Every operation whose upstream method is DELETE appears only in the admin
column. A future DELETE endpoint must default to admin even before this matrix
is updated; it cannot be inferred into writer from its resource family.

## GraphQL Naming Rules

- Read singletons use singular field names such as `task(id:)`.
- Collections use plural field names such as `tasks(filter:page:)`.
- Mutations use explicit verbs: `createTask`, `updateTask`, `deleteTask`.
- Project-owned names use `folder` and `project` semantics even when both map
  to Wrike's folders endpoint family.
- Folder and project public fields use distinct capability ids, including
  `folders.delete` and `projects.delete`, even when they share a Wrike path
  family.
- Capability ids use a stable plural resource namespace and operation verb.
- A GraphQL field cannot be registered unless its capability id, tier,
  endpoint, auth scopes, stable input/output, and test fixture are registered.

## Validation and Scope Rules

Wrike scopes vary by endpoint and account plan. Capability metadata records
all accepted upstream scopes and the least-privilege recommended scope. The
planner rejects known scope mismatches before transport when token metadata is
available; Wrike remains authoritative when a permanent token provides no
inspectable scope metadata.

Writer operations that remove a relationship without deleting a resource,
such as removing a member from a space, remain update operations only when the
official endpoint uses POST or PUT. Their inputs must name the relationship
explicitly and must not expose recursive or wildcard removal.

## Destructive Operation Rules

- Admin delete mutations require one explicit resource id per operation unless
  a separately reviewed bulk endpoint defines bounded ids.
- No `force`, recursive, wildcard, "all", or implicit descendant delete is in
  the initial contract.
- The response returns the confirmed deleted id or a stable outcome-unknown
  error; local success is never inferred from a dropped connection.
- Automatic retry is disabled.
- Admin schema and SDK documentation label delete methods as destructive.

## Coverage State

The matrix is a design inventory, not an implementation claim. Each capability
is tracked as `planned`, `implemented`, `blockedByScope`, `blockedByPlan`, or
`unsupported`. A capability becomes `implemented` only when the SDK method,
role-specific GraphQL registration, adapter mapping, auth metadata, stable
error mapping, and canned-response tests are all present.

## References

- `design-docs/specs/architecture.md`
- `design-docs/specs/design-graphql-contract.md`
- `design-docs/specs/design-wrike-api-client.md`
- Wrike API v4 reference index: `https://developers.wrike.com/reference/`
- Wrike webhook guide: `https://developers.wrike.com/docs/webhooks`
