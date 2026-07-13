# Control-plane backup and restore

## Backup

Run the online backup against the live SQLite database:

```bash
python3 control-plane/backup_state.py backup +  --source .secrets/runtime/control-plane/control-plane.db +  --destination .secrets/backups/control-plane/latest.db
```

The command exits non-zero unless `integrity_check` is `ok` and `foreign_key_check` is empty. Copy
the resulting mode-0600 file to the configured independent backup location.

## Restore prerequisites

Obtain these independently signed documents from the recovery authority:

- an unused epoch reservation containing `reservation_id`, `epoch_start`, and `epoch_end`;
- the latest append-only revocation ledger containing `sequence` and all identity revocations since
  the backup;
- the pinned raw Ed25519 authority public key.

Do not start the scheduler when either document is unavailable or its signature fails.

## Restore

Stop the scheduler and restore to a new path:

```bash
python3 control-plane/backup_state.py restore +  --backup .secrets/backups/control-plane/latest.db +  --destination .secrets/runtime/control-plane/restored.db +  --authority-public-key .secrets/recovery/authority.pub +  --epoch-document .secrets/recovery/epoch-reservation.json +  --revocation-document .secrets/recovery/revocation-ledger.json
```

The restore applies pending revocations, removes all leases, records the reserved epoch range, runs
database checks, and atomically installs the restored file. Point shadow mode at `restored.db` and
run one reconciliation cycle before replacing the active database.

## Verification

```bash
(cd control-plane && python3 -m unittest tests/test_backup_state.py -v)
sqlite3 .secrets/runtime/control-plane/restored.db +  'PRAGMA integrity_check; PRAGMA foreign_key_check; SELECT * FROM restore_events;'
```

Expected: `ok`, no foreign-key rows, and exactly one new restore event with the issued reservation
and ledger sequence.
