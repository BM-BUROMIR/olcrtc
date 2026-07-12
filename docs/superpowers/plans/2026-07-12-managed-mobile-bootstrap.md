# Managed Mobile Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically rotate and distribute validated Telemost/WB configurations to independently revocable iOS field devices.

**Architecture:** A Python control-plane transaction activates and probes a complete server configuration before publishing versioned AES-GCM envelopes per device. The iOS app resolves managed profiles through encrypted bootstrap, validates monotonic generations and expiry, atomically caches the last good envelope, and passes only the resolved subscription to the tunnel extension.

**Tech Stack:** Python 3 stdlib plus `cryptography`, Swift/SwiftUI/NetworkExtension, Ruby profile generator, shell deployment scripts, XCTest-compatible Swift smoke tests, TestFlight automation.

---

### Task 1: Bring Product Sources Under Version Control

**Files:**
- Create: `control-plane/*.py`, `control-plane/*.sh`, `control-plane/README.md`
- Create: `apps/ios/OlcClientiOS/**`
- Modify: `.gitignore`
- Modify: `tools/ios-testflight/fastlane/Fastfile`
- Modify: `tools/ios-testflight/apply_identifiers.rb`

- [ ] Copy only source, project, test, and documentation files from the private workspace into the repository; exclude `build`, generated profiles, backups, runtime state, and secrets.
- [ ] Change TestFlight defaults to repository-relative `apps/ios/OlcClientiOS` while preserving an explicit `OLC_IOS_APP_DIR` override.
- [ ] Add ignore rules for generated profile JSON, Xcode output, archives, provisioning material, control-plane state, and transaction logs.
- [ ] Run `git grep` and gitleaks to prove that no local absolute path, room URL, tunnel key, JWT, or credential entered tracked files.
- [ ] Commit with `chore: track mobile control plane sources`.

### Task 2: Versioned Bootstrap Envelope

**Files:**
- Create: `control-plane/envelope.py`
- Create: `control-plane/tests/test_envelope.py`
- Modify: `control-plane/bootstrap.py`

- [ ] Write failing tests for envelope schema, UTC timestamps, profile matching, expiry, generation monotonicity, malformed subscription rejection, AES-GCM tamper rejection, and redacted diagnostics.
- [ ] Run `python3 -m unittest control-plane.tests.test_envelope -v` and confirm the new tests fail before implementation.
- [ ] Implement immutable envelope construction and validation with schema version `1`, RFC3339 UTC timestamps, positive generation, explicit profile ID, and strict 32-byte tunnel key validation.
- [ ] Extend `bootstrap.py publish/fetch` to encrypt and decrypt envelopes while refusing legacy bare subscriptions unless an explicit migration flag is supplied.
- [ ] Run the envelope and existing bootstrap tests; expect all to pass.
- [ ] Commit with `feat: add versioned bootstrap envelopes`.

### Task 3: Device Registry And Per-Device Publication

**Files:**
- Create: `control-plane/device_registry.py`
- Create: `control-plane/tests/test_device_registry.py`
- Modify: `control-plane/bootstrap.py`
- Modify: `control-plane/README.md`

- [ ] Write failing tests for enrollment, independent keys, profile allowlists, disabled devices, deterministic object names, and secret-free list output.
- [ ] Implement a private JSON registry whose path is mandatory and whose records contain device ID, key, enabled state, allowed profiles, and timestamps.
- [ ] Add `device enroll`, `device disable`, and `publish-all` commands; print secrets only during enrollment and never during list/status operations.
- [ ] Make publication skip disabled or unauthorized devices and fail the transaction if any required enabled-device upload fails.
- [ ] Run unit tests and a filesystem-backend integration test for two devices.
- [ ] Commit with `feat: manage per-device bootstrap access`.

### Task 4: Atomic Carrier Rotation

**Files:**
- Create: `control-plane/rotate.py`
- Create: `control-plane/server_config.py`
- Create: `control-plane/tests/test_rotation.py`
- Modify: `control-plane/push_room.sh`
- Modify: `control-plane/room_manager.py`

- [ ] Write failing tests proving room/channel/key are rendered together, generations are locked and monotonic, failed readiness/probe never publishes, failed activation restores the previous config, and a retry is idempotent.
- [ ] Implement atomic YAML rendering without ad-hoc text replacement and preserve only an explicit allowlist of static server settings.
- [ ] Implement transaction phases `prepare`, `activate`, `ready`, `probe`, `publish`, and `commit` with a filesystem lock and persisted redacted state.
- [ ] Replace room-only deployment with complete candidate deployment and backup/rollback commands.
- [ ] Add a bounded pluggable SOCKS HTTPS probe so unit tests use a fake and field runs use the current OLC client.
- [ ] Run rotation tests plus `shellcheck control-plane/*.sh` when available.
- [ ] Commit with `feat: rotate carrier configs atomically`.

### Task 5: Managed iOS Profiles And Resolver

**Files:**
- Create: `apps/ios/OlcClientiOS/App/ManagedProfile.swift`
- Create: `apps/ios/OlcClientiOS/App/BootstrapResolver.swift`
- Create: `apps/ios/OlcClientiOS/scripts/BootstrapResolverSmokeTest.swift`
- Modify: `apps/ios/OlcClientiOS/App/ProfileStore.swift`
- Modify: `apps/ios/OlcClientiOS/App/OlcApp.swift`
- Modify: `apps/ios/OlcClientiOS/project.yml`

- [ ] Write failing Swift smoke tests for decrypt/validate, profile mismatch, replay rejection, fetched-newer preference, valid-cache fallback, expired-cache refusal, and atomic cache replacement.
- [ ] Split managed profile metadata from resolved `Subscription`; static custom profiles remain unchanged.
- [ ] Implement URLSession fetch with no-cache headers, bounded timeout, AES-GCM authenticated decryption, strict envelope validation, and App Group cache storage.
- [ ] Change resolution order to fetch managed profile, then valid cache; remove the current built-in-first behavior that makes bootstrap fields unreachable.
- [ ] Refresh on launch and before connect; retry one refresh after `wait for peer` without creating an unbounded reconnect loop.
- [ ] Ensure logs contain profile/generation/source/hash but never bootstrap key, room, channel, or tunnel key.
- [ ] Run Swift smoke tests and simulator build.
- [ ] Commit with `feat: resolve managed ios profiles dynamically`.

### Task 6: Safe Packaging And Enrollment

**Files:**
- Create: `apps/ios/OlcClientiOS/scripts/generate-managed-profiles.rb`
- Create: `tools/ios-testflight/verify-package.sh`
- Modify: `tools/ios-testflight/fastlane/Fastfile`
- Modify: `tools/ios-testflight/README.md`
- Modify: `tools/ios-testflight/HANDOFF.md`

- [ ] Write failing packaging checks that reject ephemeral room data, shared tunnel keys, backup files, absolute local paths, and missing Telemost/WB managed descriptors.
- [ ] Generate managed descriptors from a private per-device enrollment file without printing values.
- [ ] Make archive/beta run package verification before signing and uploading.
- [ ] Document enrollment, revocation, rotation, recovery, and adding a second internal tester using placeholders only.
- [ ] Build an unsigned simulator app and inspect the bundle with the package verifier.
- [ ] Commit with `build: package managed ios bootstrap safely`.

### Task 7: Field Deployment And TestFlight Verification

**Files:**
- Create: `artifacts/managed-bootstrap/README.md`
- Modify: `docs/ios-vpn-status-2026-07-06.md`

- [ ] Back up current server configs and deploy the synchronized server binary and rotation tooling.
- [ ] Enroll the owner's device, rotate Telemost, publish its envelope, and verify a local SOCKS HTTPS request before exposing the generation.
- [ ] Run ten iOS cold-connect cycles with short HTTPS and 1 MiB probes, then force rotation and verify reconnect without manual JSON entry.
- [ ] Repeat the available test matrix for WB; record WB as blocked rather than claiming support if owner authorization still returns `403`.
- [ ] Archive and upload a new build using per-command Apple credentials; verify processing, entitlements, encryption declaration, and internal group assignment through App Store Connect APIs.
- [ ] Store only sanitized summaries and hashes under `artifacts/managed-bootstrap`; keep raw logs in the private runtime directory.
- [ ] Commit with `test: verify managed bootstrap field flow` and push only to the `bm` fork.

### Task 8: Second Tester Readiness

**Files:**
- Modify: `tools/ios-testflight/HANDOFF.md`
- Modify: `artifacts/managed-bootstrap/README.md`

- [ ] Enroll a separate device record for the second tester and publish only its encrypted objects.
- [ ] Add the tester to the internal TestFlight group without exposing bootstrap material in App Store Connect metadata.
- [ ] Verify that disabling the second record stops future publication without affecting the owner's device.
- [ ] Record the remaining external manual action, if any, without storing personal identifiers in Git.
- [ ] Commit with `docs: add second tester field procedure` and push only to the `bm` fork.
