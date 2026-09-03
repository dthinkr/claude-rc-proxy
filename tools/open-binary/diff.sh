#!/bin/bash
#
# Show the patch without applying it.
#
# Copies your installed extension.js to a temp file, patches the copy, runs node --check
# on the copy, and prints the openFile function before and after with the injected
# region marked. Nothing under ~/.vscode/extensions is touched, and the temp file is
# removed on the way out.
#
# The bundle is minified, so openFile is a few hundred characters of one very long line.
# Both sides are wrapped for reading. What lands in the file is one line.
#
# Usage:
#   ./cc-kit diff open-binary
#   tools/open-binary/diff.sh --version 2.1.259     pick one installed version
#   tools/open-binary/diff.sh --click-log           show it with the per-click log on

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CCW_ROOT="$(cd "$HERE/../.." && pwd)"
export CCW_ROOT
# shellcheck source=lib/common.sh
. "$CCW_ROOT/lib/common.sh"

require_macos

WANT_VERSION=""
PATCH_ARGS=(--no-click-log)
while [ $# -gt 0 ]; do
  case "$1" in
    --version) WANT_VERSION="${2:-}"; shift 2 ;;
    --click-log) PATCH_ARGS=(--click-log); shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done

PYTHON="$(resolve_python3)" || die "no python3 found. macOS ships one at /usr/bin/python3."

# show_openfile FILE [--mark]
#
# Print the openFile function, wrapped. With --mark, put a marker line around the region
# this repo injected.
show_openfile() {
  "$PYTHON" - "$@" <<'PY'
import re, sys, textwrap

path = sys.argv[1]
mark = "--mark" in sys.argv[2:]
src = open(path, encoding="utf-8", errors="surrogateescape").read()

i = src.find("async openFile(")
if i == -1:
    sys.exit("openFile not found in this bundle. The anchor would not match either.")

# Walk the braces from the function's opening one so the slice is the whole function and
# nothing after it. Strings and regex literals in minified code can carry braces, so this
# is approximate; it is for reading, not for editing.
start = src.index("{", i)
depth, j = 0, start
while j < len(src):
    c = src[j]
    if c == "{":
        depth += 1
    elif c == "}":
        depth -= 1
        if depth == 0:
            j += 1
            break
    j += 1
body = src[i:j]

MARKER = "/*OPEN-BINARY-FALLBACK-PATCH-v2*/"
if mark and MARKER in body:
    a = body.index(MARKER)
    # The injected region contains more than one }catch{} when the click log is on, so
    # anchor the end on the binary branch rather than on the first catch after the start.
    k = body.index("if(__ccBin){", a)
    b = body.index("}catch{}", k) + len("}catch{}")
    parts = [("plain", body[:a]), ("added", body[a:b]), ("plain", body[b:])]
else:
    parts = [("plain", body)]

for kind, text in parts:
    if not text:
        continue
    if kind == "added":
        print("--- injected by this repo, starts ---")
    for line in textwrap.wrap(text, 96, break_long_words=True,
                              break_on_hyphens=False, drop_whitespace=False):
        print(("| " if kind == "added" else "  ") + line)
    if kind == "added":
        print("--- injected by this repo, ends ---")
PY
}

collect_lines DIRS < <(claude_ext_dirs || true)
[ "${#DIRS[@]}" -gt 0 ] || die "no anthropic.claude-code extension found under ~/.vscode/extensions.
Install the Claude Code extension in VS Code first."

TARGET_DIR=""
if [ -n "$WANT_VERSION" ]; then
  for d in "${DIRS[@]}"; do
    case "$(basename "$d")" in
      *"$WANT_VERSION"*) TARGET_DIR="$d"; break ;;
    esac
  done
  [ -n "$TARGET_DIR" ] || die "no installed extension directory matches $WANT_VERSION"
else
  TARGET_DIR="${DIRS[${#DIRS[@]}-1]}"
fi

JS="$TARGET_DIR/extension.js"
BAK="$JS.ccw-open-binary.bak"

SRC="$JS"
ALREADY=0
if [ -f "$BAK" ]; then
  # The installed bundle is already patched, so diff against the pristine copy taken
  # before the first patch. Patching an already-patched file would show nothing.
  SRC="$BAK"
elif grep -q "OPEN-BINARY-FALLBACK-PATCH" "$JS" 2>/dev/null; then
  # Patched, but not by an install from this checkout: there is no backup here to read
  # the original out of. Say so rather than printing a diff with nothing in it.
  ALREADY=1
fi

# The copy has to be named *.js. `mktemp -t ccw-open-binary` produces a name ending in a
# random suffix after a dot, and node reads that as an unknown file extension and refuses
# to parse the file at all: ERR_UNKNOWN_FILE_EXTENSION. patch.sh then saw node --check
# fail and rolled back, so this command reported a failure on every run against a bundle
# that patches perfectly well. A temp directory with a fixed filename inside it avoids the
# whole question.
TMPD="$(mktemp -d -t ccw-open-binary)"
TMP="$TMPD/extension.js"
trap 'rm -rf "$TMPD"' EXIT INT TERM
cp "$SRC" "$TMP"

head1 "Bundle"
say "  $JS"
say "  version $(ext_version "$TARGET_DIR"), $(wc -c < "$JS" | tr -d ' ') bytes"
if [ "$SRC" = "$BAK" ]; then
  say "  already patched, so this is a diff against the backup taken before the first patch"
fi
if [ "$ALREADY" = 1 ]; then
  printf '\n'
  warn "this bundle already carries the patch marker, and there is no
$(basename "$BAK") next to it. Something other than an install from this checkout
applied it, so there is no clean copy here to diff against. What follows is the patched
bundle on both sides and a delta of zero. To see a real diff, restore the bundle from
whatever backup that other tool left, or reinstall the extension in VS Code."
fi
printf '\n'

head1 "openFile before"
show_openfile "$TMP"
printf '\n'

head1 "Patching a temp copy"
say "  $TMP"
# patch.sh exits 3 when the anchor does not match, which is the single most useful thing
# this command can tell you. Under set -e that exit killed diff.sh before it printed
# anything, so a reader trying to find out whether the patch still applies got silence.
set +e
"$CCW_ROOT/tools/open-binary/patch.sh" --file "$TMP" "${PATCH_ARGS[@]}"
patch_rc=$?
set -e
if [ "$patch_rc" = 3 ]; then
  printf '\n'
  say "The anchor did not match, so there is nothing to show and nothing to install."
  say "That means the openFile handler in your installed bundle is not the shape this"
  say "patch expects. Either the extension changed, or you are on a build this has not"
  say "been tested against. Open an issue with your extension version."
  exit 3
elif [ "$patch_rc" != 0 ]; then
  printf '\n'
  die "patch.sh exited $patch_rc against a temp copy. Nothing on your machine changed."
fi
printf '\n'

head1 "openFile after"
show_openfile "$TMP" --mark
printf '\n'

BEFORE=$(wc -c < "$SRC" | tr -d ' ')
AFTER=$(wc -c < "$TMP" | tr -d ' ')
say "$((AFTER - BEFORE)) bytes added to a $BEFORE byte bundle. Two edits, one function."
say "Nothing under ~/.vscode/extensions was touched."
say "To apply it for real: ./cc-kit install open-binary"
