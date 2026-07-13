import datetime as dt
import pathlib
import tempfile
import unittest

from state_store import ControlPlaneStore, LeaseBusy, StaleFence


class ControlPlaneStoreSchemaTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = pathlib.Path(self.temp.name) / "control-plane.db"

    def test_initializes_transactional_schema(self) -> None:
        store = ControlPlaneStore(self.path)

        self.assertEqual(store.schema_version(), 3)
        self.assertEqual(store.journal_mode(), "wal")
        self.assertTrue(store.foreign_keys_enabled())
        self.assertEqual(
            store.table_names(),
            {
                "schema_migrations",
                "users",
                "devices",
                "provider_identities",
                "identity_grants",
                "profile_assignments",
                "device_endpoints",
                "endpoint_revisions",
                "profile_generations",
                "leases",
                "operations",
                "manifest_streams",
            },
        )


class LeaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = ControlPlaneStore(pathlib.Path(self.temp.name) / "control-plane.db")
        self.now = dt.datetime(2026, 7, 13, 12, 0, tzinfo=dt.timezone.utc)

    def test_rejects_second_owner_before_expiry(self) -> None:
        self.store.acquire_lease("endpoint", "ep-1", "worker-a", now=self.now, ttl_seconds=30)

        with self.assertRaises(LeaseBusy):
            self.store.acquire_lease(
                "endpoint", "ep-1", "worker-b", now=self.now, ttl_seconds=30
            )

    def test_expired_lease_increments_fence_and_rejects_old_worker(self) -> None:
        lease1 = self.store.acquire_lease(
            "endpoint", "ep-1", "worker-a", now=self.now, ttl_seconds=30
        )
        lease2 = self.store.acquire_lease(
            "endpoint",
            "ep-1",
            "worker-b",
            now=self.now + dt.timedelta(seconds=31),
            ttl_seconds=30,
        )

        self.assertEqual((lease1.fencing_token, lease2.fencing_token), (1, 2))
        with self.assertRaises(StaleFence):
            self.store.assert_current_lease(
                lease1,
                now=self.now + dt.timedelta(seconds=31),
            )

    def test_renews_only_current_owner_and_token(self) -> None:
        lease = self.store.acquire_lease(
            "endpoint", "ep-1", "worker-a", now=self.now, ttl_seconds=30
        )

        renewed = self.store.renew_lease(
            lease,
            now=self.now + dt.timedelta(seconds=10),
            ttl_seconds=30,
        )

        self.assertEqual(renewed.fencing_token, lease.fencing_token)
        self.store.assert_current_lease(
            renewed,
            now=self.now + dt.timedelta(seconds=31),
        )


if __name__ == "__main__":
    unittest.main()
