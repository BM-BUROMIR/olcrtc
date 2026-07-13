#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <rotation-config.json> <credentials.env> <private-runtime-dir>" >&2
  exit 64
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
CREDENTIALS=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
RUNTIME=$3
LABEL=com.olc.managed-rotation
PLIST="$RUNTIME/$LABEL.plist"
LOG_DIR="$RUNTIME/logs"
LINK="$HOME/Library/LaunchAgents/$LABEL.plist"
PYTHON=$(command -v python3)

mkdir -p "$RUNTIME" "$LOG_DIR" "$HOME/Library/LaunchAgents"
chmod 700 "$RUNTIME" "$LOG_DIR"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ROOT/control-plane/run-managed-rotation.sh</string>
    <string>$CONFIG</string>
    <string>$CREDENTIALS</string>
  </array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>EnvironmentVariables</key>
  <dict><key>OLC_PYTHON</key><string>$PYTHON</string></dict>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>1800</integer>
  <key>ProcessType</key><string>Background</string>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$LOG_DIR/stdout.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/stderr.log</string>
</dict>
</plist>
PLIST
chmod 600 "$PLIST"
plutil -lint "$PLIST"
ln -sfn "$PLIST" "$LINK"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LINK"
launchctl enable "gui/$(id -u)/$LABEL"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "$PLIST"
