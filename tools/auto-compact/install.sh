#!/bin/bash
#
# Install the stdin shim, and the daemon that uses it.
#
# Everything runs out of this checkout. The VS Code setting and the launchd plist both
# point at absolute paths inside the clone, so moving or deleting the clone breaks both
# and git pull is the whole update procedure.
#
# Two separate things get installed:
#
#   the shim    a wrapper VS Code launches instead of the Claude Code binary. It execs
#               the real binary unchanged and opens one unix socket onto its stdin.
#               One VS Code user setting, claudeCode.claudeProcessWrapper.
#   the daemon  a launchd agent that reads session transcripts every 120 seconds and
#               sends /compact through that socket when a session is idle with a warm
#               cache. One plist.
#
# --shim-only installs the first and not the second, which is the whole tool if you
# want the side channel for something else.
#
# Usage:
#   ./cc-kit install auto-compact
#   ./cc-kit install auto-compact --shim-only
#   ./cc-kit install auto-compact --yes            no confirmation prompt
#   ./cc-kit install auto-compact --force          install past the cache-tier refusal
#
# Tuning carries into the plist. Any of CC_COMPACT_CTX, CC_COMPACT_IDLE_MIN,
# CC_COMPACT_IDLE_MAX, CC_COMPACT_CEILINGS and CC_INJECT_DIR that are set in this
# shell's environment are written into the agent's EnvironmentVariables, because a
# launchd job does not inherit your shell:
#
#   CC_COMPACT_CTX=300000 ./cc-kit install auto-compact

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

SHIM_ONLY=0
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --shim-only) SHIM_ONLY=1; shift ;;
    --yes|-y) CCW_ASSUME_YES=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done

SHIM="$HERE/shim/cc-stdin-shim"
DAEMON="$HERE/compactd.py"
# Not state_dir here: nothing is created before the plan is shown and confirmed.
STATE="$CCW_STATE_ROOT/auto-compact"
PLIST="$HOME/Library/LaunchAgents/$TOOL_AGENT_LABEL.plist"
SETTING_KEY="claudeCode.claudeProcessWrapper"

# ---- prerequisites, named ----------------------------------------------------

PYTHON="$(resolve_bin python3 /usr/bin/python3)" \
  || die "no python3 at /usr/bin/python3. The shim's shebang is #!/usr/bin/python3 and
the launchd agent runs the daemon with the same interpreter, so the macOS one is what
both need. Check: xcode-select --install"

[ -f "$SHIM" ] || die "no shim at $SHIM. Is this checkout complete?"
[ -f "$DAEMON" ] || die "no daemon at $DAEMON. Is this checkout complete?"
chmod +x "$SHIM" "$DAEMON" 2>/dev/null || true

collect_lines VSDIRS < <(vscode_user_dirs)
[ "${#VSDIRS[@]}" -gt 0 ] || die "no VS Code user settings directory found.
Looked for:
  ~/Library/Application Support/Code/User
  ~/Library/Application Support/Code - Insiders/User
Start VS Code once so it writes its settings, then run this again."

# ---- refuse on a colliding agent --------------------------------------------

collect_lines COLLIDE < <(colliding_agents 'auto.?compact')
if [ "${#COLLIDE[@]}" -gt 0 ]; then
  say "Another launchd agent is already running a compaction daemon:"
  for label in "${COLLIDE[@]}"; do
    say "  $label"
  done
  die "Two daemons send /compact to the same sessions and you pay for both summaries.
Boot the other one out first:
  launchctl bootout gui/\$(id -u)/${COLLIDE[0]}
  rm -f ~/Library/LaunchAgents/${COLLIDE[0]}.plist
If it carried EnvironmentVariables you want to keep, copy them out of that plist first
and pass them to this installer. This one writes what it finds in its own environment."
fi

# ---- refuse on a foreign wrapper --------------------------------------------
#
# claudeCode.claudeProcessWrapper holds exactly one program. Overwriting somebody else's
# takes their tool out of the launch path without telling them.
for dir in "${VSDIRS[@]}"; do
  s="$dir/settings.json"
  [ -f "$s" ] || continue
  current="$("$PYTHON" - "$s" "$SETTING_KEY" <<'PY'
import json, sys
try:
    cfg = json.loads(open(sys.argv[1], encoding="utf-8").read())
except Exception:
    sys.exit(0)
v = cfg.get(sys.argv[2])
if isinstance(v, str):
    print(v)
PY
)"
  if [ -n "$current" ] && [ "$current" != "$SHIM" ]; then
    die "$s already sets $SETTING_KEY to
  $current
That is not this checkout's shim. Remove it yourself first if you want this one instead.
Overwriting it would take whatever wrote it out of the launch path silently."
  fi
done

# ---- the cache-tier gate -----------------------------------------------------
#
# The shipped window fires between 50 and 58 minutes idle, which only makes sense on a
# 1-hour cache tier. On a 5-minute tier it is wrong by an order of magnitude and the
# daemon looks broken rather than useless.
if [ "$SHIM_ONLY" = 0 ]; then
  set +e
  "$HERE/status.sh" --cache-tier
  tier_rc=$?
  set -e
  if [ "$tier_rc" -ne 0 ] && [ "$FORCE" = 0 ]; then
    die "Refusing to install the daemon on this account.
Either install the side channel alone:
  ./cc-kit install auto-compact --shim-only
or set bounds that match your tier and install past this check:
  CC_COMPACT_IDLE_MIN=180 CC_COMPACT_IDLE_MAX=280 ./cc-kit install auto-compact --force
The two bounds are seconds of idle time. Read tools/auto-compact/README.md first."
  fi
  [ "$tier_rc" -ne 0 ] && warn "installing past the cache-tier check because --force was given"
  printf '\n'
fi

# ---- carry tuning into the plist --------------------------------------------

PLIST_ENV=()
for var in CC_COMPACT_CTX CC_COMPACT_IDLE_MIN CC_COMPACT_IDLE_MAX CC_COMPACT_CEILINGS CC_INJECT_DIR; do
  if [ -n "${!var:-}" ]; then
    PLIST_ENV+=("$var=${!var}")
  fi
done

# ---- the plan ---------------------------------------------------------------

plan_reset
for dir in "${VSDIRS[@]}"; do
  s="$dir/settings.json"
  if [ -f "$s" ]; then
    plan_add "setting  $(tilde "$s")"
    plan_add "           add \"$SETTING_KEY\": \"$SHIM\""
    plan_add "           a timestamped backup is written next to it first"
  else
    plan_add "setting  $(tilde "$s") does not exist yet, it will be created"
  fi
done
if [ "$SHIM_ONLY" = 0 ]; then
  plan_add ""
  plan_add "agent    $(tilde "$PLIST")"
  plan_add "           runs $(tilde "$DAEMON") every 120 seconds"
  plan_add "state    $(tilde "$STATE")"
  if [ "${#PLIST_ENV[@]}" -gt 0 ]; then
    for kv in "${PLIST_ENV[@]}"; do
      plan_add "           EnvironmentVariables: $kv"
    done
  fi
else
  plan_add ""
  plan_add "no agent, no daemon. --shim-only was given."
fi
plan_show

confirm "Change how VS Code launches Claude Code?" || exit 1

# ---- write ------------------------------------------------------------------

mkdir -p "$STATE"
printf '\n'
head1 "VS Code setting"
for dir in "${VSDIRS[@]}"; do
  s="$dir/settings.json"
  if [ -f "$s" ]; then
    bak="$(backup_file "$s")"
    say "  backup $(tilde "$bak")"
  else
    mkdir -p "$dir"
    printf '{}\n' > "$s"
    say "  created $(tilde "$s")"
  fi
  "$PYTHON" - "$s" "$SHIM" "$SETTING_KEY" <<'PY'
import json, sys
path, shim, key = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(path, encoding="utf-8").read()
try:
    cfg = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(f"  {path} is not plain JSON, probably because it has comments in it.\n"
             f"  Nothing was changed. Add this key by hand:\n"
             f'      "{key}": "{shim}"')
if cfg.get(key) == shim:
    print(f"  already set: {path}")
    sys.exit(0)
cfg[key] = shim
open(path, "w", encoding="utf-8").write(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print(f"  set {key} in {path}")
PY
done
printf '\n'

if [ "$SHIM_ONLY" = 1 ]; then
  manifest_print_touched
  head1 "Shim only. No daemon, nothing fires on its own."
  say "Restart a Claude Code session, then:"
  say "  ls /tmp/cc-inject/                       one socket per session that picked it up"
  say "  echo /compact | nc -U /tmp/cc-inject/<pid>.sock"
  exit 0
fi

head1 "Agent"
PLIST_LABEL="$TOOL_AGENT_LABEL"
PLIST_PROGRAM=("$PYTHON" "$DAEMON")
PLIST_INTERVAL=120           # the firing window is 8 minutes wide, so 2-minute polling never misses it
PLIST_RUNATLOAD=1
PLIST_STDOUT="$STATE/launchd.out"
PLIST_STDERR="$STATE/launchd.err"
PLIST_PROCTYPE="Background"
emit_plist "$PLIST"
agent_load "$TOOL_AGENT_LABEL" "$PLIST"
say "  loaded $TOOL_AGENT_LABEL, runs every 120 seconds"
printf '\n'

manifest_print_touched

head1 "Sessions already running keep their old process"
say "Restart one before you check anything, or it will report as having no side channel."
printf '\n'
say "  ./cc-kit status auto-compact"
say "  $(tilde "$DAEMON") --status      per-session verdict"
say "  $(tilde "$DAEMON") --dry-run     decide and log, send nothing"
printf '\n'
head1 "Undo by hand, if this checkout is ever gone"
cat <<UNDO
  launchctl bootout gui/\$(id -u)/$TOOL_AGENT_LABEL
  rm -f $(tilde "$PLIST")
  # then remove "$SETTING_KEY" from your VS Code settings.json
  rm -rf $(tilde "$STATE")
UNDO
