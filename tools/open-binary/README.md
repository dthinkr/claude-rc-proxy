# I click a PNG in the Claude Code chat panel and nothing happens

No error. No tab. No notification. Nothing in the output channel. Click a `.md` file on the line
above it and that opens fine.

`open-binary` patches the extension bundle so those clicks open the file. It also reveals every
clicked file in the Explorer sidebar. The extension already did that for directories only.

Measured on macOS 27.0, VS Code 1.135.0, `anthropic.claude-code` 2.1.259, Node 26.8.1. Everything
below that names a version was read out of those builds on 2026-09-03.

- [What is actually happening](#what-is-actually-happening)
- [The NUL rule](#the-nul-rule)
- [The one-byte repro](#the-one-byte-repro)
- [Measurements you can reproduce](#measurements-you-can-reproduce)
- [What the patch changes](#what-the-patch-changes)
- [Read the patch before you install it](#read-the-patch-before-you-install-it)
- [Install](#install)
- [Is it still there](#is-it-still-there)
- [Uninstall](#uninstall)
- [The launchd self-heal](#the-launchd-self-heal)
- [The launchd PATH gotcha](#the-launchd-path-gotcha)
- [The click log](#the-click-log)
- [What this does not fix](#what-this-does-not-fix)
- [When it breaks](#when-it-breaks)
- [Credit](#credit)

---

## What is actually happening

The extension host calls `openFile` when you click a file link in the chat panel. Here is the tail
of that function in 2.1.259, as shipped. The minified names are `_$` for the `vscode` namespace,
`K5` for `fs`, `J` for the resolved path and `X` for the URI.

```js
let X=_$.Uri.file(J);
try{if(K5.statSync(J).isDirectory()){_$.commands.executeCommand("revealInExplorer",X);return}}catch{}
_$.window.showTextDocument(X).then((z)=>{ /* jump to line, or select searchText */ })
```

`showTextDocument` has a success callback and no rejection handler. It awaits
`workspace.openTextDocument` first, and that rejects at the document-model stage for any file VS
Code decides is binary. No editor is ever created. The rejection lands on a promise nobody is
watching, so it is swallowed. The click does nothing at all, and there is nothing to find in a log.

Directories already worked, because the `isDirectory` branch above returns early through
`revealInExplorer`.

## The NUL rule

**The discriminator is a NUL byte in the first 512 bytes. It is not the file extension and it is
not the MIME type.**

The rule belongs to VS Code. The extension's part is failing to handle the result. In VS Code 1.135.0
the encoding detector scans the first `512` bytes for zero bytes, once, and that window size is a
constant in the build. It sets `seemsBinary` when it finds a zero byte and the zero bytes do not
fall in a strict alternating pattern. The two alternating patterns are UTF-16 LE (zeros at odd offsets) and UTF-16 BE (zeros at
even offsets), and both are treated as text. The decode path then throws:

```js
if(p.seemsBinary&&o.acceptTextOnly)throw new mHi("Stream is binary but only text is accepted for decoding",1)
```

That throw is the rejection the extension never handles.

Three consequences follow, and they explain most of the confusion in the upstream issues.

1. Two files of the same format can behave differently. The count is a property of the individual
   file.
2. A binary file whose first 512 bytes happen to be NUL-free takes the text path and opens as a tab
   of garbage. That is why some people report "it opens something useless" and others report "it
   does nothing", for the same extension.
3. A UTF-16 text file has plenty of NUL bytes and still opens, because of the alternating-pattern
   exemption. `nul-scan.sh` reports raw counts and does not model that exemption. Neither does the
   patch. See [What this does not fix](#what-this-does-not-fix).

## The one-byte repro

Two 600-byte files. Same extension, same size, identical except for byte 11.

```sh
python3 - <<'PY'
b = bytearray(b'A' * 600)
open('opens.bin', 'wb').write(bytes(b))
b[10] = 0
open('inert.bin', 'wb').write(bytes(b))
PY
cmp -l opens.bin inert.bin
```

```
   11 101   0
```

Link both from the chat panel. `opens.bin` opens as a tab of 600 A characters. `inert.bin` does
nothing. One byte decides it.

## Measurements you can reproduce

The table below counts NUL bytes in the first 512 bytes of files that ship inside the extension
itself, so anyone on 2.1.259 gets these exact numbers.

```sh
cd ~/.vscode/extensions/anthropic.claude-code-2.1.259-darwin-arm64
~/code/claude-code-workarounds/cc-kit nul-scan resources/claude-logo.png resources/PlanMode.jpg package.json
```

| File shipped with the extension | Size | NULs in first 512 B | Without the patch |
|---|---:|---:|---|
| `resources/claude-logo.png` | 10,358 | 14 | click does nothing |
| `resources/walkthrough/welcome.png` | 112,125 | 14 | click does nothing |
| `resources/walkthrough/chat.png` | 127,137 | 17 | click does nothing |
| `resources/walkthrough/click.png` | 132,059 | 17 | click does nothing |
| `resources/ClawdWithGradCap.png` | 2,308 | 46 | click does nothing |
| `resources/PlanMode.jpg` | 128,933 | 39 | click does nothing |
| `resources/HighlightText.jpg` | 218,828 | 39 | click does nothing |
| `resources/audio-capture/arm64-darwin/audio-capture.node` | 438,064 | 354 | click does nothing |
| `resources/claude-logo.svg` | 1,696 | 0 | opens, it is text |
| `resources/welcome-art-dark.svg` | 228,426 | 0 | opens, it is text |
| `package.json` | 17,971 | 0 | opens, it is text |

The counts are measured. The last column follows from the rule above rather than from clicking all
eleven.

Five PNGs shipped by one vendor in one extension spread across 14, 17 and 46. Nothing about the
format predicts the number.

A wider sample, for shape only. On 2026-09-03 I scanned the first 400 matching files under four
directory trees on this machine, to a depth of four, skipping empty files:

| Extension | files | lowest | highest | files with zero |
|---|---:|---:|---:|---:|
| `png` | 74 | 13 | 437 | 0 |
| `db` (SQLite) | 28 | 102 | 469 | 0 |
| `pdf` | 235 | 0 | 73 | 136 |
| `csv` | 52 | 0 | 0 | 52 |

That is one person's files on one day. Do not read it as a specification, and do not build anything
on a per-format table. Scan your own:

```sh
./cc-kit nul-scan ~/Downloads/*.pdf ~/Desktop/*.png
```

PDF is the interesting row. 136 of 235 carried no NUL in the header and would take the text path.
The other 99 carried 1 to 73 and are caught by the patch. PDF behavior depends on the individual
file, and [What this does not fix](#what-this-does-not-fix) has the one-setting answer that works
for every PDF.

## What the patch changes

`patch.sh` finds `openFile` structurally. It anchors on the `isDirectory` check, which is the one
place in the function that spells out four minified names at once, so it recovers `_$`, `K5`, `J`
and `X` from the bundle instead of hardcoding them. Those four names change with every
re-minification. In 2.1.259 they are the ones above.

It then makes two edits.

**Edit 1, after the directory check.** Read the first 512 bytes. Reveal the file in the Explorer
sidebar, using the same command the extension already ran for directories. If a NUL is present, hand
the URI to `vscode.open` and return before `showTextDocument` is ever reached.

**Edit 2, around the existing call.** Wrap `showTextDocument` so a rejection routes to `vscode.open`
as well. This catches a binary file whose first 512 bytes hold no NUL and whose failure comes from
somewhere else. The catch returns a promise that never settles, on purpose, so the original
`.then` callback never runs against an editor that does not exist.

Expanded for reading, with the unchanged parts marked:

```js
let X = _$.Uri.file(J);
try { if (K5.statSync(J).isDirectory()) { _$.commands.executeCommand("revealInExplorer", X); return } } catch {}

/*OPEN-BINARY-FALLBACK-PATCH-v2*/                                   // <-- edit 1 starts
try {
  let __ccBin = (() => {
    try {
      let __f = K5.openSync(J, "r");
      try {
        let __u = Buffer.alloc(512), __n = K5.readSync(__f, __u, 0, 512, 0);
        return __u.subarray(0, __n).includes(0)
      } finally { K5.closeSync(__f) }
    } catch {
      try { return K5.readFileSync(J).subarray(0, 512).includes(0) } catch { return !1 }
    }
  })();
  _$.commands.executeCommand("revealInExplorer", X);
  if (__ccBin) { _$.commands.executeCommand("vscode.open", X); return }
} catch {}                                                          // <-- edit 1 ends

Promise.resolve(_$.window.showTextDocument(X)).catch(() => {        // <-- edit 2 wraps the call
  _$.commands.executeCommand("vscode.open", X);
  return new Promise(() => {})
})
.then((z) => { /* unchanged: jump to line, or select searchText */ })
```

What lands in the bundle is one line, because the bundle is minified. This is the exact text of
edit 1 on 2.1.259 with the click log off:

```
/*OPEN-BINARY-FALLBACK-PATCH-v2*/try{let __ccBin=(()=>{try{let __f=K5.openSync(J,"r");try{let __u=Buffer.alloc(512),__n=K5.readSync(__f,__u,0,512,0);return __u.subarray(0,__n).includes(0)}finally{K5.closeSync(__f)}}catch{try{return K5.readFileSync(J).subarray(0,512).includes(0)}catch{return !1}}})();_$.commands.executeCommand("revealInExplorer",X);if(__ccBin){_$.commands.executeCommand("vscode.open",X);return}}catch{}
```

Sizes on 2.1.259: 421 bytes for edit 1, 101 bytes for edit 2, 522 bytes total against a 3,214,270
byte bundle. With the click log on it is 662 bytes, and the extra 140 are the log path and the
`appendFileSync` call. Nothing else in the bundle is touched, and no other function is read.

Three guards run around the write.

- The first patch of a given version copies the bundle to
  `extension.js.ccw-open-binary.bak` in the same directory. Later runs reuse that copy.
- `node --check` runs on the patched file. If it fails, the backup is restored and the run is
  logged `FAIL`. You are never left with a broken extension.
- The marker comment makes the run idempotent. Already on v2, the file is skipped. Carrying an
  older marker, the backup is restored first and v2 is applied to the clean bundle. That path fired
  for real on this machine on 2026-09-03 at 11:02:32, on two installed versions in the same second.

If `patch.sh` cannot find a `node` to run `node --check` with, it refuses and writes `SKIP`. It does
not apply an unverified edit to the file that runs your editor. That is the repo's
refuse-rather-than-degrade rule. `./cc-kit doctor` tells you up front whether it found a Node, so
you learn about this before you install rather than from a log line afterwards.

## Read the patch before you install it

```sh
./cc-kit diff open-binary
```

That copies your installed bundle to a temp file, patches the copy, runs `node --check` on the copy,
and prints the before and after of `openFile` alone with the injected region marked. Nothing under
`~/.vscode/extensions` is touched. The output is about 40 lines. Read it, then decide.

## Install

```sh
./cc-kit install open-binary
```

Then **run `Developer: Reload Window` from the VS Code command palette**. This step is required.
`Developer: Restart Extension Host` also works. Restarting the Claude Code session does not reload
`extension.js`, and neither does starting a new chat.

`install.sh` patches every installed `anthropic.claude-code-*` directory it finds, writes
`~/Library/LaunchAgents/io.github.dthinkr.ccw.open-binary.plist`, and loads the agent. It says which
of applied, already applied or upgraded happened per version, then lists what it touched. Running it
twice is safe.

The plist points at `patch.sh` inside this checkout by absolute path. Moving or deleting the
checkout breaks the agent, and the next extension upgrade then silently removes the fix.

## Is it still there

```sh
./cc-kit status open-binary
```

Two independent questions get two answers. Whether the launchd agent is loaded, and whether the
marker is present in the bundle VS Code is running right now. A loaded agent proves nothing. By
hand:

```sh
grep -c OPEN-BINARY-FALLBACK-PATCH-v2 ~/.vscode/extensions/anthropic.claude-code-*/extension.js
```

`1` per installed version means the patch is in the file on disk. It does not mean the running
window has it. If clicks are still dead after a `1`, you have not reloaded the window.

The patch log is `~/.local/state/ccw/open-binary/patch.log`, one line per run per version, with the
outcome as the second field:

```
OK      applied, node --check passed
RESET   older marker found, restored from backup before applying
SKIP    anchor did not match, or no node, nothing changed
FAIL    node --check failed or the patch script errored, backup restored
```

## Uninstall

```sh
./cc-kit uninstall open-binary
```

That restores every backup, boots out the agent, removes the plist, and removes the state directory.
It reads the file list from `manifest.conf`, so it reverses exactly what was recorded.

By hand, if the checkout is gone or the CLI is broken:

```sh
launchctl bootout gui/$(id -u)/io.github.dthinkr.ccw.open-binary
rm -f ~/Library/LaunchAgents/io.github.dthinkr.ccw.open-binary.plist
for d in ~/.vscode/extensions/anthropic.claude-code-*/; do
  [ -f "$d/extension.js.ccw-open-binary.bak" ] && cp "$d/extension.js.ccw-open-binary.bak" "$d/extension.js"
done
rm -rf ~/.local/state/ccw/open-binary
```

Reload the window afterwards. There is a cheaper undo that costs you the backups: reinstall the
extension from the Marketplace and it writes a fresh directory.

The backup name carries a tool prefix on purpose. Bare `.bak` names collide. Two unrelated scripts
on my own machine patch `webview/index.css` in the same extension directory, both back it up to
`index.css.bak`, and both guard with `[ -f "$CSS.bak" ] || cp`. Whichever runs second backs up an
already-patched file, and restoring that one backup silently reverts both patches. See
[docs/launchd-notes.md](../../docs/launchd-notes.md).

## The launchd self-heal

Every extension upgrade replaces `extension.js` and takes the patch with it. The agent has
`WatchPaths` on `~/.vscode/extensions`, so it fires when that directory changes and re-applies within
seconds. You still have to reload the window.

`patch.sh` also takes a lock on the bundle before writing, so two agent invocations firing on the
same filesystem event cannot interleave a read-modify-write on one file.

The real risk is a restructured `openFile`. When Anthropic changes that function enough that the
`isDirectory` anchor stops matching, the script writes `SKIP`, changes nothing, and your clicks
quietly go back to doing nothing. You get a log line and no other signal.
`./cc-kit status open-binary` is how you find out. As of 2.1.259 the anchor still matches, and it has
matched across 2.1.257, 2.1.258 and 2.1.259.

## The launchd PATH gotcha

launchd runs jobs with a PATH that does not include `/opt/homebrew/bin`. The script called `node`
bare, so `node --check` failed with command-not-found, so the safety net restored the backup on every
single agent run. Restoring the backup also removes the marker, so the next filesystem event
triggered a fresh patch, which failed the same way. By hand, in a login shell, it worked every time.

From the real log on 2026-09-03, translated from the original Chinese:

```
00:26:34  OK    patched   .../anthropic.claude-code-2.1.257-darwin-arm64/extension.js
00:27:06  FAIL  node --check failed, rolled back
00:27:16  FAIL  node --check failed, rolled back
00:27:27  FAIL  node --check failed, rolled back
00:27:37  FAIL  node --check failed, rolled back
00:29:06  OK    patched
```

Four failures in 31 seconds, then an OK once the script resolved `node` by absolute path. `patch.sh`
now tries `/opt/homebrew/bin/node`, then `/usr/local/bin/node`, then whatever `command -v node`
finds. `./cc-kit doctor` prints the path it resolved. Resolve every interpreter by absolute path in
anything launchd runs.

## The click log

Off by default. With it on, every click through the patched `openFile` appends one line to
`~/.local/state/ccw/open-binary/runtime.log`, in this shape:

```
2026-09-03T10:07:17.910Z  bin=true   /Users/you/work/logo.png
2026-09-03T10:16:51.099Z  bin=false  /Users/you/work/notes/draft.md
```

`bin=true` means the sniff found a NUL and the click went to `vscode.open`. `bin=false` means it took
the text path. Turn it on when you want to know whether a dead click even reached the extension host.
An absent line means the click never got that far, which is usually the
[directory link defect](#what-this-does-not-fix).

```sh
./cc-kit install open-binary --click-log    # on
./cc-kit install open-binary                # off again
```

Either form rewrites the bundle, so reload the window after switching. The log records every file
path you click. It never leaves the machine, and it has no size cap today. Leave it off unless you
are debugging.

## What this does not fix

**Relative directory links, which never reach the extension at all.** This one is a separate defect
in the webview, and no patch to `extension.js` can touch it. The webview parses the href before it
sends anything to the extension host. In 2.1.259, `webview/index.js` accepts a link only if it starts
with `/`, `./`, `../`, `.\` or `..\`, or ends in a dot plus 1 to 10 alphanumerics, or ends in a slash
or backslash, or contains a slash and its last segment is one of:

```
src lib test tests dist build node_modules components utils services api assets
public private config scripts docs
```

Anything else returns `null`, and the click handler is:

```js
function EB0($,J,Y){if(!J)return;let X=jv(J);if(!X)return;$.preventDefault(),$.stopPropagation(),Y?.open(X.filePath,...)}
```

It returns before `open`. No message is sent. Nothing is logged anywhere, including in this tool's
click log. Running the shipped parser against real strings:

```
INERT  engagements/2026-nca-clustering
INERT  tools/open-binary
INERT  docs
INERT  tools/rc-proxy/notes
OK     engagements/2026-nca-clustering/
OK     ./engagements/2026-nca-clustering
OK     engagements/docs
OK     tools/src
OK     README.md
OK     /Users/you/pic.png
```

So `tools/src` is clickable and `tools/open-binary` is inert, and bare `docs` is inert because the
allowlist branch also requires a slash somewhere in the path. The workaround is in how you write the
link. Add a trailing slash or a leading `./` to any directory you want clickable. Note that
`@`-mention chips use the same parser differently, keeping the raw text when the parse fails, so a
directory that is dead as a link can still open as a mention.

**PDFs with no NUL in the header.** 136 of the 235 PDFs I scanned carry none, take the text path, and
open as a tab of garbage. The patch cannot help, because from VS Code's point of view the file is
text and `showTextDocument` succeeds. This has a supported fix that needs no patch at all. Install any
PDF preview extension and add one stock setting, which sends every `.pdf` to that editor before the
text path is reached:

```json
{
  "workbench.editorAssociations": {
    "*.pdf": "pdf.preview"
  }
}
```

Replace `pdf.preview` with the view type your chosen extension registers. If PDFs are your only
problem, use that and install nothing from this repo.

**Line numbers on UTF-16 text files.** The patch tests for any NUL byte. VS Code exempts the strict
alternating patterns that mean UTF-16. A UTF-16 encoded text file therefore sniffs as binary here,
goes to `vscode.open`, and opens correctly in a text editor, but the early return skips the
line-jump, so `file.txt:42` opens the file at the top. Rare enough that I left it alone. The same
early return means no binary file ever gets a line jump, which is not a loss.

**What the file opens as.** `vscode.open` hands the URI to whatever editor VS Code associates with
it. Images land in the built-in image preview. A format with no registered editor gets VS Code's own
binary-file notice with the size and an option to open it anyway. That is VS Code's behavior and this
patch does not change it. Either way the click does something you can see.

**Other patchers.** If you run any other tool that patches `anthropic.claude-code`, you are in a
combination nobody has tested. Several of them back the same files up to fixed names and race on the
same `WatchPaths` event. See [docs/launchd-notes.md](../../docs/launchd-notes.md).

## When it breaks

In order of likelihood:

1. You did not reload the window. Run `Developer: Reload Window`.
2. An extension upgrade landed and the agent has not fired yet. Check
   `~/.local/state/ccw/open-binary/patch.log`, then reload the window.
3. The log says `SKIP` on a new version. The anchor stopped matching. Nothing was changed and nothing
   is broken. Run `./cc-kit diff open-binary` to see what `openFile` looks like now.
4. The log says `FAIL`. The patched bundle did not pass `node --check` and the backup was restored.
   Your extension is intact. Open an issue with the version number.
5. The click was a directory link. See [What this does not fix](#what-this-does-not-fix).

## Credit

The cause was not discovered here. The symptom is reported in at least eight upstream issues, and
[anthropics/claude-code#37989](https://github.com/anthropics/claude-code/issues/37989), filed
2026-03-23, already guessed the mechanism ("likely routes through
`vscode.workspace.openTextDocument` which silently fails for binary files") and already named the fix
("should go through `vscode.commands.executeCommand('vscode.open', uri)`"). That guess was right.
Credit for both belongs there.

What this directory adds: the guess confirmed against the shipped bundle, the NUL rule and the
512-byte window read out of the VS Code build, the webview allowlist defect documented above, and a
patch that survives extension upgrades. See [docs/prior-art.md](../../docs/prior-art.md) for the other
tools that patch this extension and what differs here.
