import base64
import datetime as dt
import json
import pathlib
import tempfile
import unittest

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from backup_state import (
    RestoreBlocked,
    backup_database,
    restore_database,
    verify_database,
)
from state_store import ControlPlaneStore


class BackupStateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.source = self.root / "source.db"
        self.store = ControlPlaneStore(self.source)
        self.now = dt.datetime(2026, 7, 13, 12, 0, tzinfo=dt.timezone.utc)
        self.private_key = Ed25519PrivateKey.generate()
        public_bytes = self.private_key.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
        self.public_key_path = self.root / "authority.pub"
        self.public_key_path.write_bytes(public_bytes)

    def _signed(self, name: str, payload: dict) -> pathlib.Path:
        canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        document = {
            "payload": payload,
            "signature": base64.b64encode(self.private_key.sign(canonical)).decode(),
        }
        path = self.root / name
        path.write_text(json.dumps(document), encoding="utf-8")
        return path

    def test_online_backup_is_integral(self) -> None:
        with self.store.transaction() as connection:
            connection.execute(
                "INSERT INTO users(id, display_name, status) VALUES ('owner', 'Owner', 'active')"
            )
        backup = self.root / "backups" / "control-plane.db"

        backup_database(self.source, backup)

        self.assertEqual(verify_database(backup), {"integrity": "ok", "foreign_key_errors": 0})
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)

    def test_restore_fails_closed_without_authorities(self) -> None:
        backup = self.root / "backup.db"
        backup_database(self.source, backup)

        with self.assertRaises(RestoreBlocked):
            restore_database(
                backup,
                self.root / "restored.db",
                authority_public_key=self.public_key_path,
                epoch_document=self.root / "missing-epoch.json",
                revocation_document=self.root / "missing-ledger.json",
                now=self.now,
            )

    def test_restore_expires_leases_and_applies_revocation_ledger(self) -> None:
        with self.store.transaction() as connection:
            connection.execute(
                "INSERT INTO users(id, display_name, status) VALUES ('owner', 'Owner', 'active')"
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
        self.store.acquire_lease(
            "endpoint", "endpoint-1", "worker-a", now=self.now, ttl_seconds=300
        )
        backup = self.root / "backup.db"
        backup_database(self.source, backup)
        epoch = self._signed(
            "epoch.json",
            {
                "schema_version": 1,
                "reservation_id": "restore-20260713",
                "epoch_start": 1000,
                "epoch_end": 1999,
            },
        )
        ledger = self._signed(
            "ledger.json",
            {
                "schema_version": 1,
                "sequence": 7,
                "revocations": [
                    {
                        "identity_id": "identity-1",
                        "credential_revision": 3,
                    }
                ],
            },
        )
        restored = self.root / "restored.db"

        restore_database(
            backup,
            restored,
            authority_public_key=self.public_key_path,
            epoch_document=epoch,
            revocation_document=ledger,
            now=self.now,
        )

        restored_store = ControlPlaneStore(restored)
        with restored_store.read_connection() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM leases").fetchone()[0], 0)
            identity = connection.execute(
                "SELECT status, credential_revision FROM provider_identities WHERE id = 'identity-1'"
            ).fetchone()
            event = connection.execute(
                "SELECT epoch_start, epoch_end, ledger_sequence FROM restore_events"
            ).fetchone()
        self.assertEqual(tuple(identity), ("disabled", 3))
        self.assertEqual(tuple(event), (1000, 1999, 7))


if __name__ == "__main__":
    unittest.main()
