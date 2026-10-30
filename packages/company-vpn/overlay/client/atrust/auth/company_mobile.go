package auth

import (
	"context"
	"fmt"
	"github.com/mythologyli/zju-connect/internal/companycert"
	"io"
	"net/http"
)

func (s *Session) SetCertificatePin(fingerprint string) {
	s.companyPin = fingerprint
	if transport, ok := s.client.Transport.(*http.Transport); ok {
		transport.TLSClientConfig = transport.TLSClientConfig.Clone()
		transport.TLSClientConfig.VerifyConnection = companycert.ForFingerprint(fingerprint)
	}
}
func (s *Session) CertificatePin() string { return s.companyPin }

// One context covers all requests in a login, including password changes. A
// canceled write is indeterminate, never permission to repeat that write.
func (s *Session) SetLifecycleContext(ctx context.Context) {
	if ctx != nil {
		s.client.Transport = lifecycleTransport{s.client.Transport, ctx}
	}
}

type lifecycleTransport struct {
	base http.RoundTripper
	ctx  context.Context
}

func (t lifecycleTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	response, err := t.base.RoundTrip(r.WithContext(t.ctx))
	if err != nil {
		return nil, err
	}
	if response.ContentLength > 4*1024*1024 {
		_ = response.Body.Close()
		return nil, fmt.Errorf("认证响应超过支持大小")
	}
	response.Body = &boundedAuthBody{ReadCloser: response.Body, remaining: 4 * 1024 * 1024}
	return response, nil
}

type boundedAuthBody struct {
	io.ReadCloser
	remaining int
}

func (b *boundedAuthBody) Read(p []byte) (int, error) {
	if b.remaining == 0 {
		var extra [1]byte
		n, err := b.ReadCloser.Read(extra[:])
		if n > 0 {
			return 0, fmt.Errorf("认证响应超过支持大小")
		}
		return 0, err
	}
	if len(p) > b.remaining {
		p = p[:b.remaining]
	}
	n, err := b.ReadCloser.Read(p)
	b.remaining -= n
	return n, err
}
func (t lifecycleTransport) CloseIdleConnections() {
	if v, ok := t.base.(interface{ CloseIdleConnections() }); ok {
		v.CloseIdleConnections()
	}
}
