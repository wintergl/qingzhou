package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/mythologyli/zju-connect/internal/companycert"
)

type authMethod struct {
	LoginDomain string `json:"loginDomain"`
	AuthType    string `json:"authType"`
	AuthName    string `json:"authName"`
}

type probeInfo struct {
	Origin        string       `json:"origin"`
	Fingerprint   string       `json:"fingerprint"`
	Subject       string       `json:"subject"`
	ValidTo       string       `json:"validTo"`
	ValidFrom     string       `json:"validFrom"`
	NameMatches   bool         `json:"nameMatches"`
	SelfSigned    bool         `json:"selfSigned"`
	SystemTrusted bool         `json:"systemTrusted"`
	Methods       []authMethod `json:"methods"`
}

func probe(u *url.URL) (probeInfo, error) {
	var result probeInfo
	port := u.Port()
	if port == "" {
		port = "443"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	// This handshake only observes a certificate. No credentials or HTTP data
	// are sent until the exact observed certificate is scoped to public GETs.
	dialer := tls.Dialer{NetDialer: &net.Dialer{Timeout: 8 * time.Second}, Config: &tls.Config{
		InsecureSkipVerify: true, MinVersion: tls.VersionTLS12, ServerName: u.Hostname(),
	}}
	connection, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(u.Hostname(), port))
	if err != nil {
		return result, err
	}
	tlsConnection := connection.(*tls.Conn)
	state := tlsConnection.ConnectionState()
	_ = connection.Close()
	if len(state.PeerCertificates) == 0 {
		return result, fmt.Errorf("接入网关未提供证书。")
	}
	certificate := state.PeerCertificates[0]
	now := time.Now()
	if now.Before(certificate.NotBefore) || now.After(certificate.NotAfter) {
		return result, fmt.Errorf("接入网关的 certificate 不在有效期内。")
	}
	observed := sha256.Sum256(certificate.Raw)
	tr := &http.Transport{TLSClientConfig: &tls.Config{
		InsecureSkipVerify: true, MinVersion: tls.VersionTLS12,
		VerifyConnection: func(s tls.ConnectionState) error {
			if len(s.PeerCertificates) == 0 || sha256.Sum256(s.PeerCertificates[0].Raw) != observed {
				return fmt.Errorf("certificate changed during public probe")
			}
			return nil
		},
	}}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: 12 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	get := func(path string, output any) error {
		req, err := http.NewRequest(http.MethodGet, u.String()+path, nil)
		if err != nil {
			return err
		}
		req.Header.Set("User-Agent", "SplitVPN-CompanyAccountTest/0.1 (macOS)")
		req.Header.Set("Accept", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("public endpoint HTTP %d", resp.StatusCode)
		}
		return json.NewDecoder(io.LimitReader(resp.Body, 512*1024)).Decode(output)
	}
	var manifest struct {
		Code *int `json:"code"`
	}
	if err := get("/public/manifest", &manifest); err != nil {
		return result, err
	}
	if manifest.Code == nil || *manifest.Code != 0 {
		return result, fmt.Errorf("接入网关未返回有效的 aTrust 服务信息。")
	}
	var config struct {
		Code *int `json:"code"`
		Data struct {
			Methods []authMethod `json:"authServerInfoList"`
		} `json:"data"`
	}
	if err := get("/passport/v1/public/authConfig?clientType=SDPClient&platform=Mac&lang=zh-CN&needTicket=0", &config); err != nil {
		return result, err
	}
	if config.Code == nil || *config.Code != 0 {
		return result, fmt.Errorf("接入网关未返回有效的认证方式。")
	}
	parts := make([]string, len(observed))
	for i, value := range observed {
		parts[i] = strings.ToUpper(hex.EncodeToString([]byte{value}))
	}
	result = probeInfo{Origin: u.String(), Fingerprint: strings.Join(parts, ":"), Subject: certificate.Subject.String(),
		ValidTo: certificate.NotAfter.Format(time.RFC3339), NameMatches: certificate.VerifyHostname(u.Hostname()) == nil,
		ValidFrom:     certificate.NotBefore.Format(time.RFC3339),
		SelfSigned:    bytes.Equal(certificate.RawIssuer, certificate.RawSubject),
		SystemTrusted: companycert.VerifySystemChain(state, u.Hostname(), nil, now) == nil, Methods: config.Data.Methods}
	if result.Methods == nil {
		result.Methods = []authMethod{}
	}
	return result, nil
}
