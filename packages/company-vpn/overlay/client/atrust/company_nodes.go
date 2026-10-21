package atrust

// Probe failures describe this probe, not revocation of a server's resource
// grant. Keep a previously working node only while it is still in the grant.
// This is used exclusively by the company's TCP mode, without an L3 tunnel.
func companyReachableNodes(groups map[string]NodeGroup, previous, probed map[string]string) map[string]string {
	result := make(map[string]string, len(groups))
	for group, nodes := range groups {
		if node := probed[group]; node != "" {
			result[group] = node
			continue
		}
		old := previous[group]
		if old == "" { continue }
		for _, node := range append(append([]string(nil), nodes.WAN...), nodes.LAN...) {
			if node == old { result[group] = old; break }
		}
	}
	return result
}
