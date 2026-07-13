# Durable Rotation Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace mutable JSON rotation state with a crash-recoverable SQLite core that can run in shadow mode without changing deployed iOS profiles.

**Architecture:** A focused `ControlPlaneStore` owns schema migrations, leases, fencing tokens, endpoint revisions, generations, and an operation journal. A separate immutable publication coordinator writes candidate blobs and records manifest intent; the existing Telemost runner invokes it only in `--shadow` mode until the later enrollment/publication plan adds the iOS wire protocol.

**Tech Stack:** Python 3.11 stdlib `sqlite3`, existing `cryptography` package, `unittest`, existing control-plane scripts.

---

## Scope Boundary

This plan implements rollout milestone 1's durable rotation core and shadow reconciliation. It does
not activate Secure Enclave enrollment, the new signed manifest wire format, production WB room
creation, or provider login. Those require separate plans and physical-device gates.

### Task 1: Transactional SQLite Store

**Files:**
- Create: `control-plane/state_store.py`
- Create: `control-plane/migrations/001_control_plane.sql`
- Create: `control-plane/tests/test_state_store.py`

- [ ] **Step 1: Write the failing schema test**

Add a test that opens a temporary database and asserts WAL mode, foreign keys, schema version 1,
and the required tables:

```python
def test_initializes_transactional_schema(self) -> None:
    store = ControlPlaneStore(self.path)
    self.assertEqual(store.schema_version(), 1)
    self.assertEqual(store.journal_mode(), "wal")
    self.assertTrue(store.foreign_keys_enabled())
    self.assertEqual(
        store.table_names(),
        {"schema_migrations", "devices", "provider_identities", "identity_grants",
         "profile_assignments", "device_endpoints", "endpoint_revisions",
         "profile_generations", "leases", "operations"},
    )
```

- [ ] **Step 2: Run the test and confirm failure**

Run: `python3 -m unittest control-plane/tests/test_state_store.py -v`

Expected: FAIL because `state_store` does not exist.

- [ ] **Step 3: Add migration and store bootstrap**

Implement `ControlPlaneStore(path)` with one connection per operation, `PRAGMA journal_mode=WAL`,
`PRAGMA foreign_keys=ON`, `BEGIN IMMEDIATE` for writes, and migration checksums. The migration must
use strict foreign keys and unique constraints for `(device_id, provider)` assignments and
`(endpoint_id, epoch, generation)` generations.

```python
class ControlPlaneStore:
    def __init__(self, path: pathlib.Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._migrate()

    @contextlib.contextmanager
    def transaction(self):
        connection = sqlite3.connect(self.path, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("BEGIN IMMEDIATE")
        try:
            yield connection
            connection.execute("COMMIT")
        except BaseException:
            connection.execute("ROLLBACK")
            raise
        finally:
            connection.close()
```

- [ ] **Step 4: Run schema tests**

Run: `python3 -m unittest control-plane/tests/test_state_store.py -v`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add control-plane/state_store.py control-plane/migrations/001_control_plane.sql control-plane/tests/test_state_store.py
git commit -m "feat: establish durable control-plane state"
```

### Task 2: Leases and Fencing

**Files:**
- Modify: `control-plane/state_store.py`
- Modify: `control-plane/tests/test_state_store.py`

- [ ] **Step 1: Add lease race tests**

Test that the first owner receives token 1, a second owner is rejected before expiry, token 2 is
issued after expiry, and token 1 cannot authorize a state transition:

```python
lease1 = store.acquire_lease("endpoint", "ep-1", "worker-a", now=t0, ttl_seconds=30)
with self.assertRaises(LeaseBusy):
    store.acquire_lease("endpoint", "ep-1", "worker-b", now=t0, ttl_seconds=30)
lease2 = store.acquire_lease("endpoint", "ep-1", "worker-b", now=t0 + timedelta(seconds=31), ttl_seconds=30)
self.assertEqual((lease1.fencing_token, lease2.fencing_token), (1, 2))
with self.assertRaises(StaleFence):
    store.authorize_publication("op-1", lease1)
```

- [ ] **Step 2: Confirm the race test fails**

Run: `python3 -m unittest control-plane.tests.test_state_store.LeaseTest -v`

Expected: FAIL because lease APIs are absent.

- [ ] **Step 3: Implement fenced leases**

Add immutable `Lease`, `LeaseBusy`, and `StaleFence` types. Acquisition atomically increments the
persisted token. `renew_lease` and every state-changing method require owner, unexpired lease, and
the latest token in the same transaction.

- [ ] **Step 4: Run the focused and full control-plane tests**

Run: `python3 -m unittest discover -s control-plane/tests -v`

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add control-plane/state_store.py control-plane/tests/test_state_store.py
git commit -m "feat: fence concurrent rotation workers"
```

### Task 3: Endpoint Revision and Operation Journal

**Files:**
- Modify: `control-plane/state_store.py`
- Create: `control-plane/rotation_journal.py`
- Create: `control-plane/tests/test_rotation_journal.py`

- [ ] **Step 1: Write transition and replay tests**

Cover `preparing -> publish_authorized -> active -> draining -> retired`, reject skipped transitions,
and prove that replaying the same `operation_id` returns the same revision rather than creating a
new room candidate.

```python
operation = journal.begin("op-1", endpoint_id="ep-1", lease=lease)
same = journal.begin("op-1", endpoint_id="ep-1", lease=lease)
self.assertEqual(operation.revision_id, same.revision_id)
journal.authorize("op-1", object_key="devices/d1/telemost/generations/1-1.olcb",
                  content_hash="a" * 64, lease=lease)
with self.assertRaises(InvalidTransition):
    journal.retire("op-1", lease=lease)
```

- [ ] **Step 2: Confirm failure**

Run: `python3 -m unittest control-plane/tests/test_rotation_journal.py -v`

Expected: FAIL because `rotation_journal` does not exist.

- [ ] **Step 3: Implement journal methods**

Store operation ID, endpoint/revision IDs, phase, expected/result ETag, content hash, fencing token,
last error code, and timestamps. Every method is idempotent for identical input and rejects changed
input for an existing operation ID.

- [ ] **Step 4: Run journal and store tests**

Run: `python3 -m unittest control-plane/tests/test_rotation_journal.py control-plane/tests/test_state_store.py -v`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add control-plane/state_store.py control-plane/rotation_journal.py control-plane/tests/test_rotation_journal.py
git commit -m "feat: journal recoverable endpoint revisions"
```

### Task 4: Immutable Shadow Publisher

**Files:**
- Create: `control-plane/immutable_publisher.py`
- Create: `control-plane/tests/test_immutable_publisher.py`
- Modify: `control-plane/managed_rotation.py`

- [ ] **Step 1: Write crash-boundary tests**

Use an in-memory backend with `put_immutable` and `get_manifest`. Inject failure after object PUT,
after `publish_authorized`, and after manifest CAS. Assert that immutable blobs are never overwritten,
the old manifest remains valid before CAS, and reconciliation commits a CAS-visible revision.

```python
publisher.publish(operation, envelope, fail_after="manifest_cas")
self.assertEqual(backend.manifest("device-1", "telemost")["content_hash"], expected_hash)
publisher.reconcile(operation.id)
self.assertEqual(store.operation(operation.id).phase, "active")
```

- [ ] **Step 2: Confirm failure**

Run: `python3 -m unittest control-plane/tests/test_immutable_publisher.py -v`

Expected: FAIL because `immutable_publisher` does not exist.

- [ ] **Step 3: Implement shadow publication**

`ImmutablePublisher` computes SHA-256, refuses an existing key with different bytes, records
`publish_authorized` before manifest CAS, and treats a matching visible manifest as cutover truth.
Add `--shadow-state-db` to `managed_rotation.py`. Shadow mode records and reconciles candidates but
does not replace current `<device>/<profile>.olcb` objects or server config.

- [ ] **Step 4: Run all control-plane tests**

Run: `python3 -m unittest discover -s control-plane/tests -v`

Expected: all tests PASS, including existing mutable publisher compatibility tests.

- [ ] **Step 5: Commit**

```bash
git add control-plane/immutable_publisher.py control-plane/managed_rotation.py control-plane/tests/test_immutable_publisher.py
git commit -m "feat: shadow immutable profile publication"
```

### Task 5: Backup, Integrity, and Restore Fencing

**Files:**
- Create: `control-plane/backup_state.py`
- Create: `control-plane/tests/test_backup_state.py`
- Create: `control-plane/runbooks/control-plane-restore.md`

- [ ] **Step 1: Write backup/restore tests**

Create a live WAL database, write during backup, restore it, and assert `PRAGMA integrity_check` is
`ok`, foreign-key check is empty, leases are expired, and publication refuses to start without an
external epoch watermark and revocation ledger snapshot.

- [ ] **Step 2: Confirm failure**

Run: `python3 -m unittest control-plane/tests/test_backup_state.py -v`

Expected: FAIL because backup functions are absent.

- [ ] **Step 3: Implement online backup and restore gate**

Use `sqlite3.Connection.backup` into a mode-0600 temporary file, run integrity checks, then
`os.replace`. Restore accepts signed watermark/ledger JSON paths, applies revocations, expires all
leases, reserves a higher epoch range, and otherwise exits non-zero without starting workers.

- [ ] **Step 4: Run tests and exercise CLI help**

Run: `python3 -m unittest control-plane/tests/test_backup_state.py -v && python3 control-plane/backup_state.py --help`

Expected: tests PASS and help exits 0 without exposing local paths or credentials.

- [ ] **Step 5: Commit**

```bash
git add control-plane/backup_state.py control-plane/tests/test_backup_state.py control-plane/runbooks/control-plane-restore.md
git commit -m "feat: gate rotation on verified recoverable state"
```

### Task 6: Shadow Deployment and Evidence

**Files:**
- Create: `control-plane/systemd/olc-control-plane-shadow.service`
- Create: `control-plane/systemd/olc-control-plane-shadow.timer`
- Create: `control-plane/runbooks/shadow-rollout.md`
- Create: `control-plane/tests/test_systemd_units.py`
- Modify: `control-plane/README.md`

- [ ] **Step 1: Add static deployment tests**

Extend a test to assert the units use `EnvironmentFile` only for non-secret paths, `LoadCredential`
for secrets, `Persistent=true`, a stable working directory, and no developer-machine paths.

- [ ] **Step 2: Confirm failure**

Run: `python3 -m unittest control-plane/tests/test_systemd_units.py -v`

Expected: FAIL because units and test do not exist.

- [ ] **Step 3: Add hardened shadow units and runbook**

Use `DynamicUser=yes`, `StateDirectory=olc-control-plane`, `UMask=0077`,
`NoNewPrivileges=yes`, bounded runtime, and a timer with jitter. The runbook must include install,
shadow comparison, alert thresholds, backup check, rollback by stopping the timer, and artifact
collection under the repository's ignored artifact directory.

- [ ] **Step 4: Verify repository and secret hygiene**

Run:

```bash
python3 -m unittest discover -s control-plane/tests -v
git diff --check
rg -n '/Users/|BEGIN (RSA|OPENSSH) PRIVATE KEY|Bearer [A-Za-z0-9]' control-plane docs/superpowers
```

Expected: tests PASS; `git diff --check` exits 0; `rg` returns no credential or local-path matches.

- [ ] **Step 5: Commit**

```bash
git add control-plane/systemd control-plane/runbooks control-plane/README.md control-plane/tests/test_systemd_units.py
git commit -m "ops: deploy durable rotation in shadow mode"
```

## Final Verification

- [ ] Run `python3 -m unittest discover -s control-plane/tests -v`.
- [ ] Run `git diff --check` and the repository's secret/path scanners.
- [ ] Start shadow mode on the always-on host for one Telemost endpoint.
- [ ] Force duplicate scheduler execution and confirm stale fencing rejection.
- [ ] Kill the worker after each journal phase and confirm reconciliation.
- [ ] Complete an online backup and isolated restore drill before any production manifest cutover.
