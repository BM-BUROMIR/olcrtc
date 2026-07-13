#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT=${OLC_ROOT:-/opt/olc}
STATE_DIR=${STATE_DIRECTORY:-/var/lib/olc-control-plane}
DATABASE="$STATE_DIR/control-plane.db"
BACKUP_DIR="$STATE_DIR/backups"

if [[ ! -f "$DATABASE" ]]; then
    exit 0
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
python3 "$ROOT/control-plane/backup_state.py" backup \
    --source "$DATABASE" \
    --destination "$BACKUP_DIR/control-plane-$timestamp.db"
find "$BACKUP_DIR" -type f -name 'control-plane-*.db' -mtime +14 -delete
