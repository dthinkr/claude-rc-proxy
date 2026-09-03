# Pointing `ANTHROPIC_BASE_URL` at a gateway switches off Remote Control and Artifact publishing

`rc-proxy` is a local forward proxy. It diverts inference requests to a model gateway and leaves
everything else going to Anthropic on your real OAuth session.

That distinction is the whole tool. `ANTHROPIC_BASE_URL` is a single switch for all traffic, so
pointing it at a gateway sends your control plane there too, and every feature that talks to
Anthropic's own endpoints stops working. Remote Control is switched off by an explicit gate.
Artifact publishing stops. So does anything else that is not inference. Set `ANTHROPIC_AUTH_TOKEN`
instead and the session is classified as API-key auth, which fails the same gate.

This proxy intercepts at the network layer instead. Claude Code still believes it is talking to
`api.anthropic.com`, because it is, for everything except the one path that carries inference.

macOS only. It is a Go program in one file with one goroutine per connection.

---

## What goes where

| Request | Destination |
|---|---|
| `CONNECT` to any host other than `api.anthropic.com` | Raw TCP tunnel, copied byte for byte. TLS is never decrypted |
| `POST /v1/messages*` on `api.anthropic.com` | Your gateway at `127.0.0.1:8317`, with the `Authorization` header swapped for your pool token |
| Response to `GET /api/claude_cli/bootstrap` | Passed through from Anthropic, with your pool's model ids added to the model picker |
| Everything else on `api.anthropic.com` | Real Anthropic, unmodified. RC bridge and heartbeat, oauth, registration, telemetry |

The routing check is one line, in `handleConnect`:

```go
if host != anthropicHost { p.tunnel(clientConn, r.Host); return }   // raw tunnel, no TLS
```

Only traffic to `api.anthropic.com` is decrypted at all, and inside that, only paths beginning
`/v1/messages` are diverted.

The gateway address is a constant (`upstreamPool = "127.0.0.1:8317"`, the CLIProxyAPI default). If
yours listens elsewhere, edit that line and rebuild.

---

## What you need before installing

`install.sh` refuses until all three are in place.

```sh
brew install go mitmproxy

# Generates ~/.mitmproxy/. Wait a few seconds, then Ctrl-C. mitmproxy is not used again.
mitmdump --listen-port 39801 -q

mkdir -p ~/.config/ccw
printf '%s' 'YOUR_POOL_TOKEN' > ~/.config/ccw/rc-proxy.token
chmod 600 ~/.config/ccw/rc-proxy.token
```

The CA is reused from mitmproxy rather than minted here, so an existing mitmproxy-based setup
migrates with no client-side change. The proxy reads `~/.mitmproxy/mitmproxy-ca.pem`, which holds
the key and the certificate together, and mints a leaf certificate per host on demand.

Your token stays in that file. The launchd agent reads it at start, so it never goes into the
plist, which is world readable.

---

## Install

```sh
./cc-kit install rc-proxy
```

That builds the binary into `tools/rc-proxy/`, writes the plist, loads the agent, and then prints a
JSON block for you to paste. **It does not edit `~/.claude/settings.json`.** Editing the file every
Claude Code session reads, on behalf of someone who has not seen the diff, is the wrong default for
the one tool here that can take the whole machine offline.

Paste this into the `env` object of `~/.claude/settings.json`, with your own home directory
expanded. The printed block has that done for you.

```json
{
  "env": {
    "https_proxy": "http://127.0.0.1:9801",
    "http_proxy": "http://127.0.0.1:9801",
    "no_proxy": "localhost,127.0.0.1,::1,datadoghq.com,statsig.com,sentry.io",
    "NODE_EXTRA_CA_CERTS": "/Users/you/.mitmproxy/mitmproxy-ca-cert.pem"
  }
}
```

No `ANTHROPIC_BASE_URL`. No `ANTHROPIC_AUTH_TOKEN`. Adding either one defeats the point of this
tool.

Four notes on that block.

**`NODE_EXTRA_CA_CERTS` points at `mitmproxy-ca-cert.pem`, not `mitmproxy-ca.pem`.** The first is
the certificate alone and is what a client should trust. The second also contains the private key
and is what the proxy needs.

**Use an absolute path.** A leading `~` is not expanded by the runtime that reads this variable.

**`no_proxy` keeps telemetry and error reporting off the proxy.** Those hosts would otherwise open
a tunnel each. Add anything else you do not want passing through one process.

**`NODE_EXTRA_CA_CERTS` in `settings.json` alone is not enough for the bridge's own TLS.** The
compiled Bun binary initializes its trust store at startup, before it applies the `env` block from
settings. If Remote Control fails to connect while ordinary inference works, that is the reason.
Export it from the environment VS Code itself inherits:

```sh
launchctl setenv NODE_EXTRA_CA_CERTS "$HOME/.mitmproxy/mitmproxy-ca-cert.pem"
```

and restart VS Code. Keep the settings.json entry as well.

### Every process Claude Code spawns inherits these

`https_proxy` and friends are ordinary environment variables, so every Bash tool call, every
`curl`, `pip`, `npm` and `git` that Claude Code starts goes through the same local process. Checked
from inside a Claude Code Bash call on the machine this was written on, `env | grep -i proxy`
returns all four variables.

That is one Go process carrying your inference stream and your downloads at the same time. If a
large download matters, point it somewhere else explicitly rather than relying on the ambient
setting:

```sh
curl -x http://127.0.0.1:7897 -O https://example.com/big.tar.zst   # your own general proxy
```

I have not measured throughput through `rc-proxy` against a direct connection, so treat that as
caution rather than a measurement.

---

## Check that it works

Three probes, and you want all three.

```sh
# 1. Is the proxy alive at all? Plaintext, local only.
curl -s --noproxy '*' http://127.0.0.1:9801/healthz
# ok

# 2. Does a control-plane request survive TLS interception and reach Anthropic?
curl -s -o /dev/null -w 'code=%{http_code}\n' --max-time 15 \
     -x http://127.0.0.1:9801 --cacert ~/.mitmproxy/mitmproxy-ca-cert.pem \
     https://api.anthropic.com/
# code=404

# 3. The same request without the proxy.
curl -s --noproxy '*' -o /dev/null -w 'code=%{http_code}\n' --max-time 15 \
     https://api.anthropic.com/
# code=404
```

404 is the pass. Probe 2 is not testing the endpoint, it is testing that TLS interception worked
and the request reached Anthropic unchanged. What matters is that probes 2 and 3 agree.

`--noproxy '*'` on probes 1 and 3 is required, not decoration. Your shell almost certainly has
`https_proxy` set once this is installed, and without it the "bypass" probe would quietly go
through the proxy as well.

Reading the three results together is the point:

| 1 healthz | 2 through | 3 bypass | Diagnosis |
|---|---|---|---|
| ok | pass | pass | Working |
| ok | fail | pass | The proxy is wedged, or the CA is wrong |
| ok | fail | fail | Anthropic or your network is down. Restarting the proxy fixes nothing |
| no answer | fail | pass | The agent is dead. Restart it |

`./cc-kit status rc-proxy` runs all three and prints the diagnosis. `watchdog.sh` uses the same
three so it never restarts the proxy during an outage it cannot fix.

---

## Troubleshooting

**Every session fails to connect at once.** The proxy is down and `https_proxy` still points at it.
Either start it, or remove the `env` block from `~/.claude/settings.json`. There is no partial
failure mode here.

**`certificate signed by unknown authority`, or curl exit 60.** The client does not trust the
mitmproxy CA. Check that `NODE_EXTRA_CA_CERTS` is an absolute path to `mitmproxy-ca-cert.pem` and
that the file exists.

**Remote Control never connects, but chat works.** `NODE_EXTRA_CA_CERTS` is not in the process
environment at startup. See the `launchctl setenv` line above.

**"There's an issue with the selected model (X). It may not exist or you may not have access to
it."** Claude Code renders every model-level failure as that one sentence, whether the cause is a
quota that ran out, an unsupported feature, or an upstream 5xx. The real reason is in the log, and
that log is the only place it appears:

```sh
grep POOL-ERR ~/.local/state/ccw/rc-proxy/route.log | tail
```

**A pool model is missing from the picker.** The list is injected once, into the `bootstrap`
response, at session start. A session that started while the gateway was restarting would
permanently have no pool models, so the proxy persists the list to
`~/.local/state/ccw/rc-proxy/pool-models.json` and falls back to it. It also injects the union of
"live now" and "seen in the last 7 days", because gateways drop rate-limited models out of
`/v1/models` and the picker would otherwise lose a model exactly while it was cooling down.
If injection genuinely failed you get a `WARN` line in `route.log`.

**A pool model is in the picker and Claude Code silently uses Opus instead.** Injected ids are bare
names. If your `settings.json` names a model with a context-variant suffix such as `[1m]`, Claude
Code treats it as invalid and falls back without saying so. Write the bare name.

**More detail.** Per-request logging is off by default, because one VS Code startup makes thousands
of requests and writing a line per request becomes the bottleneck. Turn it on for a session by
setting `CLAUDE_RC_PROXY_VERBOSE=1` in the plist and reloading the agent.

### Environment variables the binary reads

| variable | default | effect |
|---|---|---|
| `CLAUDE_RC_PROXY_TOKEN` | unset | Bearer token sent to the gateway. Unset is a refusal, see below |
| `CLAUDE_RC_PROXY_LISTEN` | `127.0.0.1:9801` | Listen address |
| `CLAUDE_RC_PROXY_CA` | `$HOME/.mitmproxy/mitmproxy-ca.pem` | CA key and certificate |
| `CLAUDE_RC_PROXY_VERBOSE` | unset | `1` logs a line per request |
| `CLAUDE_RC_PROXY_DUMP_BOOTSTRAP` | unset | `1` saves each bootstrap response before injection, for debugging |

With no token set, inference requests are routed to `127.0.0.1:1`, which cannot connect. That is
deliberate. A misconfigured proxy that quietly forwarded inference to Anthropic would spend your
subscription quota while you believed you were on the gateway, and you would find out from the
bill.

---

## Logs and state

```
~/.local/state/ccw/rc-proxy/route.log            startup, injections, errors, POOL-ERR bodies
~/.local/state/ccw/rc-proxy/pool-models.json     model ids seen in the last 7 days
```

`route.log` grows slowly even with per-request logging off. On the machine this was written on it
reached 4.0 MB. Deleting it is safe at any time.

---

## Uninstall, in this order

```sh
./cc-kit uninstall rc-proxy
```

**Remove the `env` block from `~/.claude/settings.json` before or at the same time as booting out
the agent.** If `https_proxy` still points at `127.0.0.1:9801` and nothing is listening, every
Claude Code session on the machine fails to connect. `uninstall.sh` prints this and pauses.

By hand:

```sh
launchctl bootout gui/$(id -u)/io.github.dthinkr.ccw.rc-proxy
rm -f ~/Library/LaunchAgents/io.github.dthinkr.ccw.rc-proxy.plist
rm -rf ~/.local/state/ccw/rc-proxy ~/.config/ccw/rc-proxy.token
# then edit ~/.claude/settings.json and delete the four env keys
```

---

## What breaks

**Certificate pinning ends this tool.** The whole design rests on Claude Code trusting a CA you
control for `api.anthropic.com`. The day that stops being true, nothing here can be repaired.

**It is a single point of failure for the entire machine.** Every Claude Code session, and every
child process any of them spawns, has `https_proxy` pointed at one local process. When it dies they
all go silent at the same moment. The launchd agent has `KeepAlive` set, so the usual outcome is a
few seconds of failure and not a dead afternoon.

**A restart kills the turn that was streaming.** `/v1/messages` is one long response. When the
process dies the TCP connection resets and that generation is over. What a restart does recover is
the listener: new connections are accepted immediately, the RC heartbeat reconnects on its own, and
retrying or sending the next message works. Old windows do not need to be closed. There is no way
to resume a generation that was cut off.

**Anthropic can change the bootstrap response shape.** The model picker injection reads
`additional_model_options` out of that JSON. If the field moves, injection stops and you get a
`WARN` in the log, with everything else still working.

---

## Caveats

- The RC control plane runs on your logged-in account identity while inference responses come from
  gateway accounts. This combination is untested in the wild. It has worked here.
- Streaming responses are never buffered (`FlushInterval: -1`). Remote Control's inbound direction
  is a long poll on `/bridge`, and buffering it would close the phone-to-computer channel. If you
  fork this and add any middleware that reads a whole response, that is the first thing that
  breaks.

---

## What is in this directory

| File | What it is |
|---|---|
| `main.go` | The proxy, in one file |
| `main_test.go` | Six tests, `go test ./...`. No network needed |
| `go.mod` | The module lives here and not at the repo root. `go build` at the root does nothing |
| `install.sh`, `uninstall.sh`, `status.sh` | Driven by `manifest.conf` |
| `watchdog.sh` | Restarts the agent when probe 1 fails and probe 3 passes |
| `notes/design.md` | Why HTTP/1.1 in both directions, why the token file, and the rest of the reasoning |

Build and test by hand:

```sh
cd tools/rc-proxy
go build -o claude-rc-proxy .
go vet ./... && go test ./...
```

The old build command from before this repo was merged, `go build -o claude-rc-proxy-go .` at the
repo root, no longer works. `main.go` and `go.mod` live here now.
