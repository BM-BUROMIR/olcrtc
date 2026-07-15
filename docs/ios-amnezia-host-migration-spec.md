# iOS migration to an Amnezia-based host

Status: critic-reviewed direction, implementation pending

## Decision

Stop extending the current standalone iOS shell as the production client. Import the public
AmneziaVPN history into a new private BM-BUROMIR repository and maintain it as an independent
downstream with the official Amnezia repository configured as a read-only upstream remote.

The result remains the complete Amnezia product shell with OLC added as a first-class managed
protocol. Existing Amnezia protocols, profile import and removal, self-hosted setup, subscriptions,
split tunnelling, backup/restore, diagnostics and connection UI must remain available. OLC must not
replace, hide or masquerade as an existing Amnezia protocol.

This is an imported downstream, not a GitHub fork: GitHub does not support changing a fork of a
public repository to private visibility. The downstream uses its own product name, icon, bundle
namespace and store metadata unless written permission to use Amnezia marks is obtained. This
branding rule does not permit removing Amnezia functionality.

GPLv3/TestFlight compatibility is a release gate, not an assumption. Before distributing an
Amnezia-derived build beyond development devices, obtain a documented legal conclusion or
permission from the relevant rightsholders. Each distributed build must also have complete
Corresponding Source: pinned app and submodule revisions, downstream patches, OLC sources,
dependency locks, build/install scripts, generated-binding inputs, license inventory and SBOM.
TestFlight remains a beta channel with expiring builds; the production channel for the private
group must be selected separately after Apple account and legal eligibility are verified.

## Goals

- Reuse and preserve the maintained cross-platform Amnezia product instead of rebuilding VPN
  lifecycle and UI.
- Add `OlcManaged` beside the existing Amnezia protocols without changing their serialized IDs or
  behavior.
- Preserve the existing OLC Telemost and WB transports and managed per-device enrollment.
- Provide explicit connection state, connected duration, traffic counters, last successful probe,
  active profile and configuration generation.
- Reuse mature profile management, diagnostics, network-change handling and log export after a
  security audit of those paths.
- Keep the path open for Android and desktop clients after iOS is stable.

## Non-goals and safety constraints

- Do not redesign the OLC carrier protocol merely to fit the host migration.
- Do not mutate production control-plane state during the architecture spike; use isolated test
  devices, profiles, rooms and generations.
- Do not run two app-owned packet tunnels at once. The app may embed two packet-tunnel extensions,
  but exactly one app-owned OLC/Amnezia manager is enabled and one app-owned tunnel is active. Happ
  Plus remains outside this coordinator and is governed only by the compatibility preflight.
- Do not modify, stop, start, restart, remove, reconfigure, route through or otherwise interfere
  with Happ Plus. Only read-only status observation is permitted unless a future explicit request
  names a precise Happ Plus action.
- Do not publish changes, issues or pull requests to Amnezia or any other upstream without explicit
  approval.

## Product identity and upgrade contract

The existing TestFlight app is upgraded in place. Its identifiers are immutable:

| Component | Identifier | Rule |
| --- | --- | --- |
| containing app | `com.oxi717.olc` | retain the current App Store Connect record |
| OLC packet tunnel | `com.oxi717.olc.tunnel` | retain so installed managers keep resolving |
| shared App Group | `group.com.oxi717.olc` | retain existing profiles, cache and diagnostics |
| Amnezia packet tunnel | `com.oxi717.olc.amnezia-tunnel` | new explicit App ID and provisioning profile |

One minimal upstream-facing patch parameterizes every hard-coded signing value. Concrete downstream
team ID, bundle IDs, App Group, keychain groups, provisioning profiles, branding, endpoints and
store metadata exist only in a downstream preset/generated overlay. CI also builds with
`AMNEZIA_ENABLE_OLC=OFF` and rejects downstream identifiers in upstream-owned product, model and QML
files. Archive validation inspects the app and both `.appex` bundles and rejects upstream team IDs,
profile names or App Groups.

An upgrade migration must preserve the current OLC manager, profile selection, enrollment material
and cached valid generation. It must not ask for a new VPN configuration solely because the host UI
changed. Manager lookup uses a stable profile UUID and expected `providerBundleIdentifier`, never
`localizedDescription` alone. Stale managers are handled only when they belong to this app; global
`clearSettings()` behavior that removes unrelated managers is prohibited.

## iOS extension architecture

Current Amnezia iOS has one `networkextension` target that dispatches OpenVPN, WireGuard/AWG and
Xray from `providerConfiguration`. OLC cannot be described as another existing Amnezia target.
The downstream deliberately embeds two extensions:

1. The original Amnezia extension remains the provider for all stock Amnezia protocols.
2. The existing OLC extension remains the provider for `OlcManaged` and is moved into the Amnezia
   build without changing its bundle ID.

This separation avoids linking the Xray Go runtime and OlcMobile Go runtime into one extension
process. It also keeps OLC faults out of the stock Amnezia provider. The containing app adds an
explicit `protocol -> providerBundleIdentifier` mapping and a manager coordinator that:

- selects managers by stable profile UUID and provider bundle ID;
- disables the previously selected app-owned manager before enabling another one;
- supports `Amnezia -> OLC -> Amnezia` switching without deleting either profile;
- never deletes or changes a manager owned by Happ Plus or another app;
- verifies the selected provider after every save/load round trip.

The persisted OLC manager contract also includes `isOnDemandEnabled`, explicit On-Demand rules and
the selected full-tunnel policy. Migration, switching, reboot and app upgrade must preserve those
fields so OLC can reconnect without opening the containing app.

Before the spike, perform a read-only compatibility preflight for the installed Happ Plus VPN type.
If enabling an app-owned manager would cause iOS to disable or supersede Happ Plus, stop the
implementation and request a separate product decision; never alter Happ Plus to make the test
pass. No assumption of simultaneous compatibility is allowed.

The OLC packet path is:

```text
iOS packet flow
  -> OLC NEPacketTunnelProvider lifecycle and network settings
  -> hev-socks5-tunnel
  -> OlcMobile local SOCKS endpoint
  -> Telemost or WB carrier
  -> OLC server
  -> Internet
```

OlcMobile and its dependencies are linked once into the OLC extension. The extension must not start
a subprocess or another packet tunnel. Shared lifecycle code may be extracted from Amnezia only
when it does not couple the two provider targets or change stock behavior.

### Routing contract

Before installing a default route, OlcMobile must expose an iOS socket binder callback and apply the
current physical-interface index to every carrier and Pion socket. Bootstrap/control-plane fetches
use a separate physically scoped transport: either a protected Go dialer or Network.framework with
an explicitly required physical interface. `URLSession.shared` is not permitted for recovery. A
healthy session fetches and validates a successor before stopping HEV/OlcMobile; emergency recovery
uses the scoped bypass fetch while the tunnel is reasserting. The interface index is refreshed
before reconnect after each meaningful `NWPath` change. Failure to bind is a start failure, not a
silent routing fallback.

The initial strict full-tunnel OLC policy sets `includeAllNetworks=true`,
`excludeLocalNetworks=false` and `excludeAPNs=true`; APNs is the only permitted direct system
exception so push delivery does not depend on the OLC carrier. `enforceRoutes` is not relied on when
`includeAllNetworks` is enabled. Any later route-based mode must instead set
`includeAllNetworks=false`, define `enforceRoutes` explicitly and pass a separate leak matrix. The
same application-traffic no-bypass policy applies while reasserting, refreshing and changing
networks; default IPv4 route alone is not treated as a kill switch.

The initial OLC transport remains TCP-only. HEV UDP forwarding is disabled; DNS uses the existing
synthetic MapDNS path with an explicitly tunnelled TCP/DoH resolver. IPv6 is either tunnelled after
implementation or deliberately blocked for an OLC full-tunnel profile; it must never bypass the
tunnel silently. Acceptance tests cover UDP and TCP DNS, DNS/IPv6 leaks, QUIC fallback and
NAT64/DNS64 networks.

## Amnezia data model integration

`OlcManaged` has an explicit, versioned schema across `ConfigType::OlcManaged`, protocol enum,
config variant, repository, import, controller dispatch and QML models. It uses a unique discriminator
and never passes through `hasThirdPartyConfig()` heuristics, self-hosted install/configurator paths or
API-subscription paths. New enum values are appended with stable explicit numbers so existing
serialized profiles do not change. Unknown protocol JSON is rejected and must never fall through to
AWG or another default. Legacy OLC descriptors have an explicit migration and round-trip tests.

The feature is guarded by `AMNEZIA_ENABLE_OLC`, disabled by default upstream-style and enabled only
by the downstream build overlay. Until another platform implements OLC, Android and desktop must
not display, import or select it.

Generic Amnezia Share and Full Access export are disabled for OLC. Backup may contain only a safe,
non-secret enrollment descriptor or initiate enrollment of a new device on restore. It never
contains a cached envelope, envelope decryption key, device identity, carrier credential or tunnel
key. Round-trip and secret-scanning tests cover profile storage, Share, Backup, diagnostics,
QSettings, Keychain and App Group files.

## Managed configuration and recovery

An OLC profile stores only a managed bootstrap descriptor and non-secret presentation metadata.
The encrypted, device-scoped envelope remains the source of Telemost/WB room, channel and crypto
material. There is one authenticated manifest stream per `(device_id, profile_id)`. A control-plane
signature or per-device MAC authenticates it; `blob_hash` covers the exact encrypted envelope bytes
and `config_hash` covers canonical decrypted configuration. The existing outer wire
`schema_version` is bumped from `1` to `2`, which legacy clients already reject. Manifest and
envelope also include `epoch`, `generation`, `config_schema`, `transport_abi`, `min_client_build`,
required capabilities and cohort.

Compatibility fencing happens server-side before a device manifest advances. Authenticated client
build/capabilities are registered at enrollment or upgrade; an incompatible device remains on a
serviced previous generation until it upgrades or is explicitly revoked. Merely adding unknown
fields to the legacy schema is not a compatibility mechanism.

The extension owns recovery because the containing app may be suspended. Normal rotation fetches
before stopping the working path:

```text
connected(N)
  -> fetch and validate(N+1)
  -> reasserting
  -> stop HEV and OlcMobile
  -> start(N+1)
  -> prove end-to-end readiness
  -> connected(N+1)
```

Emergency recovery, when `N` has no usable data path, is separate:

```text
failed(N)
  -> reasserting
  -> physically scoped bypass fetch
  -> stop residual HEV and OlcMobile resources
  -> start accepted generation
  -> prove end-to-end readiness
```

The extension coalesces concurrent refreshes, uses stable per-device jitter, honors `Retry-After`
and applies full-jitter exponential backoff with a bounded retry budget. It restarts its internal
data path without relying on the containing app or assuming that `cancelTunnelWithError` will cause
iOS to reconnect.

An already healthy tunnel performs a `networkOnly` manifest refresh at a jittered interval no longer
than five minutes. A trusted-time expiry timer stops the data path when the active envelope expires;
no successful traffic probe can extend that deadline. Maximum manifest staleness is part of the
revocation SLA.

Fetch modes are typed:

- `networkOnly` never falls back to cache;
- `networkWithOfflineFallback` may use a valid cache only for timeout, DNS failure or approved
  transient `5xx` responses;
- `404`, `410`, authentication/AEAD failure, hash mismatch, replay, schema/ABI incompatibility and
  generation rollback fail closed with a precise diagnostic.

Validation enforces monotonic `(epoch, generation)`, bounded clock skew, maximum envelope lifetime,
future `issued_at` tolerance and minimum remaining lifetime for offline start. Last known trusted
control-plane time is persisted separately from wall-clock time. A published profile that requires
a newer client remains on its previous serviced generation.

### Rotation and rollback

Control-plane rotation is transactional and serves overlapping generations:

```text
PREPARED
  -> SERVING_N_AND_N_PLUS_1
  -> PUBLISHED_BY_CAS
  -> CLIENT_ACK_OR_GRACE
  -> RETIRED_N
```

Generation-scoped envelopes are immutable. Each device manifest changes by compare-and-swap. The
server must serve both generations before advancing manifests. A generation cannot retire while
any non-revoked device manifest references it. Grace expiry may classify a compatible,
non-acknowledging device as failed and trigger an explicit revoke policy, but cannot silently
override compatibility retention. Rotation completion aggregates per-device manifest and
authenticated ACK state. Rollout is cohort-based and subject to a provider/room reconnect budget.

Rollback after publication is forward-only: publish `N+2` with restored working parameters or keep
serving `N+1`; never ask a client that accepted `N+1` to return to `N`. A new epoch is reserved for a
controlled disaster-recovery reset. Fault injection after every transition must leave at least one
usable generation and an auditable recovery action.

Epochs come from a fenced durable allocator outside the normal control-plane rollback domain. After
restore or suspected split brain, publication first reconciles the maximum tuple from immutable
manifests and acknowledged client state. Every epoch transition is authenticated, audited and
strictly greater than all previously published epochs.

Device disable is not sufficient revocation. Revocation publishes a tombstone (`410`), removes the
active manifest and invalidates the per-device/per-profile enrollment-key version. From an accepted
revoke command to server-side denial, the initial maximum SLA is ten minutes. A control-plane outage
uses a separately authenticated emergency path to the provider server and is tested; losing both
normal and emergency control is a declared security incident, not a successful revoke. Until the
server verifies a distinct per-device session credential, every security revocation rotates and
retires the affected shared carrier generation within the ten-minute bound; client cache deletion
is never considered access revocation. Re-enrollment creates a new device identity and key version.

## Product behavior and diagnostics

The main connection view exposes:

- disconnected, connecting, connected, recovering and failed states;
- connected duration and time-to-ready;
- selected protocol and, for OLC, Telemost/WB provider;
- active generation, source (`network` or `cache`) and last refresh;
- last successful end-to-end HTTPS probe;
- uploaded/downloaded bytes and a concise actionable failure reason.

UI `connected` is not proof of a working VPN. Readiness requires a unique nonce through a controlled
HTTPS endpoint and matching server-side session, device, provider and generation evidence.

Full logs belong on a diagnostics screen. Export is bounded and allowlist-based: app, provider and
native event timelines, build metadata and redacted fingerprints only. Before reuse, audit all
Amnezia logs and remove configuration previews, including the OpenVPN preview currently emitted by
the provider. Secret fixtures include inline OpenVPN credentials and PEM, WireGuard keys, Xray UUID,
Amnezia backups, OLC enrollment values, rooms, carrier tokens and tunnel keys.

## Observability and privacy

Optional production observability is opt-in and disclosed before first VPN use. It contains only the
documented health schema and is not sent to third-party analytics. Retention, deletion and access
policies are defined before release; App Store privacy labels, privacy policy and both app/extension
privacy manifests must agree with implementation.

Mandatory generation ACK is minimal essential control-plane traffic, separately disclosed and not
conditioned on optional telemetry consent. It authenticates device/profile, generation, session and
readiness with a dedicated key, monotonic sequence and idempotency key. Optional heartbeat uses a
separate telemetry key and additionally includes timestamp and boot/session ID. The server enforces
replay windows, rate limits and credential revocation. Only authenticated generation ACKs may
advance rotation. Neither channel includes destinations, message content, raw logs or secrets.

While connected, the extension runs a small end-to-end data-path probe with per-device jitter around
a five-minute interval. A central canary independently checks each provider and generation. Client
and control-plane generation mismatch is an alert, not merely a dashboard field.

## Delivery stages and acceptance

### Stage 0: reproducible stock baseline

1. Pin an Amnezia upstream commit, submodules and dependency locks.
2. Build and sign unmodified functionality using the downstream signing overlay.
3. On physical iPhone 11 and iPhone 15, record a before-integration matrix for every stock iOS
   protocol available to the test accounts: profile import/removal, connect/data path/stop,
   reconnect, lock/wake, Wi-Fi/cellular transition, DNS, split tunnel, counters, backup/restore and
   diagnostic export.
4. Create a versioned stock-feature inventory covering account/subscription/device flows,
   self-hosted onboarding and server management, protocol install/update/remove, Amnezia
   Share/Full Access, services catalog, settings, all existing QML routes and backup/restore. Each
   workflow must pass against a controlled account/server or deterministic fixture.
5. Record extension memory, CPU, thermal state and unplugged screen-off battery use.

Any missing stock feature or regression blocks OLC integration. The same matrix runs after every
upstream merge and before every release. A documented fixture/account blocker may defer a check only
during an intermediate spike. Before release every protocol present in the pinned upstream iOS build
must pass on controlled infrastructure; it may be excluded only when the unchanged pinned upstream
build also does not support it.

### Stage 1: isolated OLC architecture spike

1. Embed both extensions and prove provider selection and switching in both directions.
2. Migrate an installed current TestFlight build in place without deleting its VPN manager.
3. Connect isolated managed profiles through Telemost and WB.
4. Complete 20 start/stop cycles per provider. Every cycle proves DNS, controlled HTTPS nonce,
   expected egress, matching server session/generation, no direct bypass, and records time-to-ready
   and time-to-first-byte.
5. Complete 20 Wi-Fi/cellular transitions plus airplane mode, 5/30-minute no-service, captive
   portal, Wi-Fi without Internet, broken DNS, Low Data Mode and return to the same SSID. Recovery
   must not require opening the app.
6. Test locked/background operation with the containing app suspended and terminated, including
   1/8/24-hour lock, sleep/wake and externally initiated Telegram delivery with measured latency.
7. Pass DNS, IPv4/IPv6 leak, HTTPS, Telegram text/photo/document, Safari parallel browsing,
   sustained 20 MiB download and 15-minute YouTube playback with concurrent messaging.
8. Verify automatic On-Demand start after reboot and app update without opening the containing app.

### Stage 2: rotation, field and release gate

1. Run at least a 48-hour unattended soak spanning three rotations for each provider, with the app
   terminated and screen locked for substantial intervals.
2. Inject bootstrap/control-plane failure before, during and after every rotation transition and
   verify overlap, forward rollback, compatibility fencing, revocation and automatic recovery.
3. Test TestFlight build `N -> N+1` over an active VPN, cold device reboot, profile-schema upgrade,
   app reinstall/re-enrollment and recovery of managed profiles. Record when Apple legitimately
   requires a new VPN permission prompt.
4. Repeat the release matrix without debugger on iPhone 11, iPhone 15, minimum supported iOS,
   current stable iOS and at least one independent tester device.
5. Verify no provider crash, jetsam, leaked listener, routing loop or growing memory footprint.
   Capture steady/peak extension footprint, reconnect deltas, MetricKit exits and autonomous device
   traces.
6. Run three unplugged screen-off repetitions for two-hour idle and 30-minute workload. Initial
   release targets are no `serious`/`critical` thermal state, no sustained heating, idle drain at or
   below 3% battery/hour and no unexplained wake/reconnect loop. A target may change only through an
   explicit recorded product decision, not to make a failing run pass.
7. Produce a signed archive, entitlements report, secret-clean diagnostic export, crypto inventory,
   export-compliance decision and complete Corresponding Source/SBOM bundle.

The spike is rejected if preserving stock Amnezia requires fragile Qt/build patches, if the two
extensions cannot coexist within iOS memory/signing constraints, if OlcMobile cannot bind all
physical sockets, or if battery behavior remains unsuitable for always-on use. Fallback evaluation
then proceeds to commercially licensed Passepartout/Partout and, if a permissive license is needed,
Outline. The existing current OLC client remains available as rollback until the Amnezia-based
build passes all gates.

## Repository and upstream policy

- Push only to the private BM-BUROMIR downstream.
- Keep `origin` pointed at BM-BUROMIR and `upstream` pointed at official Amnezia read-only.
- Fetching upstream is allowed; pushing, opening issues or pull requests upstream requires explicit
  approval.
- Use merge-only updates from a pinned `upstream/dev`; release branches are never rebased or
  force-pushed.
- Record upstream SHA, submodule SHAs, dependency lock and downstream patch manifest in every build.
- Keep OLC behind its feature flag and isolated modules; avoid unrelated Amnezia refactors.
- An upstream merge is releasable only after both the stock-Amnezia and OLC matrices pass.
- Store signing and App Store Connect credentials outside source and Corresponding Source archives,
  with minimum scopes and rotation procedures.

## Apple distribution gates

- Verify that the selected Apple Developer membership and legal entity satisfy Apple's current VPN
  app rules before external distribution.
- Treat TestFlight as beta testing only and account for its build expiry.
- Choose and document the eventual private-group distribution method before calling the product
  production-ready.
- Maintain a cryptography inventory for Amnezia and OLC, answer export-compliance questions from the
  actual implementation and never inherit upstream `ITSAppUsesNonExemptEncryption` blindly.

## References

- AmneziaVPN: <https://github.com/amnezia-vpn/amnezia-client>
- Amnezia iOS provider:
  <https://github.com/amnezia-vpn/amnezia-client/blob/dev/client/platforms/ios/PacketTunnelProvider.swift>
- Amnezia iOS controller:
  <https://github.com/amnezia-vpn/amnezia-client/blob/dev/client/platforms/ios/ios_controller.mm>
- Amnezia Xray provider:
  <https://github.com/amnezia-vpn/amnezia-client/blob/dev/client/platforms/ios/PacketTunnelProvider%2BXray.swift>
- Amnezia HEV bridge:
  <https://github.com/amnezia-vpn/amnezia-client/blob/dev/client/platforms/ios/HevSocksTunnel.swift>
- Passepartout fallback: <https://github.com/partout-io/passepartout>
- Outline fallback: <https://github.com/OutlineFoundation/outline-apps>
