import datetime as dt
import pathlib
import tempfile
import unittest

from rotation_journal import (
    GenerationCandidate,
    InvalidTransition,
    OperationConflict,
    RevisionCandidate,
    RotationJournal,
)
from state_store import ControlPlaneStore


class RotationJournalTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = ControlPlaneStore(pathlib.Path(self.temp.name) / "control-plane.db")
        self.now = dt.datetime(2026, 7, 13, 12, 0, tzinfo=dt.timezone.utc)
        self._seed_endpoint()
        self.lease = self.store.acquire_lease(
            "endpoint", "endpoint-1", "worker-a", now=self.now, ttl_seconds=60
        )
        self.journal = RotationJournal(self.store)
        self.candidate = RevisionCandidate(
            revision_id="revision-1",
            room_ref="room-1",
            server_unit="olc-endpoint-1-r1.service",
            channel="channel-1",
            tunnel_credential_ref="secret://tunnel-1",
            provider_expires_at="2026-07-14T12:00:00Z",
        )
        self.generation = GenerationCandidate(
            generation_id="generation-1",
            epoch=1,
            generation=1,
            issued_at="2026-07-13T12:00:00Z",
            expires_at="2026-07-14T12:00:00Z",
        )

    def _seed_endpoint(self) -> None:
        with self.store.transaction() as connection:
            connection.execute(
                "INSERT INTO users(id, display_name, status) VALUES ('owner', 'Owner', 'active')"
            )
            connection.execute(
                """
                INSERT INTO devices(id, user_id, status, public_key)
                VALUES ('device-1', 'owner', 'active', X'01')
                """
            )
            connection.execute(
                """
                INSERT INTO provider_identities(
                    id, user_id, provider, credential_ref, status, operational_health
                ) VALUES (
                    'identity-1', 'owner', 'telemost', 'secret://identity-1',
                    'active', 'healthy'
                )
                """
            )
            connection.execute(
                """
                INSERT INTO profile_assignments(
                    id, identity_id, user_id, device_id, provider, state, valid_from
                ) VALUES (
                    'assignment-1', 'identity-1', 'owner', 'device-1',
                    'telemost', 'active', '2026-07-13T12:00:00Z'
                )
                """
            )
            connection.execute(
                """
                INSERT INTO device_endpoints(id, assignment_id, provider, state)
                VALUES ('endpoint-1', 'assignment-1', 'telemost', 'active')
                """
            )

    def test_begin_is_idempotent_for_identical_operation(self) -> None:
        first = self.journal.begin(
            "operation-1",
            endpoint_id="endpoint-1",
            candidate=self.candidate,
            lease=self.lease,
            now=self.now,
        )
        second = self.journal.begin(
            "operation-1",
            endpoint_id="endpoint-1",
            candidate=self.candidate,
            lease=self.lease,
            now=self.now,
        )

        self.assertEqual(first, second)
        self.assertEqual(first.phase, "preparing")

    def test_begin_rejects_changed_replay(self) -> None:
        self.journal.begin(
            "operation-1",
            endpoint_id="endpoint-1",
            candidate=self.candidate,
            lease=self.lease,
            now=self.now,
        )
        changed = RevisionCandidate(
            **{**self.candidate.__dict__, "room_ref": "room-2"}
        )

        with self.assertRaises(OperationConflict):
            self.journal.begin(
                "operation-1",
                endpoint_id="endpoint-1",
                candidate=changed,
                lease=self.lease,
                now=self.now,
            )

    def test_authorize_records_immutable_publication_intent(self) -> None:
        self.journal.begin(
            "operation-1",
            endpoint_id="endpoint-1",
            candidate=self.candidate,
            lease=self.lease,
            now=self.now,
        )

        operation = self.journal.authorize(
            "operation-1",
            object_key="devices/device-1/profiles/telemost/generations/1-1.olcb",
            content_hash="a" * 64,
            generation=self.generation,
            lease=self.lease,
            now=self.now,
        )

        self.assertEqual(operation.phase, "publish_authorized")
        with self.store.transaction() as connection:
            revision = connection.execute(
                "SELECT state FROM endpoint_revisions WHERE id = 'revision-1'"
            ).fetchone()
            generation = connection.execute(
                "SELECT epoch, generation, state FROM profile_generations WHERE id = 'generation-1'"
            ).fetchone()
        self.assertEqual(revision["state"], "publish_authorized")
        self.assertEqual(tuple(generation), (1, 1, "preparing"))

    def test_rejects_skipped_transition(self) -> None:
        self.journal.begin(
            "operation-1",
            endpoint_id="endpoint-1",
            candidate=self.candidate,
            lease=self.lease,
            now=self.now,
        )

        with self.assertRaises(InvalidTransition):
            self.journal.mark_active(
                "operation-1",
                resulting_etag="etag-1",
                lease=self.lease,
                now=self.now,
            )

    def test_authorize_rejects_changed_generation_replay(self) -> None:
        self.journal.begin(
            "operation-1",
            endpoint_id="endpoint-1",
            candidate=self.candidate,
            lease=self.lease,
            now=self.now,
        )
        arguments = {
            "object_key": "devices/device-1/profiles/telemost/generations/1-1.olcb",
            "content_hash": "a" * 64,
            "lease": self.lease,
            "now": self.now,
        }
        self.journal.authorize(
            "operation-1", generation=self.generation, **arguments
        )

        changed = GenerationCandidate(
            **{**self.generation.__dict__, "generation": 2}
        )
        with self.assertRaises(OperationConflict):
            self.journal.authorize(
                "operation-1", generation=changed, **arguments
            )


if __name__ == "__main__":
    unittest.main()
