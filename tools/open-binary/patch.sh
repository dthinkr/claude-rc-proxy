#!/bin/bash
#
# Make binary file links in the Claude Code VS Code chat panel do something when you
# click them, and reveal every clicked file in the Explorer sidebar.
#
# This is the file the launchd agent runs. It is deliberately self-contained: it does
# not source lib/common.sh, because a launchd job that depends on more of the checkout
# has more ways to fail silently after a bad git pull.
#
# WHAT IS BROKEN UPSTREAM
#
# The extension's openFile does revealInExplorer for directories and, for everything
# else, calls showTextDocument with a success callback and no rejection handler.
# showTextDocument first awaits workspace.openTextDocument, which rejects at the
# document-model stage for any file whose first 512 bytes contain a NUL byte. No editor
# is ever created and the rejection is swallowed, so the click does nothing at all.
# Issue #37989, filed 2026-03-23, guessed this and named the fix. Credit is theirs.
#
# WHY v2 LOOKS LIKE THIS
#
# v1 added a failure callback to the existing .then(). That bet on showTextDocument
# rejecting in a way the callback could see, which was never verified and did not work.
# v2 does not depend on VS Code's failure behavior at all: it reads the first 512 bytes
# itself, and if any of them is NUL it hands the uri straight to vscode.open and never
# calls showTextDocument. The failure callback stays as a second line of defense for a
# binary file whose first 512 bytes happen to carry no NUL.
#
# A PDF whose header is plain ASCII carries no NUL and still takes the text path, where
# it opens as a garbage text tab. Some PDFs do carry a NUL in the first 512 bytes and
# those are caught here and open correctly. The condition is the NUL, not the format.
# The stock VS Code setting for PDFs is an editorAssociations entry, see the tool README.
#
# HOW IT FINDS THE FUNCTION
#
# By structure, not by name. The bundle is minified and the names change between
# releases, so the anchor is the isDirectory check, whose shape also yields the four
# minified names the injected code needs: fs, the path variable, the vscode namespace
# and the uri variable.
#
# GUARDS
#
#   idempotent   already on v2, the file is skipped. Carrying an older marker, the
#                backup is restored first and v2 is applied to the clean bundle.
#   backup       the pristine bundle is copied to extension.js.ccw-open-binary.bak
#                before the first write for that version. The name carries a tool
#                prefix because bare .bak names collide: two other scripts on the
#                author's machine both write webview/index.css.bak.
#   node --check runs on the patched file. On failure the backup is restored.
#   no node      refuse. Nothing is written and the run is logged SKIP. An unverified
#                edit to the file that runs your editor is not a smaller risk than
#                doing nothing.
#   lock         one run at a time. The agent fires on a WatchPaths event and a person
#                can run install.sh in the same second, and both do read-modify-write
#                on one file.
#
# Takes effect only after Developer: Reload Window or Developer: Restart Extension Host.
# Restarting the Claude Code session does not reload extension.js.
#
# Usage:
#   patch.sh                    patch every installed bundle, log to the state dir
#   patch.sh --file PATH        patch this one file only, no backup, no logging.
#                               diff.sh uses this on a temp copy.
#   patch.sh --click-log        force the per-click runtime log on for this run
#   patch.sh --no-click-log     force it off for this run
#   patch.sh --quiet            no stdout, the log file still gets its line

set -u

MARK_V2="OPEN-BINARY-FALLBACK-PATCH-v2"
MARK_ANY="OPEN-BINARY-FALLBACK-PATCH"
BAK_SUFFIX="ccw-open-binary.bak"

STATE="${CCW_STATE_ROOT:-$HOME/.local/state/ccw}/open-binary"
LOG="$STATE/patch.log"
RUNTIME_LOG="$STATE/runtime.log"
CLICK_FLAG="$STATE/click-log.on"
LOCK="$STATE/patch.lock"

TARGET=""
DO_LOG=1
QUIET=0
CLICK_LOG="auto"

while [ $# -gt 0 ]; do
  case "$1" in
    --file) TARGET="${2:-}"; DO_LOG=0; shift 2 ;;
    --click-log) CLICK_LOG="on"; shift ;;
    --no-click-log) CLICK_LOG="off"; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "patch.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

[ -n "$TARGET" ] && [ ! -f "$TARGET" ] && { echo "patch.sh: no such file: $TARGET" >&2; exit 2; }

ts() { date "+%Y-%m-%d %H:%M:%S"; }

note() {
  # note STATUS MESSAGE [PATH]
  local status="$1" msg="$2" path="${3:-}"
  local line
  line="$(printf '%s  %-5s %s %s' "$(ts)" "$status" "$msg" "$path")"
  [ "$QUIET" = 1 ] || printf '%s\n' "$line"
  if [ "$DO_LOG" = 1 ]; then
    mkdir -p "$STATE" 2>/dev/null
    printf '%s\n' "$line" >> "$LOG" 2>/dev/null
  fi
}

# ---- node, by absolute path -------------------------------------------------
#
# launchd runs jobs with a PATH that has no /opt/homebrew/bin. Calling node bare made
# node --check fail with command-not-found, so this script rolled its own patch back on
# every agent run while working perfectly by hand. Four FAIL lines in 31 seconds on
# 2026-09-03 before that was understood. Resolve every interpreter by absolute path.
NODE=""
for cand in /opt/homebrew/bin/node /usr/local/bin/node "$(command -v node 2>/dev/null)"; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then NODE="$cand"; break; fi
done

PYTHON=""
for cand in /usr/bin/python3 /opt/homebrew/bin/python3 "$(command -v python3 2>/dev/null)"; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then PYTHON="$cand"; break; fi
done

if [ -z "$PYTHON" ]; then
  note SKIP "no python3 found, nothing was changed"
  exit 3
fi
if [ -z "$NODE" ]; then
  note SKIP "no node found, so node --check cannot run. Nothing was changed. brew install node, or see docs/launchd-notes.md"
  exit 3
fi

# ---- click log --------------------------------------------------------------
# Off by default. install.sh --click-log writes the flag file; install.sh without it
# removes the flag file. The plist carries no arguments, so the agent picks the current
# setting up from disk.
case "$CLICK_LOG" in
  on)  RT="$RUNTIME_LOG" ;;
  off) RT="" ;;
  *)   if [ -f "$CLICK_FLAG" ]; then RT="$RUNTIME_LOG"; else RT=""; fi ;;
esac
[ -n "$RT" ] && mkdir -p "$(dirname "$RT")" 2>/dev/null

# ---- lock -------------------------------------------------------------------
# mkdir is the atomic primitive available in a plain bash script. A lock older than five
# minutes is stale by definition: a normal run takes well under a second.
LOCK_HELD=0
if [ -z "$TARGET" ]; then
  mkdir -p "$STATE" 2>/dev/null
  if [ -d "$LOCK" ]; then
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
      rm -rf "$LOCK"
    fi
  fi
  tries=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 30 ]; then
      note SKIP "another patch.sh has held the lock for 30 seconds, giving up"
      exit 3
    fi
    sleep 1
  done
  LOCK_HELD=1
fi
cleanup() { [ "$LOCK_HELD" = 1 ] && rm -rf "$LOCK"; }
trap cleanup EXIT INT TERM

# ---- the patch itself -------------------------------------------------------

apply_to() {
  # apply_to FILE RUNTIME_LOG_PATH -> 0 patched, 3 anchor missing, other on error.
  MARK="$MARK_V2" RUNTIME_LOG="$2" "$PYTHON" - "$1" <<'PY'
import os, re, sys

path = sys.argv[1]
mark = os.environ["MARK"]
rt = os.environ.get("RUNTIME_LOG", "")
src = open(path, encoding="utf-8", errors="surrogateescape").read()

anchor = src.find("async openFile(")
if anchor == -1:
    print("NOANCHOR openFile"); sys.exit(3)

window = src[anchor:anchor + 3000]

# This one shape yields all four minified names: fs, the path variable, the vscode
# namespace and the uri variable. That is why the anchor is the isDirectory check and
# not the function name.
dir_re = re.compile(
    r'try\{if\((?P<fs>[A-Za-z_$][\w$]*)\.statSync\((?P<p>[A-Za-z_$][\w$]*)\)\.isDirectory\(\)\)\{'
    r'(?P<vs>[A-Za-z_$][\w$]*)\.commands\.executeCommand\("revealInExplorer",(?P<uri>[A-Za-z_$][\w$]*)\);'
    r'return\}\}catch\{\}'
)
m = dir_re.search(window)
if not m:
    print("NOANCHOR isDirectory"); sys.exit(3)

FS, P, VS, URI = m.group("fs"), m.group("p"), m.group("vs"), m.group("uri")

probe = ""
if rt:
    probe = ('try{%s.appendFileSync(%r,new Date().toISOString()+"  bin="+__ccBin+"  "+%s+"\\n")}catch{}'
             % (FS, rt, P))

inject = (
    "/*" + mark + "*/try{"
    "let __ccBin=(()=>{try{"
    "let __f=" + FS + ".openSync(" + P + ',"r");'
    "try{let __u=Buffer.alloc(512),__n=" + FS + ".readSync(__f,__u,0,512,0);"
    "return __u.subarray(0,__n).includes(0)}"
    "finally{" + FS + ".closeSync(__f)}"
    "}catch{try{return " + FS + ".readFileSync(" + P + ").subarray(0,512).includes(0)}catch{return !1}}})();"
    + probe +
    VS + '.commands.executeCommand("revealInExplorer",' + URI + ");"
    "if(__ccBin){" + VS + '.commands.executeCommand("vscode.open",' + URI + ");return}"
    "}catch{}"
)

# Edit 1: after the directory check, sniff for a NUL, reveal in the Explorer, and send
# anything binary straight to vscode.open.
insert_at = anchor + m.end()
src = src[:insert_at] + inject + src[insert_at:]

# Edit 2: wrap the original showTextDocument in a catch, for a binary file that carries
# no NUL in its first 512 bytes. Returning a promise that never settles stops the
# original success callback from running against an editor that does not exist.
show_re = re.compile(re.escape(VS) + r"\.window\.showTextDocument\(" + re.escape(URI) + r"\)")
m2 = show_re.search(src, insert_at)
if not m2:
    print("NOANCHOR showTextDocument"); sys.exit(3)
wrapped = ("Promise.resolve(" + m2.group(0) + ").catch(()=>{"
           + VS + '.commands.executeCommand("vscode.open",' + URI + ");"
           "return new Promise(()=>{})})")
src = src[:m2.start()] + wrapped + src[m2.end():]

open(path, "w", encoding="utf-8", errors="surrogateescape").write(src)
print("PATCHED vscode=%s fs=%s path=%s uri=%s" % (VS, FS, P, URI))
PY
}

patch_one() {
  local js="$1" bak="$1.$BAK_SUFFIX"
  local managed=1
  [ -n "$TARGET" ] && managed=0        # temp copy handed to us, caller owns the backup

  if grep -q "$MARK_V2" "$js" 2>/dev/null; then
    note OK "already applied, nothing to do" "$js"
    return 0
  fi

  if grep -q "$MARK_ANY" "$js" 2>/dev/null; then
    if [ "$managed" = 1 ] && [ -f "$bak" ]; then
      cp "$bak" "$js"
      note RESET "older marker found, restored from backup before applying" "$js"
    else
      note SKIP "an older marker is in the file and there is no backup to restore, refusing to edit it again" "$js"
      return 3
    fi
  fi

  if [ "$managed" = 1 ]; then
    [ -f "$bak" ] || cp "$js" "$bak"
  fi

  local out rc
  out="$(apply_to "$js" "$RT")"
  rc=$?

  if [ "$rc" -eq 3 ]; then
    # The anchor did not match. openFile has been restructured, or this is not the
    # bundle we think it is. Nothing was written.
    note SKIP "anchor did not match ($out), nothing changed" "$js"
    return 3
  elif [ "$rc" -ne 0 ]; then
    [ "$managed" = 1 ] && [ -f "$bak" ] && cp "$bak" "$js"
    note FAIL "patch script errored (rc=$rc), restored from backup" "$js"
    return 1
  fi

  if "$NODE" --check "$js" >/dev/null 2>&1; then
    note OK "patched, node --check passed" "$js"
    return 0
  fi

  [ "$managed" = 1 ] && [ -f "$bak" ] && cp "$bak" "$js"
  note FAIL "node --check failed, rolled back" "$js"
  return 1
}

# ---- drive ------------------------------------------------------------------

worst=0

if [ -n "$TARGET" ]; then
  patch_one "$TARGET"
  exit $?
fi

found=0
for JS in "$HOME"/.vscode/extensions/anthropic.claude-code-*/extension.js; do
  [ -f "$JS" ] || continue
  found=1
  patch_one "$JS"
  rc=$?
  [ "$rc" -gt "$worst" ] && worst=$rc
done

if [ "$found" = 0 ]; then
  note SKIP "no anthropic.claude-code extension directory found under ~/.vscode/extensions"
  exit 3
fi

exit "$worst"
