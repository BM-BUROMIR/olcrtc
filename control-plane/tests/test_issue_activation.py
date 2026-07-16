import pathlib
import tempfile
import unittest

from activation_grants import ActivationGrantStore
from issue_activation import issue_activation


class IssueActivationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)

    def test_writes_private_link_without_secret_in_summary(self) -> None:
        output = self.root / "owner.activation"
        summary = issue_activation(
            grants_db=self.root / "activation.db",
            device_id="owner-iphone",
            ttl_seconds=900,
            output=output,
        )
        link = output.read_text(encoding="utf-8").strip()
        self.assertRegex(link, r"^olc://activate/[A-Za-z0-9_-]{43}$")
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(link.rsplit("/", 1)[-1], repr(summary))
        self.assertEqual(summary["device_id"], "owner-iphone")

        token = link.rsplit("/", 1)[-1]
        result = ActivationGrantStore(self.root / "activation.db").consume(
            token, "installation-a-0001"
        )
        self.assertEqual(result.device_id, "owner-iphone")

    def test_refuses_to_overwrite_private_link(self) -> None:
        output = self.root / "owner.activation"
        output.write_text("keep", encoding="utf-8")
        with self.assertRaises(FileExistsError):
            issue_activation(
                grants_db=self.root / "activation.db",
                device_id="owner-iphone",
                ttl_seconds=900,
                output=output,
            )
        self.assertEqual(output.read_text(encoding="utf-8"), "keep")


if __name__ == "__main__":
    unittest.main()
