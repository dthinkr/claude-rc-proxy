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
| I want inference from a local gateway, but pointing `ANTHROPIC_BASE_URL` at it kills Remote Control and Artifact publishing. | [`rc-proxy`](tools/rc-proxy/) | Every Claude Code session on the machine goes through one local process that terminates your TLS. | You do not route inference anywhere other than Anthropic. |

They share three small shell libraries under `lib/` and one state root, `~/.local/state/ccw`, and
nothing else. Install one and ignore the other two.

**If your only problem is PDFs**, you need none of this. Install a PDF preview extension and add one
stock setting, which sends PDFs to that editor instead of the failing text path:

```json
{ "workbench.editorAssociations": { "*.pdf": "pdf.preview" } }
```

---

## What breaks, and when

This section is above Install on purpose.

**`open-binary`** is a text patch against a 3.2 MB minified bundle. Every extension upgrade replaces
that bundle and wipes the patch. The launchd agent watches the extensions directory and re-applies
within seconds, then you need a window reload. The real failure is a restructured `openFile`: the
anchor stops matching, the script writes `SKIP`, changes nothing, and clicks quietly go back to
doing nothing. You get a log line and no other signal. As of 2.1.259 the anchor still matches.

**`auto-compact`** rests on one undocumented behavior, that a message arriving on the session's
stream-json stdin with no `origin` field is treated as human input, so slash commands expand. If
that changes, `/compact` lands in a session as literal text. Its other failure is duller and more
likely: the wrapper setting points at a path in this checkout, so moving or deleting the checkout
stops every new session from starting.

**`rc-proxy`** terminates TLS for `api.anthropic.com` using a local CA. It dies the day Anthropic
pins certificates. When it dies, every Claude Code session on the machine goes silent at once,
because they all have `https_proxy` pointed at it. Uninstalling has the same hazard in reverse:
remove the `env` block from `~/.claude/settings.json` before you boot out the agent.

---

## What this touches

[docs/what-this-touches.md](docs/what-this-touches.md) lists every path every tool writes, with the
undo command beside each. `./cc-kit manifest-doc` generates it from `tools/*/manifest.conf` and CI
fails if it has drifted, so it cannot go stale quietly. If a path is not on that page, no tool here
writes it.

`install.sh` never edits `~/.claude/settings.json`. It prints the JSON block and you paste it.

---

## Install

Clone once, somewhere you will not move. Every tool runs out of the checkout, so `git pull` is the
whole update procedure and there is no re-install step. Moving or deleting the checkout breaks the
agents.

```sh
git clone https://github.com/dthinkr/claude-code-workarounds ~/code/claude-code-workarounds
cd ~/code/claude-code-workarounds
./cc-kit doctor                 # writes nothing, reports what it found
./cc-kit diff open-binary       # shows the patch without applying it
./cc-kit install open-binary
```

**Then run `Developer: Reload Window` in VS Code.** This step is required. Restarting the Claude
Code session does not reload `extension.js`.

`diff` copies your bundle to a temp file, patches the copy, runs `node --check` on it, and prints
the before and after of `openFile` and nothing else. Nothing under your extensions directory is
touched. It is about 400 bytes of change and it fits on a screen.

Install more than one by naming them. There is no `all`, on purpose: the three have very different
blast radius, and nobody should acquire a TLS-intercepting single point of failure from a blanket
command.

---

## Is it working

```sh
./cc-kit status
```

One line per tool, and the second column is the one that matters. A loaded agent proves nothing.
`open-binary` is in place when the marker is in the installed bundle, `auto-compact` when the
wrapper setting points into this checkout and the session was restarted after, `rc-proxy` when it
answers on `/healthz`.

The failure mode shared by all three is silence. If a tool looks dead, it is usually a missing
window reload or a session that was never restarted.

---

## The one idea worth taking away

Clicking a binary file does nothing because `openFile` calls `showTextDocument(uri).then(success)`
with no rejection handler, and the rejection happens inside `workspace.openTextDocument`, at the
document-model layer, before any editor exists. That is why no editor setting fixes it.

Which files it hits is decided by whether the first 512 bytes contain a NUL byte, not by the
extension and not by the type. That is why PNG and mp4 do nothing at all while most PDFs open as a
tab full of mojibake, and why the behavior looks random until you measure it.

[tools/open-binary/README.md](tools/open-binary/README.md) has the measurements, a two-file
reproduction that differs by one byte, and a second defect in the webview that this repo cannot fix.

**The cause is not my discovery.** Issue
[#37989](https://github.com/anthropics/claude-code/issues/37989) described it in March 2026 and
named this exact fix. It was closed by a stale bot.
[docs/prior-art.md](docs/prior-art.md) has the full accounting of what came before and what is
actually new here, which is narrower than a repo like this usually claims.

---

## Further reading

- [docs/conventions.md](docs/conventions.md), where things go and why uninstall can be trusted
- [docs/launchd-notes.md](docs/launchd-notes.md), the PATH trap, `bootout` versus `unload`, and what
  happens when two agents watch one directory
- [docs/claude-code-internals.md](docs/claude-code-internals.md), what these tools depend on,
  version-stamped and going stale as you read it
- [SECURITY.md](SECURITY.md), what runs on your machine and what never leaves it
- [SUPPORT.md](SUPPORT.md), what an issue here can and cannot get you

---

## License and disclaimer

MIT, copyright 2026 Wenbin Wu. See [LICENSE](LICENSE).

Not affiliated with Anthropic. These tools modify and intercept software I did not write.
`open-binary` edits a file Anthropic ships to you. `rc-proxy` decrypts your own Claude traffic on
your own machine using a local CA. Check your own agreements before you run either one. If any of
this costs you money or a working install, that is on you, and
[docs/what-this-touches.md](docs/what-this-touches.md) tells you exactly what to put back.
