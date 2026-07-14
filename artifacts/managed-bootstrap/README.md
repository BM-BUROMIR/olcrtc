# Managed VPN field acceptance

Sanitized status for the private managed deployment on 2026-07-13. Raw device logs, provider
credentials, room identifiers, bootstrap keys, App Store Connect responses, and control-plane
databases remain in the ignored workspace runtime tree.

## Deployed control plane

- Durable SQLite state, operation journal, fencing leases, online backup, and restore validation
  are deployed.
- Telemost and WB run as independent scheduled workers. A failure in one provider does not block
  refresh of the other.
- Each enabled device receives independently encrypted Telemost and WB objects. Device bootstrap
  keys and provider owner credentials are not included in client envelopes or tracked artifacts.
- Healthy timer cycles reconcile the current envelope to every enabled device, so enrolling a new
  device does not wait for a carrier room rotation or restart either edge service.
- A temporary independent device was issued against the production object store, published for
  Telemost generation `7` and WB generation `2`, fetched and decrypted with its own key, then fully
  removed. The enrollment artifact was mode `0600`; no temporary object remained after cleanup.
- Active field generations at the start of acceptance were Telemost `7` and WB `2`.
- The deployed edge executable is identified in `artifacts/control-plane-deploy/README.md`.

The independent provider units were deployed at `2026-07-13T18:00:00Z`. The first production run
returned `healthy` for Telemost generation `7` and WB generation `2`; both oneshot units exited with
status `0` and both persistent 30-minute timers remained active. Deployment exposed and fixed an
ownership defect in the earlier unit layout: two transient `DynamicUser` identities could not safely
share the same SQLite and room state. Both units now run as the declared, non-login
`olc-control-plane` system user, preserving one shared state directory without mutable UID ownership.

## Physical iPhone 11 matrix

| Scenario | Result |
|---|---|
| Telemost, 10 rounds of HTTPS plus 1 MiB | 10/10, each round `ok=3 fail=0` |
| WB, 10 rounds of HTTPS plus 1 MiB | 10/10, each round `ok=3 fail=0` |
| Managed Telemost generation rotation | Client detected the newer generation and reconnected without manual configuration |
| Managed WB generation rotation | Client detected the newer generation and reconnected without manual configuration |
| WB hard service restart | Health watchdog terminated the dead data path; iOS On-Demand restored it without user action |
| Full edge VM restart while using Telemost | One health timeout, recovery in the next probe interval, then HTTPS plus 1 MiB `ok=3 fail=0` |

The VM restart was issued through the cloud API at `2026-07-13T15:45:39Z`. Boot completion was
confirmed independently from serial output. The iPhone health check recovered at
`2026-07-13T15:46:40Z`; a fresh application probe completed `3/3` after recovery.

## TestFlight artifact

- Version: `0.1.1`
- Build: `202607141354`
- App Store Connect processing state: `VALID`
- Minimum iOS version: `16.0`
- Included managed profiles: Telemost and WB
- Embedded static subscriptions: none
- Embedded bootstrap credentials: none
- App Group entitlement: present
- Packet Tunnel Provider entitlement: present
- Private-path scan of the exported IPA: passed
- External field-test group: current build attached
- Beta App Review: `WAITING_FOR_REVIEW`
- Review access: dedicated per-device Telemost/WB enrollment; owner and field-tester keys are not
  shared with Apple

This is a universal binary. An update restores the current owner's per-device enrollment from the
persisted VPN provider configuration, including the sibling managed profile under the strict
`{device}/{profile}.olcb` contract. A clean install remains disconnected until a private enrollment
file is imported. Every tester receives an independent key; no owner's credential is shared through
TestFlight.

## 24-hour soak

The resumable physical-device soak started at `2026-07-13T16:41:24Z`. It probes every ten minutes,
keeps each provider active for six rounds, then switches provider and reconnects through managed
bootstrap. The first 112 valid rounds contain 110 passes and two isolated probe failures; both
providers recovered in later rounds without configuration changes. Attempts made while CoreDevice
reported a physically locked phone are retained as harness events and are excluded from network
failure counts. Laptop downtime is also excluded from the active soak duration.

Acceptance remains pending until 24 hours of active scheduled rounds have completed. Starting or
resuming the runner is not evidence that the duration requirement has passed.
