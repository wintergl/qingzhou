package main

import (
    "context"
    "encoding/json"
    "fmt"
    "io"
    "net"
    "net/http"
    "net/url"
    "strconv"
    "strings"
    "sync"
    "sync/atomic"
    "time"

    "github.com/mythologyli/zju-connect/client"
    "github.com/mythologyli/zju-connect/client/atrust"
    "github.com/mythologyli/zju-connect/client/atrust/auth"
    "github.com/mythologyli/zju-connect/resolve"
    "github.com/mythologyli/zju-connect/underlay"
    socks5 "github.com/things-go/go-socks5"
    "golang.org/x/net/proxy"
)

type tunnelInfo struct {
    Port int `json:"port"`
    Target string `json:"target"`
    HTTPStatus int `json:"httpStatus"`
    ElapsedMS int64 `json:"elapsedMs"`
    Sent int64 `json:"sent"`
    Received int64 `json:"received"`
    VerifiedAt string `json:"verifiedAt"`
    Transport string `json:"transport"`
}
type companyTunnel struct {
    info tunnelInfo
    listener net.Listener
    client *atrust.Client
    underlay *underlay.Dialer
    sent atomic.Int64
    received atomic.Int64
    active sync.Map
    once sync.Once
}

func validatedTarget(raw string) (*url.URL, error) {
    raw = strings.TrimSpace(raw)
    if !strings.Contains(raw, "://") { raw = "http://" + raw }
    u, err := url.Parse(raw)
    if err != nil || u.Hostname() == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
        return nil, fmt.Errorf("请输入不含账号或令牌的 HTTP/HTTPS 业务地址。")
    }
    if u.Path == "" { u.Path = "/" }
    return u, nil
}

func startCompanyTunnel(session *auth.Session, origin *url.URL, username, device, interfaceName string, resources []byte) (*companyTunnel, error) {
    snapshot, err := session.Snapshot()
    if err != nil { return nil, err }
    dialer, err := underlay.New(underlay.Options{InterfaceName: interfaceName, AutoDetect: interfaceName == ""})
    if err != nil { return nil, err }
    t := &companyTunnel{underlay: dialer}
    t.client = atrust.NewClient(atrust.ClientOptions{UnderlayDialer: dialer,
        Session: atrust.SessionOptions{Username: username, SID: snapshot.SID, DeviceID: device}})
    clientData, _ := json.Marshal(auth.ClientAuthData{DeviceID: device, Cookies: snapshot.Cookies})
    port := 443
    if origin.Port() != "" { port, err = strconv.Atoi(origin.Port()); if err != nil { t.close(); return nil, err } }
    _, err = t.client.Setup(atrust.SetupOptions{SkipL3: true, ServerAddress: origin.Hostname(), ServerPort: port,
        ClientData: clientData, ResourceData: resources, SessionRefreshInterval: time.Minute, BestNodesRefreshInterval: 2*time.Minute})
    if err != nil { t.close(); return nil, err }
    listener, err := net.Listen("tcp4", "127.0.0.1:0")
    if err != nil { t.close(); return nil, err }
    t.listener = listener
    resolver := &companyResolver{client: t.client}
    server := socks5.NewServer(socks5.WithResolver(resolver), socks5.WithRule(&socks5.PermitCommand{EnableConnect: true}), socks5.WithDial(t.dial))
    go func() { _ = server.Serve(listener) }()
    t.info.Port = listener.Addr().(*net.TCPAddr).Port
    t.info.Transport = "atrust-tcp"
    return t, nil
}

// Revalidation uses the same authenticated client and SOCKS listener. A single
// failed request must not tear down other applications' company connections.
func (t *companyTunnel) verify(target string) (tunnelInfo, error) {
    u, err := validatedTarget(target)
    if err != nil { return tunnelInfo{}, err }
    beforeSent, beforeReceived := t.sent.Load(), t.received.Load()
    // This transport only dials our company SOCKS listener. It never consults
    // HTTP_PROXY or falls back to direct LAN access, even while in the office.
    status, elapsed, err := verifyThroughSOCKS(t.info.Port, u)
    if err != nil { return tunnelInfo{}, err }
    sent, received := t.sent.Load(), t.received.Load()
    if sent <= beforeSent || received <= beforeReceived { return tunnelInfo{}, fmt.Errorf("业务请求没有产生私有网络隧道流量，验收未通过。") }
    t.info.Target = u.String()
    t.info.HTTPStatus, t.info.ElapsedMS = status, elapsed
    t.info.Sent, t.info.Received = sent, received
    t.info.VerifiedAt, t.info.Transport = time.Now().Format(time.RFC3339), "atrust-tcp"
    return t.info, nil
}

func verifyThroughSOCKS(port int, target *url.URL) (int, int64, error) {
    dialer, err := proxy.SOCKS5("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), nil, &net.Dialer{Timeout: 20*time.Second})
    if err != nil { return 0, 0, err }
    contextDialer, ok := dialer.(proxy.ContextDialer)
    if !ok { return 0, 0, fmt.Errorf("私有网络代理不支持可取消的连接。") }
    transport := &http.Transport{Proxy: nil, DialContext: contextDialer.DialContext, TLSHandshakeTimeout: 15*time.Second,
        ResponseHeaderTimeout: 20*time.Second, DisableKeepAlives: true}
    defer transport.CloseIdleConnections()
    hc := &http.Client{Transport: transport, Timeout: 35*time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
    begin := time.Now()
    response, err := hc.Get(target.String())
    if err != nil { return 0, time.Since(begin).Milliseconds(), err }
    defer response.Body.Close()
    _, err = io.Copy(io.Discard, io.LimitReader(response.Body, 256*1024))
    if err != nil { return response.StatusCode, time.Since(begin).Milliseconds(), err }
    if response.StatusCode < 200 || response.StatusCode >= 400 { return response.StatusCode, time.Since(begin).Milliseconds(), fmt.Errorf("指定业务经私有网络隧道返回 HTTP %d，业务验收未通过。", response.StatusCode) }
    return response.StatusCode, time.Since(begin).Milliseconds(), nil
}

func (t *companyTunnel) dial(ctx context.Context, network, address string) (net.Conn, error) {
    if network != "tcp" && network != "tcp4" { return nil, fmt.Errorf("当前私有网络连接仅支持 TCP。") }
    host, rawPort, err := net.SplitHostPort(address)
    if err != nil { return nil, err }
    port, err := strconv.Atoi(rawPort)
    if err != nil { return nil, err }
    if resources, ok := ctx.Value(companyDomainKey{}).([]client.DomainResource); ok {
        resource, found := client.MatchDomainResource(resources, "tcp", port)
        if !found { return nil, fmt.Errorf("接入网关未授权该域名的 TCP 端口。") }
        ctx = context.WithValue(ctx, resolve.ContextKeyDomainResource, resource)
    }
    ip := net.ParseIP(host)
    if ip == nil { return nil, fmt.Errorf("私有网络 DNS 未返回可用地址。") }
    connection, err := t.client.DialTCP(ctx, &net.TCPAddr{IP: ip, Port: port})
    if err != nil { return nil, err } // Never direct fallback.
    counted := &countedConn{Conn: connection, owner: t}
    t.active.Store(counted, true)
    return counted, nil
}
func (t *companyTunnel) close() {
    t.once.Do(func() {
        if t.listener != nil { _ = t.listener.Close() }
        t.active.Range(func(key, value any) bool { _ = key.(*countedConn).Close(); return true })
        if t.client != nil { t.client.Close() }
        if t.underlay != nil { _ = t.underlay.Close() }
    })
}
type countedConn struct { net.Conn; owner *companyTunnel }
func (c *countedConn) Read(p []byte) (int, error) { n, err := c.Conn.Read(p); c.owner.received.Add(int64(n)); return n, err }
func (c *countedConn) Write(p []byte) (int, error) { n, err := c.Conn.Write(p); c.owner.sent.Add(int64(n)); return n, err }
func (c *countedConn) Close() error { c.owner.active.Delete(c); return c.Conn.Close() }
func (c *countedConn) CloseWrite() error { if half, ok := c.Conn.(interface{ CloseWrite() error }); ok { return half.CloseWrite() }; return nil }
type companyDomainKey struct{}
type companyResolver struct { client *atrust.Client }
func (r *companyResolver) Resolve(ctx context.Context, name string) (context.Context, net.IP, error) {
    name = strings.ToLower(strings.TrimSuffix(name, "."))
    domains, _ := r.client.DomainResources()
    var resources []client.DomainResource
    longest := -1
    for domain, entries := range domains {
        suffix := strings.TrimPrefix(strings.ToLower(domain), "*.")
        if (name == suffix || strings.HasSuffix(name, "."+suffix)) && len(suffix) > longest { resources = entries; longest = len(suffix) }
    }
    if len(resources) > 0 {
        ctx = context.WithValue(ctx, companyDomainKey{}, resources)
        ctx = context.WithValue(ctx, resolve.ContextKeyResolveHost, name)
    }
    static, _ := r.client.DNSResource()
    if ips := static[name]; len(ips) > 0 { return ctx, ips[0], nil }
    // AddrPretend explicitly authorizes forwarding the hostname to the gateway.
    // The placeholder never leaves the tunnel as a destination IP in this mode.
    allPretend := len(resources) > 0
    for _, entry := range resources { allPretend = allPretend && entry.AddrPretend }
    if allPretend { return ctx, net.IPv4(198,19,255,254), nil }
    servers, _ := r.client.DNSServers()
    for _, server := range servers {
        ip := net.ParseIP(server)
        if ip == nil { continue }
        resolver := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
            return r.client.DialTCP(ctx, &net.TCPAddr{IP: ip, Port: 53})
        }}
        ips, err := resolver.LookupIP(ctx, "ip4", name)
        if err == nil && len(ips) > 0 { return ctx, ips[0], nil }
    }
    return ctx, nil, fmt.Errorf("接入网关未提供可用的授权 DNS；该域名不能通过当前私有网络连接解析。")
}
