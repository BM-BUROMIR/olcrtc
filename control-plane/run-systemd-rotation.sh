#!/usr/bin/env bash
set -euo pipefail

: "${CREDENTIALS_DIRECTORY:?systemd credential directory is required}"

ROOT=${OLC_ROOT:-/opt/olc}
CONFIG=${OLC_ROTATION_CONFIG:-/etc/olc-control-plane/managed-rotation.json}

set -a
# shellcheck disable=SC1090
source "$CREDENTIALS_DIRECTORY/rotation.env"
set +a

export OLC_SSH_KEY_PATH="$CREDENTIALS_DIRECTORY/ssh_key"
export OLC_TELEMOST_COOKIES_PATH="$CREDENTIALS_DIRECTORY/telemost.cookies"
export OLC_SSH_KNOWN_HOSTS_PATH="$CREDENTIALS_DIRECTORY/known_hosts"
export OLC_DEPLOYMENT_PATH="$CREDENTIALS_DIRECTORY/deployment.json"
export OLC_SERVER_BASE_CONFIG="$CREDENTIALS_DIRECTORY/server-base.yaml"
export PYTHONPATH="$ROOT/control-plane"

exec python3 "$ROOT/control-plane/managed_rotation.py" --config "$CONFIG"
