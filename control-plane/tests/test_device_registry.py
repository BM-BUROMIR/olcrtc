import json
import pathlib
import tempfile
import unittest

from device_registry import DeviceRegistry, RegistryError


class DeviceRegistryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = pathlib.Path(self.temp.name) / "devices.json"
        self.registry = DeviceRegistry(self.path)

    def test_enrolls_devices_with_independent_keys(self) -> None:
        owner = self.registry.enroll("owner-phone", ["telemost", "wb"])
        tester = self.registry.enroll("field-tester", ["telemost"])
        self.assertEqual(len(owner["client_key"]), 64)
        self.assertNotEqual(owner["client_key"], tester["client_key"])
        self.assertEqual(self.registry.object_id("owner-phone", "telemost"), "owner-phone/telemost")

    def test_duplicate_enrollment_is_rejected(self) -> None:
        self.registry.enroll("owner-phone", ["telemost"])
        with self.assertRaisesRegex(RegistryError, "already enrolled"):
            self.registry.enroll("owner-phone", ["telemost"])

    def test_disabled_device_is_not_publishable(self) -> None:
        self.registry.enroll("field-tester", ["telemost"])
        self.registry.disable("field-tester")
        self.assertEqual(self.registry.publishable("telemost"), [])

    def test_profile_allowlist_is_enforced(self) -> None:
        self.registry.enroll("telemost-only", ["telemost"])
        self.assertEqual(self.registry.publishable("wb"), [])
        self.assertEqual([d["device_id"] for d in self.registry.publishable("telemost")], ["telemost-only"])

    def test_public_listing_does_not_expose_keys(self) -> None:
        enrolled = self.registry.enroll("owner-phone", ["telemost"])
        listing = json.dumps(self.registry.list_public())
        self.assertNotIn(enrolled["client_key"], listing)
        self.assertNotIn("client_key", listing)


if __name__ == "__main__":
    unittest.main()
