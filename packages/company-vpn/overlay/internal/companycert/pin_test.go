package companycert

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestTLSRejectsUnconfirmedOrChangedCertificateBeforeSendingHTTP(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	pin := sha256.Sum256(server.Certificate().Raw)
	for _, test := range []struct { name, value string; allowed bool }{
		{"missing", "", false},
		{"changed", strings.Repeat("00", 32), false},
		{"confirmed", hex.EncodeToString(pin[:]), true},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv("SPLITVPN_ATRUST_CERT_SHA256", test.value)
			transport := &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true, VerifyConnection: VerifyConnection}}
			defer transport.CloseIdleConnections()
			client := &http.Client{Transport: transport, Timeout: 3 * time.Second}
			before := requests.Load()
			response, err := client.Get(server.URL)
			if test.allowed {
				if err != nil { t.Fatal(err) }
				response.Body.Close()
				if requests.Load() != before+1 { t.Fatal("confirmed channel did not reach handler") }
			} else {
				if err == nil { response.Body.Close(); t.Fatal("unexpected unverified request") }
				if requests.Load() != before { t.Fatal("HTTP was sent before certificate was verified") }
			}
		})
	}
}

func TestConfirmedPinStillRejectsExpiredCertificate(t *testing.T) {
	cert := &x509.Certificate{Raw: []byte("fixture"), NotBefore: time.Now().Add(-2*time.Hour), NotAfter: time.Now().Add(-time.Hour)}
	pin := sha256.Sum256(cert.Raw)
	t.Setenv("SPLITVPN_ATRUST_CERT_SHA256", hex.EncodeToString(pin[:]))
	if err := VerifyConnection(tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}}); err == nil {
		t.Fatal("expired certificate was accepted")
	}
}
