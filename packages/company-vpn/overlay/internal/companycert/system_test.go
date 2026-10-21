package companycert

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"testing"
	"time"
)

func TestSystemChainRequiresTrustedAuthorityMatchingHostValidTimeAndServerUsage(t *testing.T) {
	now := time.Now()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	issue := func(template, parent *x509.Certificate) *x509.Certificate {
		t.Helper()
		der, err := x509.CreateCertificate(rand.Reader, template, parent, &key.PublicKey, key)
		if err != nil {
			t.Fatal(err)
		}
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			t.Fatal(err)
		}
		return cert
	}
	rootTemplate := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "fixture-root"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign}
	root := issue(rootTemplate, rootTemplate)
	intermediate := issue(&x509.Certificate{SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "fixture-intermediate"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign}, root)
	leaf := func(before, after time.Time, usage x509.ExtKeyUsage) *x509.Certificate {
		return issue(&x509.Certificate{SerialNumber: big.NewInt(3), Subject: pkix.Name{CommonName: "gateway.invalid"},
			DNSNames: []string{"gateway.invalid"}, NotBefore: before, NotAfter: after,
			KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{usage}}, intermediate)
	}
	valid := leaf(now.Add(-time.Minute), now.Add(time.Minute), x509.ExtKeyUsageServerAuth)
	roots := x509.NewCertPool()
	roots.AddCert(root)
	for _, test := range []struct {
		name    string
		chain   []*x509.Certificate
		host    string
		roots   *x509.CertPool
		allowed bool
	}{
		{"trusted-matching-valid", []*x509.Certificate{valid, intermediate}, "gateway.invalid", roots, true},
		{"unknown-authority", []*x509.Certificate{valid, intermediate}, "gateway.invalid", x509.NewCertPool(), false},
		{"host-mismatch", []*x509.Certificate{valid, intermediate}, "other.invalid", roots, false},
		{"missing-host", []*x509.Certificate{valid, intermediate}, "", roots, false},
		{"missing-certificate", nil, "gateway.invalid", roots, false},
		{"missing-intermediate", []*x509.Certificate{valid}, "gateway.invalid", roots, false},
		{"expired", []*x509.Certificate{leaf(now.Add(-time.Hour), now.Add(-time.Minute), x509.ExtKeyUsageServerAuth), intermediate}, "gateway.invalid", roots, false},
		{"not-yet-valid", []*x509.Certificate{leaf(now.Add(time.Minute), now.Add(time.Hour), x509.ExtKeyUsageServerAuth), intermediate}, "gateway.invalid", roots, false},
		{"client-only", []*x509.Certificate{leaf(now.Add(-time.Minute), now.Add(time.Minute), x509.ExtKeyUsageClientAuth), intermediate}, "gateway.invalid", roots, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := VerifySystemChain(tls.ConnectionState{PeerCertificates: test.chain}, test.host, test.roots, now)
			if (err == nil) != test.allowed {
				t.Fatalf("allowed=%t, error=%v", test.allowed, err)
			}
		})
	}
}
