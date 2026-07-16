# Private Device Activation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a clean TestFlight installation securely obtain the managed Telemost and WB profiles from a single-use personal activation link.

**Architecture:** The operator issues a short-lived random grant whose SHA-256 hash is stored in a durable SQLite registry. The iOS app opens `olc://activate/<grant>`, sends the grant and a persistent random installation identifier to a fixed HTTPS rendezvous endpoint, then feeds the returned enrollment through the existing atomic App Group and ThisDeviceOnly Keychain importer. Consumption is idempotent for the first installation and rejected for every other installation.

**Tech Stack:** Python 3 standard library, SQLite, Objective-C++/Qt, NSURLSession, iOS custom URL scheme, shell packaging tests.

---

### Task 1: Durable activation grants

**Files:**
- Create: `control-plane/activation_grants.py`
- Create: `control-plane/tests/test_activation_grants.py`

- [ ] Write tests for expiry, hash-only persistence, first-install binding, idempotent retry, and cross-install rejection.
- [ ] Run `python3 -m unittest control-plane.tests.test_activation_grants -v` and verify the missing module fails.
- [ ] Implement transactional SQLite issuance and consumption.
- [ ] Run the focused test and the complete control-plane suite.
- [ ] Commit and push only to `BM-BUROMIR/olcrtc`.

### Task 2: Enrollment HTTP service and operator CLI

**Files:**
- Create: `control-plane/activation_service.py`
- Create: `control-plane/issue_activation.py`
- Create: `control-plane/tests/test_activation_service.py`
- Modify: `control-plane/README.md`

- [ ] Write an HTTP contract test for valid, retried, expired, malformed, and already-bound grants.
- [ ] Run it and verify failure before implementation.
- [ ] Implement a bounded JSON POST endpoint with secret-free logs and responses.
- [ ] Add a CLI that prints the private `olc://` link only to a mode-0600 output file and emits a redacted summary on stdout.
- [ ] Run focused and complete tests, then commit and push to the BM fork.

### Task 3: iOS activation-link import

**Files:**
- Modify: `client/platforms/ios/ios_controller.h`
- Modify: `client/platforms/ios/ios_controller.mm`
- Modify: `client/platforms/ios/QtAppDelegate.mm`
- Modify: `client/platforms/ios/AmneziaSceneDelegateHooks.mm`
- Modify: `client/ios/app/Info.plist.in`
- Modify: `client/cmake/ios.cmake`
- Create: `downstream/ios/test-managed-activation-contract.sh`

- [ ] Add a failing static contract test for strict URL parsing, fixed HTTPS endpoint use, installation-ID persistence, bounded response size, and invocation of the existing importer.
- [ ] Run the test and verify it fails for the missing behavior.
- [ ] Add the `olc` URL scheme and forward non-file activation URLs from app and scene delegates.
- [ ] Fetch enrollment with an ephemeral NSURLSession, strict status/content validation, and no token logging.
- [ ] Atomically stage and import both profiles, preserving a previous valid catalog on every failure.
- [ ] Run contract, build, packaging, and leak checks; commit and push only to the BM fork.

### Task 4: Deployment and physical-device acceptance

**Files:**
- Create: `control-plane/systemd/olc-activation.service`
- Create: `control-plane/activation-gateway.example.yaml`
- Modify: `control-plane/tests/test_systemd_units.py`
- Modify: `script/ios-post-update-acceptance.sh`

- [ ] Test and install the activation service with durable state and restricted permissions.
- [ ] Publish it behind a Yandex API Gateway HTTPS hostname reachable before VPN startup.
- [ ] Issue separate owner and Malyutin grants without committing tokens or enrollment data.
- [ ] Build, sign, package-check, and upload a monotonically versioned TestFlight build.
- [ ] On iPhone 11, verify clean activation creates Telemost and WB, then run connect, restart, rotation, reconnect, and network probes for both profiles.
- [ ] Store only sanitized evidence under repository `artifacts/`; retain raw evidence under `.secrets/runtime/`.

