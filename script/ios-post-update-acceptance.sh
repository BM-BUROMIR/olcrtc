#!/bin/sh
set -eu

usage() {
  cat >&2 <<'EOF'
Usage: ios-post-update-acceptance.sh --device ID --expected-build BUILD --output DIR [options]

Options:
  --probe-wait-seconds N  Wait before collecting device logs (default: 120)
EOF
  exit 2
}

device=
expected_build=
output=
probe_wait=120

while [ "$#" -gt 0 ]; do
  case "$1" in
    --device) device=$2; shift 2 ;;
    --expected-build) expected_build=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --probe-wait-seconds) probe_wait=$2; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$device" ] && [ -n "$expected_build" ] && [ -n "$output" ] || usage
case "$probe_wait" in *[!0-9]*|'') usage ;; esac
if [ -e "$output" ]; then
  echo "output already exists: $output" >&2
  exit 1
fi

xcrun=${OLC_XCRUN:-xcrun}
bundle_id=${OLC_IOS_BUNDLE_ID:-com.oxi717.olc}
app_group=${OLC_IOS_APP_GROUP:-group.com.oxi717.olc}

mkdir -p "$output"
chmod 700 "$output"

"$xcrun" devicectl device info apps \
  --include-all-apps \
  --device "$device" \
  --bundle-id "$bundle_id" \
  --json-output "$output/apps.json" \
  >"$output/apps.log" 2>&1

installed_build=$(jq -r --arg bundle "$bundle_id" '
  [.result.apps[]? | select(.bundleIdentifier == $bundle)][0].bundleVersion // empty
' "$output/apps.json")
if [ -z "$installed_build" ]; then
  echo "installed app not found: $bundle_id" >&2
  exit 1
fi
if [ "$installed_build" != "$expected_build" ]; then
  echo "installed build $installed_build does not match expected build $expected_build" >&2
  exit 1
fi

run_profile() {
  profile=$1
  profile_dir="$output/$profile"
  mkdir -p "$profile_dir/app-group"
  stamp=$(date -u '+%Y-%m-%d %H:%M:%S')
  started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  launch_status=0
  "$xcrun" devicectl device process launch --terminate-existing \
    --device "$device" "$bundle_id" \
    --profile-id "$profile" --connect-on-launch \
    --probe-rounds 1 --probe-download-bytes 1048576 \
    --json-output "$profile_dir/launch.json" \
    >"$profile_dir/launch.log" 2>&1 || launch_status=$?

  [ "$probe_wait" -eq 0 ] || sleep "$probe_wait"
  copy_status=0
  "$xcrun" devicectl device copy from \
    --device "$device" \
    --domain-type appGroupDataContainer \
    --domain-identifier "$app_group" \
    --source olc \
    --destination "$profile_dir/app-group" \
    --json-output "$profile_dir/copy.json" \
    >"$profile_dir/copy.log" 2>&1 || copy_status=$?

  app_log="$profile_dir/app-group/app.log"
  log_status=missing
  if [ -f "$app_log" ]; then
    awk -v since="$stamp" '$0 >= since' "$app_log" >"$profile_dir/app-since-launch.log"
    if grep -F "profile override id=$profile" "$profile_dir/app-since-launch.log" >/dev/null &&
       grep -F 'http probe vpn ready status=NEVPNStatus(rawValue: 3)' "$profile_dir/app-since-launch.log" >/dev/null &&
       grep -F 'http probe round=1 done ok=3 fail=0' "$profile_dir/app-since-launch.log" >/dev/null; then
      log_status=passed
    else
      log_status=failed
    fi
  fi

  cache_status=passed
  for cached_profile in telemost wb; do
    cache="$profile_dir/app-group/bootstrap/$cached_profile.json"
    if ! jq -e --arg profile "$cached_profile" '
      .profile_id == $profile and
      (.generation | type == "number" and . > 0) and
      (.expires_at | fromdateiso8601 > now)
    ' "$cache" >/dev/null 2>&1; then
      cache_status=failed
    fi
  done

  generation=0
  cache="$profile_dir/app-group/bootstrap/$profile.json"
  if [ -f "$cache" ]; then
    generation=$(jq -r '.generation // 0' "$cache")
  fi
  profile_status=failed
  if [ "$launch_status" -eq 0 ] && [ "$copy_status" -eq 0 ] &&
     [ "$log_status" = passed ] && [ "$cache_status" = passed ]; then
    profile_status=passed
  fi

  jq -n \
    --arg profile "$profile" \
    --arg status "$profile_status" \
    --arg log_status "$log_status" \
    --arg cache_status "$cache_status" \
    --arg started_at "$started_at" \
    --arg finished_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson generation "$generation" \
    --argjson launch_status "$launch_status" \
    --argjson copy_status "$copy_status" \
    '{profile:$profile,status:$status,log_status:$log_status,cache_status:$cache_status,generation:$generation,started_at:$started_at,finished_at:$finished_at,launch_status:$launch_status,copy_status:$copy_status}' \
    >"$profile_dir/result.json"

  [ "$profile_status" = passed ]
}

failed=0
run_profile telemost || failed=1
run_profile wb || failed=1

status=passed
[ "$failed" -eq 0 ] || status=failed
jq -n \
  --arg status "$status" \
  --arg installed_build "$installed_build" \
  --slurpfile telemost "$output/telemost/result.json" \
  --slurpfile wb "$output/wb/result.json" \
  '{status:$status,installed_build:$installed_build,profiles:{telemost:$telemost[0],wb:$wb[0]}}' \
  >"$output/summary.json"

[ "$status" = passed ]
