#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repo_root=$(dirname "$script_dir")
fixture=$(mktemp -d "${TMPDIR:-/tmp}/olc-ios-soak-test.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM

cat >"$fixture/xcrun" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$OLC_FAKE_COMMANDS"

if [ "${OLC_FAKE_MODE:-ok}" = locked ]; then
  echo 'The device has not been unlocked recently (CoreDevice error 10003)' >&2
  exit 1
fi

case " $* " in
  *' device info apps '*) is_apps=true ;;
  *) is_apps=false ;;
esac

destination=
json_output=
profile=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --destination) destination=$2; shift 2 ;;
    --json-output) json_output=$2; shift 2 ;;
    --environment-variables)
      profile=$(printf '%s' "$2" | jq -r '.OLC_TEST_PROFILE_ID // empty')
      shift 2
      ;;
    *) shift ;;
  esac
done

if [ -n "$profile" ]; then
  printf '%s\n' "$profile" >"$OLC_FAKE_PROFILE"
  stamp=$(date -u '+%Y-%m-%d %H:%M:%S')
  cat >>"$OLC_FAKE_TUNNEL" <<EOF
$stamp +0000 === startTunnel ===
$stamp +0000 managed bootstrap ready profile=$profile generation=1
$stamp +0000 cnc session ready
$stamp +0000 === startTunnel done ===
EOF
fi

if [ -n "$json_output" ]; then
  mkdir -p "$(dirname "$json_output")"
  if [ "$is_apps" = true ]; then
    cat >"$json_output" <<'EOF'
{"result":{"apps":[{"name":"Happ Plus","bundleIdentifier":"su.ffg.happ.plus","version":"4.12.0","bundleVersion":"2606121423"}]}}
EOF
  else
    printf '{}\n' >"$json_output"
  fi
fi
if [ -n "$destination" ]; then
  mkdir -p "$(dirname "$destination")"
  stamp=$(date -u '+%Y-%m-%d %H:%M:%S')
  rx=$(cat "$OLC_FAKE_RX" 2>/dev/null || printf 0)
  if [ "${OLC_FAKE_MODE:-ok}" != stale ] || [ "$rx" -eq 0 ]; then
    rx=$((rx + 8192))
  fi
  printf '%s\n' "$rx" >"$OLC_FAKE_RX"
  cat >>"$OLC_FAKE_TUNNEL" <<EOF
$stamp +0000 tun2socks stats tx_packets=10 tx_bytes=4096 rx_packets=10 rx_bytes=$rx
EOF
  cp "$OLC_FAKE_TUNNEL" "$destination"
fi
SH
chmod +x "$fixture/xcrun"

export OLC_XCRUN="$fixture/xcrun"
export OLC_FAKE_COMMANDS="$fixture/commands.log"
export OLC_FAKE_PROFILE="$fixture/profile.txt"
export OLC_FAKE_TUNNEL="$fixture/tunnel.log"
export OLC_FAKE_RX="$fixture/rx.txt"
: >"$OLC_FAKE_TUNNEL"
output="$fixture/output"

"$repo_root/script/ios-managed-soak.sh" \
  --device test-device \
  --output "$output" \
  --duration-seconds 5 \
  --interval-seconds 2 \
  --profile-block-rounds 2 \
  --connect-wait-seconds 0 \
  --probe-wait-seconds 0

jq -e '.status == "passed" and .failed == 0 and .passed >= 2' "$output/summary.json" >/dev/null
jq -e 'select(.profile_status == "passed" and .session_status == "passed" and .traffic_status == "passed")' \
  "$output/results.jsonl" >/dev/null
grep -F -- '--environment-variables {"OLC_TEST_PROFILE_ID":"telemost","OLC_TEST_CONNECT_ON_LAUNCH":"1"}' "$fixture/commands.log" >/dev/null
grep -F -- '--environment-variables {"OLC_TEST_PROFILE_ID":"wb","OLC_TEST_CONNECT_ON_LAUNCH":"1"}' "$fixture/commands.log" >/dev/null
grep -F -- '--payload-url https://api.ipify.org/?olc-soak-cycle=' "$fixture/commands.log" >/dev/null
grep -F -- 'device info apps' "$fixture/commands.log" >/dev/null
grep -F -- '--bundle-id su.ffg.happ.plus' "$fixture/commands.log" >/dev/null
grep -F -- '--source olc/tunnel.log' "$fixture/commands.log" >/dev/null
if grep -F -- '--source olc ' "$fixture/commands.log" >/dev/null; then
  echo "the soak must not copy the complete sensitive app group" >&2
  exit 1
fi
if grep -F -- '--profile-id' "$fixture/commands.log" >/dev/null; then
  echo "legacy OLC app arguments must not be used" >&2
  exit 1
fi

paused_output="$fixture/paused-output"
mkdir -p "$paused_output"
printf '%s\n' "$(($(date +%s) - 100))" >"$paused_output/start-epoch.txt"
printf '1\n' >"$paused_output/next-cycle.txt"
printf 'telemost\n' >"$paused_output/previous-profile.txt"
: >"$paused_output/results.jsonl"
: >"$fixture/commands.log"

"$repo_root/script/ios-managed-soak.sh" \
  --device test-device \
  --output "$paused_output" \
  --duration-seconds 3 \
  --interval-seconds 1 \
  --profile-block-rounds 1 \
  --connect-wait-seconds 0 \
  --probe-wait-seconds 0

jq -e '.rounds >= 3 and .failed == 0' "$paused_output/summary.json" >/dev/null
[ "$(grep -c -- 'device process launch' "$fixture/commands.log")" -ge 2 ]
jq -e 'select(.type == "resume" and .pause_seconds >= 90)' \
  "$paused_output/harness-events.jsonl" >/dev/null

stale_output="$fixture/stale-output"
: >"$fixture/commands.log"
: >"$OLC_FAKE_TUNNEL"
rm -f "$OLC_FAKE_RX"
export OLC_FAKE_MODE=stale
stale_status=0
"$repo_root/script/ios-managed-soak.sh" \
  --device test-device \
  --output "$stale_output" \
  --duration-seconds 1 \
  --interval-seconds 1 \
  --profile-block-rounds 1 \
  --connect-wait-seconds 0 \
  --probe-wait-seconds 0 || stale_status=$?
unset OLC_FAKE_MODE

[ "$stale_status" -ne 0 ]
jq -e 'select(.traffic_status == "failed")' "$stale_output/results.jsonl" >/dev/null

locked_output="$fixture/locked-output"
: >"$fixture/commands.log"
export OLC_FAKE_MODE=locked
locked_status=0
"$repo_root/script/ios-managed-soak.sh" \
  --device test-device \
  --output "$locked_output" \
  --duration-seconds 2 \
  --interval-seconds 1 \
  --profile-block-rounds 1 \
  --connect-wait-seconds 0 \
  --probe-wait-seconds 0 || locked_status=$?
unset OLC_FAKE_MODE

[ "$locked_status" -eq 75 ]
[ ! -s "$locked_output/results.jsonl" ]
[ "$(cat "$locked_output/next-cycle.txt")" -eq 0 ]
jq -e 'select(.type == "blocked" and .reason == "device_locked" and .cycle == 0)' \
  "$locked_output/harness-events.jsonl" >/dev/null

echo "ios managed soak tests passed"
