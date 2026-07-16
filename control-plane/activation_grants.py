"""Durable single-use activation grants for managed field devices."""

from __future__ import annotations

import dataclasses
import datetime as dt
import hashlib
import os
import pathlib
import re
import secrets
import sqlite3


_DEVICE_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
_INSTALLATION_ID = re.compile(r"^[A-Za-z0-9_-]{16,128}$")
_TOKEN = re.compile(r"^[A-Za-z0-9_-]{43}$")


class ActivationError(ValueError):
    pass


class ActivationInvalid(ActivationError):
    pass


class ActivationExpired(ActivationError):
    pass


class ActivationConflict(ActivationError):
    pass


@dataclasses.dataclass(frozen=True)
class ActivationResult:
    device_id: str
    retried: bool


def _timestamp(value: dt.datetime | None) -> int:
    current = value or dt.datetime.now(dt.timezone.utc)
    if current.tzinfo is None:
        raise ValueError("activation time must be timezone-aware")
    return int(current.timestamp())


def _token_hash(token: str) -> bytes:
    if not _TOKEN.fullmatch(token):
        raise ActivationInvalid("invalid activation grant")
    return hashlib.sha256(token.encode("ascii")).digest()


class ActivationGrantStore:
    def __init__(self, path: str | pathlib.Path):
        self.path = pathlib.Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout = 10000")
        return connection

    def _initialize(self) -> None:
        with self._connect() as connection:
            connection.execute("PRAGMA journal_mode = WAL")
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS activation_grants (
                    token_hash BLOB PRIMARY KEY CHECK(length(token_hash) = 32),
                    device_id TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL,
                    consumed_at INTEGER,
                    consumed_by TEXT,
                    revoked_at INTEGER,
                    CHECK(expires_at > created_at),
                    CHECK((consumed_at IS NULL) = (consumed_by IS NULL))
                )
                """
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS activation_grants_device ON activation_grants(device_id)"
            )
        os.chmod(self.path, 0o600)

    def issue(
        self,
        device_id: str,
        *,
        ttl_seconds: int = 900,
        now: dt.datetime | None = None,
    ) -> str:
        if not _DEVICE_ID.fullmatch(device_id):
            raise ActivationInvalid("invalid device id")
        if ttl_seconds < 60 or ttl_seconds > 86400:
            raise ActivationInvalid("activation ttl must be between 60 and 86400 seconds")
        created_at = _timestamp(now)
        token = secrets.token_urlsafe(32)
        digest = _token_hash(token)
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                """
                UPDATE activation_grants
                   SET revoked_at = ?
                 WHERE device_id = ? AND consumed_at IS NULL AND revoked_at IS NULL
                """,
                (created_at, device_id),
            )
            connection.execute(
                """
                INSERT INTO activation_grants(
                    token_hash, device_id, created_at, expires_at
                ) VALUES (?, ?, ?, ?)
                """,
                (digest, device_id, created_at, created_at + ttl_seconds),
            )
            connection.commit()
        return token

    def consume(
        self,
        token: str,
        installation_id: str,
        *,
        now: dt.datetime | None = None,
    ) -> ActivationResult:
        digest = _token_hash(token)
        if not _INSTALLATION_ID.fullmatch(installation_id):
            raise ActivationInvalid("invalid installation id")
        consumed_at = _timestamp(now)
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT * FROM activation_grants WHERE token_hash = ?",
                (digest,),
            ).fetchone()
            if row is None or row["revoked_at"] is not None:
                connection.rollback()
                raise ActivationInvalid("invalid activation grant")
            if consumed_at > row["expires_at"]:
                connection.rollback()
                raise ActivationExpired("activation grant expired")
            if row["consumed_by"] is not None:
                connection.rollback()
                if secrets.compare_digest(row["consumed_by"], installation_id):
                    return ActivationResult(device_id=row["device_id"], retried=True)
                raise ActivationConflict("activation grant already bound")
            connection.execute(
                """
                UPDATE activation_grants
                   SET consumed_at = ?, consumed_by = ?
                 WHERE token_hash = ? AND consumed_at IS NULL
                """,
                (consumed_at, installation_id, digest),
            )
            connection.commit()
            return ActivationResult(device_id=row["device_id"], retried=False)
