# OAuth Callback Strategy

## Question

After the initial fixed registered TLS loopback callback at
`https://localhost:8765/callback` and operator-provisioned macOS login Keychain
identity labeled `wrike-gateway.oauth.localhost`, should a future release
automate certificate provisioning, allow configurable registered HTTPS
callbacks or identity labels, or define a manual handoff that does not expose
the client id or OAuth state through process output?

## Answer

Keep the fixed TLS loopback callback and fixed Keychain identity label for the
initial release. A future release should add an opt-in guided setup command
that generates a localhost certificate and imports it under the fixed label
with explicit user confirmation for the trust change; no silent trust
modification. Configurable callback URIs, alternate identity labels, and
manual authorization-URL handoff stay out of scope because they widen the
surface for leaking the client id and OAuth state. Decided on 2026-08-05 by
user delegation to the assistant's recommendation.
