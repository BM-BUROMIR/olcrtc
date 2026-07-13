"""Transactional state for the managed provider control plane."""

from __future__ import annotations

import contextlib
import hashlib
import os
import pathlib
import sqlite3
from collections.abc import Iterator


class StoreError(RuntimeError):
    pass


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
