import datetime as dt
import json
import pathlib
import tempfile
import unittest

from shadow_runtime import ShadowEndpoint, record_shadow_generation


class ShadowRuntimeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.now = dt.datetime(2026, 7, 13, 12, 0, tzinfo=dt.timezone.utc)

    def test_records_generation_without_touching_legacy_object(self) -> None:
        endpoint = ShadowEndpoint(
            user_id="owner",
            device_id="owner-iphone11",
            identity_id="owner-telemost",
            assignment_id="owner-iphone11-telemost",
            endpoint_id="owner-iphone11-telemost",
            provider="telemost",
        )
        envelope = {
            "schema_version": 1,
            "profile_id": "telemost",
            "generation": 7,
            "subscription": {
                "room": "room-7",
                "channel": "channel-7",
                "crypto_key": "a" * 64,
            },
        }

        result = record_shadow_generation(
            state_path=self.root / "control-plane.db",
            object_root=self.root / "shadow-objects",
            endpoint=endpoint,
            envelope=envelope,
            now=self.now,
        )

        self.assertEqual(result["phase"], "active")
        self.assertEqual(result["generation"], 7)
        object_path = self.root / "shadow-objects" / result["object_key"]
        self.assertEqual(json.loads(object_path.read_text()), envelope)
        self.assertFalse((self.root / "owner-iphone11" / "telemost.olcb").exists())


if __name__ == "__main__":
    unittest.main()
