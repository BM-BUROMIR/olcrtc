import pathlib
import tempfile
import unittest

from state_store import ControlPlaneStore


class ControlPlaneStoreSchemaTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = pathlib.Path(self.temp.name) / "control-plane.db"

    def test_initializes_transactional_schema(self) -> None:
        store = ControlPlaneStore(self.path)

        self.assertEqual(store.schema_version(), 1)
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
            },
        )


if __name__ == "__main__":
    unittest.main()
