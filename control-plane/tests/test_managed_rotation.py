import datetime as dt
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

from bootstrap import decrypt_subscription, encrypt_subscription
from device_registry import DeviceRegistry
from managed_rotation import (
    DeviceEnvelopePublisher,
    SSHServerActivator,
    record_shadow_if_configured,
    should_rotate,
)


UTC = dt.timezone.utc


class MemoryBackend:
    def __init__(self, objects=None, fail_object_id=None):
        self.objects = dict(objects or {})
        self.fail_object_id = fail_object_id

    def put(self, object_id: str, blob: bytes) -> str:
        if object_id == self.fail_object_id:
            raise RuntimeError("upload failed")
        self.objects[object_id] = blob
        return self.url_for(object_id)

    def url_for(self, object_id: str) -> str:
        return f"memory://{object_id}"

    def get(self, object_id: str) -> bytes | None:
        return self.objects.get(object_id)

    def delete(self, object_id: str) -> None:
        self.objects.pop(object_id, None)


class RotationDecisionTest(unittest.TestCase):
    def test_reuses_healthy_envelope_for_same_room(self) -> None:
        now = dt.datetime(2026, 7, 13, 8, 0, tzinfo=UTC)
        envelope = {
            "expires_at": "2026-07-13T18:00:00Z",
            "subscription": {"room": "room-a"},
        }
        self.assertFalse(should_rotate(envelope, "room-a", now=now, refresh_before=dt.timedelta(hours=2)))

    def test_rotates_for_new_room_or_expiring_envelope(self) -> None:
        now = dt.datetime(2026, 7, 13, 8, 0, tzinfo=UTC)
        envelope = {
            "expires_at": "2026-07-13T09:00:00Z",
            "subscription": {"room": "room-a"},
        }
        self.assertTrue(should_rotate(envelope, "room-a", now=now, refresh_before=dt.timedelta(hours=2)))
        envelope["expires_at"] = "2026-07-13T18:00:00Z"
        self.assertTrue(should_rotate(envelope, "room-b", now=now, refresh_before=dt.timedelta(hours=2)))


class DevicePublisherTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.registry = DeviceRegistry(pathlib.Path(self.temp.name) / "devices.json")
        self.first = self.registry.enroll("first", ["telemost"])
        self.second = self.registry.enroll("second", ["telemost"])

    def test_partial_upload_restores_previous_objects(self) -> None:
        old_payload = {"generation": 1}
        old = {
            DeviceRegistry.object_id("first", "telemost"): encrypt_subscription(
                old_payload, bytes.fromhex(self.first["client_key"])
            ),
            DeviceRegistry.object_id("second", "telemost"): encrypt_subscription(
                old_payload, bytes.fromhex(self.second["client_key"])
            ),
        }
        backend = MemoryBackend(
            old,
            fail_object_id=DeviceRegistry.object_id("second", "telemost"),
        )
        publisher = DeviceEnvelopePublisher(self.registry, backend)

        with self.assertRaisesRegex(RuntimeError, "upload failed"):
            publisher.publish("telemost", {"generation": 2})

        for record in (self.first, self.second):
            object_id = DeviceRegistry.object_id(record["device_id"], "telemost")
            restored = decrypt_subscription(backend.objects[object_id], bytes.fromhex(record["client_key"]))
            self.assertEqual(restored["generation"], 1)

    def test_publishes_only_enabled_authorized_devices(self) -> None:
        self.registry.disable("second")
        backend = MemoryBackend()
        count = DeviceEnvelopePublisher(self.registry, backend).publish("telemost", {"generation": 2})
        self.assertEqual(count, 1)
        self.assertEqual(list(backend.objects), ["first/telemost"])

    def test_successful_publication_can_be_rolled_back_before_commit(self) -> None:
        old_payload = {"generation": 1}
        object_id = "first/telemost"
        old_blob = encrypt_subscription(old_payload, bytes.fromhex(self.first["client_key"]))
        backend = MemoryBackend({object_id: old_blob})
        publication = DeviceEnvelopePublisher(self.registry, backend).publish_transactionally(
            "telemost", {"generation": 2}
        )
        publication.rollback()
        restored = decrypt_subscription(backend.objects[object_id], bytes.fromhex(self.first["client_key"]))
        self.assertEqual(restored["generation"], 1)

    def test_partial_upload_removes_new_objects(self) -> None:
        backend = MemoryBackend(fail_object_id="second/telemost")
        publisher = DeviceEnvelopePublisher(self.registry, backend)
        with self.assertRaisesRegex(RuntimeError, "upload failed"):
            publisher.publish("telemost", {"generation": 2})
        self.assertEqual(backend.objects, {})


class ServerActivatorTest(unittest.TestCase):
    @mock.patch("managed_rotation._run")
    def test_failed_restart_restores_backup_inside_activate(self, run: mock.Mock) -> None:
        completed = subprocess.CompletedProcess([], 0, "", "")
        metadata = subprocess.CompletedProcess([], 0, "root ubuntu 640\n", "")
        run.side_effect = [metadata, completed, completed, RuntimeError("restart failed"), completed]
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            base = root / "base.yaml"
            base.write_text(
                "mode: srv\nroom: {id: old, channel: old}\n"
                f"crypto: {{key: {'a' * 64}}}\nnet: {{transport: vp8channel}}\n",
                encoding="utf-8",
            )
            activator = SSHServerActivator(
                host="example.invalid", user="ubuntu", ssh_key=root / "key",
                base_config=base, remote_config="/etc/olc/config.yaml",
                service="olc.service", work_dir=root,
            )
            payload = {
                "subscription": {
                    "carrier": "telemost", "room": "new", "channel": "channel",
                    "crypto_key": "b" * 64, "transport": "vp8channel",
                }
            }
            with self.assertRaisesRegex(RuntimeError, "restart failed"):
                activator.activate(payload)
        self.assertEqual(run.call_count, 5)
        rollback_command = run.call_args_list[-1].args[0][-1]
        self.assertIn("install -o root -g ubuntu -m 640", rollback_command)
        self.assertIn("/var/lib/olc-bypass/rotation/", rollback_command)


class ShadowIntegrationTest(unittest.TestCase):
    def test_disabled_shadow_is_a_noop(self) -> None:
        self.assertIsNone(
            record_shadow_if_configured(
                {},
                {"generation": 1},
                now=dt.datetime(2026, 7, 13, tzinfo=UTC),
            )
        )

    @mock.patch("managed_rotation.record_shadow_generation")
    def test_maps_explicit_shadow_config(self, record: mock.Mock) -> None:
        record.return_value = {"phase": "active", "generation": 1}
        config = {
            "runtime_dir": "/private/runtime",
            "shadow": {
                "state_db": "/private/state/control-plane.db",
                "object_root": "/private/state/objects",
                "user_id": "owner",
                "device_id": "owner-iphone11",
                "identity_id": "owner-telemost",
                "assignment_id": "owner-iphone11-telemost",
                "endpoint_id": "owner-iphone11-telemost",
            },
        }
        now = dt.datetime(2026, 7, 13, tzinfo=UTC)

        result = record_shadow_if_configured(config, {"generation": 1}, now=now)

        self.assertEqual(result["phase"], "active")
        self.assertEqual(record.call_args.kwargs["endpoint"].provider, "telemost")
        self.assertEqual(record.call_args.kwargs["now"], now)

    @mock.patch("managed_rotation.record_shadow_generation")
    def test_maps_wb_shadow_provider(self, record: mock.Mock) -> None:
        record.return_value = {"phase": "active", "generation": 1}
        config = {
            "shadow": {
                "state_db": "/private/state/control-plane.db",
                "object_root": "/private/state/objects",
                "user_id": "owner",
                "device_id": "owner-iphone11",
                "identity_id": "owner-wb",
                "assignment_id": "owner-iphone11-wb",
                "endpoint_id": "owner-iphone11-wb",
            },
        }

        record_shadow_if_configured(
            config,
            {"generation": 1},
            now=dt.datetime(2026, 7, 13, tzinfo=UTC),
            provider="wbstream",
        )

        self.assertEqual(record.call_args.kwargs["endpoint"].provider, "wbstream")


if __name__ == "__main__":
    unittest.main()
