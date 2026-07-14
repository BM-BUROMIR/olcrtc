#!/usr/bin/env python3
"""Production orchestration helpers for managed carrier rotation."""

from __future__ import annotations

import datetime as dt
import argparse
import json
import os
import pathlib
import shlex
import socket
import subprocess
import time
import uuid
from dataclasses import dataclass
from typing import Any, Protocol

import yaml

from bootstrap import YandexStorageBackend, encrypt_subscription
from device_registry import DeviceRegistry
from envelope import build_envelope
from room_manager import Deployment, RoomManager
from rotate import RotationTransaction
from server_config import render_server_config
from shadow_runtime import ShadowEndpoint, record_shadow_generation
from telemost_client import TelemostClient, load_cookie_header


class ObjectBackend(Protocol):
    def put(self, object_id: str, blob: bytes) -> str: ...
    def get(self, object_id: str) -> bytes | None: ...
    def delete(self, object_id: str) -> None: ...


def _utc(value: dt.datetime) -> dt.datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("now must include timezone")
    return value.astimezone(dt.timezone.utc)


def _timestamp(value: str) -> dt.datetime:
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    return _utc(parsed)


def should_rotate(
    active_envelope: dict[str, Any] | None,
    room: str,
    *,
    now: dt.datetime,
    refresh_before: dt.timedelta,
) -> bool:
    """Return true when the published room changed or its envelope is near expiry."""
    if not active_envelope:
        return True
    try:
        active_room = active_envelope["subscription"]["room"]
        expires_at = _timestamp(active_envelope["expires_at"])
    except (KeyError, TypeError, ValueError):
        return True
    return active_room != room or expires_at <= _utc(now) + refresh_before


class DeviceEnvelopePublisher:
    """Publish one encrypted envelope per authorized device with compensating rollback."""

    def __init__(self, registry: DeviceRegistry, backend: ObjectBackend):
        self.registry = registry
        self.backend = backend

    def publish_transactionally(self, profile_id: str, envelope: dict[str, Any]) -> "Publication":
        candidates = []
        for record in self.registry.publishable(profile_id):
            object_id = DeviceRegistry.object_id(record["device_id"], profile_id)
            previous = self.backend.get(object_id)
            blob = encrypt_subscription(envelope, bytes.fromhex(record["client_key"]))
            candidates.append((object_id, previous, blob))

        updated: list[tuple[str, bytes | None]] = []
        try:
            for object_id, previous, blob in candidates:
                self.backend.put(object_id, blob)
                updated.append((object_id, previous))
        except Exception:
            self._rollback(updated)
            raise
        return Publication(len(candidates), lambda: self._rollback(updated))

    def publish(self, profile_id: str, envelope: dict[str, Any]) -> int:
        return self.publish_transactionally(profile_id, envelope).count

    def _rollback(self, updated: list[tuple[str, bytes | None]]) -> None:
        rollback_errors = []
        for object_id, previous in reversed(updated):
            try:
                if previous is None:
                    self.backend.delete(object_id)
                else:
                    self.backend.put(object_id, previous)
            except Exception as exc:
                rollback_errors.append(f"{object_id}: {exc}")
        if rollback_errors:
            raise RuntimeError("bootstrap rollback failed: " + "; ".join(rollback_errors))


def reconcile_active_envelope(
    registry: DeviceRegistry,
    backend: ObjectBackend,
    profile_id: str,
    active_envelope: dict[str, Any],
) -> int:
    """Publish a healthy envelope to the registry without rotating the carrier."""
    return DeviceEnvelopePublisher(registry, backend).publish(profile_id, active_envelope)


@dataclass(frozen=True)
class Publication:
    count: int
    _rollback: Any

    def rollback(self) -> None:
        self._rollback()


def _run(command: list[str], *, timeout: int = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=True, text=True, capture_output=True, timeout=timeout)


class SSHServerActivator:
    """Atomically install a complete server config and retain a rollback copy."""

    def __init__(
        self,
        *,
        host: str,
        user: str,
        ssh_key: pathlib.Path,
        base_config: pathlib.Path,
        remote_config: str,
        service: str,
        work_dir: pathlib.Path,
        auth_token_path: pathlib.Path | None = None,
    ) -> None:
        self.host = host
        self.user = user
        self.ssh_key = ssh_key
        self.base_config = base_config
        self.remote_config = remote_config
        self.service = service
        self.work_dir = work_dir
        self.auth_token_path = auth_token_path

    @property
    def _ssh_options(self) -> list[str]:
        options = [
            "-i", str(self.ssh_key), "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
            "-o", "ConnectTimeout=15",
        ]
        known_hosts = os.environ.get("OLC_SSH_KNOWN_HOSTS_PATH")
        if known_hosts:
            options.extend([
                "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={known_hosts}",
            ])
        else:
            options.extend(["-o", "StrictHostKeyChecking=accept-new"])
        return options

    @property
    def _target(self) -> str:
        return f"{self.user}@{self.host}"

    def activate(self, payload: dict[str, Any]) -> "ServerBackup":
        self.work_dir.mkdir(parents=True, exist_ok=True)
        candidate = self.work_dir / "server-candidate.yaml"
        auth_token = None
        if self.auth_token_path is not None:
            auth_token = self.auth_token_path.read_text(encoding="utf-8").strip()
            if not auth_token:
                raise ValueError("provider auth token is empty")
        rendered = render_server_config(
            self.base_config.read_text(encoding="utf-8"),
            payload["subscription"],
            auth_token=auth_token,
        )
        candidate.write_text(rendered, encoding="utf-8")
        os.chmod(candidate, 0o600)

        transaction_id = uuid.uuid4().hex
        upload = f".olc-rotation-{transaction_id}.yaml"
        backup = f"/var/lib/olc-bypass/rotation/{transaction_id}.yaml"
        metadata_result = _run([
            "ssh", *self._ssh_options, self._target,
            f"sudo stat -c '%U %G %a' {shlex.quote(self.remote_config)}",
        ])
        owner, group, mode = metadata_result.stdout.strip().split()
        _run(["scp", *self._ssh_options, str(candidate), f"{self._target}:{upload}"])
        prepare = " && ".join([
            "sudo install -d -m 700 /var/lib/olc-bypass/rotation",
            f"sudo cp {shlex.quote(self.remote_config)} {shlex.quote(backup)}",
        ])
        _run(["ssh", *self._ssh_options, self._target, prepare])
        install = " && ".join([
            f"sudo install -o {shlex.quote(owner)} -g {shlex.quote(group)} -m {shlex.quote(mode)} "
            f"{shlex.quote(upload)} {shlex.quote(self.remote_config)}",
            f"rm -f {shlex.quote(upload)}",
            f"sudo systemctl reset-failed {shlex.quote(self.service)}",
            f"sudo systemctl restart {shlex.quote(self.service)}",
        ])
        token = ServerBackup(backup, owner, group, mode)
        try:
            _run(["ssh", *self._ssh_options, self._target, install])
        except Exception:
            self.rollback(token)
            raise
        return token

    def ready(self) -> None:
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            try:
                result = _run([
                    "ssh", *self._ssh_options, self._target,
                    f"sudo systemctl show --property=ActiveState --property=MainPID {shlex.quote(self.service)}",
                ], timeout=20)
                status = dict(
                    line.split("=", 1) for line in result.stdout.splitlines() if "=" in line
                )
                if status.get("ActiveState") in ("active", "activating") and int(status.get("MainPID", "0")) > 0:
                    time.sleep(2)
                    confirmation = _run([
                        "ssh", *self._ssh_options, self._target,
                        f"sudo systemctl show --property=ActiveState --property=MainPID {shlex.quote(self.service)}",
                    ], timeout=20)
                    confirmed = dict(
                        line.split("=", 1) for line in confirmation.stdout.splitlines() if "=" in line
                    )
                    if confirmed.get("ActiveState") in ("active", "activating") and int(confirmed.get("MainPID", "0")) > 0:
                        return
            except (subprocess.SubprocessError, OSError):
                pass
            time.sleep(2)
        raise RuntimeError("server service did not become active")

    def rollback(self, token: "ServerBackup") -> None:
        remote = " && ".join([
            f"sudo install -o {shlex.quote(token.owner)} -g {shlex.quote(token.group)} "
            f"-m {shlex.quote(token.mode)} {shlex.quote(token.path)} {shlex.quote(self.remote_config)}",
            f"sudo systemctl reset-failed {shlex.quote(self.service)}",
            f"sudo systemctl restart {shlex.quote(self.service)}",
        ])
        _run(["ssh", *self._ssh_options, self._target, remote])


@dataclass(frozen=True)
class ServerBackup:
    path: str
    owner: str
    group: str
    mode: str


class OlcSocksProbe:
    """Start a bounded CNC process and verify HTTPS plus a 1 MiB transfer through SOCKS."""

    def __init__(self, binary: pathlib.Path, work_dir: pathlib.Path) -> None:
        self.binary = binary
        self.work_dir = work_dir

    @staticmethod
    def _free_port() -> int:
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            return listener.getsockname()[1]

    def __call__(self, payload: dict[str, Any]) -> None:
        self.work_dir.mkdir(parents=True, exist_ok=True)
        port = self._free_port()
        subscription = payload["subscription"]
        config = {
            "mode": "cnc",
            "auth": {"provider": subscription["carrier"]},
            "room": {"id": subscription["room"], "channel": subscription["channel"]},
            "crypto": {"key": subscription["crypto_key"]},
            "net": {"transport": subscription.get("transport", "vp8channel"), "dns": "8.8.8.8:53"},
            "vp8": {"fps": 30, "batch_size": 8, "max_bytes_per_sec": 60000},
            "socks": {"host": "127.0.0.1", "port": port, "max_sessions": 24},
            "data": str(self.work_dir / "data"),
        }
        config_path = self.work_dir / "probe-cnc.yaml"
        config_path.write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")
        os.chmod(config_path, 0o600)
        log_path = self.work_dir / "probe-cnc.log"
        with log_path.open("ab") as log:
            process = subprocess.Popen([str(self.binary), str(config_path)], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError("probe CNC exited before SOCKS became ready")
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=1):
                            break
                    except OSError:
                        time.sleep(0.5)
                else:
                    raise RuntimeError("probe SOCKS did not become ready")

                proxy = f"127.0.0.1:{port}"
                for url in (
                    "https://api.ipify.org?format=json",
                    "https://speed.cloudflare.com/__down?bytes=1048576",
                ):
                    _run([
                        "curl", "--fail", "--silent", "--show-error", "--location",
                        "--max-time", "75", "--socks5-hostname", proxy,
                        "--output", "/dev/null", url,
                    ], timeout=85)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def _load_json(path: pathlib.Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def _replace_private_json(path: pathlib.Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def record_shadow_if_configured(
    config: dict[str, Any],
    envelope: dict[str, Any],
    *,
    now: dt.datetime,
    provider: str = "telemost",
) -> dict[str, Any] | None:
    shadow = config.get("shadow")
    if shadow is None:
        return None
    endpoint = ShadowEndpoint(
        user_id=shadow["user_id"],
        device_id=shadow["device_id"],
        identity_id=shadow["identity_id"],
        assignment_id=shadow["assignment_id"],
        endpoint_id=shadow["endpoint_id"],
        provider=provider,
    )
    return record_shadow_generation(
        state_path=shadow["state_db"],
        object_root=shadow["object_root"],
        endpoint=endpoint,
        envelope=envelope,
        now=now,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Rotate, probe, and publish managed Telemost bootstrap")
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
    room_manager = RoomManager(
        TelemostClient(
            load_cookie_header(
                os.environ.get("OLC_TELEMOST_COOKIES_PATH", config["cookies_path"])
            )
        ),
        Deployment.load(
            os.environ.get("OLC_DEPLOYMENT_PATH", config["deployment_path"])
        ),
        str(runtime / "rooms.json"),
    )
    room = room_manager.rotate_now() if args.force else room_manager.ensure_current()
    envelope_path = runtime / "telemost-envelope.json"
    active = _load_json(envelope_path)
    now = dt.datetime.now(dt.timezone.utc)
    backend = YandexStorageBackend(
        config["yc_bucket"],
        access_key=access_key,
        secret_key=secret_key,
    )
    registry = DeviceRegistry(runtime / "devices.json")
    if not args.force and not should_rotate(
        active, room["uri"], now=now, refresh_before=dt.timedelta(hours=2)
    ):
        published = reconcile_active_envelope(registry, backend, "telemost", active)
        print(json.dumps({
            "status": "healthy",
            "profile": "telemost",
            "generation": active["generation"],
            "published_devices": published,
        }))
        return 0

    generation = int(active.get("generation", 0) if active else 0) + 1
    expires_at = dt.datetime.fromtimestamp(room["expires_at"], tz=dt.timezone.utc) - dt.timedelta(minutes=15)
    envelope = build_envelope(
        profile_id="telemost",
        generation=generation,
        issued_at=now,
        expires_at=expires_at,
        subscription=room_manager.subscription(),
    )
    server = config["server"]
    activator = SSHServerActivator(
        host=server["host"], user=server.get("user", "ubuntu"),
        ssh_key=pathlib.Path(
            os.environ.get("OLC_SSH_KEY_PATH", server["ssh_key"])
        ),
        base_config=pathlib.Path(
            os.environ.get("OLC_SERVER_BASE_CONFIG", server["base_config"])
        ),
        remote_config=server.get("config_path", "/etc/olc-bypass/tm-srv.yaml"),
        service=server.get("service", "olc-telemost-srv.service"),
        work_dir=runtime,
    )
    publisher = DeviceEnvelopePublisher(registry, backend)

    def publish(payload: dict[str, Any]) -> Publication:
        publication = publisher.publish_transactionally("telemost", payload)
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
        state_path=runtime / "rotation-state.json",
        activator=activator,
        probe=OlcSocksProbe(pathlib.Path(config["olcrtc_binary"]), runtime / "probe"),
        publish=publish,
    )
    changed = transaction.run(envelope)
    shadow_result = record_shadow_if_configured(config, envelope, now=now) if changed else None
    print(json.dumps({
        "status": "rotated" if changed else "unchanged",
        "profile": "telemost", "generation": generation,
        "published_devices": len(registry.publishable("telemost")),
        "shadow": shadow_result,
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
