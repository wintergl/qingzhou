use serde_json::{Value, json};
use splitvpn_core::{mobile, singbox};
use std::ffi::{CStr, CString};

const PROVIDER: &str = r#"
proxies:
  - {name: "香港 01", type: vless, server: hk.example.net, port: 443, uuid: 11111111-1111-1111-1111-111111111111, tls: true, network: grpc, servername: cdn.example.net, client-fingerprint: safari, flow: "", reality-opts: {public-key: PUBKEY, short-id: ab12}, grpc-opts: {grpc-service-name: tunnel}, udp: true}
  - {name: "日本 02", type: trojan, server: jp.example.net, port: 8443, password: secret, sni: jp.example.net, skip-cert-verify: true, network: ws, ws-opts: {path: /ws, headers: {Host: front.example.net}}}
  - {name: "美国 03", type: hysteria2, server: us.example.net, port: 443, ports: "20000-30000", password: pass, up: "50 Mbps", down: 200, obfs: salamander, obfs-password: obfs}
  - {name: "新加坡 04", type: ss, server: sg.example.net, port: 8388, cipher: aes-256-gcm, password: pw, plugin: obfs, plugin-opts: {mode: tls, host: bing.com}, udp: false}
  - {name: "台湾 05", type: tuic, server: tw.example.net, port: 443, uuid: 22222222-2222-2222-2222-222222222222, password: pw, congestion-controller: bbr, udp-relay-mode: native, reduce-rtt: true, heartbeat-interval: 10000}
  - {name: direct, type: socks5, server: 10.0.0.2, port: 1080, username: u, password: p}
  - {name: "WG", type: wireguard, server: wg.example.net, port: 51820, private-key: x}
  - {name: "HTTP 伪装", type: vmess, server: v.example.net, port: 80, uuid: 33333333-3333-3333-3333-333333333333, alterId: 0, cipher: auto, network: http}
"#;

fn call(dir: &tempfile::TempDir, channel: &str, payload: Value) -> Value {
    let reply: Value = serde_json::from_str(&mobile::call(
        dir.path().to_str().unwrap(),
        &json!({"channel":channel,"payload":payload}).to_string(),
    ))
    .unwrap();
    assert_eq!(reply["ok"], true, "{channel}: {reply}");
    reply["data"].clone()
}
fn subscribe(dir: &tempfile::TempDir, content: &str) -> String {
    let record = call(
        dir,
        "subscription:save",
        json!({"name":"机场","url":"https://sub.example.net/api?token=abc"}),
    );
    let id = record["entries"][0]["id"].as_str().unwrap().to_owned();
    let plan = call(dir, "subscription:plan", json!({"id":id}));
    let accepted = call(
        dir,
        "subscription:accept",
        json!({"id":id,"token":plan["token"],"index":0,"status":200,"content":content}),
    );
    assert_eq!(accepted["done"], true);
    assert_eq!(accepted["ok"], true, "{accepted}");
    id
}
fn generate(dir: &tempfile::TempDir, payload: Value) -> (Value, Value) {
    let out = call(dir, "singbox:generate", payload);
    let config: Value = serde_json::from_str(out["config"].as_str().unwrap()).unwrap();
    (config, out["summary"].clone())
}
fn outbound<'a>(config: &'a Value, tag: &str) -> &'a Value {
    config["outbounds"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["tag"] == tag)
        .unwrap_or_else(|| panic!("missing outbound {tag}"))
}

#[test]
fn subscription_lifecycle_uses_platform_downloads() {
    let dir = tempfile::tempdir().unwrap();
    let record = call(
        &dir,
        "subscription:save",
        json!({"url":"https://sub.example.net/api?token=abc"}),
    );
    let id = record["entries"][0]["id"].as_str().unwrap().to_owned();
    assert_eq!(call(&dir, "subscription:due", json!({})), json!([id]));

    let plan = call(&dir, "subscription:plan", json!({"id":id}));
    let urls = plan["urls"].as_array().unwrap();
    assert_eq!(urls.len(), 4);
    assert!(urls[1].as_str().unwrap().ends_with("flag=clash"));
    assert!(
        plan["headers"]["user-agent"]
            .as_str()
            .unwrap()
            .contains("mihomo")
    );

    // A notice page on the first URL falls through to the clash variants.
    let first = call(
        &dir,
        "subscription:accept",
        json!({"id":id,"token":plan["token"],"index":0,"status":200,"content":"<html>请使用客户端</html>"}),
    );
    assert_eq!(first, json!({"done":false,"next":1}));
    let second = call(
        &dir,
        "subscription:accept",
        json!({"id":id,"token":plan["token"],"index":1,"status":200,"content":PROVIDER}),
    );
    assert_eq!(second["ok"], true);
    assert_eq!(second["subscription"]["entries"][0]["nodeCount"], 8);
    assert_eq!(second["subscription"]["status"], "ready");
    assert_eq!(call(&dir, "subscription:due", json!({})), json!([]));

    let boot = call(&dir, "bootstrap", json!({}));
    assert_eq!(boot["nodes"].as_array().unwrap().len(), 8);
    assert_eq!(boot["settings"]["selectedProxy"], "AUTO");

    // A failed refresh keeps the committed nodes and records the error.
    let plan = call(&dir, "subscription:plan", json!({"id":id}));
    let failed = call(
        &dir,
        "subscription:accept",
        json!({"id":id,"token":plan["token"],"index":0,"status":500,"content":""}),
    );
    assert_eq!(failed["ok"], false);
    assert!(failed["error"].as_str().unwrap().contains("HTTP 500"));
    assert_eq!(failed["subscription"]["entries"][0]["nodeCount"], 8);
    assert_eq!(failed["subscription"]["status"], "ready");
    let nodes = call(&dir, "nodes:list", json!({}));
    assert_eq!(nodes.as_array().unwrap().len(), 8);
    assert!(nodes[0]["server"].is_string());
    assert!(nodes[0]["port"].is_u64());

    let disabled = call(
        &dir,
        "subscription:set-enabled",
        json!({"id":id,"enabled":false}),
    );
    assert_eq!(disabled["status"], "not-configured");
    assert!(
        call(&dir, "nodes:list", json!({}))
            .as_array()
            .unwrap()
            .is_empty()
    );
    let deleted = call(&dir, "subscription:delete", json!({"id":id}));
    assert!(deleted["entries"].as_array().unwrap().is_empty());
}

#[test]
fn transport_errors_on_the_last_candidate_mark_new_subscriptions_failed() {
    let dir = tempfile::tempdir().unwrap();
    let record = call(
        &dir,
        "subscription:save",
        json!({"url":"https://sub.example.net/a"}),
    );
    let id = record["entries"][0]["id"].as_str().unwrap().to_owned();
    let plan = call(&dir, "subscription:plan", json!({"id":id}));
    for index in 1..3 {
        let r = call(
            &dir,
            "subscription:accept",
            json!({"id":id,"token":plan["token"],"index":index,"error":"timeout"}),
        );
        assert_eq!(r["done"], false);
    }
    let r = call(
        &dir,
        "subscription:accept",
        json!({"id":id,"token":plan["token"],"index":3,"error":"timeout"}),
    );
    assert_eq!(r["ok"], false);
    assert_eq!(r["subscription"]["entries"][0]["status"], "error");
    assert!(!r["subscription"]["entries"][0]["lastAttemptAt"].is_null());
}

#[test]
fn generates_sing_box_outbounds_from_mihomo_nodes() {
    let dir = tempfile::tempdir().unwrap();
    subscribe(&dir, PROVIDER);
    let (config, summary) = generate(&dir, json!({"mtu":1280}));
    assert_eq!(summary["providerNodeCount"], 8);
    assert_eq!(summary["convertedOutboundCount"], 6);
    assert_eq!(summary["unsupportedNodeCount"], 2);
    assert_eq!(summary["selectedProxyStatus"], "automatic-urltest");
    assert_eq!(summary["selectedOutboundTag"], "__QZ_MOBILE_AUTO__");
    assert_eq!(config["inbounds"][0]["mtu"], 1280);
    assert_eq!(config["inbounds"][0]["address"][0], singbox::TUN_ADDRESS);
    assert_eq!(config["inbounds"][0]["address"][1], singbox::TUN_ADDRESS6);

    let vless = outbound(&config, "香港-01");
    assert_eq!(vless["type"], "vless");
    assert!(vless.get("flow").is_none());
    assert_eq!(
        vless["transport"],
        json!({"type":"grpc","service_name":"tunnel"})
    );
    assert_eq!(vless["tls"]["server_name"], "cdn.example.net");
    assert_eq!(
        vless["tls"]["reality"],
        json!({"enabled":true,"public_key":"PUBKEY","short_id":"ab12"})
    );
    assert_eq!(vless["tls"]["utls"]["fingerprint"], "safari");

    let trojan = outbound(&config, "日本-02");
    assert_eq!(trojan["tls"]["insecure"], true);
    assert_eq!(
        trojan["transport"],
        json!({"type":"ws","path":"/ws","headers":{"Host":"front.example.net"}})
    );

    let hy2 = outbound(&config, "美国-03");
    assert_eq!(hy2["server_ports"], json!(["20000:30000"]));
    assert_eq!(hy2["up_mbps"], 50);
    assert_eq!(hy2["down_mbps"], 200);
    assert_eq!(hy2["obfs"], json!({"type":"salamander","password":"obfs"}));
    assert_eq!(hy2["tls"]["server_name"], "us.example.net");

    let ss = outbound(&config, "新加坡-04");
    assert_eq!(ss["type"], "shadowsocks");
    assert_eq!(ss["plugin"], "obfs-local");
    assert_eq!(ss["plugin_opts"], "obfs=tls;obfs-host=bing.com");
    assert_eq!(ss["network"], "tcp");

    let tuic = outbound(&config, "台湾-05");
    assert_eq!(tuic["tls"]["alpn"], json!(["h3"]));
    assert_eq!(tuic["heartbeat"], "10000ms");
    assert_eq!(tuic["zero_rtt_handshake"], true);

    // A node named like a built-in outbound must not shadow it.
    assert_eq!(outbound(&config, "direct")["type"], "direct");
    assert_eq!(outbound(&config, "direct-2")["type"], "socks");
    let selector = outbound(&config, "proxy");
    assert_eq!(selector["default"], "__QZ_MOBILE_AUTO__");
    assert_eq!(selector["outbounds"].as_array().unwrap().len(), 8);
}

#[test]
fn geo_fallback_shapes_singbox_route_when_geo_is_missing() {
    let dir = tempfile::tempdir().unwrap();
    subscribe(&dir, PROVIDER);
    let payload = json!({"domainResolver":"ali","mtu":9000});

    // Default: mainland names direct, unmatched traffic goes to the proxy.
    let (config, summary) = generate(&dir, payload.clone());
    assert_eq!(summary["geoRuleSets"], false);
    assert_eq!(summary["geoFallback"], "cn-direct-else-vpn");
    assert_eq!(config["route"]["final"], "proxy");
    assert_eq!(config["dns"]["final"], "cloudflare");
    assert!(config["route"]["rule_set"].is_null());

    // follow-default keeps the old shape: unknownTraffic decides the final hop.
    call(
        &dir,
        "settings:patch",
        json!({"unknownTraffic":"direct","geoFallback":"follow-default"}),
    );
    let (config, summary) = generate(&dir, payload.clone());
    assert_eq!(summary["geoFallback"], "follow-default");
    assert_eq!(config["route"]["final"], "direct");
    assert_eq!(config["dns"]["final"], "ali");

    // block: generation fails instead of starting an unfiltered tunnel.
    call(&dir, "settings:patch", json!({"geoFallback":"block"}));
    let reply: Value = serde_json::from_str(&mobile::call(
        dir.path().to_str().unwrap(),
        &json!({"channel":"singbox:generate","payload":payload}).to_string(),
    ))
    .unwrap();
    assert_eq!(reply["ok"], false, "{reply}");
}

#[test]
fn routes_follow_shared_settings() {
    let dir = tempfile::tempdir().unwrap();
    let id = subscribe(&dir, PROVIDER);
    let identity = splitvpn_core::storage::identity(&id, "新加坡 04");
    call(
        &dir,
        "settings:patch",
        json!({
            "selectedProxy":"新加坡 04",
            "defaultOutlet":{"kind":"node","name":"新加坡 04","identityKey":identity},
            "unknownTraffic":"vpn",
            "tailscaleDirect":false,
            "vpnDomainRules":["DOMAIN-SUFFIX,openai.com","DOMAIN,cdn.example.org","DOMAIN-KEYWORD,chatgpt","GEOSITE,netflix"],
        }),
    );
    let geo = json!({"geositeCn":"/g/cn.srs","geoipCn":"/g/ip.srs","geositeNonCn":"/g/!cn.srs"});
    let (config, summary) = generate(&dir, json!({"geo":geo,"domainResolver":"ali","mtu":9000}));
    assert_eq!(summary["selectedProxyStatus"], "manual-converted");
    assert_eq!(summary["selectedOutboundTag"], "新加坡-04");
    assert_eq!(summary["skippedRuleCount"], 1);
    assert_eq!(summary["packetTunnelMTU"], singbox::DEFAULT_MTU);
    assert!(
        !summary["directCidrs"]
            .as_array()
            .unwrap()
            .contains(&json!("100.64.0.0/10"))
    );
    let route = &config["route"];
    assert_eq!(route["final"], "proxy");
    assert_eq!(route["default_domain_resolver"], "ali");
    assert_eq!(route["rule_set"].as_array().unwrap().len(), 3);
    let rules = route["rules"].as_array().unwrap();
    // The selected node is TCP-only, so QUIC to proxied names is blocked
    // before the explicit VPN rule.
    let find = |pred: &dyn Fn(&Value) -> bool| rules.iter().position(pred).unwrap();
    let vpn_block =
        find(&|r| r["domain_suffix"] == json!(["openai.com"]) && r["outbound"] == "block");
    let vpn = find(&|r| r["domain_suffix"] == json!(["openai.com"]) && r["outbound"] == "proxy");
    let cn = find(&|r| r["rule_set"] == json!(["geosite-cn"]));
    assert!(vpn_block < vpn && vpn < cn);
    assert_eq!(rules[vpn]["domain"], json!(["cdn.example.org"]));
    assert_eq!(rules[vpn]["domain_keyword"], json!(["chatgpt"]));
    assert!(
        rules
            .iter()
            .any(|r| r.as_object().unwrap().len() == 2 && r["protocol"] == json!(["quic"]))
    );
    let dns = config["dns"]["rules"].as_array().unwrap();
    assert!(
        dns.iter()
            .any(|r| r["domain_suffix"] == json!(["openai.com"]) && r["server"] == "fakeip")
    );

    // Missing nodes block instead of silently leaking through another exit.
    call(&dir, "settings:patch", json!({"selectedProxy":"不存在"}));
    let (config, summary) = generate(&dir, json!({}));
    assert_eq!(summary["selectedProxyStatus"], "manual-missing");
    assert_eq!(outbound(&config, "proxy")["default"], "block");
    assert!(config["route"].get("rule_set").is_none());

    call(&dir, "settings:patch", json!({"selectedProxy":"WG"}));
    assert_eq!(
        generate(&dir, json!({})).1["selectedProxyStatus"],
        "manual-unsupported"
    );
}
#[test]
fn direct_exceptions_survive_older_shell_patches_and_compile_on_both_data_planes() {
    let dir = tempfile::tempdir().unwrap();
    subscribe(&dir, PROVIDER);
    call(
        &dir,
        "settings:patch",
        json!({"directDomainRules":["api.example.test","192.0.2.0/24","2001:db8::/32"]}),
    );
    // iOS and Android's existing shells patch their own fields only.
    call(
        &dir,
        "settings:patch",
        json!({"vpnDomainRules":["DOMAIN-SUFFIX,example.test","IP-CIDR,203.0.113.8/32"],"unknownTraffic":"vpn"}),
    );
    let settings = call(&dir, "settings:get", json!({}));
    assert_eq!(settings["directDomainRules"].as_array().unwrap().len(), 3);
    let (config, summary) = generate(&dir, json!({}));
    assert_eq!(summary["skippedRuleCount"], 0);
    let rules = config["route"]["rules"].as_array().unwrap();
    let direct = rules
        .iter()
        .position(|r| {
            r["domain_suffix"] == json!(["api.example.test"]) && r["outbound"] == "direct"
        })
        .unwrap();
    let vpn = rules
        .iter()
        .position(|r| r["domain_suffix"] == json!(["example.test"]) && r["outbound"] == "proxy")
        .unwrap();
    assert!(direct < vpn);
    assert_eq!(
        rules[direct]["ip_cidr"],
        json!(["192.0.2.0/24", "2001:db8::/32"])
    );
    let dns = config["dns"]["rules"].as_array().unwrap();
    assert_eq!(dns[0]["server"], "ali");
    assert_eq!(dns[0]["domain_suffix"], json!(["api.example.test"]));
    assert!(dns.iter().all(|r| r.get("ip_cidr").is_none()));
    let mihomo = call(
        &dir,
        "mihomo:generate",
        json!({"mixedPort":17890,"controllerPort":19090}),
    );
    let yaml: Value = serde_yaml_ng::from_str(
        &std::fs::read_to_string(mihomo["config"].as_str().unwrap()).unwrap(),
    )
    .unwrap();
    assert!(
        yaml["rules"]
            .as_array()
            .unwrap()
            .contains(&json!("IP-CIDR,192.0.2.0/24,DIRECT,no-resolve"))
    );
}

#[test]
fn uri_subscriptions_keep_grpc_and_reality_options() {
    let dir = tempfile::tempdir().unwrap();
    let uri = "vless://44444444-4444-4444-4444-444444444444@r.example.net:443?security=reality&type=grpc&serviceName=gun&pbk=KEY&sid=01&fp=chrome&sni=www.example.com#Reality%20%E8%8A%82%E7%82%B9\ntrojan://pw@t.example.net:443?type=ws&path=%2Ftr&host=cdn.example.net#Trojan";
    subscribe(&dir, uri);
    let (config, summary) = generate(&dir, json!({}));
    assert_eq!(summary["convertedOutboundCount"], 2);
    let vless = outbound(&config, "Reality-节点");
    assert_eq!(vless["transport"]["service_name"], "gun");
    assert_eq!(vless["tls"]["reality"]["public_key"], "KEY");
    assert_eq!(vless["tls"]["server_name"], "www.example.com");
    let trojan = outbound(&config, "Trojan");
    assert_eq!(trojan["transport"]["path"], "/tr");
    assert_eq!(trojan["transport"]["headers"]["Host"], "cdn.example.net");
}

#[test]
fn manual_selection_without_any_node_goes_direct() {
    // An upgraded install keeps its old manual pick before the first
    // subscription update; blocking would also block that download.
    let dir = tempfile::tempdir().unwrap();
    call(&dir, "settings:patch", json!({"selectedProxy":"Tokyo X"}));
    let (config, summary) = generate(&dir, json!({}));
    assert_eq!(summary["selectedOutboundTag"], "direct");
    assert_eq!(summary["selectedProxyStatus"], "direct-only");
    assert_eq!(outbound(&config, "proxy")["default"], "direct");

    subscribe(&dir, PROVIDER);
    let (_, summary) = generate(&dir, json!({}));
    assert_eq!(summary["selectedProxyStatus"], "manual-missing");
    assert_eq!(summary["selectedOutboundTag"], "block");
}

#[test]
fn legacy_base64_shadowsocks_uri_keeps_query() {
    let dir = tempfile::tempdir().unwrap();
    // base64("aes-128-gcm:password@ss.example.com:8388"), padded, then a query.
    subscribe(
        &dir,
        "ss://YWVzLTEyOC1nY206cGFzc3dvcmRAc3MuZXhhbXBsZS5jb206ODM4OA==?udp=true#ss%20sample",
    );
    let (config, _) = generate(&dir, json!({}));
    let ss = outbound(&config, "ss-sample");
    assert_eq!(ss["server"], "ss.example.com");
    assert_eq!(ss["server_port"], 8388);
    assert_eq!(ss["method"], "aes-128-gcm");
}

#[test]
fn c_abi_round_trips_errors() {
    let dir = tempfile::tempdir().unwrap();
    let root = CString::new(dir.path().to_str().unwrap()).unwrap();
    let request = CString::new(r#"{"channel":"nope"}"#).unwrap();
    let take = |raw: *mut std::ffi::c_char| {
        // SAFETY: `raw` comes from `qz_core_call` and is freed exactly once.
        unsafe {
            let text = CStr::from_ptr(raw).to_str().unwrap().to_owned();
            mobile::qz_core_free(raw);
            text
        }
    };
    // SAFETY: both pointers are valid NUL-terminated strings.
    let reply = take(unsafe { mobile::qz_core_call(root.as_ptr(), request.as_ptr()) });
    let reply: Value = serde_json::from_str(&reply).unwrap();
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["error"]["code"], "CORE_OPERATION_FAILED");
    // SAFETY: null pointers are accepted and reported as errors.
    let reply = take(unsafe { mobile::qz_core_call(std::ptr::null(), std::ptr::null()) });
    assert!(reply.contains("缺少数据目录"));
}

#[test]
fn mihomo_probes_follow_selection_without_changing_saved_settings() {
    let dir = tempfile::tempdir().unwrap();
    subscribe(&dir, PROVIDER);
    for (selected, automatic) in [
        ("香港 01", false),
        ("AUTO", true),
        ("BALANCE", true),
        ("日本 02", false),
        ("DIRECT", false),
    ] {
        call(&dir, "settings:patch", json!({"selectedProxy": selected}));
        let before = call(&dir, "settings:get", json!({}));
        let generated = call(&dir, "mihomo:generate", json!({}));
        assert_eq!(generated["selectionValid"], true);
        assert_eq!(generated["selectedProxy"], selected);
        let config: Value = serde_yaml_ng::from_str(
            &std::fs::read_to_string(generated["config"].as_str().unwrap()).unwrap(),
        )
        .unwrap();
        for provider in config["proxy-providers"].as_object().unwrap().values() {
            let health = &provider["health-check"];
            assert_eq!(health["enable"], automatic, "selection={selected}");
            if automatic {
                assert!(health["interval"].as_u64().unwrap() > 0);
            } else {
                assert_eq!(health["interval"], 0);
            }
            assert!(health["url"].as_str().is_some_and(|url| !url.is_empty()));
            for group in config["proxy-groups"].as_array().unwrap() {
                if group.get("url").is_some() {
                    assert_eq!(group["url"], health["url"]);
                    if automatic {
                        assert!(group["interval"].as_u64().unwrap() > 0);
                    } else {
                        assert_eq!(group["interval"], 0);
                    }
                }
                if group["name"] == "VPN" {
                    assert_eq!(group["default-selected"], selected);
                }
            }
        }
        assert_eq!(call(&dir, "settings:get", json!({})), before);
    }
}

#[test]
fn mihomo_config_runs_behind_tun2socks() {
    let dir = tempfile::tempdir().unwrap();
    let empty = call(&dir, "mihomo:generate", json!({}));
    assert_eq!(empty["providerCount"], 0);
    let text = std::fs::read_to_string(empty["config"].as_str().unwrap()).unwrap();
    assert!(text.contains("MATCH,DIRECT"));

    subscribe(&dir, PROVIDER);
    call(
        &dir,
        "settings:patch",
        json!({"selectedProxy":"香港 01","unknownTraffic":"vpn","vpnDomainRules":["DOMAIN-SUFFIX,openai.com"]}),
    );
    let out = call(&dir, "mihomo:generate", json!({"mixedPort":7891}));
    assert_eq!(out["providerCount"], 1);
    assert_eq!(out["udp"], true);
    assert_eq!(out["controller"], "127.0.0.1:9090");
    assert!(out["secret"].as_str().unwrap().len() >= 32);
    let home = std::path::Path::new(out["home"].as_str().unwrap());
    let c: Value =
        serde_yaml_ng::from_str(&std::fs::read_to_string(out["config"].as_str().unwrap()).unwrap())
            .unwrap();
    assert_eq!(c["mixed-port"], 7891);
    assert_eq!(c["tun"]["enable"], false);
    assert_eq!(c["geo-auto-update"], false);
    assert!(c["dns"].get("listen").is_none());
    let provider = c["proxy-providers"]
        .as_object()
        .unwrap()
        .values()
        .next()
        .unwrap();
    assert!(std::path::Path::new(provider["path"].as_str().unwrap()).starts_with(home));
    assert_eq!(provider["health-check"]["lazy"], true);
    assert_eq!(provider["health-check"]["enable"], false);
    assert_eq!(provider["health-check"]["interval"], 0);
    for name in ["AUTO", "BALANCE"] {
        let group = c["proxy-groups"]
            .as_array()
            .unwrap()
            .iter()
            .find(|g| g["name"] == name)
            .unwrap();
        assert_eq!(group["lazy"], true);
        assert_eq!(group["interval"], 0);
        assert_eq!(group["url"], provider["health-check"]["url"]);
    }
    let rules: Vec<&str> = c["rules"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r.as_str().unwrap())
        .collect();
    assert!(rules.contains(&"RULE-SET,vpn-domains,VPN"));
    assert_eq!(rules.last(), Some(&"MATCH,VPN"));
    assert!(!rules.iter().any(|r| r.starts_with("PROCESS-NAME")));
    assert!(
        !c["proxy-groups"]
            .as_array()
            .unwrap()
            .iter()
            .any(|g| g["name"] == "WECHAT")
    );
    let domains = std::fs::read_to_string(home.join("providers/vpn-domains.yaml")).unwrap();
    assert!(domains.contains("DOMAIN-SUFFIX,openai.com"));

    let reply: Value = serde_json::from_str(&mobile::call(
        dir.path().to_str().unwrap(),
        &json!({"channel":"mihomo:generate","payload":{"controllerPort":70000}}).to_string(),
    ))
    .unwrap();
    assert_eq!(reply["ok"], false);
}

#[test]
fn android_virtual_dns_precedes_direct_rules_without_changing_settings() {
    let dir = tempfile::tempdir().unwrap();
    subscribe(
        &dir,
        "proxies:\n  - {name: __QZ_ANDROID_DNS__, type: http, server: example.test, port: 8080}\n  - {name: __QZ_ANDROID_DNS__1, type: http, server: example.test, port: 8081}\n",
    );
    call(
        &dir,
        "settings:patch",
        json!({"selectedProxy":"__QZ_ANDROID_DNS__","lanDirect":true,"directDomainRules":["IP-CIDR,172.19.0.0/16"]}),
    );
    // Simulate a preference written by a newer shell. Generating DNS must not
    // rewrite or discard fields this version does not own.
    let settings_path = dir.path().join("settings.json");
    let mut settings: Value =
        serde_json::from_str(&std::fs::read_to_string(&settings_path).unwrap()).unwrap();
    settings["futureShellPreference"] = json!({"enabled":true,"value":"preserve"});
    std::fs::write(&settings_path, serde_json::to_vec(&settings).unwrap()).unwrap();
    let before = call(&dir, "settings:get", json!({}));
    for selected in ["__QZ_ANDROID_DNS__", "DIRECT", "AUTO"] {
        call(&dir, "settings:patch", json!({"selectedProxy":selected}));
        let saved = call(&dir, "settings:get", json!({}));
        let generated = call(&dir, "mihomo:generate", json!({}));
        let c: Value = serde_yaml_ng::from_str(
            &std::fs::read_to_string(generated["config"].as_str().unwrap()).unwrap(),
        )
        .unwrap();
        assert_eq!(c["proxies"][0]["name"], "__QZ_ANDROID_DNS__2");
        assert_eq!(c["proxies"][0]["type"], "dns");
        assert_eq!(
            c["rules"][0],
            "AND,((IP-CIDR,172.19.0.2/32,no-resolve),(DST-PORT,53)),__QZ_ANDROID_DNS__2"
        );
        assert!(c["dns"].get("listen").is_none());
        assert_eq!(c["dns"]["enable"], true);
        assert_eq!(c["dns"]["enhanced-mode"], "fake-ip");
        assert_eq!(generated["selectedProxy"], selected);
        assert_eq!(call(&dir, "settings:get", json!({})), saved);
    }
    assert_eq!(
        call(&dir, "settings:get", json!({}))["directDomainRules"],
        before["directDomainRules"]
    );
}

#[test]
fn mobile_download_result_cannot_follow_an_edited_url() {
    let dir = tempfile::tempdir().unwrap();
    let id = subscribe(&dir, PROVIDER);
    let plan = call(&dir, "subscription:plan", json!({"id":id}));
    call(
        &dir,
        "subscription:save",
        json!({"id":id,"url":"https://new.example.test/sub"}),
    );
    let before = std::fs::read(dir.path().join("subscription.json")).unwrap();
    let manifest = std::fs::read(
        dir.path()
            .join("mihomo/providers/subscription-manifest.json"),
    )
    .unwrap();
    for payload in [
        json!({"status":200,"content":PROVIDER}),
        json!({"error":"old request failed"}),
    ] {
        let mut p = json!({"id":id,"token":plan["token"],"index":0});
        p.as_object_mut()
            .unwrap()
            .extend(payload.as_object().unwrap().clone());
        let result = call(&dir, "subscription:accept", p);
        assert_eq!(result["stale"], true);
        assert_eq!(result["ok"], false);
        assert_eq!(
            std::fs::read(dir.path().join("subscription.json")).unwrap(),
            before
        );
        assert_eq!(
            std::fs::read(
                dir.path()
                    .join("mihomo/providers/subscription-manifest.json")
            )
            .unwrap(),
            manifest
        );
    }
}

#[test]
fn mobile_newer_download_and_completed_token_reject_old_results() {
    let dir = tempfile::tempdir().unwrap();
    let id = subscribe(&dir, PROVIDER);
    let old = call(&dir, "subscription:plan", json!({"id":id}));
    let new = call(&dir, "subscription:plan", json!({"id":id}));
    let stale = call(
        &dir,
        "subscription:accept",
        json!({"id":id,"token":old["token"],"index":0,"error":"timeout"}),
    );
    assert_eq!(stale["stale"], true);
    assert!(stale["subscription"]["entries"][0]["lastError"].is_null());
    let accepted = call(
        &dir,
        "subscription:accept",
        json!({"id":id,"token":new["token"],"index":0,"status":200,"content":PROVIDER}),
    );
    assert_eq!(accepted["ok"], true);
    let replay = call(
        &dir,
        "subscription:accept",
        json!({"id":id,"token":new["token"],"index":0,"error":"replayed failure"}),
    );
    assert_eq!(replay["stale"], true);
    assert!(replay["subscription"]["entries"][0]["lastError"].is_null());
}

#[test]
fn android_fixed_selection_is_invalid_after_removal_or_disable() {
    let dir = tempfile::tempdir().unwrap();
    let id = subscribe(&dir, PROVIDER);
    call(&dir, "settings:patch", json!({"selectedProxy":"香港 01"}));
    assert_eq!(
        call(&dir, "mihomo:generate", json!({}))["selectionValid"],
        true
    );
    let plan = call(&dir, "subscription:plan", json!({"id":id}));
    call(
        &dir,
        "subscription:accept",
        json!({"id":id,"token":plan["token"],"index":0,"status":200,"content":"proxies:\n  - {name: other, type: http, server: example.test, port: 80}\n"}),
    );
    let missing = call(&dir, "mihomo:generate", json!({}));
    assert_eq!(missing["selectionValid"], false);
    assert_eq!(missing["selectedProxy"], "香港 01");
    for builtin in ["AUTO", "BALANCE", "DIRECT"] {
        call(&dir, "settings:patch", json!({"selectedProxy":builtin}));
        assert_eq!(
            call(&dir, "mihomo:generate", json!({}))["selectionValid"],
            true
        );
    }
    call(&dir, "settings:patch", json!({"selectedProxy":"香港 01"}));
    call(
        &dir,
        "subscription:set-enabled",
        json!({"id":id,"enabled":false}),
    );
    let empty = call(&dir, "mihomo:generate", json!({}));
    assert_eq!(empty["selectionValid"], false);
    assert_eq!(empty["providerCount"], 0);
    // DIRECT does not depend on any node, so it stays startable without them.
    call(&dir, "settings:patch", json!({"selectedProxy":"DIRECT"}));
    assert_eq!(
        call(&dir, "mihomo:generate", json!({}))["selectionValid"],
        true
    );
}

#[test]
fn android_node_switch_regenerates_quic_rule_in_both_directions() {
    let dir = tempfile::tempdir().unwrap();
    subscribe(&dir, PROVIDER);
    for (name, udp) in [("香港 01", true), ("新加坡 04", false), ("香港 01", true)] {
        call(&dir, "settings:patch", json!({"selectedProxy":name}));
        let out = call(&dir, "mihomo:generate", json!({}));
        assert_eq!(out["selectionValid"], true);
        assert_eq!(out["udp"], udp);
        let c: Value = serde_yaml_ng::from_str(
            &std::fs::read_to_string(out["config"].as_str().unwrap()).unwrap(),
        )
        .unwrap();
        let rules = c["rules"].as_array().unwrap();
        assert_eq!(
            rules
                .iter()
                .any(|r| r == splitvpn_core::config::QUIC_REJECT),
            !udp
        );
    }
}
