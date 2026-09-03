#!/bin/bash
#
# Put the extension bundle back the way it was and remove everything this tool added.
#
# The restore is a straight copy of extension.js.ccw-open-binary.bak over extension.js,
# so it also reverts anything else that patched the bundle after our backup was taken.
# If you run another patcher against this extension, read docs/launchd-notes.md before
# running this.
#
# Usage:
#   ./cc-kit uninstall open-binary
#   ./cc-kit uninstall open-binary --yes         no confirmation prompt
#   ./cc-kit uninstall open-binary --keep-backups

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

KEEP_BACKUPS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) CCW_ASSUME_YES=1; shift ;;
    --keep-backups) KEEP_BACKUPS=1; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done

STATE="$CCW_STATE_ROOT/open-binary"
PLIST="$HOME/Library/LaunchAgents/$TOOL_AGENT_LABEL.plist"

collect_lines DIRS < <(claude_ext_dirs || true)

plan_reset
restorable=0
for d in ${DIRS[@]+"${DIRS[@]}"}; do
  [ -n "$d" ] || continue
  js="$d/extension.js"
  bak="$js.ccw-open-binary.bak"
  ver="$(ext_version "$d")"
  if [ -f "$bak" ]; then
    restorable=$((restorable + 1))
    plan_add "$(printf '%-12s restore extension.js from the backup' "$ver")"
    if [ "$KEEP_BACKUPS" = 0 ]; then
      plan_add "$(printf '%-12s then remove the backup' "")"
    fi
  elif grep -q "OPEN-BINARY-FALLBACK-PATCH" "$js" 2>/dev/null; then
    plan_add "$(printf '%-12s PATCHED WITH NO BACKUP. Nothing can be restored here.' "$ver")"
  else
    plan_add "$(printf '%-12s not patched, nothing to do' "$ver")"
  fi
done
plan_add ""
plan_add "boot out and remove $(tilde "$PLIST")"
plan_add "remove $(tilde "$STATE")"
plan_show

if [ "$restorable" = 0 ]; then
  say "No backup to restore. If a bundle is patched and its backup is gone, the clean"
  say "way back is to uninstall and reinstall the Claude Code extension in VS Code."
  printf '\n'
fi

confirm "Restore the bundles and remove the agent?" || exit 1

printf '\n'
head1 "Reverting"
for d in ${DIRS[@]+"${DIRS[@]}"}; do
  [ -n "$d" ] || continue
  js="$d/extension.js"
  bak="$js.ccw-open-binary.bak"
  [ -f "$bak" ] || continue
  cp "$bak" "$js"
  say "  restored $(tilde "$js")"
  if [ "$KEEP_BACKUPS" = 0 ]; then
    rm -f "$bak"
    say "  removed  $(tilde "$bak")"
  fi
done

manifest_generic_uninstall
printf '\n'

say "Run Developer: Reload Window in VS Code to get the unpatched bundle back."
say "Until you do, the running window still has the patch loaded."
