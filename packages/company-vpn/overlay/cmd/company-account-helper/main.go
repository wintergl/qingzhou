// company-account-helper authenticates and exposes an authorized TCP tunnel on
// loopback. System routing remains owned by split-vpn's existing Mihomo core.
package main

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	stdlog "log"
	"net"
	"net/url"
	"os"
	"regexp"
	"strings"
	"sync"

	"github.com/mythologyli/zju-connect/client/atrust/auth"
	"github.com/mythologyli/zju-connect/client/authchallenge"
)

type command struct {
	Type          string                `json:"type"`
	Origin        string                `json:"origin"`
	Username      string                `json:"username"`
	Password      string                `json:"password"`
	OldPassword   string                `json:"oldPassword"`
	NewPassword   string                `json:"newPassword"`
	NewUsername   string                `json:"newUsername"`
	Domain        string                `json:"domain"`
	Fingerprint   string                `json:"fingerprint"`
	ID            string                `json:"id"`
	Code          string                `json:"code"`
	Points        []authchallenge.Point `json:"points"`
	Width         int                   `json:"width"`
	Height        int                   `json:"height"`
	CallbackURL   string                `json:"callbackURL"`
	Target        string                `json:"target"`
	InterfaceName string                `json:"interfaceName"`
}

type event struct {
	Type      string          `json:"type"`
	Stage     string          `json:"stage,omitempty"`
	Message   string          `json:"message,omitempty"`
	Username  string          `json:"username,omitempty"`
	Probe     *probeInfo      `json:"probe,omitempty"`
	Resources *resourceResult `json:"resources,omitempty"`
	Challenge *challenge      `json:"challenge,omitempty"`
	Tunnel    *tunnelInfo     `json:"tunnel,omitempty"`
	Code      string          `json:"code,omitempty"`
	ID        string          `json:"id,omitempty"`
}

type challenge struct {
	ID              string   `json:"id"`
	Kind            string   `json:"kind"`
	Title           string   `json:"title"`
	Message         string   `json:"message"`
	ImageBase64     string   `json:"imageBase64,omitempty"`
	URL             string   `json:"url,omitempty"`
	Username        string   `json:"username,omitempty"`
	RequireUsername bool     `json:"requireUsername,omitempty"`
	Rules           []string `json:"rules,omitempty"`
	ErrorMessage    string   `json:"errorMessage,omitempty"`
}

type bridge struct {
	input        *bufio.Scanner
	output       *json.Encoder
	seq          int
	outputMu     sync.Mutex
	loginSecrets []string
}

func (b *bridge) emit(e event) {
	b.outputMu.Lock()
	defer b.outputMu.Unlock()
	if err := b.output.Encode(e); err != nil {
		os.Exit(0) // The native window has closed; retain no session on disk.
	}
}

func (b *bridge) receive() (command, error) {
	var c command
	if !b.input.Scan() {
		if err := b.input.Err(); err != nil {
			return c, err
		}
		return c, io.EOF
	}
	if err := json.Unmarshal(b.input.Bytes(), &c); err != nil {
		return c, fmt.Errorf("invalid local command")
	}
	return c, nil
}

func (b *bridge) answer(c challenge) (command, error) {
	b.seq++
	c.ID = fmt.Sprintf("challenge-%d", b.seq)
	b.emit(event{Type: "challenge", Stage: "login", Challenge: &c})
	r, err := b.receive()
	if err != nil || r.Type == "end" {
		return command{}, fmt.Errorf("authentication cancelled")
	}
	if r.Type != "challenge_response" || r.ID != c.ID {
		return command{}, fmt.Errorf("invalid local challenge response")
	}
	return r, nil
}

func (b *bridge) handler() authchallenge.Handler {
	return authchallenge.HandlerFuncs{
		Code: func(c authchallenge.CodeChallenge) (authchallenge.CodeResponse, error) {
			title, message := "输入验证码", "输入私有网络认证服务要求的验证码。"
			switch c.Kind {
			case authchallenge.CodeSMS:
				title, message = "短信验证", "输入私有网络认证服务发送的短信验证码。"
			case authchallenge.CodeTOTP:
				title, message = "动态口令", "输入认证器中当前的动态口令。"
			case authchallenge.CodeRadius:
				title, message = "二次认证", "输入私有网络认证服务要求的口令或验证码。"
			}
			r, err := b.answer(challenge{Kind: "code", Title: title, Message: message})
			return authchallenge.CodeResponse{Code: strings.TrimSpace(r.Code)}, err
		},
		TextCaptcha: func(c authchallenge.TextCaptchaChallenge) (authchallenge.TextCaptchaResponse, error) {
			r, err := b.answer(challenge{Kind: "text", Title: "图形验证码", Message: "输入图片中的验证码。", ImageBase64: base64.StdEncoding.EncodeToString(c.Image)})
			return authchallenge.TextCaptchaResponse{Code: strings.TrimSpace(r.Code)}, err
		},
		ClickCaptcha: func(c authchallenge.ClickCaptchaChallenge) (authchallenge.ClickCaptchaResponse, error) {
			r, err := b.answer(challenge{Kind: "click", Title: "点选验证码", Message: "按图片里的提示依次点选，再点击提交。", ImageBase64: base64.StdEncoding.EncodeToString(c.Image)})
			return authchallenge.ClickCaptchaResponse{Points: r.Points, Width: r.Width, Height: r.Height}, err
		},
		ExternalLogin: func(c authchallenge.ExternalLoginChallenge) (authchallenge.ExternalLoginResponse, error) {
			r, err := b.answer(challenge{Kind: "external", Title: "私有网络统一认证", Message: "打开私有网络认证页面，完成后粘贴最终回调地址。", URL: c.LoginURL})
			return authchallenge.ExternalLoginResponse{CallbackURL: strings.TrimSpace(r.CallbackURL)}, err
		},
	}
}

func (b *bridge) HandlePasswordChange(c auth.PasswordChangeChallenge) (auth.PasswordChangeResponse, error) {
	message := "接入网关要求修改密码，完成后会继续本次登录。修改后，其他已在线终端可能需要重新登录。"
	if c.Message != "" {
		message = safeError(errors.New(c.Message), b.loginSecrets...) + " 修改后，其他已在线终端可能需要重新登录。"
	}
	display := challenge{Kind: "password_change", Title: "修改接入密码", Message: message,
		Username: c.Username, RequireUsername: c.RequireUsername}
	for _, rule := range c.Rules {
		display.Rules = append(display.Rules, safeError(errors.New(rule), b.loginSecrets...))
	}
	if c.Error != nil {
		display.ErrorMessage = safeError(c.Error, b.loginSecrets...)
	}
	r, err := b.answer(display)
	if r.OldPassword != "" {
		b.loginSecrets = append(b.loginSecrets, r.OldPassword)
	}
	if r.NewPassword != "" {
		b.loginSecrets = append(b.loginSecrets, r.NewPassword)
	}
	return auth.PasswordChangeResponse{ID: r.ID, OldPassword: r.OldPassword, NewPassword: r.NewPassword, NewUsername: r.NewUsername}, err
}

func (b *bridge) PasswordChanged(r auth.PasswordChangeResponse) {
	b.emit(event{Type: "password_changed", Stage: "login", ID: r.ID, Username: r.NewUsername, Message: "接入密码已修改，正在继续认证…"})
}

func validatedOrigin(raw string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u == nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil ||
		(u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return nil, fmt.Errorf("请输入不含账号信息的 HTTPS 接入地址，例如 https://vpn.example.test")
	}
	u.Path = ""
	return u, nil
}

var businessCode = regexp.MustCompile(`(?:code|HTTP(?: status)?)\s+(\d+)`)
var sensitiveAssignment = regexp.MustCompile(`(?i)(password|passwd|cookie|sid|ticket|token|authorization)\s*[=:]\s*[^\s,;]+`)
var opaqueValue = regexp.MustCompile(`[A-Za-z0-9_+/=-]{36,}`)

// Only selected, short diagnostic text leaves this process, never raw responses.
func safeError(err error, secrets ...string) string {
	if errors.Is(err, auth.ErrPasswordChangeRequired) {
		return "接入网关要求先修改密码。请在官方 aTrust 完成修改并断开私有网络连接，再回轻舟输入新密码登录。"
	}
	if errors.Is(err, auth.ErrPasswordChangeUncertain) {
		return "未能确认接入密码是否已修改。请重新登录并先尝试新密码；如仍无法登录，再通过官方 aTrust 核对。"
	}
	if errors.Is(err, auth.ErrSessionInvalid) {
		return "登录会话已失效，请重新登录。"
	}
	var networkError net.Error
	if errors.As(err, &networkError) && networkError.Timeout() {
		return "接入网关响应超时，请检查接入地址后重试。"
	}
	var requestError *url.Error
	if errors.As(err, &requestError) {
		return safeError(requestError.Err, secrets...)
	}
	m := err.Error()
	for _, secret := range secrets {
		if secret != "" {
			m = strings.ReplaceAll(m, secret, "[已隐藏]")
		}
	}
	m = sensitiveAssignment.ReplaceAllString(m, "$1=[已隐藏]")
	m = opaqueValue.ReplaceAllString(m, "[已隐藏]")
	m = strings.Join(strings.Fields(m), " ")
	if strings.Contains(m, "certificate") || strings.Contains(m, "pin") {
		return "证书核验未通过，请重新检测接入网关并核对证书。"
	}
	if strings.Contains(m, "connection refused") || strings.Contains(m, "no such host") || strings.Contains(m, "network is unreachable") {
		return "无法连接接入网关，请检查地址和当前网络。"
	}
	if match := businessCode.FindStringSubmatch(m); len(match) > 1 {
		if cut := strings.LastIndex(m, ": "); cut >= 0 {
			detail := m[cut+2:]
			// Server messages are useful, but raw JSON/HTML and long values are not.
			if !strings.ContainsAny(detail, "<>{}") && len([]rune(detail)) <= 160 {
				return "接入服务返回错误 " + match[1] + "：" + detail
			}
		}
		return "接入服务返回错误 " + match[1] + "。"
	}
	if len([]rune(m)) > 200 || strings.ContainsAny(m, "<>{}") {
		return "接入服务返回了无法识别的响应，请重试或复制诊断信息。"
	}
	return m
}

func (b *bridge) fetchResources(s *auth.Session) ([]byte, *resourceResult, error) {
	b.emit(event{Type: "progress", Stage: "resources", Message: "正在读取服务器下发的授权资源…"})
	data, err := s.ClientResource()
	if err == nil {
		var result resourceResult
		result, err = parseResources(data)
		if err == nil {
			b.emit(event{Type: "resources", Resources: &result})
			return data, &result, nil
		}
	}
	b.emit(event{Type: "error", Stage: "resources", Message: safeError(err)})
	return nil, nil, err
}

func (b *bridge) run(c command) {
	u, err := validatedOrigin(c.Origin)
	if err != nil {
		b.emit(event{Type: "error", Stage: "probe", Message: err.Error()})
		return
	}
	if c.Type == "probe" {
		b.emit(event{Type: "progress", Stage: "probe", Message: "正在检测接入网关和认证方式…"})
		p, err := probe(u)
		if err != nil {
			b.emit(event{Type: "error", Stage: "probe", Message: safeError(err)})
			return
		}
		b.emit(event{Type: "probe", Probe: &p})
		return
	}
	if (c.Type != "login" && c.Type != "connect") || strings.TrimSpace(c.Username) == "" || c.Password == "" || c.Domain == "" {
		b.emit(event{Type: "error", Stage: "login", Message: "请填写接入账号、密码，并选择认证方式。"})
		return
	}
	pin := strings.ReplaceAll(c.Fingerprint, ":", "")
	if bytes, err := hex.DecodeString(pin); err != nil || len(bytes) != 32 {
		b.emit(event{Type: "error", Stage: "login", Message: "请先检测入口并确认网关证书。"})
		return
	}
	device := make([]byte, 16)
	if _, err := rand.Read(device); err != nil {
		b.emit(event{Type: "error", Stage: "login", Message: "无法生成本次测试的设备标识。"})
		return
	}
	s := auth.NewSession(u.Host, nil)
	s.SetCertificatePin(c.Fingerprint)
	b.loginSecrets = []string{c.Password}
	defer func() { b.loginSecrets = nil }()
	b.emit(event{Type: "progress", Stage: "login", Message: "正在认证接入账号…"})
	result, err := s.Login(auth.PasswordLogin{Username: strings.TrimSpace(c.Username), Password: c.Password, Domain: c.Domain}, auth.LoginOptions{
		DeviceID: hex.EncodeToString(device), ChallengeHandler: b.handler(), PasswordChangeHandler: b,
	})
	if err != nil {
		failure := event{Type: "error", Stage: "login", Message: safeError(err, b.loginSecrets...)}
		if errors.Is(err, auth.ErrPasswordChangeRequired) {
			failure.Code = "password_change_required"
		}
		if errors.Is(err, auth.ErrPasswordChangeUncertain) {
			failure.Code = "password_change_uncertain"
		}
		b.emit(failure)
		return
	}
	c.Password = ""
	b.loginSecrets = nil
	b.emit(event{Type: "login_success", Username: result.Username, Message: "接入账号认证成功。"})
	raw, _, _ := b.fetchResources(s)
	var tunnel *companyTunnel
	defer func() {
		if tunnel != nil {
			tunnel.close()
		}
	}()
	start := func() (*companyTunnel, error) {
		if raw == nil {
			return nil, fmt.Errorf("请先获取有效的接入授权资源。")
		}
		return startCompanyTunnel(s, u, result.Username, hex.EncodeToString(device), c.InterfaceName, raw)
	}
	if c.Type == "connect" {
		b.controlTunnel(c, &tunnel, start)
	}
	for {
		r, err := b.receive()
		if err != nil || r.Type == "end" {
			return
		}
		if r.Type == "refresh_resources" {
			if tunnel != nil {
				b.emit(event{Type: "error", Stage: "resources", Message: "请先断开私有网络隧道，再刷新授权资源。"})
				continue
			}
			raw, _, _ = b.fetchResources(s)
		}
		b.controlTunnel(r, &tunnel, start)
	}
}

// Connecting and disconnecting never inspect or request a business address.
// Verification is an explicit operation on the existing authenticated tunnel.
func (b *bridge) controlTunnel(c command, tunnel **companyTunnel, start func() (*companyTunnel, error)) {
	switch c.Type {
	case "connect":
		if *tunnel == nil {
			b.emit(event{Type: "progress", Stage: "tunnel", Message: "正在建立私有网络 TCP 隧道…"})
			connected, err := start()
			if err != nil {
				b.emit(event{Type: "error", Stage: "tunnel", Message: safeError(err)})
				return
			}
			*tunnel = connected
		}
		b.emit(event{Type: "tunnel_ready", Stage: "tunnel", Tunnel: &(*tunnel).info, Message: "私有网络隧道已连接。"})
	case "verify":
		if *tunnel == nil {
			b.emit(event{Type: "error", Stage: "business", Message: "请先连接私有网络，再验证业务地址。"})
			return
		}
		b.emit(event{Type: "progress", Stage: "business", Message: "正在通过现有私有网络隧道验证业务地址…"})
		info, err := (*tunnel).verify(c.Target)
		if err != nil {
			b.emit(event{Type: "error", Stage: "business", Message: safeError(err)})
			return
		}
		b.emit(event{Type: "tunnel_verified", Stage: "business", Tunnel: &info, Message: "指定业务经私有网络隧道验证通过。"})
	case "disconnect":
		if *tunnel != nil {
			(*tunnel).close()
			*tunnel = nil
		}
		b.emit(event{Type: "tunnel_closed", Message: "私有网络隧道已关闭。"})
	}
}

func main() {
	// Upstream debug output can contain authentication payloads. Disable its log
	// sink entirely; stdout is reserved for the narrow native-app event schema.
	stdlog.SetOutput(io.Discard)
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 2*1024*1024)
	b := bridge{input: scanner, output: json.NewEncoder(os.Stdout)}
	c, err := b.receive()
	if err != nil {
		b.emit(event{Type: "error", Stage: "probe", Message: "应用与认证内核之间的请求无效。"})
		return
	}
	b.run(c)
}
