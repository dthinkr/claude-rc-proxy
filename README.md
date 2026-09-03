# claude-code-workarounds

Three unsupported macOS workarounds for Claude Code: clickable binary file links in VS Code,
auto-compaction before the prompt cache goes cold, and a forward proxy that routes inference to
your own gateway without switching off Remote Control, Artifact publishing, or anything else
first-party.

These are three things about Claude Code on macOS that I fixed for myself. Anthropic did not write
them and does not support them. Each one edits or intercepts something owned by someone else, so
each one will break. macOS only. There is no Linux or Windows path and there will not be one.

---

## Which one do you want

| Your symptom | Tool | What it costs you | Skip this if |
|---|---|---|---|
| I click a PNG in the Claude Code chat panel and nothing happens. No error, no tab, nothing. | [`open-binary`](tools/open-binary/) | Edits a file Anthropic ships. Every extension upgrade wipes it and a launchd agent puts it back. | You only click text files, or you use Claude Code in a terminal instead of the VS Code panel. |
| I left a huge session overnight and the first message next morning cost a fortune. | [`auto-compact`](tools/auto-compact/) | Every VS Code Claude Code session launches through a file in this checkout. | Your account is on the 5-minute cache tier, your sessions stay small, or you work in a terminal. |
| I want inference from a local gateway, but pointing `ANTHROPIC_BASE_URL` at it kills Remote Control and Artifact publishing. | [`rc-proxy`](tools/rc-proxy/) | Every Claude Code session on the machine goes through one local process that terminates your TLS. | You do not route inference anywhere other than Anthropic. This is the whole reason it exists. |

They share no code and no state. Install one and ignore the other two.

---

## What breaks, and when

This section is above Install on purpose. For an unsupported repo it is the contract.

**`open-binary`** is a text patch against a 3.2 MB minified bundle. Every extension upgrade replaces
that bundle and wipes the patch. The launchd agent watches `~/.vscode/extensions` and re-applies
within seconds, then you need a window reload. The real failure is a restructured `openFile`: the
anchor stops matching, the script writes `SKIP`, changes nothing, and clicks quietly go back to
doing nothing. You get a log line and no other signal. As of 2.1.259 the anchor still matches.

**`auto-compact`** rests on one undocumented behavior. The extension launches the CLI with
`--input-format stream-json` over a socketpair, and a user message arriving there with no `origin`
field is treated as human input, so slash commands expand. The `claudeCode.claudeProcessWrapper`
setting the shim uses is documented. The missing-`origin` rule is not. If it changes, the most
likely outcome is that `/compact` lands in a session as literal text.

**`rc-proxy`** terminates TLS for `api.anthropic.com` using a local CA. It dies the day Anthropic
pins certificates. When it dies, every Claude Code session on the machine goes silent at the same
moment, because they all have `https_proxy` pointed at it. Uninstalling has the same hazard in
reverse. Remove the `env` block from `~/.claude/settings.json` before or at the same time as you
boot out the agent. If `https_proxy` still points at `127.0.0.1:9801` and nothing is listening,
every Claude Code session on the machine fails to connect. `uninstall.sh` prints this and pauses.

---

## What this touches on your machine

A summary. The full list lives in [docs/what-this-touches.md](docs/what-this-touches.md), which
`./cc-kit manifest-doc` generates from `tools/*/manifest.conf` and CI checks for drift. If a path
is not on that page, no tool here writes it.

**`open-binary`**

| Path | Undo |
|---|---|
| `~/.vscode/extensions/anthropic.claude-code-*/extension.js` (patched in place, 522 bytes inserted on 2.1.259, 662 if you turn the click log on) | `cp extension.js.ccw-open-binary.bak extension.js` |
| `~/.vscode/extensions/anthropic.claude-code-*/extension.js.ccw-open-binary.bak` (created once per version) | `rm` it |
| `~/Library/LaunchAgents/io.github.dthinkr.ccw.open-binary.plist` | `launchctl bootout gui/$(id -u)/io.github.dthinkr.ccw.open-binary && rm` it |
| `~/.local/state/ccw/open-binary/patch.log`, `runtime.log` | `rm -rf ~/.local/state/ccw/open-binary` |

**`auto-compact`**

| Path | Undo |
|---|---|
| `~/Library/Application Support/Code/User/settings.json`, one key: `claudeCode.claudeProcessWrapper` | delete that one key |
| `~/Library/Application Support/Code/User/settings.json.bak-<timestamp>` | `rm` it |
| `~/Library/LaunchAgents/io.github.dthinkr.ccw.auto-compact.plist` | `launchctl bootout gui/$(id -u)/io.github.dthinkr.ccw.auto-compact && rm` it |
| `~/.local/state/ccw/auto-compact/` (state, log) | `rm -rf` it |
| `/tmp/cc-inject/<pid>.sock`, one per live session | gone on reboot; gone per session on restart |

**`rc-proxy`**

| Path | Undo |
|---|---|
| `tools/rc-proxy/claude-rc-proxy`, the binary `install.sh` builds | `rm` it, it is gitignored |
| `~/Library/LaunchAgents/io.github.dthinkr.ccw.rc-proxy.plist` | `launchctl bootout gui/$(id -u)/io.github.dthinkr.ccw.rc-proxy && rm` it |
| `~/.local/state/ccw/rc-proxy/` (`route.log`, `pool-models.json`) | `rm -rf` it |
| `~/.config/ccw/rc-proxy.token`, mode 600, written by you | `rm` it |
| `~/.claude/settings.json`, four keys in `env`, pasted by you | delete those four keys |
| `~/.mitmproxy/`, written by mitmproxy and reused as the CA | `rm -rf` it if nothing else uses it |

`install.sh` never edits `~/.claude/settings.json`. It prints the JSON block and you paste it.

---

## Install

Clone once, somewhere you will not move. Every tool runs out of the checkout. The launchd plists
point at absolute paths inside the clone, so `git pull` is the whole update procedure and there is
no re-install step. Moving or deleting the checkout breaks the agents.

```sh
git clone https://github.com/dthinkr/claude-code-workarounds ~/code/claude-code-workarounds
cd ~/code/claude-code-workarounds
./cc-kit doctor                 # writes nothing, reports what it found
./cc-kit diff open-binary       # shows the patch without applying it
./cc-kit install open-binary
```

**Then run `Developer: Reload Window` from the VS Code command palette.** This step is required.
Restarting the Claude Code session does not reload `extension.js`.

`diff` copies your installed bundle to a temp file, patches the copy, runs `node --check` on it, and
prints the before and after of `openFile` only. Nothing under `~/.vscode/extensions` is touched.
Read it before you install. It is short.

Install more than one by naming them. There is no `all`, on purpose. The three tools have very
different blast radius and nobody should acquire a TLS-intercepting single point of failure from a
blanket command.

```sh
./cc-kit install open-binary auto-compact
```

`auto-compact` refuses to install if your account is dominated by the 5-minute cache tier, because
the shipped 50-minute window is then wrong by an order of magnitude. It tells you to pass
`--shim-only` or lower the bounds. `rc-proxy` needs Go, mitmproxy and a pool token before it will
install anything. See [tools/rc-proxy/README.md](tools/rc-proxy/README.md) for that setup path.

---

## How to tell whether anything is still working

```sh
./cc-kit status
```

One line per tool: whether the agent is loaded, when it last ran, and whether the effect is in place
right now. Those last two are different questions. A loaded agent proves nothing.

- `open-binary` is in place when the version marker is present in the installed `extension.js`.
- `auto-compact` is in place when `claudeCode.claudeProcessWrapper` points at the shim in this
  checkout, and the session you care about has been restarted since.
- `rc-proxy` is in place when it answers on `/healthz`. `./cc-kit status rc-proxy` runs three
  probes: `/healthz`, one request to `api.anthropic.com` through the proxy, and one that bypasses
  it. Three results separate a wedged proxy from a dead upstream from a dead network, so the
  watchdog never restarts during an outage it cannot fix.

The failure mode shared by all three is silence. If a tool looks dead, the answer is usually a
missing window reload or a session that was never restarted.

---

## The NUL rule

This is the part worth reading even if you install nothing.

The extension's `openFile` calls `vscode.window.showTextDocument(uri).then(success)`. There is no
rejection handler. `showTextDocument` first awaits `workspace.openTextDocument`, which rejects at
the document-model stage for any file whose first 512 bytes contain a NUL byte. No editor is ever
created, the rejection is swallowed, and the click does nothing at all. No error, no notification,
no log entry.

**The discriminator is the NUL byte. It is not the file extension and it is not the MIME type.**

Here is the one-byte repro. Two 600-byte files, same extension, same size, identical except for
byte 11.

```sh
python3 - <<'PY'
b = bytearray(b'A' * 600)
open('opens.bin', 'wb').write(bytes(b))
b[10] = 0
open('inert.bin', 'wb').write(bytes(b))
PY
cmp -l opens.bin inert.bin      # 11 101 0
```

Link both from the chat panel. `opens.bin` opens as a tab of 600 A characters. `inert.bin` does
nothing. That is the entire bug.

### Measurements, on named sample files

The count is a property of the individual file. It is not a property of the format. The table below
is a scan of files that happen to be on one machine in September 2026, up to 40 per row, empty files
excluded. Do not read it as a specification. The only line that generalizes is the sentence above
the table.

| Extension | files scanned | NULs in first 512 B, lowest | highest | files with zero |
|---|---:|---:|---:|---:|
| `png` | 40 | 14 | 225 | 0 |
| `jpg` | 40 | 39 | 274 | 0 |
| `xlsx` | 40 | 15 | 467 | 0 |
| `docx` | 40 | 15 | 475 | 0 |
| `pptx` | 37 | 12 | 467 | 0 |
| `gif` | 31 | 1 | 456 | 0 |
| `mp4` | 9 | 11 | 476 | 0 |
| `zip` | 40 | 10 | 117 | 0 |
| `ttf` | 40 | 174 | 270 | 0 |
| `woff2` | 18 | 34 | 43 | 0 |
| `webp` | 40 | 2 | 28 | 0 |
| `ico` | 38 | 31 | 497 | 0 |
| `db` (SQLite) | 40 | 102 | 470 | 0 |
| `pdf` | 40 | **0** | 5 | **21** |
| `svg`, `csv`, `ipynb`, `md` | 40 each | 0 | 0 | all 40 |

Two things fall out of that. Every non-empty binary file I sampled carried at least one NUL in the
first 512 bytes, so the patch catches all of them. PDF is the exception and it splits down the
middle: 21 of 40 carried zero NULs, and the other 19 carried 1 to 5. A PDF with a NUL in its header
is caught by the patch and opens in whatever editor VS Code associates with it. A PDF with none
takes the text path and opens as a tab of garbage. Behavior depends on the individual file. See
[Further reading](#further-reading) for a stock VS Code setting that fixes the PDF case with no
patch at all.

Scan your own files:

```sh
./cc-kit nul-scan ~/Downloads/*.pdf ~/Desktop/*.png
```

### A second defect, documented and not fixed

The webview's href-to-path parser drops some links before they ever reach `openFile`, so no patch to
`extension.js` can help. A link is accepted only if it starts with `/`, `./` or `../`, or ends in a
dot-extension, or ends in a slash, or contains a slash and its last segment is in this hardcoded
list: `src lib test tests dist build node_modules components utils services api assets public
private config scripts docs`.

Verified against the shipped parser in `webview/index.js` at 2.1.259:

```
INERT  engagements/2026-nca-clustering
OK     engagements/docs
INERT  docs
OK     engagements/2026-nca-clustering/
OK     ./engagements/2026-nca-clustering
INERT  tools/open-binary
OK     tools/src
OK     README.md
```

So `tools/src` is clickable and `tools/open-binary` is inert. Adding a trailing slash or a leading
`./` makes any directory link work. That is the whole workaround and it lives in your prose, not in
this repo.

---

## Conventions

One of each, so there is nothing to remember per tool.

- **launchd labels**: `io.github.dthinkr.ccw.open-binary`, `.auto-compact`, `.rc-proxy`. One grep
  finds all of them: `launchctl list | grep ccw.`
- **launchctl verbs**: `bootstrap`, `bootout`, `kickstart`. The legacy `load` and `unload` appear
  nowhere in this repo.
- **State and logs**: `~/.local/state/ccw/<tool>/`. Not `~/.claude/`, which belongs to Anthropic.
- **Config**: `~/.config/ccw/`.
- **Backups**: `<file>.bak-YYYYmmdd-HHMMSS`. The one exception is the extension bundle, which uses
  the fixed name `extension.js.ccw-open-binary.bak` because rollback and the version migration both
  read it back. The name carries a tool prefix because bare `.bak` names collide. On my own machine
  two unrelated scripts patch `webview/index.css` and both write `index.css.bak` with
  `[ -f "$CSS.bak" ] || cp "$CSS" "$CSS.bak"`, so whichever runs second backs up an already-patched
  file and restoring that one backup silently reverts both patches. Anything else you run that
  patches this extension is an unsupported combination with no warning. See
  [docs/launchd-notes.md](docs/launchd-notes.md).
- **Run twice**: every installer is safe to run again and says which of applied, already applied, or
  upgraded happened.
- **Refuse rather than degrade**: when a tool cannot do the safe thing it stops and says so. Two real
  instances. With no pool token, `rc-proxy` routes inference to an unroutable address instead of
  quietly spending your subscription quota. When `node --check` fails on a patched bundle,
  `open-binary` restores the backup and logs `FAIL` instead of leaving you a broken extension.
- **Every installer ends by listing what it touched**, read from its manifest.

---

## The launchd PATH note

launchd runs jobs with a PATH that does not include `/opt/homebrew/bin`. The patch script called
`node` bare, so `node --check` failed with command-not-found, so the script rolled the patch back on
every single agent run. By hand it worked perfectly every time.

From the real log, 2026-09-03:

```
00:26:34 OK    patched   .../anthropic.claude-code-2.1.257-darwin-arm64/extension.js
00:27:06 FAIL  node --check failed, rolled back
00:27:16 FAIL  node --check failed, rolled back
00:27:27 FAIL  node --check failed, rolled back
00:27:37 FAIL  node --check failed, rolled back
00:29:06 OK    patched
```

Four failures in 31 seconds, all on 2.1.257, then an OK once the script resolved `node` by absolute
path. Resolve every interpreter by absolute path in anything launchd runs. If you write your own
agent, this is the paragraph to remember.

---

## Prior art and credit

**This repo did not discover the cause of the binary link bug.** The symptom is reported in at least
eight upstream issues, including
[#10846](https://github.com/anthropics/claude-code/issues/10846),
[#37989](https://github.com/anthropics/claude-code/issues/37989),
[#41112](https://github.com/anthropics/claude-code/issues/41112),
[#51015](https://github.com/anthropics/claude-code/issues/51015),
[#57100](https://github.com/anthropics/claude-code/issues/57100) and
[#72889](https://github.com/anthropics/claude-code/issues/72889). Issue #37989, filed 2026-03-23,
already guessed the mechanism ("likely routes through `vscode.workspace.openTextDocument` which
silently fails for binary files") and already named the fix ("should go through
`vscode.commands.executeCommand('vscode.open', uri)`"). Credit for both belongs there.

What this repo adds on top of that guess:

- The cause confirmed against the shipped bundle rather than inferred from the symptom.
- The NUL-byte rule, which explains why some binaries do nothing and others open as garbage, and
  why the answer differs between two files of the same format.
- The webview allowlist defect, documented above, which is separate and which this repo does not fix.
- A patch that survives extension upgrades.

None of those issues has a comment carrying a patch or a script. Anthropic's stale-bot closes issues
14 days after the stale label unless they reach ten or more `+1` reactions or a human comments after
the label, so several are closed rather than resolved.

Patching VS Code itself is a mature genre. Star counts read in 2026 and already stale: Custom CSS
and JS Loader at 1062, Vibrancy Continued at 864, APC at 745. Patching a third-party extension
bundle is rarer and also not new: `subframe7536/vscode-custom-ui-style` (378) patches
`github.copilot-chat` the same way. Roughly eight tools already patch `anthropic.claude-code`, and
two of them,
`ojhurst/claude-code-vscode-patcher` and `Blake-C/claude-overwrite-features-vscode`, arrived
independently at the same launchd plus WatchPaths plus regex plus `.bak` architecture this repo uses.
What differs here is `node --check` with automatic rollback, and structural recovery of the minified
identifiers so the anchor survives re-minification. In 2.1.259 the four names the patch needs are
`_$`, `K5`, `J` and `X`, and they change between releases.

For `auto-compact`, [cache-keepalive](https://github.com/yujiachen-y/claude-code-cache-keepalive) and
[CacheWarden](https://github.com/Efs-O/CacheWarden) take the opposite approach and keep the cache
warm rather than shrink the context. Both hardcode the 5-minute tier. Upstream request:
[anthropics/claude-code#66115](https://github.com/anthropics/claude-code/issues/66115).

---

## Further reading

- [tools/open-binary/README.md](tools/open-binary/README.md), [tools/auto-compact/README.md](tools/auto-compact/README.md), [tools/rc-proxy/README.md](tools/rc-proxy/README.md)
- [docs/what-this-touches.md](docs/what-this-touches.md), the generated long form of
  [What this touches](#what-this-touches-on-your-machine)
- [docs/conventions.md](docs/conventions.md) and [docs/launchd-notes.md](docs/launchd-notes.md)
- [docs/claude-code-internals.md](docs/claude-code-internals.md), what I learned about the bundle
  while doing this. Version-stamped and going stale as you read it.
- [docs/prior-art.md](docs/prior-art.md), the long form of [Prior art and credit](#prior-art-and-credit)
- [tools/auto-compact/notes.md](tools/auto-compact/notes.md), eight injection routes that do not
  work, and the measurement mistakes behind the numbers in that tool's README

**If your only problem is PDFs**, you do not need `open-binary`. Install any PDF preview extension
and add one stock VS Code setting, which makes VS Code open PDFs in that editor and never reach the
failing text path:

```json
{
  "workbench.editorAssociations": {
    "*.pdf": "pdf.preview"
  }
}
```

Replace `pdf.preview` with whatever view type your chosen extension registers. This is a supported
setting and it patches nothing.

---

## License and disclaimer

MIT, copyright 2026 Wenbin Wu. See [LICENSE](LICENSE).

Not affiliated with Anthropic. These tools modify and intercept software I did not write.
`open-binary` edits a file Anthropic ships to you. `rc-proxy` decrypts your own Claude traffic on
your own machine using a local CA. Check your own agreements before you run either one. If any of
this ends up costing you money or a working install, that is on you, and
[What this touches](#what-this-touches-on-your-machine) tells you exactly what to put back.
