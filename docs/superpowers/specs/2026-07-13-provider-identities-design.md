# Managed provider identities for Telemost and WB

Date: 2026-07-13
Status: reviewed design

## Goal

Build a production control plane that keeps Telemost and WB tunnel profiles usable without manual
configuration on each device. The first release uses operator-provisioned owner credentials and a
private device cohort. Later releases may add provider sign-in after the required provider flows are
proved on physical iOS devices.

The system must:

- isolate provider credentials from tunnel clients and edge-server configuration;
- give every installed device its own enrollment, tunnel credential, room/session, and revocation
  boundary;
- rotate rooms without invalidating the last known-good generation;
- survive scheduler restart, duplicate workers, host reboot, and object-storage retries;
- support staged migration from the owner's provider identity to a user's own identity.

## Proven facts and blocked assumptions

- Telemost room creation works with an authenticated Yandex cookie jar. Reusing rooms after repeated
  restarts can leave stale SFU peers, so each active device endpoint uses a fresh room.
- The current WB owner bearer successfully obtains `roomToken` and `serverUrl` for an existing room
  through `connection-details`. Owner-authenticated room creation has not been proved.
- A WB guest can join an existing public room but cannot create an owner room. Managed WB profiles
  never fall back to guest mode.
- A usable OAuth-style callback is not known for either provider. `ASWebAuthenticationSession`,
  WB phone/OTP, and Telemost cookie transfer remain discovery work, not release dependencies.
- Yandex sessions are sensitive to source-IP and anti-fraud changes. Telemost automation requires a
  dedicated account and a stable, tested non-RU egress.

The first WB release therefore uses an operator-created room and the verified owner
`connection-details` path. Managed WB room creation is enabled only after its live API contract is
captured and repeatedly verified without committing credentials or raw responses.

## Runtime cardinality

A provider identity is an account-level authorization source. It can own many device endpoints, but
an endpoint is never shared by simultaneously active devices.

```text
ProviderIdentity 1 --- N ProfileAssignment 1 --- N DeviceEndpoint
                              |
                              +--- N EndpointRevision --- N ProfileGeneration
```

The owner's account may authorize both the owner's and Malyutin's devices, but each device receives
a separate provider room, server unit, channel, and tunnel credential. This avoids peer matching
conflicts and makes revocation independent. Reusing one room is permitted only as an explicitly
labelled single-device diagnostic mode.

## Domain model

### User and Device

```text
User
  id                  stable opaque identifier
  display_name        non-secret operator label
  status              active | disabled

Device
  id
  user_id
  status              pending | active | revoked
  public_key
  enrolled_at
  last_seen_at
  highest_epoch_by_profile
```

No bootstrap decryption key or secret URL is packaged in the IPA. The bundle contains only a
non-secret rendezvous URL on a carrier domain verified to be reachable before VPN startup. On first
launch, OLC creates a Secure Enclave P-256 key shared with the app and tunnel extension through a
dedicated ThisDeviceOnly Keychain access group. A single-use, short-lived enrollment grant is
transferred out of band as a QR code or universal link.

Enrollment accepts the attested public key and nonce, verifies a challenge signature, and binds the
grant to the public-key hash, `user_id`, `device_id`, allowed providers, expiry, and one-time
consumption. Every later rendezvous request carries a fresh nonce and DPoP-style signature.

### ProviderIdentity and CredentialBundle

```text
ProviderIdentity
  id
  user_id
  provider            telemost | wbstream
  credential_ref
  credential_revision
  status              active | reauth_required | disabled
  operational_health  healthy | transient_failure | permission_denied |
                      account_challenged | provider_contract_changed
  last_validated_at
  last_error_code
  row_version

CredentialBundle
  schema_version
  provider
  secret_payload       encrypted provider-specific primary credential schema
  acquired_at
  validated_at
  expires_at           optional
  refresh_material     optional encrypted field
  provider_metadata    allowlisted, non-secret fields only
```

For Telemost, `secret_payload` is the minimized cookie jar; for WB it is the owner bearer. Unknown
fields are rejected rather than stored.

There is at most one active identity per `(user_id, provider)` in the first release. Transient
health is separate from authorization state. A 401 or 403 becomes `reauth_required` only when the
provider-specific endpoint and sanitized error code confirm credential rejection.

### Assignment, endpoint, and generation

```text
ProfileAssignment
  id
  identity_id
  user_id
  device_id
  state               pending | active | migrating | retired
  valid_from
  valid_until
  migration_id
  row_version

IdentityGrant
  id
  identity_id
  grantee_user_id
  grantee_device_id    optional narrowing
  scopes
  expires_at
  revoked_at

DeviceEndpoint
  id
  assignment_id
  provider
  state               active | migrating | retired
  row_version

EndpointRevision
  id
  endpoint_id
  room_ref
  server_unit
  channel
  tunnel_credential_ref
  state               preparing | publish_authorized | active | draining | failed | retired
  provider_expires_at
  fencing_token

ProfileGeneration
  id
  revision_id
  epoch
  generation
  object_key
  content_hash
  state               preparing | active | draining | failed | retired
  issued_at
  expires_at
  acknowledged_at
```

An active cross-user `IdentityGrant` is required before an assignment can reference another user's
identity. Rotation creates a new endpoint revision, not a second logical endpoint. Identity
migration may temporarily create two logical endpoints for the same device/provider, one per
assignment, until the shared assignment is retired.

The client profile contains only provider transport coordinates and its device-scoped tunnel
credential. Provider bearers, cookie jars, refresh material, and master keys never enter profiles,
edge command lines, systemd unit text, or the IPA.

## Provider adapter contract

```text
validate_identity(identity) -> IdentityHealth
refresh_identity(identity) -> CredentialBundle | NoRefreshAvailable
use_existing_room(identity, room_ref) -> ProviderRoom
create_room(identity) -> ProviderRoom
issue_server_credentials(identity, room, participant) -> ServerCredentials
provider_revoke(identity) -> RevocationResult
```

`create_room` is capability-gated per provider. WB starts with `use_existing_room`; Telemost starts
with the existing proved create-room API. Server credentials define audience, participant identity,
expiry, and refresh behavior. If reconnect needs fresh credentials, an edge process uses a
mutually-authenticated, endpoint-scoped control-plane API; it never stores the provider identity.

Adapters accept response cookie updates and atomically replace a credential bundle after validation.
They classify errors by provider, operation, HTTP status class, and allowlisted provider error code.
Raw exception strings, URLs, headers, response bodies, phone numbers, cookies, and tokens are never
passed to logs.

The first WB canary uses an operator-provisioned room inventory. Each room is owner-validated,
atomically reserved to one endpoint, and never concurrently reused. A low-watermark alert requests
replenishment; exhausted inventory blocks WB enrollment and rotation rather than reusing a room.
WB remains canary-grade, not production-ready, until proved `create_room` can replenish this
inventory automatically and recover without an operator.

WB server and device participants are explicit: the edge obtains an owner `connection-details`
credential for its participant, while the device obtains a short-lived guest participant credential
for that existing room through the authenticated control plane. Guest registration/join is allowed
only for the device participant and never substitutes for owner authorization or room creation. Both
credential lifetimes, reconnect issuance, and participant uniqueness are recorded by the WB
live-contract test before canary publication.

## Login discovery and future login protocol

The first release has no in-app provider login. Credentials are provisioned by the operator into
SecretStore and validated before activation.

Each future provider login is a blocking discovery milestone. A physical-device proof must record:

- the provider-controlled authorization entry point and exact callback ownership;
- credential exchange, refresh, expiry, logout, and provider-side revocation behavior;
- repeated operation from the production control-plane egress over several days;
- the minimum credential scope required for room creation and reconnect.

Only then may OLC expose that login method. A browser flow requires a 256-bit state, PKCE where
supported, exact redirect scheme/host/path validation, provider/issuer validation, and a
device-authenticated completion. The stored challenge secret is hashed and transitions atomically:

```text
created -> provider_pending -> consuming -> consumed | expired | cancelled
```

Older challenges are superseded, attempts are bounded, and account identity is confirmed before a
credential replaces the previous revision.

WB phone/OTP remains an optional experiment. It must bind the exact provider pre-auth session,
device, user, and normalized phone hash; enforce send and verification limits, resend cooldown,
generic anti-enumeration responses, short expiry, atomic consumption, and a remote kill switch.

Telemost `WKWebView` cookie transfer remains a high-risk experiment. It requires a non-persistent
data store, navigation allowlists, an exact cookie allowlist by name/domain/path/security/expiry,
rejection of third-party or unexpected cookies, bounded payloads, immediate local clearing, and
successful validation from production egress. If a narrowly scoped jar is insufficient, this flow
requires explicit consent and is not enabled for the private production cohort.

## Durable control plane

The scheduler runs on an always-on host before managed profiles are enabled. Telemost uses stable
non-RU egress and a dedicated provider account. Host migration is rehearsed without changing egress
unexpectedly.

State is stored in SQLite WAL mode with foreign keys and transactional migrations. One scheduler
owns a durable queue with bounded worker concurrency and provider rate budgets. Every identity or
endpoint mutation acquires a lease with TTL and monotonically increasing fencing token. Workers use
idempotency keys and compare-and-swap `row_version`; a stale worker cannot activate or publish.

Each server process has a unique endpoint-derived name and private config. Endpoint lifecycle keeps
candidate and previous server generations alive during an overlap window. Provider and server
side-effects use forward recovery; they are never described as transactionally rolled back.
The edge activator atomically stores the highest fencing token per endpoint and rejects lower tokens
for install, restart, and retire operations.

## Publication protocol

Encrypted profile objects are immutable:

```text
devices/<device>/profiles/<provider>/generations/<epoch>-<generation>.olcb
devices/<device>/profiles/<provider>/manifest.olcm
```

Generation encryption uses ephemeral P-256 ECDH, HKDF-SHA256, and AES-256-GCM with device ID, key ID,
epoch, generation, and content hash as AAD. The manifest uses canonical JSON and is signed by a
dedicated control-plane P-256 key; it includes signing and encryption key IDs, fencing token, epoch,
generation, hash, expiry, and previous generation. It is updated through a strongly consistent
publication gateway only after candidate activation and probes pass. The gateway atomically rejects
a fencing token below its per-profile watermark; object storage is payload storage, not the fencing
authority. Clients reject a lower `(epoch, generation)` than the highest accepted value for the same
`(device_id, provider)` stream, verify the signature and referenced hash,
and atomically persist anti-replay state in the shared ThisDeviceOnly Keychain access group before
activation.

Publication status and retries are per device. One offline or broken device does not block another
device's generation. The old revision remains draining until the new generation is acknowledged or
the bounded grace period expires. Immutable objects are retained for at least the maximum client
cache lifetime plus 24 hours.

The sequence is:

1. acquire endpoint lease and fencing token and persist an idempotent operation journal row;
2. validate or refresh the provider identity;
3. reserve a fresh provider room or fail without changing the active revision;
4. render and activate a candidate server;
5. run provider, HTTPS, and complete 1 MiB probes;
6. write an immutable encrypted generation;
7. fenced-CAS the revision to `publish_authorized`, then submit manifest CAS to the publication
   gateway, which atomically advances its fencing watermark;
8. reconcile the visible manifest into committed state and mark the old revision draining;
9. retire the old server after acknowledgement or grace expiry.

The manifest is cutover source of truth after CAS. The journal stores operation ID, expected and
resulting ETags, revision, hash, and fencing token before external effects. On response loss or
crash, a reconciler reads and verifies the gateway manifest. If it matches the authorized revision,
it completes the DB commit even if a newer lease now exists; a revision visible in a valid manifest
is never stopped as unreferenced. Otherwise it leaves the previous revision active and retires the
candidate. Crashes between every pair of steps are recovered idempotently.

A device acknowledgement is authenticated and bound to endpoint, epoch, generation, and hash. It is
accepted only after the device activates the VPN and completes an end-to-end IP, HTTPS, and download
probe through that revision. Fetch or decryption alone cannot retire the old revision.

## Revocation and migration

Ordinary device removal revokes enrollment, tombstones its manifest, rejects future authenticated
fetches, and stops its endpoint. Because credentials are device-scoped, other devices do not rotate.
The maximum control-plane revocation target is five minutes. A compromised-device action also
expires the endpoint immediately and rotates any legacy shared tunnel key before remaining devices
are considered safe.

Identity actions are distinct:

- `disable`: stop scheduling and endpoints;
- `local_delete`: cryptographically erase local credential material and runtime copies;
- `provider_revoke`: attempt provider logout or token invalidation and record only a redacted result.

If the provider has no revocation endpoint, the UI and runbook state the residual risk. Backups age
out encrypted revoked records under the retention policy; restoring a backup cannot lower credential
revision or publication epoch.

Migration from owner identity to a personal identity is staged:

```text
pending -> dual-published -> device-verified -> preferred-personal -> shared-retired
```

Each device acknowledges the personal generation independently. The shared assignment remains
available through a grace window and can be restored until retirement.

## Secret storage and disaster recovery

SecretStore uses versioned AES-256-GCM envelopes with a random per-record data-encryption key wrapped
twice: by the online non-exportable Keychain/KMS KEK and by an offline recovery KEK in a separate
failure domain. Each envelope records algorithm, key IDs, random nonce,
credential revision, and identity/provider/revision associated data. Rotation rewraps data keys
online; retired wrapping keys remain only for the documented recovery window.

Operator provisioning uses a privileged local command with a separate admin role and MFA. It reads
credentials only from TTY or a protected file descriptor, never argv or environment, encrypts
immediately, clears staging data, and emits only a redacted audit event.

Decrypted runtime files are restrictive, short-lived, and removed after process shutdown.
Production diagnostics that print provider responses are excluded from packaging. HTTP boundaries
map failures to allowlisted structured fields: provider, operation, status class, internal code,
retryability, request ID, and credential fingerprint.

`local_delete` is logical deletion until backup retention expires; the design does not claim instant
cryptographic erasure from backups. Backups retain credentials for at most 30 days and carry a
restore-time denylist of revoked credential IDs.

Encrypted state and object metadata are backed up at least every 15 minutes with the SQLite Online
Backup API to a separate failure domain, followed by integrity and foreign-key checks. Leases expire
during restore. The offline recovery KEK is independently stored with break-glass audit. Target RPO
is 15 minutes and RTO is two hours. A strongly consistent epoch allocator and append-only
credential revocation ledger in the backup failure domain store watermarks outside SQLite. The
ledger records maximum credential revision and every revoke/delete event per identity. Restore
first applies the ledger and denylist, then reserves a new epoch range above the allocator watermark
before workers start. It fails closed if either external authority is unavailable.

## Observability

Structured metrics and redacted events cover:

- validation age and result by provider;
- queue depth, lease contention, stale-worker rejection, and rotation duration;
- active/draining/failed endpoints and manifest adoption lag;
- time until credential, room, and generation expiry;
- probe latency, complete bytes, throughput, reconnects, and server restarts.

Alerts fire when validation is older than two scheduler intervals, three consecutive rotations fail,
expiry is under two hours without a candidate, manifest adoption exceeds five minutes for an online
device, or no scheduler heartbeat is seen for two intervals. Each alert links to a checked-in
runbook for reauthentication, provider outage, stuck rotation, revocation, and restore.

## Verification gates

Automated tests cover adapter contracts; WB owner flow without guest calls; error classification;
credential refresh; SecretStore tamper and anti-rollback behavior; enrollment replay; lease fencing;
CAS conflicts; process death after every publication step; duplicate schedulers; stale and partial
object-storage reads; device authorization isolation; migration states; and seeded canary-secret
scans of every production log sink.

For each provider on a physical iPhone 11:

1. cold install, one-time enrollment, VPN permission, update over the installed build, lock/unlock,
   device reboot, app backgrounding, Wi-Fi/cellular transition, and temporary offline operation;
2. ten consecutive rounds with 30/30 successful IP, HTTPS, and complete 1 MiB probes;
3. zero tunnel teardown or unexplained reconnect during those rounds;
4. median throughput no worse than 20% below the established provider baseline, with absolute floors
   of 0.5 Mbit/s for Telemost and 2 Mbit/s for WB;
5. server restart recovery within 90 seconds and forced generation adoption within 120 seconds;
6. credential rejection classified correctly without guest fallback or impact on the other
   provider;
7. owner-device soak for 24 hours, then a second enrolled device and 48-hour soak before external
   tester rollout.

After every lifecycle action in step 1, the expected state is an active VPN with correct public IP,
HTTPS, and complete 1 MiB probe within 90 seconds and no more than one reconnect. During intentional
offline mode, the cached unexpired generation remains selected, no downgrade occurs, and probes pass
within 90 seconds after connectivity returns.

Server credentials are refreshed before half their remaining lifetime or two hours before expiry,
whichever is earlier. The edge keeps enough scoped credential validity for a 30-minute control-plane
outage; after expiry it fails closed. Fault injection covers control-plane, KMS, and network outages
before and during edge reconnect.

WB room creation, provider login, refresh, and revoke capabilities have separate live contract tests
and remain disabled until their own evidence gates pass.

## Rollout milestones

1. **Runtime prerequisite:** deploy durable state, fencing, immutable publication, backup/restore,
   monitoring, and the always-on scheduler in shadow mode.
2. **WB repair:** restore the proved owner `connection-details` path for an operator-created room;
   verify that the owner/edge path makes no guest calls while the isolated iPhone participant uses
   the separately tested guest join path.
3. **Telemost canary:** migrate one owner device to the new endpoint model, force rotation/recovery,
   and complete a 24-hour soak.
4. **WB canary:** reserve one inventory room, publish one device endpoint, and complete the same
   gates. WB does not advance to production until automatic room creation and recovery pass.
5. **Private cohort:** enroll Malyutin with separate device endpoints under the owner's identities;
   soak for 48 hours and exercise revoke.
6. **Login discovery:** prove provider-specific login/refresh/revoke flows; implement only the flows
   that pass physical-device and production-egress tests.
7. **Personal identities:** dual-publish, verify, and migrate each user from owner to personal
   assignments.

Each milestone is independently deployable and has a stop/go decision. A failed shadow, canary,
rotation, revocation, restore, or soak gate blocks the next milestone.

## Non-goals for the first release

- Public self-service registration.
- Provider login inside OLC.
- Storing provider passwords.
- Sharing a room, channel, or tunnel credential between active devices.
- Silent guest fallback.
- Unproved WB room creation.
- More than one active identity per user and provider.
