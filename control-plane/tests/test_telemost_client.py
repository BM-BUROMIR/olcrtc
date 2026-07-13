import urllib.error
import unittest
from unittest import mock

from telemost_client import TelemostClient, TelemostError


class TelemostClientTest(unittest.TestCase):
    def setUp(self) -> None:
        self.client = TelemostClient("session=fake")

    @mock.patch("telemost_client.time.sleep")
    @mock.patch("telemost_client.urllib.request.urlopen")
    def test_transient_network_failure_is_retried(
        self, urlopen: mock.Mock, sleep: mock.Mock
    ) -> None:
        response = mock.MagicMock()
        response.__enter__.return_value.status = 200
        urlopen.side_effect = [urllib.error.URLError("TLS unavailable"), response]

        self.assertTrue(self.client.is_alive("https://telemost.example/room"))
        self.assertEqual(urlopen.call_count, 2)
        sleep.assert_called_once_with(1)

    @mock.patch("telemost_client.time.sleep")
    @mock.patch("telemost_client.urllib.request.urlopen")
    def test_persistent_network_failure_does_not_mark_room_dead(
        self, urlopen: mock.Mock, sleep: mock.Mock
    ) -> None:
        urlopen.side_effect = urllib.error.URLError("TLS unavailable")
        with self.assertRaisesRegex(TelemostError, "health check failed"):
            self.client.is_alive("https://telemost.example/room")
        self.assertEqual(urlopen.call_count, 3)
        self.assertEqual(sleep.call_args_list, [mock.call(1), mock.call(2)])

    @mock.patch("telemost_client.urllib.request.urlopen")
    def test_http_not_found_marks_room_dead(self, urlopen: mock.Mock) -> None:
        urlopen.side_effect = urllib.error.HTTPError("url", 404, "not found", {}, None)
        self.assertFalse(self.client.is_alive("https://telemost.example/room"))


if __name__ == "__main__":
    unittest.main()
