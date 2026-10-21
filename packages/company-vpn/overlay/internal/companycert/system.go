package companycert

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"time"
)

// nil roots uses the OS trust store. A trusted chain must also match the
// gateway hostname and be valid for server authentication at this time.
func VerifySystemChain(state tls.ConnectionState, hostname string, roots *x509.CertPool, now time.Time) error {
	if hostname == "" || len(state.PeerCertificates) == 0 {
		return fmt.Errorf("ATRUST_CERT_MISSING_HOST_OR_CERTIFICATE")
	}
	intermediates := x509.NewCertPool()
	for _, certificate := range state.PeerCertificates[1:] {
		intermediates.AddCert(certificate)
	}
	_, err := state.PeerCertificates[0].Verify(x509.VerifyOptions{
		DNSName: hostname, Roots: roots, Intermediates: intermediates,
		CurrentTime: now, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	})
	return err
}
