#!/usr/bin/env bash
set -euo pipefail

: "${CREDENTIALS_DIRECTORY:?systemd credential directory is required}"

ROOT=${OLC_ROOT:-/opt/olc}
WB_CONFIG=${OLC_WB_ROTATION_CONFIG:-"$CREDENTIALS_DIRECTORY/managed-wb-rotation.json"}

set -a
# shellcheck disable=SC1090
source "$CREDENTIALS_DIRECTORY/rotation.env"
set +a

export OLC_SSH_KEY_PATH="$CREDENTIALS_DIRECTORY/ssh_key"
export OLC_SSH_KNOWN_HOSTS_PATH="$CREDENTIALS_DIRECTORY/known_hosts"
export OLC_WB_BEARER_PATH="$CREDENTIALS_DIRECTORY/wb.bearer"
export OLC_WB_ROOM_PATH="$CREDENTIALS_DIRECTORY/wb.room"
export OLC_WB_SERVER_BASE_CONFIG="$CREDENTIALS_DIRECTORY/wb-server-base.yaml"
export PYTHONPATH="$ROOT/control-plane"

exec python3 "$ROOT/control-plane/managed_wb_rotation.py" --config "$WB_CONFIG" "$@"
