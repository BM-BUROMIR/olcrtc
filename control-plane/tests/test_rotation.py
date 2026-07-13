import pathlib
import tempfile
import unittest

import yaml

from rotate import RotationError, RotationTransaction
from server_config import render_server_config


def candidate(generation: int = 2) -> dict:
    return {
        "profile_id": "telemost",
        "generation": generation,
        "subscription": {
            "carrier": "telemost",
            "room": "https://example.invalid/room/new",
            "channel": "new-channel",
            "crypto_key": "b" * 64,
            "transport": "vp8channel",
        },
    }


class ServerConfigTest(unittest.TestCase):
    def test_renders_complete_candidate_without_mutating_base(self) -> None:
        base = """
mode: srv
auth:
  provider: telemost
room:
  id: old-room
  channel: old-channel
crypto:
  key: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
net:
  transport: datachannel
  dns: 8.8.8.8:53
proxy:
  type: socks5
  address: 127.0.0.1:1080
"""
        rendered = yaml.safe_load(render_server_config(base, candidate()["subscription"]))
        self.assertEqual(rendered["room"], {"id": candidate()["subscription"]["room"], "channel": "new-channel"})
        self.assertEqual(rendered["crypto"]["key"], "b" * 64)
        self.assertEqual(rendered["net"]["transport"], "vp8channel")
        self.assertEqual(rendered["net"]["dns"], "8.8.8.8:53")
        self.assertEqual(rendered["proxy"]["address"], "127.0.0.1:1080")
        self.assertIn("old-room", base)


class FakeActivator:
    def __init__(self) -> None:
        self.events = []

    def activate(self, payload: dict) -> str:
        self.events.append(("activate", payload["generation"]))
        return "backup-token"

    def ready(self) -> None:
        self.events.append(("ready", None))

    def rollback(self, token: str) -> None:
        self.events.append(("rollback", token))


class RotationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = pathlib.Path(self.temp.name) / "rotation.json"
        self.activator = FakeActivator()
        self.published = []

    def transaction(self, probe=lambda _payload: None, publish=None) -> RotationTransaction:
        return RotationTransaction(
            state_path=self.state,
            activator=self.activator,
            probe=probe,
            publish=publish or (lambda payload: self.published.append(payload["generation"])),
        )

    def test_publishes_only_after_activate_ready_and_probe(self) -> None:
        events = self.activator.events

        def probe(payload: dict) -> None:
            events.append(("probe", payload["generation"]))

        def publish(payload: dict) -> None:
            events.append(("publish", payload["generation"]))

        self.transaction(probe=probe, publish=publish).run(candidate())
        self.assertEqual([name for name, _ in events], ["activate", "ready", "probe", "publish"])

    def test_failed_probe_rolls_back_and_never_publishes(self) -> None:
        def fail(_payload: dict) -> None:
            raise RuntimeError("probe failed")

        with self.assertRaisesRegex(RotationError, "probe failed"):
            self.transaction(probe=fail).run(candidate())
        self.assertEqual(self.published, [])
        self.assertEqual(self.activator.events[-1], ("rollback", "backup-token"))

    def test_generation_must_increase_and_retry_is_idempotent(self) -> None:
        tx = self.transaction()
        tx.run(candidate(2))
        tx.run(candidate(2))
        self.assertEqual(self.published, [2])
        with self.assertRaisesRegex(RotationError, "generation"):
            tx.run(candidate(1))

    def test_commit_failure_rolls_back_publication_before_server(self) -> None:
        events = self.activator.events

        class Publication:
            def rollback(self) -> None:
                events.append(("publication-rollback", None))

        tx = self.transaction(publish=lambda _payload: Publication())
        tx._commit = lambda _payload: (_ for _ in ()).throw(OSError("disk full"))
        with self.assertRaisesRegex(RotationError, "disk full"):
            tx.run(candidate())
        self.assertEqual(
            [name for name, _ in events[-2:]],
            ["publication-rollback", "rollback"],
        )


if __name__ == "__main__":
    unittest.main()
