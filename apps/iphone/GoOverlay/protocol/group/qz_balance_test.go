package group

import (
	"context"
	"errors"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	M "github.com/sagernet/sing/common/metadata"
	"net"
	"testing"
	"time"
)

type balanceFake struct {
	outbound.Adapter
	fail  bool
	calls int
}

func (f *balanceFake) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	f.calls++
	if f.fail {
		return nil, errors.New("fixture failure")
	}
	a, b := net.Pipe()
	_ = b.Close()
	return a, nil
}
func (f *balanceFake) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, errors.New("no UDP")
}
func TestQZBalanceStableDistributionAndFailover(t *testing.T) {
	a := &balanceFake{Adapter: outbound.NewAdapter("fake", "one", []string{"tcp"}, nil)}
	b := &balanceFake{Adapter: outbound.NewAdapter("fake", "two", []string{"tcp"}, nil)}
	group := &qzBalance{tags: []string{"one", "two"}, members: []adapter.Outbound{a, b}, failed: map[string]time.Time{}, now: time.Now}
	for i := 0; i < 20; i++ {
		c, err := group.DialContext(context.Background(), "tcp", M.ParseSocksaddr("stable.example.test:443"))
		if err != nil {
			t.Fatal(err)
		}
		c.Close()
	}
	if a.calls != 20 && b.calls != 20 {
		t.Fatal("same destination moved between nodes")
	}
	a.calls = 0
	b.calls = 0
	for _, host := range []string{"a.example.test:443", "b.example.test:443", "c.example.test:443", "d.example.test:443"} {
		c, err := group.DialContext(context.Background(), "tcp", M.ParseSocksaddr(host))
		if err != nil {
			t.Fatal(err)
		}
		c.Close()
	}
	if a.calls == 0 || b.calls == 0 {
		t.Fatal("did not distribute destinations")
	}
	a.fail = true
	for _, host := range []string{"a.example.test:443", "b.example.test:443"} {
		c, err := group.DialContext(context.Background(), "tcp", M.ParseSocksaddr(host))
		if err != nil {
			t.Fatal(err)
		}
		c.Close()
	}
	if group.Now() != "two" {
		t.Fatal("failed member did not fail over")
	}
	if _, err := group.ListenPacket(context.Background(), M.ParseSocksaddr("a.example.test:53")); err == nil {
		t.Fatal("unsupported UDP was accepted")
	}
	b.fail = true
	if _, err := group.DialContext(context.Background(), "tcp", M.ParseSocksaddr("a.example.test:443")); err == nil {
		t.Fatal("all failed members fell back to direct")
	}
}
