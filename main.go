// claude-rc-proxy — 让 Claude Code 同时拥有 Remote Control 和 CLIProxyAPI 轮换池。
//
// 为什么存在
// ──────────
// Claude Code v2.1.196 起加了门禁:ANTHROPIC_BASE_URL 一旦不指向 api.anthropic.com,
// Remote Control 立即关闭;ANTHROPIC_AUTH_TOKEN 又会让 session 被判成 API-key 认证,
// 同样出局。所以不能用"改 base URL"接代理,只能做正向代理:让 Claude Code 以为
// 自己在直连 api.anthropic.com(两道门禁都过),我们在网络层把推理流量拐去 CPA。
//
// 它只做两件事,别的一律原样放行:
//  1. /v1/messages*                 → 改道 CLIProxyAPI(127.0.0.1:8317),换 token
//  2. /api/claude_cli/bootstrap 的响应 → 把池里的型号塞回模型选择器
//
// 为什么用 Go 重写(替掉原来的 mitmproxy + Python addon)
// ─────────────────────────────────────────────────────
// mitmproxy 是**单线程 asyncio,没有 worker 模式**。多会话用户(几十个并发
// Claude Code 实例)的全部流量挤过那一个事件循环,任何一次阻塞就是全体停摆:
// 实测单请求级阻塞会放大到秒级 event-loop stall、成片的连接 reset,
// 以及客户端侧的初始化超时。
//
// Go 版每条连接一个 goroutine,跑满所有核心,一个慢请求卡不住别人。
// 而且这里只有两条改写规则,代码量是 mitmproxy 通用框架的零头 —— 能坏的地方少得多。
//
// 设计上的取舍(都是有意的)
// ──────────────────────────
//   - **对客户端只协商 HTTP/1.1**(ALPN 不宣告 h2)。Claude Code 会自动降级,
//     功能不受影响。换来少一整类 h2 + 流式的坑(之前被坑过)。对上游仍然走 h2。
//   - **非 api.anthropic.com 的 CONNECT 一律裸隧道对拷**,不解 TLS。
//     这些流量我们既不看也不改,解了纯属浪费 —— 旧版一次会话白扛 1139 条这种连接。
//   - **绝不整体读取请求体**。推理请求体是整个对话历史(实测有 4MB 的),
//     只读头部 4KB 做模型名归一化,剩下的直接流式转发。
//   - **流式响应零缓冲**(FlushInterval = -1)。RC 的入方向是 /bridge 长轮询,
//     一缓冲就把手机→电脑的通道憋死。
//
// 复用 mitmproxy 的 CA(~/.mitmproxy/mitmproxy-ca.pem),所以客户端侧的
// NODE_EXTRA_CA_CERTS 一个字都不用改,换过来是纯抽换。
package main

import (
	"bytes"
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
	anthropicHost = "api.anthropic.com"
	upstreamPool  = "127.0.0.1:8317" // CLIProxyAPI
)

var (
	listenAddr = envOr("CLAUDE_RC_PROXY_LISTEN", "127.0.0.1:9801")
	poolToken  = os.Getenv("CLAUDE_RC_PROXY_TOKEN")
	verbose    = os.Getenv("CLAUDE_RC_PROXY_VERBOSE") == "1"
	caPath     = envOr("CLAUDE_RC_PROXY_CA", os.ExpandEnv("$HOME/.mitmproxy/mitmproxy-ca.pem"))
)

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// ───────────────────────────── 日志 ─────────────────────────────
// 逐请求日志默认关闭:一次 VSCode 启动上万个请求,写日志本身就会变成瓶颈
// (旧版 Python 每行都 makedirs+open+close,是实测的成本之一)。

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

// ──────────────────────── 证书:用 mitmproxy 的 CA 现签 ────────────────────────

type certMinter struct {
	ca    tls.Certificate
	leaf  *x509.Certificate
	mu    sync.Mutex
	cache map[string]*tls.Certificate
}

func newCertMinter(path string) (*certMinter, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("读不到 CA %s: %w", path, err)
	}
	// mitmproxy-ca.pem 里是「私钥 + 证书」拼在一起,得自己拆。
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
			return nil, fmt.Errorf("解析 CA 私钥失败: %w", err)
		}
	}
	if certDER == nil || key == nil {
		return nil, errors.New("CA 文件里没同时找到证书和私钥")
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
	// CA 可能是 RSA 也可能是 EC,签名算法由 x509 按 CA 私钥类型自己选。
	der, err := x509.CreateCertificate(rand.Reader, tmpl, m.leaf, &priv.PublicKey, m.ca.PrivateKey)
	if err != nil {
		return nil, err
	}
	c := &tls.Certificate{Certificate: [][]byte{der, m.leaf.Raw}, PrivateKey: priv}
	m.cache[host] = c
	return c, nil
}

// ──────────────────────── 池内模型列表(带 TTL 缓存) ────────────────────────

// 模型列表要**落盘**,不能只放内存。
//
// 注入是 session 启动时的一锤子买卖:bootstrap 响应只来一次,那一刻拿不到列表,
// 这个 session 就永久没有池内模型,之后选 gpt-5.6-sol 必然报
// "There's an issue with the selected model … It may not exist"。
// 而 CPA 重启只要几秒,期间起的 session 全中招 —— 实际发生过,而且很难联想到病因。
//
// 落盘之后:冷启动时先读上次的列表垫底,CPA 正在重启也照样能注入。
// 列表变化极慢(型号增减是按周计的),用过期几分钟的数据远好过一个都没有。
const poolStatePath = "$HOME/.local/state/claude-rc-proxy/pool-models.json"

type poolCache struct {
	mu     sync.Mutex
	models []string
	at     time.Time
}

const poolTTL = 5 * time.Minute

var pool poolCache

// seen 记录每个型号最后一次出现在 CPA 列表里的时间。
// 只保留 seenTTL 之内的 —— 真的下架的型号最终会自己消失。
var seen = map[string]int64{}

const seenTTL = 7 * 24 * time.Hour

// loadDisk 把上次落盘的「见过的型号」读进来。调用方须持锁。
func (p *poolCache) loadDisk() {
	if len(seen) > 0 {
		return
	}
	raw, err := os.ReadFile(os.ExpandEnv(poolStatePath))
	if err != nil {
		return
	}
	if json.Unmarshal(raw, &seen) != nil || len(seen) == 0 {
		// 兼容早期的 []string 格式
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
	log.Printf("START  从磁盘恢复见过的型号 %d 个", len(seen))
}

// merge 把这次拉到的列表并进 seen,返回**并集**(live 在前,保持 CPA 的顺序)。
//
// ★ 为什么要并集而不是直接用 live:
//
//	CPA 会把**限流中**的模型从 /v1/models 里摘掉(实测 13 → 10,少掉的正是
//	额度耗尽的 glm-5.3 / kimi-k3 / deepseek-v4-pro)。而注入是切模型时才发生的,
//	所以那一刻正在冷却的型号就从选择器里消失,你选它就报
//	"There's an issue with the selected model … It may not exist" ——
//	过一阵冷却结束又自己好了,表现就是"用着用着就不行了",极难联想到病因。
//	保留并集之后:冷却中的型号仍可选,选中会给一句明确的额度错误(可行动),
//	而不是"模型不存在"(莫名其妙)。
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
			delete(seen, id) // 真下架了,过 7 天自己消失
			continue
		}
		if !inLive[id] {
			extra = append(extra, id)
		}
	}
	sort.Strings(extra) // 顺序稳定,别让选择器每次刷新都乱跳
	return append(out, extra...)
}

// saveDisk 落盘。失败不影响主流程 —— 它只是个优化。
func (p *poolCache) saveDisk() {
	raw, err := json.Marshal(seen)
	if err != nil {
		return
	}
	path := os.ExpandEnv(poolStatePath)
	if os.MkdirAll(filepath.Dir(path), 0o755) != nil {
		return
	}
	// 先写临时文件再 rename,避免读到写了一半的内容
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
		// 取不到就用「见过的型号」顶着 —— 列表变化很慢,
		// 用过期几分钟的数据远好过让选择器空掉。
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

// ──────────────────────── 模型名归一化 ────────────────────────
//
// Claude Code 从 Anthropic 拿到的型号带上下文变体后缀(claude-fable-5[1m]),
// 而 CPA 池里注册的是裸名。不去掉后缀池子会报模型不存在。
//
// ★ 绝不整体读请求体。推理请求体是整个对话历史,实测有 4MB 的;
//   Python 旧版对每条请求做全量 parse+dump,一次 43 毫秒,全是阻塞。
//   这里只读头部 4KB(model 字段在 JSON 开头),改完把头部和剩余流拼起来继续流式转发。

var modelSuffixRE = regexp.MustCompile(`("model"\s*:\s*"[^"\[]+)\[[^"\]]*\]"`)

const headWindow = 4096

// stripModelSuffix 返回新的 body reader 和长度增量(负数表示变短了)。
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

// ──────────────────────── 反向代理:两条路由 ────────────────────────

func newReverseProxy(minter *certMinter) *httputil.ReverseProxy {
	poolURL := &url.URL{Scheme: "http", Host: upstreamPool}
	realURL := &url.URL{Scheme: "https", Host: anthropicHost}

	return &httputil.ReverseProxy{
		// FlushInterval = -1:每次写入立刻 flush,不缓冲。
		// RC 的入方向是 /bridge 长轮询,SSE 推理回复也一样 —— 一缓冲就憋死。
		FlushInterval: -1,
		Transport: &http.Transport{
			Proxy:                 nil, // 我们**就是**代理,绝不能再套一层,否则自环
			MaxIdleConns:          512,
			MaxIdleConnsPerHost:   128,
			IdleConnTimeout:       90 * time.Second,
			TLSHandshakeTimeout:   15 * time.Second,
			ExpectContinueTimeout: time.Second,
			ForceAttemptHTTP2:     true, // 对上游用 h2,省连接
		},
		Director: func(r *http.Request) {
			path := r.URL.Path
			if strings.HasPrefix(path, "/v1/messages") {
				if poolToken == "" {
					// 没 token 宁可失败,也不能拿订阅额度去跑推理
					r.URL.Scheme, r.URL.Host = "http", "127.0.0.1:1" // 必然连不上
					return
				}
				r.URL.Scheme, r.URL.Host = poolURL.Scheme, poolURL.Host
				r.Host = poolURL.Host
				r.Header.Set("Authorization", "Bearer "+poolToken)
				r.Header.Del("X-Api-Key") // CPA 会自己补身份头,别冲突

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
			// 控制面(RC bridge/注册/心跳、oauth、bootstrap…)原样直送真 Anthropic,
			// 必须保持订阅身份,不能改道。
			r.URL.Scheme, r.URL.Host = realURL.Scheme, realURL.Host
			r.Host = anthropicHost

			// bootstrap 的响应我们要改(往里塞池内模型),所以必须拿到明文。
			// 客户端自己带的 Accept-Encoding: gzip 会让 Transport 原样透传压缩字节,
			// 解不动就只能静默放行 —— 那正是第一版注入失效的原因。
			// 删掉之后 Transport 会自己加 gzip 并**透明解压**,我们拿到的就是明文。
			// 只对这一条路径做,别的响应照旧压缩传输。
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

// injectPoolModels 把轮换池里的型号补进模型选择器。
//
// forward-proxy 模式下 Claude Code 以为自己直连 Anthropic,模型列表来自
// /api/claude_cli/bootstrap 的 additional_model_options —— 那里只有 Anthropic
// 给这个订阅的型号,glm-5.3 / kimi-k3 / grok-4.6 全没了。补进去选择器就恢复原样。
//
// 注入的是**裸名**(不带 [1m]),所以 settings.json 里的 model 也必须写裸名,
// 否则 CC 判定该型号无效、静默回落到 opus。踩过。
func injectPoolModels(resp *http.Response) error {
	// 推理失败时把错误原文记下来。Claude Code 把**所有**模型级失败都渲染成
	// "There's an issue with the selected model (X). It may not exist or you may
	// not have access to it." —— 额度耗尽、模型不支持某个特性、上游 5xx,
	// 用户看到的都是同一句话,完全没法定位。这里是唯一能看到真实原因的地方。
	// 只在 >=400 时读 body(错误响应都很小),正常流式响应一个字节都不碰。
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
		// 走到这里意味着这个 session 会**永久**没有池内模型 —— bootstrap 只来一次。
		// 用户侧的表现是选 gpt-5.6-sol 报 "It may not exist",且完全联想不到病因。
		// 落盘缓存就是为了让这条几乎不可能发生;真发生了必须看得见。
		log.Printf("WARN   拿不到池内模型列表,本次 bootstrap 未注入 —— " +
			"该 session 的模型选择器里不会有池内型号")
		return nil
	}
	// bootstrap 响应很小,整体读没问题(不像推理请求体动辄几 MB)。
	raw, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return err
	}

	// 排查用:CLAUDE_RC_PROXY_DUMP_BOOTSTRAP=1 时把注入前的响应原样存下来。
	// 切模型会重新拉 bootstrap 且把型号带在 query 里
	// (?entrypoint=claude-vscode&model=gpt-5.6-sol),所以"切了模型就报
	// It may not exist"的现场就在这些响应里。
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
		// 解不动就原样放行。会走到这里通常意味着响应还是压缩的 ——
		// Director 里对 bootstrap 删 Accept-Encoding 就是为了避免这种情况,
		// 所以这里额外记一笔,免得又静默失效一次(第一版就是这么栽的)。
		log.Printf("WARN   bootstrap 响应解不动(%d 字节, content-encoding=%q),未注入模型",
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
			"description": "via CLIProxyAPI 轮换池", "disabled_reason": nil,
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
	resp.Header.Del("Content-Encoding") // 我们写的是明文 JSON
	log.Printf("INJECT bootstrap +%d 个池内模型 (共 %d)", added, len(opts))
	return nil
}

// ──────────────────────── 代理入口 ────────────────────────

type proxy struct {
	minter *certMinter
	rp     *httputil.ReverseProxy
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect {
		p.handleConnect(w, r)
		return
	}
	// 明文 HTTP 走代理(少见)。同样按路径分流。
	p.rp.ServeHTTP(w, r)
}

func (p *proxy) handleConnect(w http.ResponseWriter, r *http.Request) {
	host, _, err := net.SplitHostPort(r.Host)
	if err != nil {
		host = r.Host
	}

	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijack 不支持", http.StatusInternalServerError)
		return
	}
	clientConn, _, err := hj.Hijack()
	if err != nil {
		return
	}
	defer clientConn.Close()

	if host != anthropicHost {
		// 我们既不看也不改这些流量,解 TLS 纯属浪费 —— 裸隧道对拷。
		p.tunnel(clientConn, r.Host)
		return
	}

	if _, err := clientConn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")); err != nil {
		return
	}

	cert, err := p.minter.get(host)
	if err != nil {
		log.Printf("ERR    签证书失败 %s: %v", host, err)
		return
	}
	tlsConn := tls.Server(clientConn, &tls.Config{
		Certificates: []tls.Certificate{*cert},
		// 只宣告 http/1.1:客户端会自动降级,功能不受影响,
		// 换来少一整类 h2 + 流式的坑。对上游仍然走 h2。
		NextProtos: []string{"http/1.1"},
		MinVersion: tls.VersionTLS12,
	})
	if err := tlsConn.Handshake(); err != nil {
		vlog("TLS    握手失败 %s: %v", host, err)
		return
	}

	// 用 http.Server 跑这条连接,才能正确处理 keep-alive / chunked / 多请求复用。
	srv := &http.Server{
		Handler:           p.rp,
		ReadHeaderTimeout: 30 * time.Second,
		// 不设 WriteTimeout:RC 的 /bridge 长轮询会挂很久,设了会被腰斩。
	}
	_ = srv.Serve(&oneShotListener{conn: tlsConn, addr: clientConn.RemoteAddr()})
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
	<-done // 任一方向结束就收工,defer 会关掉另一头
}

// oneShotListener 把单条已建立的连接包装成 net.Listener,
// 好让 http.Server 接管它(从而白拿 keep-alive、chunked、并发请求解析)。
type oneShotListener struct {
	conn net.Conn
	addr net.Addr
	once sync.Once
	done chan struct{}
}

func (l *oneShotListener) Accept() (net.Conn, error) {
	var c net.Conn
	l.once.Do(func() {
		l.done = make(chan struct{})
		c = l.conn
	})
	if c != nil {
		return c, nil
	}
	<-l.done
	return nil, io.EOF
}

func (l *oneShotListener) Close() error {
	l.once.Do(func() { l.done = make(chan struct{}) })
	select {
	case <-l.done:
	default:
		close(l.done)
	}
	return nil
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
		log.Println("WARN   CLAUDE_RC_PROXY_TOKEN 未设置 —— 推理流量会失败,不会静默走订阅额度")
	}
	minter, err := newCertMinter(caPath)
	if err != nil {
		log.Fatalf("FATAL  %v", err)
	}
	// 预热池内模型列表,避免第一个 bootstrap 请求现拉。
	if poolToken != "" {
		log.Printf("START  监听 %s   池内模型 %d 个   verbose=%v",
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

// 让编译器别抱怨没用到的 rsa(CA 可能是 RSA,x509 内部按需使用)
var _ = rsa.PublicKey{}
