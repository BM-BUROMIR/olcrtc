#!/bin/sh
set -eu

usage() {
  cat >&2 <<'EOF'
Usage: ios-managed-soak.sh --device ID --output DIR [options]

Options:
  --duration-seconds N       Total wall-clock duration (default: 86400)
  --interval-seconds N       Probe cadence (default: 600)
  --profile-block-rounds N   Rounds before switching provider (default: 6)
  --probe-wait-seconds N     Wait before collecting app logs (default: 120)
EOF
  exit 2
}

device=
output=
duration=86400
interval=600
profile_block=6
probe_wait=120

while [ "$#" -gt 0 ]; do
  case "$1" in
    --device) device=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --duration-seconds) duration=$2; shift 2 ;;
    --interval-seconds) interval=$2; shift 2 ;;
    --profile-block-rounds) profile_block=$2; shift 2 ;;
    --probe-wait-seconds) probe_wait=$2; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$device" ] && [ -n "$output" ] || usage
for value in "$duration" "$interval" "$profile_block" "$probe_wait"; do
  case "$value" in *[!0-9]*|'') usage ;; esac
done
[ "$duration" -gt 0 ] && [ "$interval" -gt 0 ] && [ "$profile_block" -gt 0 ] || usage

xcrun=${OLC_XCRUN:-xcrun}
bundle_id=${OLC_IOS_BUNDLE_ID:-com.oxi717.olc}
app_group=${OLC_IOS_APP_GROUP:-group.com.oxi717.olc}

mkdir -p "$output"
chmod 700 "$output"
lock="$output/.runner-lock"
if ! mkdir "$lock" 2>/dev/null; then
  echo "soak runner is already active" >&2
  exit 1
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT HUP INT TERM

start_file="$output/start-epoch.txt"
cycle_file="$output/next-cycle.txt"
previous_profile_file="$output/previous-profile.txt"
results_file="$output/results.jsonl"

if [ ! -f "$start_file" ]; then
  date +%s >"$start_file"
  printf '0\n' >"$cycle_file"
  : >"$results_file"
fi
start_epoch=$(cat "$start_file")
cycle=$(cat "$cycle_file")

while :; do
  now=$(date +%s)
  elapsed=$((now - start_epoch))
  [ "$elapsed" -lt "$duration" ] || break

  block=$((cycle / profile_block))
  if [ $((block % 2)) -eq 0 ]; then profile=telemost; else profile=wb; fi
  previous_profile=
  [ -f "$previous_profile_file" ] && previous_profile=$(cat "$previous_profile_file")
  force_connect=false
  [ "$cycle" -eq 0 ] && force_connect=true
  [ -n "$previous_profile" ] && [ "$previous_profile" != "$profile" ] && force_connect=true

  iteration=$(printf '%06d-%s' "$cycle" "$profile")
  iteration_dir="$output/$iteration"
  mkdir -p "$iteration_dir/app-group"
  started_epoch=$(date +%s)
  started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  log_stamp=$(date -u '+%Y-%m-%d %H:%M:%S')

  launch_status=0
  if [ "$force_connect" = true ]; then
    "$xcrun" devicectl device process launch --terminate-existing \
      --device "$device" "$bundle_id" \
      --profile-id "$profile" --connect-on-launch \
      --probe-rounds 1 --probe-download-bytes 1048576 \
      --json-output "$iteration_dir/launch.json" \
      >"$iteration_dir/launch.log" 2>&1 || launch_status=$?
  else
    "$xcrun" devicectl device process launch --terminate-existing \
      --device "$device" "$bundle_id" \
      --profile-id "$profile" \
      --probe-rounds 1 --probe-download-bytes 1048576 \
      --json-output "$iteration_dir/launch.json" \
      >"$iteration_dir/launch.log" 2>&1 || launch_status=$?
  fi

  [ "$probe_wait" -eq 0 ] || sleep "$probe_wait"
  copy_status=0
  "$xcrun" devicectl device copy from \
    --device "$device" \
    --domain-type appGroupDataContainer \
    --domain-identifier "$app_group" \
    --source olc \
    --destination "$iteration_dir/app-group" \
    --json-output "$iteration_dir/copy.json" \
    >"$iteration_dir/copy.log" 2>&1 || copy_status=$?

  app_log="$iteration_dir/app-group/app.log"
  probe_status=missing
  if [ -f "$app_log" ]; then
    awk -v stamp="$log_stamp" '$0 >= stamp' "$app_log" >"$iteration_dir/app-since-launch.log"
    if grep -F 'http probe round=1 done ok=3 fail=0' "$iteration_dir/app-since-launch.log" >/dev/null; then
      probe_status=passed
    else
      probe_status=failed
    fi
  fi

  result_status=failed
  if [ "$launch_status" -eq 0 ] && [ "$copy_status" -eq 0 ] && [ "$probe_status" = passed ]; then
    result_status=passed
  fi
  finished_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  duration_seconds=$(($(date +%s) - started_epoch))
  jq -n -c \
    --argjson cycle "$cycle" \
    --arg profile "$profile" \
    --arg status "$result_status" \
    --arg probe_status "$probe_status" \
    --arg started_at "$started_at" \
    --arg finished_at "$finished_at" \
    --argjson launch_status "$launch_status" \
    --argjson copy_status "$copy_status" \
    --argjson duration_seconds "$duration_seconds" \
    '{cycle:$cycle,profile:$profile,status:$status,probe_status:$probe_status,started_at:$started_at,finished_at:$finished_at,launch_status:$launch_status,copy_status:$copy_status,duration_seconds:$duration_seconds}' \
    >"$iteration_dir/result.json"
  cat "$iteration_dir/result.json" >>"$results_file"

  printf '%s\n' "$profile" >"$previous_profile_file"
  cycle=$((cycle + 1))
  printf '%s\n' "$cycle" >"$cycle_file"

  next_epoch=$((start_epoch + cycle * interval))
  now=$(date +%s)
  remaining=$((next_epoch - now))
  [ "$remaining" -le 0 ] || sleep "$remaining"
done

finished_epoch=$(date +%s)
passed=$(jq -s '[.[] | select(.status == "passed")] | length' "$results_file")
failed=$(jq -s '[.[] | select(.status != "passed")] | length' "$results_file")
status=passed
[ "$failed" -eq 0 ] || status=failed
jq -n \
  --arg status "$status" \
  --arg started_at "$(date -u -r "$start_epoch" '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg finished_at "$(date -u -r "$finished_epoch" '+%Y-%m-%dT%H:%M:%SZ')" \
  --argjson duration_seconds "$((finished_epoch - start_epoch))" \
  --argjson passed "$passed" \
  --argjson failed "$failed" \
  --argjson rounds "$cycle" \
  '{status:$status,started_at:$started_at,finished_at:$finished_at,duration_seconds:$duration_seconds,rounds:$rounds,passed:$passed,failed:$failed}' \
  >"$output/summary.json"

[ "$failed" -eq 0 ]
