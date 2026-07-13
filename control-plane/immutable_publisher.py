"""Immutable generation publication with fenced manifest cutover."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import pathlib
import uuid
from dataclasses import dataclass
from typing import Any, Protocol

from rotation_journal import GenerationCandidate, Operation, RotationJournal
from state_store import ControlPlaneStore, Lease, StaleFence


class PublicationError(RuntimeError):
    pass


class ImmutableConflict(PublicationError):
    pass


class ManifestConflict(PublicationError):
    pass


class StaleManifestFence(PublicationError):
    pass


class InjectedFailure(PublicationError):
    pass


class ImmutableBackend(Protocol):
    def put_immutable(self, object_key: str, blob: bytes) -> str: ...


class ManifestGateway(Protocol):
    def compare_and_swap(
        self,
        stream_id: str,
        *,
        expected_etag: str | None,
        manifest: dict[str, Any],
        lease: Lease,
        now: dt.datetime,
    ) -> str: ...

    def get_manifest(
        self, stream_id: str
    ) -> tuple[dict[str, Any], str] | None: ...


class MemoryImmutableBackend:
    def __init__(self) -> None:
        self.objects: dict[str, bytes] = {}

    def put_immutable(self, object_key: str, blob: bytes) -> str:
        current = self.objects.get(object_key)
        if current is not None and current != blob:
            raise ImmutableConflict(f"immutable object changed: {object_key}")
        self.objects[object_key] = blob
        return f"memory://{object_key}"


class FilesystemImmutableBackend:
    def __init__(self, root: str | pathlib.Path) -> None:
        self.root = pathlib.Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)

    def _path(self, object_key: str) -> pathlib.Path:
        relative = pathlib.PurePosixPath(object_key)
        if relative.is_absolute() or ".." in relative.parts or not relative.parts:
            raise ValueError("unsafe immutable object key")
        return self.root.joinpath(*relative.parts)

    def put_immutable(self, object_key: str, blob: bytes) -> str:
        target = self._path(object_key)
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(target.parent, 0o700)
        if target.exists():
            if target.read_bytes() != blob:
                raise ImmutableConflict(f"immutable object changed: {object_key}")
            return target.as_uri()

        temporary = self.root / f".tmp-{uuid.uuid4().hex}"
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(blob)
                stream.flush()
                os.fsync(stream.fileno())
            try:
                os.link(temporary, target)
            except FileExistsError:
                if target.read_bytes() != blob:
                    raise ImmutableConflict(f"immutable object changed: {object_key}")
        finally:
            temporary.unlink(missing_ok=True)
        return target.as_uri()


@dataclass
class _ManifestRecord:
    manifest: dict[str, Any]
    etag: str
    fencing_token: int


class MemoryManifestGateway:
    def __init__(self) -> None:
        self._records: dict[str, _ManifestRecord] = {}
        self._next_etag = 1

    def compare_and_swap(
        self,
        stream_id: str,
        *,
        expected_etag: str | None,
        manifest: dict[str, Any],
        lease: Lease,
        now: dt.datetime,
    ) -> str:
        current = self._records.get(stream_id)
        if current is not None and lease.fencing_token < current.fencing_token:
            raise StaleManifestFence(f"stale manifest fence for {stream_id}")
        current_etag = current.etag if current is not None else None
        if current_etag != expected_etag:
            raise ManifestConflict(f"manifest ETag changed for {stream_id}")
        etag = str(self._next_etag)
        self._next_etag += 1
        self._records[stream_id] = _ManifestRecord(
            manifest=dict(manifest),
            etag=etag,
            fencing_token=lease.fencing_token,
        )
        return etag

    def get_manifest(
        self, stream_id: str
    ) -> tuple[dict[str, Any], str] | None:
        record = self._records.get(stream_id)
        if record is None:
            return None
        return dict(record.manifest), record.etag


class SQLiteManifestGateway:
    """Manifest authority that checks lease and CAS in one database transaction."""

    def __init__(self, store: ControlPlaneStore) -> None:
        self.store = store

    def compare_and_swap(
        self,
        stream_id: str,
        *,
        expected_etag: str | None,
        manifest: dict[str, Any],
        lease: Lease,
        now: dt.datetime,
    ) -> str:
        with self.store.transaction() as connection:
            try:
                self.store.assert_current_lease(
                    lease,
                    now=now,
                    connection=connection,
                )
            except StaleFence as exc:
                raise StaleManifestFence(f"stale manifest fence for {stream_id}") from exc
            current = connection.execute(
                "SELECT etag FROM manifest_streams WHERE stream_id = ?",
                (stream_id,),
            ).fetchone()
            current_etag = str(current["etag"]) if current is not None else None
            if current_etag != expected_etag:
                raise ManifestConflict(f"manifest ETag changed for {stream_id}")
            next_etag = int(current["etag"]) + 1 if current is not None else 1
            payload = json.dumps(manifest, sort_keys=True, separators=(",", ":"))
            connection.execute(
                """
                INSERT INTO manifest_streams(
                    stream_id, manifest_json, etag, fencing_token, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(stream_id) DO UPDATE SET
                    manifest_json = excluded.manifest_json,
                    etag = excluded.etag,
                    fencing_token = excluded.fencing_token,
                    updated_at = excluded.updated_at
                """,
                (
                    stream_id,
                    payload,
                    next_etag,
                    lease.fencing_token,
                    now.astimezone(dt.timezone.utc).isoformat(),
                ),
            )
        return str(next_etag)

    def get_manifest(
        self, stream_id: str
    ) -> tuple[dict[str, Any], str] | None:
        with self.store.read_connection() as connection:
            row = connection.execute(
                "SELECT manifest_json, etag FROM manifest_streams WHERE stream_id = ?",
                (stream_id,),
            ).fetchone()
        if row is None:
            return None
        return json.loads(row["manifest_json"]), str(row["etag"])


class ImmutablePublisher:
    def __init__(
        self,
        *,
        store: ControlPlaneStore,
        journal: RotationJournal,
        backend: ImmutableBackend,
        gateway: ManifestGateway,
    ) -> None:
        self.store = store
        self.journal = journal
        self.backend = backend
        self.gateway = gateway

    def publish(
        self,
        *,
        operation_id: str,
        stream_id: str,
        object_key: str,
        blob: bytes,
        generation: GenerationCandidate,
        expected_etag: str | None,
        lease: Lease,
        now: dt.datetime,
        fail_after: str | None = None,
    ) -> Operation:
        operation = self.journal.get(operation_id)
        content_hash = hashlib.sha256(blob).hexdigest()
        self.backend.put_immutable(object_key, blob)
        if fail_after == "object_put":
            raise InjectedFailure("failure after immutable object PUT")

        operation = self.journal.authorize(
            operation_id,
            object_key=object_key,
            content_hash=content_hash,
            generation=generation,
            lease=lease,
            now=now,
        )
        if fail_after == "publish_authorized":
            raise InjectedFailure("failure after publication authorization")

        manifest = {
            "operation_id": operation.operation_id,
            "endpoint_id": operation.endpoint_id,
            "revision_id": operation.revision_id,
            "object_key": object_key,
            "content_hash": content_hash,
            "fencing_token": operation.fencing_token,
        }
        resulting_etag = self.gateway.compare_and_swap(
            stream_id,
            expected_etag=expected_etag,
            manifest=manifest,
            lease=lease,
            now=now,
        )
        if fail_after == "manifest_cas":
            raise InjectedFailure("failure after manifest CAS")
        return self.journal.mark_active(
            operation_id,
            resulting_etag=resulting_etag,
            lease=lease,
            now=now,
        )

    def reconcile(
        self,
        operation_id: str,
        *,
        stream_id: str,
        lease: Lease,
        now: dt.datetime,
    ) -> Operation:
        operation = self.journal.get(operation_id)
        visible = self.gateway.get_manifest(stream_id)
        if visible is None:
            raise ManifestConflict(f"manifest is absent for {stream_id}")
        manifest, etag = visible
        expected = {
            "operation_id": operation.operation_id,
            "endpoint_id": operation.endpoint_id,
            "revision_id": operation.revision_id,
            "object_key": operation.object_key,
            "content_hash": operation.content_hash,
            "fencing_token": operation.fencing_token,
        }
        if manifest != expected:
            raise ManifestConflict(f"manifest does not match operation {operation_id}")
        return self.journal.reconcile_active(
            operation_id,
            resulting_etag=etag,
            lease=lease,
            now=now,
        )
