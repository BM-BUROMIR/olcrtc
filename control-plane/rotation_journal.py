"""Fenced, idempotent journal for endpoint revision activation."""

from __future__ import annotations

import datetime as dt
import re
import sqlite3
from dataclasses import dataclass

from state_store import ControlPlaneStore, Lease


class JournalError(RuntimeError):
    pass


class OperationConflict(JournalError):
    pass


class InvalidTransition(JournalError):
    pass


@dataclass(frozen=True)
class RevisionCandidate:
    revision_id: str
    room_ref: str
    server_unit: str
    channel: str
    tunnel_credential_ref: str
    provider_expires_at: str | None


@dataclass(frozen=True)
class Operation:
    operation_id: str
    endpoint_id: str
    revision_id: str
    phase: str
    fencing_token: int
    object_key: str | None
    content_hash: str | None
    resulting_etag: str | None


def _timestamp(value: dt.datetime) -> str:
    if value.tzinfo is None:
        raise ValueError("journal timestamps must be timezone-aware")
    return value.astimezone(dt.timezone.utc).isoformat(timespec="microseconds").replace(
        "+00:00", "Z"
    )


class RotationJournal:
    def __init__(self, store: ControlPlaneStore):
        self.store = store

    @staticmethod
    def _operation(connection: sqlite3.Connection, operation_id: str) -> Operation | None:
        row = connection.execute(
            """
            SELECT id, endpoint_id, revision_id, phase, fencing_token,
                   object_key, content_hash, resulting_etag
            FROM operations
            WHERE id = ?
            """,
            (operation_id,),
        ).fetchone()
        if row is None:
            return None
        return Operation(
            operation_id=str(row["id"]),
            endpoint_id=str(row["endpoint_id"]),
            revision_id=str(row["revision_id"]),
            phase=str(row["phase"]),
            fencing_token=int(row["fencing_token"]),
            object_key=row["object_key"],
            content_hash=row["content_hash"],
            resulting_etag=row["resulting_etag"],
        )

    def begin(
        self,
        operation_id: str,
        *,
        endpoint_id: str,
        candidate: RevisionCandidate,
        lease: Lease,
        now: dt.datetime,
    ) -> Operation:
        with self.store.transaction() as connection:
            self.store.assert_current_lease(lease, now=now, connection=connection)
            existing = self._operation(connection, operation_id)
            if existing is not None:
                revision = connection.execute(
                    """
                    SELECT room_ref, server_unit, channel, tunnel_credential_ref,
                           provider_expires_at
                    FROM endpoint_revisions
                    WHERE id = ?
                    """,
                    (existing.revision_id,),
                ).fetchone()
                matches = (
                    existing.endpoint_id == endpoint_id
                    and existing.revision_id == candidate.revision_id
                    and existing.fencing_token == lease.fencing_token
                    and revision is not None
                    and tuple(revision) == (
                        candidate.room_ref,
                        candidate.server_unit,
                        candidate.channel,
                        candidate.tunnel_credential_ref,
                        candidate.provider_expires_at,
                    )
                )
                if not matches:
                    raise OperationConflict(f"operation {operation_id} replay changed")
                return existing

            connection.execute(
                """
                INSERT INTO endpoint_revisions(
                    id, endpoint_id, room_ref, server_unit, channel,
                    tunnel_credential_ref, state, provider_expires_at, fencing_token
                ) VALUES (?, ?, ?, ?, ?, ?, 'preparing', ?, ?)
                """,
                (
                    candidate.revision_id,
                    endpoint_id,
                    candidate.room_ref,
                    candidate.server_unit,
                    candidate.channel,
                    candidate.tunnel_credential_ref,
                    candidate.provider_expires_at,
                    lease.fencing_token,
                ),
            )
            timestamp = _timestamp(now)
            connection.execute(
                """
                INSERT INTO operations(
                    id, endpoint_id, revision_id, phase, fencing_token, created_at, updated_at
                ) VALUES (?, ?, ?, 'preparing', ?, ?, ?)
                """,
                (
                    operation_id,
                    endpoint_id,
                    candidate.revision_id,
                    lease.fencing_token,
                    timestamp,
                    timestamp,
                ),
            )
            operation = self._operation(connection, operation_id)
            assert operation is not None
            return operation

    def authorize(
        self,
        operation_id: str,
        *,
        object_key: str,
        content_hash: str,
        lease: Lease,
        now: dt.datetime,
    ) -> Operation:
        if not object_key or re.fullmatch(r"[0-9a-f]{64}", content_hash) is None:
            raise ValueError("publication object key or SHA-256 hash is invalid")
        with self.store.transaction() as connection:
            self.store.assert_current_lease(lease, now=now, connection=connection)
            operation = self._operation(connection, operation_id)
            if operation is None:
                raise JournalError(f"operation {operation_id} not found")
            if operation.fencing_token != lease.fencing_token:
                raise OperationConflict(f"operation {operation_id} has a different fence")
            if operation.phase == "publish_authorized":
                if operation.object_key == object_key and operation.content_hash == content_hash:
                    return operation
                raise OperationConflict(f"operation {operation_id} publication changed")
            if operation.phase != "preparing":
                raise InvalidTransition(
                    f"cannot authorize operation in phase {operation.phase}"
                )
            connection.execute(
                """
                UPDATE endpoint_revisions
                SET state = 'publish_authorized'
                WHERE id = ? AND state = 'preparing' AND fencing_token = ?
                """,
                (operation.revision_id, lease.fencing_token),
            )
            connection.execute(
                """
                UPDATE operations
                SET phase = 'publish_authorized', object_key = ?, content_hash = ?, updated_at = ?
                WHERE id = ?
                """,
                (object_key, content_hash, _timestamp(now), operation_id),
            )
            authorized = self._operation(connection, operation_id)
            assert authorized is not None
            return authorized

    def mark_active(
        self,
        operation_id: str,
        *,
        resulting_etag: str,
        lease: Lease,
        now: dt.datetime,
    ) -> Operation:
        if not resulting_etag:
            raise ValueError("resulting_etag is required")
        with self.store.transaction() as connection:
            self.store.assert_current_lease(lease, now=now, connection=connection)
            operation = self._operation(connection, operation_id)
            if operation is None:
                raise JournalError(f"operation {operation_id} not found")
            if operation.phase != "publish_authorized":
                raise InvalidTransition(
                    f"cannot activate operation in phase {operation.phase}"
                )
            connection.execute(
                "UPDATE endpoint_revisions SET state = 'active' WHERE id = ?",
                (operation.revision_id,),
            )
            connection.execute(
                """
                UPDATE operations
                SET phase = 'active', resulting_etag = ?, updated_at = ?
                WHERE id = ?
                """,
                (resulting_etag, _timestamp(now), operation_id),
            )
            active = self._operation(connection, operation_id)
            assert active is not None
            return active
