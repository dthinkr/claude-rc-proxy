# claude-code-workarounds

Three unsupported macOS workarounds for Claude Code. Anthropic did not write them and
does not support them. Each one will break. There is no Linux or Windows path.

| Symptom | Tool | Cost | Skip if |
|---|---|---|---|
| Click a PNG in the VS Code chat panel and nothing happens. | [`open-binary`](tools/open-binary/) | Edits a file Anthropic ships. Every upgrade wipes it; a launchd agent puts it back. | You only click text, or you use the terminal, not the VS Code panel. |
| A huge session left overnight costs a fortune on the first message next morning. | [`auto-compact`](tools/auto-compact/) | Every VS Code Claude Code session launches through a file in this checkout. | 5-minute cache tier, small sessions, or terminal. |
| Pointing `ANTHROPIC_BASE_URL` at a gateway kills Remote Control and Artifact publishing. | [`rc-proxy`](tools/rc-proxy/) | Every Claude Code session on the machine goes through one local process that terminates TLS. | You send inference to Anthropic only. |

Install one and ignore the other two. They share `lib/` and `~/.local/state/ccw`.

If the only problem is PDFs, install a PDF preview extension and add
`{ "workbench.editorAssociations": { "*.pdf": "pdf.preview" } }`. That is a stock setting.

## What breaks

**open-binary** is a text patch on a minified bundle. An upgrade wipes it; the agent
re-applies it; you still have to reload the window. If Anthropic restructures `openFile`,
the script writes `SKIP` and clicks silently do nothing again. As of 2.1.259 the anchor
matches.

**auto-compact** depends on an undocumented rule: a stream-json message with no `origin`
is treated as human input, so `/compact` expands. If that changes, `/compact` lands as
literal text. Moving or deleting this checkout also stops every new session from starting,
because the wrapper setting points here.

**rc-proxy** dies the day Anthropic pins certificates. While it is up, every session has
`https_proxy` pointed at it, so if it dies they all go silent together. Uninstall: take
the `env` block out of `~/.claude/settings.json` before you boot out the agent.

Every path each tool writes, with the undo next to it:
[docs/what-this-touches.md](docs/what-this-touches.md).

## Install

Clone somewhere you will not move. Tools run out of the checkout. `git pull` is the update.

```sh
git clone https://github.com/dthinkr/claude-code-workarounds
cd claude-code-workarounds
./cc-kit doctor
./cc-kit diff open-binary
./cc-kit install open-binary
```

Then **Developer: Reload Window**. Restarting the Claude Code session does not reload
`extension.js`.

There is no `install all`. Name the tools you want.

## Is it working

```sh
./cc-kit status
```

A loaded agent proves nothing. `open-binary` is in place when the marker is in the
bundle, `auto-compact` when the wrapper points here and the session was restarted after,
`rc-proxy` when `/healthz` answers.

If it looks dead, you usually skipped the window reload.

## Credit

Clicking a binary does nothing because `openFile` calls `showTextDocument(uri).then(success)`
with no rejection handler. The rejection happens inside `workspace.openTextDocument`,
before any editor exists, which is why no editor setting fixes it. Which files fail is
decided by a NUL in the first 512 bytes, not by the extension.

That cause is not mine. [#37989](https://github.com/anthropics/claude-code/issues/37989)
described it in March 2026 and named this fix. A stale bot closed it.
[docs/prior-art.md](docs/prior-art.md) says what is actually new here.

## More

- [docs/conventions.md](docs/conventions.md)
- [docs/launchd-notes.md](docs/launchd-notes.md)
- [docs/claude-code-internals.md](docs/claude-code-internals.md)
- [SECURITY.md](SECURITY.md)
- [SUPPORT.md](SUPPORT.md)

MIT, 2026 Wenbin Wu. Not affiliated with Anthropic. `open-binary` edits a file they
ship. `rc-proxy` decrypts your own Claude traffic on your machine. If either costs you
money or a working install, that is on you.
