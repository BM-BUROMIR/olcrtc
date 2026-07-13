CREATE TABLE users (
    id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('active', 'disabled'))
) STRICT;

CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    status TEXT NOT NULL CHECK (status IN ('pending', 'active', 'revoked')),
    public_key BLOB NOT NULL,
    enrolled_at TEXT,
    last_seen_at TEXT
) STRICT;

CREATE TABLE provider_identities (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    provider TEXT NOT NULL CHECK (provider IN ('telemost', 'wbstream')),
    credential_ref TEXT NOT NULL,
    credential_revision INTEGER NOT NULL DEFAULT 1 CHECK (credential_revision > 0),
    status TEXT NOT NULL CHECK (status IN ('active', 'reauth_required', 'disabled')),
    operational_health TEXT NOT NULL,
    last_validated_at TEXT,
    last_error_code TEXT,
    row_version INTEGER NOT NULL DEFAULT 1 CHECK (row_version > 0),
    UNIQUE (user_id, provider)
) STRICT;

CREATE TABLE identity_grants (
    id TEXT PRIMARY KEY,
    identity_id TEXT NOT NULL REFERENCES provider_identities(id),
    grantee_user_id TEXT NOT NULL REFERENCES users(id),
    grantee_device_id TEXT REFERENCES devices(id),
    scopes TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    revoked_at TEXT
) STRICT;

CREATE TABLE profile_assignments (
    id TEXT PRIMARY KEY,
    identity_id TEXT NOT NULL REFERENCES provider_identities(id),
    user_id TEXT NOT NULL REFERENCES users(id),
    device_id TEXT NOT NULL REFERENCES devices(id),
    provider TEXT NOT NULL CHECK (provider IN ('telemost', 'wbstream')),
    state TEXT NOT NULL CHECK (state IN ('pending', 'active', 'migrating', 'retired')),
    valid_from TEXT NOT NULL,
    valid_until TEXT,
    migration_id TEXT,
    row_version INTEGER NOT NULL DEFAULT 1 CHECK (row_version > 0),
    UNIQUE (device_id, provider, identity_id)
) STRICT;

CREATE TABLE device_endpoints (
    id TEXT PRIMARY KEY,
    assignment_id TEXT NOT NULL REFERENCES profile_assignments(id),
    provider TEXT NOT NULL CHECK (provider IN ('telemost', 'wbstream')),
    state TEXT NOT NULL CHECK (state IN ('active', 'migrating', 'retired')),
    row_version INTEGER NOT NULL DEFAULT 1 CHECK (row_version > 0)
) STRICT;

CREATE TABLE endpoint_revisions (
    id TEXT PRIMARY KEY,
    endpoint_id TEXT NOT NULL REFERENCES device_endpoints(id),
    room_ref TEXT NOT NULL,
    server_unit TEXT NOT NULL,
    channel TEXT NOT NULL,
    tunnel_credential_ref TEXT NOT NULL,
    state TEXT NOT NULL CHECK (
        state IN ('preparing', 'publish_authorized', 'active', 'draining', 'failed', 'retired')
    ),
    provider_expires_at TEXT,
    fencing_token INTEGER NOT NULL CHECK (fencing_token > 0)
) STRICT;

CREATE TABLE profile_generations (
    id TEXT PRIMARY KEY,
    revision_id TEXT NOT NULL REFERENCES endpoint_revisions(id),
    endpoint_id TEXT NOT NULL REFERENCES device_endpoints(id),
    epoch INTEGER NOT NULL CHECK (epoch > 0),
    generation INTEGER NOT NULL CHECK (generation > 0),
    object_key TEXT NOT NULL UNIQUE,
    content_hash TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('preparing', 'active', 'draining', 'failed', 'retired')),
    issued_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    acknowledged_at TEXT,
    UNIQUE (endpoint_id, epoch, generation)
) STRICT;

CREATE TABLE leases (
    resource_type TEXT NOT NULL,
    resource_id TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    fencing_token INTEGER NOT NULL CHECK (fencing_token > 0),
    PRIMARY KEY (resource_type, resource_id)
) STRICT;

CREATE TABLE operations (
    id TEXT PRIMARY KEY,
    endpoint_id TEXT NOT NULL REFERENCES device_endpoints(id),
    revision_id TEXT REFERENCES endpoint_revisions(id),
    phase TEXT NOT NULL,
    expected_etag TEXT,
    resulting_etag TEXT,
    content_hash TEXT,
    fencing_token INTEGER NOT NULL CHECK (fencing_token > 0),
    last_error_code TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
) STRICT;
