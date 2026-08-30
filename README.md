# claude-code-auto-compactor

Drive a running Claude Code session from an external process, using the VS Code extension's own
launch hook — plus an idle auto-compactor built on it.

- **`shim/cc-stdin-shim`** gives every VS Code Claude Code session a side channel at
  `/tmp/cc-inject/<pid>.sock`. Write a line into it and the session behaves as if you had typed
  that line into the composer, slash commands included.
- **`compactd.py`** is the reference consumer: it sends `/compact` to sessions that went idle
  holding a large context, while the prompt cache is very likely still warm.

Ignore `compactd.py` if you only want the channel. macOS + VS Code only.

## Why this saves anything

Claude re-reads the whole conversation every time you send a message. To stop that costing a
fortune it is kept as a **warm copy** — reading from it costs about a twentieth of what building
it costs. The warm copy is discarded after an hour of silence, and the next message rebuilds one
at full price, for however large the conversation has grown.

Compaction swaps the conversation for a summary, about a fifth of the size in practice. The whole
question is *when*:

```
  last turn                                                       cache expires
      │                                                          │
      ├───────────────── warm copy alive (1 h) ──────────────────┤─────────►
      │                                ▲                         │
      │                        ┌───────┴────────┐                │
      │                        │  compact here  │                │
      │                        │  50 - 58 min   │                │
      │                        └────────────────┘                │
      │                                                          │
      │  the summary reads the warm copy, so writing             │  the summary must
      │  it is nearly free -- and the new warm copy              │  rebuild everything
      │  it leaves behind is small                               │  first: full price
```

Real numbers from one 842k-token conversation that compacted to 13.5k, in input-token
equivalents:

```
  cost of picking that conversation back up tomorrow

  do nothing            ████████████████████████████████████████   1,684k
  compact while warm    ███                                          111k     ← 15x cheaper
  compact once cold     ████████████████████████████████████████▏  1,711k
                        └── rebuild you were trying to avoid ──┘
```

The bottom bar is why the rule has an **upper** bound too. Compacting cold pays the expensive
rebuild just to write the summary — for the act of resuming, worse than doing nothing. (Over a
longer horizon it recovers: each later warm turn saves `0.1·(C−C′)`, clearing the extra `2.0·C′`
after roughly six turns. It is a bad bet, not a disaster. An idle session gives no signal about
whether those turns are coming, so past the window this daemon declines the bet.)

## Install

```sh
git clone https://github.com/dthinkr/claude-code-auto-compactor
cd claude-code-auto-compactor
./install.sh                 # --shim-only to skip the daemon;  ./uninstall.sh to undo
```

It backs up and edits your VS Code user settings, writes a launchd plist, and loads it.
**Sessions already running keep their old process** — restart one, then `./compactd.py --status`
should show `yes` in the port column.

## The rule

Fire when idle is in **`[50 min, 58 min)`** and context is **≥ 450k**. Both bounds and the floor
are settable via `CC_COMPACT_IDLE_MIN` / `CC_COMPACT_IDLE_MAX` / `CC_COMPACT_CTX`, which is also
how you exercise the whole path without waiting an hour.

The window assumes a 1-hour cache tier. **Check yours** — a 5-minute tier needs a much tighter
one:

```sh
grep -ho '"ephemeral_[0-9]*[hm]_input_tokens":[0-9]*' ~/.claude/projects/*/*.jsonl \
  | awk -F'[:"]' '{t[$2]+=$NF} END{for(k in t) print k, t[k]}'
```

The 450k floor is empirical but from one machine: backtesting 168 sessions over 45 days
(`analyze_sessions.py`), the chance a session was used again after going quiet ran 67.5% below
100k, 84.6% at 100–250k, 91.7% at 250–500k and 97.5% above 500k. Bigger context is its own
predictor, so no behavioural model was needed — untested for other working styles. Measured
compaction ratio across 142 real compactions: `C′/C = 0.203`. Compaction also costs conversation
detail, which is the other reason the floor is not lower.

```sh
compactd.py --status      # per-session verdict; first line is the daemon heartbeat
compactd.py --dry-run     # decide and log, send nothing
tail -f ~/.local/state/claude-auto-compact/compactd.log
```

The daemon is silent unless it acts, so the heartbeat is how you tell "running, nothing due" from
"not running".

## How it works

Claude Code wraps or de-slashes every input path that is not a human typing — `Stop` hook `block`
reasons, the cross-session peer socket, Remote Control events — so none of them can invoke a slash
command. The session's own stdin is the exception: the extension runs the CLI with
`--input-format stream-json` over a socketpair, and a message arriving there has no `origin`
field, which Claude Code reads as human. The extension's documented
`claudeCode.claudeProcessWrapper` setting is enough to get a handle on that stdin; the shim execs
the real binary unchanged and multiplexes one socket into it. stdout/stderr are inherited
untouched.

[FINDINGS.md](FINDINGS.md) has the full record: the eight injection routes that *don't* work,
`autoCompactWindow` and cache-tier semantics, and three measurement mistakes worth not repeating.

## Caveats

- **The channel accepts arbitrary text**, not just `/compact` — anything running as your user can
  type into your sessions. Not a privilege boundary (whoever can edit your VS Code settings can
  already run code as you), but set `CC_INJECT_ALLOW='/compact'` to make it single-purpose.
- **`claudeProcessWrapper` is documented; missing-origin-as-human is not.** That part is internal
  behaviour and could change in any release.
- **Upgrades are fine.** The setting lives in user settings, and the real binary path is whatever
  the extension passes as `argv[1]`. If that convention ever changes the shim finds a bundled
  binary itself and runs it, losing only the side channel — it never leaves you unable to start a
  session.
- **Terminal sessions are not covered.** They never go through the extension, and their input is a
  tty; `TIOCSTI` returns `EPERM` on current macOS.

Related: [cache-keepalive](https://github.com/yujiachen-y/claude-code-cache-keepalive) and
[CacheWarden](https://github.com/Efs-O/CacheWarden) take the opposite approach — keep the cache
warm rather than shrink the context — and both hardcode the 5-minute tier. Upstream request:
[anthropics/claude-code#66115](https://github.com/anthropics/claude-code/issues/66115).

## License

MIT.
