#!/bin/bash
#
# Count NUL bytes in the first 512 bytes of each file you name, and say what the Claude
# Code chat panel does with a link to it.
#
# The rule the patch implements: a file whose first 512 bytes contain at least one NUL
# never reaches an editor, so clicking its link does nothing at all. Zero NULs means the
# link takes the text path, which opens the file, correctly for text and as a garbage
# tab for anything else.
#
# The count is a property of the individual file, not of its format. Measured across 14
# real files per format on the author's machine: PNG ranged 15 to 225, JPG 39 to 274,
# XLSX 29 to 467, DOCX 15 to 467, GIF 3 to 456. Most PDFs carry zero, and a few carry
# one, two or four. So run this on your own files rather than trusting a table.
#
# Usage:
#   ./cc-kit nul-scan FILE...
#   ./cc-kit nul-scan ~/Downloads/*.pdf ~/Desktop/*.png

set -u

if [ $# -eq 0 ]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

PYTHON=""
for cand in /usr/bin/python3 /opt/homebrew/bin/python3 "$(command -v python3 2>/dev/null)"; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then PYTHON="$cand"; break; fi
done
[ -n "$PYTHON" ] || { echo "nul-scan: no python3 found" >&2; exit 1; }

"$PYTHON" - "$@" <<'PY'
import os, sys

rows = []
for path in sys.argv[1:]:
    if os.path.isdir(path):
        rows.append((path, None, "directory, revealed in the Explorer, no editor"))
        continue
    try:
        with open(path, "rb") as fh:
            head = fh.read(512)
    except OSError as exc:
        rows.append((path, None, f"unreadable: {exc.strerror}"))
        continue
    n = head.count(0)
    if n:
        verdict = "does nothing without the patch, opens with it"
    else:
        verdict = "takes the text path, opens either way"
    rows.append((path, n, verdict))

width = max((len(os.path.basename(p)) for p, _, _ in rows), default=4)
width = min(max(width, 4), 44)
print(f"{'file'.ljust(width)}  {'NUL':>4}  verdict")
for path, n, verdict in rows:
    name = os.path.basename(path)
    if len(name) > width:
        name = name[: width - 2] + ".."
    count = "  -" if n is None else f"{n:>4}"
    print(f"{name.ljust(width)}  {count}  {verdict}")

counted = [n for _, n, _ in rows if n is not None]
if counted:
    blocked = sum(1 for n in counted if n)
    print(f"\n{blocked} of {len(counted)} files carry a NUL in their first 512 bytes.")
PY
