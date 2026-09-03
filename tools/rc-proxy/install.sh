#!/bin/bash
#
# Build the proxy, write the launchd agent, and print the settings.json block for you to
# paste.
#
# It does not edit ~/.claude/settings.json. Every Claude Code session on this machine
# reads that file, and this is the one tool here that can take all of them offline at
# once, so the edit is yours to make after you have seen it.
#
# Prerequisites, all three refused loudly rather than worked around:
#
#   brew install go mitmproxy
#   mitmdump --listen-port 39801 -q     # a few seconds, then Ctrl-C. Writes ~/.mitmproxy/
#   mkdir -p ~/.config/ccw
#   printf '%s' 'YOUR_POOL_TOKEN' > ~/.config/ccw/rc-proxy.token
#   chmod 600 ~/.config/ccw/rc-proxy.token
#
# The CA is reused from mitmproxy rather than minted here, so an existing mitmproxy setup
# migrates with no client-side change. mitmproxy itself is never run again.
#
# Usage:
#   ./cc-kit install rc-proxy
#   ./cc-kit install rc-proxy --yes     no confirmation prompt

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

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) CCW_ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done

BIN="$HERE/claude-rc-proxy"
# Not state_dir here: nothing is created before the plan is shown and confirmed.
STATE="$CCW_STATE_ROOT/rc-proxy"
PLIST="$HOME/Library/LaunchAgents/$TOOL_AGENT_LABEL.plist"
TOKEN_FILE="$CCW_CONFIG_ROOT/rc-proxy.token"
CA_KEY="$HOME/.mitmproxy/mitmproxy-ca.pem"
CA_CERT="$HOME/.mitmproxy/mitmproxy-ca-cert.pem"
LISTEN="${CLAUDE_RC_PROXY_LISTEN:-127.0.0.1:9801}"

# ---- prerequisites, named ----------------------------------------------------

[ -f "$HERE/main.go" ] && [ -f "$HERE/go.mod" ] || die "no Go source in $(tilde "$HERE").
main.go and go.mod belong in this directory. Is this checkout complete?"

# The proxy writes its log and its model cache itself, so the paths inside main.go have
# to agree with the manifest. A mismatch would leave state in a directory uninstall never
# looks at.
if ! grep -q 'state/ccw/rc-proxy' "$HERE/main.go"; then
  die "main.go does not write to ~/.local/state/ccw/rc-proxy.
The manifest says that is where its route.log and pool-models.json live, and uninstall
removes exactly what the manifest declares. Fix the paths in main.go first, or this
install would leave state behind that nothing cleans up."
fi

GO="$(resolve_go)" || die "no go found.
  brew install go
The binary is built here rather than downloaded. An unsigned Mach-O from a GitHub
Release trips Gatekeeper and produces one identical issue per user."

[ -f "$CA_KEY" ] || die "no CA at $(tilde "$CA_KEY").
The proxy mints a leaf certificate per host from mitmproxy's CA, which holds the key and
the certificate in one file. Generate it once:
  brew install mitmproxy
  mitmdump --listen-port 39801 -q      # a few seconds, then Ctrl-C
mitmproxy is not used again after that."

[ -f "$CA_CERT" ] || die "no certificate at $(tilde "$CA_CERT").
That is the file your client trusts, and it is written alongside the CA by the same
mitmdump run."

if [ ! -f "$TOKEN_FILE" ]; then
  die "no token at $(tilde "$TOKEN_FILE").
Without one the proxy routes inference to an unroutable address instead of quietly
spending your Anthropic subscription quota on requests you meant to send elsewhere.
  mkdir -p $(tilde "$CCW_CONFIG_ROOT")
  printf '%s' 'YOUR_POOL_TOKEN' > $(tilde "$TOKEN_FILE")
  chmod 600 $(tilde "$TOKEN_FILE")"
fi
[ -s "$TOKEN_FILE" ] || die "$(tilde "$TOKEN_FILE") is empty."

MODE="$(stat -f '%Lp' "$TOKEN_FILE")"
if [ "$MODE" != "600" ]; then
  warn "$(tilde "$TOKEN_FILE") is mode $MODE. It holds a credential.
  chmod 600 $(tilde "$TOKEN_FILE")"
fi

# ---- refuse on a colliding agent or a busy port ------------------------------

collect_lines COLLIDE < <(colliding_agents 'rc.?proxy')
if [ "${#COLLIDE[@]}" -gt 0 ]; then
  say "Another launchd agent is already running a proxy:"
  for label in "${COLLIDE[@]}"; do
    say "  $label"
  done
  die "Boot it out first, then run this again:
  launchctl bootout gui/\$(id -u)/${COLLIDE[0]}
  rm -f ~/Library/LaunchAgents/${COLLIDE[0]}.plist"
fi

PORT="${LISTEN##*:}"
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  say "Something is already listening on port $PORT:"
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN | sed 's/^/  /'
  die "Stop it first. Starting a second proxy on the same port fails at bind time and
the agent then respawns in a loop."
fi

# ---- the plan ---------------------------------------------------------------

plan_reset
plan_add "build    $(tilde "$BIN")"
plan_add "           $GO build, from main.go in this checkout"
plan_add "agent    $(tilde "$PLIST")"
plan_add "           KeepAlive, listens on $LISTEN"
plan_add "           reads your token from $(tilde "$TOKEN_FILE") at start, so it never"
plan_add "           goes into the plist, which is world readable"
plan_add "state    $(tilde "$STATE")"
plan_add ""
plan_add "NOT changed: ~/.claude/settings.json. The env block is printed for you to paste."
plan_show

head1 "What this does to your traffic"
say "  Every Claude Code session on this machine goes through one local process that"
say "  terminates TLS for api.anthropic.com. Requests to /v1/messages are rerouted to"
say "  your gateway with the token swapped. Everything else reaches Anthropic untouched,"
say "  carrying your real OAuth session. Non-Anthropic hosts are blind-tunneled."
say "  If this process dies while https_proxy points at it, every session fails at once."
printf '\n'

confirm "Build the proxy and load the agent?" || exit 1

# ---- build ------------------------------------------------------------------

mkdir -p "$STATE"
printf '\n'
head1 "Building"
( cd "$HERE" && "$GO" build -o claude-rc-proxy . )
say "  $(tilde "$BIN"), $(commafy "$(wc -c < "$BIN" | tr -d ' ')") bytes"
printf '\n'

# ---- agent ------------------------------------------------------------------

head1 "Agent"
PLIST_LABEL="$TOOL_AGENT_LABEL"
# bash reads the token out of the file at start. The token is never a plist value, and
# the plist is world readable.
PLIST_PROGRAM=(/bin/bash -c "CLAUDE_RC_PROXY_TOKEN=\"\$(cat '$TOKEN_FILE')\" exec '$BIN'")
PLIST_KEEPALIVE=1
PLIST_RUNATLOAD=1
PLIST_STDOUT="$STATE/launchd.out"
PLIST_STDERR="$STATE/launchd.err"
PLIST_PROCTYPE="Adaptive"
# One CONNECT per host per session, times a few dozen sessions, goes past the default.
PLIST_NOFILE=8192
if [ -n "${CLAUDE_RC_PROXY_LISTEN:-}" ]; then
  PLIST_ENV=("CLAUDE_RC_PROXY_LISTEN=$CLAUDE_RC_PROXY_LISTEN")
fi
emit_plist "$PLIST"
agent_load "$TOOL_AGENT_LABEL" "$PLIST"
say "  loaded $TOOL_AGENT_LABEL"

# Give it a moment to bind before the first probe.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s --noproxy '*' --max-time 1 "http://$LISTEN/healthz" >/dev/null 2>&1 && break
  sleep 0.5
done
health="$(curl -s --noproxy '*' --max-time 2 "http://$LISTEN/healthz" 2>/dev/null || true)"
case "$health" in
  *ok*) say "  answering on http://$LISTEN/healthz" ;;
  *) warn "no answer on http://$LISTEN/healthz yet. Check $(tilde "$STATE/launchd.err")" ;;
esac
printf '\n'

manifest_print_touched

# ---- the block you paste -----------------------------------------------------

head1 "Paste this into the env object of ~/.claude/settings.json"
say "No ANTHROPIC_BASE_URL and no ANTHROPIC_AUTH_TOKEN. Either one defeats the point:"
say "they switch off Remote Control, Artifact publishing and everything else that talks"
say "to Anthropic's own endpoints. This proxy diverts inference only, so none of that is"
say "lost."
printf '\n'
cat <<JSON
{
  "env": {
    "https_proxy": "http://$LISTEN",
    "http_proxy": "http://$LISTEN",
    "no_proxy": "localhost,127.0.0.1,::1,datadoghq.com,waditu.com,statsig.com,sentry.io",
    "NODE_EXTRA_CA_CERTS": "$CA_CERT"
  }
}
JSON
printf '\n'
say "Three things about that block."
say "  NODE_EXTRA_CA_CERTS points at mitmproxy-ca-cert.pem, the certificate alone. The"
say "  other file, mitmproxy-ca.pem, also holds the private key and is for the proxy."
say "  The path is absolute because a leading ~ is not expanded by the runtime that"
say "  reads this variable."
printf '\n'
say "  settings.json alone is not enough for the Remote Control bridge's own TLS. The"
say "  compiled binary initializes its trust store before it applies that env block. If"
say "  Remote Control fails while ordinary inference works, this is why:"
say "    launchctl setenv NODE_EXTRA_CA_CERTS \"\$HOME/.mitmproxy/mitmproxy-ca-cert.pem\""
say "  then restart VS Code. Keep the settings.json entry as well."
printf '\n'
say "  Every process Claude Code spawns inherits these. Each Bash tool call, curl, pip,"
say "  npm and git goes through the same local process."
printf '\n'

head1 "Then check it"
say "  ./cc-kit status rc-proxy"
printf '\n'
head1 "Undo by hand, if this checkout is ever gone"
cat <<UNDO
  # remove the four env keys from ~/.claude/settings.json FIRST, or every session
  # on this machine fails to connect the moment the proxy stops listening
  launchctl bootout gui/\$(id -u)/$TOOL_AGENT_LABEL
  rm -f $(tilde "$PLIST")
  rm -rf $(tilde "$STATE") $(tilde "$TOKEN_FILE")
UNDO
