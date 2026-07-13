#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUTPUT="$ROOT/apps/ios/OlcMobile.xcframework"
BUILD_ROOT=${OLC_MOBILE_BUILD_ROOT:-/Users/Shared/olc-build}

command -v gomobile >/dev/null 2>&1 || {
  echo "gomobile is required to build OlcMobile.xcframework" >&2
  exit 127
}

mkdir -p "$(dirname "$BUILD_ROOT")"
ln -sfn "$ROOT" "$BUILD_ROOT"
rm -rf "$OUTPUT"

(
  cd "$BUILD_ROOT"
  GOFLAGS="${GOFLAGS:+$GOFLAGS }-buildvcs=false" gomobile bind \
    -target=ios,iossimulator \
    -trimpath \
    -ldflags='-s -w' \
    -o "$OUTPUT" \
    ./mobile/olcmobile
)

for binary in \
  "$OUTPUT/ios-arm64/OlcMobile.framework/OlcMobile" \
  "$OUTPUT/ios-arm64_x86_64-simulator/OlcMobile.framework/OlcMobile"; do
  [[ -f "$binary" ]] || { echo "missing mobile framework binary: $binary" >&2; exit 1; }
  if strings "$binary" | grep -F -e "$ROOT" -e "$HOME" -e '/tmp/' >/dev/null; then
    echo "mobile framework contains a private build path: $binary" >&2
    exit 1
  fi
done
