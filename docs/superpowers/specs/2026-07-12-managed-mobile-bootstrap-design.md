# Managed Mobile Bootstrap Design

## Goal

Keep iOS field clients connected across short-lived carrier rooms without manually
copying room URLs or tunnel keys. Support multiple testers with independently
revocable device credentials and no secrets or local paths in Git.

## Scope

The first release uses Yandex Object Storage as the public, whitelist-reachable
bootstrap channel. Telemost and WB are managed profiles. Telegram fallback and a
custom authenticated API are intentionally deferred.

## Repository Boundary

The iOS application, control-plane code, tests, deployment templates, and operator
documentation live in this repository. Runtime state and credentials live under
the private workspace `.secrets` tree and are referenced through environment
variables or command-line arguments. Generated subscriptions, room URLs, tunnel
keys, Apple credentials, device bootstrap keys, absolute paths, and build output
must not be committed.

## Device Model

Each installation has a stable public device identifier and a random 256-bit
bootstrap key. The control plane publishes one encrypted object per device. A
device can therefore be added or revoked without rotating every tester. Initial
TestFlight builds may provision a private bootstrap descriptor at build time;
subsequent builds should support enrollment without embedding shared credentials.

The descriptor contains only:

- schema version;
- device identifier;
- bootstrap object URL;
- bootstrap decryption key;
- managed profile identifiers and display names.

## Subscription Envelope

The encrypted payload contains a versioned envelope rather than a bare
subscription:

- `schema_version`;
- `generation`, monotonically increasing per managed profile;
- `profile_id` (`telemost` or `wb`);
- `issued_at` and `expires_at` in UTC;
- carrier subscription (`carrier`, `room`, `channel`, `crypto_key`, `transport`);
- optional previous subscription and its overlap deadline.

Authenticated encryption remains AES-256-GCM. The client rejects unknown schema
versions, invalid timestamps, malformed carrier fields, non-increasing generations,
and payloads whose authenticated profile does not match the selected profile.

## Control-Plane Transaction

Rotation is a single command with persisted transaction state:

1. Create or reuse a carrier room that has enough remaining lifetime.
2. Generate a candidate room/channel/key tuple.
3. Render and atomically install the complete server configuration.
4. Restart the service and wait for carrier readiness.
5. Run a bounded end-to-end SOCKS HTTPS probe with the candidate subscription.
6. Publish encrypted per-device envelopes to temporary object names.
7. Promote every successfully uploaded object to its stable name.
8. Persist the generation as active while retaining the previous generation for
   a bounded overlap period.

Failure before promotion leaves clients on the previous generation. Failure after
server activation either restores the previous server configuration or keeps both
generations usable during overlap. Updating only `room` is forbidden: room,
channel, crypto key, generation, expiry, and published subscription form one unit.

The transaction is idempotent and protected by a process lock. Structured logs
contain profile, generation, phase, duration, and redacted hashes, never secret
values.

## iOS Resolution And Cache

Managed profiles store bootstrap metadata separately from resolved subscriptions.
Resolution order is:

1. Fetch and decrypt the selected profile before every manual or automatic connect.
2. Validate and atomically store a newer envelope in the App Group container.
3. Use a valid cached envelope if the network fetch fails.
4. Refuse connection when neither fetched nor cached data is valid.

The app refreshes on launch, before connect, at the envelope refresh interval, and
once immediately after a peer-wait failure. Refresh never replaces a valid cache
with invalid data. The packet-tunnel extension receives a resolved subscription,
not bootstrap credentials. Logs expose source, generation, age, expiry, and a
short configuration hash only.

Built-in Telemost and WB entries are managed-profile descriptors. They must not
contain ephemeral rooms or shared tunnel keys. User-added static profiles remain
available for diagnostics and are clearly identified as unmanaged.

## Operational Readiness

The control plane reports profile health: active generation, carrier room expiry,
server readiness, last successful probe, published device count, and next rotation
deadline. A scheduled job rotates before expiry with enough overlap for sleeping
iPhones. WB health is independent of Telemost; one broken carrier cannot block
publication or use of the other.

## Testing

Automated coverage includes envelope encryption and validation, replay rejection,
cache fallback, profile isolation, atomic server rendering, failed-probe rollback,
idempotent rotation, publication failure, and redaction. A packaging test rejects
ephemeral built-in data, secrets, and local absolute paths.

Field acceptance requires, for each carrier:

- ten cold connect/disconnect cycles on iOS;
- reconnect after a forced room rotation;
- connect with bootstrap temporarily unavailable using cache;
- rejection of an expired cache;
- short HTTPS, 1 MiB download, and sustained probe;
- overnight operation and next-day reconnection;
- independent enrollment and revocation of a second tester.

Only a TestFlight build that passes automated checks and the available-device field
matrix is promoted to testers.
