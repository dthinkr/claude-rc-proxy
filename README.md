# claude-rc-proxy

Run Claude Code with **Remote Control enabled** while routing inference to a local model pool (CLIProxyAPI or any OpenAI/Anthropic-compatible backend).

## Why

Claude Code ≥ 2.1.196 silently disables Remote Control (and `/schedule`, claude.ai MCP connectors) when `ANTHROPIC_BASE_URL` points anywhere other than `api.anthropic.com`. So you can't just point the base URL at a proxy.

This is a **forward proxy** instead: Claude Code keeps believing it talks to `api.anthropic.com` (gate passes, subscription OAuth works, Remote Control stays on), and at the network layer:

- `/v1/messages*` → rerouted to your pool (`127.0.0.1:8317`, token swapped)
- everything else (RC bridge/heartbeat, oauth, bootstrap) → passed through to real Anthropic untouched
- pool models are injected back into the model picker via the bootstrap response

Single Go binary, ~500 lines, one goroutine per connection.

## Setup

```sh
go build -o claude-rc-proxy-go .

CLAUDE_RC_PROXY_TOKEN=<your-pool-token> ./claude-rc-proxy-go   # listens on 127.0.0.1:9801
```

`~/.claude/settings.json` — no `ANTHROPIC_BASE_URL`, no `ANTHROPIC_AUTH_TOKEN`:

```json
{
  "env": {
    "https_proxy": "http://127.0.0.1:9801",
    "NODE_EXTRA_CA_CERTS": "~/.mitmproxy/mitmproxy-ca-cert.pem"
  }
}
```

⚠️ `NODE_EXTRA_CA_CERTS` must be in the process environment **before** Claude Code starts — setting it in `settings.json` env alone is not enough for the compiled Bun binary's bridge TLS (it initializes trust stores at startup). Use shell export or `launchctl setenv`.

The TLS CA is reused from mitmproxy (`~/.mitmproxy/mitmproxy-ca.pem`), so any existing mitmproxy-based setup migrates without client changes.

## Design notes

- HTTP/1.1 only toward the client (no h2 ALPN) — fewer streaming edge cases; h2 upstream
- Non-Anthropic CONNECTs are blind-tunneled, never intercepted
- Request bodies are streamed; only the first 4 KB is inspected for `[1m]`-suffix normalization
- Streaming responses are flushed immediately (`FlushInterval: -1`) — RC inbound uses long-poll
- Pool model list persists to disk so sessions started during a pool restart still get the full picker

## Caveats

- Breaks if Anthropic adds certificate pinning
- The RC control plane uses your logged-in account identity while inference responses come from pool accounts — an untested-in-the-wild combination that has worked fine here

## License

MIT
