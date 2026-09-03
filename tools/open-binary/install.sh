#!/bin/bash
#
# Install the binary-file-link patch and the launchd agent that keeps it applied.
#
# This is the only script here that edits a file Anthropic ships, so it prints the whole
# plan and asks before it writes anything. Read ./cc-kit diff open-binary first if you
# want to see the patch itself.
#
# Safe to run twice. It says which of applied, already applied or upgraded happened for
# each installed extension version.
#
# Usage:
#   ./cc-kit install open-binary
#   ./cc-kit install open-binary --click-log   log one line per click to the state dir
#   ./cc-kit install open-binary --yes         no confirmation prompt

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

CLICK_LOG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --click-log) CLICK_LOG=1; shift ;;
    --no-click-log) CLICK_LOG=0; shift ;;
    --yes|-y) CCW_ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done

# Not state_dir here: nothing is created before the plan is shown and confirmed.
STATE="$CCW_STATE_ROOT/open-binary"
PLIST="$HOME/Library/LaunchAgents/$TOOL_AGENT_LABEL.plist"
CLICK_FLAG="$STATE/click-log.on"
# Watch both editors. claude_ext_dirs() reads both, so watching only stable would leave
# an Insiders install patched once and never re-patched after an upgrade. A WatchPaths
# entry for a directory that does not exist is ignored by launchd.
WATCH_DIRS=("$HOME/.vscode/extensions" "$HOME/.vscode-insiders/extensions")

# ---- prerequisites, named ----------------------------------------------------

NODE="$(resolve_node)" || die "no node found.
patch.sh runs node --check on the patched bundle and refuses to write without it, so
node is required, not optional.
  brew install node
Then run this again."

PYTHON="$(resolve_python3)" || die "no python3 found. macOS ships one at /usr/bin/python3.
Check: xcode-select --install"

collect_lines DIRS < <(claude_ext_dirs || true)
[ "${#DIRS[@]}" -gt 0 ] || die "no anthropic.claude-code extension under ~/.vscode/extensions or ~/.vscode-insiders/extensions.
Install the Claude Code extension in VS Code, then run this again."

_have_watch=0
for _w in "${WATCH_DIRS[@]}"; do
  [ -d "$_w" ] && _have_watch=1
done
[ "$_have_watch" = 1 ] || die "neither ~/.vscode/extensions nor ~/.vscode-insiders/extensions exists"

# ---- refuse on a colliding agent --------------------------------------------
#
# An agent from an older naming scheme, or a hand-rolled one, keeps patching the same
# bundle on the same WatchPaths event. Two agents doing read-modify-write on one file in
# the same second is the failure that goes unnoticed for weeks.
collect_lines COLLIDE < <(colliding_agents 'open.?binary')
if [ "${#COLLIDE[@]}" -gt 0 ]; then
  say "Another launchd agent is already patching this bundle:"
  for label in "${COLLIDE[@]}"; do
    say "  $label"
  done
  die "Boot it out first, then run this again:
  launchctl bootout gui/\$(id -u)/${COLLIDE[0]}
  rm -f ~/Library/LaunchAgents/${COLLIDE[0]}.plist
This installer will not run alongside it."
fi

# Not a collision, but an unsupported combination worth saying out loud once.
OTHER_PATCHERS="$(launchctl list 2>/dev/null | awk '$3 ~ /cc-(hide-banner|pink-send)/ {print $3}' || true)"
if [ -n "$OTHER_PATCHERS" ]; then
  warn "these agents also patch files inside the Claude Code extension:
$OTHER_PATCHERS
They back up to their own fixed .bak names. Restoring one of those backups can revert
this patch as well. See docs/launchd-notes.md."
fi

# ---- the plan ---------------------------------------------------------------

plan_reset
for d in "${DIRS[@]}"; do
  js="$d/extension.js"
  ver="$(ext_version "$d")"
  if grep -q "OPEN-BINARY-FALLBACK-PATCH-v2" "$js" 2>/dev/null; then
    plan_add "$(printf '%-12s %s' "$ver" "already patched with v2, will be left alone")"
  elif grep -q "OPEN-BINARY-FALLBACK-PATCH" "$js" 2>/dev/null; then
    plan_add "$(printf '%-12s %s' "$ver" "carries an older patch, will be restored from backup then patched")"
  else
    plan_add "$(printf '%-12s %s' "$ver" "will be patched, about 520 bytes into a $(wc -c < "$js" | tr -d ' ') byte file")"
  fi
  plan_add "$(printf '%-12s   %s' "" "$(tilde "$js")")"
  if [ ! -f "$js.ccw-open-binary.bak" ]; then
    plan_add "$(printf '%-12s   %s' "" "backup will be created: $(basename "$js").ccw-open-binary.bak")"
  fi
done
plan_add ""
plan_add "agent    $(tilde "$PLIST")"
for _w in "${WATCH_DIRS[@]}"; do
  [ -d "$_w" ] || continue
  plan_add "           WatchPaths on $(tilde "$_w"), re-applies after every extension upgrade"
done
plan_add "state    $(tilde "$STATE")"
if [ "$CLICK_LOG" = 1 ]; then
  plan_add "           per-click log ON, one line per click to $(tilde "$STATE/runtime.log")"
else
  plan_add "           per-click log off"
fi
plan_show

say "node:    $NODE"
say "python3: $PYTHON"
printf '\n'

confirm "Patch the Claude Code extension bundle and load the agent?" || exit 1

# ---- write ------------------------------------------------------------------

mkdir -p "$STATE"
if [ "$CLICK_LOG" = 1 ]; then
  : > "$CLICK_FLAG"
else
  rm -f "$CLICK_FLAG"
fi

printf '\n'
head1 "Patching"
set +e
"$HERE/patch.sh"
patch_rc=$?
set -e
printf '\n'

if [ "$patch_rc" -eq 1 ]; then
  die "at least one bundle failed and was rolled back. See $(tilde "$STATE/patch.log").
The agent was not loaded."
fi
if [ "$patch_rc" -eq 3 ]; then
  warn "nothing was patched. The anchor did not match, or a prerequisite was missing.
See $(tilde "$STATE/patch.log"). Loading the agent anyway so a future extension version
gets another try, but clicks will keep doing nothing until the anchor matches again.
Run ./cc-kit diff open-binary to see what openFile looks like now."
fi

head1 "Agent"
PLIST_LABEL="$TOOL_AGENT_LABEL"
PLIST_PROGRAM=(/bin/bash "$HERE/patch.sh" --quiet)
PLIST_WATCH=()
for _w in "${WATCH_DIRS[@]}"; do
  [ -d "$_w" ] && PLIST_WATCH+=("$_w")
done
PLIST_RUNATLOAD=1
PLIST_STDERR="$STATE/agent.err"
PLIST_PROCTYPE="Background"
emit_plist "$PLIST"
agent_load "$TOOL_AGENT_LABEL" "$PLIST"
say "  loaded $TOOL_AGENT_LABEL"
say "  runs $(tilde "$HERE/patch.sh") on every write under the watched extension directories"
printf '\n'

manifest_print_touched

head1 "One more step, and it is required"
say "In VS Code, run Developer: Reload Window from the command palette."
say "Developer: Restart Extension Host works too. Restarting the Claude Code session"
say "does not reload extension.js, and neither does starting a new chat."
printf '\n'
say "Then click a PNG in the chat panel. Check anything with:"
say "  ./cc-kit status open-binary"
printf '\n'
head1 "Undo by hand, if this checkout is ever gone"
cat <<UNDO
  launchctl bootout gui/\$(id -u)/$TOOL_AGENT_LABEL
  rm -f $(tilde "$PLIST")
  for d in ~/.vscode/extensions/anthropic.claude-code-*/ ~/.vscode-insiders/extensions/anthropic.claude-code-*/; do
    [ -f "\$d/extension.js.ccw-open-binary.bak" ] && cp "\$d/extension.js.ccw-open-binary.bak" "\$d/extension.js"
  done
  rm -rf $(tilde "$STATE")
UNDO
