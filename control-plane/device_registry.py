"""Private per-device bootstrap credentials and profile authorization."""

from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import re
import secrets
from typing import Any
from urllib.parse import urlsplit


_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
_KNOWN_PROFILES = frozenset({"telemost", "wb"})
_PROFILE_NAMES = {"telemost": "Telemost", "wb": "WB"}


class RegistryError(ValueError):
    pass


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


class DeviceRegistry:
    def __init__(self, path: str | pathlib.Path):
        self.path = pathlib.Path(path)

    def _load(self) -> dict[str, Any]:
        if not self.path.exists():
            return {"schema_version": 1, "devices": {}}
        data = json.loads(self.path.read_text(encoding="utf-8"))
        if data.get("schema_version") != 1 or not isinstance(data.get("devices"), dict):
            raise RegistryError("unsupported device registry")
        return data

    def _save(self, data: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(self.path.suffix + ".tmp")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, self.path)
        os.chmod(self.path, 0o600)

    def enroll(self, device_id: str, profiles: list[str]) -> dict[str, Any]:
        if not _ID.fullmatch(device_id):
            raise RegistryError("device_id must use lowercase letters, digits, and hyphens")
        normalized = sorted(set(profiles))
        if not normalized or not set(normalized).issubset(_KNOWN_PROFILES):
            raise RegistryError("profiles must contain telemost and/or wb")
        data = self._load()
        if device_id in data["devices"]:
            raise RegistryError("device already enrolled")
        record = {
            "device_id": device_id,
            "client_key": secrets.token_hex(32),
            "enabled": True,
            "profiles": normalized,
            "created_at": _now(),
            "disabled_at": None,
        }
        data["devices"][device_id] = record
        self._save(data)
        return dict(record)

    def disable(self, device_id: str) -> None:
        data = self._load()
        try:
            record = data["devices"][device_id]
        except KeyError as exc:
            raise RegistryError("device not found") from exc
        record["enabled"] = False
        record["disabled_at"] = _now()
        self._save(data)

    def publishable(self, profile_id: str) -> list[dict[str, Any]]:
        devices = self._load()["devices"].values()
        return [
            dict(record)
            for record in sorted(devices, key=lambda item: item["device_id"])
            if record["enabled"] and profile_id in record["profiles"]
        ]

    def list_public(self) -> list[dict[str, Any]]:
        return [
            {key: value for key, value in record.items() if key != "client_key"}
            for record in sorted(self._load()["devices"].values(), key=lambda item: item["device_id"])
        ]

    def enrollment(self, device_id: str, object_base_url: str) -> list[dict[str, Any]]:
        parsed = urlsplit(object_base_url)
        if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment:
            raise RegistryError("object base URL must use HTTPS without query or fragment")
        try:
            record = self._load()["devices"][device_id]
        except KeyError as exc:
            raise RegistryError("device not found") from exc
        if not record["enabled"]:
            raise RegistryError("device is disabled")

        base = object_base_url.rstrip("/")
        return [
            {
                "id": profile_id,
                "name": _PROFILE_NAMES[profile_id],
                "bootstrap": {
                    "url": f"{base}/{self.object_id(device_id, profile_id)}.olcb",
                    "client_key": record["client_key"],
                },
            }
            for profile_id in record["profiles"]
        ]

    @staticmethod
    def object_id(device_id: str, profile_id: str) -> str:
        if not _ID.fullmatch(device_id) or profile_id not in _KNOWN_PROFILES:
            raise RegistryError("invalid device or profile id")
        return f"{device_id}/{profile_id}"
