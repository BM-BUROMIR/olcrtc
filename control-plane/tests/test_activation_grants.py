import datetime as dt
import pathlib
import sqlite3
import tempfile
import unittest

from activation_grants import (
    ActivationConflict,
    ActivationExpired,
    ActivationGrantStore,
    ActivationInvalid,
)


UTC = dt.timezone.utc


class ActivationGrantStoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = pathlib.Path(self.temp.name) / "activation.db"
        self.store = ActivationGrantStore(self.path)
        self.now = dt.datetime(2026, 7, 16, 9, 0, tzinfo=UTC)

    def test_persists_only_hash_and_binds_first_installation(self) -> None:
        token = self.store.issue("owner-iphone", ttl_seconds=900, now=self.now)
        raw = self.path.read_bytes()
        self.assertNotIn(token.encode(), raw)

        result = self.store.consume(token, "installation-a-0001", now=self.now)
        self.assertEqual(result.device_id, "owner-iphone")
        self.assertFalse(result.retried)

        retried = self.store.consume(token, "installation-a-0001", now=self.now)
        self.assertEqual(retried.device_id, "owner-iphone")
        self.assertTrue(retried.retried)

        with self.assertRaises(ActivationConflict):
            self.store.consume(token, "installation-b-0002", now=self.now)

    def test_rejects_expired_unknown_and_malformed_grants(self) -> None:
        token = self.store.issue("owner-iphone", ttl_seconds=60, now=self.now)
        with self.assertRaises(ActivationExpired):
            self.store.consume(token, "installation-a-0001", now=self.now + dt.timedelta(seconds=61))
        with self.assertRaises(ActivationInvalid):
            self.store.consume("A" * 43, "installation-a-0001", now=self.now)
        with self.assertRaises(ActivationInvalid):
            self.store.consume("not-a-token", "installation-a-0001", now=self.now)

    def test_issue_revokes_previous_open_grant_for_device(self) -> None:
        first = self.store.issue("owner-iphone", ttl_seconds=900, now=self.now)
        second = self.store.issue("owner-iphone", ttl_seconds=900, now=self.now)
        with self.assertRaises(ActivationInvalid):
            self.store.consume(first, "installation-a-0001", now=self.now)
        self.assertEqual(
            self.store.consume(second, "installation-a-0001", now=self.now).device_id,
            "owner-iphone",
        )

        with sqlite3.connect(self.path) as connection:
            count = connection.execute(
                "SELECT COUNT(*) FROM activation_grants WHERE device_id = ? AND revoked_at IS NULL",
                ("owner-iphone",),
            ).fetchone()[0]
        self.assertEqual(count, 1)


if __name__ == "__main__":
    unittest.main()
