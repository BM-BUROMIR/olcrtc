#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repo_root=$(dirname "$script_dir")
fixture_root=${OLC_TEST_TMPDIR:-$repo_root/build/local-check/tmp}
mkdir -p "$fixture_root"
fixture=$(mktemp -d "$fixture_root/olc-ios-post-update-test.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM

cat >"$fixture/xcrun" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$OLC_FAKE_COMMANDS"

destination=
json_output=
command=$*
while [ "$#" -gt 0 ]; do
  case "$1" in
    --destination) destination=$2; shift 2 ;;
    --json-output) json_output=$2; shift 2 ;;
    *) shift ;;
  esac
done

if [ -n "$json_output" ]; then
  mkdir -p "$(dirname "$json_output")"
  if printf '%s' "$command" | grep -F 'device info apps' >/dev/null; then
    jq -n --arg build "$OLC_FAKE_BUILD" \
      '{result:{apps:[{bundleIdentifier:"com.oxi717.olc",bundleVersion:$build}]}}' >"$json_output"
  else
    printf '{}\n' >"$json_output"
  fi
fi

profile=$(printf '%s' "$command" | sed -n 's/.*--profile-id \([^ ]*\).*/\1/p')
if [ -n "$profile" ]; then
  printf '%s\n' "$profile" >"$OLC_FAKE_PROFILE"
fi

if [ -n "$destination" ]; then
  mkdir -p "$destination/bootstrap"
  stamp=$(date -u '+%Y-%m-%d %H:%M:%S')
  profile=$(cat "$OLC_FAKE_PROFILE")
  {
    printf '%s +0000 profile override id=%s\n' "$stamp" "$profile"
    printf '%s +0000 http probe vpn ready status=NEVPNStatus(rawValue: 3)\n' "$stamp"
    printf '%s +0000 http probe round=1 done ok=3 fail=0\n' "$stamp"
  } >"$destination/app.log"
  printf '{"profile_id":"telemost","generation":8,"expires_at":"2099-01-01T00:00:00Z"}\n' >"$destination/bootstrap/telemost.json"
  printf '{"profile_id":"wb","generation":3,"expires_at":"2099-01-01T00:00:00Z"}\n' >"$destination/bootstrap/wb.json"
fi
SH
chmod +x "$fixture/xcrun"

export OLC_XCRUN="$fixture/xcrun"
export OLC_FAKE_COMMANDS="$fixture/commands.log"
export OLC_FAKE_PROFILE="$fixture/profile.txt"
export OLC_FAKE_BUILD=202607131956

if ! "$repo_root/script/ios-post-update-acceptance.sh" \
  --device test-device \
  --expected-build 202607131956 \
  --output "$fixture/pass" \
  --probe-wait-seconds 0; then
  find "$fixture/pass" -name result.json -exec jq -c . {} \; >&2
  exit 1
fi

jq -e '
  .status == "passed" and
  .installed_build == "202607131956" and
  .profiles.telemost.status == "passed" and
  .profiles.wb.status == "passed" and
  .profiles.telemost.generation == 8 and
  .profiles.wb.generation == 3
' "$fixture/pass/summary.json" >/dev/null
grep -F -- 'device info apps --include-all-apps' "$fixture/commands.log" >/dev/null
[ "$(grep -c -- '--connect-on-launch' "$fixture/commands.log")" -eq 2 ]

: >"$fixture/commands.log"
if "$repo_root/script/ios-post-update-acceptance.sh" \
  --device test-device \
  --expected-build 202607131957 \
  --output "$fixture/reject" \
  --probe-wait-seconds 0; then
  echo "post-update runner accepted the wrong installed build" >&2
  exit 1
fi
if grep -F 'device process launch' "$fixture/commands.log" >/dev/null; then
  echo "post-update runner launched the app after a build mismatch" >&2
  exit 1
fi

echo "ios post-update acceptance tests passed"
