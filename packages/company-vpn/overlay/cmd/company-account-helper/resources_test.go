package main

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestGrantedResourcesExcludeSessionSecrets(t *testing.T) {
	raw := []byte(`{"code":0,"sid":"session-secret","data":{"appList":{"code":0,"data":{"appInfo":[{"apps":[{"id":"17","name":"示例应用","accessModel":"L3VPN","ticket":"ticket-secret","addressList":[{"protocol":"tcp","port":"80","host":"10.0.0.8","ip":[]} ]},{"id":"18","name":"示例门户","url":"https://example.test/home?token=url-secret#fragment"}]}],"config":{"nodeGroupConf":{"nodeGroupList":[{"addressInfo":[{"address":"gateway.test:443"}]}]}}}},"sdpPolicy":{"data":{"clientOption":{"dnsOption":{"firstDNS":"10.0.0.1"}}}},"password":"password-secret"}}`)
	result, err := parseResources(raw)
	if err != nil {
		t.Fatal(err)
	}
	if result.AppCount != 2 || len(result.Rows) != 2 || result.Rows[0].Address != "10.0.0.8" || result.Rows[0].Ports != "80" {
		t.Fatalf("wrong resource summary: %+v", result)
	}
	if len(result.DNS) != 1 || len(result.Gateways) != 1 {
		t.Fatal("missing network metadata")
	}
	encoded, _ := json.Marshal(result)
	for _, forbidden := range []string{"session-secret", "ticket-secret", "url-secret", "password-secret", "fragment"} {
		if strings.Contains(string(encoded), forbidden) {
			t.Fatalf("leaked %s", forbidden)
		}
	}
}

func TestResourceFailureIsNotEmptySuccess(t *testing.T) {
	for _, raw := range []string{
		`{"code":75500002,"data":{}}`,
		`{"code":0,"data":{"appList":{"code":401,"data":{"appInfo":[]}}}}`,
		`{"data":{"appList":{"data":{"appInfo":[]}}}}`,
		`{"code":0,"data":{}}`,
		`{"code":0,"data":{"appList":{"data":{"appInfo":{}}}}}`,
	} {
		if _, err := parseResources([]byte(raw)); err == nil {
			t.Fatalf("reported failure as success: %s", raw)
		}
	}
	result, err := parseResources([]byte(`{"code":0,"data":{"appList":{"code":0,"data":{"appInfo":[]}}}}`))
	if err != nil || result.AppCount != 0 || result.Rows == nil {
		t.Fatalf("legitimate empty resources rejected: %v", err)
	}
}

func TestLocalChallengeRepliesBindToPendingRequest(t *testing.T) {
	input := `{"type":"challenge_response","id":"challenge-1","code":"123456"}` + "\n"
	b := testBridge(input)
	r, err := b.answer(challenge{Kind: "code"})
	if err != nil || r.Code != "123456" {
		t.Fatalf("valid reply failed: %v", err)
	}
	b = testBridge(`{"type":"challenge_response","id":"stale","code":"123456"}` + "\n")
	if _, err := b.answer(challenge{Kind: "code"}); err == nil {
		t.Fatal("stale reply accepted")
	}
}

func TestDiagnosticsDoNotEchoPassword(t *testing.T) {
	message := safeError(errors.New("password authentication failed with code 42: wrong password secret-value"), "secret-value")
	if strings.Contains(message, "secret-value") || !strings.Contains(message, "42") {
		t.Fatalf("unsafe/unhelpful diagnostic: %s", message)
	}
}
