"""Fail-closed rotation transaction: activate, verify, publish, then commit."""

from __future__ import annotations

import fcntl
import json
import os
import pathlib
from typing import Any, Callable, Protocol


class RotationError(RuntimeError):
    pass


class Activator(Protocol):
    def activate(self, payload: dict[str, Any]) -> str: ...
    def ready(self) -> None: ...
    def rollback(self, token: str) -> None: ...


class RotationTransaction:
    def __init__(
        self,
        *,
        state_path: str | pathlib.Path,
        activator: Activator,
        probe: Callable[[dict[str, Any]], None],
        publish: Callable[[dict[str, Any]], None],
    ) -> None:
        self.state_path = pathlib.Path(state_path)
        self.activator = activator
        self.probe = probe
        self.publish = publish

    def _state(self) -> dict[str, Any]:
        if not self.state_path.exists():
            return {"schema_version": 1, "active_generation": 0}
        return json.loads(self.state_path.read_text(encoding="utf-8"))

    def _commit(self, payload: dict[str, Any]) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.state_path.with_suffix(self.state_path.suffix + ".tmp")
        state = {
            "schema_version": 1,
            "profile_id": payload["profile_id"],
            "active_generation": payload["generation"],
        }
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(state, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, self.state_path)

    def run(self, payload: dict[str, Any]) -> bool:
        generation = payload.get("generation")
        if not isinstance(generation, int) or isinstance(generation, bool) or generation <= 0:
            raise RotationError("generation must be a positive integer")
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        lock_path = self.state_path.with_suffix(self.state_path.suffix + ".lock")
        with lock_path.open("a+", encoding="utf-8") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            active = self._state().get("active_generation", 0)
            if generation == active:
                return False
            if generation < active:
                raise RotationError("generation is older than active generation")

            backup_token = None
            try:
                backup_token = self.activator.activate(payload)
                self.activator.ready()
                self.probe(payload)
                self.publish(payload)
                self._commit(payload)
                return True
            except Exception as exc:
                if backup_token is not None:
                    try:
                        self.activator.rollback(backup_token)
                    except Exception as rollback_exc:
                        raise RotationError(f"{exc}; rollback failed: {rollback_exc}") from rollback_exc
                raise RotationError(str(exc)) from exc
