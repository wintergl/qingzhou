package companymobile

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestControllerCancellationWakesBlockedInputAndKeepsNoExport(t *testing.T) {
	c := NewController()
	c.Close()
	c.Close()
	select {
	case <-c.done:
	case <-time.After(2 * time.Second):
		t.Fatal("cancel did not end reader")
	}
	if !c.Finished() {
		t.Fatal("not finished")
	}
	if _, err := c.ExportSession(); err == nil {
		t.Fatal("closed session exported")
	}
	if c.Send(`{"type":"probe","origin":"https://vpn.example.test"}`) == nil {
		t.Fatal("closed controller accepted input")
	}
	if c.Poll() != "[]" {
		t.Fatal("closed controller retained events")
	}
}
func TestControllerRejectsOversizeAndUnsupportedWithoutNetwork(t *testing.T) {
	c := NewController()
	defer c.Close()
	for _, value := range []string{strings.Repeat("x", maxMessage+1), `{}`, `{"type":"unsafe"}`} {
		if c.Send(value) == nil {
			t.Fatal("invalid command accepted")
		}
	}
	if _, err := c.ExportSession(); err == nil {
		t.Fatal("unauthenticated session exported")
	}
}
func TestTransferRequiresFreshVersionedSessionAndPin(t *testing.T) {
	base := map[string]any{"version": 1, "origin": "https://vpn.example.test", "fingerprint": strings.Repeat("ab", 32), "session": map[string]any{"SID": "fixture-session"}, "resourceData": map[string]any{}, "issuedAt": time.Now().Unix()}
	for _, change := range []map[string]any{{"version": 2}, {"issuedAt": time.Now().Add(-3 * time.Minute).Unix()}, {"issuedAt": time.Now().Add(time.Minute).Unix()}, {"fingerprint": ""}, {"origin": "http://vpn.example.test"}, {"session": map[string]any{}}} {
		data := map[string]any{}
		for k, v := range base {
			data[k] = v
		}
		for k, v := range change {
			data[k] = v
		}
		raw, _ := json.Marshal(data)
		if live, err := newTunnelContext(context.Background(), string(raw), ""); err == nil {
			live.Close()
			t.Fatal("invalid transfer accepted")
		}
	}
}
func TestAttemptInvalidTransferFailsAndCanBeClosedTwice(t *testing.T) {
	a := StartTunnel("{}", "")
	defer a.Close()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if strings.Contains(a.Status(), `"phase":"failed"`) {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if !strings.Contains(a.Status(), `"phase":"failed"`) {
		t.Fatal(a.Status())
	}
	if _, err := a.ExportSession(); err == nil {
		t.Fatal("failed attempt exported")
	}
	if _, err := a.Verify("https://example.test"); err == nil {
		t.Fatal("failed attempt verified")
	}
	a.Close()
	a.Close()
	new(TunnelAttempt).Close()
}
func TestEventSinkBoundsAndOwnsBytes(t *testing.T) {
	c := NewController()
	defer c.Close()
	raw := []byte(`{"type":"fixture"}`)
	if _, err := (eventSink{c}).Write(raw); err != nil {
		t.Fatal(err)
	}
	raw[0] = 'x'
	if !json.Valid([]byte(c.Poll())) {
		t.Fatal("caller mutated retained event")
	}
	if _, err := (eventSink{c}).Write([]byte("invalid")); err == nil {
		t.Fatal("invalid event accepted")
	}
	if _, err := c.ExportSession(); err == nil {
		t.Fatal("bounded event created session")
	}
}
