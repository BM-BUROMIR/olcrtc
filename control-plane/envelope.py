"""Versioned, validated payload distributed through encrypted bootstrap objects."""

from __future__ import annotations

import copy
import datetime as dt
import re
from typing import Any


SCHEMA_VERSION = 1
_HEX_32 = re.compile(r"^[0-9a-fA-F]{64}$")
_REQUIRED_SUBSCRIPTION_FIELDS = ("carrier", "room", "channel", "crypto_key")


class EnvelopeError(ValueError):
    """The decrypted bootstrap payload is invalid or unsafe to activate."""


def _utc(value: dt.datetime) -> dt.datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise EnvelopeError("timestamp must include timezone")
    return value.astimezone(dt.timezone.utc)


def _format_time(value: dt.datetime) -> str:
    return _utc(value).isoformat(timespec="seconds").replace("+00:00", "Z")


def _parse_time(value: Any, field: str) -> dt.datetime:
    if not isinstance(value, str):
        raise EnvelopeError(f"{field} must be RFC3339 UTC")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise EnvelopeError(f"{field} must be RFC3339 UTC") from exc
    return _utc(parsed)


def build_envelope(
    *,
    profile_id: str,
    generation: int,
    issued_at: dt.datetime,
    expires_at: dt.datetime,
    subscription: dict[str, Any],
) -> dict[str, Any]:
    envelope = {
        "schema_version": SCHEMA_VERSION,
        "profile_id": profile_id,
        "generation": generation,
        "issued_at": _format_time(issued_at),
        "expires_at": _format_time(expires_at),
        "subscription": copy.deepcopy(subscription),
    }
    validate_envelope(envelope, expected_profile_id=profile_id, now=_utc(issued_at))
    return envelope


def validate_envelope(
    envelope: dict[str, Any],
    *,
    expected_profile_id: str,
    now: dt.datetime | None = None,
    minimum_generation: int | None = None,
) -> dict[str, Any]:
    if not isinstance(envelope, dict):
        raise EnvelopeError("envelope must be an object")
    if envelope.get("schema_version") != SCHEMA_VERSION:
        raise EnvelopeError("unsupported schema_version")
    if envelope.get("profile_id") != expected_profile_id:
        raise EnvelopeError("profile mismatch")

    generation = envelope.get("generation")
    if not isinstance(generation, int) or isinstance(generation, bool) or generation <= 0:
        raise EnvelopeError("generation must be a positive integer")
    if minimum_generation is not None and generation <= minimum_generation:
        raise EnvelopeError("generation is not newer than cached generation")

    issued_at = _parse_time(envelope.get("issued_at"), "issued_at")
    expires_at = _parse_time(envelope.get("expires_at"), "expires_at")
    if expires_at <= issued_at:
        raise EnvelopeError("expires_at must be after issued_at")
    current = _utc(now or dt.datetime.now(dt.timezone.utc))
    if expires_at <= current:
        raise EnvelopeError("envelope expired")

    subscription = envelope.get("subscription")
    if not isinstance(subscription, dict):
        raise EnvelopeError("subscription must be an object")
    for field in _REQUIRED_SUBSCRIPTION_FIELDS:
        value = subscription.get(field)
        if not isinstance(value, str) or not value.strip():
            raise EnvelopeError(f"subscription {field} is required")
    if not _HEX_32.fullmatch(subscription["crypto_key"]):
        raise EnvelopeError("subscription crypto_key must be hex64")
    transport = subscription.get("transport", "vp8channel")
    if not isinstance(transport, str) or not transport.strip():
        raise EnvelopeError("subscription transport must be non-empty")
    return copy.deepcopy(envelope)
