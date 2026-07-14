#!/bin/sh
set -eu

repo_root=$(git rev-parse --show-toplevel)
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

destination=
json_output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --destination) destination=$2; shift 2 ;;
    --json-output) json_output=$2; shift 2 ;;
    *) shift ;;
  esac
done

if [ -n "$json_output" ]; then
  mkdir -p "$(dirname "$json_output")"
  printf '{}\n' >"$json_output"
fi
if [ -n "$destination" ]; then
  mkdir -p "$destination"
  stamp=$(date -u '+%Y-%m-%d %H:%M:%S')
  printf '%s +0000 http probe round=1 done ok=3 fail=0\n' "$stamp" >"$destination/app.log"
fi
SH
chmod +x "$fixture/xcrun"

export OLC_XCRUN="$fixture/xcrun"
export OLC_FAKE_COMMANDS="$fixture/commands.log"
output="$fixture/output"

"$repo_root/script/ios-managed-soak.sh" \
  --device test-device \
  --output "$output" \
  --duration-seconds 2 \
  --interval-seconds 1 \
  --profile-block-rounds 1 \
  --probe-wait-seconds 0

jq -e '.status == "passed" and .failed == 0 and .passed >= 2' "$output/summary.json" >/dev/null
grep -F -- '--profile-id telemost' "$fixture/commands.log" >/dev/null
grep -F -- '--profile-id wb' "$fixture/commands.log" >/dev/null
[ "$(grep -c -- '--connect-on-launch' "$fixture/commands.log")" -ge 2 ]

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
  --probe-wait-seconds 0

jq -e '.rounds >= 3 and .failed == 0' "$paused_output/summary.json" >/dev/null
[ "$(grep -c -- 'device process launch' "$fixture/commands.log")" -ge 2 ]
jq -e 'select(.type == "resume" and .pause_seconds >= 90)' \
  "$paused_output/harness-events.jsonl" >/dev/null

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
  --probe-wait-seconds 0 || locked_status=$?
unset OLC_FAKE_MODE

[ "$locked_status" -eq 75 ]
[ ! -s "$locked_output/results.jsonl" ]
[ "$(cat "$locked_output/next-cycle.txt")" -eq 0 ]
jq -e 'select(.type == "blocked" and .reason == "device_locked" and .cycle == 0)' \
  "$locked_output/harness-events.jsonl" >/dev/null

echo "ios managed soak tests passed"
