#!/bin/sh
set -eu

usage() {
  cat >&2 <<'EOF'
Usage: ios-managed-soak.sh --device ID --output DIR [options]

Options:
  --duration-seconds N       Total wall-clock duration (default: 86400)
  --interval-seconds N       Probe cadence (default: 600)
  --profile-block-rounds N   Rounds before switching provider (default: 6)
  --connect-wait-seconds N   Wait after a provider switch (default: 15)
  --probe-wait-seconds N     Wait after browser traffic (default: 30)
EOF
  exit 2
}

device=
output=
duration=86400
interval=600
profile_block=6
connect_wait=15
probe_wait=30

while [ "$#" -gt 0 ]; do
  case "$1" in
    --device) device=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --duration-seconds) duration=$2; shift 2 ;;
    --interval-seconds) interval=$2; shift 2 ;;
    --profile-block-rounds) profile_block=$2; shift 2 ;;
    --connect-wait-seconds) connect_wait=$2; shift 2 ;;
    --probe-wait-seconds) probe_wait=$2; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$device" ] && [ -n "$output" ] || usage
for value in "$duration" "$interval" "$profile_block" "$connect_wait" "$probe_wait"; do
  case "$value" in *[!0-9]*|'') usage ;; esac
done
[ "$duration" -gt 0 ] && [ "$interval" -gt 0 ] && [ "$profile_block" -gt 0 ] || usage

xcrun=${OLC_XCRUN:-xcrun}
bundle_id=${OLC_IOS_BUNDLE_ID:-com.oxi717.olc}
app_group=${OLC_IOS_APP_GROUP:-group.com.oxi717.olc}
happ_bundle_id=${OLC_HAPP_BUNDLE_ID:-su.ffg.happ.plus}

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
events_file="$output/harness-events.jsonl"

if [ ! -f "$start_file" ]; then
  date +%s >"$start_file"
  printf '0\n' >"$cycle_file"
  : >"$results_file"
fi
start_epoch=$(cat "$start_file")
cycle=$(cat "$cycle_file")
touch "$results_file" "$events_file"

snapshot_happ() {
  label=$1
  json="$output/happ-$label.json"
  log="$output/happ-$label.log"
  status=0
  "$xcrun" devicectl device info apps \
    --device "$device" \
    --include-all-apps \
    --bundle-id "$happ_bundle_id" \
    --timeout 30 \
    --json-output "$json" >"$log" 2>&1 || status=$?
  if [ "$status" -ne 0 ] ||
     ! jq -e --arg bundle "$happ_bundle_id" \
       '.result.apps | length == 1 and .[0].bundleIdentifier == $bundle' "$json" >/dev/null 2>&1; then
    return 1
  fi
  jq -S '.result.apps[0] | {bundleIdentifier,name,version,bundleVersion}' "$json"
}

now=$(date +%s)
expected_epoch=$((start_epoch + cycle * interval))
if [ "$cycle" -gt 0 ] && [ "$now" -gt $((expected_epoch + interval)) ]; then
  pause_seconds=$((now - expected_epoch))
  start_epoch=$((start_epoch + pause_seconds))
  printf '%s\n' "$start_epoch" >"$start_file"
  jq -n -c \
    --arg type resume \
    --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson cycle "$cycle" \
    --argjson pause_seconds "$pause_seconds" \
    '{type:$type,at:$at,cycle:$cycle,pause_seconds:$pause_seconds}' \
    >>"$events_file"
fi

record_device_locked() {
  phase=$1
  event_file=$2
  jq -n -c \
    --arg type blocked \
    --arg reason device_locked \
    --arg phase "$phase" \
    --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson cycle "$cycle" \
    '{type:$type,reason:$reason,phase:$phase,at:$at,cycle:$cycle}' \
    >"$event_file"
  cat "$event_file" >>"$events_file"
  exit 75
}

is_device_locked() {
  grep -E 'has not been unlocked recently|CoreDevice error 10003|RemotePairing.*1016' "$1" >/dev/null 2>&1
}

if [ ! -f "$output/happ-before.snapshot.json" ]; then
  if ! snapshot_happ before >"$output/happ-before.snapshot.json"; then
    if is_device_locked "$output/happ-before.log"; then
      record_device_locked happ-snapshot "$output/harness-event.json"
    fi
    echo "unable to obtain the required read-only Happ Plus snapshot" >&2
    exit 1
  fi
fi

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
  mkdir -p "$iteration_dir"
  started_epoch=$(date +%s)
  started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  log_stamp=$(date -u '+%Y-%m-%d %H:%M:%S')

  launch_status=0
  if [ "$force_connect" = true ]; then
    environment=$(printf '{"OLC_TEST_PROFILE_ID":"%s","OLC_TEST_CONNECT_ON_LAUNCH":"1"}' "$profile")
    "$xcrun" devicectl device process launch --terminate-existing \
      --device "$device" \
      --environment-variables "$environment" \
      --timeout 90 \
      --json-output "$iteration_dir/launch.json" \
      "$bundle_id" >"$iteration_dir/launch.log" 2>&1 || launch_status=$?
  else
    "$xcrun" devicectl device process launch --terminate-existing \
      --device "$device" \
      --timeout 90 \
      --json-output "$iteration_dir/launch.json" \
      "$bundle_id" >"$iteration_dir/launch.log" 2>&1 || launch_status=$?
  fi
  if [ "$launch_status" -ne 0 ] && is_device_locked "$iteration_dir/launch.log"; then
    record_device_locked launch "$iteration_dir/harness-event.json"
  fi

  if [ "$force_connect" = true ] && [ "$connect_wait" -gt 0 ]; then
    sleep "$connect_wait"
  fi

  baseline_copy_status=0
  "$xcrun" devicectl device copy from \
    --device "$device" \
    --domain-type appGroupDataContainer \
    --domain-identifier "$app_group" \
    --source olc/tunnel.log \
    --destination "$iteration_dir/tunnel-before-probe.log" \
    --timeout 90 \
    --json-output "$iteration_dir/baseline-copy.json" \
    >"$iteration_dir/baseline-copy.log" 2>&1 || baseline_copy_status=$?
  if [ "$baseline_copy_status" -ne 0 ] && is_device_locked "$iteration_dir/baseline-copy.log"; then
    record_device_locked baseline-copy "$iteration_dir/harness-event.json"
  fi
  baseline_rx=0
  if [ -f "$iteration_dir/tunnel-before-probe.log" ]; then
    candidate_rx=$(sed -n 's/.*rx_bytes=\([0-9][0-9]*\).*/\1/p' \
      "$iteration_dir/tunnel-before-probe.log" | tail -1)
    [ -z "$candidate_rx" ] || baseline_rx=$candidate_rx
  fi

  browser_status=0
  probe_url="https://api.ipify.org/?olc-soak-cycle=$cycle"
  "$xcrun" devicectl device process launch --terminate-existing \
    --device "$device" \
    --payload-url "$probe_url" \
    --timeout 90 \
    --json-output "$iteration_dir/browser.json" \
    com.apple.mobilesafari >"$iteration_dir/browser.log" 2>&1 || browser_status=$?
  if [ "$browser_status" -ne 0 ] && is_device_locked "$iteration_dir/browser.log"; then
    record_device_locked browser "$iteration_dir/harness-event.json"
  fi

  [ "$probe_wait" -eq 0 ] || sleep "$probe_wait"
  copy_status=0
  "$xcrun" devicectl device copy from \
    --device "$device" \
    --domain-type appGroupDataContainer \
    --domain-identifier "$app_group" \
    --source olc/tunnel.log \
    --destination "$iteration_dir/tunnel.log" \
    --timeout 90 \
    --json-output "$iteration_dir/copy.json" \
    >"$iteration_dir/copy.log" 2>&1 || copy_status=$?
  if [ "$copy_status" -ne 0 ] && is_device_locked "$iteration_dir/copy.log"; then
    record_device_locked copy "$iteration_dir/harness-event.json"
  fi

  tunnel_log="$iteration_dir/tunnel.log"
  profile_status=missing
  session_status=missing
  traffic_status=missing
  latest_rx=0
  if [ -f "$tunnel_log" ]; then
    awk -v stamp="$log_stamp" '$0 >= stamp' "$tunnel_log" >"$iteration_dir/tunnel-since-launch.log"
    latest_profile=$(sed -n 's/.*managed bootstrap ready profile=\([^ ]*\).*/\1/p' "$tunnel_log" | tail -1)
    [ "$latest_profile" = "$profile" ] && profile_status=passed || profile_status=failed
    session_log="$iteration_dir/tunnel-since-launch.log"
    [ "$force_connect" = false ] && session_log="$tunnel_log"
    if grep -F 'cnc session ready' "$session_log" >/dev/null &&
       grep -F '=== startTunnel done ===' "$session_log" >/dev/null; then
      session_status=passed
    else
      session_status=failed
    fi
    latest_rx=$(sed -n 's/.*rx_bytes=\([0-9][0-9]*\).*/\1/p' "$iteration_dir/tunnel-since-launch.log" | tail -1)
    if [ -n "$latest_rx" ] && [ "$latest_rx" -gt "$baseline_rx" ]; then
      traffic_status=passed
    else
      traffic_status=failed
    fi
  fi

  result_status=failed
  if [ "$launch_status" -eq 0 ] && [ "$baseline_copy_status" -eq 0 ] &&
     [ "$browser_status" -eq 0 ] &&
     [ "$copy_status" -eq 0 ] && [ "$profile_status" = passed ] &&
     [ "$session_status" = passed ] && [ "$traffic_status" = passed ]; then
    result_status=passed
  fi
  finished_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  duration_seconds=$(($(date +%s) - started_epoch))
  jq -n -c \
    --argjson cycle "$cycle" \
    --arg profile "$profile" \
    --arg status "$result_status" \
    --arg profile_status "$profile_status" \
    --arg session_status "$session_status" \
    --arg traffic_status "$traffic_status" \
    --arg started_at "$started_at" \
    --arg finished_at "$finished_at" \
    --argjson launch_status "$launch_status" \
    --argjson baseline_copy_status "$baseline_copy_status" \
    --argjson browser_status "$browser_status" \
    --argjson copy_status "$copy_status" \
    --argjson baseline_rx "$baseline_rx" \
    --argjson latest_rx "$latest_rx" \
    --argjson duration_seconds "$duration_seconds" \
    '{cycle:$cycle,profile:$profile,status:$status,profile_status:$profile_status,session_status:$session_status,traffic_status:$traffic_status,started_at:$started_at,finished_at:$finished_at,launch_status:$launch_status,baseline_copy_status:$baseline_copy_status,browser_status:$browser_status,copy_status:$copy_status,baseline_rx:$baseline_rx,latest_rx:$latest_rx,duration_seconds:$duration_seconds}' \
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
if ! snapshot_happ after >"$output/happ-after.snapshot.json"; then
  echo "unable to obtain the final read-only Happ Plus snapshot" >&2
  exit 1
fi
happ_unchanged=false
if cmp -s "$output/happ-before.snapshot.json" "$output/happ-after.snapshot.json"; then
  happ_unchanged=true
fi
passed=$(jq -s '[.[] | select(.status == "passed")] | length' "$results_file")
failed=$(jq -s '[.[] | select(.status != "passed")] | length' "$results_file")
status=passed
[ "$failed" -eq 0 ] || status=failed
[ "$happ_unchanged" = true ] || status=failed
jq -n \
  --arg status "$status" \
  --arg started_at "$(date -u -r "$start_epoch" '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg finished_at "$(date -u -r "$finished_epoch" '+%Y-%m-%dT%H:%M:%SZ')" \
  --argjson duration_seconds "$((finished_epoch - start_epoch))" \
  --argjson passed "$passed" \
  --argjson failed "$failed" \
  --argjson rounds "$cycle" \
  --argjson happ_unchanged "$happ_unchanged" \
  '{status:$status,started_at:$started_at,finished_at:$finished_at,duration_seconds:$duration_seconds,rounds:$rounds,passed:$passed,failed:$failed,happ_unchanged:$happ_unchanged}' \
  >"$output/summary.json"

[ "$failed" -eq 0 ] && [ "$happ_unchanged" = true ]
