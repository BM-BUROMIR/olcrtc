import datetime as dt
import unittest

from cryptography.exceptions import InvalidTag

from bootstrap import decrypt_subscription, encrypt_subscription, prepare_payload
from envelope import EnvelopeError, build_envelope, validate_envelope


UTC = dt.timezone.utc


def subscription() -> dict:
    return {
        "carrier": "telemost",
        "room": "https://example.invalid/room/active",
        "channel": "field",
        "crypto_key": "a" * 64,
        "transport": "vp8channel",
    }


class EnvelopeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.now = dt.datetime(2026, 7, 12, 10, 0, tzinfo=UTC)
        self.envelope = build_envelope(
            profile_id="telemost",
            generation=7,
            issued_at=self.now,
            expires_at=self.now + dt.timedelta(hours=20),
            subscription=subscription(),
        )

    def test_valid_envelope(self) -> None:
        result = validate_envelope(
            self.envelope,
            expected_profile_id="telemost",
            now=self.now,
            minimum_generation=6,
        )
        self.assertEqual(result["generation"], 7)

    def test_rejects_expired_envelope(self) -> None:
        with self.assertRaisesRegex(EnvelopeError, "expired"):
            validate_envelope(
                self.envelope,
                expected_profile_id="telemost",
                now=self.now + dt.timedelta(days=1),
            )

    def test_rejects_profile_mismatch(self) -> None:
        with self.assertRaisesRegex(EnvelopeError, "profile"):
            validate_envelope(self.envelope, expected_profile_id="wb", now=self.now)

    def test_rejects_replayed_generation(self) -> None:
        with self.assertRaisesRegex(EnvelopeError, "generation"):
            validate_envelope(
                self.envelope,
                expected_profile_id="telemost",
                now=self.now,
                minimum_generation=7,
            )

    def test_rejects_malformed_tunnel_key(self) -> None:
        self.envelope["subscription"]["crypto_key"] = "short"
        with self.assertRaisesRegex(EnvelopeError, "crypto_key"):
            validate_envelope(self.envelope, expected_profile_id="telemost", now=self.now)

    def test_ciphertext_tampering_is_rejected(self) -> None:
        key = bytes.fromhex("42" * 32)
        blob = bytearray(encrypt_subscription(self.envelope, key))
        blob[-1] ^= 1
        with self.assertRaises(InvalidTag):
            decrypt_subscription(bytes(blob), key)

    def test_publish_rejects_legacy_bare_subscription(self) -> None:
        with self.assertRaisesRegex(EnvelopeError, "schema_version"):
            prepare_payload(subscription(), expected_profile_id="telemost")

    def test_publish_accepts_validated_envelope(self) -> None:
        prepared = prepare_payload(self.envelope, expected_profile_id="telemost", now=self.now)
        self.assertEqual(prepared["generation"], 7)


if __name__ == "__main__":
    unittest.main()
