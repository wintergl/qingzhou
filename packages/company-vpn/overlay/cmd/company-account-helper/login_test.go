package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
 "github.com/mythologyli/zju-connect/internal/companyprocess"
)

// This local server exercises the real Session.Login implementation, including
// RSA password encryption, environment report, session cookie, and clientResource.
// No request in these tests is sent to the company gateway.
func TestAccountLoginThenGrantedResources(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	const password = "local-test-password"
	const sid = "local-test-session-cookie"
	const ticket = "local-test-auth-ticket"
	paths := []string{}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		if r.URL.Query().Get("platform") != companyprocess.AuthPlatform() {
			t.Error("incorrect platform")
		}
		switch r.URL.Path {
		case "/passport/v1/public/authConfig":
			_ = json.NewEncoder(w).Encode(map[string]any{"code": 0, "data": map[string]any{
				"isLogin": 0, "csrfToken": "local-test-csrf", "pubKey": fmt.Sprintf("%X", key.N),
				"pubKeyExp": "65537", "antiReplayRand": "test-rand",
				"authServerInfoList": []map[string]any{{"loginDomain": "local", "authType": "auth/psw", "authName": "本地密码认证"}},
			}})
		case "/passport/v1/auth/psw":
			var body struct {
				Username, Password string
				RememberPwd        string `json:"rememberPwd"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Error(err)
			}
			cipher, err := hex.DecodeString(body.Password)
			if err != nil {
				t.Error(err)
			}
			plain, err := rsa.DecryptPKCS1v15(rand.Reader, key, cipher)
			if err != nil || string(plain) != password+"_test-rand" || body.Username != "tester@local" || body.RememberPwd != "0" {
				t.Error("password authentication request was not correctly encrypted or scoped")
			}
			fmt.Fprintf(w, `{"code":0,"data":{"ticket":%q,"nextService":"auth/authCheck"}}`, ticket)
		case "/controller/v1/public/reportEnv":
			var payload struct{ Ticket, DeviceID string }
			_ = json.NewDecoder(r.Body).Decode(&payload)
			if payload.Ticket != ticket || len(payload.DeviceID) != 32 {
				t.Error("missing login ticket/device ID")
			}
			fmt.Fprint(w, `{"code":0}`)
		case "/passport/v1/auth/authCheck":
			http.SetCookie(w, &http.Cookie{Name: "sid", Value: sid, Path: "/", Secure: true, HttpOnly: true})
			fmt.Fprint(w, `{"code":0,"data":{"nextService":""}}`)
		case "/passport/v1/user/onlineInfo":
			c, err := r.Cookie("sid")
			if err != nil || c.Value != sid {
				t.Error("onlineInfo called without authenticated session")
			}
			fmt.Fprint(w, `{"code":0,"data":{"username":"tester"}}`)
		case "/controller/v1/user/clientResource":
			c, err := r.Cookie("sid")
			if err != nil || c.Value != sid {
				t.Error("resources called without authenticated session")
			}
			fmt.Fprint(w, `{"code":0,"data":{"appList":{"code":0,"data":{"appInfo":[{"apps":[{"id":"1","name":"测试应用","accessModel":"L3VPN","addressList":[{"protocol":"tcp","port":"80","host":"10.0.0.8"}]}]}]}}}}`)
		default:
			t.Errorf("unexpected request %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	pin := sha256.Sum256(server.Certificate().Raw)
	t.Setenv("SPLITVPN_ATRUST_CERT_SHA256", "")
	output := &bytes.Buffer{}
	b := bridge{input: bufio.NewScanner(strings.NewReader("{\"type\":\"end\"}\n")), output: json.NewEncoder(output)}
	b.run(command{Type: "login", Origin: server.URL, Username: "tester", Password: password, Domain: "local", Fingerprint: hex.EncodeToString(pin[:])})
	events := output.String()
	if !strings.Contains(events, `"type":"login_success"`) || !strings.Contains(events, `"type":"resources"`) || strings.Contains(events, `"type":"error"`) {
		t.Fatalf("authentication/resource events missing: %s", events)
	}
	for _, secret := range []string{password, sid, ticket, "local-test-csrf"} {
		if strings.Contains(events, secret) {
			t.Error("private session data leaked to native app")
		}
	}
	if len(paths) != 6 {
		t.Fatalf("expected entire auth/resource sequence, got %d requests", len(paths))
	}
}
