# Live Wrike Verification, 2026-08-06

> **Reconciliation note, added 2026-08-06 by the second review-and-improve
> pass.** This document records what a live session observed at the time it ran.
> Two commits landed after it and changed the auth boundary it describes:
> `8a45649` moved the OAuth callback to plain HTTP on the loopback interface and
> removed the Keychain, and `1934c87` sends the token exchange under a policy
> that admits the login host. The recorded live outcomes below are unchanged;
> the forward-looking claims they imply are corrected in place and are marked
> as reconciliation notes. See "Auth Boundary as of the Reconciliation" and
> "Verification Counts" for the current state.

## Status

Completed against an account-owner-authorized real Wrike account at the
`www.wrike.com` data center. Permanent-token authentication and the `/api/v4`
base were already configured and were not changed. The access token,
authorization header, personal names, email addresses, live account values,
request identifiers, pagination tokens, and machine-local temporary paths are
not recorded here.

The live run found four implementation or catalog defects. All were corrected
with covering tests. The dedicated verification container and every object
successfully created inside it were removed from active work. No webhook was
created, no browser was opened, no token was requested, and nothing was pushed.

Documents below preserve the sent operation and field names. Session-owned
identifiers, the opaque page token, and temporary paths are normalized as
`<session-...>`, `<next-page-token>`, and `<temporary-path>` so the report does
not retain account-identifying values.

## Authentication and Endpoint

- `auth status`: success; mode `permanentToken`, host `www.wrike.com`.
- Account query: success against the authorized account; account identity is
  intentionally omitted.
- API data center: `https://www.wrike.com/api/v4`.
- Token value and authorization header: never printed or stored.

The OAuth authorize endpoint separately returned HTTP 400 with
`Redirect uri is missing or invalid` for
`https://localhost:8765/callback`. That URI is not registered for the Wrike
application. This was recorded, not changed: the operator can register the
default URI or set `WRIKE_GATEWAY_OAUTH_CALLBACK_PORT` to the registered port.

**Reconciliation note.** The `https` redirect URI above is what the code sent on
the day of this run. It is no longer what the code sends. Since `8a45649` the
redirect URI is `http://localhost:8765/callback`: plain HTTP bound to the
loopback interface, per RFC 8252 section 7.3, because a native application
cannot hold a certificate a browser will trust for `localhost`. The
loopback-only bind is the security property that replaces TLS, and no Keychain,
`SecIdentity`, or `SecTrust` dependency remains. The URI that must be registered
for the Wrike application is therefore the `http` one, not the `https` one
recorded above.

## Reader Schema Inventory

`swift run wrike-gateway-reader graphql schema` reported 33 query fields. The
capability list below is derived from that output rather than from guessed API
names.

| Area | Schema fields |
| --- | --- |
| contacts | `contact`, `contacts`, `contactsHistory` |
| users | `user`, `userTypes` |
| groups | `group`, `groups` |
| accounts/spaces | `accessRoles`, `account`, `space`, `spaces` |
| folders/projects | `folder`, `folders`, `foldersHistory`, `project`, `projects` |
| tasks | `task`, `tasks`, `tasksHistory` |
| comments | `comment`, `comments` |
| attachments | `attachment`, `attachments`, `attachmentDownload`, `attachmentDownloadUrl`, `attachmentPreview` |
| timelogs | `timelog`, `timelogs` |
| custom fields | `customField`, `customFields` |
| workflows | `workflows` |
| webhooks | `webhook`, `webhooks` |

## Per-Area Live Outcomes

| Area | Documents sent | Outcome |
| --- | --- | --- |
| contacts | `{ contacts { id type deleted } }`; `query C($id: ID!) { contact(id: $id) { id type deleted } }` | Success. List and live by-id response decoded. |
| users | `{ userTypes { id title licenseType } }`; `query U($id: ID!) { user(id: $id) { id type deleted me } }` | By-id success. `userTypes` was `blockedByPlan`: HTTP 403, `AUTHORIZATION_FAILED`, upstream `not_allowed`. |
| groups | `{ groups { id title memberIds } }`; `query G($id: ID!) { group(id: $id) { id title memberIds } }` | Success. List and by-id response decoded. |
| accounts/spaces | `{ account { id name rootFolderId } }`; `{ spaces { id title accessType archived } }` | Success. The root folder ID used for the contained lifecycle came only from this response. |
| folders/projects | `{ folders { id title parentIds space project { customStatusId } } }`; `{ projects { id title parentIds project { customStatusId } } }`; `query F($id: ID!) { folder(id: $id) { id title parentIds } }` | Success. Folder tree, project projection, and by-id response decoded. |
| tasks | `{ tasks(page: { pageSize: 1 }) { nodes { id title status parentIds hasAttachments } pageInfo { resultCount nextPageToken } } }`; `query T($id: ID!) { task(id: $id) { id title status parentIds } }` | Success. First page returned a real next-page token; by-id response decoded. |
| comments | `{ comments(limit: 1) { id text taskId folderId } }`; `query { comment(id: "<session-comment-id>") { id taskId text } }` | Account-wide list was `blockedByPlan`: HTTP 403, `AUTHORIZATION_FAILED`, upstream `not_allowed`. The session-created comment decoded by ID. |
| attachments | `{ attachments { id name contentType taskId folderId size } }`; `query A($id: ID!) { attachment(id: $id) { id name contentType size taskId } }`; `query D($id: ID!, $destination: String!) { attachmentDownload(id: $id, destination: $destination) { path byteCount contentType } }` | Success. A real attachment downloaded to a new temporary file; reported and actual size were both 95,281 bytes. The temporary file was removed after verification. |
| timelogs | `{ timelogs(page: { pageSize: 1 }) { nodes { id taskId hours } pageInfo { resultCount nextPageToken } } }` | Success with an empty node list and a decoded page-info object. Create was separately `blockedByPlan` after the required inputs were supplied. |
| custom fields | `{ customFields { id title type } }`; `query CF($id: ID!) { customField(id: $id) { id title type } }` | Success. List and by-id response decoded. |
| workflows | `{ workflows { id name standard hidden } }` | Success. Live workflow envelope decoded. |
| webhooks | `{ webhooks { id status folderId spaceId } }` | Success with an empty list. Create/delete was not exercised because a real callback URL must not be registered for verification. |

## Pagination and Attachment Download

The first mise run page returned a non-empty opaque `nextPageToken`. The exact
follow-up document was:

```graphql
query P($token: String!) {
  tasks(page: { pageSize: 1, nextPageToken: $token }) {
    nodes { id title status }
    pageInfo { resultCount nextPageToken }
  }
}
```

Variables were `{ "token": "<next-page-token>" }`. The second page succeeded,
returned a different task, and returned another non-empty token.

The download document was:

```graphql
query D($id: ID!, $destination: String!) {
  attachmentDownload(id: $id, destination: $destination) {
    path
    byteCount
    contentType
  }
}
```

Variables were an existing live attachment ID and
`<temporary-path>/attachment.bin`. The destination did not exist before the
call. The file existed after the call, its byte count matched the stable result,
and the temporary directory was removed.

## Contained Mutation Lifecycle

One folder titled `wrike-gateway verification` was created under the account
root. Its ID was recorded immediately but is omitted here because cleanup
succeeded. No object outside that folder was created, modified, or deleted.

| Step | Document | Outcome |
| --- | --- | --- |
| create container | `mutation { createFolder(input: { parentFolderId: "<root-folder-id>", title: "wrike-gateway verification" }) { folder { id title parentIds } } }` | Success; `parentIds` confirmed the account root. |
| create task | `mutation { createTask(input: { folderId: "<session-container-id>", title: "verification task" }) { task { id title parentIds } } }` | Success; `parentIds` confirmed the dedicated container. |
| update task | `mutation { updateTask(input: { taskId: "<session-task-id>", description: "updated by verification" }) { task { id description parentIds } } }` | Success; the same task remained in the container. |
| create comment | `mutation { createComment(scope: { taskId: "<session-task-id>" }, input: { text: "verification comment" }) { comment { id taskId text } } }` | Success; `taskId` confirmed ownership. |
| create timelog, incomplete | `mutation { createTimelog(input: { taskId: "<session-task-id>", hours: 0.25, comment: "verification" }) { timelog { id taskId hours comment } } }` | `VALIDATION_ERROR`, HTTP 400, upstream `invalid_parameter`; exposed the missing local required-field validation. No ID was created. |
| create timelog, complete | `mutation { createTimelog(input: { taskId: "<session-task-id>", hours: 0.25, trackedDate: "2026-08-06", comment: "verification" }) { timelog { id taskId hours trackedDate comment } } }` | `blockedByPlan`: `AUTHORIZATION_FAILED`, HTTP 403, upstream `not_allowed`. No ID was created and no timelog delete was necessary. |
| upload attachment | `mutation U($file: String!) { uploadTaskAttachment(input: { taskId: "<session-task-id>", filePath: $file }) { attachment { id name taskId size contentType } } }` | Success with 32 bytes; `taskId` confirmed ownership. The malformed live filename exposed a header defect described below. |
| writer delete refusal | `mutation { deleteAttachment(input: { attachmentId: "<session-attachment-id>" }) { deletedId } }` through writer | Correctly refused locally with `CAPABILITY_DENIED`; no delete was sent. |
| reader mutation refusal | `mutation { createTask(input: { folderId: "<session-container-id>", title: "must not be created" }) { task { id } } }` through reader | Correctly refused locally with `CAPABILITY_DENIED`; no task was created. |
| admin delete attachment | `mutation { deleteAttachment(input: { attachmentId: "<session-attachment-id>" }) { deletedId } }` | Live response exposed `UPSTREAM_RESPONSE_INVALID`; a subsequent read returned `NOT_FOUND`, confirming deletion. Adapter fixed. |
| admin delete comment | `mutation { deleteComment(input: { commentId: "<session-comment-id>" }) { deletedId } }` | Live response exposed `UPSTREAM_RESPONSE_INVALID`; a subsequent read returned `NOT_FOUND`, confirming deletion. Adapter fixed. |
| admin delete task | `mutation { deleteTask(input: { taskId: "<session-task-id>" }) { deletedId } }` | Success with the exact created ID. |
| admin delete container | `mutation { deleteFolder(input: { folderId: "<session-container-id>" }) { deletedId } }` | Success with the exact created ID; performed last. |

Before admin deletion, fresh reads confirmed that the task belonged to the
container and the comment and attachment belonged to that task. Every delete
named an ID created in this session. After cleanup, attachment and comment reads
returned `NOT_FOUND`. Wrike task/folder deletion moves the subtree to the
Recycle Bin; a final read showed the container under the Recycle Bin and the
task under that deleted container. Nothing remains in active work, and there is
no undeleted session ID to report.

## Defects Found and Fixed

### Timelog create required fields

- Document: the incomplete `createTimelog` document recorded in the lifecycle
  table.
- Stable code: `VALIDATION_ERROR` after Wrike HTTP 400 `invalid_parameter`.
- Divergence: `CreateTimelogInput` and the typed SDK treated `trackedDate` and
  `comment` as optional. Wrike requires both. Canned fixtures omitted them and
  therefore did not exercise the live contract.
- Fix: both fields are required in the capability schema and typed SDK; missing
  either fails locally before credential resolution or transport. Writer
  fixtures and the lifecycle document now provide both.

### Attachment upload filename header

- Document: the `uploadTaskAttachment` document recorded in the lifecycle
  table.
- Stable code: none; the operation returned success.
- Divergence: the transport sent
  `X-File-Name: attachment; filename="verification.txt"`. Wrike treats the
  entire header value as the attachment name, so live metadata returned that
  whole string instead of `verification.txt`.
- Fix: the transport sends only the sanitized filename as `X-File-Name`. A
  loopback test now inspects that non-secret header value while continuing to
  retain no authorization-header value or attachment bytes.

### Empty successful attachment/comment delete envelopes

- Documents: the `deleteAttachment` and `deleteComment` documents recorded in
  the lifecycle table.
- Stable code before fix: `UPSTREAM_RESPONSE_INVALID` with
  `outcomeUnknown: true` for each.
- Divergence: live successful responses had an empty `data` collection, while
  the shared deletion adapter required an echoed string ID or entity carrying
  `id`. Subsequent by-ID reads returned `NOT_FOUND`, proving the operations had
  succeeded.
- Fix: only `comments.delete` and `attachments.delete` declare a reviewed
  empty-data confirmation policy. On a successful empty envelope, the result
  uses the planner's single already-validated path identifier. Every other
  delete still reports outcome unknown for empty data, malformed bodies,
  transport failures, and 5xx responses. The canned delete fixtures were
  corrected to empty `data` and are explicitly identified as live-derived,
  sanitized fixtures.

### Boundary catalog expectations

- Documents: reader `createTask`, reader `deleteTask`, writer `deleteTask`, and
  writer `deleteSpace` from `E2EScenarioCatalog.boundaryScenarios`.
- Stable code: `CAPABILITY_DENIED`.
- Divergence: the catalog expected `VALIDATION_ERROR`, although the existing
  runtime contract correctly identifies known higher-tier fields and names the
  required tier. The standalone boundary tests already asserted the correct
  code; only the new catalog fixture was wrong.
- Fix: all four catalog expectations now require `CAPABILITY_DENIED`. The raw
  REST-escape scenario was also corrected to expect local `VALIDATION_ERROR`
  and no transport response.

No live read produced a model-decoding field-type mismatch. The only
`UPSTREAM_RESPONSE_INVALID` results were the two live empty-delete envelope
divergences described above.

## Blocks and Intentionally Unexercised Operations

| Classification | Operation | Reason |
| --- | --- | --- |
| `blockedByPlan` | `userTypes` | HTTP 403, upstream `not_allowed`; Wrike documents this code for license/quota restrictions. |
| `blockedByPlan` | account-wide `comments` list | HTTP 403, upstream `not_allowed`; a created comment remained readable by ID. |
| `blockedByPlan` | `createTimelog` with complete required inputs | HTTP 403, upstream `not_allowed`; no timelog ID was created. |
| `blockedByScope` | none observed | The permanent token exposes no locally inspectable scope list; Wrike returned no scope-specific denial distinct from the plan blocks above. |
| not exercised | webhook create/delete | Verification must not register a real callback URL. Webhook list was exercised successfully. |
| not exercised | OAuth browser authorization | Credentials were already working, the browser was forbidden, and the redirect URI registration failure is recorded above. See the blocker below. |

### OAuth Login Blocker

Recorded by the second review-and-improve pass. A live OAuth login is blocked
outside the code and must not be retried until the blocker is cleared: with a
valid authorization code, Wrike's token endpoint answers `unauthorized_client`,
and a manual `curl` exchange using the same client id, client secret, and
redirect URI reproduces it exactly. The stored client secret therefore does not
match the registered Wrike application. This is a credential-registration
problem, not a gateway defect, so no code change can work around it. Clearing it
needs an operator to reconcile the Wrike application's client secret and its
registered `http://localhost:8765/callback` redirect URI with the values kinko
exports.

Until it is cleared, the authorization-code exchange, refresh rotation, and
single-flight refresh remain proved only through injected transports and the
real-socket loopback listener tests. The second pass reviewed exactly that gap
and fixed two defects a live run would have surfaced: a refresh response that
omits `scope` or `refresh_token`, which RFC 6749 sections 5.1 and 6 permit, no
longer empties the granted scopes or forces a new authorization; and a callback
request line split across TCP segments is now reassembled instead of parsed
partially into a truncated authorization code.

**Cleared on 2026-08-06.** The operator reconciled the client secret in kinko
with the Wrike application, and `auth oauth2` then completed end to end against
the live endpoint: the loopback HTTP listener received the redirect, the state
validated, the authorization-code exchange succeeded at `login.wrike.com`, and
the committed OAuth credential (mode `oauth2`, host `www.wrike.com`, refresh
state available) served a live `/api/v4` account read. Refresh rotation remains
unexercised live, since it needs a token near expiry; it stays proved against
injected transports and RFC 6749.

## Auth Boundary as of the Reconciliation

- Redirect URI: `http://localhost:8765/callback`, port configurable through
  `WRIKE_GATEWAY_OAUTH_CALLBACK_PORT`.
- Callback transport: plain HTTP, `requiredInterfaceType = .loopback`, one
  request per login, bounded lifetime. No TLS identity exists, so
  `AuthStatusReport` no longer carries `callbackIdentityAvailable`.
- Token exchange: sent under a policy whose allowlist is `login.wrike.com`
  only, kept separate from the API policy so an ordinary API request can never
  address the host that receives the client secret.
- Credential storage: kinko only. No Keychain, `SecIdentity`, or `SecTrust`
  dependency remains anywhere in the package.

## Scenario Suite

The shared catalog now contains:

- 18 reader scenarios covering all twelve resource areas, including live-ID
  capture for by-ID documents;
- 6 tier/input boundary scenarios;
- an 11-step lifecycle: create container, create/update task, create comment,
  create timelog, upload attachment, delete attachment, delete timelog, delete
  comment, delete task, and delete container.

`E2EScenarioReplayTests` adds three normal-suite tests. It runs every replayable
catalog document through `LoopbackHTTPServer`, runs the full lifecycle with
capture/interpolation, and checks area and cleanup inventory. It needs no
credential and changes no Wrike account.

`LiveE2EScenarioTests` adds two opt-in tests. It is skipped unless
`WRIKE_GATEWAY_LIVE_E2E=1`, `WRIKE_GATEWAY_ACCESS_TOKEN`, and
`WRIKE_GATEWAY_API_BASE_URL` are all non-empty. It executes the same catalog
with live identifiers captured from earlier list/account responses. Its
mutation test creates and removes one dedicated container, verifies every
created relationship before cleanup, and accepts only explicit
`AUTHORIZATION_FAILED` plan/scope blocks as non-defects.

Run the default replay suite:

```bash
mise run test
```

Run only the read and boundary half, which creates nothing:

```bash
kinko exec --force \
  --env WRIKE_GATEWAY_ACCESS_TOKEN,WRIKE_GATEWAY_API_BASE_URL -- \
  mise run test:live:read
```

Run the full live suite, including the mutation lifecycle that creates and then
removes a real container:

```bash
kinko exec --force \
  --env WRIKE_GATEWAY_ACCESS_TOKEN,WRIKE_GATEWAY_API_BASE_URL -- \
  mise run test:live
```

**Reconciliation note.** `mise run test:live:read` did not exist when this document
was written; the only documented live command ran both tests, so a read-only
check could not be requested without also running the mutation lifecycle. The
second pass added the read-only task and verified that
`swift test --filter 'LiveE2EScenarioTests/readsAndBoundaries'` selects exactly
one test.

The live runner was not executed after implementation during this session:
the manual lifecycle had already used the authorized one-container allowance.
The opt-in guard was verified with credentials present and the live flag absent;
the suite skipped cleanly and created nothing.

## Verification Counts

- Before: 307 tests in 43 suites passed; SwiftLint clean over 100 Swift files.
- After: 315 tests in 45 suites passed; SwiftLint clean with 0 violations
  across 101 Swift files.
- Required final gates: `mise run build`, `mise run test`, and `swiftlint` all passed.

**Reconciliation note.** The 315/45 over 101 files recorded above is stale. It
predates `8a45649`, which removed the Keychain-backed callback identity and the
files and suites that covered it. The baseline on `1934c87` is 313 tests in 44
suites over 99 Swift files, and the second review-and-improve pass raised it to
321 tests in 44 suites over 99 files. The count above is left as written because
it is what this session measured.
