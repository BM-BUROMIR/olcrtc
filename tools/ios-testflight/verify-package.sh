#!/bin/sh
set -eu

usage() {
  echo "Usage: verify-package.sh --profiles PATH [--scan-root PATH ...]" >&2
  exit 2
}

profiles=
scan_roots=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profiles)
      [ "$#" -ge 2 ] || usage
      profiles=$2
      shift 2
      ;;
    --scan-root)
      [ "$#" -ge 2 ] || usage
      scan_roots="${scan_roots}${scan_roots:+
}$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$profiles" ] || usage
[ -f "$profiles" ] || { echo "managed profiles file is missing" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

for profile_id in telemost wb; do
  count=$(jq --arg id "$profile_id" '[.[] | select(.id == $id)] | length' "$profiles")
  [ "$count" = 1 ] || { echo "missing managed profile: $profile_id" >&2; exit 1; }
  jq -e --arg id "$profile_id" '.[] | select(.id == $id) | .subscription == null' \
    "$profiles" >/dev/null || { echo "embedded subscription: $profile_id" >&2; exit 1; }
  jq -e --arg id "$profile_id" \
    '.[] | select(.id == $id) | (.bootstrap.url | type == "string" and test("^https://[^/[:space:]]+/.+"))' \
    "$profiles" >/dev/null || { echo "invalid bootstrap URL: $profile_id" >&2; exit 1; }
  jq -e --arg id "$profile_id" \
    '.[] | select(.id == $id) | (.bootstrap.client_key | type == "string" and test("^[0-9a-fA-F]{64}$"))' \
    "$profiles" >/dev/null || { echo "invalid bootstrap key: $profile_id" >&2; exit 1; }
done

old_ifs=$IFS
IFS='
'
for root in $scan_roots; do
  [ -e "$root" ] || { echo "package scan root is missing" >&2; exit 1; }
  if find "$root" -type f \( -name '*.bak' -o -name '*.backup' -o -name '*~' -o -name '.DS_Store' \) \
    -print -quit | grep -q .; then
    echo "backup file in package input" >&2
    exit 1
  fi
  if grep -a -I -R -E -l \
    "/Users/[^/[:space:]\"']+|/home/[^/[:space:]\"']+|/private/(tmp|var/folders)/" \
    "$root" >/dev/null 2>&1; then
    echo "absolute local path in package input" >&2
    exit 1
  fi
done
IFS=$old_ifs

echo "managed package verification passed"
