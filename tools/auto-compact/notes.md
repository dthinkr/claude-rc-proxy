# auto-compact: how the mechanism was found, and what did not work

Read against **Claude Code 2.1.251**. Minified identifiers below (`IYt`, `GA`, `Vje`) are
build-specific and will differ in your version. The string literals around them are stable enough
to re-locate.

Every claim is labeled **[binary]** (read out of the shipped executable) or **[measured]**
(observed by running it). Where I got something wrong on the way, the wrong version is kept,
because the wrong turns are most of the value here.

For how to read the shipped binary at all, plus cache tiers and the session registry, see
[docs/claude-code-internals.md](../../docs/claude-code-internals.md).

---

## The mechanism that works

Summarized in [How it works](README.md#how-it-works). The two pieces of evidence behind it:

A user message arriving on the stream-json channel has no `origin` field, and the classifier reads
a missing origin as human. **[binary]**

```js
function mC(e) { return e === undefined || e.kind === "human" }
```

There is telemetry counting how often this happens (`tengu_human_origin_presumed`). The message
then reaches the slash gate with its content untouched:

```js
IYt(e) = typeof e.value === "string" && e.value.trim().startsWith("/") && !e.skipSlashCommands
```

and expands. `/compact` is registered as
`{type:"local", name:"compact", supportsNonInteractive:true, thinClientDispatch:"post-text"}`, so
it is valid in this mode. **[binary]**

Verified end to end against a real session driven over stream-json: **[measured]**

```
>>> stream-json stdin: "/compact"
system/compact_boundary  trigger=manual  pre_tokens=35575 -> post_tokens=1556
PreCompact and PostCompact hooks both fired
```

And through the shim, with `/compact` injected from a separate process: **[measured]**

```
[  5.39s] side-channel inject 88823.sock: '/compact' -> ok
[ 22.50s] *** compact_boundary trigger=manual 34467 -> 2038 tok ***
shim exit code: 0
```

The wrapper hook itself: **[binary, extension.js]**

```js
function Dr($, Q) {
  let J = y$("claudeProcessWrapper"), X = <bundled native binary>;
  if (J) return { pathToClaudeCodeExecutable: J, executableArgs: X ? [X] : [], env: Q };
  if (!X) throw ...;
  return { pathToClaudeCodeExecutable: X, executableArgs: [], env: Q };
}
```

Two side effects of setting a wrapper, both benign: **[binary]**

- `resolvePermissionModeInCli: !getConfig("claudeProcessWrapper")`. Permission-mode resolution
  moves to the extension side.
- The post-upgrade binary probe and its telemetry are skipped, with the reason string
  `"a process wrapper is configured"`. This is a probe. It is not the extension's own update
  mechanism.

---

## There is no supported programmatic trigger

The SDK and bridge `control_request` dispatch handles exactly these subtypes and no more:
**[binary]**

```
initialize            set_model              set_max_thinking_tokens
set_permission_mode   rename_session         set_color
file_suggestions      read_file              get_workspace_diff
get_context_usage     get_usage              apply_flag_settings
mcp_set_servers       stop_task
```

Anything else hits `REPL bridge does not handle control_request subtype: <x>`. There is no
compaction entry and no `compact_now`-style field in any hook output schema. `apply_flag_settings`
accepts only `effortLevel` and `ultracode`.

---

## The built-in idle detector has the right shape and the wrong action

**[binary]**, at offset around 177951168:

```js
let P = Number(process.env.CLAUDE_CODE_IDLE_TOKEN_THRESHOLD ?? 1e5);   // 100k
if (contextTokens < P) return;
let H = Number(process.env.CLAUDE_CODE_IDLE_THRESHOLD_MINUTES ?? 75) * 60000
        - (now - lastQueryCompletionTime);
setTimeout(() => addNotification({ ... "new task? /clear to save N tokens" }), H)
```

Idle minutes crossed with context tokens, both tunable by environment variable. Structurally this
is what the daemon does. The action is a TUI line suggesting `/clear`, so it cannot be used as a
trigger. It goes through `addNotification`, which is a TUI element, and not through the
`Notification` hook, whose payload is `{message, title, notification_type}` and which fires from the
`os_notification` path.

---

## `autoCompactWindow` semantics

**[binary]** the window resolution, in precedence order:

```js
function GA(e, t, r) {
  if (process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW) { ... source:"env" }
  if (t !== undefined) return { window: Math.min(u, t), source:"settings" };
  ... clientdata ... experiment ... model-default ...
}
function eF(e, t) { let r = Math.min(reserved(e), 20000); let {window:u} = GA(e, ...); return u - r }
function W3(e)    { return e - 13000 }
// autocompact threshold = window - 20000 - 13000 = window - 33000   (flat, not a percentage)
```

- Legal range is 100k to 1M (`rCe = 1e5`, `YNe = 1e6`). Out-of-range values are rejected outright
  with `Couldn't parse '<x>'. Expected 'auto' or 100k-1M tokens`. My first test used 5000 and 8000
  and I wrongly concluded that project-scope settings were ignored. 100000 works.
- The effective window is `min(setting, model max context)`.
- `/autocompact` writes user settings. There is no per-session form.
- The environment variable wins over the setting and is fixed at process start, so it cannot act as
  an actuator.
- The check runs before each turn (`willRetriggerNextTurn: postCompactTokens >= threshold`). **An
  idle session has no turn, so lowering the threshold from outside does nothing.** Confirmed
  **[measured]**: rewriting the settings file mid-session had no effect at 30s or at 90s.

**[measured] caution.** On the machine this was developed on, an `autoCompactWindow` of 500000 was
demonstrably not in effect. Real auto-compactions in the transcripts fired at `preTokens` of
749,845, 875,572 and 1,000,264, so the effective threshold was near 967k, which is 1M minus 33k.
Read your own transcripts before assuming your setting is live:

```sh
grep -ho '"compactMetadata":{[^}]*}' ~/.claude/projects/*/*.jsonl | head
```

---

## `precomputeCompactionEnabled` is a real, gated, adjacent feature

**[binary]** a genuine user setting, surfaced in `/config` as "Precompute compaction":

> Precompute the compaction summary in the background before it is needed. Only applies when
> auto-compact is on.

```js
function Y$() {
  if (!autoCompactEnabled()) return false;
  if (!QB()) return false;
  if (!gate("tengu_sepia_moth", false)) return false;      // server-side statsig gate
  return setting("precomputeCompactionEnabled", default()).value
}
```

The summary is computed in the background and persisted to a sidecar (`summaryText`,
`summaryMessages`, `preserveUuids`, `preCompactTokens`, 7-day TTL, rehydrated on session resume).
Arming happens at a buffer fraction of the window, set by statsig `tengu_amber_moleskin` (a table
per window size) or `tengu_amber_rokovoko` (scalar, default 0.2), so roughly 80% of the threshold,
around 770k on a 1M window.

It does not replace an idle compactor, because it never shrinks the resident context. It only has
the summary ready for when the built-in threshold fires. It does establish that background
summarization of a live session is a sanctioned operation.

Two environment overrides live nearby: `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` and
`CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE`. There is no local statsig cache file, so gate state is
server-supplied and can only be determined empirically.

---

## The eight routes that do not work

| Route | Why it fails |
|---|---|
| `Stop` hook `{"decision":"block","reason":"/compact"}` | Prefixed with `Stop hook feedback:\n`, so it no longer starts with `/` |
| Sleeping `Stop` hook used as a timer | Blocks the user's own input. Measured at 36.3s |
| Rewriting `autoCompactWindow` from outside | Not hot-reloaded, and an idle session has no turn to check on |
| Peer UDS socket (`/tmp/cc-socks/<pid>.sock`) | Content wrapped in `<cross-session-message>` |
| Remote Control `/v1/code/sessions/{id}/events` | `client_platform` is stamped server-side from the OAuth client identity. See below |
| RC `control_request` | No compaction subtype in the whitelist |
| `claude://` deep links | Launch only. Opens a new session, cannot address a running one |
| `TIOCSTI` into the controlling tty | VS Code sessions have no tty, and on current macOS the ioctl returns `EPERM` anyway |

They share one cause. Every non-human input path is wrapped or de-slashed so the slash gate fails.
That is a deliberate design, and it is why the answer turned out to be the session's own stdin.

### Two traps inside the Remote Control route

Both cost real time.

**The endpoint is also the session's outbound mirror.** `/v1/code/sessions/{id}/events` carries
assistant messages, results and tool output outward. Constructing a POST that mimics the shape seen
in the mirror (`session_id` plus `parent_tool_use_id` plus `origin:{kind:"human"}` plus content
blocks) returns 200 with a `sequence_num` and is never consumed. Inbound and outbound shapes differ
by the presence of `client_platform` and `priority`.

**The blocker is client identity, not device trust.** **[binary]**

```js
var h = new Set(["ios", "android", "web_claude_ai", "desktop_app"]);
if (r && h.has(r)) return { kind: "human" };     // r = clientPlatform
...
warn("[bridge] demoting unwrapped inbound message to peer origin: client_platform=" + (r || "(absent)"))
```

**[measured]** with `--debug-file`:

```
SSETransport: Event seq=12 event_type=user payload_type=user
[bridge] demoting unwrapped inbound message to peer origin: client_platform=(absent)
[bridge:repl] Injecting inbound user message: /compact
[cross-session-inbound] held inbound peer message (cause=no-mode-asserted): from=unknown "/compact"
```

POSTing `"client_platform":"ios"` in the payload and then reading the event back shows the key
stripped, while `priority` survives. An event sent by the first-party mobile app keeps it. So the
field is server-stamped from the OAuth client, and forging it means impersonating a first-party
client. Even with the hold removed (`--permission-mode default`, since the `no-mode-asserted` hold
applies only to bypass-mode receivers) the delivered content is prefixed with
`"Another Claude session sent a message:\n"`, so it still does not expand. `crossSessionInbound:
"accept"` cannot be set at project scope: *"a repo may only tighten, so your own 'accept' cannot
override it"*.

---

## Three mistakes, kept on purpose

**The model will claim it complied.** After a `Stop` hook block injecting `/compact`, the model
replied "Acknowledged. Context has been compacted for the next window." Nothing had been compacted.
Never verify a side effect from the model's own account of it. Use the `PreCompact` hook writing to
disk, or read the transcript.

**A false positive from not checking identity.** After RC injection I saw a target session's
compaction count go from 1 to 2 and declared success. Checking uuids showed the compaction came
from the user's phone, a `priority:"later"` message that had queued and then drained. My injected
uuids appeared zero times in the transcript. Attributing an outcome without checking whose event
produced it is how you get a confident wrong answer.

**A blocking test that measured the wrong thing.** Testing whether a sleeping `Stop` hook blocks
input, my driver waited for `result` before sending the second message. `result` was itself held by
the hook, so the second message went out after the hook woke, measuring 1.5s and looking fine.
Firing it on a timer instead gave the real answer: 36.3s blocked. A 50-minute sleep would make a
returning user wait 45 minutes. The timer has to live outside the session.

---

## Measuring the threshold properly

The 450k floor in the first version of this tool came from `analyze_sessions.py`, which scores one
candidate at a time: would compacting here have paid for itself by the time the session was picked
back up. That question is well posed and the answer was right, and it is the wrong question. It
undercounts by a lot.

Compaction buys two things.

1. The cold rebuild after cache expiry shrinks from `2.0 x C` to `2.0 x C'`. One time.
2. Every later turn in that session reads `C'` instead of `C`. Per turn, for the rest of the
   session.

Term 2 is larger in any session that keeps going, and no per-event scoring can see it, because the
saving lands on turns that have not happened yet. It also cannot be estimated by summing over
candidates: sessions have many idle windows and their remaining-turn ranges overlap, so a naive sum
double-counts. A first attempt at exactly that produced a savings figure a hundred times larger
than the entire month's spend, which is a useful smell test for anyone repeating this.

`replay.py` measures it instead. It replays every session turn by turn, carries an offset for
context already compacted away, and bills each turn at its real recorded token counts scaled by the
smaller context. The no-compaction run reproduces actual recorded spend, which bounds the whole
thing: no policy can save more than the baseline.

Over 1,179 sessions and 302,213 turns:

- Cost splits 52% cache reads, 37% cache writes, 10% output. The read tax is the main term and it
  is linear in context size.
- The savings curve saturates hard. A 500k threshold captures 56 points of the bill with 44
  compactions. Pushing to 50k adds 15 more points and 222 more compactions.
- Marginal value per compaction falls from about $1,620 at 800k to about $6 at 50k.
- Spend is concentrated enough to explain that shape on its own. Top 5 sessions were 51% of spend,
  top 25 were 82%, and a single 38,627-turn session was a third of the month.

The three remaining biases are listed under [Caveats](README.md#caveats).

One non-finding worth recording: the dip at 600k in the swept curve is not real. Compacting earlier
changes which later windows still clear the threshold, and at high thresholds there are too few
events for that ordering effect to average out.
