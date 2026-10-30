package companycert

import (
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"time"
)

// VerifyConnection replaces public-PKI/name checks for this self-signed
// deployment with an explicit, per-run certificate pin and expiry check.
// Missing/changed pins fail before HTTP credentials or tunnel tickets are sent.
func VerifyConnection(state tls.ConnectionState) error {
	return ForFingerprint(os.Getenv("SPLITVPN_ATRUST_CERT_SHA256"))(state)
}

// Embedded clients bind the pin to one authenticated session. Changing another
// session must never change the certificate accepted by an in-flight request.
func ForFingerprint(fingerprint string) func(tls.ConnectionState) error {
	return func(state tls.ConnectionState) error {
		value := strings.ReplaceAll(strings.TrimSpace(fingerprint), ":", "")
		pin, err := hex.DecodeString(value)
		if err != nil || len(pin) != sha256.Size {
			return fmt.Errorf("ATRUST_CERT_PIN_REQUIRED: certificate must be confirmed locally before login")
		}
		if len(state.PeerCertificates) == 0 {
			return fmt.Errorf("ATRUST_CERT_MISSING")
		}
		cert := state.PeerCertificates[0]
		actual := sha256.Sum256(cert.Raw)
		if subtle.ConstantTimeCompare(pin, actual[:]) != 1 {
			return fmt.Errorf("ATRUST_CERT_PIN_MISMATCH: received SHA256 %X; stop and verify this gateway certificate", actual)
		}
		now := time.Now()
		if now.Before(cert.NotBefore) || now.After(cert.NotAfter) {
			return fmt.Errorf("ATRUST_CERT_EXPIRED_OR_NOT_YET_VALID")
		}
		return nil
	}
}
