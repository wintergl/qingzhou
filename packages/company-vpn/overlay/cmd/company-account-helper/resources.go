package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"
)

type resourceRow struct {
	ID          string `json:"id"`
	AppID       string `json:"appID"`
	Name        string `json:"name"`
	Address     string `json:"address"`
	Ports       string `json:"ports"`
	Network     string `json:"network"`
	AccessModel string `json:"accessModel"`
}

type resourceResult struct {
	Rows      []resourceRow `json:"rows"`
	AppCount  int           `json:"appCount"`
	DNS       []string      `json:"dns"`
	Gateways  []string      `json:"gateways"`
	FetchedAt string        `json:"fetchedAt"`
}

func object(value any) map[string]any {
	m, _ := value.(map[string]any)
	return m
}

func array(value any) []any {
	a, _ := value.([]any)
	return a
}

// Only these resource metadata fields are exported to the UI. Authentication
// cookies, tickets, device policy, and all other payload data stay in memory.
func field(m map[string]any, key string) any {
	for k, v := range m {
		if strings.EqualFold(k, key) {
			return v
		}
	}
	return nil
}

func child(m map[string]any, key string) map[string]any { return object(field(m, key)) }

func text(m map[string]any, keys ...string) string {
	for _, key := range keys {
		switch value := field(m, key).(type) {
		case string:
			if strings.TrimSpace(value) != "" {
				return strings.TrimSpace(value)
			}
		case json.Number:
			return value.String()
		}
	}
	return ""
}

func validateCode(m map[string]any, required bool) error {
	value := field(m, "code")
	if value == nil {
		if required {
			return fmt.Errorf("授权资源响应缺少结果码。")
		}
		return nil
	}
	code, ok := value.(json.Number)
	if !ok {
		return fmt.Errorf("授权资源响应的结果码格式不正确。")
	}
	n, err := code.Int64()
	if err != nil {
		return fmt.Errorf("授权资源响应的结果码格式不正确。")
	}
	if n != 0 {
		return fmt.Errorf("resource request failed with code %d", n)
	}
	return nil
}

func plainAddress(value string) string {
	if strings.Contains(value, "://") {
		u, err := url.Parse(value)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
			return ""
		}
		u.User, u.RawQuery, u.Fragment = nil, "", ""
		return u.String()
	}
	return strings.SplitN(strings.SplitN(value, "?", 2)[0], "#", 2)[0]
}

func uniqueSorted(values []string) []string {
	seen := map[string]bool{}
	result := make([]string, 0)
	for _, v := range values {
		v = strings.TrimSpace(v)
		if v != "" && !seen[v] {
			seen[v] = true
			result = append(result, v)
		}
	}
	sort.Strings(result)
	return result
}

func parseResources(raw []byte) (resourceResult, error) {
	result := resourceResult{Rows: []resourceRow{}, DNS: []string{}, Gateways: []string{}, FetchedAt: time.Now().Format(time.RFC3339)}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var root map[string]any
	if err := decoder.Decode(&root); err != nil {
		return result, fmt.Errorf("接入网关未返回有效的授权资源数据。")
	}
	if err := validateCode(root, true); err != nil {
		return result, err
	}
	data := child(root, "data")
	apps := child(data, "appList")
	if apps == nil {
		return result, fmt.Errorf("服务器响应中没有 appList 授权资源列表。")
	}
	if err := validateCode(apps, false); err != nil {
		return result, err
	}
	appData := child(apps, "data")
	if appData == nil || field(appData, "appInfo") == nil {
		return result, fmt.Errorf("服务器响应中没有有效的应用资源数据。")
	}
	groups, ok := field(appData, "appInfo").([]any)
	if !ok {
		return result, fmt.Errorf("服务器应用资源列表格式不正确。")
	}
	appIDs := map[string]bool{}
	for groupIndex, group := range groups {
		groupMap := object(group)
		appValues, ok := field(groupMap, "apps").([]any)
		if !ok {
			return result, fmt.Errorf("服务器应用分组格式不正确。")
		}
		for appIndex, value := range appValues {
			app := object(value)
			if app == nil {
				return result, fmt.Errorf("服务器应用资源格式不正确。")
			}
			id := text(app, "id")
			if id == "" {
				id = fmt.Sprintf("group-%d-app-%d", groupIndex, appIndex)
			}
			appIDs[id] = true
			name := text(app, "name", "appName", "displayName")
			if name == "" {
				name = "应用 " + id
			}
			model := text(app, "accessModel")
			addresses := array(field(app, "addressList"))
			if len(addresses) == 0 {
				result.Rows = append(result.Rows, resourceRow{ID: fmt.Sprintf("%d-%d-0", groupIndex, appIndex), AppID: id, Name: name,
					Address: plainAddress(text(app, "url", "uri", "address")), AccessModel: model})
			}
			for addressIndex, value := range addresses {
				address := object(value)
				host := plainAddress(text(address, "host"))
				ips := []string{}
				for _, ip := range array(field(address, "ip")) {
					if s, ok := ip.(string); ok {
						ips = append(ips, s)
					}
				}
				if host == "" {
					host = strings.Join(uniqueSorted(ips), ", ")
				}
				result.Rows = append(result.Rows, resourceRow{ID: fmt.Sprintf("%d-%d-%d", groupIndex, appIndex, addressIndex), AppID: id,
					Name: name, Address: host, Ports: text(address, "port"), Network: text(address, "protocol"), AccessModel: model})
			}
		}
	}
	result.AppCount = len(appIDs)
	config := child(child(appData, "config"), "nodeGroupConf")
	for _, item := range array(field(config, "nodeGroupList")) {
		for _, address := range array(field(object(item), "addressInfo")) {
			result.Gateways = append(result.Gateways, plainAddress(text(object(address), "address")))
		}
	}
	policy := child(data, "sdpPolicy")
	if validateCode(policy, false) == nil {
		options := child(child(policy, "data"), "clientOption")
		for _, key := range []string{"dnsOption", "dnsOptionV2"} {
			dns := child(options, key)
			result.DNS = append(result.DNS, text(dns, "firstDNS"), text(dns, "secondDNS"))
		}
	}
	result.DNS, result.Gateways = uniqueSorted(result.DNS), uniqueSorted(result.Gateways)
	return result, nil
}
