#!/bin/sh
set -eu

repo_root=$(git rev-parse --show-toplevel)
verifier="$repo_root/tools/ios-testflight/verify-package.sh"
fixtures=$(mktemp -d "${TMPDIR:-/tmp}/olc-package-test.XXXXXX")
trap 'rm -rf "$fixtures"' EXIT HUP INT TERM

make_profiles() {
  destination=$1
  cat >"$destination" <<'JSON'
[
  {
    "id": "telemost",
    "name": "Telemost",
    "subscription": null,
    "bootstrap": {
      "url": "https://example.invalid/device/telemost.olcb",
      "client_key": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    "isBuiltIn": true
  },
  {
    "id": "wb",
    "name": "WB",
    "subscription": null,
    "bootstrap": {
      "url": "https://example.invalid/device/wb.olcb",
      "client_key": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    "isBuiltIn": true
  }
]
JSON
}

expect_rejected() {
  expected=$1
  shift
  if output=$("$verifier" "$@" 2>&1); then
    echo "expected package rejection: $expected" >&2
    exit 1
  fi
  printf '%s' "$output" | grep -F "$expected" >/dev/null || {
    echo "wrong rejection for $expected: $output" >&2
    exit 1
  }
}

valid="$fixtures/valid"
mkdir -p "$valid"
make_profiles "$valid/BuiltInProfiles.local.json"
"$verifier" --profiles "$valid/BuiltInProfiles.local.json" --scan-root "$valid"

missing="$fixtures/missing.json"
jq 'map(select(.id != "wb"))' "$valid/BuiltInProfiles.local.json" >"$missing"
expect_rejected "missing managed profile: wb" --profiles "$missing" --scan-root "$fixtures"

static="$fixtures/static.json"
jq '.[0].subscription = {"room":"https://telemost.example.invalid/j/123"}' \
  "$valid/BuiltInProfiles.local.json" >"$static"
expect_rejected "embedded subscription: telemost" --profiles "$static" --scan-root "$fixtures"

invalid_key="$fixtures/invalid-key.json"
jq '.[1].bootstrap.client_key = "short"' "$valid/BuiltInProfiles.local.json" >"$invalid_key"
expect_rejected "invalid bootstrap key: wb" --profiles "$invalid_key" --scan-root "$fixtures"

backup_root="$fixtures/backup-root"
mkdir -p "$backup_root"
make_profiles "$backup_root/BuiltInProfiles.local.json"
: >"$backup_root/config.json.bak"
expect_rejected "backup file in package input" \
  --profiles "$backup_root/BuiltInProfiles.local.json" --scan-root "$backup_root"

path_root="$fixtures/path-root"
mkdir -p "$path_root"
make_profiles "$path_root/BuiltInProfiles.local.json"
printf '%s\n' '/Users/developer/private/build' >"$path_root/metadata.txt"
expect_rejected "absolute local path in package input" \
  --profiles "$path_root/BuiltInProfiles.local.json" --scan-root "$path_root"

echo "verify-package tests passed"
