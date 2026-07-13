import datetime as dt
import pathlib
import tempfile
import unittest

from immutable_publisher import (
    ImmutableConflict,
    ImmutablePublisher,
    InjectedFailure,
    MemoryImmutableBackend,
    MemoryManifestGateway,
    SQLiteManifestGateway,
    StaleManifestFence,
)
from rotation_journal import RevisionCandidate, RotationJournal
from state_store import ControlPlaneStore


class ImmutablePublisherTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = ControlPlaneStore(pathlib.Path(self.temp.name) / "control-plane.db")
        self.now = dt.datetime(2026, 7, 13, 12, 0, tzinfo=dt.timezone.utc)
        self._seed_endpoint()
        self.lease = self.store.acquire_lease(
            "endpoint", "endpoint-1", "worker-a", now=self.now, ttl_seconds=60
        )
        self.journal = RotationJournal(self.store)
        self.operation = self.journal.begin(
            "operation-1",
            endpoint_id="endpoint-1",
            candidate=RevisionCandidate(
                revision_id="revision-1",
                room_ref="room-1",
                server_unit="olc-endpoint-1-r1.service",
                channel="channel-1",
                tunnel_credential_ref="secret://tunnel-1",
                provider_expires_at="2026-07-14T12:00:00Z",
            ),
            lease=self.lease,
            now=self.now,
        )
        self.backend = MemoryImmutableBackend()
        self.gateway = MemoryManifestGateway()
        self.publisher = ImmutablePublisher(
            store=self.store,
            journal=self.journal,
            backend=self.backend,
            gateway=self.gateway,
        )
        self.object_key = (
            "devices/device-1/profiles/telemost/generations/1-1.olcb"
        )

    def _seed_endpoint(self) -> None:
        with self.store.transaction() as connection:
            connection.execute(
                "INSERT INTO users(id, display_name, status) VALUES ('owner', 'Owner', 'active')"
            )
            connection.execute(
                """
                INSERT INTO devices(id, user_id, status, public_key)
                VALUES ('device-1', 'owner', 'active', X'01')
                """
            )
            connection.execute(
                """
                INSERT INTO provider_identities(
                    id, user_id, provider, credential_ref, status, operational_health
                ) VALUES (
                    'identity-1', 'owner', 'telemost', 'secret://identity-1',
                    'active', 'healthy'
                )
                """
            )
            connection.execute(
                """
                INSERT INTO profile_assignments(
                    id, identity_id, user_id, device_id, provider, state, valid_from
                ) VALUES (
                    'assignment-1', 'identity-1', 'owner', 'device-1',
                    'telemost', 'active', '2026-07-13T12:00:00Z'
                )
                """
            )
            connection.execute(
                """
                INSERT INTO device_endpoints(id, assignment_id, provider, state)
                VALUES ('endpoint-1', 'assignment-1', 'telemost', 'active')
                """
            )

    def test_immutable_backend_rejects_different_bytes_for_same_key(self) -> None:
        self.backend.put_immutable(self.object_key, b"first")

        with self.assertRaises(ImmutableConflict):
            self.backend.put_immutable(self.object_key, b"second")

    def test_crash_after_blob_keeps_manifest_unchanged(self) -> None:
        with self.assertRaises(InjectedFailure):
            self.publisher.publish(
                operation_id=self.operation.operation_id,
                stream_id="device-1/telemost",
                object_key=self.object_key,
                blob=b"encrypted-generation",
                expected_etag=None,
                lease=self.lease,
                now=self.now,
                fail_after="object_put",
            )

        self.assertIsNone(self.gateway.get_manifest("device-1/telemost"))
        self.assertEqual(
            self.journal.get("operation-1").phase,
            "preparing",
        )

    def test_new_worker_reconciles_manifest_visible_before_crash(self) -> None:
        with self.assertRaises(InjectedFailure):
            self.publisher.publish(
                operation_id=self.operation.operation_id,
                stream_id="device-1/telemost",
                object_key=self.object_key,
                blob=b"encrypted-generation",
                expected_etag=None,
                lease=self.lease,
                now=self.now,
                fail_after="manifest_cas",
            )
        visible = self.gateway.get_manifest("device-1/telemost")
        self.assertIsNotNone(visible)
        self.assertEqual(self.journal.get("operation-1").phase, "publish_authorized")

        recovery_time = self.now + dt.timedelta(seconds=61)
        recovery_lease = self.store.acquire_lease(
            "endpoint",
            "endpoint-1",
            "worker-b",
            now=recovery_time,
            ttl_seconds=60,
        )
        active = self.publisher.reconcile(
            "operation-1",
            stream_id="device-1/telemost",
            lease=recovery_lease,
            now=recovery_time,
        )

        self.assertEqual(active.phase, "active")

    def test_gateway_rejects_lower_fencing_token(self) -> None:
        gateway = SQLiteManifestGateway(self.store)
        gateway.compare_and_swap(
            "device-1/telemost",
            expected_etag=None,
            manifest={"generation": 2},
            lease=self.lease,
            now=self.now,
        )
        recovery_time = self.now + dt.timedelta(seconds=61)
        self.store.acquire_lease(
            "endpoint",
            "endpoint-1",
            "worker-b",
            now=recovery_time,
            ttl_seconds=60,
        )

        with self.assertRaises(StaleManifestFence):
            gateway.compare_and_swap(
                "device-1/telemost",
                expected_etag="1",
                manifest={"generation": 1},
                lease=self.lease,
                now=recovery_time,
            )


if __name__ == "__main__":
    unittest.main()
