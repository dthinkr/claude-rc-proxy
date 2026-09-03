#!/bin/bash
# Remove everything install.sh added. Running sessions keep the shim until restarted.
set -euo pipefail
LABEL="com.claude-auto-compact"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "  removed $PLIST"
fi

for dir in "$HOME/Library/Application Support/Code/User" \
           "$HOME/Library/Application Support/Code - Insiders/User"; do
  settings="$dir/settings.json"
  [ -f "$settings" ] || continue
  python3 - "$settings" <<'PY'
import json, sys
path = sys.argv[1]
try:
    cfg = json.loads(open(path, encoding="utf-8").read())
except json.JSONDecodeError:
    sys.exit(f"  {path} is not plain JSON; remove claudeCode.claudeProcessWrapper by hand")
if cfg.pop("claudeCode.claudeProcessWrapper", None) is None:
    sys.exit(0)
open(path, "w", encoding="utf-8").write(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print(f"  removed claudeCode.claudeProcessWrapper from {path}")
PY
done

echo
echo "State and logs left in ~/.local/state/claude-auto-compact/ -- delete if you want."
echo "Restart your Claude Code sessions to stop using the shim."
