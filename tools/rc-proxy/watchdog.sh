#!/bin/bash
#
# Restart the proxy when it is wedged, and only then.
#
# It runs the same three probes as status.sh and acts on one combination:
#
#   healthz no answer, bypass passes  ->  restart
#   anything else                     ->  do nothing
#
# The second condition is the whole point. During an Anthropic outage or a network drop,
# probes 2 and 3 both fail and a restart fixes nothing. Restarting anyway would kill
# every session's in-flight stream for no reason, once per interval, for the length of
# the outage.
#
# install.sh does not install this as an agent. It is here to run by hand or from your
# own scheduler. If you do schedule it, resolve interpreters by absolute path: launchd
# runs jobs with a PATH that has no /opt/homebrew/bin. See docs/launchd-notes.md.
#
# Usage:
#   tools/rc-proxy/watchdog.sh              check, restart if wedged
#   tools/rc-proxy/watchdog.sh --dry-run    check and report, never restart

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

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

STATE="$(state_dir rc-proxy)"
LOG="$STATE/watchdog.log"

log() {
  local line
  line="$(printf '%s  %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$*")"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$LOG" 2>/dev/null || true
}

set +e
result="$("$HERE/status.sh" --quiet)"
rc=$?
set -e

case "$rc" in
  0)
    log "ok       $result"
    ;;
  2)
    # Probes 2 and 3 both failed. Upstream or the network, not us.
    log "upstream $result   not restarting, a restart cannot fix this"
    ;;
  3)
    if [ "$DRY" = 1 ]; then
      log "wedged   $result   would restart (dry run)"
      exit 0
    fi
    log "wedged   $result   restarting $TOOL_AGENT_LABEL"
    if agent_loaded "$TOOL_AGENT_LABEL"; then
      agent_kickstart "$TOOL_AGENT_LABEL"
    else
      log "error    $TOOL_AGENT_LABEL is not loaded. Run ./cc-kit install rc-proxy"
      exit 1
    fi
    sleep 2
    set +e
    "$HERE/status.sh" --quiet
    after=$?
    set -e
    if [ "$after" = 0 ]; then
      log "recovered"
    else
      log "still down after a restart. Check $(tilde "$STATE/launchd.err")"
      exit 1
    fi
    ;;
  *)
    log "unclear  $result   doing nothing"
    ;;
esac

exit 0
