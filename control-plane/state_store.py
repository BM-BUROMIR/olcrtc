"""Transactional state for the managed provider control plane."""

from __future__ import annotations

import contextlib
import hashlib
import os
import pathlib
import sqlite3
from collections.abc import Iterator
from dataclasses import dataclass
import datetime as dt


class StoreError(RuntimeError):
    pass


class LeaseBusy(StoreError):
    pass


class StaleFence(StoreError):
    pass


@dataclass(frozen=True)
class Lease:
    resource_type: str
    resource_id: str
    owner_id: str
    expires_at: dt.datetime
    fencing_token: int


def _utc(value: dt.datetime) -> dt.datetime:
    if value.tzinfo is None:
        raise ValueError("lease timestamps must be timezone-aware")
    return value.astimezone(dt.timezone.utc)


def _timestamp(value: dt.datetime) -> str:
    return _utc(value).isoformat(timespec="microseconds").replace("+00:00", "Z")


def _parse_timestamp(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(dt.timezone.utc)


class ControlPlaneStore:
    def __init__(self, path: str | pathlib.Path):
        self.path = pathlib.Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._migrate()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("PRAGMA journal_mode=WAL")
        return connection

    def _migrate(self) -> None:
        migration = pathlib.Path(__file__).with_name("migrations") / "001_control_plane.sql"
        sql = migration.read_text(encoding="utf-8")
        checksum = hashlib.sha256(sql.encode()).hexdigest()
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version INTEGER PRIMARY KEY,
                    checksum TEXT NOT NULL,
                    applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                ) STRICT
                """
            )
            current = connection.execute(
                "SELECT checksum FROM schema_migrations WHERE version = 1"
            ).fetchone()
            if current is None:
                connection.executescript(sql)
                connection.execute(
                    "INSERT INTO schema_migrations(version, checksum) VALUES (1, ?)",
                    (checksum,),
                )
            elif current["checksum"] != checksum:
                raise StoreError("migration 1 checksum mismatch")
        os.chmod(self.path, 0o600)

    @contextlib.contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        connection = self._connect()
        connection.execute("BEGIN IMMEDIATE")
        try:
            yield connection
            connection.execute("COMMIT")
        except BaseException:
            connection.execute("ROLLBACK")
            raise
        finally:
            connection.close()

    def schema_version(self) -> int:
        with self._connect() as connection:
            row = connection.execute("SELECT MAX(version) AS version FROM schema_migrations").fetchone()
        return int(row["version"])

    def journal_mode(self) -> str:
        with self._connect() as connection:
            row = connection.execute("PRAGMA journal_mode").fetchone()
        return str(row[0]).lower()

    def foreign_keys_enabled(self) -> bool:
        with self._connect() as connection:
            row = connection.execute("PRAGMA foreign_keys").fetchone()
        return bool(row[0])

    def table_names(self) -> set[str]:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            ).fetchall()
        return {str(row["name"]) for row in rows}

    def acquire_lease(
        self,
        resource_type: str,
        resource_id: str,
        owner_id: str,
        *,
        now: dt.datetime,
        ttl_seconds: int,
    ) -> Lease:
        if ttl_seconds <= 0:
            raise ValueError("ttl_seconds must be positive")
        now = _utc(now)
        expires_at = now + dt.timedelta(seconds=ttl_seconds)
        with self.transaction() as connection:
            row = connection.execute(
                """
                SELECT owner_id, expires_at, fencing_token
                FROM leases
                WHERE resource_type = ? AND resource_id = ?
                """,
                (resource_type, resource_id),
            ).fetchone()
            if row is None:
                token = 1
                connection.execute(
                    """
                    INSERT INTO leases(
                        resource_type, resource_id, owner_id, expires_at, fencing_token
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    (resource_type, resource_id, owner_id, _timestamp(expires_at), token),
                )
            else:
                if _parse_timestamp(row["expires_at"]) > now:
                    raise LeaseBusy(f"{resource_type} {resource_id} is already leased")
                token = int(row["fencing_token"]) + 1
                connection.execute(
                    """
                    UPDATE leases
                    SET owner_id = ?, expires_at = ?, fencing_token = ?
                    WHERE resource_type = ? AND resource_id = ?
                    """,
                    (owner_id, _timestamp(expires_at), token, resource_type, resource_id),
                )
        return Lease(resource_type, resource_id, owner_id, expires_at, token)

    def assert_current_lease(
        self,
        lease: Lease,
        *,
        now: dt.datetime,
        connection: sqlite3.Connection | None = None,
    ) -> None:
        now = _utc(now)

        def check(active: sqlite3.Connection) -> None:
            row = active.execute(
                """
                SELECT owner_id, expires_at, fencing_token
                FROM leases
                WHERE resource_type = ? AND resource_id = ?
                """,
                (lease.resource_type, lease.resource_id),
            ).fetchone()
            if (
                row is None
                or row["owner_id"] != lease.owner_id
                or int(row["fencing_token"]) != lease.fencing_token
                or _parse_timestamp(row["expires_at"]) <= now
            ):
                raise StaleFence(
                    f"stale lease for {lease.resource_type} {lease.resource_id}"
                )

        if connection is not None:
            check(connection)
            return
        with self._connect() as active:
            check(active)

    def renew_lease(
        self,
        lease: Lease,
        *,
        now: dt.datetime,
        ttl_seconds: int,
    ) -> Lease:
        if ttl_seconds <= 0:
            raise ValueError("ttl_seconds must be positive")
        now = _utc(now)
        expires_at = now + dt.timedelta(seconds=ttl_seconds)
        with self.transaction() as connection:
            self.assert_current_lease(lease, now=now, connection=connection)
            connection.execute(
                """
                UPDATE leases
                SET expires_at = ?
                WHERE resource_type = ? AND resource_id = ?
                  AND owner_id = ? AND fencing_token = ?
                """,
                (
                    _timestamp(expires_at),
                    lease.resource_type,
                    lease.resource_id,
                    lease.owner_id,
                    lease.fencing_token,
                ),
            )
        return Lease(
            lease.resource_type,
            lease.resource_id,
            lease.owner_id,
            expires_at,
            lease.fencing_token,
        )
