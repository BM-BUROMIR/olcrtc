import pathlib
import tempfile
import unittest

from room_manager import Deployment, RoomManager


class FakeClient:
    def __init__(self) -> None:
        self.number = 0

    def create_room(self) -> dict:
        self.number += 1
        return {
            "uri": f"room-{self.number}",
            "room_id": str(self.number),
            "created_at": 1000 + self.number,
            "expires_at": 100000 + self.number,
        }

    def is_alive(self, _uri: str) -> bool:
        return True


class RoomManagerTest(unittest.TestCase):
    def test_rotate_now_always_creates_fresh_room(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manager = RoomManager(
                FakeClient(),
                Deployment("test", "telemost", "channel", "a" * 64, "vp8channel", []),
                str(pathlib.Path(directory) / "rooms.json"),
            )
            first = manager.rotate_now()
            second = manager.rotate_now()
            self.assertNotEqual(first["uri"], second["uri"])
            self.assertEqual(manager.current()["uri"], second["uri"])


if __name__ == "__main__":
    unittest.main()
