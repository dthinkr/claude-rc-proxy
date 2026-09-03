#!/bin/bash
#
# Is the click fix actually in place?
#
# Two independent questions get two answers. Whether the launchd agent is loaded, and
# whether the marker is in the bundle VS Code is running right now. A loaded agent
# proves nothing: the agent only re-applies the patch after an extension upgrade.
#
# Neither answer tells you whether the window has been reloaded. If the marker is
# present and clicks still do nothing, that is the reason.
#
# Usage:
#   ./cc-kit status open-binary
#   tools/open-binary/status.sh --oneline    one line, for ./cc-kit status

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

ONELINE=0
[ "${1:-}" = "--oneline" ] && ONELINE=1

STATE="$CCW_STATE_ROOT/open-binary"
LOG="$STATE/patch.log"
MARK="OPEN-BINARY-FALLBACK-PATCH-v2"

loaded="no"
agent_loaded "$TOOL_AGENT_LABEL" && loaded="yes"

patched=0
total=0
while read -r d; do
  [ -n "$d" ] || continue
  total=$((total + 1))
  grep -q "$MARK" "$d/extension.js" 2>/dev/null && patched=$((patched + 1))
done < <(claude_ext_dirs || true)

if [ "$ONELINE" = 1 ]; then
  if [ "$total" = 0 ]; then
    printf '%-14s agent %-3s  no claude-code extension installed\n' "open-binary" "$loaded"
  else
    printf '%-14s agent %-3s  patched %d of %d installed version(s)\n' \
           "open-binary" "$loaded" "$patched" "$total"
  fi
  exit 0
fi

head1 "open-binary"
say "  agent $TOOL_AGENT_LABEL: $loaded"
if [ "$loaded" = "yes" ]; then
  pid="$(agent_pid "$TOOL_AGENT_LABEL")"
  exitcode="$(agent_last_exit "$TOOL_AGENT_LABEL")"
  prog="$(agent_program "$TOOL_AGENT_LABEL")"
  [ -n "$pid" ] && say "    running now, pid $pid"
  [ -n "$exitcode" ] && say "    last exit code $exitcode"
  if [ -n "$prog" ] && [ "${prog#*"$CCW_ROOT"}" = "$prog" ]; then
    warn "the loaded agent runs $prog, which is not in this checkout ($CCW_ROOT).
Another clone installed it. Uninstall from that one, or run install.sh here to take over."
  fi
fi
printf '\n'

if [ "$total" = 0 ]; then
  say "  no anthropic.claude-code extension found under ~/.vscode/extensions"
else
  say "  installed extension versions:"
  while read -r d; do
    [ -n "$d" ] || continue
    ver="$(ext_version "$d")"
    if grep -q "$MARK" "$d/extension.js" 2>/dev/null; then
      bak="present"
      [ -f "$d/extension.js.ccw-open-binary.bak" ] || bak="MISSING, nothing to restore"
      say "    $ver  patched, backup $bak"
    else
      say "    $ver  not patched"
    fi
  done < <(claude_ext_dirs || true)
fi
printf '\n'

if [ -f "$LOG" ]; then
  say "  last three lines of $(tilde "$LOG"):"
  tail -n 3 "$LOG" | sed 's/^/    /'
else
  say "  no patch log at $(tilde "$LOG") yet"
fi
printf '\n'

if [ -f "$STATE/click-log.on" ]; then
  say "  per-click log is ON: $(tilde "$STATE/runtime.log")"
  if [ -f "$STATE/runtime.log" ]; then
    say "  last two clicks:"
    tail -n 2 "$STATE/runtime.log" | sed 's/^/    /'
  fi
else
  say "  per-click log is off. Turn it on with ./cc-kit install open-binary --click-log"
fi
printf '\n'

if [ "$patched" -gt 0 ]; then
  say "The patch is in the file on disk. That does not mean the running window has it."
  say "If clicks are still dead, run Developer: Reload Window in VS Code."
else
  say "Nothing is patched right now. ./cc-kit install open-binary applies it."
  say "If it has been failing, ./cc-kit diff open-binary shows what openFile looks like now."
fi
