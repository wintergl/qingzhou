package atrust

import (
	"crypto/tls"
	"github.com/mythologyli/zju-connect/client/atrust/auth"
	"github.com/mythologyli/zju-connect/internal/companycert"
)

func (c *Client) companyTLSConfig(config *tls.Config) *tls.Config {
	if c.certificateFingerprint != "" {
		config.VerifyConnection = companycert.ForFingerprint(c.certificateFingerprint)
	}
	return config
}

func (c *Client) CompanySnapshot() (auth.LoginResult, error) {
	c.sessionMu.RLock()
	session := c.companyAuthSession
	failure := c.sessionErr
	c.sessionMu.RUnlock()
	if failure != nil {
		return auth.LoginResult{}, failure
	}
	if session == nil {
		return auth.LoginResult{}, auth.ErrSessionInvalid
	}
	return session.Snapshot()
}
