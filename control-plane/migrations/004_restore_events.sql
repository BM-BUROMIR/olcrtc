CREATE TABLE restore_events (
    reservation_id TEXT PRIMARY KEY,
    epoch_start INTEGER NOT NULL CHECK (epoch_start > 0),
    epoch_end INTEGER NOT NULL CHECK (epoch_end >= epoch_start),
    ledger_sequence INTEGER NOT NULL CHECK (ledger_sequence >= 0),
    restored_at TEXT NOT NULL
) STRICT;
