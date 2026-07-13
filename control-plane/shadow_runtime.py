"""Record legacy rotations in the durable model without changing client delivery."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import pathlib
from dataclasses import dataclass
from typing import Any

from immutable_publisher import (
    FilesystemImmutableBackend,
    ImmutablePublisher,
    SQLiteManifestGateway,
)
from rotation_journal import GenerationCandidate, RevisionCandidate, RotationJournal
from state_store import ControlPlaneStore


@dataclass(frozen=True)
class ShadowEndpoint:
    user_id: str
    device_id: str
    identity_id: str
    assignment_id: str
    endpoint_id: str
    provider: str


def _seed_shadow_endpoint(
    store: ControlPlaneStore,
    endpoint: ShadowEndpoint,
    *,
    now: dt.datetime,
) -> None:
    timestamp = now.astimezone(dt.timezone.utc).isoformat()
    with store.transaction() as connection:
        connection.execute(
            """
            INSERT OR IGNORE INTO users(id, display_name, status)
            VALUES (?, ?, 'active')
            """,
            (endpoint.user_id, endpoint.user_id),
        )
        connection.execute(
            """
            INSERT OR IGNORE INTO devices(id, user_id, status, public_key, enrolled_at)
            VALUES (?, ?, 'active', X'00', ?)
            """,
            (endpoint.device_id, endpoint.user_id, timestamp),
        )
        connection.execute(
            """
            INSERT OR IGNORE INTO provider_identities(
                id, user_id, provider, credential_ref, status, operational_health
            ) VALUES (?, ?, ?, 'shadow://legacy', 'active', 'healthy')
            """,
            (endpoint.identity_id, endpoint.user_id, endpoint.provider),
        )
        connection.execute(
            """
            INSERT OR IGNORE INTO profile_assignments(
                id, identity_id, user_id, device_id, provider, state, valid_from
            ) VALUES (?, ?, ?, ?, ?, 'active', ?)
            """,
            (
                endpoint.assignment_id,
                endpoint.identity_id,
                endpoint.user_id,
                endpoint.device_id,
                endpoint.provider,
                timestamp,
            ),
        )
        connection.execute(
            """
            INSERT OR IGNORE INTO device_endpoints(id, assignment_id, provider, state)
            VALUES (?, ?, ?, 'active')
            """,
            (endpoint.endpoint_id, endpoint.assignment_id, endpoint.provider),
        )


def record_shadow_generation(
    *,
    state_path: str | pathlib.Path,
    object_root: str | pathlib.Path,
    endpoint: ShadowEndpoint,
    envelope: dict[str, Any],
    now: dt.datetime,
) -> dict[str, Any]:
    generation = int(envelope["generation"])
    subscription = envelope["subscription"]
    blob = json.dumps(
        envelope,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    digest = hashlib.sha256(blob).hexdigest()
    operation_id = f"{endpoint.endpoint_id}-{generation}-{digest[:12]}"
    revision_id = f"{endpoint.endpoint_id}-r{generation}-{digest[:12]}"
    object_key = (
        f"devices/{endpoint.device_id}/profiles/{endpoint.provider}/"
        f"generations/1-{generation}.olcb"
    )
    stream_id = f"{endpoint.device_id}/{endpoint.provider}"

    store = ControlPlaneStore(state_path)
    _seed_shadow_endpoint(store, endpoint, now=now)
    lease = store.acquire_lease(
        "endpoint",
        endpoint.endpoint_id,
        operation_id,
        now=now,
        ttl_seconds=300,
    )
    journal = RotationJournal(store)
    operation = journal.begin(
        operation_id,
        endpoint_id=endpoint.endpoint_id,
        candidate=RevisionCandidate(
            revision_id=revision_id,
            room_ref=str(subscription["room"]),
            server_unit=f"shadow-{endpoint.endpoint_id}-r{generation}",
            channel=str(subscription["channel"]),
            tunnel_credential_ref=f"shadow://{endpoint.endpoint_id}/r{generation}",
            provider_expires_at=envelope.get("expires_at"),
        ),
        lease=lease,
        now=now,
    )
    gateway = SQLiteManifestGateway(store)
    visible = gateway.get_manifest(stream_id)
    expected_etag = visible[1] if visible is not None else None
    active = ImmutablePublisher(
        store=store,
        journal=journal,
        backend=FilesystemImmutableBackend(object_root),
        gateway=gateway,
    ).publish(
        operation_id=operation.operation_id,
        stream_id=stream_id,
        object_key=object_key,
        blob=blob,
        generation=GenerationCandidate(
            generation_id=f"{endpoint.endpoint_id}-e1-g{generation}",
            epoch=1,
            generation=generation,
            issued_at=str(envelope["issued_at"]),
            expires_at=str(envelope["expires_at"]),
        ),
        expected_etag=expected_etag,
        lease=lease,
        now=now,
    )
    return {
        "operation_id": active.operation_id,
        "phase": active.phase,
        "generation": generation,
        "object_key": object_key,
        "manifest_etag": active.resulting_etag,
    }
