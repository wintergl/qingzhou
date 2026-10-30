package auth

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

type fixtureRoundTripper func(*http.Request) (*http.Response, error)

func (f fixtureRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestMobileLifecycleCancellationAndResponseLimit(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	tr := lifecycleTransport{fixtureRoundTripper(func(r *http.Request) (*http.Response, error) { return nil, r.Context().Err() }), ctx}
	req, _ := http.NewRequest("GET", "https://example.test", nil)
	if _, err := tr.RoundTrip(req); err == nil {
		t.Fatal("cancel not propagated")
	}
	for _, size := range []int{4 * 1024 * 1024, 4*1024*1024 + 1} {
		body := &boundedAuthBody{ReadCloser: io.NopCloser(strings.NewReader(strings.Repeat("x", size))), remaining: 4 * 1024 * 1024}
		data, err := io.ReadAll(body)
		if size > 4*1024*1024 && err == nil {
			t.Fatal("unbounded body")
		}
		if len(data) > 4*1024*1024 {
			t.Fatal("memory bound exceeded")
		}
		if size == 4*1024*1024 && err != nil {
			t.Fatal(err)
		}
	}
}

// The upstream protocol tests use httptest's fixed local certificate. Confirm
// that fixture explicitly; production verification remains unchanged.
func TestMain(m *testing.M) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	pin := sha256.Sum256(server.Certificate().Raw)
	server.Close()
	_ = os.Setenv("SPLITVPN_ATRUST_CERT_SHA256", hex.EncodeToString(pin[:]))
	os.Exit(m.Run())
}
