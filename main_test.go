package main

import (
	"bytes"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

func testRequest(method, path, body string, contentLength int64) *http.Request {
	return &http.Request{
		Method:        method,
		URL:           &url.URL{Path: path},
		Header:        make(http.Header),
		Body:          io.NopCloser(strings.NewReader(body)),
		ContentLength: contentLength,
	}
}

func TestIsReplayableControlPost(t *testing.T) {
	tests := []struct {
		name   string
		method string
		path   string
		want   bool
	}{
		{"heartbeat", http.MethodPost, "/v1/code/sessions/cse_123/worker/heartbeat", true},
		{"event logging", http.MethodPost, "/api/event_logging/v2/batch", true},
		{"heartbeat GET", http.MethodGet, "/v1/code/sessions/cse_123/worker/heartbeat", false},
		{"worker events", http.MethodPost, "/v1/code/sessions/cse_123/worker/events", false},
		{"messages", http.MethodPost, "/v1/messages", false},
		{"registration", http.MethodPost, "/v1/code/sessions", false},
		{"similar suffix", http.MethodPost, "/other/worker/heartbeat", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := testRequest(tt.method, tt.path, `{}`, 2)
			if got := isReplayableControlPost(r); got != tt.want {
				t.Fatalf("isReplayableControlPost() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestMakeReplayableControlBody(t *testing.T) {
	for _, path := range []string{
		"/v1/code/sessions/cse_123/worker/heartbeat",
		"/api/event_logging/v2/batch",
	} {
		t.Run(path, func(t *testing.T) {
			want := []byte(`{"worker_epoch":7,"ok":true}`)
			r := testRequest(http.MethodPost, path, string(want), int64(len(want)))
			if !makeReplayableControlBody(r) {
				t.Fatal("request was not made replayable")
			}
			if r.GetBody == nil {
				t.Fatal("GetBody is nil")
			}
			if r.ContentLength != int64(len(want)) || r.Header.Get("Content-Length") != "28" {
				t.Fatalf("wrong content length: field=%d header=%q", r.ContentLength, r.Header.Get("Content-Length"))
			}

			got, err := io.ReadAll(r.Body)
			if err != nil || !bytes.Equal(got, want) {
				t.Fatalf("first body = %q, %v; want %q", got, err, want)
			}
			for i := 0; i < 2; i++ {
				body, err := r.GetBody()
				if err != nil {
					t.Fatalf("GetBody #%d: %v", i+1, err)
				}
				got, err := io.ReadAll(body)
				body.Close()
				if err != nil || !bytes.Equal(got, want) {
					t.Fatalf("replay #%d = %q, %v; want %q", i+1, got, err, want)
				}
			}
		})
	}
}

type countingBody struct {
	reads int
	data  *strings.Reader
}

func (b *countingBody) Read(p []byte) (int, error) {
	b.reads++
	return b.data.Read(p)
}
func (*countingBody) Close() error { return nil }

func TestMakeReplayableControlBodyLeavesUnsafeRequestsUntouched(t *testing.T) {
	tests := []struct {
		name          string
		path          string
		contentLength int64
	}{
		{"inference", "/v1/messages", 4},
		{"worker events", "/v1/code/sessions/cse_123/worker/events", 4},
		{"unknown length", "/v1/code/sessions/cse_123/worker/heartbeat", -1},
		{"over limit", "/v1/code/sessions/cse_123/worker/heartbeat", replayableBodyLimit + 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			body := &countingBody{data: strings.NewReader("data")}
			r := &http.Request{
				Method:        http.MethodPost,
				URL:           &url.URL{Path: tt.path},
				Header:        make(http.Header),
				Body:          body,
				ContentLength: tt.contentLength,
			}
			if makeReplayableControlBody(r) {
				t.Fatal("unsafe request was made replayable")
			}
			if r.Body != body || body.reads != 0 || r.GetBody != nil {
				t.Fatalf("request was touched: sameBody=%v reads=%d getBody=%v", r.Body == body, body.reads, r.GetBody != nil)
			}
		})
	}
}

func BenchmarkMakeReplayableControlBody(b *testing.B) {
	body := `{"worker_epoch":7,"external_metadata":{"model":"test-model"},"status":"active"}`
	b.SetBytes(int64(len(body)))
	b.ReportAllocs()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			r := testRequest(http.MethodPost,
				"/v1/code/sessions/cse_benchmark/worker/heartbeat",
				body, int64(len(body)))
			if !makeReplayableControlBody(r) || r.GetBody == nil {
				b.Fatal("request was not made replayable")
			}
		}
	})
}

func TestDirectorAddsReplayOnlyToDirectAllowlist(t *testing.T) {
	oldToken := poolToken
	poolToken = "test-token"
	t.Cleanup(func() { poolToken = oldToken })

	rp := newReverseProxy(nil)
	heartbeatBody := `{"worker_epoch":1}`
	heartbeat := testRequest(http.MethodPost,
		"/v1/code/sessions/cse_123/worker/heartbeat",
		heartbeatBody, int64(len(heartbeatBody)))
	rp.Director(heartbeat)
	if heartbeat.URL.Scheme != "https" || heartbeat.URL.Host != anthropicHost || heartbeat.GetBody == nil {
		t.Fatalf("heartbeat route/replay wrong: url=%s getBody=%v", heartbeat.URL.String(), heartbeat.GetBody != nil)
	}

	messageBody := `{"model":"test","messages":[]}`
	message := testRequest(http.MethodPost, "/v1/messages", messageBody, int64(len(messageBody)))
	rp.Director(message)
	if message.URL.Scheme != "http" || message.URL.Host != upstreamPool || message.GetBody != nil {
		t.Fatalf("message route/replay wrong: url=%s getBody=%v", message.URL.String(), message.GetBody != nil)
	}
}
