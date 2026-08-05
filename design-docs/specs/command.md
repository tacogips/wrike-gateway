# Command

## Status

Draft

## Binaries

| Binary | Linked capability | Public schema |
| --- | --- | --- |
| `wrike-gateway-reader` | `WrikeGatewayCore` + `WrikeGatewayRead` | Query only |
| `wrike-gateway-writer` | reader + `WrikeGatewayWrite` | Query plus non-delete Mutation |
| `wrike-gateway-admin` | writer + `WrikeGatewayAdmin` | Full reviewed Query and Mutation |

All binaries share the same command grammar and JSON envelope. Their thin
entry points select a role and pass arguments and environment into shared core
command handling.

## Common Command Surface

```bash
<binary> [--pretty] graphql query '<document>' [--variables '<json-object>']
<binary> [--pretty] graphql query-file <path> [--variables-file <path>]
<binary> graphql schema
<binary> auth oauth2
<binary> auth status
<binary> auth logout
<binary> --help
<binary> --version
```

`graphql query` is canonical for both GraphQL queries and mutations, matching
the x-gateway command shape. `query-file` avoids shell quoting for automation.
Exactly one inline or file-based document is accepted, and variables must
decode to a JSON object.

`graphql schema` renders the linked role-specific schema. It never fetches
schema from Wrike. `auth logout` removes local OAuth token state; it is not a
Wrike resource delete and is available in all three executables.

## Reader Example

```bash
wrike-gateway-reader graphql query \
  'query { task(id: "IEAAAAAAKQAB5FNY") { id title status assignees { id name } } }'
```

```json
{
  "data": {
    "task": {
      "id": "IEAAAAAAKQAB5FNY",
      "title": "Prepare launch",
      "status": "Active",
      "assignees": [{"id": "KUAAAAAA", "name": "Alex Example"}]
    }
  },
  "extensions": {
    "requestId": "request-uuid"
  }
}
```

The same request is valid in writer and admin binaries because tiers are
cumulative.

## Writer Examples

```bash
wrike-gateway-writer graphql query \
  'mutation { createTask(input: { folderId: "IEAAAAAAI4AB5FNY", title: "Prepare launch" }) { task { id title } } }'
```

```json
{
  "data": {
    "createTask": {
      "task": {"id": "IEAAAAAAKQAB5FNY", "title": "Prepare launch"}
    }
  },
  "extensions": {
    "requestId": "request-uuid"
  }
}
```

```bash
wrike-gateway-writer graphql query \
  'mutation { updateTask(input: { taskId: "IEAAAAAAKQAB5FNY", status: COMPLETED }) { task { id status } } }'
```

Writer mutations map only to create or update capabilities. A delete field is
absent from the writer schema and also rejected as a tier violation if a
pre-parsed operation reaches dispatch.

## Admin Example

```bash
wrike-gateway-admin graphql query \
  'mutation { deleteTask(input: { taskId: "IEAAAAAAKQAB5FNY" }) { deletedId } }'
```

```json
{
  "data": {
    "deleteTask": {"deletedId": "IEAAAAAAKQAB5FNY"}
  },
  "extensions": {
    "requestId": "request-uuid"
  }
}
```

Admin delete inputs require an exact opaque identifier. The CLI provides no
wildcard, recursive-delete default, or implicit bulk-delete behavior.

## Attachment Input

Attachment upload is a writer operation because it creates Wrike content:

```bash
wrike-gateway-writer graphql query \
  'mutation { uploadTaskAttachment(input: { taskId: "IEAAAAAAKQAB5FNY", filePath: "/tmp/brief.pdf" }) { attachment { id name } } }'
```

The adapter validates that `filePath` names a readable regular file before
opening it. Attachment bytes are sent as the Wrike upload body and are never
embedded in diagnostic output. Deleting an attachment remains admin-only.

## Authentication Commands

```bash
wrike-gateway-reader auth oauth2
wrike-gateway-reader auth status
wrike-gateway-reader auth logout
```

`auth oauth2` reads the client id and secret from kinko-provisioned
`WRIKE_GATEWAY_API_CLIENT_ID` and
`WRIKE_GATEWAY_API_CLIENT_SECRET`. It opens the authorization URL through the
operating-system browser API and never writes that URL, its OAuth state, the
client id, authorization codes, access tokens, refresh tokens, permanent
tokens, or client secrets to stdout, stderr, or logs. The initial contract has
no manual-URL output mode. The redirect URI must use HTTPS, match the Wrike
application registration, and resolve to the fixed initial loopback listener at
`https://localhost:8765/callback`. The initial command accepts no redirect URI
flag or environment override. Before browser launch, it requires one valid,
trusted certificate/private-key identity in the current user's macOS login
Keychain under the fixed label `wrike-gateway.oauth.localhost`. Missing or
invalid identity state fails with exit code `3`; the command does not generate,
import, export, or trust certificates. The resolved callback strategy is
documented in `design-docs/user-qa/qa-oauth-callback.md`: the fixed callback
and identity label stay, a future release adds opt-in guided certificate
setup, and configurable callbacks and manual handoff stay out of scope.

`auth status` reports only the selected credential kind, account host, scopes,
expiry status, whether refresh state is available, and whether a valid callback
TLS identity is available. This last value is a boolean and exposes no
certificate or Keychain record data. If
`WRIKE_GATEWAY_ACCESS_TOKEN` is present, OAuth login and refresh state are not
used for that process. Permanent-token mode also requires
`WRIKE_GATEWAY_API_BASE_URL`; there is no host default or token-based discovery.
A missing or invalid base URL fails locally before any Wrike request.

## Validation

- Documents must contain exactly one executable operation.
- Operation type must be allowed by the linked schema.
- Fields, arguments, variables, enum values, and selection sets are validated
  before authentication or network access.
- Wrike IDs are non-empty opaque strings of at most 256 supported characters;
  they are not case-normalized or structurally parsed.
- Page size is bounded by the capability's upstream maximum; continuation
  tokens are opaque and cannot be combined with filters that differ from the
  original request.
- Unknown raw REST paths, methods, fields, and query parameters are rejected.
- Delete operations are registered only by `WrikeGatewayAdmin`.

## Output and Exit Codes

JSON business output goes to stdout. Usage diagnostics and non-business
process failures go to stderr. `--pretty` changes whitespace only.

GraphQL execution failures use a stable envelope:

```json
{
  "data": null,
  "errors": [{
    "message": "Mutation deleteTask requires the admin capability tier.",
    "extensions": {
      "code": "CAPABILITY_DENIED",
      "requestId": "request-uuid",
      "requiredTier": "admin"
    }
  }]
}
```

Secret values, raw authorization headers, and raw upstream response bodies are
never included in error extensions.

| Exit code | Meaning |
| --- | --- |
| `0` | successful command |
| `2` | CLI usage or local GraphQL validation error |
| `3` | credential missing, invalid, expired without refresh, or insufficient scope |
| `4` | Wrike rejected a valid request or resource was not found |
| `5` | rate limit or transient upstream failure |
| `6` | local file or credential-store failure |
| `70` | unexpected internal failure |

## Help and Version

Invoking a binary without arguments prints its own help and exits `0`.
`--help` names only commands linked into that binary. `--version` prints a
single semantic version line and performs no credential or network access.

## References

- `design-docs/specs/architecture.md`
- `design-docs/specs/design-graphql-contract.md`
- `design-docs/specs/design-capability-matrix.md`
- `design-docs/specs/design-authentication.md`
