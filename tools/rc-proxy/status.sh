#!/bin/bash
#
# Three probes, read together.
#
#   1  /healthz on the proxy, plaintext, local only
#   2  a request to api.anthropic.com through the proxy
#   3  the same request with the proxy bypassed
#
# Probe 2 is not testing Anthropic's endpoint. It is testing that TLS interception
# worked and the request arrived unchanged, so 404 is the pass and what matters is that
# probes 2 and 3 agree.
#
#   1 healthz | 2 through | 3 bypass | diagnosis
#   ok          pass        pass       working
#   ok          fail        pass       the proxy is wedged, or the CA is wrong
#   ok          fail        fail       Anthropic or your network is down, restarting
#                                      the proxy fixes nothing
#   no answer   fail        pass       the agent is dead, restart it
#
# --noproxy '*' on probes 1 and 3 is required, not decoration. Your shell almost
# certainly has https_proxy set once this is installed, and without it the bypass probe
# would quietly go through the proxy too.
#
# Usage:
#   ./cc-kit status rc-proxy
#   tools/rc-proxy/status.sh --oneline    one line, for ./cc-kit status
#   tools/rc-proxy/status.sh --quiet      probes only, exit code carries the verdict

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
  --quiet) MODE="quiet" ;;
  "") ;;
  *) die "unknown argument $1" ;;
esac

LISTEN="${CLAUDE_RC_PROXY_LISTEN:-127.0.0.1:9801}"
CA_CERT="$HOME/.mitmproxy/mitmproxy-ca-cert.pem"
STATE="$CCW_STATE_ROOT/rc-proxy"

# ---- probes ------------------------------------------------------------------

# Capture and then test. Piping curl into grep -q makes grep exit at the first match,
# which sends curl SIGPIPE, and pipefail then reports the whole pipeline as failed. That
# read as "proxy down" against a proxy that was answering perfectly.
p1="no answer"
health="$(curl -s --noproxy '*' --max-time 3 "http://$LISTEN/healthz" 2>/dev/null || true)"
case "$health" in
  *ok*) p1="ok" ;;
esac

p2_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
           -x "http://$LISTEN" --cacert "$CA_CERT" \
           https://api.anthropic.com/ 2>/dev/null || true)"
p3_code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 15 \
           https://api.anthropic.com/ 2>/dev/null || true)"

# curl writes 000 when the connection never completed.
p2="fail"; [ "$p2_code" != "000" ] && [ -n "$p2_code" ] && p2="pass"
p3="fail"; [ "$p3_code" != "000" ] && [ -n "$p3_code" ] && p3="pass"

verdict="unexpected combination, read the three results yourself"
rc=1
if [ "$p1" = "ok" ] && [ "$p2" = "pass" ] && [ "$p3" = "pass" ]; then
  verdict="working"; rc=0
elif [ "$p1" = "ok" ] && [ "$p2" = "fail" ] && [ "$p3" = "pass" ]; then
  verdict="the proxy is wedged, or NODE_EXTRA_CA_CERTS points at the wrong file"
elif [ "$p2" = "fail" ] && [ "$p3" = "fail" ]; then
  verdict="Anthropic or your network is down. Restarting the proxy fixes nothing"
  rc=2
elif [ "$p1" != "ok" ]; then
  verdict="the proxy is not answering. Restart the agent"
  rc=3
fi

loaded="no"
agent_loaded "$TOOL_AGENT_LABEL" && loaded="yes"

if [ "$MODE" = "oneline" ]; then
  printf '%-14s agent %-3s  healthz %-9s  through %-4s  bypass %-4s  %s\n' \
         "rc-proxy" "$loaded" "$p1" "$p2" "$p3" "$verdict"
  exit 0
fi

if [ "$MODE" = "quiet" ]; then
  printf 'healthz=%s through=%s(%s) bypass=%s(%s)\n' "$p1" "$p2" "$p2_code" "$p3" "$p3_code"
  exit "$rc"
fi

head1 "rc-proxy"
say "  agent $TOOL_AGENT_LABEL: $loaded"
if [ "$loaded" = "yes" ]; then
  pid="$(agent_pid "$TOOL_AGENT_LABEL")"
  exitcode="$(agent_last_exit "$TOOL_AGENT_LABEL")"
  prog="$(agent_program "$TOOL_AGENT_LABEL")"
  [ -n "$pid" ] && say "    running, pid $pid"
  [ -n "$exitcode" ] && say "    last exit code $exitcode"
  if [ -n "$prog" ] && [ "${prog#*"$CCW_ROOT"}" = "$prog" ]; then
    warn "the loaded agent runs $prog, which is not in this checkout ($CCW_ROOT)."
  fi
fi
printf '\n'

say "  1 healthz on http://$LISTEN  -> $p1"
say "  2 through the proxy to api.anthropic.com -> $p2 (HTTP $p2_code)"
say "  3 bypassing the proxy                    -> $p3 (HTTP $p3_code)"
printf '\n'
head1 "  $verdict"
printf '\n'

if [ ! -f "$CA_CERT" ]; then
  warn "no certificate at $(tilde "$CA_CERT"), so probe 2 could not have passed.
Regenerate it with: mitmdump --listen-port 39801 -q"
fi

# Is the client actually pointed at the proxy? A working proxy that nothing uses is a
# different problem from a broken one.
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [ -f "$CLAUDE_SETTINGS" ]; then
  if grep -q "$LISTEN" "$CLAUDE_SETTINGS" 2>/dev/null; then
    say "  ~/.claude/settings.json points at $LISTEN"
  else
    say "  ~/.claude/settings.json does not mention $LISTEN, so Claude Code is not"
    say "  using this proxy. ./cc-kit install rc-proxy prints the block to paste."
  fi
else
  say "  no ~/.claude/settings.json, so nothing is pointed at this proxy yet"
fi
printf '\n'

if [ -f "$STATE/route.log" ]; then
  say "  $(tilde "$STATE/route.log") is $(commafy "$(wc -c < "$STATE/route.log" | tr -d ' ')") bytes"
  say "  last three lines:"
  tail -n 3 "$STATE/route.log" | sed 's/^/    /'
  errs="$(grep -c 'POOL-ERR' "$STATE/route.log" 2>/dev/null || true)"
  if [ -n "$errs" ] && [ "$errs" != "0" ]; then
    say "  $errs POOL-ERR lines, which are gateway refusals rather than proxy faults:"
    say "    grep POOL-ERR $(tilde "$STATE/route.log") | tail"
  fi
else
  say "  no route.log yet at $(tilde "$STATE/route.log")"
fi

exit 0
