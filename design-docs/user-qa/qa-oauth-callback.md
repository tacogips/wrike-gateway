# OAuth Callback Strategy

## Question

After the initial fixed registered TLS loopback callback at
`https://localhost:8765/callback` and operator-provisioned macOS login Keychain
identity labeled `wrike-gateway.oauth.localhost`, should a future release
automate certificate provisioning, allow configurable registered HTTPS
callbacks or identity labels, or define a manual handoff that does not expose
the client id or OAuth state through process output?

## Answer

Superseded on 2026-08-06 by the answer below. The original answer, kept for the
record, was: keep the fixed TLS loopback callback and fixed Keychain identity
label, add an opt-in guided certificate setup command in a future release, and
rule out configurable callbacks and manual handoff.

## Revised Answer

The callback does not use TLS and does not use the Keychain at all. The account
owner directed that the CLI must not use the Keychain, and exercising the
original design against a real account showed why that is also the better
engineering choice:

- Provisioning the identity required the operator to create a certificate and
  approve a macOS trust-store change, which only a human at the keyboard can
  authorize.
- RFC 8252 section 7.3 specifies `http` for a native application's loopback
  redirect precisely because such an application cannot hold a certificate a
  browser will trust for `localhost`.

The callback is now `http://localhost:<port>/callback`, served by a plain HTTP
listener bound to the loopback interface for the duration of one login. The
loopback bind is the property that keeps the authorization code on the machine;
state validation, exact host/port/path matching, the single-request lifetime,
and the bounded timeout are unchanged.

The port is configurable through `WRIKE_GATEWAY_OAUTH_CALLBACK_PORT`, defaulting
to `8765`, because Wrike matches registered redirect URIs exactly and the
registered port differs per application. The scheme, host, and path remain fixed
with no override, and no CLI flag carries any of them. Automated certificate
provisioning, alternate identity labels, and manual authorization-URL handoff
are all moot and remain out of scope.
