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

The resumable physical-device soak completed 24 hours of active scheduled time with 144 rounds: 72
Telemost and 72 WB. The raw harness summary reports 141 passes and three failures. One WB result was
a harness timing false negative: retries pushed the probe past the fixed 120-second collection
window, and the cumulative device log later recorded the same round as `ok=3 fail=0`. The corrected
network result is therefore 142/144 (`98.61%`): Telemost 71/72 and WB 71/72.

Both real degraded rounds retained an active iOS VPN status and partial connectivity. The Telemost
round passed both short HTTPS probes but its 1 MiB transfer timed out. The WB round completed the 1
MiB transfer but its short HTTPS probes timed out after a managed reconnect. In both cases the next
scheduled round passed without manual intervention or configuration changes.

Successful 1 MiB transfers had median throughput of about `0.97 Mbit/s` on Telemost and
`0.86 Mbit/s` on WB. The observed successful range was approximately `0.41-1.67 Mbit/s` on
Telemost and `0.44-1.41 Mbit/s` on WB. Attempts made while CoreDevice reported a physically locked
phone remain separate harness events; laptop downtime is excluded from active soak duration. The
LaunchAgent unloaded after artifact collection.
