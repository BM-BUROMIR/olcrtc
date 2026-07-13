#!/usr/bin/env python3
"""Consistent control-plane backup and fail-closed restore."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import pathlib
import sqlite3
import uuid
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from state_store import ControlPlaneStore


class BackupError(RuntimeError):
    pass


class RestoreBlocked(BackupError):
    pass


def verify_database(path: str | pathlib.Path) -> dict[str, Any]:
    connection = sqlite3.connect(path)
    try:
        connection.execute("PRAGMA foreign_keys=ON")
        integrity_rows = connection.execute("PRAGMA integrity_check").fetchall()
        foreign_key_rows = connection.execute("PRAGMA foreign_key_check").fetchall()
    finally:
        connection.close()
    integrity = "ok" if integrity_rows == [("ok",)] else "failed"
    if integrity != "ok" or foreign_key_rows:
        raise BackupError(
            f"database verification failed: integrity={integrity}, "
            f"foreign_key_errors={len(foreign_key_rows)}"
        )
    return {"integrity": integrity, "foreign_key_errors": len(foreign_key_rows)}


def backup_database(
    source: str | pathlib.Path,
    destination: str | pathlib.Path,
) -> pathlib.Path:
    source = pathlib.Path(source)
    destination = pathlib.Path(destination)
    if not source.is_file():
        raise BackupError("source database does not exist")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(destination.parent, 0o700)
    temporary = destination.parent / f".{destination.name}.{uuid.uuid4().hex}.tmp"
    source_connection = sqlite3.connect(source)
    target_connection = sqlite3.connect(temporary)
    try:
        source_connection.backup(target_connection)
        target_connection.commit()
    finally:
        target_connection.close()
        source_connection.close()
    try:
        verify_database(temporary)
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def _signed_payload(
    path: str | pathlib.Path,
    public_key: Ed25519PublicKey,
) -> dict[str, Any]:
    try:
        document = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
        payload = document["payload"]
        signature = base64.b64decode(document["signature"], validate=True)
        canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        public_key.verify(signature, canonical)
    except (
        FileNotFoundError,
        KeyError,
        TypeError,
        ValueError,
        json.JSONDecodeError,
        InvalidSignature,
    ) as exc:
        raise RestoreBlocked("restore authority document is missing or invalid") from exc
    if not isinstance(payload, dict):
        raise RestoreBlocked("restore authority payload must be an object")
    return payload


def _load_public_key(path: str | pathlib.Path) -> Ed25519PublicKey:
    try:
        raw = pathlib.Path(path).read_bytes()
        return Ed25519PublicKey.from_public_bytes(raw)
    except (FileNotFoundError, ValueError) as exc:
        raise RestoreBlocked("restore authority public key is unavailable") from exc


def restore_database(
    backup: str | pathlib.Path,
    destination: str | pathlib.Path,
    *,
    authority_public_key: str | pathlib.Path,
    epoch_document: str | pathlib.Path,
    revocation_document: str | pathlib.Path,
    now: dt.datetime,
) -> pathlib.Path:
    if now.tzinfo is None:
        raise ValueError("restore timestamp must be timezone-aware")
    verify_database(backup)
    public_key = _load_public_key(authority_public_key)
    epoch = _signed_payload(epoch_document, public_key)
    ledger = _signed_payload(revocation_document, public_key)
    try:
        if epoch["schema_version"] != 1 or ledger["schema_version"] != 1:
            raise ValueError
        reservation_id = str(epoch["reservation_id"])
        epoch_start = int(epoch["epoch_start"])
        epoch_end = int(epoch["epoch_end"])
        ledger_sequence = int(ledger["sequence"])
        revocations = list(ledger["revocations"])
        if not reservation_id or epoch_start <= 0 or epoch_end < epoch_start:
            raise ValueError
        if ledger_sequence < 0:
            raise ValueError
    except (KeyError, TypeError, ValueError) as exc:
        raise RestoreBlocked("restore authority payload has an invalid schema") from exc

    destination = pathlib.Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = destination.parent / f".{destination.name}.{uuid.uuid4().hex}.restore"
    try:
        backup_database(backup, temporary)
        store = ControlPlaneStore(temporary)
        with store.transaction() as connection:
            connection.execute("DELETE FROM leases")
            for revocation in revocations:
                try:
                    identity_id = str(revocation["identity_id"])
                    revision = int(revocation["credential_revision"])
                    if not identity_id or revision <= 0:
                        raise ValueError
                except (KeyError, TypeError, ValueError) as exc:
                    raise RestoreBlocked("revocation ledger entry is invalid") from exc
                connection.execute(
                    """
                    UPDATE provider_identities
                    SET status = 'disabled',
                        credential_revision = MAX(credential_revision, ?),
                        row_version = row_version + 1
                    WHERE id = ?
                    """,
                    (revision, identity_id),
                )
            connection.execute(
                """
                INSERT INTO restore_events(
                    reservation_id, epoch_start, epoch_end, ledger_sequence, restored_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                (
                    reservation_id,
                    epoch_start,
                    epoch_end,
                    ledger_sequence,
                    now.astimezone(dt.timezone.utc).isoformat(),
                ),
            )
        with store.read_connection() as connection:
            connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        verify_database(temporary)
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
        temporary.with_name(temporary.name + "-wal").unlink(missing_ok=True)
        temporary.with_name(temporary.name + "-shm").unlink(missing_ok=True)
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description="Backup or restore durable control-plane state")
    subparsers = parser.add_subparsers(dest="command", required=True)
    backup_parser = subparsers.add_parser("backup")
    backup_parser.add_argument("--source", required=True, type=pathlib.Path)
    backup_parser.add_argument("--destination", required=True, type=pathlib.Path)
    restore_parser = subparsers.add_parser("restore")
    restore_parser.add_argument("--backup", required=True, type=pathlib.Path)
    restore_parser.add_argument("--destination", required=True, type=pathlib.Path)
    restore_parser.add_argument("--authority-public-key", required=True, type=pathlib.Path)
    restore_parser.add_argument("--epoch-document", required=True, type=pathlib.Path)
    restore_parser.add_argument("--revocation-document", required=True, type=pathlib.Path)
    args = parser.parse_args()
    if args.command == "backup":
        backup_database(args.source, args.destination)
    else:
        restore_database(
            args.backup,
            args.destination,
            authority_public_key=args.authority_public_key,
            epoch_document=args.epoch_document,
            revocation_document=args.revocation_document,
            now=dt.datetime.now(dt.timezone.utc),
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
