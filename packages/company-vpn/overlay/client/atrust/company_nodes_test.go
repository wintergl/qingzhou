package atrust

import (
	"reflect"
	"testing"
)

func TestCompanyNodeProbeFailureKeepsLastAuthorizedOutlet(t *testing.T) {
	groups := map[string]NodeGroup{"main": {WAN: []string{"node-a:441", "node-b:441"}}, "office": {LAN: []string{"lan:441"}}}
	previous := map[string]string{"main": "node-a:441", "office": "lan:441"}
	got := companyReachableNodes(groups, previous, map[string]string{})
	if !reflect.DeepEqual(got, previous) { t.Fatalf("temporary probe failure erased the working outlets: %v", got) }
	got["main"] = "changed"
	if previous["main"] != "node-a:441" { t.Fatal("mutated the previous live node map") }
}

func TestCompanyNodeRefreshAdoptsAReachableReplacementPerGroup(t *testing.T) {
	groups := map[string]NodeGroup{"main": {WAN: []string{"node-a:441", "node-b:441"}}, "office": {LAN: []string{"lan:441"}}}
	got := companyReachableNodes(groups, map[string]string{"main": "node-a:441", "office": "lan:441"}, map[string]string{"main": "node-b:441"})
	if got["main"] != "node-b:441" || got["office"] != "lan:441" { t.Fatalf("bad partial refresh: %v", got) }
}

func TestCompanyNodeRefreshDoesNotKeepRevokedNodesOrGroups(t *testing.T) {
	groups := map[string]NodeGroup{"main": {WAN: []string{"node-b:441"}}}
	got := companyReachableNodes(groups, map[string]string{"main": "old:441", "revoked": "lan:441"}, nil)
	if len(got) != 0 { t.Fatalf("kept nodes no longer in the server grant: %v", got) }
}
