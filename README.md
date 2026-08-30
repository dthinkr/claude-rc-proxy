# claude-code-auto-compactor

**A supported way to drive a running Claude Code session from an external process — and an idle
auto-compactor built on top of it.**

Two things live here:

1. **`shim/cc-stdin-shim`** — a ~170-line wrapper that gives every VS Code Claude Code session a
   side channel at `/tmp/cc-inject/<pid>.sock`. Write a line of text into it and the session
   behaves exactly as if you had typed that line into the composer and pressed enter — slash
   commands included.
2. **`compactd.py`** — the reference consumer. It watches for sessions that have gone idle while
   holding a large context and sends them `/compact` **while the prompt cache is still warm**, so
   coming back tomorrow does not pay for a cold rebuild of the whole conversation.

If you only want #1, ignore `compactd.py`. The shim is independent and has no idea what it is
carrying.

---

## Why the side channel exists

Claude Code deliberately wraps or strips the leading slash on *every* input path that is not a
human typing:

| Path | What arrives |
|---|---|
| `Stop` hook `{"decision":"block","reason":"/compact"}` | `Stop hook feedback:\n/compact` |
| cross-session peer socket | `<cross-session-message>…</cross-session-message>` |
| Remote Control `/events` from a non-first-party client | `Another Claude session sent a message:\n/compact` |

The gate is one predicate — roughly
`value.trim().startsWith("/") && !skipSlashCommands` — and every wrapper above is enough to make
it fail. That is intentional, not an oversight, and there is no supported programmatic trigger for
`/compact` (the SDK `control_request` subtype whitelist has no compaction entry).

What is *not* closed is the session's own stdin. The VS Code extension does not run the CLI in a
terminal; it runs it with `--input-format stream-json` over a socketpair:

```console
$ ps -o args= -p <pid>
…/native-binary/claude --output-format stream-json --input-format stream-json \
    --permission-prompt-tool stdio --resume=… --permission-mode …

$ lsof -a -p <pid> -d 0
claude  <pid>  0u  unix 0x…          # socketpair held by the extension host, not a tty
```

A user message arriving on that channel carries **no `origin` field**, and the classifier treats a
missing origin as human (`origin === undefined || origin.kind === "human"`). So it reaches the
slash gate unwrapped and expands normally. `/compact` is additionally registered with
`supportsNonInteractive: true`, so it works there.

The only obstacle is that the write end of fd 0 belongs to the extension host. The extension
solves that for us: it has a documented setting for choosing what to launch.

```js
// extension.js
function Dr($, Q) {
  let J = getConfig("claudeProcessWrapper"), X = <bundled native binary>;
  if (J) return { pathToClaudeCodeExecutable: J, executableArgs: X ? [X] : [], env: Q };
  …
}
```

Set `claudeCode.claudeProcessWrapper` and the extension invokes
`<wrapper> <real binary> <all the usual args…>`. The shim execs the real binary unchanged and
multiplexes one extra source into its stdin. That is the whole trick.

See [FINDINGS.md](FINDINGS.md) for the full reverse-engineering record, including the eight
injection routes that do *not* work and why.

## What the shim does and does not touch

- **stdin only.** `stdout`/`stderr` are inherited straight through, so the extension's protocol is
  never copied, parsed, or reordered.
- Opens the side channel **only** when `--input-format stream-json` is present, so a terminal-mode
  launch (`claudeCode.useTerminal`) passes through untouched.
- Socket is `0600` inside a `0700` directory, named by the child pid — the same pid that appears in
  `~/.claude/sessions/<pid>.json`, so a supervisor can map session name → port.
- Writes are serialized, so an injected line can never interleave with the extension's own.
- Exit status and `SIGTERM`/`SIGINT`/`SIGHUP`/`SIGQUIT` are forwarded to the real process.

**Security note.** The channel accepts arbitrary text, not just `/compact`. Anything running as
your user can use it to type into any of your sessions. That is not a privilege boundary — anyone
who can write to your VS Code settings can already run code as you — but it is a convenience worth
being deliberate about. Set `CC_INJECT_ALLOW` to restrict it:

```sh
CC_INJECT_ALLOW='/compact'          # only this exact line is accepted
```

## Install

```sh
git clone https://github.com/<you>/claude-code-auto-compactor
cd claude-code-auto-compactor
./install.sh          # --shim-only to skip the compaction daemon
```

`install.sh` backs up and edits your VS Code user settings, generates a launchd plist with absolute
paths, and loads it. **Sessions already running keep their old process** — restart a session (or
open a new one) before it gets a port.

```sh
./compactd.py --status     # "✓" in the port column means the shim is live for that session
./uninstall.sh             # removes both
```

macOS only, and VS Code only. A terminal `claude` never goes through the extension, and its input
is a tty rather than stream-json; `TIOCSTI` — the one candidate for injecting into a tty — returns
`EPERM` on current macOS, so terminal sessions have no equivalent channel.

## The compaction rule

Fire when idle time is in **`[50 min, 58 min)`** and context is **≥ 450k tokens**.

The upper bound is the part that is easy to get wrong. With a 1-hour cache tier (write `2.0x`,
read `0.1x` of base input):

| | cost when the user returns |
|---|---|
| do nothing | `2.0 · C` |
| compact **while warm** | `0.1 · C` for the summary, then `2.0 · C′` |
| compact **after the cache expired** | `2.0 · C` for the summary, *then* `2.0 · C′` |

So compacting cold is **strictly worse than doing nothing** — you pay the full cold rebuild anyway
and then pay again. Any "compact after N seconds idle" rule without an upper bound is
negative-expected-value every time it fires late (laptop asleep, daemon restarted, machine
suspended). Past the window, the right move is to leave the session alone.

The lower bound and the context floor come from measurement, not taste. Backtesting every
transcript under `~/.claude/projects` (`analyze_sessions.py`), the probability that a session is
used again after going quiet rises monotonically with how much context it was holding:

| context when it went quiet | came back |
|---|---|
| < 100k | 67.5% |
| 100–250k | 84.6% |
| 250–500k | 91.7% |
| > 500k | 97.5% |

Context size is therefore its own predictor — no per-session behavioural model is needed. Measured
compaction ratio across 142 real compactions: `C′/C = 0.203` (median).

**Compaction is not free in the other direction.** You trade conversation detail for the summary.
That is why the floor is 450k rather than as low as the economics alone would allow.

Check your own tier before trusting these numbers — a session on the 5-minute tier needs a much
tighter window:

```sh
grep -ho '"ephemeral_[0-9]*[hm]_input_tokens":[0-9]*' ~/.claude/projects/*/*.jsonl \
  | awk -F'[:"]' '{t[$2]+=$NF} END{for(k in t) print k, t[k]}'
```

## Operating it

```sh
compactd.py --status      # per-session verdict; first line is the daemon heartbeat
compactd.py --dry-run     # decide, log, send nothing

# Exercise the whole path without waiting an hour:
CC_COMPACT_IDLE_MIN=0 CC_COMPACT_IDLE_MAX=999999 CC_COMPACT_CTX=200000 \
  compactd.py --dry-run

tail -f ~/.local/state/claude-auto-compact/compactd.log
```

The daemon is silent unless it acts, so `--status`'s heartbeat line is how you tell "running with
nothing to do" from "not running".

Two behaviours worth knowing:

- **The same conversation can be open in two windows.** Two live processes then share one
  `sessionId` and one transcript. The daemon deduplicates, because compacting both means paying for
  two summaries of the same thing.
- **Compaction is slow on large contexts** and writes nothing to the transcript while it runs. An
  842k-token session took **3m16s** end to end. Silence after the injection is expected.

## Surviving upgrades

| Upgrade | Effect |
|---|---|
| VS Code itself | None. The setting lives in user settings, not in the extension. |
| Claude Code extension | None. The real binary path is whatever the extension passes as argv[1], so a new version directory is followed automatically. |
| Standalone `claude` npm package | Irrelevant; the extension uses its own bundled binary. |

The real risk is the extension changing the `executableArgs` convention. The shim degrades instead
of breaking: if argv[1] is not an executable it locates a bundled binary itself and runs that,
losing only the side channel; if it cannot find one it exits 2 with instructions. **It never leaves
you unable to start a session.** After an extension upgrade, `compactd.py --status` showing `✓` on
a newly started session is the confirmation.

## Prior art

| Project | What it does | Why it does not cover this |
|---|---|---|
| [cache-keepalive](https://github.com/yujiachen-y/claude-code-cache-keepalive) | `Stop` hook sleeps 240s, then injects a synthetic turn to refresh the TTL | Opposite strategy (keep warm vs. shrink), and hardcodes the 5-minute tier |
| [CacheWarden](https://github.com/Efs-O/CacheWarden) | VS Code extension, pings before TTL expiry | Same |
| [claude-code-cache-fix](https://github.com/cnighswonger/claude-code-cache-fix) | Fixes a cache regression on resumed sessions | Different problem |

Upstream feature request: [anthropics/claude-code#66115](https://github.com/anthropics/claude-code/issues/66115)
(`autoCompactOnIdleSeconds`), open and marked stale. Note that its proposed shape — a single idle
threshold — has no upper bound and assumes the 5-minute tier.

## License

MIT. See [LICENSE](LICENSE).
