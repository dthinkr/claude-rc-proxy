// claude-rc-proxy lets Claude Code use a model gateway without giving up any
// first-party feature.
//
// Why it exists
// ─────────────
// Claude Code v2.1.196 added a gate. Point ANTHROPIC_BASE_URL anywhere other than
// api.anthropic.com and Remote Control switches off. Set ANTHROPIC_AUTH_TOKEN and the
// session is treated as API-key auth, which is out too. So you cannot attach a gateway
// by changing the base URL. A forward proxy is the way in: Claude Code believes it is
// talking straight to api.anthropic.com, which clears both gates, and the inference
// traffic is diverted at the network layer.
//
// It changes two things and passes everything else through untouched:
//  1. /v1/messages*                     → routed to the gateway, with the token swapped
//  2. the /api/claude_cli/bootstrap body → gateway models added to the model picker
//
// That second point about passing everything else through is the whole design, not a
// detail. Remote Control keeps working, and so does anything else that talks to
// Anthropic's own endpoints, publishing Artifacts included. Swapping the base URL
// sends all of it to the gateway and breaks all of it at once.
//
// Why Go, replacing the original mitmproxy plus Python addon
// ─────────────────────────────────────────────────────────
// mitmproxy is single-threaded asyncio with no worker mode. All traffic from a user
// running dozens of concurrent Claude Code instances funnels through one event loop,
// and any single block stalls every session at once. Measured: a per-request block
// grew into seconds of event-loop stall, connection resets in batches, and client-side
// initialization timeouts.
//
// The Go version gives each connection its own goroutine, uses every core, and one slow
// request cannot hold up the rest. There are also only two rewrite rules here, so the
// code is a fraction of a general-purpose interception framework and has far less that
// can break.
//
// Deliberate trade-offs
// ─────────────────────
//   - A restart cannot resume a turn that is mid-stream. /v1/messages is one stream, and
//     when the process dies the TCP connection is reset, so that turn is over. What it
//     does instead is accept new CONNECTs on the listener immediately, so you do not
//     have to close the window: the Remote Control heartbeat reconnects on its own and
//     the next message or a retry goes through. Splicing a cut-off generation back
//     together is not possible.
//   - HTTP/1.1 to the client and to the upstream. The client-facing ALPN does not offer
//     h2 and Claude Code downgrades on its own. The upstream once used
//     ForceAttemptHTTP2 to save connections, which multiplexed the long polls,
//     heartbeats and logging of dozens of sessions onto a handful of H2 connections to
//     Anthropic. One INTERNAL_ERROR from the far end then timed out all of them
//     together. Measured 2026-08-25: 383 H2 INTERNAL_ERRORs in one process lifetime,
//     with the frozen stretches accompanied by a storm of TLS handshake timeouts. Under
//     H1 a dead connection takes only itself down. New handshakes are capped at 4 at a
//     time so that a restart does not set off a handshake storm as every session
//     reconnects at once; once a handshake completes, long polls carry on over their own
//     H1 connections.
//   - Every CONNECT to a host other than api.anthropic.com is copied through as a raw
//     tunnel with no TLS interception. That traffic is neither read nor modified, so
//     decrypting it would be pure waste. The old version decrypted 1139 such connections
//     in a single session for nothing.
//   - The request body is never read whole. An inference body is the entire conversation
//     history and a 4 MB one has been seen in practice. Only the leading 4 KB is read,
//     to normalize the model name, and the rest is streamed straight through.
//   - Streaming responses are not buffered at all (FlushInterval = -1). The inbound
//     direction of Remote Control is a /bridge long poll, and buffering it chokes the
//     phone-to-computer channel.
//
// It reuses the mitmproxy CA at ~/.mitmproxy/mitmproxy-ca.pem, so NODE_EXTRA_CA_CERTS on
// the client side needs no change and switching over is a straight swap.
package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	anthropicHost             = "api.anthropic.com"
	upstreamPool              = "127.0.0.1:8317" // CLIProxyAPI
	anthropicTLSMaxConcurrent = 4
)

var (
	listenAddr     = envOr("CLAUDE_RC_PROXY_LISTEN", "127.0.0.1:9801")
	poolToken      = os.Getenv("CLAUDE_RC_PROXY_TOKEN")
	verbose        = os.Getenv("CLAUDE_RC_PROXY_VERBOSE") == "1"
	caPath         = envOr("CLAUDE_RC_PROXY_CA", os.ExpandEnv("$HOME/.mitmproxy/mitmproxy-ca.pem"))
	upstreamDialer = &net.Dialer{
		Timeout:   5 * time.Second,
		KeepAlive: 30 * time.Second,
	}
	anthropicTLSGate = make(chan struct{}, anthropicTLSMaxConcurrent)
)

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// ───────────────────────────── Logging ─────────────────────────────
// Per-request logging is off by default. One VS Code launch makes tens of thousands of
// requests, and the old Python version's makedirs+open+close per line was a measured cost.

var logFile *os.File

func initLog() {
	p := os.ExpandEnv("$HOME/.local/state/claude-rc-proxy/route.log")
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return
	}
	f, err := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	logFile = f
	log.SetOutput(io.MultiWriter(os.Stderr, f))
	log.SetFlags(log.Ltime)
}

func vlog(format string, a ...any) {
	if verbose {
		log.Printf(format, a...)
	}
}

// ──────────────────── Certificates: minted on the fly from the mitmproxy CA ────────────────────

type certMinter struct {
	ca    tls.Certificate
	leaf  *x509.Certificate
	mu    sync.Mutex
	cache map[string]*tls.Certificate
}

func newCertMinter(path string) (*certMinter, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read CA %s: %w", path, err)
	}
	// mitmproxy-ca.pem holds the private key and the certificate concatenated, so split them.
	var certDER []byte
	var key any
	for block, rest := pem.Decode(raw); block != nil; block, rest = pem.Decode(rest) {
		switch block.Type {
		case "CERTIFICATE":
			if certDER == nil {
				certDER = block.Bytes
			}
		case "RSA PRIVATE KEY":
			key, err = x509.ParsePKCS1PrivateKey(block.Bytes)
		case "PRIVATE KEY":
			key, err = x509.ParsePKCS8PrivateKey(block.Bytes)
		case "EC PRIVATE KEY":
			key, err = x509.ParseECPrivateKey(block.Bytes)
		}
		if err != nil {
			return nil, fmt.Errorf("failed to parse CA private key: %w", err)
		}
	}
	if certDER == nil || key == nil {
		return nil, errors.New("CA file does not contain both a certificate and a private key")
	}
	leaf, err := x509.ParseCertificate(certDER)
	if err != nil {
		return nil, err
	}
	return &certMinter{
		ca:    tls.Certificate{Certificate: [][]byte{certDER}, PrivateKey: key},
		leaf:  leaf,
		cache: map[string]*tls.Certificate{},
	}, nil
}

func (m *certMinter) get(host string) (*tls.Certificate, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if c, ok := m.cache[host]; ok {
		return c, nil
	}
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: host},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().AddDate(1, 0, 0),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{host},
	}
	// The CA may be RSA or EC. x509 picks the signature algorithm from the CA key type.
	der, err := x509.CreateCertificate(rand.Reader, tmpl, m.leaf, &priv.PublicKey, m.ca.PrivateKey)
	if err != nil {
		return nil, err
	}
	c := &tls.Certificate{Certificate: [][]byte{der, m.leaf.Raw}, PrivateKey: priv}
	m.cache[host] = c
	return c, nil
}

// ──────────────────────── Gateway model list, with a TTL cache ────────────────────────

// The model list has to be persisted, not just held in memory.
//
// Injection is a one-shot at session start. The bootstrap response arrives exactly once,
// so a session that misses the list at that moment has no gateway models for its whole
// life, and selecting one reports "There's an issue with the selected model ... It may
// not exist". A gateway restart takes only seconds, but every session started during it
// is hit, and the cause is very hard to guess from the symptom.
//
// Persisting fixes it. A cold start reads the previous list as a floor, so injection
// still works while the gateway is restarting. The list changes slowly, models are added
// or removed on the order of weeks, so data a few minutes stale beats having none.
const poolStatePath = "$HOME/.local/state/claude-rc-proxy/pool-models.json"

type poolCache struct {
	mu     sync.Mutex
	models []string
	at     time.Time
}

const poolTTL = 5 * time.Minute

var pool poolCache

// seen records the last time each model id appeared in the gateway's list.
// Only entries within seenTTL are kept, so a model that is genuinely gone drops out.
var seen = map[string]int64{}

const seenTTL = 7 * 24 * time.Hour

// loadDisk reads the previously persisted "models seen" set. Caller must hold the lock.
func (p *poolCache) loadDisk() {
	if len(seen) > 0 {
		return
	}
	raw, err := os.ReadFile(os.ExpandEnv(poolStatePath))
	if err != nil {
		return
	}
	if json.Unmarshal(raw, &seen) != nil || len(seen) == 0 {
		// tolerate the earlier []string format
		var ids []string
		if json.Unmarshal(raw, &ids) != nil {
			seen = map[string]int64{}
			return
		}
		now := time.Now().Unix()
		for _, id := range ids {
			seen[id] = now
		}
	}
	log.Printf("START  restored %d seen models from disk", len(seen))
}

// merge folds the freshly fetched list into seen and returns the UNION, live first so the
// gateway's own ordering is preserved.
//
// Why a union rather than just the live list:
//
//	A gateway drops rate-limited models from its /v1/models response. Injection only
//	happens when you switch models, so a model that is cooling down at that moment
//	vanishes from the picker, and selecting it reports "There's an issue with the
//	selected model ... It may not exist". Once the cooldown ends it comes back on its
//	own, which reads as "it worked and then it stopped" and is very hard to diagnose.
//
//	Keeping the union means a cooling-down model stays selectable and returns a clear
//	quota error you can act on, instead of a "does not exist" that makes no sense.
func (p *poolCache) merge(live []string) []string {
	now := time.Now()
	for _, id := range live {
		seen[id] = now.Unix()
	}
	out := append([]string{}, live...)
	inLive := map[string]bool{}
	for _, id := range live {
		inLive[id] = true
	}
	extra := make([]string, 0, len(seen))
	cutoff := now.Add(-seenTTL).Unix()
	for id, ts := range seen {
		if ts < cutoff {
			delete(seen, id) // genuinely gone; it ages out after seenTTL
			continue
		}
		if !inLive[id] {
			extra = append(extra, id)
		}
	}
	sort.Strings(extra) // stable order, so the picker does not reshuffle on every refresh
	return append(out, extra...)
}

// saveDisk persists the set. Failure does not affect the main path; this is only an optimization.
func (p *poolCache) saveDisk() {
	raw, err := json.Marshal(seen)
	if err != nil {
		return
	}
	path := os.ExpandEnv(poolStatePath)
	if os.MkdirAll(filepath.Dir(path), 0o755) != nil {
		return
	}
	// write a temp file and rename, so a reader never sees a half-written file
	tmp := path + ".tmp"
	if os.WriteFile(tmp, raw, 0o644) == nil {
		_ = os.Rename(tmp, path)
	}
}

func (p *poolCache) models_() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.loadDisk()
	if len(p.models) > 0 && time.Since(p.at) < poolTTL {
		return p.models
	}
	req, err := http.NewRequest("GET", "http://"+upstreamPool+"/v1/models", nil)
	if err != nil {
		return p.models
	}
	req.Header.Set("Authorization", "Bearer "+poolToken)
	cli := &http.Client{Timeout: 2 * time.Second}
	resp, err := cli.Do(req)
	if err != nil {
		// fall back to the seen set. The list changes slowly, and data that is a few
		// minutes stale beats an empty picker.
		if len(p.models) == 0 {
			p.models = p.merge(nil)
		}
		return p.models
	}
	defer resp.Body.Close()
	var body struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if json.NewDecoder(resp.Body).Decode(&body) != nil {
		return p.models
	}
	ids := make([]string, 0, len(body.Data))
	for _, d := range body.Data {
		if d.ID != "" {
			ids = append(ids, d.ID)
		}
	}
	if len(ids) > 0 {
		p.models, p.at = p.merge(ids), time.Now()
		p.saveDisk()
	}
	return p.models
}

// ──────────────────────── Model name normalization ────────────────────────
//
// Anthropic hands Claude Code model ids carrying a context-variant suffix, written as
// name[1m]. Gateways register the bare name, so leaving the suffix on makes the gateway
// report that the model does not exist.
//
// Never read the whole request body. An inference body is the entire conversation history

var modelSuffixRE = regexp.MustCompile(`("model"\s*:\s*"[^"\[]+)\[[^"\]]*\]"`)

const headWindow = 4096

// stripModelSuffix returns a new body reader and the length delta, negative when it shrank.
func stripModelSuffix(body io.ReadCloser) (io.ReadCloser, int, error) {
	head := make([]byte, headWindow)
	n, err := io.ReadFull(body, head)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return body, 0, err
	}
	head = head[:n]

	newHead := modelSuffixRE.ReplaceAll(head, []byte(`$1"`))
	delta := len(newHead) - len(head)

	rest := io.MultiReader(bytes.NewReader(newHead), body)
	return struct {
		io.Reader
		io.Closer
	}{rest, body}, delta, nil
}

// ──────────────────── Safe replay of H2 control requests ────────────────────
//
// Go's H2 transport retries peer PROTOCOL_ERROR and REFUSED_STREAM on its own, but once a
// POST body has been written it needs GetBody to replay. Without it, one error on a shared
// H2 connection makes every heartbeat on that same connection fail with
//
// "cannot rewind body after connection loss".
//

const replayableBodyLimit int64 = 1 << 20 // 1 MiB; a normal heartbeat is far smaller

func isReplayableControlPost(r *http.Request) bool {
	if r.Method != http.MethodPost {
		return false
	}
	path := r.URL.Path
	if path == "/api/event_logging/v2/batch" {
		return true
	}
	return strings.HasPrefix(path, "/v1/code/sessions/") &&
		strings.HasSuffix(path, "/worker/heartbeat")
}

// makeReplayableControlBody sets Body and GetBody for small, safe POSTs. Anything uncertain
// keeps the original stream semantics. Returning true means the request is now replayable.
func makeReplayableControlBody(r *http.Request) bool {
	if !isReplayableControlPost(r) || r.Body == nil || r.Body == http.NoBody ||
		r.ContentLength <= 0 || r.ContentLength > replayableBodyLimit {
		return false
	}

	original := r.Body
	raw, err := io.ReadAll(io.LimitReader(original, replayableBodyLimit+1))
	if err != nil || int64(len(raw)) > replayableBodyLimit {
		// the prefix already consumed has to go back; a failure must not alter the byte stream
		r.Body = struct {
			io.Reader
			io.Closer
		}{io.MultiReader(bytes.NewReader(raw), original), original}
		return false
	}
	_ = original.Close()

	body := append([]byte(nil), raw...)
	r.Body = io.NopCloser(bytes.NewReader(body))
	r.GetBody = func() (io.ReadCloser, error) {
		return io.NopCloser(bytes.NewReader(body)), nil
	}
	r.ContentLength = int64(len(body))
	r.Header.Set("Content-Length", strconv.FormatInt(r.ContentLength, 10))
	return true
}

// ──────────────────────── Reverse proxy: two routes ────────────────────────

// dialAnthropicTLS throttles only the expensive TCP and TLS setup, never an established
// long poll. Dozens of Claude Code sessions reconnect at once when the process restarts,
// and with no backpressure that produces TLS handshake timeouts in batches, after which
func dialAnthropicTLS(ctx context.Context, network, addr string) (net.Conn, error) {
	select {
	case anthropicTLSGate <- struct{}{}:
		defer func() { <-anthropicTLSGate }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}

	raw, err := upstreamDialer.DialContext(ctx, network, addr)
	if err != nil {
		return nil, err
	}

	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		host = addr
	}
	conn := tls.Client(raw, &tls.Config{
		ServerName: host,
		MinVersion: tls.VersionTLS12,
		NextProtos: []string{"http/1.1"},
	})
	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		_ = raw.Close()
		return nil, err
	}
	if err := conn.HandshakeContext(ctx); err != nil {
		_ = raw.Close()
		return nil, err
	}
	_ = conn.SetDeadline(time.Time{})
	return conn, nil
}

func newReverseProxy(minter *certMinter) *httputil.ReverseProxy {
	poolURL := &url.URL{Scheme: "http", Host: upstreamPool}
	realURL := &url.URL{Scheme: "https", Host: anthropicHost}

	return &httputil.ReverseProxy{
		// FlushInterval = -1: flush on every write, no buffering.
		// The inbound side of Remote Control is a /bridge long poll and streamed replies are
		FlushInterval: -1,
		Transport: &http.Transport{
			Proxy:                 nil, // we ARE the proxy; layering another one here would self-loop
			DialContext:           upstreamDialer.DialContext,
			DialTLSContext:        dialAnthropicTLS,
			MaxIdleConns:          512,
			MaxIdleConnsPerHost:   128,
			IdleConnTimeout:       90 * time.Second,
			ExpectContinueTimeout: time.Second,
			// No H2 upstream. Saving connections costs a shared failure domain. See the file header.
			ForceAttemptHTTP2: false,
		},
		Director: func(r *http.Request) {
			path := r.URL.Path
			if strings.HasPrefix(path, "/v1/messages") {
				if poolToken == "" {
					// fail rather than quietly spend subscription quota on inference
					r.URL.Scheme, r.URL.Host = "http", "127.0.0.1:1" // guaranteed to fail to connect
					return
				}
				r.URL.Scheme, r.URL.Host = poolURL.Scheme, poolURL.Host
				r.Host = poolURL.Host
				r.Header.Set("Authorization", "Bearer "+poolToken)
				r.Header.Del("X-Api-Key") // the gateway supplies its own identity header; do not clash

				if r.Body != nil {
					nb, delta, err := stripModelSuffix(r.Body)
					if err == nil {
						r.Body = nb
						if delta != 0 && r.ContentLength > 0 {
							r.ContentLength += int64(delta)
							r.Header.Set("Content-Length", strconv.FormatInt(r.ContentLength, 10))
						}
					}
				}
				vlog("POOL   %s %s", r.Method, truncate(path, 60))
				return
			}
			// The control plane (Remote Control bridge, registration, heartbeat, oauth, bootstrap and
			// the rest) goes straight to the real Anthropic. It must keep the subscription identity.
			r.URL.Scheme, r.URL.Host = realURL.Scheme, realURL.Host
			r.Host = anthropicHost
			// Remote Control long polls are cancelled by the client all the time. Reusing those
			// upstream H1 connections slowly poisons the Transport: new control-plane requests get
			// no response while a direct connection to Anthropic still works. So close the
			r.Close = true
			if makeReplayableControlBody(r) {
				vlog("REPLAY %s %s", r.Method, truncate(path, 60))
			}

			// The bootstrap response gets modified, which means it has to arrive as plaintext.
			// An Accept-Encoding: gzip the client set itself makes the Transport pass the compressed
			// bytes through untouched, and anything we cannot decode has to be forwarded as-is. That
			// is exactly how the first version of this injection failed, silently. Delete the header
			// and the Transport adds gzip itself and decompresses transparently.
			if strings.HasPrefix(path, "/api/claude_cli/bootstrap") {
				r.Header.Del("Accept-Encoding")
			}
			vlog("DIRECT %s %s", r.Method, truncate(path, 60))
		},
		ModifyResponse: injectPoolModels,
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("ERR    %s %s: %v", r.Method, truncate(r.URL.Path, 60), err)
			w.WriteHeader(http.StatusBadGateway)
		},
	}
}

// injectPoolModels adds the gateway's models to the model picker.
//
// In forward-proxy mode Claude Code believes it is talking to Anthropic directly, so its
// model list comes from additional_model_options in /api/claude_cli/bootstrap. That list
// holds only the models Anthropic offers this subscription, so every gateway model is
// missing until they are added back here.
func injectPoolModels(resp *http.Response) error {
	// Record the upstream error text when inference fails. Claude Code renders EVERY
	// "There's an issue with the selected model (X). It may not exist or you may
	// model-level failure as the same sentence, "...does not exist or you do not have access
	// to it." Quota exhausted, an unsupported feature, an upstream 5xx: the user sees one
	// message with nothing to act on. This is the only place the real reason is visible.
	if strings.HasPrefix(resp.Request.URL.Path, "/v1/messages") && resp.StatusCode >= 400 {
		raw, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		if err == nil {
			log.Printf("POOL-ERR %d  %s", resp.StatusCode,
				strings.ReplaceAll(string(raw), "\n", " "))
			resp.Body = io.NopCloser(bytes.NewReader(raw))
			resp.ContentLength = int64(len(raw))
			resp.Header.Set("Content-Length", strconv.Itoa(len(raw)))
		} else {
			resp.Body = io.NopCloser(bytes.NewReader(nil))
		}
		return nil
	}

	if !strings.HasPrefix(resp.Request.URL.Path, "/api/claude_cli/bootstrap") ||
		resp.StatusCode != 200 || poolToken == "" {
		return nil
	}
	ids := pool.models_()
	if len(ids) == 0 {
		// Reaching here means this session will have NO gateway models for its entire life,
		// because bootstrap arrives only once. The user sees a model that reports it does not
		// exist, with no way to connect that to the cause. The on-disk cache exists to make this
		log.Printf("WARN   could not fetch the gateway model list; this bootstrap was not injected. " +
			"the model picker in this session will not show gateway models")
		return nil
	}
	// The bootstrap response is small, so reading it whole is fine, unlike an inference body.
	raw, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return err
	}

	// For debugging: CLAUDE_RC_PROXY_DUMP_BOOTSTRAP=1 saves the response before injection.
	// Switching models refetches bootstrap and carries the model id in the query string, so
	// the evidence for a "switched model and it says it does not exist" report is in these
	// responses.
	if os.Getenv("CLAUDE_RC_PROXY_DUMP_BOOTSTRAP") == "1" {
		dir := os.ExpandEnv("$HOME/.local/state/claude-rc-proxy/bootstrap-dumps")
		if os.MkdirAll(dir, 0o755) == nil {
			name := strings.ReplaceAll(resp.Request.URL.RawQuery, "/", "_")
			if len(name) > 80 {
				name = name[:80]
			}
			_ = os.WriteFile(filepath.Join(dir, name+".json"), raw, 0o644)
		}
	}
	var body map[string]any
	if json.Unmarshal(raw, &body) != nil {
		// Forward it unchanged if it cannot be decoded. Getting here usually means the response
		// is still compressed. Deleting Accept-Encoding for bootstrap in the Director exists to
		// prevent exactly that, so log it rather than fail silently again as the first version did.
		log.Printf("WARN   could not decode the bootstrap response (%d bytes, content-encoding=%q); no models injected",
			len(raw), resp.Header.Get("Content-Encoding"))
		resp.Body = io.NopCloser(bytes.NewReader(raw))
		return nil
	}
	opts, _ := body["additional_model_options"].([]any)
	have := map[string]bool{}
	for _, o := range opts {
		if m, ok := o.(map[string]any); ok {
			if s, ok := m["model"].(string); ok {
				have[s] = true
			}
		}
	}
	added := 0
	for _, id := range ids {
		if have[id] {
			continue
		}
		opts = append(opts, map[string]any{
			"model": id, "name": id,
			"description": "via gateway", "disabled_reason": nil,
		})
		added++
	}
	body["additional_model_options"] = opts
	out, err := json.Marshal(body)
	if err != nil {
		resp.Body = io.NopCloser(bytes.NewReader(raw))
		return nil
	}
	resp.Body = io.NopCloser(bytes.NewReader(out))
	resp.ContentLength = int64(len(out))
	resp.Header.Set("Content-Length", strconv.Itoa(len(out)))
	resp.Header.Del("Content-Encoding") // what we write is plaintext JSON
	log.Printf("INJECT bootstrap +%d gateway models (%d total)", added, len(opts))
	return nil
}

// ──────────────────────── Proxy entry point ────────────────────────

type proxy struct {
	minter *certMinter
	rp     *httputil.ReverseProxy
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Plaintext /healthz is for the local watchdog only. Claude Code uses CONNECT and never
	// reaches it. It has to be caught before routing, or it gets forwarded to Anthropic.
	if r.Method == http.MethodGet && r.URL.Path == "/healthz" {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "ok\n")
		return
	}
	if r.Method == http.MethodConnect {
		p.handleConnect(w, r)
		return
	}
	// Plaintext HTTP through the proxy, which is rare. Same split by path.
	p.rp.ServeHTTP(w, r)
}

func (p *proxy) handleConnect(w http.ResponseWriter, r *http.Request) {
	host, _, err := net.SplitHostPort(r.Host)
	if err != nil {
		host = r.Host
	}

	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijacking not supported", http.StatusInternalServerError)
		return
	}
	clientConn, _, err := hj.Hijack()
	if err != nil {
		return
	}
	defer clientConn.Close()

	if host != anthropicHost {
		// This traffic is neither read nor modified, so decrypting it is pure waste. Raw tunnel.
		p.tunnel(clientConn, r.Host)
		return
	}

	if _, err := clientConn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")); err != nil {
		return
	}

	cert, err := p.minter.get(host)
	if err != nil {
		log.Printf("ERR    failed to mint a certificate for %s: %v", host, err)
		return
	}
	tlsConn := tls.Server(clientConn, &tls.Config{
		Certificates: []tls.Certificate{*cert},
		// Offer http/1.1 only. The client downgrades on its own with no loss of function, and
		// it removes a whole class of h2-plus-streaming problems. The upstream is H1 too.
		NextProtos: []string{"http/1.1"},
		MinVersion: tls.VersionTLS12,
	})
	if err := tlsConn.Handshake(); err != nil {
		vlog("TLS    handshake failed %s: %v", host, err)
		return
	}

	// Run this connection through http.Server so keep-alive, chunked encoding and multiple
	srv := &http.Server{
		Handler:           p.rp,
		ReadHeaderTimeout: 30 * time.Second,
		// No WriteTimeout: a Remote Control /bridge long poll hangs for a long time on purpose,
	}
	_ = srv.Serve(newOneShotListener(tlsConn, clientConn.RemoteAddr()))
}

func (p *proxy) tunnel(client net.Conn, hostPort string) {
	server, err := net.DialTimeout("tcp", hostPort, 15*time.Second)
	if err != nil {
		_, _ = client.Write([]byte("HTTP/1.1 502 Bad Gateway\r\n\r\n"))
		return
	}
	defer server.Close()
	if _, err := client.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")); err != nil {
		return
	}
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(server, client); done <- struct{}{} }()
	go func() { _, _ = io.Copy(client, server); done <- struct{}{} }()
	<-done // either direction finishing ends it; the deferred close takes the other side down
}

// oneShotListener wraps a single established connection as a net.Listener so that
// http.Server can take it over, which gives keep-alive, chunked and concurrent parsing free.
type oneShotListener struct {
	conn       net.Conn
	addr       net.Addr
	acceptOnce sync.Once
	closeOnce  sync.Once
	done       chan struct{}
}

func newOneShotListener(conn net.Conn, addr net.Addr) *oneShotListener {
	return &oneShotListener{
		conn: conn,
		addr: addr,
		done: make(chan struct{}),
	}
}

type closeNotifyConn struct {
	net.Conn
	once    sync.Once
	onClose func()
}

func (c *closeNotifyConn) Close() error {
	err := c.Conn.Close()
	c.once.Do(c.onClose)
	return err
}

func (l *oneShotListener) Accept() (net.Conn, error) {
	var c net.Conn
	l.acceptOnce.Do(func() {
		select {
		case <-l.done:
			return
		default:
		}
		c = &closeNotifyConn{Conn: l.conn, onClose: l.signalDone}
	})
	if c != nil {
		return c, nil
	}
	<-l.done
	return nil, io.EOF
}

func (l *oneShotListener) Close() error {
	l.signalDone()
	return nil
}

func (l *oneShotListener) signalDone() {
	l.closeOnce.Do(func() { close(l.done) })
}

func (l *oneShotListener) Addr() net.Addr { return l.addr }

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

func main() {
	initLog()
	if poolToken == "" {
		log.Println("WARN   CLAUDE_RC_PROXY_TOKEN is not set. Inference will fail rather than quietly use subscription quota")
	}
	minter, err := newCertMinter(caPath)
	if err != nil {
		log.Fatalf("FATAL  %v", err)
	}
	// Warm the model list so the first bootstrap request does not have to fetch it.
	if poolToken != "" {
		log.Printf("START  listening on %s   gateway models %d   verbose=%v",
			listenAddr, len(pool.models_()), verbose)
	}
	p := &proxy{minter: minter, rp: newReverseProxy(minter)}
	srv := &http.Server{
		Addr:              listenAddr,
		Handler:           p,
		ReadHeaderTimeout: 30 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}

// Keep the compiler quiet about rsa; the CA may be RSA and x509 uses it as needed.
var _ = rsa.PublicKey{}
