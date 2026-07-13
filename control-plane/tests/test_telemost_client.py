import urllib.error
import unittest
from unittest import mock

from telemost_client import TelemostClient, TelemostError


class TelemostClientTest(unittest.TestCase):
    def setUp(self) -> None:
        self.client = TelemostClient("session=fake")

    @mock.patch("telemost_client.urllib.request.urlopen")
    def test_network_failure_does_not_mark_room_dead(self, urlopen: mock.Mock) -> None:
        urlopen.side_effect = urllib.error.URLError("TLS unavailable")
        with self.assertRaisesRegex(TelemostError, "health check failed"):
            self.client.is_alive("https://telemost.example/room")

    @mock.patch("telemost_client.urllib.request.urlopen")
    def test_http_not_found_marks_room_dead(self, urlopen: mock.Mock) -> None:
        urlopen.side_effect = urllib.error.HTTPError("url", 404, "not found", {}, None)
        self.assertFalse(self.client.is_alive("https://telemost.example/room"))


if __name__ == "__main__":
    unittest.main()
