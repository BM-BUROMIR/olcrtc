import datetime as dt
import json
import pathlib
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

from activation_grants import ActivationGrantStore
from activation_service import ActivationService, handler
from device_registry import DeviceRegistry
from http.server import ThreadingHTTPServer


UTC = dt.timezone.utc


class ActivationServiceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.now = dt.datetime(2026, 7, 16, 10, 0, tzinfo=UTC)
        self.registry = DeviceRegistry(self.root / "devices.json")
        self.registry.enroll("owner-iphone", ["telemost", "wb"])
        self.grants = ActivationGrantStore(self.root / "activation.db")
        self.service = ActivationService(
            grants=self.grants,
            registry=self.registry,
            object_base_url="https://storage.example.invalid/bootstrap",
            clock=lambda: self.now,
        )

    def request(self, token: str, installation_id: str = "installation-a-0001") -> tuple[int, dict]:
        return self.service.exchange(
            json.dumps(
                {
                    "schema_version": 1,
                    "grant": token,
                    "installation_id": installation_id,
                }
            ).encode()
        )

    def test_returns_both_profiles_and_allows_same_installation_retry(self) -> None:
        token = self.grants.issue("owner-iphone", now=self.now)
        first_status, first = self.request(token)
        retry_status, retry = self.request(token)
        self.assertEqual(first_status, 200)
        self.assertEqual(retry_status, 200)
        self.assertEqual(first, retry)
        self.assertEqual([item["id"] for item in first["profiles"]], ["telemost", "wb"])
        self.assertNotIn(token, json.dumps(first))

    def test_rejects_second_installation_and_malformed_payload(self) -> None:
        token = self.grants.issue("owner-iphone", now=self.now)
        self.assertEqual(self.request(token)[0], 200)
        status, payload = self.request(token, "installation-b-0002")
        self.assertEqual((status, payload), (409, {"error": "grant_already_bound"}))

        status, payload = self.service.exchange(b"{}")
        self.assertEqual((status, payload), (400, {"error": "invalid_request"}))
        status, payload = self.service.exchange(b"{" + b"x" * 5000)
        self.assertEqual((status, payload), (413, {"error": "request_too_large"}))

    def test_http_health_endpoint_is_cacheless_and_does_not_expose_state(self) -> None:
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler(self.service))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        with urllib.request.urlopen(
            f"http://127.0.0.1:{server.server_port}/healthz"
        ) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers["Cache-Control"], "no-store")
            self.assertEqual(json.load(response), {"status": "ok"})


if __name__ == "__main__":
    unittest.main()
