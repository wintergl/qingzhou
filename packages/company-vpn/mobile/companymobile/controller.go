// Package companymobile embeds the reviewed desktop authentication protocol.
// Session cookies cross the iOS process boundary only via transient IPC.
package companymobile

import (
	"bufio"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/url"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/mythologyli/zju-connect/client/atrust/auth"
)

const maxMessage = 4 * 1024 * 1024

type Controller struct {
	mu         sync.Mutex
	input      *io.PipeWriter
	cancel     context.CancelFunc
	events     []json.RawMessage
	eventBytes int
	export     *sessionTransfer
	closed     bool
	done       chan struct{}
}
type sessionTransfer struct {
	Version     int              `json:"version"`
	Origin      string           `json:"origin"`
	Username    string           `json:"username"`
	Device      string           `json:"device"`
	Fingerprint string           `json:"fingerprint"`
	Session     auth.LoginResult `json:"session"`
	Resources   json.RawMessage  `json:"resourceData"`
	IssuedAt    int64            `json:"issuedAt"`
}
type eventSink struct{ owner *Controller }

func (s eventSink) Write(data []byte) (int, error) {
	c := s.owner
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return 0, io.ErrClosedPipe
	}
	if !json.Valid(data) || len(data) > maxMessage || c.eventBytes+len(data) > maxMessage {
		c.mu.Unlock()
		c.Close()
		return 0, fmt.Errorf("认证事件超过支持大小，已取消")
	}
	c.events = append(c.events, append(json.RawMessage(nil), data...))
	c.eventBytes += len(data)
	c.mu.Unlock()
	return len(data), nil
}
func NewController() *Controller {
	log.SetOutput(io.Discard)
	ctx, cancel := context.WithCancel(context.Background())
	input, writer := io.Pipe()
	c := &Controller{input: writer, cancel: cancel, done: make(chan struct{})}
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), maxMessage)
	b := &bridge{input: scanner, output: json.NewEncoder(eventSink{c}), ctx: ctx, cancel: cancel}
	b.capture = func(s *auth.Session, u *url.URL, username, device string, resources []byte) {
		snapshot, err := s.Snapshot()
		if err != nil {
			return
		}
		c.mu.Lock()
		defer c.mu.Unlock()
		if !c.closed {
			c.export = &sessionTransfer{Version: 1, Origin: u.String(), Username: username, Device: device, Fingerprint: s.CertificatePin(), Session: snapshot, Resources: append(json.RawMessage(nil), resources...)}
		}
	}
	go func() {
		defer close(c.done)
		defer input.Close()
		defer cancel()
		defer func() {
			if recover() != nil {
				_, _ = eventSink{c}.Write([]byte(`{"type":"error","message":"认证内核异常，已结束本次会话"}`))
			}
		}()
		first, err := b.receive()
		if err == nil {
			b.run(first)
		}
	}()
	return c
}
func (c *Controller) Send(line string) error {
	if len(line) > maxMessage {
		return fmt.Errorf("认证请求过大")
	}
	var value command
	if json.Unmarshal([]byte(line), &value) != nil {
		return fmt.Errorf("认证请求格式无效")
	}
	switch value.Type {
	case "probe", "login", "challenge_response", "refresh_resources", "end":
	default:
		return fmt.Errorf("认证请求类型无效")
	}
	if runtime.GOOS == "ios" && (value.Type == "login" || value.Type == "probe") && (value.InterfaceName == "" || strings.HasPrefix(value.InterfaceName, "utun")) {
		return fmt.Errorf("尚未取得可用的物理网络接口")
	}
	c.mu.Lock()
	closed := c.closed
	c.mu.Unlock()
	if closed {
		return io.ErrClosedPipe
	}
	_, err := io.WriteString(c.input, line+"\n")
	return err
}
func (c *Controller) Poll() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	events := c.events
	c.events = nil
	c.eventBytes = 0
	if events == nil {
		return "[]"
	}
	data, _ := json.Marshal(events)
	return string(data)
}
func (c *Controller) ExportSession() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.export == nil {
		return "", fmt.Errorf("请先完成认证并获取授权资源")
	}
	snapshot := *c.export
	snapshot.IssuedAt = time.Now().Unix()
	data, err := json.Marshal(snapshot)
	if err != nil || len(data) > maxMessage {
		return "", fmt.Errorf("授权会话超过支持大小")
	}
	return string(data), nil
}
func (c *Controller) Close() {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	c.export = nil
	c.events = nil
	c.eventBytes = 0
	c.mu.Unlock()
	c.cancel()
	_ = c.input.CloseWithError(context.Canceled)
}
func (c *Controller) Finished() bool {
	select {
	case <-c.done:
		return true
	default:
		return false
	}
}

type Tunnel struct {
	mu       sync.Mutex
	verifyMu sync.Mutex
	tunnel   *companyTunnel
	transfer sessionTransfer
}

func NewTunnel(transferJSON, interfaceName string) (*Tunnel, error) {
	return newTunnelContext(context.Background(), transferJSON, interfaceName)
}
func newTunnelContext(ctx context.Context, transferJSON, interfaceName string) (*Tunnel, error) {
	log.SetOutput(io.Discard)
	if len(transferJSON) > maxMessage {
		return nil, fmt.Errorf("会话过大")
	}
	var data sessionTransfer
	if json.Unmarshal([]byte(transferJSON), &data) != nil || data.Version != 1 || data.Session.SID == "" || len(data.Resources) == 0 || time.Now().Unix()-data.IssuedAt > 120 || data.IssuedAt > time.Now().Unix()+5 {
		return nil, fmt.Errorf("认证会话无效或已过期，请重新登录")
	}
	u, err := validatedOrigin(data.Origin)
	if err != nil {
		return nil, err
	}
	pin, err := hex.DecodeString(strings.ReplaceAll(data.Fingerprint, ":", ""))
	if err != nil || len(pin) != 32 {
		return nil, fmt.Errorf("缺少已确认的证书指纹")
	}
	if runtime.GOOS == "ios" && (interfaceName == "" || strings.HasPrefix(interfaceName, "utun")) {
		return nil, fmt.Errorf("缺少物理网络接口，未建立隧道")
	}
	s := auth.NewSession(u.Host, nil)
	s.SetCertificatePin(data.Fingerprint)
	s.Restore(data.Device, data.Session.SID, data.Session.Cookies)
	tunnel, err := startCompanyTunnelContext(ctx, s, u, data.Username, data.Device, interfaceName, data.Resources)
	if err != nil {
		return nil, errors.New("接入建立失败，请检查网关、证书与授权资源")
	}
	return &Tunnel{tunnel: tunnel, transfer: data}, nil
}
func (t *Tunnel) healthy() bool {
	t.mu.Lock()
	live := t.tunnel
	t.mu.Unlock()
	if live == nil {
		return false
	}
	_, err := live.client.CompanySnapshot()
	return err == nil
}
func (t *Tunnel) Port() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.tunnel == nil {
		return 0
	}
	return t.tunnel.info.Port
}
func (t *Tunnel) Verify(target string) (string, error) {
	t.verifyMu.Lock()
	defer t.verifyMu.Unlock()
	t.mu.Lock()
	live := t.tunnel
	t.mu.Unlock()
	if live == nil {
		return "", fmt.Errorf("隧道已关闭")
	}
	info, err := live.verify(target)
	if err != nil {
		return "", errors.New(safeError(err))
	}
	data, _ := json.Marshal(info)
	return string(data), nil
}
func (t *Tunnel) Close() {
	t.mu.Lock()
	live := t.tunnel
	t.tunnel = nil
	t.mu.Unlock()
	if live != nil {
		live.close()
	}
}

// An attempt can be canceled while Setup is still waiting on the network.
type TunnelAttempt struct {
	mu      sync.Mutex
	cancel  context.CancelFunc
	live    *Tunnel
	phase   string
	message string
}

func StartTunnel(transferJSON, interfaceName string) *TunnelAttempt {
	ctx, cancel := context.WithCancel(context.Background())
	a := &TunnelAttempt{cancel: cancel, phase: "starting"}
	go func() {
		defer func() {
			if recover() != nil {
				a.mu.Lock()
				a.phase = "failed"
				a.message = "接入内核异常，请重新认证"
				a.mu.Unlock()
				cancel()
			}
		}()
		live, err := newTunnelContext(ctx, transferJSON, interfaceName)
		a.mu.Lock()
		if ctx.Err() != nil {
			a.phase = "cancelled"
			a.mu.Unlock()
			if live != nil {
				live.Close()
			}
			return
		}
		if err != nil {
			a.phase = "failed"
			a.message = safeError(err)
		} else {
			a.phase = "ready"
			a.live = live
		}
		a.mu.Unlock()
	}()
	return a
}
func (a *TunnelAttempt) Status() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	port := 0
	if a.live != nil {
		port = a.live.Port()
		if !a.live.healthy() {
			a.phase = "failed"
			a.message = "接入会话已失效，请重新登录"
			port = 0
		}
	}
	data, _ := json.Marshal(map[string]any{"phase": a.phase, "port": port, "error": a.message})
	return string(data)
}
func (a *TunnelAttempt) Verify(target string) (string, error) {
	a.mu.Lock()
	live := a.live
	a.mu.Unlock()
	if live == nil {
		return "", fmt.Errorf("隧道尚未就绪")
	}
	return live.Verify(target)
}
func (a *TunnelAttempt) Close() {
	if a.cancel != nil {
		a.cancel()
	}
	a.mu.Lock()
	live := a.live
	a.live = nil
	a.phase = "cancelled"
	a.mu.Unlock()
	if live != nil {
		live.Close()
	}
}

func (t *Tunnel) ExportSession() (string, error) {
	t.mu.Lock()
	live := t.tunnel
	data := t.transfer
	t.mu.Unlock()
	if live == nil {
		return "", fmt.Errorf("隧道已关闭")
	}
	snapshot, err := live.client.CompanySnapshot()
	if err != nil {
		return "", fmt.Errorf("会话失效，请重新登录")
	}
	data.Session = snapshot
	data.IssuedAt = time.Now().Unix()
	raw, err := json.Marshal(data)
	if err != nil {
		return "", fmt.Errorf("会话导出失败")
	}
	return string(raw), nil
}
func (a *TunnelAttempt) ExportSession() (string, error) {
	a.mu.Lock()
	live := a.live
	a.mu.Unlock()
	if live == nil {
		return "", fmt.Errorf("隧道尚未就绪")
	}
	return live.ExportSession()
}
