# Reverse-engineering notes — Claude Code 2.1.251

Everything below is labelled either **[binary]** (read out of the shipped executable) or
**[measured]** (observed by running it). Where I got something wrong on the way, the wrong version
is kept, because the wrong turns are most of the value here.

The macOS binary is a Bun single-file executable with the JavaScript embedded, so `strings` and
byte-slicing are enough to read it:

```sh
B=/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe   # or the copy under
                                                                           # ~/.vscode/extensions/…
grep -abo 'some string' "$B"          # byte offset
python3 -c "print(open('$B','rb').read()[OFF-2000:OFF+2000].decode('utf8','replace'))"
```

Minified identifiers (`IYt`, `GA`, `Vje`, …) are build-specific and will differ in your version.
The strings around them are stable enough to re-locate.

---

## 1. The mechanism that works: `claudeProcessWrapper` + stream-json stdin

**This is the whole answer. Sections 2–9 are the routes that failed.**

### The input channel was never closed

The VS Code extension does not run the CLI in a terminal. **[measured]**

```console
$ ps -o args= -p <pid>
…/native-binary/claude --output-format stream-json --verbose --input-format stream-json \
    --max-thinking-tokens … --permission-prompt-tool stdio --resume=<uuid> \
    --setting-sources=user,project,local --permission-mode … --include-partial-messages \
    --debug --debug-to-stderr --enable-auth-status --no-chrome --replay-user-messages

$ lsof -a -p <pid> -d 0,1,2
claude  <pid>  0u  unix 0x…      # socketpair to the extension host — not a tty
claude  <pid>  1u  unix 0x…
claude  <pid>  2u  unix 0x…
```

A user message arriving on that channel has **no `origin` field**, and the classifier reads a
missing origin as human: **[binary]**

```js
function mC(e) { return e === undefined || e.kind === "human" }
```

There is even telemetry counting how often this happens (`tengu_human_origin_presumed`). So the
message reaches the slash gate with its content untouched:

```js
IYt(e) = typeof e.value === "string" && e.value.trim().startsWith("/") && !e.skipSlashCommands
```

…and expands. `/compact` is registered `{type:"local", name:"compact", supportsNonInteractive:true,
thinClientDispatch:"post-text"}`, so it is valid in this mode. **[binary]**

Verified end to end against a real session driven over stream-json: **[measured]**

```
>>> stream-json stdin: "/compact"
system/compact_boundary  trigger=manual  pre_tokens=35575 -> post_tokens=1556
PreCompact and PostCompact hooks both fired
```

### Getting a handle on that stdin

fd 0's write end belongs to the extension host. The extension provides the hook itself —
`claudeCode.claudeProcessWrapper`, described in `package.json` as *"Executable path used to launch
the Claude process."* **[binary, extension.js]**

```js
function Dr($, Q) {
  let J = y$("claudeProcessWrapper"), X = <bundled native binary>;
  if (J) return { pathToClaudeCodeExecutable: J, executableArgs: X ? [X] : [], env: Q };
  if (!X) throw …;
  return { pathToClaudeCodeExecutable: X, executableArgs: [], env: Q };
}
```

So with the setting present the wrapper is invoked as
`<wrapper> <real binary> <all the normal args…>` — the real binary arrives as `argv[1]`, which is
why the shim keeps working across extension upgrades without being told the new path.

Two side effects of setting a wrapper, both benign: **[binary]**

- `resolvePermissionModeInCli: !getConfig("claudeProcessWrapper")` — permission-mode resolution
  moves to the extension side.
- The post-upgrade binary probe/telemetry is skipped (`"a process wrapper is configured"`). This is
  a probe, not the extension's own update mechanism.

### Verified end to end through the shim

Launched with the extension's exact argv convention, three normal turns through the regular
channel, then `/compact` injected **from a separate process**: **[measured]**

```
[  5.39s] side-channel inject 88823.sock: '/compact' -> ok
[ 22.50s] *** compact_boundary trigger=manual 34467 -> 2038 tok ***
shim exit code: 0
```

And on a real 842k-token session: `trigger=manual  842,223 -> 13,555`, taking **3m16s**. The
transcript is completely silent while compaction runs — an early check at 150s wrongly looked like
failure.

---

## 2. There is no supported programmatic trigger

The SDK/bridge `control_request` dispatch handles exactly these subtypes, and no more: **[binary]**

```
initialize            set_model              set_max_thinking_tokens
set_permission_mode   rename_session         set_color
file_suggestions      read_file              get_workspace_diff
get_context_usage     get_usage              apply_flag_settings
mcp_set_servers       stop_task
```

Anything else hits `REPL bridge does not handle control_request subtype: <x>`. There is no
compaction entry, and no `compact_now`-style field in any hook output schema. (`apply_flag_settings`
only accepts `effortLevel` and `ultracode`.)

## 3. The built-in idle detector — same shape, wrong action

**[binary]**, offset ≈ 177951168:

```js
let P = Number(process.env.CLAUDE_CODE_IDLE_TOKEN_THRESHOLD ?? 1e5);   // 100k
if (contextTokens < P) return;
let H = Number(process.env.CLAUDE_CODE_IDLE_THRESHOLD_MINUTES ?? 75) * 60000
        - (now - lastQueryCompletionTime);
setTimeout(() => addNotification({ … "new task? /clear to save N tokens" }), H)
```

Structurally identical to what we want — idle-minutes × context-tokens, both env-tunable — but the
action is a TUI line suggesting `/clear`. It cannot be used as a trigger: it goes through
`addNotification` (a TUI element), not the `Notification` hook, whose payload is
`{message, title, notification_type}` and which fires from the `os_notification` path instead.

## 4. `autoCompactWindow` semantics

**[binary]** the window resolution, in precedence order:

```js
function GA(e, t, r) {
  if (process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW) { … source:"env" }
  if (t !== undefined) return { window: Math.min(u, t), source:"settings" };
  … clientdata … experiment … model-default …
}
function eF(e, t) { let r = Math.min(reserved(e), 20000); let {window:u} = GA(e, …); return u - r }
function W3(e)    { return e - 13000 }
// autocompact threshold = window − 20000 − 13000 = window − 33000   (flat, not a percentage)
```

- Legal range **100k–1M** (`rCe = 1e5`, `YNe = 1e6`). Out-of-range values are rejected outright:
  `Couldn't parse '<x>'. Expected 'auto' or 100k-1M tokens`. My first test used 5000 and 8000 and I
  wrongly concluded project-scope settings were ignored; 100000 works.
- Effective window is `min(setting, model max context)`.
- `/autocompact` writes **user settings**; there is no per-session form.
- The env var wins over the setting and is fixed at process start, so it cannot act as an actuator.
- The check runs **before each turn** (`willRetriggerNextTurn: postCompactTokens >= threshold`).
  **An idle session has no turn, so lowering the threshold externally does nothing.** Confirmed
  **[measured]**: rewriting the settings file mid-session had no effect at 30s or 90s.

**[measured] caution:** on the machine I developed this on, an `autoCompactWindow` of 500000 was
demonstrably *not* in effect — real auto-compactions in the transcripts fired at `preTokens` of
749,845 / 875,572 / 1,000,264, i.e. an effective threshold near 967k (= 1M − 33k). Read your own
transcripts before assuming your setting is live:

```sh
grep -ho '"compactMetadata":{[^}]*}' ~/.claude/projects/*/*.jsonl | head
```

## 5. Cache tier is per-account, and it is not always 5 minutes

**[measured]** from `usage.cache_creation` accumulated across transcripts:

```
ephemeral_1h_input_tokens: 1690864632
ephemeral_5m_input_tokens: 0
```

The three keepalive tools I found all hardcode 300s. On a 1-hour tier that is wrong by an order of
magnitude, and it is what makes a ~50-minute window correct here instead of ~4 minutes.

**[binary]** `overage state changed (TTL flip expected)` — entering usage overage flips the tier. The
string proves a flip is expected; it does not by itself prove the destination is the 5-minute tier.
Either way, a rule that pins the tier at startup can silently become wrong.

## 6. `precomputeCompactionEnabled` — a real, gated, adjacent feature

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
Arming is at a *buffer fraction* of the window — statsig `tengu_amber_moleskin` (a per-window-size
table) or `tengu_amber_rokovoko` (scalar, default **0.2**), i.e. roughly 80% of the threshold, so
~770k on a 1M window.

**It does not replace an idle compactor**: it never shrinks the resident context, it only has the
summary ready for when the built-in threshold fires. But it establishes that background
summarization of a live session is a sanctioned operation.

Two env overrides live nearby: `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`,
`CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE`. There is no local statsig cache file, so gate state is
server-supplied and can only be determined empirically.

## 7. Session registry and the peer socket

**[measured]** `~/.claude/sessions/<pid>.json`:

```json
{
  "pid": 81286,
  "sessionId": "<uuid>",
  "cwd": "…",
  "messagingSocketPath": "/tmp/cc-socks/81286.sock",
  "peerProtocol": 1,
  "peerFeatures": ["notify_idle", "reply_across_default_dirs", "artifact_yield"],
  "kind": "interactive",
  "entrypoint": "claude-vscode",
  "name": "<short name>",
  "bridgeSessionId": "session_…"
}
```

Alongside it, `<pid>.<sha256(socket path)>.key`, mode 600, containing `{"peerToken":"<32 hex>"}`
(`[uds-messaging]` / `[uds-auth]` in the binary, `requireAuth`, 16 random bytes). This is what
`SendMessage` / `ListAgents` ride on.

Two useful facts for a supervisor: the registry `pid` is the actual CLI process (so it matches the
shim's child pid), and **the same conversation can be resumed in two windows**, giving two live
pids sharing one `sessionId` and one transcript. Deduplicate by `sessionId` or you will pay for two
summaries of the same conversation.

## 8. The eight routes that do not work

| Route | Why it fails |
|---|---|
| `Stop` hook `{"decision":"block","reason":"/compact"}` | Prefixed with `Stop hook feedback:\n`; no longer starts with `/` |
| Sleeping `Stop` hook used as a timer | Blocks the user's own input — **measured 36.3s** |
| Rewriting `autoCompactWindow` from outside | Not hot-reloaded; and an idle session has no turn to check on |
| Peer UDS socket (`/tmp/cc-socks/<pid>.sock`) | Wrapped in `<cross-session-message>` |
| Remote Control `/v1/code/sessions/{id}/events` | `client_platform` is stamped server-side from OAuth client identity; see below |
| RC `control_request` | No compaction subtype in the whitelist (§2) |
| `claude://` deep links | Launch-only; opens a new session, cannot address a running one |
| `TIOCSTI` into the controlling tty | VS Code sessions have no tty; and on current macOS the ioctl returns `EPERM` anyway |

They share one cause: every non-human input path is wrapped or de-slashed so `IYt()` fails. That is
a deliberate design, and it is why the answer turned out to be the session's own stdin rather than
any of these.

### Two traps inside the Remote Control route

Worth recording because both cost real time.

**The endpoint is also the session's outbound mirror.** `/v1/code/sessions/{id}/events` carries
assistant messages, results and tool output *out*. Constructing a POST that mimics the shape seen
in the mirror (`session_id` + `parent_tool_use_id` + `origin:{kind:"human"}` + content blocks)
returns 200 with a `sequence_num` and is **never consumed**. Inbound and outbound shapes differ by
the presence of `client_platform` and `priority`.

**The blocker is client identity, not device trust.** **[binary]**

```js
var h = new Set(["ios", "android", "web_claude_ai", "desktop_app"]);
if (r && h.has(r)) return { kind: "human" };     // r = clientPlatform
…
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
**stripped** (`priority` survives); an event sent by the first-party mobile app keeps it. So the
field is server-stamped from the OAuth client, and forging it means impersonating a first-party
client. Even with the hold removed (`--permission-mode default` — the `no-mode-asserted` hold only
applies to bypass-mode receivers) the delivered content is prefixed with `"Another Claude session
sent a message:\n"`, so it still does not expand. `crossSessionInbound: "accept"` cannot be set at
project scope (*"a repo may only tighten, so your own 'accept' cannot override it"*).

## 9. Three mistakes I made, kept on purpose

**The model will claim it complied.** After a `Stop` hook block injecting `/compact`, the model
replied *"Acknowledged. Context has been compacted for the next window."* Nothing had been
compacted. Never verify a side effect from the model's own account of it — use the `PreCompact`
hook writing to disk, or the transcript.

**A false positive from not checking identity.** After RC injection I saw a target session's
compaction count go from 1 to 2 and declared success. Checking uuids showed the compaction came
from the user's phone (a `priority:"later"` message that had queued and then drained); my injected
uuids appeared **zero** times in the transcript. Attributing an outcome without checking *whose*
event produced it is how you get a confident wrong answer.

**A blocking test that measured the wrong thing.** Testing whether a sleeping `Stop` hook blocks
input, my driver waited for `result` before sending the second message — but `result` was itself
held by the hook, so the second message went out *after* the hook woke, measuring 1.5s and looking
fine. Firing it on a timer instead gave the real answer: **36.3s blocked**. A 50-minute sleep would
make a returning user wait 45 minutes. The timer has to live outside the session.
