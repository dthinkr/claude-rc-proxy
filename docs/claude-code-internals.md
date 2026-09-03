# Claude Code internals these tools depend on

Read against the **VS Code extension 2.1.259** and **Claude Code 2.1.251** for the CLI
parts. None of this is documented by Anthropic. All of it can change without notice, and
when it does, the tool that depends on it stops working. Each entry says what happens then.

## The file link click path

Clicking a file path in the chat panel goes through two layers.

**Layer one, the webview.** A markdown link is rendered as an anchor whose `onClick` hands
the href to a parser. That parser accepts the href as a file reference only if it starts
with `/`, `./` or `../`, or ends in a dot extension, or ends in a slash, or its last path
segment is in a hardcoded list: `src`, `lib`, `test`, `tests`, `dist`, `build`,
`node_modules`, `components`, `utils`, `services`, `api`, `assets`, `public`, `private`,
`config`, `scripts`, `docs`.

Anything else returns null and no message is sent at all. A relative directory link with no
trailing slash and a name outside that list, `engagements/2026-planning` for example, is
inert. `docs` is clickable, `2026-planning` is not.

This is confirmed from the extension host log, which records every message the webview
sends. The non-slash form produces no `open_file` message.

**Layer two, the extension host.** The `open_file` message reaches a handler that resolves
the path, returns early for directories after calling `revealInExplorer`, and otherwise
calls `showTextDocument` on the file. That call has a success callback and no rejection
handler.

`showTextDocument` first awaits `workspace.openTextDocument`, which rejects at the
document-model layer for a file whose first 512 bytes contain a NUL byte. No editor is ever
created, so no editor setting is involved and none can work around it. The rejection is
swallowed and the click does nothing.

`open-binary` patches the second layer only. The first is out of reach from the extension
host, because the message never arrives.

**If this changes:** the patch anchors on the `isDirectory` check, which is where it also
recovers the minified names for the vscode namespace, `fs`, the path variable and the URI
variable. A restructured handler means the anchor stops matching. The script writes `SKIP`
to its log, changes nothing, and clicks go back to doing nothing with no other signal.

## The NUL byte rule

VS Code's binary sniffing reads the first 512 bytes and looks for a NUL. That is the whole
discriminator. It is not the extension and not the MIME type.

Measured across 14 files per format on one machine, NUL count in the first 512 bytes:

| Format | Range | Median |
|---|---|---|
| PNG | 15 to 225 | 24 |
| JPG | 39 to 274 | 54 |
| DOCX | 15 to 467 | 246 |
| PDF | 0 to 4 | 1 |

PDF is the one that varies across the boundary. Most PDFs carry one to four NULs early and
are caught. Some carry none, take the text path, and open as a tab full of mojibake.

The counts vary a lot inside a single format, so treat any single number as a sample and
not as a property of the format. `./cc-kit nul-scan <dir>` measures your own files.

## claudeProcessWrapper and the session stdin

The VS Code extension reads `claudeCode.claudeProcessWrapper` from settings and, when set,
launches the CLI through it: `<wrapper> <real binary> <all the normal args>`.

The extension talks to the CLI over `--input-format stream-json` on a socketpair. A user
message arriving on that channel with no `origin` field is treated as human input, so slash
commands expand normally. `auto-compact`'s shim opens a side channel onto that stdin and
writes `/compact` into it.

The setting is documented. The missing-`origin` rule is not.

**If this changes:** the most likely outcome is `/compact` landing in a session as literal
text rather than expanding.

The setting is also a single global slot. Only one tool can own it. `auto-compact` refuses
to overwrite a value pointing outside this checkout.

## Telling whether the extension host actually reloaded

Patching `extension.js` on disk changes nothing until the extension host restarts.
Restarting the *Claude Code session* does not do that. Only `Developer: Reload Window`,
`Developer: Restart Extension Host`, or quitting VS Code does.

This is worth knowing because "I restarted it and nothing changed" is almost always this.
The log file's first line is the timestamp the current host started:

```sh
head -1 ~/Library/Application\ Support/Code/logs/*/window*/exthost/Anthropic.claude-code/Claude\ VSCode.log
```

Compare it against the modification time of the patched bundle. If the log is older, the
running code predates the patch.

With several windows open, the command palette acts on the focused window, which may not be
the one holding the chat panel. Grep those logs for a session id to find which window is
which, or quit VS Code entirely.

## Cache tiers

The economics behind `auto-compact` assume a 1-hour prompt cache tier. On a 5-minute tier
the shipped 50-minute idle window is wrong by an order of magnitude, and the installer
refuses rather than compacting on a schedule that cannot pay for itself.

## Version stamp

Verified against extension 2.1.259 on 2026-09-03. Earlier versions checked while writing
this: 2.1.252, 2.1.257, 2.1.258. The `openFile` structure was identical across all of them.
