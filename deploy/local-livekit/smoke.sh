#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

RUN_DIR="deploy/local-livekit/run"
LOG_DIR="$RUN_DIR/logs"
SOCKS_ADDR="${SOCKS_ADDR:-127.0.0.1:8808}"
HTTP_URL="${HTTP_URL:-http://http:8080/}"
COMPOSE=(docker compose -f deploy/local-livekit/compose.yaml --profile stand)

mkdir -p "$LOG_DIR"
: >"$LOG_DIR/livekit.log"
: >"$LOG_DIR/srv.log"
: >"$LOG_DIR/cnc.log"
go run ./deploy/local-livekit/gen-configs.go "$RUN_DIR"
DOCKER_ARCH="$(docker info --format '{{.Architecture}}')"
case "$DOCKER_ARCH" in
  x86_64|amd64) GOARCH_VALUE=amd64 ;;
  aarch64|arm64) GOARCH_VALUE=arm64 ;;
  *) echo "unsupported Docker architecture: $DOCKER_ARCH" >&2; exit 1 ;;
esac
CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH_VALUE" go build -trimpath -o "$RUN_DIR/olcrtc-linux" ./cmd/olcrtc
CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH_VALUE" go build -trimpath -o "$RUN_DIR/local-livekit-helper-linux" ./deploy/local-livekit
docker build -f deploy/local-livekit/Dockerfile -t olcrtc-local-livekit:dev .

cleanup() {
  set +e
  "${COMPOSE[@]}" down >/dev/null 2>&1
}
trap cleanup EXIT

"${COMPOSE[@]}" up -d --force-recreate livekit http srv cnc

wait_log() {
  local name="$1"
  local needle="$2"
  local file="$LOG_DIR/$name.log"
  local deadline=$((SECONDS + 75))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if grep -q "$needle" "$file"; then
      return 0
    fi
    sleep 1
  done
  "${COMPOSE[@]}" logs --no-color livekit >"$LOG_DIR/livekit.log" 2>&1 || true
  echo "missing '$needle' in $name logs" >&2
  for log_name in livekit srv cnc; do
    echo "----- $log_name logs -----" >&2
    tail -80 "$LOG_DIR/$log_name.log" >&2 || true
  done
  return 1
}

wait_log cnc "SOCKS5 server listening"
wait_log cnc "peer latched"
wait_log srv "peer latched"

HTTP_STATUS="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --max-time 20 --socks5-hostname "$SOCKS_ADDR" "$HTTP_URL")"

if [ "$HTTP_STATUS" != "200" ]; then
  echo "HTTP_STATUS=$HTTP_STATUS, want 200" >&2
  exit 1
fi

echo "vp8channel SOCKS probe returned HTTP_STATUS=200"
