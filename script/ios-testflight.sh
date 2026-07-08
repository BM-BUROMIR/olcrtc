#!/usr/bin/env sh
set -eu

usage() {
  cat <<'EOF'
Usage: script/ios-testflight.sh [apply_ids|doctor|dry_run|portal_prepare|certificates|profiles|archive|beta]

Environment:
  OLC_APPSTORE_ENV                 optional shell env file loaded before running fastlane
  OLC_IOS_APP_DIR                  iOS app directory; auto-detected when omitted
  OLC_IOS_APP_IDENTIFIER           defaults to com.oxi717.olc
  OLC_IOS_TUNNEL_IDENTIFIER        defaults to $OLC_IOS_APP_IDENTIFIER.tunnel
  OLC_IOS_APP_GROUP                defaults to group.com.oxi717.olc
  OLC_IOS_DEVELOPMENT_TEAM         Apple development team id
  OLC_APPLE_ID                     required only for portal_prepare
  ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH required for certificates/profiles/beta
EOF
}

cmd="${1:-dry_run}"
case "$cmd" in
  apply_ids|doctor|dry_run|portal_prepare|certificates|profiles|archive|beta) ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

repo_root="$(git rev-parse --show-toplevel)"

if [ -n "${OLC_APPSTORE_ENV:-}" ]; then
  if [ ! -f "$OLC_APPSTORE_ENV" ]; then
    echo "missing OLC_APPSTORE_ENV file: $OLC_APPSTORE_ENV" >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  . "$OLC_APPSTORE_ENV"
  set +a
fi

if [ -z "${OLC_IOS_APP_DIR:-}" ]; then
  for candidate in \
    "$repo_root/../client/ios/OlcClientiOS" \
    "$repo_root/../../../client/ios/OlcClientiOS"; do
    if [ -d "$candidate" ]; then
      OLC_IOS_APP_DIR="$candidate"
      break
    fi
  done
fi

if [ -z "${OLC_IOS_APP_DIR:-}" ]; then
  echo "cannot auto-detect iOS app directory; set OLC_IOS_APP_DIR" >&2
  exit 1
fi

export OLC_IOS_APP_DIR
export OLC_IOS_APP_IDENTIFIER="${OLC_IOS_APP_IDENTIFIER:-com.oxi717.olc}"
export OLC_IOS_TUNNEL_IDENTIFIER="${OLC_IOS_TUNNEL_IDENTIFIER:-$OLC_IOS_APP_IDENTIFIER.tunnel}"
export OLC_IOS_APP_GROUP="${OLC_IOS_APP_GROUP:-group.com.oxi717.olc}"
export OLC_IOS_DEVELOPMENT_TEAM="${OLC_IOS_DEVELOPMENT_TEAM:-2AQ4VTF696}"
export OLC_IOS_DISPLAY_NAME="${OLC_IOS_DISPLAY_NAME:-OLC}"
export OLC_IOS_TUNNEL_DISPLAY_NAME="${OLC_IOS_TUNNEL_DISPLAY_NAME:-OLC Tunnel}"
export FASTLANE_HIDE_CHANGELOG=1
export FASTLANE_SKIP_UPDATE_CHECK=1

if ! command -v fastlane >/dev/null 2>&1; then
  echo "fastlane not found; install fastlane before running this script" >&2
  exit 127
fi

cd "$repo_root/tools/ios-testflight"
exec fastlane ios "$cmd"
