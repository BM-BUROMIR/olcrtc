import io
import json
import pathlib
import tempfile
import unittest

from managed_wb_rotation import WBExistingRoom, build_subscription, load_private_value


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


class WBExistingRoomTest(unittest.TestCase):
    def test_owner_validation_uses_bearer_without_returning_credentials(self) -> None:
        captured = {}

        def open_request(request, timeout):
            captured["authorization"] = request.get_header("Authorization")
            captured["url"] = request.full_url
            captured["timeout"] = timeout
            return FakeResponse(json.dumps({
                "roomToken": "room-secret-token",
                "serverUrl": "wss://rtc.example",
            }).encode())

        room = WBExistingRoom(
            room_id="room-42",
            bearer="owner-secret",
            opener=open_request,
            api_base="https://stream.example",
        )

        self.assertIsNone(room.validate())
        self.assertEqual(captured["authorization"], "Bearer owner-secret")
        self.assertIn("/room/room-42/connection-details", captured["url"])
        self.assertEqual(captured["timeout"], 20)

    def test_rejects_incomplete_connection_details(self) -> None:
        room = WBExistingRoom(
            room_id="room-42",
            bearer="owner-secret",
            opener=lambda *_args, **_kwargs: FakeResponse(b'{"serverUrl":"wss://rtc.example"}'),
        )
        with self.assertRaisesRegex(RuntimeError, "invalid connection details"):
            room.validate()

    def test_subscription_contains_no_owner_credential(self) -> None:
        subscription = build_subscription("room-42")
        self.assertEqual(subscription["carrier"], "wbstream")
        self.assertEqual(subscription["room"], "room-42")
        self.assertEqual(subscription["transport"], "vp8channel")
        self.assertRegex(subscription["channel"], r"^olc-[0-9a-f]{16}$")
        self.assertRegex(subscription["crypto_key"], r"^[0-9a-f]{64}$")
        self.assertNotIn("token", subscription)

    def test_private_value_is_trimmed_and_required(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "credential"
            path.write_text(" secret-value\n", encoding="utf-8")
            self.assertEqual(load_private_value(path, "credential"), "secret-value")
            path.write_text("\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "credential is empty"):
                load_private_value(path, "credential")


if __name__ == "__main__":
    unittest.main()
