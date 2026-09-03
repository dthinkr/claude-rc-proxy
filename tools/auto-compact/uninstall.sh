#!/bin/bash
#
# Remove everything install.sh added.
#
# The VS Code setting is only removed if it points at this checkout's shim. If it points
# somewhere else, another clone or another tool owns it and this leaves it alone.
#
# Sessions already running keep the shim until you restart them. That is harmless: with
# no daemon nothing writes into the socket.
#
# Usage:
#   ./cc-kit uninstall auto-compact
#   ./cc-kit uninstall auto-compact --yes        no confirmation prompt
#   ./cc-kit uninstall auto-compact --keep-state keep the log and state.json

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CCW_ROOT="$(cd "$HERE/../.." && pwd)"
export CCW_ROOT
# shellcheck source=lib/common.sh
. "$CCW_ROOT/lib/common.sh"
# shellcheck source=lib/launchd.sh
. "$CCW_ROOT/lib/launchd.sh"
# shellcheck source=lib/manifest.sh
. "$CCW_ROOT/lib/manifest.sh"

require_macos
manifest_load "$HERE"

KEEP_STATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) CCW_ASSUME_YES=1; shift ;;
    --keep-state) KEEP_STATE=1; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done

SHIM="$HERE/shim/cc-stdin-shim"
STATE="$CCW_STATE_ROOT/auto-compact"
PLIST="$HOME/Library/LaunchAgents/$TOOL_AGENT_LABEL.plist"
SETTING_KEY="claudeCode.claudeProcessWrapper"

PYTHON="$(resolve_bin python3 /usr/bin/python3)" || die "no python3 found"

plan_reset
if agent_loaded "$TOOL_AGENT_LABEL"; then
  plan_add "boot out $TOOL_AGENT_LABEL"
fi
[ -f "$PLIST" ] && plan_add "remove $(tilde "$PLIST")"

touched_settings=0
while read -r dir; do
  [ -n "$dir" ] || continue
  s="$dir/settings.json"
  [ -f "$s" ] || continue
  if grep -Fq "$SHIM" "$s" 2>/dev/null; then
    touched_settings=1
    plan_add "remove \"$SETTING_KEY\" from $(tilde "$s")"
    plan_add "  a timestamped backup is written next to it first"
  elif grep -Fq "$SETTING_KEY" "$s" 2>/dev/null; then
    plan_add "leave $(tilde "$s") alone, its $SETTING_KEY points somewhere else"
  fi
done < <(vscode_user_dirs)

if [ "$KEEP_STATE" = 0 ] && [ -d "$STATE" ]; then
  plan_add "remove $(tilde "$STATE")"
fi
plan_show

confirm "Remove the compactor?" || exit 1

printf '\n'
head1 "Removing"

if [ "$touched_settings" = 1 ]; then
  while read -r dir; do
    [ -n "$dir" ] || continue
    s="$dir/settings.json"
    [ -f "$s" ] || continue
    grep -Fq "$SHIM" "$s" 2>/dev/null || continue
    bak="$(backup_file "$s")"
    say "  backup $(tilde "$bak")"
    "$PYTHON" - "$s" "$SETTING_KEY" "$SHIM" <<'PY'
import json, sys
path, key, shim = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    cfg = json.loads(open(path, encoding="utf-8").read())
except json.JSONDecodeError:
    sys.exit(f"  {path} is not plain JSON. Remove {key} by hand.")
if cfg.get(key) != shim:
    print(f"  {path}: {key} does not point here, left alone")
    sys.exit(0)
del cfg[key]
open(path, "w", encoding="utf-8").write(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print(f"  removed {key} from {path}")
PY
  done < <(vscode_user_dirs)
fi

if [ "$KEEP_STATE" = 1 ]; then
  # manifest_generic_uninstall would remove the state directory, so handle the agent
  # here instead and leave the state alone.
  agent_unload "$TOOL_AGENT_LABEL"
  if [ -f "$PLIST" ]; then
    rm -f "$PLIST"
    say "  removed $(tilde "$PLIST")"
  fi
  say "  kept $(tilde "$STATE")"
else
  manifest_generic_uninstall
fi

printf '\n'
say "Restart your Claude Code sessions to stop launching through the shim."
say "Until then they keep the side channel open, and nothing writes to it."
