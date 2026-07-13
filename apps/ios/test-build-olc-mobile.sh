#!/bin/sh
set -eu

repo_root=$(git rev-parse --show-toplevel)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/olc-mobile-build-test.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM

mkdir -p "$fixture/repo/apps/ios" "$fixture/repo/mobile/olcmobile" "$fixture/bin"
cp "$repo_root/apps/ios/build-olc-mobile.sh" "$fixture/repo/apps/ios/build-olc-mobile.sh"

cat >"$fixture/bin/gomobile" <<'SH'
#!/bin/sh
set -eu

args=" $* "
case "$args" in
  *" -ldflags=-s -w -X runtime.modinfo=olc-reproducible-build "*) ;;
  *) echo "gomobile linker flags do not remove module build info" >&2; exit 1 ;;
esac

output=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    output=$2
    break
  fi
  shift
done
[ -n "$output" ] || exit 1
mkdir -p \
  "$output/ios-arm64/OlcMobile.framework" \
  "$output/ios-arm64_x86_64-simulator/OlcMobile.framework"
printf 'sanitized fixture' >"$output/ios-arm64/OlcMobile.framework/OlcMobile"
printf 'sanitized fixture' >"$output/ios-arm64_x86_64-simulator/OlcMobile.framework/OlcMobile"
SH
chmod +x "$fixture/bin/gomobile"

HOME="$fixture/home" \
PATH="$fixture/bin:$PATH" \
OLC_MOBILE_BUILD_ROOT="$fixture/build-root" \
  "$fixture/repo/apps/ios/build-olc-mobile.sh"

echo "build-olc-mobile tests passed"
