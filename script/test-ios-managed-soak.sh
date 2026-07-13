#!/bin/sh
set -eu

repo_root=$(git rev-parse --show-toplevel)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/olc-ios-soak-test.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM

cat >"$fixture/xcrun" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$OLC_FAKE_COMMANDS"

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

echo "ios managed soak tests passed"
