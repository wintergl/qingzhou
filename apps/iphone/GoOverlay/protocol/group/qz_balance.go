package group

import (
	"context"
	"errors"
	"hash/fnv"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/service"
)

// The stock mobile engine has no load-balance group. This small group keeps a
// stable destination on one member and cools failed members without a scanner.
func RegisterQZBalance(registry *outbound.Registry) {
	outbound.Register[option.SelectorOutboundOptions](registry, "qz-load-balance", newQZBalance)
}

type qzBalance struct {
	outbound.Adapter
	manager  adapter.OutboundManager
	tags     []string
	members  []adapter.Outbound
	mu       sync.Mutex
	failed   map[string]time.Time
	selected atomic.Pointer[balanceSelection]
	now      func() time.Time
}
type balanceSelection struct{ tag string }

func newQZBalance(ctx context.Context, _ adapter.Router, _ log.ContextLogger, tag string, options option.SelectorOutboundOptions) (adapter.Outbound, error) {
	if len(options.Outbounds) == 0 {
		return nil, errors.New("负载均衡没有可用节点")
	}
	return &qzBalance{Adapter: outbound.NewAdapter("qz-load-balance", tag, nil, options.Outbounds), manager: service.FromContext[adapter.OutboundManager](ctx), tags: options.Outbounds, failed: make(map[string]time.Time), now: time.Now}, nil
}
func (b *qzBalance) Start() error {
	for _, tag := range b.tags {
		member, ok := b.manager.Outbound(tag)
		if !ok {
			return errors.New("负载均衡节点已失效")
		}
		b.members = append(b.members, member)
	}
	return nil
}
func (b *qzBalance) All() []string { return append([]string(nil), b.tags...) }
func (b *qzBalance) Now() string {
	if selected := b.selected.Load(); selected != nil {
		return selected.tag
	}
	if len(b.tags) > 0 {
		return b.tags[0]
	}
	return ""
}
func (b *qzBalance) Network() []string {
	var result []string
	for _, network := range []string{N.NetworkTCP, N.NetworkUDP} {
		for _, member := range b.members {
			if supports(member, network) {
				result = append(result, network)
				break
			}
		}
	}
	return result
}
func supports(outbound adapter.Outbound, network string) bool {
	for _, supported := range outbound.Network() {
		if supported == network {
			return true
		}
	}
	return false
}
func (b *qzBalance) candidates(network string, destination M.Socksaddr) []adapter.Outbound {
	if len(b.members) == 0 {
		return nil
	}
	hash := fnv.New64a()
	_, _ = hash.Write([]byte(destination.AddrString()))
	first := int(hash.Sum64() % uint64(len(b.members)))
	b.mu.Lock()
	defer b.mu.Unlock()
	var ready, cooling []adapter.Outbound
	for i := 0; i < len(b.members); i++ {
		member := b.members[(first+i)%len(b.members)]
		if !supports(member, network) {
			continue
		}
		if b.failed[member.Tag()].After(b.now()) {
			cooling = append(cooling, member)
		} else {
			ready = append(ready, member)
		}
	}
	if len(ready) > 0 {
		return ready
	}
	return cooling
}
func (b *qzBalance) observed(member adapter.Outbound, err error) {
	b.mu.Lock()
	if err != nil {
		b.failed[member.Tag()] = b.now().Add(30 * time.Second)
	} else {
		delete(b.failed, member.Tag())
		b.selected.Store(&balanceSelection{member.Tag()})
	}
	b.mu.Unlock()
}
func (b *qzBalance) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	var last error
	for _, member := range b.candidates(network, destination) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		probe, done := context.WithTimeout(ctx, 3*time.Second)
		conn, err := member.DialContext(probe, network, destination)
		done()
		b.observed(member, err)
		if err == nil {
			return conn, nil
		}
		last = err
	}
	if last == nil {
		last = errors.New("没有支持该网络协议的负载均衡节点")
	}
	return nil, last
}
func (b *qzBalance) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	var last error
	for _, member := range b.candidates(N.NetworkUDP, destination) {
		conn, err := member.ListenPacket(ctx, destination)
		b.observed(member, err)
		if err == nil {
			return conn, nil
		}
		last = err
	}
	if last == nil {
		last = errors.New("节点不支持 UDP")
	}
	return nil, last
}
