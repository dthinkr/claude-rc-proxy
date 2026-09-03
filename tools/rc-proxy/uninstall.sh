#!/bin/bash
#
# Remove the proxy. Order matters here more than anywhere else in this repo.
#
# Take the four env keys out of ~/.claude/settings.json before or at the same time as
# booting the agent out. If https_proxy still points at 127.0.0.1:9801 and nothing is
# listening, every Claude Code session on this machine fails to connect, and the error
# you get looks like an Anthropic outage rather than a local one.
#
# This script checks for those keys and stops if it finds them.
#
# Usage:
#   ./cc-kit uninstall rc-proxy
#   ./cc-kit uninstall rc-proxy --yes     no confirmation prompt
#   ./cc-kit uninstall rc-proxy --force   proceed with the env keys still in place

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

FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) CCW_ASSUME_YES=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done

LISTEN="${CLAUDE_RC_PROXY_LISTEN:-127.0.0.1:9801}"
STATE="$CCW_STATE_ROOT/rc-proxy"
PLIST="$HOME/Library/LaunchAgents/$TOOL_AGENT_LABEL.plist"
BIN="$HERE/claude-rc-proxy"
TOKEN_FILE="$CCW_CONFIG_ROOT/rc-proxy.token"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# ---- the ordering check ------------------------------------------------------

still_pointed=0
if [ -f "$CLAUDE_SETTINGS" ] && grep -q "$LISTEN" "$CLAUDE_SETTINGS" 2>/dev/null; then
  still_pointed=1
fi

if [ "$still_pointed" = 1 ]; then
  head1 "Stop. Remove the env block first."
  say "$(tilde "$CLAUDE_SETTINGS") still points at $LISTEN:"
  grep -n "$LISTEN" "$CLAUDE_SETTINGS" | sed 's/^/    /'
  printf '\n'
  say "Delete these four keys from the env object:"
  say "    https_proxy, http_proxy, no_proxy, NODE_EXTRA_CA_CERTS"
  printf '\n'
  say "If you boot the agent out while they are still there, every Claude Code session"
  say "on this machine fails to connect, including the one you are reading this in."
  printf '\n'
  if [ "$FORCE" = 0 ]; then
    die "Edit that file, then run this again. Pass --force if you meant it."
  fi
  warn "continuing with the env keys in place because --force was given"
  printf '\n'
fi

# ---- the plan ---------------------------------------------------------------

plan_reset
if agent_loaded "$TOOL_AGENT_LABEL"; then
  plan_add "boot out $TOOL_AGENT_LABEL, which stops proxying immediately"
fi
[ -f "$PLIST" ] && plan_add "remove $(tilde "$PLIST")"
[ -f "$BIN" ] && plan_add "remove $(tilde "$BIN")"
[ -d "$STATE" ] && plan_add "remove $(tilde "$STATE")"
[ -f "$TOKEN_FILE" ] && plan_add "keep $(tilde "$TOKEN_FILE"), you wrote it"
plan_show

confirm "Remove the proxy?" || exit 1

printf '\n'
head1 "Removing"
manifest_generic_uninstall
printf '\n'

health="$(curl -s --noproxy '*' --max-time 2 "http://$LISTEN/healthz" 2>/dev/null || true)"
case "$health" in
  *ok*)
  warn "something is still answering on http://$LISTEN/healthz.
Another process is holding that port:
  lsof -nP -iTCP:${LISTEN##*:} -sTCP:LISTEN"
    ;;
  *)
    say "  nothing is listening on $LISTEN any more"
    ;;
esac
printf '\n'

if [ "$still_pointed" = 1 ]; then
  warn "$(tilde "$CLAUDE_SETTINGS") still points at $LISTEN and nothing is there now.
Every session that reads it will fail to connect until you remove those keys."
else
  say "Also worth removing if you set it:"
  say "  launchctl unsetenv NODE_EXTRA_CA_CERTS"
  say "  then restart VS Code"
fi

exit 0
