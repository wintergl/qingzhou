package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"testing"

	socks5 "github.com/things-go/go-socks5"
)

func TestTunnelCommandsRequestBusinessOnlyForExplicitVerification(t *testing.T) {
	var requests atomic.Int32
	business := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer business.Close()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil { t.Fatal(err) }
	connected := &companyTunnel{listener: listener, info: tunnelInfo{Port: listener.Addr().(*net.TCPAddr).Port, Transport: "atrust-tcp"}}
	defer connected.close()
	server := socks5.NewServer(socks5.WithRule(&socks5.PermitCommand{EnableConnect: true}),
		socks5.WithDial(func(ctx context.Context, network, address string) (net.Conn, error) {
			conn, err := (&net.Dialer{}).DialContext(ctx, network, address)
			if err != nil { return nil, err }
			counted := &countedConn{Conn: conn, owner: connected}
			connected.active.Store(counted, true)
			return counted, nil
		}))
	go func() { _ = server.Serve(listener) }()
	output := &bytes.Buffer{}
	b := bridge{output: json.NewEncoder(output)}
	var tunnel *companyTunnel
	starts := 0
	start := func() (*companyTunnel, error) { starts++; return connected, nil }
	b.controlTunnel(command{Type: "connect", Target: "file:///invalid-verification-target"}, &tunnel, start)
	b.controlTunnel(command{Type: "connect"}, &tunnel, start)
	if tunnel != connected || starts != 1 || requests.Load() != 0 { t.Fatal("connect unexpectedly required or requested a business address") }
	if connected.info.Target != "" || connected.info.HTTPStatus != 0 { t.Fatal("connection readiness claimed business verification") }
	b.controlTunnel(command{Type: "verify", Target: business.URL}, &tunnel, start)
	if requests.Load() != 1 || tunnel != connected { t.Fatal("verification did not use the existing company tunnel") }
	b.controlTunnel(command{Type: "disconnect", Target: "file:///invalid-verification-target"}, &tunnel, start)
	b.controlTunnel(command{Type: "disconnect"}, &tunnel, start)
	if tunnel != nil || starts != 1 || requests.Load() != 1 { t.Fatal("disconnect unexpectedly requested a business address") }
	if !bytes.Contains(output.Bytes(), []byte(`"type":"tunnel_verified"`)) || !bytes.Contains(output.Bytes(), []byte(`"type":"tunnel_closed"`)) {
		t.Fatal("verification and disconnect completion were not reported separately")
	}
}

func TestVerificationCannotEstablishATunnel(t *testing.T) {
	output := &bytes.Buffer{}
	b := bridge{output: json.NewEncoder(output)}
	var tunnel *companyTunnel
	starts := 0
	b.controlTunnel(command{Type: "verify", Target: "192.0.2.55"}, &tunnel, func() (*companyTunnel, error) { starts++; return nil, nil })
	if starts != 0 || tunnel != nil { t.Fatal("verification attempted to connect implicitly") }
	if !bytes.Contains(output.Bytes(), []byte(`"stage":"business"`)) { t.Fatal("missing disconnected verification error") }
}

func TestTunnelVerificationDoesNotFallBackToOfficeLAN(t *testing.T) {
	var directRequests atomic.Int32
	business := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		directRequests.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer business.Close()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	closedSOCKSPort := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	t.Setenv("HTTP_PROXY", business.URL)
	target, _ := url.Parse(business.URL)
	if _, _, err := verifyThroughSOCKS(closedSOCKSPort, target); err == nil {
		t.Fatal("accepted a reachable LAN business with a disconnected company SOCKS outlet")
	}
	if directRequests.Load() != 0 {
		t.Fatal("business was reached directly after the company outlet failed")
	}
}

func TestTunnelVerificationUsesSOCKSAndDoesNotFollowRedirects(t *testing.T) {
	var proxyConnections, redirectedRequests atomic.Int32
	redirected := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		redirectedRequests.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer redirected.Close()
	business := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/redirect" {
			http.Redirect(w, r, redirected.URL, http.StatusFound)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer business.Close()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	server := socks5.NewServer(socks5.WithRule(&socks5.PermitCommand{EnableConnect: true}),
		socks5.WithDial(func(ctx context.Context, network, address string) (net.Conn, error) {
			proxyConnections.Add(1)
			return (&net.Dialer{}).DialContext(ctx, network, address)
		}))
	go func() { _ = server.Serve(listener) }()
	port := listener.Addr().(*net.TCPAddr).Port
	target, _ := url.Parse(business.URL)
	status, _, err := verifyThroughSOCKS(port, target)
	if err != nil || status != http.StatusNoContent {
		t.Fatalf("SOCKS business failed: status=%d err=%v", status, err)
	}
	target.Path = "/redirect"
	status, _, err = verifyThroughSOCKS(port, target)
	if err != nil || status != http.StatusFound {
		t.Fatalf("redirect response was not preserved: status=%d err=%v", status, err)
	}
	if proxyConnections.Load() != 2 {
		t.Fatalf("requests did not use the SOCKS outlet: %d", proxyConnections.Load())
	}
	if redirectedRequests.Load() != 0 {
		t.Fatal("verification followed a redirect outside the specified business")
	}
}

func TestTunnelTargetDoesNotAcceptCredentialsOrTokens(t *testing.T) {
	for _, raw := range []string{"", "file:///etc/passwd", "http://user:password@example.com", "https://example.com/?token=secret", "https://example.com/#secret"} {
		if _, err := validatedTarget(raw); err == nil {
			t.Errorf("unsafe target accepted: %q", raw)
		}
	}
	u, err := validatedTarget("192.0.2.55")
	if err != nil || u.String() != "http://192.0.2.55/" {
		t.Fatalf("plain IP not supported: url=%v err=%v", u, err)
	}
}

func TestExistingTunnelRemainsOpenAfterARevalidationFailure(t *testing.T) {
	business := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/failed" { w.WriteHeader(http.StatusServiceUnavailable); return }
		w.WriteHeader(http.StatusNoContent)
	}))
	defer business.Close()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil { t.Fatal(err) }
	tunnel := &companyTunnel{listener: listener, info: tunnelInfo{Port: listener.Addr().(*net.TCPAddr).Port}}
	defer tunnel.close()
	server := socks5.NewServer(socks5.WithRule(&socks5.PermitCommand{EnableConnect: true}),
		socks5.WithDial(func(ctx context.Context, network, address string) (net.Conn, error) {
			conn, err := (&net.Dialer{}).DialContext(ctx, network, address)
			if err != nil { return nil, err }
			counted := &countedConn{Conn: conn, owner: tunnel}
			tunnel.active.Store(counted, true)
			return counted, nil
		}))
	go func() { _ = server.Serve(listener) }()
	first, err := tunnel.verify(business.URL)
	if err != nil { t.Fatal(err) }
	if _, err := tunnel.verify(business.URL + "/failed"); err == nil { t.Fatal("accepted a failing business response") }
	if tunnel.info != first { t.Fatal("a failed revalidation replaced the previous business evidence") }
	last, err := tunnel.verify(business.URL)
	if err != nil { t.Fatalf("revalidation closed the listener: %v", err) }
	if last.Port != first.Port || last.Sent <= first.Sent || last.Received <= first.Received {
		t.Fatalf("the same tunnel was not kept: first=%+v last=%+v", first, last)
	}
}
