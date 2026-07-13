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
        self.assertIn("LoadCredential=managed-rotation.json:", service)
        self.assertIn("LoadCredential=managed-wb-rotation.json:", service)
        self.assertIn("LoadCredential=wb.bearer:", service)
        self.assertIn("LoadCredential=wb.room:", service)
        self.assertIn("LoadCredential=wb-server-base.yaml:", service)
        self.assertIn("ExecStartPost=/opt/olc/control-plane/backup-systemd-state.sh", service)
        self.assertNotIn("EnvironmentFile=", service)
        self.assertNotIn("/Users/", service)

    def test_backup_runner_is_private_verified_and_retained(self) -> None:
        runner = (ROOT / "backup-systemd-state.sh").read_text()

        self.assertIn("umask 077", runner)
        self.assertIn('backup_state.py" backup', runner)
        self.assertIn("-mtime +14 -delete", runner)
        self.assertNotIn("/Users/", runner)

    def test_shadow_timer_is_persistent_and_jittered(self) -> None:
        timer = (ROOT / "systemd/olc-control-plane-shadow.timer").read_text()

        self.assertIn("OnUnitActiveSec=30min", timer)
        self.assertIn("RandomizedDelaySec=2min", timer)
        self.assertIn("Persistent=true", timer)
        self.assertNotIn("/Users/", timer)

    def test_runner_uses_systemd_credential_directory(self) -> None:
        runner = (ROOT / "run-systemd-rotation.sh").read_text()

        self.assertIn('source "$CREDENTIALS_DIRECTORY/rotation.env"', runner)
        self.assertIn('CONFIG=${OLC_ROTATION_CONFIG:-"$CREDENTIALS_DIRECTORY/managed-rotation.json"}', runner)
        self.assertIn('OLC_SSH_KEY_PATH="$CREDENTIALS_DIRECTORY/ssh_key"', runner)
        self.assertIn('OLC_TELEMOST_COOKIES_PATH="$CREDENTIALS_DIRECTORY/telemost.cookies"', runner)
        self.assertIn('OLC_SSH_KNOWN_HOSTS_PATH="$CREDENTIALS_DIRECTORY/known_hosts"', runner)
        self.assertIn('managed_rotation.py" --config "$CONFIG" "$@"', runner)
        self.assertIn('managed_wb_rotation.py" --config "$WB_CONFIG" "$@"', runner)
        self.assertIn('OLC_WB_BEARER_PATH="$CREDENTIALS_DIRECTORY/wb.bearer"', runner)
        self.assertIn('OLC_WB_ROOM_PATH="$CREDENTIALS_DIRECTORY/wb.room"', runner)
        self.assertIn('OLC_WB_SERVER_BASE_CONFIG="$CREDENTIALS_DIRECTORY/wb-server-base.yaml"', runner)

    def test_shadow_service_waits_for_private_egress(self) -> None:
        service = (ROOT / "systemd/olc-control-plane-shadow.service").read_text()

        self.assertIn("Requires=olc-control-plane-xray.service", service)
        self.assertIn("After=network-online.target olc-control-plane-xray.service", service)
        self.assertIn("Environment=HTTPS_PROXY=http://127.0.0.1:1082", service)
        self.assertIn("Environment=HTTP_PROXY=http://127.0.0.1:1082", service)
        self.assertIn("Environment=NO_PROXY=127.0.0.1,localhost", service)

    def test_private_egress_service_is_hardened_and_uses_a_credential(self) -> None:
        service = (ROOT / "systemd/olc-control-plane-xray.service").read_text()

        self.assertIn("User=olc-control-plane-xray", service)
        self.assertIn("LoadCredential=config.json:", service)
        self.assertIn("ExecStart=/usr/local/bin/xray run -config ${CREDENTIALS_DIRECTORY}/config.json", service)
        self.assertNotIn("$CREDENTIALS_DIRECTORY/config.json", service)
        self.assertIn("Restart=on-failure", service)
        self.assertIn("NoNewPrivileges=yes", service)
        self.assertIn("ProtectSystem=strict", service)
        self.assertNotIn("/Users/", service)


if __name__ == "__main__":
    unittest.main()
