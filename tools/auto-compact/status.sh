#!/bin/bash
#
# Is the compactor actually working?
#
# Three separate questions. Whether the launchd agent is loaded, whether the VS Code
# setting points at the shim in this checkout, and whether the session you care about
# has been restarted since. A loaded agent proves nothing about the last two.
#
# Usage:
#   ./cc-kit status auto-compact
#   tools/auto-compact/status.sh --oneline      one line, for ./cc-kit status
#   tools/auto-compact/status.sh --cache-tier   just the tier check. Exit 1 means the
#                                               5-minute tier dominates and the shipped
#                                               window is wrong for this account.

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

MODE="full"
case "${1:-}" in
  --oneline) MODE="oneline" ;;
  --cache-tier) MODE="tier" ;;
  "") ;;
  *) die "unknown argument $1" ;;
esac

SHIM="$HERE/shim/cc-stdin-shim"
DAEMON="$HERE/compactd.py"
STATE="$CCW_STATE_ROOT/auto-compact"
SETTING_KEY="claudeCode.claudeProcessWrapper"
SOCK_DIR="${CC_INJECT_DIR:-/tmp/cc-inject}"

# ---- the cache-tier check ----------------------------------------------------
#
# Reads every transcript for cache-creation token counts and compares the two tiers.
# 6.7 GB of transcripts took 1.4 seconds on the machine this was written on.
#
# The tier is a property of your account and it can change. There is a string in the
# Claude Code binary reading "overage state changed (TTL flip expected)", so entering
# usage overage flips it. Which way it flips is not documented.
cache_tier() {
  local tokens h5 h1
  tokens="$(grep -ho '"ephemeral_[0-9]*[hm]_input_tokens":[0-9]*' \
            "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null \
            | awk -F'[:"]' '{t[$2]+=$NF} END{for(k in t) print k, t[k]}' || true)"
  h5="$(printf '%s\n' "$tokens" | awk '/ephemeral_5m/ {print $2}')"
  h1="$(printf '%s\n' "$tokens" | awk '/ephemeral_1h/ {print $2}')"
  h5="${h5:-0}"; h1="${h1:-0}"

  head1 "Cache tier"
  say "  ephemeral_1h  $(commafy "$h1") tokens written"
  say "  ephemeral_5m  $(commafy "$h5") tokens written"

  if [ "$h1" = 0 ] && [ "$h5" = 0 ]; then
    warn "no cache-creation records found under ~/.claude/projects.
Either this is a new install or the transcripts are elsewhere. The tier cannot be
checked, so this is not treated as a refusal. The shipped window assumes the 1-hour
tier: if yours is the 5-minute tier the daemon will simply never help."
    return 0
  fi
  if [ "$h5" -gt "$h1" ]; then
    say "  the 5-minute tier dominates on this account"
    say "  the shipped window fires between 50 and 58 minutes idle, which is wrong here"
    return 1
  fi
  say "  the 1-hour tier is real on this account, so the shipped window applies"
  return 0
}

if [ "$MODE" = "tier" ]; then
  cache_tier
  exit $?
fi

# ---- agent -------------------------------------------------------------------

loaded="no"
agent_loaded "$TOOL_AGENT_LABEL" && loaded="yes"

wired="no"
while read -r dir; do
  [ -n "$dir" ] || continue
  s="$dir/settings.json"
  [ -f "$s" ] || continue
  if grep -Fq "$SHIM" "$s" 2>/dev/null; then wired="yes"; fi
done < <(vscode_user_dirs)

live=0
if [ -d "$SOCK_DIR" ]; then
  live="$(find "$SOCK_DIR" -maxdepth 1 -name '*.sock' 2>/dev/null | wc -l | tr -d ' ')"
fi

last="never"
if [ -f "$STATE/compactd.log" ]; then
  last="$(tail -n 1 "$STATE/compactd.log" | cut -c1-19)"
fi

if [ "$MODE" = "oneline" ]; then
  printf '%-14s agent %-3s  shim wired %-3s  %s session(s) on the side channel\n' \
         "auto-compact" "$loaded" "$wired" "$live"
  exit 0
fi

head1 "auto-compact"
say "  agent $TOOL_AGENT_LABEL: $loaded"
if [ "$loaded" = "yes" ]; then
  prog="$(agent_program "$TOOL_AGENT_LABEL")"
  exitcode="$(agent_last_exit "$TOOL_AGENT_LABEL")"
  [ -n "$exitcode" ] && say "    last exit code $exitcode"
  if [ -n "$prog" ] && [ "${prog#*"$CCW_ROOT"}" = "$prog" ]; then
    warn "the loaded agent runs $prog, which is not in this checkout ($CCW_ROOT).
Another clone installed it. Uninstall from that one first, or two daemons will send
/compact to the same sessions."
  fi
fi
say "  last log line: $last"
printf '\n'

say "  $SETTING_KEY points at this checkout's shim: $wired"
while read -r dir; do
  [ -n "$dir" ] || continue
  s="$dir/settings.json"
  [ -f "$s" ] || continue
  if grep -Fq "$SHIM" "$s" 2>/dev/null; then
    say "    yes: $(tilde "$s")"
  elif grep -Fq "$SETTING_KEY" "$s" 2>/dev/null; then
    say "    set to something else: $(tilde "$s")"
  else
    say "    not set: $(tilde "$s")"
  fi
done < <(vscode_user_dirs)
printf '\n'

say "  side channels open right now: $live under $SOCK_DIR"
if [ "$live" = 0 ]; then
  say "    no live session has picked the shim up. Restart a Claude Code session."
  say "    Sessions started before the install keep their old process."
fi
printf '\n'

if [ -x "$DAEMON" ]; then
  head1 "Per-session verdict"
  "$DAEMON" --status || true
fi
