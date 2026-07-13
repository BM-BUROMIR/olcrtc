#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <rotation-config.json> <credentials.env>" >&2
  exit 64
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=$1
CREDENTIALS=$2

set -a
# shellcheck disable=SC1090
source "$CREDENTIALS"
set +a

export PYTHONPATH="$ROOT/control-plane"
exec "${OLC_PYTHON:-python3}" "$ROOT/control-plane/managed_rotation.py" --config "$CONFIG"
