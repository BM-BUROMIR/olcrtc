# Provider identities for managed Telemost and WB profiles

Date: 2026-07-13
Status: approved design

## Goal

Replace provider-specific static credentials with a managed identity layer that can:

- keep the owner's Telemost and WB rooms healthy for the current shared-testing cohort;
- let each user later sign in to Telemost and WB from OLC and receive independent rooms;
- rotate rooms and publish encrypted per-device bootstrap objects without exposing provider credentials;
- isolate authorization failures so one user or provider cannot break other profiles.

The first rollout keeps the owner's rooms shared with explicitly authorized testers. Per-user provider
login is the target state and uses the same data model and control-plane interfaces from the start.

## Current findings

- Telemost room creation uses an authenticated Yandex web session stored as cookies. The existing
  managed rotation already creates and rotates rooms from this session.
- WB uses an account bearer to create or own rooms and to exchange a room ID for LiveKit
  `roomToken` and `serverUrl` credentials.
- The current WB bearer was validated against the live `connection-details` endpoint and returned
  usable credentials. It is not an expiring JWT and must be validated against the API rather than by
  decoding an `exp` claim.
- A WB guest can register and join an existing public room, but guest authorization is not a valid
  substitute for owner room creation. Managed owner profiles must never silently fall back to guest.
- An earlier verified WB owner flow skipped guest registration and guest join, then called
  `connection-details` with the owner bearer. The current source must be brought back to that
  behavior before managed WB publication is enabled.

## Domain model

### User

A person allowed to enroll devices and provider identities.

```text
User
  id                  stable opaque identifier
  display_name        non-secret operator label
  status              active | disabled
```

### Device

An installed OLC instance. Existing per-device bootstrap encryption remains the delivery boundary.

```text
Device
  id
  user_id
  enabled
  allowed_profiles
  bootstrap_key
```

### ProviderIdentity

An independently managed login to one external carrier.

```text
ProviderIdentity
  id
  user_id
  provider            telemost | wbstream
  credential_ref      reference into SecretStore
  status              active | reauth_required | disabled
  last_validated_at
  last_error_code      classified, non-secret error
  current_generation
  current_room_ref
```

There is at most one active identity per `(user_id, provider)` in the first production version.

### ManagedProfile

A provider room and tunnel configuration published to a user's authorized devices.

```text
ManagedProfile
  id
  identity_id
  provider
  room
  channel
  tunnel_key
  transport
  generation
  issued_at
  expires_at
```

Provider credentials are never fields of `ManagedProfile` and never enter a client bootstrap.

## Provider adapter contract

Both providers implement the same control-plane boundary:

```text
begin_login(user) -> LoginChallenge
complete_login(challenge, response) -> credential_ref
validate_identity(identity) -> IdentityHealth
create_room(identity) -> ProviderRoom
issue_server_credentials(identity, room) -> ServerCredentials
revoke(identity)
```

The adapter returns typed errors such as `authorization_expired`, `authorization_rejected`,
`provider_unavailable`, `room_expired`, and `rate_limited`. Raw HTTP bodies, cookies, bearer tokens,
phone numbers, and one-time codes are not written to application logs.

### Telemost adapter

- Stores an authenticated Yandex web-session cookie jar in `SecretStore`.
- Creates rooms through the existing Telemost conferences API.
- Treats TLS, DNS, timeout, and 5xx failures as transient and retries them with bounded backoff.
- Treats 401/403 as `reauth_required`; it does not create a guest identity.
- Rotates before the known room expiry window and uses the existing activate, probe, publish, commit
  transaction.

### WB adapter

- Stores the WB Stream account bearer in `SecretStore`.
- Creates rooms through the owner room endpoint using the owner bearer.
- Exchanges the room ID for `roomToken` and `serverUrl` using the owner bearer.
- Does not call guest registration or guest join for an owner-managed profile.
- Uses guest mode only for an explicitly configured unmanaged diagnostic profile, never as fallback.
- Validates the bearer against WB Stream API behavior because the current token format has no `exp`
  claim.

## Login experience

OLC exposes separate `Sign in to Telemost` and `Sign in to WB` commands. Provider login is optional
while a user is assigned to the owner's shared profile.

### Primary browser flow

1. OLC requests a short-lived login challenge from the control-plane.
2. OLC opens the provider login in `ASWebAuthenticationSession`.
3. The user authenticates only on the provider-controlled page.
4. A verified callback completes the challenge.
5. The control-plane stores the resulting provider credential and returns only identity status.

The callback contains an opaque one-time code, not a bearer or cookie jar. Challenges expire after
five minutes and can be consumed once.

### Fallback flow

WB may use a versioned phone and one-time-code adapter if no usable browser callback is available.
The phone number and code are accepted only for the active challenge, held in memory for the request,
and never persisted or logged. The adapter can be disabled remotely when WB changes its private API.

If Telemost does not expose a usable callback, its fallback is an isolated `WKWebView` that loads
only the provider login. Native code does not receive form fields or passwords. After the user is
authenticated, OLC exports the resulting Yandex session cookies once over authenticated TLS to the
control-plane, waits for live credential validation, and clears the isolated web data store. OLC
does not ask the user to copy cookies or paste tokens.

## Shared owner rollout

Initially the owner has one active Telemost identity and one active WB identity. The owner and
Malyutin devices are both authorized for profiles generated from these identities.

- Each device receives an independently encrypted bootstrap object.
- Disabling a device stops future publication for that device without rotating credentials for all
  other devices.
- Provider credentials remain server-side and are not shared with Malyutin's device.
- When Malyutin later enrolls his own identity, only his device-to-profile assignments change. The
  owner's profiles and devices continue without interruption.

## Rotation and server processes

Each active identity has an independent rotation state and server activation unit. A failed WB
rotation cannot roll back a successful Telemost profile or another user's room.

The transaction order is:

1. validate provider identity;
2. ensure or create a provider room;
3. render a complete server candidate;
4. activate and wait for a stable server process;
5. run provider connection, HTTPS, and bounded 1 MiB probes;
6. publish encrypted objects for every required authorized device;
7. commit generation and room state.

Publication or commit failure restores published objects and server configuration. Authorization
failure stops before activation and changes the identity to `reauth_required`.

Server processes use stable identity-derived names and separate private configuration files. They do
not embed provider credentials in command lines or systemd unit text.

## Secret storage

`SecretStore` is an interface separate from identity metadata. The first implementation uses
AES-256-GCM envelope encryption with a host master key supplied by macOS Keychain or a systemd
credential. The master key, encrypted credential blobs, and decrypted runtime files are excluded
from git.

Requirements:

- authenticated encryption with a unique nonce per write;
- identity and provider bound as associated data;
- atomic writes with restrictive ownership and mode;
- no decrypted credentials in logs, crash reports, bootstrap objects, or test artifacts;
- explicit credential deletion on identity revoke;
- startup failure when the master key is unavailable rather than plaintext fallback.

## Error handling and user state

- `active`: recent validation succeeded and rotation may proceed.
- `reauth_required`: provider returned an authentication rejection. Existing cached client bootstrap
  remains available until its expiry, but no new generation is published.
- `disabled`: operator or user revoked the identity; its server process is stopped and future
  publication is disabled.
- Transient provider failures leave identity status unchanged, retry with bounded backoff, and emit a
  non-secret operational alert.
- Reauthentication replaces credentials atomically, validates them, then resumes rotation. Invalid
  new credentials do not overwrite the last known credential.

OLC shows provider status and a `Sign in again` command. It does not display raw provider errors or
technical credentials.

## Security boundaries

- The iOS app receives tunnel configuration, never WB/Yandex credentials.
- A bootstrap key authorizes one device and one allowed profile set.
- Login challenges bind user, provider, device, nonce, and expiry.
- Control-plane administrative APIs require authenticated enrollment and enforce user ownership.
- Rate limits apply per user, provider, device, and source address.
- Provider response bodies are sanitized before persistence or reporting.
- Shared owner access is explicit in device policy and can be revoked independently.

## Verification

### Automated tests

- provider adapter contract tests for success and typed errors;
- WB regression proving owner flow never calls guest registration or guest join;
- Telemost and WB `reauth_required` transitions on 401/403;
- transient retry tests that do not rotate or disable an identity;
- SecretStore encryption, associated-data mismatch, tamper rejection, and atomic replacement;
- one-time login challenge expiry and replay rejection;
- per-user and per-device authorization isolation;
- rotation rollback ordering and generation monotonicity;
- log and artifact scans for credentials and developer-machine paths.

### Live verification

For each provider:

1. authenticate the owner identity;
2. create a fresh room and publish the owner's profile;
3. connect a physical iPhone 11 through the managed profile;
4. run ten rounds of public IP, HTTPS page, and complete 1 MiB download probes;
5. restart only the provider server and verify automatic recovery;
6. force room rotation and verify the device fetches the next generation;
7. authorize a second device against the shared owner profile and repeat a bounded smoke test;
8. invalidate a test credential and verify `reauth_required` without guest fallback or impact on the
   other provider.

## Rollout

1. Restore and verify the WB owner credential path, add WB to managed rotation, and publish the
   shared owner profile to the current devices.
2. Generalize the current Telemost rotation around `ProviderIdentity` and `SecretStore` without
   changing its deployed behavior.
3. Add identity status and reauthentication endpoints.
4. Add OLC browser login UI and challenge callback handling.
5. Add the versioned WB one-time-code fallback only if browser callback testing proves insufficient.
6. Enroll Malyutin's own provider identities and move only his device assignments from shared to
   personal profiles.
7. Move scheduling from a logged-in Mac LaunchAgent to an always-on control-plane host before
   expanding beyond the private test cohort.

## Non-goals for the first rollout

- Public self-service registration.
- Sharing provider credentials between users or devices.
- Storing provider passwords.
- Silent guest fallback for managed profiles.
- Supporting more than one active identity per user and provider.
- Declaring WB ready before physical iOS rotation and recovery tests pass.
