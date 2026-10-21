package auth

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"unicode/utf16"
)

var ErrPasswordChangeRequired = errors.New("aTrust requires a password change")
var ErrPasswordChangeUncertain = errors.New("aTrust password change outcome is unknown")

// Only these display fields leave the authentication process. Passwords are
// requested over stdin and never included in challenges or diagnostic events.
type PasswordChangeChallenge struct {
	Username        string
	RequireUsername bool
	Message         string
	Rules           []string
	Error           error
}

type PasswordChangeResponse struct {
	ID          string
	OldPassword string
	NewPassword string
	NewUsername string
}

type PasswordChangeHandler interface {
	HandlePasswordChange(PasswordChangeChallenge) (PasswordChangeResponse, error)
	PasswordChanged(PasswordChangeResponse)
}

// Embed this in both the first password response and subsequent auth steps:
// gateways can require renewal at either point in the authentication chain.
type passwordChangeData struct {
	ModifyPwdCode    int             `json:"modifyPwdCode"`
	ModifyPwdMessage string          `json:"modifyPwdMessage"`
	PwdRulePrompt    string          `json:"pwdRulePrompt"`
	Username         string          `json:"username"`
	Domain           string          `json:"domain"`
	PswStrategy      json.RawMessage `json:"pswStrategy"`
}

func (d passwordChangeData) rules() []string {
	if d.PwdRulePrompt != "" {
		return []string{d.PwdRulePrompt}
	}
	if d.Domain != "" && d.Domain != "local" {
		return nil
	}
	var policy map[string]json.RawMessage
	if json.Unmarshal(d.PswStrategy, &policy) != nil {
		return nil
	}
	var rules []string
	flag := func(raw json.RawMessage) bool {
		return string(raw) == "true" || string(raw) == "1"
	}
	rule := func(key string) (bool, int) {
		var v struct {
			Enable json.RawMessage
			Value  int
		}
		_ = json.Unmarshal(policy[key], &v)
		return flag(v.Enable), v.Value
	}
	if enabled, length := rule("enablePswLength"); enabled && length > 0 {
		rules = append(rules, fmt.Sprintf("密码至少 %d 位。", length))
	}
	var combination struct {
		Enable json.RawMessage
		Value  map[string]json.RawMessage
	}
	_ = json.Unmarshal(policy["enablePswCombination"], &combination)
	if flag(combination.Enable) {
		if flag(combination.Value["enableUpperAndLowerLetter"]) {
			rules = append(rules, "需同时包含大写和小写字母。")
		} else if flag(combination.Value["enableAllLetter"]) {
			rules = append(rules, "需包含字母。")
		}
		if flag(combination.Value["enableNumber"]) {
			rules = append(rules, "需包含数字。")
		}
		if flag(combination.Value["enableSpecialLetter"]) {
			rules = append(rules, "需包含特殊字符。")
		}
	}
	if flag(policy["enablePswNotContainName"]) {
		rules = append(rules, "密码不能包含账号名。")
	}
	if enabled, count := rule("notContainContChar"); enabled && count > 0 {
		rules = append(rules, fmt.Sprintf("不能包含 %d 位连续重复字符。", count))
	}
	if enabled, _ := rule("notContainKeyboardContChar"); enabled {
		rules = append(rules, "不能包含键盘连续字符或常规连续字符（如 qwe、123、abc）。")
	}
	if enabled, count := rule("enablePswNotEqualHistory"); enabled && count > 0 {
		rules = append(rules, fmt.Sprintf("不能与最近 %d 次使用的密码重复。", count))
	}
	return rules
}

func (s *Session) completePasswordChange(step authStep) (authStep, error) {
	if s.passwordChangeHandler == nil {
		return authStep{}, ErrPasswordChangeRequired
	}
	info := step.PasswordChange
	// authCheck on some versions only names the next service; retain the
	// policy supplied by the original password response in that case.
	if info.ModifyPwdCode == 0 {
		info.ModifyPwdCode = s.passwordChangeInfo.ModifyPwdCode
	}
	if info.ModifyPwdMessage == "" {
		info.ModifyPwdMessage = s.passwordChangeInfo.ModifyPwdMessage
	}
	if info.PwdRulePrompt == "" {
		info.PwdRulePrompt = s.passwordChangeInfo.PwdRulePrompt
	}
	if len(info.PswStrategy) == 0 {
		info.PswStrategy = s.passwordChangeInfo.PswStrategy
	}
	username, domain := s.username, ""
	if at := strings.LastIndex(s.username, "@"); at >= 0 {
		username, domain = s.username[:at], s.username[at+1:]
	}
	if info.Username != "" {
		username = info.Username
	}
	if info.Domain == "" {
		info.Domain = domain
	}
	c := PasswordChangeChallenge{Username: username, Message: info.ModifyPwdMessage, Rules: info.rules(),
		RequireUsername: info.ModifyPwdCode == 75500402 || info.ModifyPwdCode == 75500404}
	for {
		answer, err := s.passwordChangeHandler.HandlePasswordChange(c)
		if err != nil {
			return authStep{}, err
		}
		answer.NewUsername = strings.TrimSpace(answer.NewUsername)
		if answer.NewUsername == "" && !c.RequireUsername {
			answer.NewUsername = username
		}
		if answer.OldPassword == "" || answer.NewPassword == "" || answer.NewUsername == "" {
			c.Error = errors.New("请填写旧密码、新密码和账号名。")
			continue
		}
		if answer.NewPassword == answer.OldPassword {
			c.Error = errors.New("新密码不能与旧密码相同。")
			continue
		}
		if len(utf16.Encode([]rune(answer.NewPassword))) > 128 || len(utf16.Encode([]rune(answer.OldPassword))) > 128 ||
			len(utf16.Encode([]rune(answer.NewUsername))) > 128 {
			c.Error = errors.New("账号名和密码不能超过 128 个字符。")
			continue
		}
		next, rejected, err := s.modifyPassword(answer)
		if err != nil {
			return authStep{}, err
		}
		if rejected != nil {
			// A known business rejection is safe to retry after the user edits
			// the form. A transport failure is never retried automatically.
			c.Error = rejected
			continue
		}
		s.username = answer.NewUsername + "@" + domain
		s.passwordChangeHandler.PasswordChanged(answer)
		return next, nil
	}
}

// aTrust's login-time reset endpoint uses a form, unlike /auth/psw's JSON.
// Both password values are RSA PKCS#1 v1.5 hex of <password>_<antiReplayRand>.
func (s *Session) modifyPassword(answer PasswordChangeResponse) (authStep, error, error) {
	oldPassword, err := s.encryptChallengeResponse(answer.OldPassword)
	if err != nil {
		return authStep{}, nil, err
	}
	newPassword, err := s.encryptChallengeResponse(answer.NewPassword)
	if err != nil {
		return authStep{}, nil, err
	}
	form := url.Values{"oldPassword": {oldPassword}, "newPassword": {newPassword}, "newUserName": {answer.NewUsername}}
	req, err := http.NewRequest(http.MethodPost, s.baseURL+"/passport/v1/auth/modifyPwd?"+WithSharedParams(nil).Encode(), strings.NewReader(form.Encode()))
	if err != nil {
		return authStep{}, nil, err
	}
	req.Header.Set("User-Agent", UserAgent)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("x-csrf-token", s.csrfToken)
	req.Header.Set("x-sdp-env", s.env)
	req.Header.Set("x-sdp-rid", s.rid)
	req.Header.Set("x-sdp-traceid", s.randSdpId())
	// Never follow a redirect and mistake an authConfig/login response for a
	// successful password change. The jar and pinned transport remain shared.
	client := *s.client
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := client.Do(req)
	if err != nil {
		return authStep{}, nil, ErrPasswordChangeUncertain
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return authStep{}, nil, ErrSessionInvalid
	}
	if resp.StatusCode != http.StatusOK {
		return authStep{}, nil, ErrPasswordChangeUncertain
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1024*1024+1))
	if err != nil || len(body) > 1024*1024 {
		return authStep{}, nil, ErrPasswordChangeUncertain
	}
	var result struct {
		Code    *int   `json:"code"`
		Message string `json:"message"`
		Data    struct {
			authStepData
			Ticket    string `json:"ticket"`
			CsrfToken string `json:"csrfToken"`
		} `json:"data"`
	}
	if json.Unmarshal(body, &result) != nil || result.Code == nil {
		return authStep{}, nil, ErrPasswordChangeUncertain
	}
	if result.Data.AntiReplayRand != "" {
		s.antiReplayRand = result.Data.AntiReplayRand
	}
	switch *result.Code {
	case 10000004, 10000008, 75500001, 75500002, 75500011:
		return authStep{}, nil, ErrSessionInvalid
	case 75500006: // Already online does not confirm that this reset was applied.
		return authStep{}, nil, ErrPasswordChangeUncertain
	}
	if *result.Code != 0 {
		return authStep{}, fmt.Errorf("password change failed with code %d: %s", *result.Code, result.Message), nil
	}
	if result.Data.Ticket != "" {
		s.ticket = result.Data.Ticket
	}
	if result.Data.CsrfToken != "" {
		s.csrfToken = result.Data.CsrfToken
	}
	next := authStepFromData(result.Data.authStepData)
	if next.Service == "" {
		next.Service = "auth/authCheck"
	}
	return next, nil, nil
}
