#!/usr/bin/env python3
"""Rotate an owner-authorized existing WB room and publish per-device profiles."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import secrets
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable

from bootstrap import YandexStorageBackend
from device_registry import DeviceRegistry
from envelope import build_envelope
from managed_rotation import (
    DeviceEnvelopePublisher,
    OlcSocksProbe,
    Publication,
    SSHServerActivator,
    _load_json,
    _replace_private_json,
    reconcile_active_envelope,
    record_shadow_if_configured,
    should_rotate,
)
from rotate import RotationTransaction


def load_private_value(path: pathlib.Path, label: str) -> str:
    value = path.read_text(encoding="utf-8").strip()
    if not value:
        raise ValueError(f"{label} is empty")
    return value


class WBExistingRoom:
    """Validate an operator-created room without retaining short-lived LiveKit credentials."""

    def __init__(
        self,
        *,
        room_id: str,
        bearer: str,
        opener: Callable[..., Any] = urllib.request.urlopen,
        api_base: str = "https://stream.wb.ru",
    ) -> None:
        if not room_id or not bearer:
            raise ValueError("WB room and bearer are required")
        self.room_id = room_id
        self.bearer = bearer
        self.opener = opener
        self.api_base = api_base.rstrip("/")

    def validate(self) -> None:
        room = urllib.parse.quote(self.room_id, safe="")
        query = urllib.parse.urlencode({
            "deviceType": "PARTICIPANT_DEVICE_TYPE_WEB_DESKTOP",
            "displayName": "OLC Control Plane",
        })
        request = urllib.request.Request(
            f"{self.api_base}/api-room-manager/v2/room/{room}/connection-details?{query}",
            headers={
                "Authorization": f"Bearer {self.bearer}",
                "User-Agent": "Mozilla/5.0 (Linux x86_64)",
            },
        )
        try:
            with self.opener(request, timeout=20) as response:
                raw = response.read(1_048_577)
        except urllib.error.HTTPError as exc:
            raise RuntimeError(f"WB owner validation failed: HTTP {exc.code}") from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise RuntimeError("WB owner validation failed") from exc
        if len(raw) > 1_048_576:
            raise RuntimeError("WB connection details response is too large")
        try:
            payload = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise RuntimeError("WB returned invalid connection details") from exc
        if not all(
            isinstance(payload.get(field), str) and len(payload[field]) > 5
            for field in ("roomToken", "serverUrl")
        ):
            raise RuntimeError("WB returned invalid connection details")


def build_subscription(room_id: str) -> dict[str, str]:
    if not room_id:
        raise ValueError("WB room is required")
    return {
        "carrier": "wbstream",
        "room": room_id,
        "channel": f"olc-{secrets.token_hex(8)}",
        "crypto_key": secrets.token_hex(32),
        "transport": "vp8channel",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Rotate managed WB existing-room bootstrap")
    parser.add_argument("--config", required=True, type=pathlib.Path)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    config = json.loads(args.config.read_text(encoding="utf-8"))
    if config.get("ca_bundle"):
        os.environ.setdefault("SSL_CERT_FILE", config["ca_bundle"])

    access_key = os.environ.get("AWS_ACCESS_KEY_ID")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY")
    if not access_key or not secret_key:
        raise SystemExit("AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required")

    runtime = pathlib.Path(config["runtime_dir"])
    bearer_path = pathlib.Path(os.environ.get("OLC_WB_BEARER_PATH", config["bearer_path"]))
    room_path = pathlib.Path(os.environ.get("OLC_WB_ROOM_PATH", config["room_path"]))
    bearer = load_private_value(bearer_path, "WB bearer")
    room_id = load_private_value(room_path, "WB room")
    WBExistingRoom(room_id=room_id, bearer=bearer).validate()

    envelope_path = runtime / "wb-envelope.json"
    active = _load_json(envelope_path)
    now = dt.datetime.now(dt.timezone.utc)
    refresh_before = dt.timedelta(hours=float(config.get("refresh_before_hours", 2)))
    backend = YandexStorageBackend(
        config["yc_bucket"],
        access_key=access_key,
        secret_key=secret_key,
    )
    registry = DeviceRegistry(runtime / "devices.json")
    if not args.force and not should_rotate(active, room_id, now=now, refresh_before=refresh_before):
        published = reconcile_active_envelope(registry, backend, "wb", active)
        print(json.dumps({
            "status": "healthy",
            "profile": "wb",
            "generation": active["generation"],
            "published_devices": published,
        }))
        return 0

    generation = int(active.get("generation", 0) if active else 0) + 1
    expires_at = now + dt.timedelta(hours=float(config.get("envelope_ttl_hours", 12)))
    envelope = build_envelope(
        profile_id="wb",
        generation=generation,
        issued_at=now,
        expires_at=expires_at,
        subscription=build_subscription(room_id),
    )
    server = config["server"]
    activator = SSHServerActivator(
        host=server["host"],
        user=server.get("user", "ubuntu"),
        ssh_key=pathlib.Path(os.environ.get("OLC_SSH_KEY_PATH", server["ssh_key"])),
        base_config=pathlib.Path(
            os.environ.get("OLC_WB_SERVER_BASE_CONFIG", server["base_config"])
        ),
        remote_config=server.get("config_path", "/etc/olc-bypass/wb-srv.yaml"),
        service=server.get("service", "olc-wb-srv.service"),
        work_dir=runtime / "wb",
        auth_token_path=bearer_path,
    )
    publisher = DeviceEnvelopePublisher(registry, backend)

    def publish(payload: dict[str, Any]) -> Publication:
        publication = publisher.publish_transactionally("wb", payload)
        previous = envelope_path.read_bytes() if envelope_path.exists() else None
        try:
            _replace_private_json(envelope_path, payload)
        except Exception:
            publication.rollback()
            raise

        def rollback() -> None:
            publication.rollback()
            if previous is None:
                envelope_path.unlink(missing_ok=True)
            else:
                envelope_path.write_bytes(previous)
                os.chmod(envelope_path, 0o600)

        return Publication(publication.count, rollback)

    transaction = RotationTransaction(
        state_path=runtime / "wb-rotation-state.json",
        activator=activator,
        probe=OlcSocksProbe(pathlib.Path(config["olcrtc_binary"]), runtime / "wb" / "probe"),
        publish=publish,
    )
    changed = transaction.run(envelope)
    shadow_result = record_shadow_if_configured(
        config,
        envelope,
        now=now,
        provider="wbstream",
    ) if changed else None
    print(json.dumps({
        "status": "rotated" if changed else "unchanged",
        "profile": "wb",
        "generation": generation,
        "published_devices": len(registry.publishable("wb")),
        "shadow": shadow_result,
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
