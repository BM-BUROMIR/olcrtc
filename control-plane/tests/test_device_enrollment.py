import json
import os
import pathlib
import tempfile
import unittest

from device_enrollment import issue_enrollment


class DeviceEnrollmentTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)

    def test_issues_private_atomic_batch_without_secret_in_summary(self) -> None:
        output = self.root / "enrollment.json"
        summary = issue_enrollment(
            registry_path=self.root / "devices.json",
            device_id="second-tester",
            profiles=["telemost", "wb"],
            object_base_url="https://storage.example.invalid/bootstrap",
            output=output,
        )
        payload = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual([item["id"] for item in payload], ["telemost", "wb"])
        self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)
        secret = payload[0]["bootstrap"]["client_key"]
        self.assertNotIn(secret, json.dumps(summary))
        self.assertEqual(summary, {"device_id": "second-tester", "profiles": ["telemost", "wb"]})

    def test_refuses_to_overwrite_enrollment_output(self) -> None:
        output = self.root / "enrollment.json"
        output.write_text("existing", encoding="utf-8")
        with self.assertRaises(FileExistsError):
            issue_enrollment(
                registry_path=self.root / "devices.json",
                device_id="second-tester",
                profiles=["telemost"],
                object_base_url="https://storage.example.invalid/bootstrap",
                output=output,
            )
        self.assertEqual(output.read_text(encoding="utf-8"), "existing")


if __name__ == "__main__":
    unittest.main()
