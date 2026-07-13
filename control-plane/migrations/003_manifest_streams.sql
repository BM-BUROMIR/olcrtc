CREATE TABLE manifest_streams (
    stream_id TEXT PRIMARY KEY,
    manifest_json TEXT NOT NULL,
    etag INTEGER NOT NULL CHECK (etag > 0),
    fencing_token INTEGER NOT NULL CHECK (fencing_token > 0),
    updated_at TEXT NOT NULL
) STRICT;
