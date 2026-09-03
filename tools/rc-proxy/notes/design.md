# rc-proxy design notes

Why the code is shaped the way it is. Each item here is a decision that cost something to learn.
Read [../README.md](../README.md) first for what the tool does.

---

## Why a forward proxy at all

`ANTHROPIC_BASE_URL` is one switch for all traffic. Point it at a gateway and the control plane goes
there too: Remote Control is switched off by a gate, Artifact publishing stops, and so does
anything else that talks to Anthropic's own endpoints. `ANTHROPIC_AUTH_TOKEN` fails the same gate by
reclassifying the session as API-key auth.

Only inference needs to move. A forward proxy can move only inference, because it sees the request
path. That is the entire reason this exists rather than a base-URL setting.

---

## Why Go instead of a mitmproxy addon

The first version of this was mitmproxy plus a Python addon. mitmproxy is single-threaded asyncio
with no worker mode, so all traffic from every session shares one event loop and any blocking
operation stalls everyone. With a few dozen concurrent Claude Code sessions, one slow request
amplified into second-scale event-loop stalls, connection resets in batches, and client-side
initialization timeouts.

Two contributors were measured in the Python version. A full parse and re-serialize of every
request body cost 43 ms per inference request, all of it blocking. And the per-request logger did
`makedirs`, `open`, `close` on every line.

Go gives one goroutine per connection and uses every core, so one slow request cannot hold up
anyone else. There are only two rewrite rules here, so the code is a fraction of a general-purpose
interception framework and there is much less that can go wrong.

---

## Why HTTP/1.1 in both directions

**Toward the client**, the ALPN list advertises only `http/1.1`. Claude Code downgrades on its own
and loses no functionality. That removes a whole class of h2-plus-streaming edge cases.

**Toward Anthropic**, `ForceAttemptHTTP2` is set false, in the reverse proxy's `Transport`. It used to be true, to save
connections. The result was that RC long polls, heartbeats and log uploads from dozens of sessions
multiplexed onto a handful of H2 connections to Anthropic, so one `INTERNAL_ERROR` from the far end
timed all of them out together. Measured on 2026-08-25: 383 H2 `INTERNAL_ERROR`s within one process
lifetime, and the stalled periods came with a storm of TLS handshake timeouts. Under HTTP/1.1 a
dead connection kills only its own request.

The connection saving was real. The shared failure domain was worse.

---

## Why new TLS handshakes are capped at 4 concurrent

Dropping H2 means more connections, and a proxy restart makes dozens of sessions reconnect at the
same instant. Without back pressure that produced TLS handshake timeouts at the Anthropic end,
after which every client retried and made it worse. A positive feedback loop.

`dialAnthropicTLS` holds a 4-slot gate around the TCP connect plus handshake only. Established
connections, including RC long polls, are never throttled. Once a handshake completes, each long
poll has its own HTTP/1.1 connection and goes at its own pace.

---

## Why an unset token routes to `127.0.0.1:1`

```go
if poolToken == "" {
    r.URL.Scheme, r.URL.Host = "http", "127.0.0.1:1" // cannot connect
    return
}
```

Port 1 is unroutable, so the request fails immediately and visibly. The alternative would be
forwarding inference to the real Anthropic, which looks like success and silently spends
subscription quota you believed was not in use. You would find out from the bill. A tool that
cannot do the thing you asked for should fail, not do a different thing.

`main()` also logs a `WARN` at startup when the token is missing.

---

## Why non-Anthropic `CONNECT` is a raw tunnel

We neither read nor rewrite that traffic, so decrypting it is pure cost. One measured session
carried 1,139 such connections in the old version, all decrypted for nothing. Now they are byte
copies in two goroutines, and TLS between the client and that host stays end to end.

---

## Why the request body is never read whole

An inference request body is the entire conversation history. Bodies of 4 MB are normal here. The
only thing that needs rewriting is the model name, and `"model"` sits at the front of the JSON, so
only the first 4 KB is read and rewritten. The rewritten head and the untouched remainder are
stitched back together with an `io.MultiReader` and forwarded as a stream.

The rewrite itself removes a context-variant suffix, turning `claude-fable-5[1m]` into
`claude-fable-5`. Claude Code learns those suffixed ids from Anthropic. Gateways register bare
names, and a suffixed name comes back as "model does not exist".

The same asymmetry appears in the response direction. Streaming responses are not touched at all.
The bootstrap response and inference error bodies are small and are read in full, and error bodies
are capped at 4 KB.

---

## Why `FlushInterval: -1`

Remote Control's inbound direction is a long poll on `/bridge`, and SSE inference replies are the
same shape. Any buffering closes the phone-to-computer channel. `-1` flushes on every write.

Anything added later that reads a whole response body will break this. It is the most fragile
invariant in the file.

---

## Why control-plane requests set `r.Close = true`

RC long polls are frequently cancelled by the client. Reusing those upstream HTTP/1.1 connections
gradually poisoned the `Transport`: new control-plane requests stopped receiving responses while a
direct connection to Anthropic still worked fine. Closing the connection at the end of every
control-plane request costs one handshake and removes the failure. Inference still reuses
connections, because those go to `localhost:8317` and are cheap.

---

## Why only two POST paths get a replayable body

Go's H2 transport retries peer `PROTOCOL_ERROR` and `REFUSED_STREAM` automatically, but a POST
whose body has already been written can only be replayed if `GetBody` is set. Without it, one error
on a shared connection made the heartbeats on that connection fail with
`cannot rewind body after connection loss`.

`GetBody` is added for exactly two paths, `/api/event_logging/v2/batch` and
`/v1/code/sessions/*/worker/heartbeat`, both idempotent and both small, with a 1 MiB ceiling.
Inference requests, worker events, registration and any body of unknown length are left alone.
Re-sending a POST that has side effects is worse than an occasional failure.

This predates the switch away from upstream H2 and is kept because it costs nothing.

---

## Why the pool model list is persisted, and why it is a union

Injection is one shot per session. The `bootstrap` response arrives once, at session start. A
session that starts during a gateway restart, which takes seconds, would permanently have no
gateway models in its picker, and selecting one would report "It may not exist". That happened, and
the cause is very hard to guess from the symptom.

So the list is written to `~/.local/state/ccw/rc-proxy/pool-models.json` and read back at cold
start. Model lineups change on a scale of weeks, so a list that is a few minutes stale is far
better than none.

The injected list is the union of models live now and models seen in the last 7 days, live ones
first. Gateways drop rate-limited models out of `/v1/models` while they cool down. Measured once at
13 models dropping to 10, and the three missing were exactly the ones whose quota had run out. With
only the live list injected, a model vanishes from the picker precisely while it is cooling, and
selecting it says "It may not exist". With the union, it stays selectable and gives an actionable
quota error instead of a nonsensical one. Entries older than 7 days are dropped, so a genuinely
retired model disappears on its own.

---

## Why `Accept-Encoding` is stripped from the bootstrap request

The bootstrap response has to be modified, which means it has to be plaintext. When the client
sends its own `Accept-Encoding: gzip`, Go's `Transport` forwards the compressed bytes untouched,
and code that cannot decompress them has to pass them through unmodified. That is exactly why the
first version of the injection silently did nothing.

Deleting the header makes the `Transport` add `gzip` itself and decompress transparently. It is
done for that one path only. Every other response stays compressed on the wire.

---

## Why errors from the gateway are logged verbatim

Claude Code renders every model-level failure as one sentence: "There's an issue with the selected
model (X). It may not exist or you may not have access to it." A quota that ran out, an unsupported
feature and an upstream 5xx all look identical from the seat. The `POOL-ERR` line in `route.log` is
the only place the real reason exists.

Only responses with status 400 and above are read, and only the first 4 KB. Successful streaming
responses are not touched.

---

## Why the CA comes from mitmproxy

`~/.mitmproxy/mitmproxy-ca.pem` holds the private key and the certificate in one file, so it is
parsed block by block and both are picked out. RSA, PKCS8 and EC keys are all handled, since which
one you have depends on the mitmproxy version that created it. Leaf certificates are minted per
host with a P-256 key, cached in memory, and valid for a year.

Reusing that CA means anyone already running a mitmproxy-based setup changes nothing on the client
side. `NODE_EXTRA_CA_CERTS` keeps pointing at the same file it always did.

---

## What a restart does and does not recover

`/v1/messages` is one long streaming response. When the process dies the TCP connection resets and
that generation is finished. Nothing can resume it.

What a restart does recover is the listener. New `CONNECT`s are accepted immediately, so old VS
Code windows do not need to be closed: the RC heartbeat reconnects on its own, and a retry or the
next message works. Making that fast was the goal. Continuing a generation that was cut
off is not available at this layer.

Each intercepted `CONNECT` is handed to a real `http.Server` wrapped around the single connection
(`oneShotListener`), which is what gets keep-alive, chunked encoding and multiple requests per
connection handled correctly instead of reimplemented. `ReadHeaderTimeout` is 30s. There is
deliberately no `WriteTimeout`, since RC's `/bridge` long poll would be cut in half by one.

---

## Logging

Per-request logging is off by default. One VS Code startup makes thousands of requests, and writing
a line for each becomes the bottleneck rather than measuring it. `CLAUDE_RC_PROXY_VERBOSE=1` turns
it on for a session.

What is always logged: startup, model injections, upstream errors, and `POOL-ERR` bodies. The file
is opened in append mode. Any rotation belongs in a size check at startup, since this program runs
no timers and there is no other cheap place to put one.
