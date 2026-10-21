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
)

const fixtureOldPassword = "fixture-old-password!"
const fixtureNewPassword = "fixture-New9!密码"

type passwordFixtureOptions struct {
	afterAuthCheck, rejectFirst, totp, totpFails, rename bool
	failure                                              string
}

// Real login and RSA/form requests against a pinned loopback TLS server.
// These tests never use a live account, tunnel or keychain.
func passwordFixture(t *testing.T, options passwordFixtureOptions, answers ...command) ([]event, int) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	changed, tokenPassed, changes := false, false, 0
	nonce, username := "fixture-password-nonce", "fixture"
	if options.rename {
		username = "fixture-renamed"
	}
	policy := map[string]any{"modifyPwdMessage": "接入密码已到期", "modifyPwdCode": 75500401,
		"pswStrategy": map[string]any{"enablePswLength": map[string]any{"enable": true, "value": 12},
			"enablePswCombination": map[string]any{"enable": true, "value": map[string]any{"enableUpperAndLowerLetter": true, "enableNumber": true}}}}
	if options.rename {
		policy["modifyPwdCode"] = 75500402
	}
	decrypt := func(raw string) string {
		cipher, err := hex.DecodeString(raw)
		if err != nil || len(cipher)%key.Size() != 0 {
			t.Error("invalid password encryption")
			return ""
		}
		var plain []byte
		for len(cipher) > 0 {
			chunk, err := rsa.DecryptPKCS1v15(rand.Reader, key, cipher[:key.Size()])
			if err != nil {
				t.Error("cannot decrypt fixture password")
				return ""
			}
			plain = append(plain, chunk...)
			cipher = cipher[key.Size():]
		}
		return string(plain)
	}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/passport/v1/public/authConfig":
			_ = json.NewEncoder(w).Encode(map[string]any{"code": 0, "data": map[string]any{
				"isLogin": 0, "csrfToken": "fixture-csrf", "pubKey": fmt.Sprintf("%X", key.N),
				"pubKeyExp": "65537", "antiReplayRand": "fixture-initial-nonce",
				"authServerInfoList": []map[string]any{{"loginDomain": "local", "authType": "auth/psw", "authName": "接入账号"}}}})
		case "/passport/v1/auth/psw":
			http.SetCookie(w, &http.Cookie{Name: "sid", Value: "fixture-pending-sid", Path: "/", Secure: true, HttpOnly: true})
			data := map[string]any{"ticket": "fixture-ticket", "nextService": "auth/modifyPwd", "antiReplayRand": nonce}
			for k, v := range policy {
				data[k] = v
			}
			if options.afterAuthCheck {
				data["nextService"] = "auth/authCheck"
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"code": 0, "data": data})
		case "/controller/v1/public/reportEnv":
			fmt.Fprint(w, `{"code":0}`)
		case "/passport/v1/auth/authCheck":
			if !changed {
				nonce = "fixture-auth-check-nonce"
				_ = json.NewEncoder(w).Encode(map[string]any{"code": 0, "data": map[string]any{"nextService": "auth/modifyPwd", "antiReplayRand": nonce}})
			} else {
				http.SetCookie(w, &http.Cookie{Name: "sid", Value: "fixture-authenticated-sid", Path: "/", Secure: true, HttpOnly: true})
				fmt.Fprint(w, `{"code":0,"data":{"nextService":""}}`)
			}
		case "/passport/v1/auth/modifyPwd":
			changes++
			if r.Method != http.MethodPost || r.Header.Get("Content-Type") != "application/x-www-form-urlencoded" ||
				r.Header.Get("x-csrf-token") != "fixture-csrf" || r.Header.Get("x-sdp-env") == "" || r.URL.Query().Get("clientType") != "SDPClient" {
				t.Error("incorrect password change request headers or method")
			}
			if c, err := r.Cookie("sid"); err != nil || c.Value != "fixture-pending-sid" {
				t.Error("lost pending login cookie")
			}
			_ = r.ParseForm()
			wantNew := fixtureNewPassword
			if options.rejectFirst && changes == 1 {
				wantNew = "fixture-rejected-password"
			}
			if decrypt(r.PostForm.Get("oldPassword")) != fixtureOldPassword+"_"+nonce ||
				decrypt(r.PostForm.Get("newPassword")) != wantNew+"_"+nonce || r.PostForm.Get("newUserName") != username {
				t.Error("incorrect encrypted password, username or fresh anti-replay nonce")
			}
			switch options.failure {
			case "missing-code":
				fmt.Fprint(w, `{"data":{}}`)
				return
			case "http":
				http.Error(w, "fixture error", 500)
				return
			case "expired":
				http.Error(w, "fixture expired", 401)
				return
			case "expired-code":
				fmt.Fprint(w, `{"code":75500001,"message":"session expired"}`)
				return
			case "already-online":
				fmt.Fprint(w, `{"code":75500006,"message":"already online"}`)
				return
			case "redirect":
				http.Redirect(w, r, "/passport/v1/public/authConfig", 302)
				return
			}
			if options.rejectFirst && changes == 1 {
				nonce = "fixture-retry-nonce"
				_ = json.NewEncoder(w).Encode(map[string]any{"code": 75500405,
					"message": "密码不能属于弱密码库 " + wantNew + " ticket=fixture-private-ticket",
					"data":    map[string]any{"antiReplayRand": nonce}})
				return
			}
			changed = true
			if options.totp {
				fmt.Fprint(w, `{"code":0,"data":{"nextService":"auth/token","nextServiceList":[{"authType":"auth/totp","authId":"fixture-totp"}],"antiReplayRand":"fixture-after-change-nonce"}}`)
			} else {
				fmt.Fprint(w, `{"code":0,"data":{}}`)
			}
		case "/passport/v1/auth/token":
			if !changed {
				t.Error("token requested before password change")
			}
			var payload map[string]any
			_ = json.NewDecoder(r.Body).Decode(&payload)
			if payload["totpToken"] != "123456" || payload["username"] != username+"@local" {
				t.Error("lost subsequent authentication or changed username")
			}
			if options.totpFails {
				fmt.Fprint(w, `{"code":75500300,"message":"fixture token rejected"}`)
				return
			}
			tokenPassed = true
			http.SetCookie(w, &http.Cookie{Name: "sid", Value: "fixture-authenticated-sid", Path: "/", Secure: true, HttpOnly: true})
			fmt.Fprint(w, `{"code":0,"data":{"nextService":""}}`)
		case "/passport/v1/user/onlineInfo", "/controller/v1/user/clientResource":
			if !changed || options.totp && !tokenPassed {
				t.Error("password renewal was treated as complete authentication")
			}
			if c, err := r.Cookie("sid"); err != nil || c.Value != "fixture-authenticated-sid" {
				t.Error("missing authenticated cookie")
			}
			if r.URL.Path == "/passport/v1/user/onlineInfo" {
				fmt.Fprintf(w, `{"code":0,"data":{"username":%q}}`, username)
			} else {
				fmt.Fprint(w, `{"code":0,"data":{"appList":{"code":0,"data":{"appInfo":[]}}}}`)
			}
		default:
			t.Errorf("unexpected request: %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	pin := sha256.Sum256(server.Certificate().Raw)
	t.Setenv("SPLITVPN_ATRUST_CERT_SHA256", "")
	var input, output bytes.Buffer
	for _, answer := range answers {
		_ = json.NewEncoder(&input).Encode(answer)
	}
	_ = json.NewEncoder(&input).Encode(command{Type: "end"})
	b := bridge{input: bufio.NewScanner(&input), output: json.NewEncoder(&output)}
	b.run(command{Type: "login", Origin: server.URL, Username: "fixture", Password: fixtureOldPassword, Domain: "local", Fingerprint: hex.EncodeToString(pin[:])})
	for _, secret := range []string{fixtureOldPassword, fixtureNewPassword, "fixture-rejected-password", "fixture-private-ticket", "fixture-ticket", "fixture-csrf", "fixture-pending-sid", nonce, server.URL} {
		if strings.Contains(output.String(), secret) {
			t.Error("private authentication data leaked to stdout")
		}
	}
	var events []event
	decoder := json.NewDecoder(&output)
	for decoder.More() {
		var e event
		if err := decoder.Decode(&e); err != nil {
			t.Fatal(err)
		}
		events = append(events, e)
	}
	return events, changes
}

func passwordAnswer(id string) command {
	return command{Type: "challenge_response", ID: id, OldPassword: fixtureOldPassword, NewPassword: fixtureNewPassword}
}

func TestNativePasswordChangeContinuesLogin(t *testing.T) {
	for _, afterAuthCheck := range []bool{false, true} {
		t.Run(fmt.Sprintf("afterAuthCheck=%t", afterAuthCheck), func(t *testing.T) {
			events, changes := passwordFixture(t, passwordFixtureOptions{afterAuthCheck: afterAuthCheck}, passwordAnswer("challenge-1"))
			var types []string
			for _, e := range events {
				if e.Type == "challenge" && (e.Challenge.Kind != "password_change" || len(e.Challenge.Rules) != 3 || e.Challenge.Username != "fixture") {
					t.Error("missing password policy challenge")
				}
				if e.Type == "password_changed" || e.Type == "login_success" || e.Type == "resources" || e.Type == "error" {
					types = append(types, e.Type)
				}
			}
			if changes != 1 || strings.Join(types, ",") != "password_changed,login_success,resources" {
				t.Fatalf("incorrect continuation: %v, changes=%d", types, changes)
			}
		})
	}
}

func TestNativePasswordChangeRejectionCanBeCorrected(t *testing.T) {
	first := passwordAnswer("challenge-1")
	first.NewPassword = "fixture-rejected-password"
	events, changes := passwordFixture(t, passwordFixtureOptions{rejectFirst: true}, first, passwordAnswer("challenge-2"))
	challenges, confirmations := 0, 0
	for _, e := range events {
		if e.Type == "challenge" {
			challenges++
			if challenges == 2 && (!strings.Contains(e.Challenge.ErrorMessage, "弱密码") || e.Challenge.ID != "challenge-2") {
				t.Error("missing retry error with new challenge identity")
			}
		}
		if e.Type == "password_changed" {
			confirmations++
			if e.ID != "challenge-2" {
				t.Error("a rejected password was accepted")
			}
		}
		if e.Type == "error" {
			t.Errorf("retry failed: %s", e.Message)
		}
	}
	if changes != 2 || challenges != 2 || confirmations != 1 {
		t.Fatal("incorrect password retry sequence")
	}
}

func TestNativePasswordChangeRetainsSecondaryAuthentication(t *testing.T) {
	for _, fails := range []bool{false, true} {
		answer := passwordAnswer("challenge-1")
		answer.NewUsername = "fixture-renamed"
		events, changes := passwordFixture(t, passwordFixtureOptions{totp: true, totpFails: fails, rename: true}, answer,
			command{Type: "challenge_response", ID: "challenge-2", Code: "123456"})
		changed, loggedIn := false, false
		for _, e := range events {
			if e.Type == "password_changed" {
				changed = true
			}
			if e.Type == "login_success" || e.Type == "resources" {
				loggedIn = true
			}
		}
		if changes != 1 || !changed || loggedIn == fails {
			t.Fatal("password change bypassed or lost subsequent authentication")
		}
	}
}

func TestNativePasswordChangeCancellationAndStaleAnswerNeverSubmit(t *testing.T) {
	for _, answer := range []command{{Type: "end"}, passwordAnswer("retired-challenge")} {
		events, changes := passwordFixture(t, passwordFixtureOptions{}, answer)
		if changes != 0 || events[len(events)-1].Type != "error" {
			t.Fatal("cancelled or stale challenge submitted a password change")
		}
	}
}

func TestNativePasswordChangeUnknownOutcomeIsNotRetried(t *testing.T) {
	for _, failure := range []string{"missing-code", "http", "expired", "expired-code", "already-online", "redirect"} {
		t.Run(failure, func(t *testing.T) {
			events, changes := passwordFixture(t, passwordFixtureOptions{failure: failure}, passwordAnswer("challenge-1"), passwordAnswer("challenge-2"))
			last := events[len(events)-1]
			if changes != 1 || last.Type != "error" {
				t.Fatal("unknown or expired reset was retried")
			}
			if failure != "expired" && failure != "expired-code" && last.Code != "password_change_uncertain" {
				t.Error("unknown password outcome must be explicit")
			}
			for _, e := range events {
				if e.Type == "password_changed" || e.Type == "login_success" || e.Type == "resources" {
					t.Error("unconfirmed password change was accepted")
				}
			}
		})
	}
}
