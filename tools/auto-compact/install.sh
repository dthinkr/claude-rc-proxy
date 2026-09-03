#!/bin/bash
# Install the stdin shim (and optionally the compaction daemon).
#
#   ./install.sh                 shim + daemon
#   ./install.sh --shim-only     just the side channel, no auto-compaction
#
# Everything it touches is backed up first and listed at the end.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$REPO/shim/cc-stdin-shim"
LABEL="com.claude-auto-compact"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/.local/state/claude-auto-compact"
SHIM_ONLY=0
[ "${1:-}" = "--shim-only" ] && SHIM_ONLY=1

[ "$(uname)" = "Darwin" ] || { echo "macOS only." >&2; exit 1; }
[ -x "$SHIM" ] || chmod +x "$SHIM"

# --- 1. point the VS Code extension at the shim -----------------------------------
found=0
for dir in "$HOME/Library/Application Support/Code/User" \
           "$HOME/Library/Application Support/Code - Insiders/User"; do
  settings="$dir/settings.json"
  [ -f "$settings" ] || continue
  found=1
  cp "$settings" "$settings.bak-$(date +%Y%m%d-%H%M%S)"
  python3 - "$settings" "$SHIM" <<'PY'
import json, sys
path, shim = sys.argv[1], sys.argv[2]
raw = open(path, encoding="utf-8").read()
try:
    cfg = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(f"{path} is not plain JSON (comments?). Add this key by hand:\n"
             f'  "claudeCode.claudeProcessWrapper": "{shim}"')
if cfg.get("claudeCode.claudeProcessWrapper") == shim:
    print(f"  already set: {path}")
    sys.exit(0)
cfg["claudeCode.claudeProcessWrapper"] = shim
open(path, "w", encoding="utf-8").write(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print(f"  claudeCode.claudeProcessWrapper -> {shim}")
print(f"  ({path})")
PY
done
[ "$found" = 1 ] || { echo "No VS Code user settings.json found." >&2; exit 1; }

if [ "$SHIM_ONLY" = 1 ]; then
  echo
  echo "Shim installed. Restart a Claude Code session, then:"
  echo "  ls /tmp/cc-inject/          # one socket per session that has picked it up"
  echo "  echo /compact | nc -U /tmp/cc-inject/<pid>.sock"
  exit 0
fi

# --- 2. launchd agent for the compaction daemon -----------------------------------
mkdir -p "$STATE" "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$REPO/compactd.py</string>
  </array>
  <!-- The firing window is only 8 minutes wide; 2-minute polling never misses it. -->
  <key>StartInterval</key>
  <integer>120</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$STATE/launchd.out</string>
  <key>StandardErrorPath</key>
  <string>$STATE/launchd.err</string>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
PLISTEOF

plutil -lint "$PLIST" >/dev/null
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "  launchd agent $LABEL loaded (every 120s)"

echo
echo "Done. Sessions already running keep their old process -- restart one, then:"
echo "  $REPO/compactd.py --status"
echo
echo "Touched:"
echo "  VS Code user settings  (.bak-<timestamp> alongside each)"
echo "  $PLIST"
echo "  $STATE/"
