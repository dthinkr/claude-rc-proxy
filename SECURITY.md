# What this repo touches, and what it does not

Everything installs per user. Nothing runs as root. Nothing here reports anything to me.
Each tool modifies something you did not write, and the full path list is in
[docs/what-this-touches.md](docs/what-this-touches.md), generated from the manifests so it
cannot drift.

## What each tool changes

**open-binary** edits one file Anthropic ships to you,
`~/.vscode/extensions/anthropic.claude-code-*/extension.js`. It copies the original to
`extension.js.ccw-open-binary.bak` before the first write, injects about 522 bytes into
one function, runs `node --check` on the result, and restores the backup if that check
fails. Read the change before you install it: `./cc-kit diff open-binary` patches a temp
copy and prints the function before and after, and touches nothing under
`~/.vscode/extensions`.

**auto-compact** adds one VS Code user setting, `claudeCode.claudeProcessWrapper`,
pointing at `shim/cc-stdin-shim` inside your checkout. After that, every Claude Code
session VS Code launches starts through that script. The script execs the real binary and
adds one unix socket per session under `/tmp/cc-inject`, directory mode 0700, socket mode
0600. Text written into that socket is handled as typed input, slash commands included, so
anything running as your user can type into your sessions. That is not a new privilege,
since anything running as you can already rewrite the setting. You can still narrow the
channel with `CC_INJECT_ALLOW='/compact'` in the environment VS Code sees. The daemon
reads your session files under `~/.claude/projects` and `~/.claude/sessions` for token
counts and timestamps. It opens them read only, writes nothing back, and sends them
nowhere. Its own state and log go to `~/.local/state/ccw/auto-compact/`.

**rc-proxy** has the largest blast radius. It runs a local HTTP proxy that you point
Claude Code at through four env keys you paste into `~/.claude/settings.json`. For
`api.anthropic.com` it terminates TLS with a certificate minted from your local mitmproxy
CA, so it can read the request and decide where it goes. Every other host is tunneled
without decryption, which is the `host != anthropicHost` branch in `main.go`. Requests to
`api.anthropic.com` that are not inference reach the real Anthropic carrying your real
session. If the proxy stops while those keys are still in place, every Claude Code session
on the machine fails to connect until you remove them.

## What none of it does

- No `sudo`. No script in this repo contains the word.
- No LaunchDaemons. Three per-user LaunchAgents in `~/Library/LaunchAgents`, all labeled
  `io.github.dthinkr.ccw.*`.
- No change to the system trust store or to any keychain. The mitmproxy CA is trusted only
  by processes you hand it to through `NODE_EXTRA_CA_CERTS`.
- No edit to `~/.claude/settings.json`. The `rc-proxy` installer prints the JSON block for
  you to paste and stops there.
- No copies outside the checkout. Nothing is written to `~/.local/bin`, `~/.local/share`
  or `~/.claude/scripts`. The launchd agents point at files inside the clone.
- No telemetry and no analytics. Every network call the shell makes is a `curl` probe you
  can read: `rc-proxy/install.sh` waits on `127.0.0.1/healthz` after starting the agent,
  and `rc-proxy/status.sh` probes `127.0.0.1` and `api.anthropic.com` to tell a working
  install from a broken one. Nothing is sent anywhere else and nothing is reported back.
- `go.mod` declares zero dependencies, so the build pulls no third-party code. It can
  still download a Go toolchain, because `GOTOOLCHAIN` defaults to `auto` and `go.mod`
  names a version. Set `GOTOOLCHAIN=local` if you want the build fully offline.
- Every Python file imports only the standard library.

## Credentials and logs

The gateway token lives in `~/.config/ccw/rc-proxy.token`, mode 600. You write that file.
The installer reads it, warns if the mode is loose, and never copies the value into the
plist, because plists in `~/Library/LaunchAgents` are world readable. The agent starts
through `/bin/bash -c` and reads the file itself at launch.

The proxy sees the `Authorization` header on the inference requests it decrypts. Any proxy
in that position does. It does not log headers or bodies. Its log holds the method, a
truncated path, model injections, and errors. One opt-in exception:
`CLAUDE_RC_PROXY_DUMP_BOOTSTRAP=1` writes bootstrap responses to disk, and a bootstrap
response is a model list rather than a conversation.

`open-binary` writes one line per click only if you installed it with `--click-log`, off
by default. Those lines carry file paths from your machine.

## Reporting something

The tracker is public and so is every line in here. If you find a path written outside
[docs/what-this-touches.md](docs/what-this-touches.md), a token that leaked into a log or
a plist, or a log line holding your own content, open an issue and say exactly that.
Nothing in this repo runs on a server I control, so there is no fix I can push on your
behalf. You update the checkout, or you remove the tool. The hand undo in the README works
without the CLI, so a broken `cc-kit` never traps you.
