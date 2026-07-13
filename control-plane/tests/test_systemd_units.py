import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class SystemdUnitTest(unittest.TestCase):
    def test_shadow_service_is_hardened_and_uses_credentials(self) -> None:
        service = (ROOT / "systemd/olc-control-plane-shadow.service").read_text()

        self.assertIn("Type=oneshot", service)
        self.assertIn("DynamicUser=yes", service)
        self.assertIn("StateDirectory=olc-control-plane", service)
        self.assertIn("UMask=0077", service)
        self.assertIn("NoNewPrivileges=yes", service)
        self.assertIn("ProtectSystem=strict", service)
        self.assertIn("LoadCredential=rotation.env:", service)
        self.assertIn("LoadCredential=ssh_key:", service)
        self.assertIn("LoadCredential=telemost.cookies:", service)
        self.assertIn("LoadCredential=known_hosts:", service)
        self.assertNotIn("EnvironmentFile=", service)
        self.assertNotIn("/Users/", service)

    def test_shadow_timer_is_persistent_and_jittered(self) -> None:
        timer = (ROOT / "systemd/olc-control-plane-shadow.timer").read_text()

        self.assertIn("OnUnitActiveSec=30min", timer)
        self.assertIn("RandomizedDelaySec=2min", timer)
        self.assertIn("Persistent=true", timer)
        self.assertNotIn("/Users/", timer)

    def test_runner_uses_systemd_credential_directory(self) -> None:
        runner = (ROOT / "run-systemd-rotation.sh").read_text()

        self.assertIn('source "$CREDENTIALS_DIRECTORY/rotation.env"', runner)
        self.assertIn('OLC_SSH_KEY_PATH="$CREDENTIALS_DIRECTORY/ssh_key"', runner)
        self.assertIn('OLC_TELEMOST_COOKIES_PATH="$CREDENTIALS_DIRECTORY/telemost.cookies"', runner)
        self.assertIn('OLC_SSH_KNOWN_HOSTS_PATH="$CREDENTIALS_DIRECTORY/known_hosts"', runner)


if __name__ == "__main__":
    unittest.main()
