use serde_json::{Value, json};
use splitvpn_core::{
    Core, Jobs, company, config,
    storage::{Storage, atomic_write, identity, normalize_rule, normalize_settings, redact},
    subscription,
};
use std::{fs, path::PathBuf, sync::Arc};

#[test]
fn subscription_format_is_explicit_and_independent_of_provider() {
    let (urls, compat) = subscription::download_plan(
        "https://sub.example.test/feed?token=fixture&list=shadowrocket&flag=clash",
    )
    .unwrap();
    assert!(compat);
    assert_eq!(urls.len(), 1);
    let pairs: Vec<_> = urls[0].query_pairs().into_owned().collect();
    assert!(pairs.contains(&("token".into(), "fixture".into())));
    assert!(pairs.contains(&("list".into(), "shadowrocket".into())));
    assert!(!pairs.iter().any(|(key, _)| key == "flag"));

    let (urls, compat) =
        subscription::download_plan("https://sub.example.test/link/fixture").unwrap();
    assert!(!compat);
    assert_eq!(urls.len(), 4);
    assert!(urls[0].query().is_none());

    let (urls, compat) =
        subscription::download_plan("https://sub.example.test/feed?list=clash").unwrap();
    assert!(!compat);
    assert_eq!(urls[0].query(), Some("list=clash"));
}

fn core(dir: &tempfile::TempDir) -> Core {
    Core::new(
        dir.path().into(),
        PathBuf::from("/nonexistent"),
        true,
        Arc::new(|_, _| {}),
        Arc::new(Jobs::default()),
    )
    .unwrap()
}
#[test]
fn company_recovery_clears_a_dead_core_without_contacting_a_controller() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = core(&dir);
    let mut finished = std::process::Command::new("/usr/bin/true").spawn().unwrap();
    let dead_pid = finished.id();
    finished.wait().unwrap();
    c.engine
        .store
        .write(
            "runtime-state/native-company-routing.json",
            &json!({
                "ownerPid":dead_pid,"corePid":dead_pid,"proxyName":"COMPANY-01234567"
            }),
        )
        .unwrap();
    // No controller or engine is running in this fixture.
    c.engine.controller = 1;
    c.company.recover(&mut c.engine).unwrap();
    assert!(
        !c.engine
            .store
            .path("runtime-state/native-company-routing.json")
            .exists()
    );
}
#[test]
fn company_recovery_keeps_the_journal_for_an_unconfirmed_live_core() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = core(&dir);
    let path = c
        .engine
        .store
        .path("runtime-state/native-company-routing.json");
    c.engine
        .store
        .write(
            "runtime-state/native-company-routing.json",
            &json!({
                "corePid":std::process::id(),"proxyName":"COMPANY-01234567"
            }),
        )
        .unwrap();
    let before = fs::read(&path).unwrap();
    c.engine.controller = 1;
    assert!(c.company.recover(&mut c.engine).is_err());
    c.shutdown();
    assert_eq!(fs::read(path).unwrap(), before);
}
fn provider(store: &Storage, id: &str, name: &str, revision: &str) {
    let path = store.path(&format!("mihomo/providers/{id}.{revision}.yaml"));
    atomic_write(&path,format!("proxies:\n  - name: '{name}'\n    type: http\n    server: 192.0.2.1\n    port: 8080\n    udp: false\n").as_bytes()).unwrap();
    let mut record = store.subscription().unwrap();
    record["entries"].as_array_mut().unwrap().push(json!({"id":id,"name":id,"url":"https://example.com/sub","enabled":true,"status":"ready","nodeCount":1}));
    store.write("subscription.json", &record).unwrap();
    let mut manifest = store.manifest().unwrap();
    manifest["entries"]
        .as_array_mut()
        .unwrap()
        .retain(|p| p["subscriptionId"] != id);
    manifest["entries"]
        .as_array_mut()
        .unwrap()
        .push(json!({"subscriptionId":id,"providerPath":path,"providerRevision":revision}));
    store.save_manifest(manifest).unwrap();
}
#[test]
fn bootstrap_does_not_rewrite_or_start_network() {
    let dir = tempfile::tempdir().unwrap();
    let store = Storage::new(dir.path().into());
    let settings = json!({"settingsVersion":10,"tun":false,"ipv6":true,"lanDirect":false,"tailscaleDirect":false,"favoriteNodeNames":["kept"],"nodeGroups":[],"vpnDomainRules":["DOMAIN-SUFFIX,example.com"],"selectedProxy":"DIRECT"});
    store.write("settings.json", &settings).unwrap();
    let before = fs::read(store.path("settings.json")).unwrap();
    let mut c = core(&dir);
    let v = c.handle("native:bootstrap", &json!({})).unwrap();
    assert_eq!(v["core"]["implementation"], "rust");
    assert_eq!(v["status"]["settings"]["tun"], false);
    assert_eq!(v["status"]["settings"]["ipv6"], true);
    assert_eq!(fs::read(store.path("settings.json")).unwrap(), before);
    assert!(!store.path("mihomo/config.yaml").exists());
}
#[test]
fn startup_adopts_existing_engine_and_does_not_reconnect_after_manual_stop() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = core(&dir);
    c.engine.pid = Some(std::process::id());
    let result = c.handle("native:startup-connect", &json!({})).unwrap();
    assert_eq!(result["startupOutcome"], "already-running");
    assert_eq!(result["mihomo"]["pid"], std::process::id());
    assert!(c.engine.owned.is_none());
    assert!(!c.engine.store.path("mihomo/config.yaml").exists());
    c.engine.pid = None;
    let repeated = c.handle("native:startup-connect", &json!({})).unwrap();
    assert_eq!(repeated["startupOutcome"], "already-attempted");
    assert_eq!(repeated["mihomo"]["state"], "stopped");
    assert!(!c.engine.store.path("mihomo/config.yaml").exists());
}
#[test]
fn failed_startup_does_not_change_saved_node_or_retry_when_it_becomes_valid() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = core(&dir);
    c.engine
        .store
        .write("settings.json", &json!({"selectedProxy":"removed-node"}))
        .unwrap();
    let before = fs::read(c.engine.store.path("settings.json")).unwrap();
    let error = c.handle("native:startup-connect", &json!({})).unwrap_err();
    assert!(error.to_string().contains("具体节点"));
    assert_eq!(
        fs::read(c.engine.store.path("settings.json")).unwrap(),
        before
    );
    assert!(!c.engine.store.path("mihomo/config.yaml").exists());
    provider(&c.engine.store, "one", "removed-node", "revision");
    let result = c.handle("native:startup-connect", &json!({})).unwrap();
    assert_eq!(result["startupOutcome"], "already-attempted");
    assert!(!c.engine.store.path("mihomo/config.yaml").exists());
}
#[test]
fn startup_does_not_clear_a_required_recovery_confirmation() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = core(&dir);
    c.engine
        .store
        .set_recovery(true, Some("fixture-required"))
        .unwrap();
    let before = c.engine.store.recovery().unwrap();
    let error = c.handle("native:startup-connect", &json!({})).unwrap_err();
    assert!(error.to_string().contains("RECOVERY_REQUIRED"));
    assert_eq!(c.engine.store.recovery().unwrap(), before);
    assert!(!c.engine.store.path("mihomo/config.yaml").exists());
}
#[test]
fn settings_keep_unknown_fields_and_explicit_empty_rules() {
    let v = normalize_settings(
        json!({"settingsVersion":10,"vpnDomainRules":[],"tun":false,"futureField":{"a":1}}),
    )
    .unwrap();
    assert_eq!(v["vpnDomainRules"], json!([]));
    assert_eq!(v["futureField"]["a"], 1);
    assert_eq!(v["tun"], false);
}
#[test]
fn invalid_settings_file_is_preserved() {
    let dir = tempfile::tempdir().unwrap();
    atomic_write(&dir.path().join("settings.json"), b"not-json").unwrap();
    assert!(Storage::new(dir.path().into()).settings().is_err());
    assert_eq!(
        fs::read(dir.path().join("settings.json")).unwrap(),
        b"not-json"
    );
}
#[test]
fn identity_uses_same_encoding_as_typescript() {
    assert_eq!(
        identity("a:b", "东京 A👍"),
        "v1:a%3Ab:%E4%B8%9C%E4%BA%AC%20A%F0%9F%91%8D"
    );
    assert_eq!(identity("one", "a!()'*~._-"), "v1:one:a!()'*~._-");
}
#[test]
fn duplicate_names_remain_distinct_and_cannot_be_selected() {
    let d = tempfile::tempdir().unwrap();
    let mut c = core(&d);
    provider(&c.engine.store, "one", "same", "rev1");
    provider(&c.engine.store, "two", "same", "rev2");
    let ns = c.nodes().unwrap();
    assert_eq!(ns.len(), 3);
    assert_ne!(ns[0]["identityKey"], ns[1]["identityKey"]);
    assert_eq!(ns[0]["identityAmbiguous"], true);
    assert!(
        c.handle(
            "nodes:select-v2",
            &json!({"identityKey":ns[0]["identityKey"]})
        )
        .is_err()
    );
    assert!(!c.engine.store.path("settings.json").exists());
}
#[test]
fn stale_provider_files_are_not_enumerated() {
    let d = tempfile::tempdir().unwrap();
    let s = Storage::new(d.path().into());
    provider(&s, "one", "good", "r1");
    atomic_write(
        &s.path("mihomo/providers/stale.yaml"),
        b"proxies: [{name: stale, type: ss, server: example.com, port: 1}]",
    )
    .unwrap();
    let nodes = subscription::provider_nodes(&s).unwrap();
    assert_eq!(nodes.len(), 1);
    assert_eq!(nodes[0]["name"], "good");
}
#[test]
fn invalid_update_interval_preserves_subscription() {
    let d = tempfile::tempdir().unwrap();
    let mut c = core(&d);
    let r = c
        .handle(
            "native:save-subscription",
            &json!({"url":"https://example.com/sub","name":"one"}),
        )
        .unwrap();
    let before = fs::read(c.engine.store.path("subscription.json")).unwrap();
    assert!(
        c.handle(
            "subscription:configure-update",
            &json!({"id":r["entries"][0]["id"],"intervalMinutes":4})
        )
        .is_err()
    );
    assert_eq!(
        fs::read(c.engine.store.path("subscription.json")).unwrap(),
        before
    );
    assert!(
        !c.engine
            .store
            .path("runtime-state/rust-pending.json")
            .exists()
    );
}
#[test]
fn manually_disabled_subscription_is_never_due() {
    let r = json!({"entries":[{"id":"a","enabled":true,"updateIntervalMinutes":null},{"id":"b","enabled":false,"updateIntervalMinutes":15},{"id":"c","enabled":true,"updateIntervalMinutes":15,"updatedAt":null}]});
    assert_eq!(subscription::due_ids(&r), ["c"]);
}
#[test]
fn parses_anytls_base64_and_preserves_tls_choice() {
    use base64::Engine;
    let uri = "anytls://secret@example.com:443?allowInsecure=0&sni=www.example.com#Tokyo";
    let encoded = base64::engine::general_purpose::STANDARD.encode(uri);
    let n = subscription::parse_provider(&encoded).unwrap();
    assert_eq!(n[0]["password"], "secret");
    assert_eq!(n[0]["skip-cert-verify"], false);
    assert_eq!(n[0]["sni"], "www.example.com");
}
#[test]
fn shadowrocket_metadata_does_not_hide_raw_or_base64_nodes() {
    use base64::Engine;
    let text = "STATUS=Fixture subscription status\r\nREMARKS=Fixture: 東京\r\n\r\n# provider comment\r\nanytls://secret@example.com:443?insecure=0&sni=example.net#Tokyo\r\nss://YWVzLTEyOC1nY206c2VjcmV0@example.net:8388#HongKong\r\n";
    let encoded = base64::engine::general_purpose::STANDARD.encode(text);
    for source in [text.to_owned(), encoded] {
        let prepared = subscription::prepare_content(&source).unwrap();
        assert_eq!(
            prepared, source,
            "unchanged protocol content and metadata must be preserved"
        );
        let nodes = subscription::parse_provider(&prepared).unwrap();
        assert_eq!(nodes.len(), 2);
        assert_eq!(nodes[0]["name"], "Tokyo");
        assert_eq!(nodes[0]["password"], "secret");
        assert_eq!(nodes[0]["skip-cert-verify"], false);
        assert_eq!(nodes[1]["type"], "ss");
    }
}
#[test]
fn metadata_does_not_turn_invalid_or_unsupported_content_into_nodes() {
    assert!(
        subscription::parse_provider("STATUS=fixture\nREMARKS=subscription: no nodes\n").is_err()
    );
    assert!(subscription::parse_provider("<html>subscription login page</html>").is_err());
    assert!(
        subscription::parse_provider("STATUS=fixture\nunsupported://secret@example.com#bad")
            .is_err()
    );
    assert!(subscription::parse_provider("STATUS=fixture\nanytls://#missing-server").is_err());
}
#[test]
fn yaml_preserves_arbitrary_mihomo_protocol_options() {
    let ns=subscription::parse_provider("proxies:\n- name: test\n  type: vless\n  server: example.com\n  port: 443\n  uuid: x\n  reality-opts: {public-key: preserved}\n").unwrap();
    assert_eq!(ns[0]["reality-opts"]["public-key"], "preserved");
}
#[test]
fn rejected_uri_does_not_create_nodes() {
    assert!(subscription::parse_provider("unsupported://password@example.com#node").is_err());
    assert!(subscription::validate_url("https://user:password@example.com/sub").is_err());
}
#[test]
fn rules_normalize_and_reject_unsafe_values() {
    assert_eq!(
        normalize_rule("*.EXAMPLE.com."),
        Some("DOMAIN-SUFFIX,example.com".into())
    );
    assert_eq!(
        normalize_rule("https://example.com/x"),
        Some("DOMAIN-SUFFIX,example.com".into())
    );
    assert_eq!(normalize_rule("MATCH,DIRECT"), None);
}
fn base() -> Value {
    json!({"mode":"rule","tun":{"enable":true,"auto-route":true,"route-exclude-address":["10.0.0.0/8","192.168.0.0/16","100.64.0.0/10"]},"dns":{"enhanced-mode":"fake-ip"},"proxies":[],"rules":["GEOIP,lan,DIRECT,no-resolve","MATCH,DIRECT"]})
}
#[test]
fn company_rules_restrict_ports_tcp_and_preserve_auto_route() {
    let b = base();
    let p = company::compile(
        b.clone(),
        1080,
        "COMPANY-0123456789abcdef",
        &json!([{"address":"192.168.0.0/24","ports":"80,443","network":"all"}]),
    )
    .unwrap();
    assert_eq!(p.rule_count, 2);
    assert_eq!(p.routes, ["192.168.0.0/24"]);
    assert!(p.config["tun"]["route-address"].is_null());
    assert_eq!(
        p.config["rules"][0],
        "AND,((NETWORK,TCP),(IP-CIDR,192.168.0.0/24,no-resolve),(DST-PORT,80)),COMPANY-0123456789abcdef"
    );
    assert_eq!(
        p.config["rules"][2],
        "IP-CIDR,192.168.0.0/24,REJECT,no-resolve"
    );
    assert_eq!(
        p.config["rules"].as_array().unwrap().last().unwrap(),
        "MATCH,DIRECT"
    );
    assert_eq!(b["tun"]["route-exclude-address"][1], "192.168.0.0/16");
}
#[test]
fn subtract_company_routes_keeps_rest_of_lan() {
    let excluded = vec!["192.168.0.0/16".into(), "10.0.0.0/8".into()];
    let v = company::subtract_routes(&excluded, &["192.168.0.0/24".into()]).unwrap();
    assert!(v.contains(&"10.0.0.0/8".into()));
    assert!(!v.contains(&"192.168.0.0/16".into()));
    let count: u64 = v
        .iter()
        .filter(|s| s.starts_with("192."))
        .map(|s| 1u64 << (32 - s.split('/').nth(1).unwrap().parse::<u32>().unwrap()))
        .sum();
    assert_eq!(count, 65536 - 256);
}
#[test]
fn company_missing_ports_udp_only_and_invalid_targets_are_rejected() {
    for rows in [
        json!([{"address":"192.168.1.1","ports":"","network":"tcp"}]),
        json!([{"address":"192.168.1.1","ports":"53","network":"udp"}]),
        json!([{"address":"127.0.0.1","ports":"80","network":"tcp"}]),
    ] {
        assert!(company::compile(base(), 1080, "COMPANY-01234567", &rows).is_err());
    }
    assert!(company::business_target("http://example.com/?token=x").is_err());
    assert!(company::business_target("ftp://example.com").is_err());
}
fn write_geodata(s: &Storage) {
    std::fs::create_dir_all(s.path("mihomo")).unwrap();
    for name in ["GeoSite.dat", "country.mmdb", "geoip.metadb"] {
        std::fs::write(s.path(&format!("mihomo/{name}")), b"geo").unwrap();
    }
}
#[test]
fn geo_fallback_shapes_mihomo_rules_when_geodata_is_missing() {
    let d = tempfile::tempdir().unwrap();
    let s = Storage::new(d.path().into());
    provider(&s, "one", "node", "r1");
    let mut settings = s.settings().unwrap();
    settings["selectedProxy"] = json!("node");
    settings["unknownTraffic"] = json!("direct");
    let rules = |c: &Value| c["rules"].as_array().unwrap().clone();

    // Default: mainland list stays direct, everything else goes through VPN.
    let c = config::build(&s, &settings, 7894, 9094, None, false).unwrap();
    assert!(rules(&c).contains(&json!("DOMAIN-SUFFIX,baidu.com,DIRECT")));
    assert!(
        !rules(&c)
            .iter()
            .any(|r| r.as_str().unwrap().starts_with("GEOSITE"))
    );
    assert_eq!(rules(&c).last().unwrap(), "MATCH,VPN");
    assert_eq!(
        c["dns"]["nameserver-policy"]["+.baidu.com"][0],
        "https://dns.alidns.com/dns-query"
    );

    // follow-default: no geo rules, unmatched traffic follows unknownTraffic.
    settings["geoFallback"] = json!("follow-default");
    let c = config::build(&s, &settings, 7894, 9094, None, false).unwrap();
    assert!(
        !rules(&c)
            .iter()
            .any(|r| r.as_str().unwrap().starts_with("DOMAIN-SUFFIX")
                && r.as_str().unwrap().ends_with(",DIRECT"))
    );
    assert_eq!(rules(&c).last().unwrap(), "MATCH,DIRECT");
    assert!(c["dns"]["nameserver-policy"].is_null());

    // block: refuse to build until the geodata is present.
    settings["geoFallback"] = json!("block");
    assert!(config::build(&s, &settings, 7894, 9094, None, false).is_err());
    write_geodata(&s);
    let c = config::build(&s, &settings, 7894, 9094, None, false).unwrap();
    assert!(rules(&c).contains(&json!("GEOSITE,cn,DIRECT")));
    assert_eq!(rules(&c).last().unwrap(), "MATCH,DIRECT");
}
#[test]
fn config_keeps_domestic_before_quic_and_uses_manifest_files() {
    let d = tempfile::tempdir().unwrap();
    let s = Storage::new(d.path().into());
    provider(&s, "one", "node", "r1");
    write_geodata(&s);
    let mut settings = s.settings().unwrap();
    settings["selectedProxy"] = json!("node");
    let c = config::build(&s, &settings, 7894, 9094, Some("en16"), false).unwrap();
    assert_eq!(c["proxy-providers"]["one"]["type"], "file");
    assert!(c["proxy-providers"]["one"]["url"].is_null());
    assert_eq!(c["interface-name"], "en16");
    let rules = c["rules"].as_array().unwrap();
    assert!(
        rules.iter().position(|r| r == "GEOSITE,cn,DIRECT").unwrap()
            < rules.iter().position(|r| r == config::QUIC_REJECT).unwrap()
    );
}
#[test]
fn explicit_outlets_precede_geo_and_direct_rules_bypass_vpn_quic_guards() {
    let d = tempfile::tempdir().unwrap();
    let s = Storage::new(d.path().into());
    provider(&s, "one", "node", "r1");
    write_geodata(&s);
    let mut settings = s.settings().unwrap();
    settings["selectedProxy"] = json!("node");
    settings["unknownTraffic"] = json!("vpn");
    settings["vpnDomainRules"] = json!(["DOMAIN-SUFFIX,example.test", "IP-CIDR,192.0.2.0/24"]);
    settings["directDomainRules"] = json!(["DOMAIN,api.example.test", "IP-CIDR6,2001:db8::/32"]);
    let c = config::build(&s, &settings, 7894, 9094, None, false).unwrap();
    let rules = c["rules"].as_array().unwrap();
    let at = |value: &str| rules.iter().position(|r| r == value).unwrap();
    assert!(at("DOMAIN,api.example.test,DIRECT") < at(config::QUIC_RULES_REJECT));
    assert!(at(config::QUIC_RULES_REJECT) < at("RULE-SET,vpn-domains,VPN"));
    assert!(at("RULE-SET,vpn-domains,VPN") < at("GEOSITE,cn,DIRECT"));
    assert!(at("GEOSITE,cn,DIRECT") < at(config::QUIC_REJECT));
    assert!(rules.contains(&json!("IP-CIDR6,2001:db8::/32,DIRECT,no-resolve")));
    assert_eq!(rules.last().unwrap(), "MATCH,VPN");
}
#[test]
fn node_group_connections_stay_disabled() {
    let d = tempfile::tempdir().unwrap();
    let mut c = core(&d);
    for channel in [
        "native:group-connect",
        "native:group-disconnect",
        "node-groups:select",
    ] {
        assert!(c.handle(channel, &json!({"groupId":"x"})).is_err());
    }
    assert!(
        c.handle("nodes:select", &json!({"nodeName":"AUTO"}))
            .is_err()
    );
}
#[test]
fn redaction_hides_credentials_in_url_paths_and_queries() {
    let out =
        redact("failed https://example.com/sub/SECRET?api-key=KEY password=PASSWORD token=TOKEN");
    for secret in ["SECRET", "KEY", "PASSWORD", "TOKEN"] {
        assert!(!out.contains(secret));
    }
    assert!(out.contains("example.com"));
}
#[test]
fn interrupted_transaction_restores_prior_files() {
    let d = tempfile::tempdir().unwrap();
    let s = Storage::new(d.path().into());
    let original = "{\"settingsVersion\":10,\"selectedProxy\":\"DIRECT\"}";
    atomic_write(&s.path("settings.json"), b"changed").unwrap();
    s.write(
        "runtime-state/rust-pending.json",
        &json!({"ownerPid":99999999,"files":{"settings.json":original}}),
    )
    .unwrap();
    let mut c = core(&d);
    assert!(c.handle("native:bootstrap", &json!({})).is_ok());
    assert_eq!(
        fs::read_to_string(s.path("settings.json")).unwrap(),
        original
    );
    assert!(!s.path("runtime-state/rust-pending.json").exists());
}
#[test]
fn risk_key_is_never_saved_to_disk() {
    let d = tempfile::tempdir().unwrap();
    let mut c = core(&d);
    assert_eq!(
        c.handle("native:risk-key", &json!({"apiKey":"private-key"}))
            .unwrap()["configured"],
        true
    );
    assert!(!c.engine.store.path("secrets.json").exists());
    assert!(!c.engine.store.path("settings.json").exists());
}

#[test]
fn risk_thresholds_match_existing_client() {
    use splitvpn_core::runtime::risk_result;
    let evaluate = |v: Value| risk_result("node", &v)["riskLevel"].clone();
    assert_eq!(
        evaluate(json!({"threat":{"is_proxy":false},"scores":{"trust_score":61,"vpn_score":99}})),
        "low"
    );
    assert_eq!(evaluate(json!({"scores":{"trust_score":60}})), "medium");
    assert_eq!(evaluate(json!({"scores":{"trust_score":39}})), "high");
    assert_eq!(
        evaluate(json!({"threat":{"is_tor":true,"is_datacenter":true}})),
        "high"
    );
    assert_eq!(evaluate(json!({"threat":{"unexpected":true}})), "unknown");
    assert_eq!(evaluate(json!({"threat":{"is_proxy":true}})), "medium");
    assert_eq!(
        evaluate(json!({"threat":{"scores":{"trust_score":55}}})),
        "medium"
    );
}

#[test]
fn notices_in_yaml_are_not_reported_as_real_nodes() {
    let n = subscription::parse_provider("proxies:\n- {name: 请升级客户端版本太旧, type: ss, server: 127.0.0.1, port: 1}\n- {name: real, type: ss, server: example.com, port: 443}\n").unwrap();
    assert_eq!(n.len(), 1);
    assert_eq!(n[0]["name"], "real");
}

#[test]
fn geodata_preserves_downloaded_updates() {
    let d = tempfile::tempdir().unwrap();
    let resources = tempfile::tempdir().unwrap();
    atomic_write(&resources.path().join("geodata/GeoSite.dat"), b"bundled").unwrap();
    atomic_write(&d.path().join("mihomo/GeoSite.dat"), b"newer-download").unwrap();
    let c = Core::new(
        d.path().into(),
        resources.path().into(),
        true,
        Arc::new(|_, _| {}),
        Arc::new(Jobs::default()),
    )
    .unwrap();
    c.engine.prepare_geodata().unwrap();
    assert_eq!(
        fs::read(d.path().join("mihomo/GeoSite.dat")).unwrap(),
        b"newer-download"
    );
    fs::remove_file(d.path().join("mihomo/GeoSite.dat")).unwrap();
    c.engine.prepare_geodata().unwrap();
    assert_eq!(
        fs::read(d.path().join("mihomo/GeoSite.dat")).unwrap(),
        b"bundled"
    );
}

#[cfg(unix)]
fn desktop_start_fixture(
    data: &tempfile::TempDir,
    resources: &tempfile::TempDir,
    settings: &Value,
) -> Core {
    use std::os::unix::fs::PermissionsExt;
    let binary = resources.path().join("mihomo");
    // Validation deliberately fails before an engine can start or touch the network.
    fs::write(
        &binary,
        b"#!/bin/sh\necho 'fixture validation stop' >&2\nexit 1\n",
    )
    .unwrap();
    fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).unwrap();
    let store = Storage::new(data.path().into());
    store.write("settings.json", settings).unwrap();
    provider(&store, "one", "node", "fixture");
    Core::new(
        data.path().into(),
        resources.path().into(),
        true,
        Arc::new(|_, _| {}),
        Arc::new(Jobs::default()),
    )
    .unwrap()
}

#[cfg(unix)]
#[test]
fn desktop_first_connection_stages_geo_before_generating_rules() {
    for channel in ["vpn:start", "native:startup-connect"] {
        for fallback in [
            config::BLOCK,
            config::CN_DIRECT_ELSE_VPN,
            config::FOLLOW_DEFAULT,
        ] {
            let data = tempfile::tempdir().unwrap();
            let resources = tempfile::tempdir().unwrap();
            for name in ["GeoSite.dat", "country.mmdb", "geoip.metadb"] {
                atomic_write(&resources.path().join("geodata").join(name), b"bundled").unwrap();
            }
            let mut c = desktop_start_fixture(
                &data,
                &resources,
                &json!({"settingsVersion":10,"selectedProxy":"node","unknownTraffic":"direct","geoFallback":fallback}),
            );
            let before = fs::read(c.engine.store.path("settings.json")).unwrap();
            let error = c.handle(channel, &json!({})).unwrap_err();
            assert!(
                error.to_string().contains("fixture validation stop"),
                "{channel}, {fallback}: {error}"
            );
            assert!(c.engine.pid.is_none());
            assert!(config::geo_ready(&c.engine.store));
            let generated = config::parse(
                &fs::read_to_string(c.engine.store.path("mihomo/config.yaml")).unwrap(),
            )
            .unwrap();
            let rules = generated["rules"].as_array().unwrap();
            assert!(rules.contains(&json!("GEOSITE,cn,DIRECT")));
            assert!(rules.contains(&json!("GEOIP,CN,DIRECT")));
            assert_eq!(rules.last().unwrap(), "MATCH,DIRECT");
            assert_eq!(
                fs::read(c.engine.store.path("settings.json")).unwrap(),
                before
            );
        }
    }
}

#[cfg(unix)]
#[test]
fn desktop_start_without_geo_honors_the_saved_fallback() {
    for (fallback, unknown, expected) in [
        (config::CN_DIRECT_ELSE_VPN, "direct", Some("MATCH,VPN")),
        (config::FOLLOW_DEFAULT, "direct", Some("MATCH,DIRECT")),
        (config::FOLLOW_DEFAULT, "vpn", Some("MATCH,VPN")),
        (config::BLOCK, "direct", None),
    ] {
        let data = tempfile::tempdir().unwrap();
        let resources = tempfile::tempdir().unwrap();
        let mut c = desktop_start_fixture(
            &data,
            &resources,
            &json!({"settingsVersion":10,"selectedProxy":"node","unknownTraffic":unknown,"geoFallback":fallback}),
        );
        let error = c.handle("vpn:start", &json!({})).unwrap_err();
        assert!(c.engine.pid.is_none());
        assert!(!config::geo_ready(&c.engine.store));
        let path = c.engine.store.path("mihomo/config.yaml");
        if let Some(expected) = expected {
            assert!(
                error.to_string().contains("fixture validation stop"),
                "{error}"
            );
            let generated = config::parse(&fs::read_to_string(path).unwrap()).unwrap();
            let rules = generated["rules"].as_array().unwrap();
            assert_eq!(rules.last().unwrap(), expected);
            assert_eq!(
                rules.contains(&json!("DOMAIN-SUFFIX,baidu.com,DIRECT")),
                fallback == config::CN_DIRECT_ELSE_VPN
            );
        } else {
            assert!(error.to_string().contains("Geo 数据不可用"), "{error}");
            assert!(!path.exists());
        }
    }
}

#[test]
fn physical_interface_filter_rejects_virtual_interfaces() {
    for name in ["lo0", "utun7", "tap0", "bridge100", "awdl0"] {
        assert!(!splitvpn_core::platform::is_physical_interface(name));
    }
    assert!(splitvpn_core::platform::is_physical_interface("en16"));
}

#[test]
fn uri_content_keeps_mihomo_specific_options_and_explicit_tls() {
    let raw =
        "vless://user@example.com:443?security=reality&type=grpc&serviceName=kept&pbk=key#node\n";
    assert_eq!(subscription::prepare_content(raw).unwrap(), raw);
    let anytls = "anytls://secret@example.com?allowInsecure=1&insecure=0#node";
    assert_eq!(subscription::prepare_content(anytls).unwrap(), anytls);
    let alias =
        subscription::prepare_content("anytls://secret@example.com?allowInsecure=0#node").unwrap();
    assert!(alias.contains("insecure=0"));
    assert!(alias.contains("secret@"));
}

#[test]
fn settings_outlet_and_group_identity_match_legacy_schema() {
    let v=normalize_settings(json!({"settingsVersion":10,"selectedProxy":"node","favoriteNodeNames":[" kept ","kept",4],"nodeGroups":[{"id":"group","name":"常用","nodeNames":["node"]}]})).unwrap();
    assert_eq!(v["defaultOutlet"]["kind"], "node");
    assert_eq!(v["defaultOutlet"]["name"], "node");
    assert_eq!(v["favoriteNodeNames"], json!(["kept"]));
    let mut next = v.clone();
    next["selectedProxy"] = json!(splitvpn_core::storage::group_runtime_name("group"));
    assert_eq!(
        normalize_settings(next).unwrap()["defaultOutlet"]["groupId"],
        "group"
    );
}

#[test]
fn runtime_reserved_names_cannot_be_selected_as_provider_nodes() {
    let d = tempfile::tempdir().unwrap();
    let mut c = core(&d);
    provider(&c.engine.store, "one", "VPN", "r1");
    let node = c.nodes().unwrap().remove(0);
    assert_eq!(node["identityAmbiguous"], true);
    assert!(
        c.handle(
            "nodes:select-v2",
            &json!({"identityKey":node["identityKey"]})
        )
        .is_err()
    );
}

#[test]
fn recovery_ledger_is_compatible_and_confirmation_does_not_clear_it() {
    let d = tempfile::tempdir().unwrap();
    let mut c = core(&d);
    c.engine.store.set_recovery(true, Some("fixture")).unwrap();
    let state = c.engine.store.recovery().unwrap();
    assert_eq!(state["schemaVersion"], 1);
    assert_eq!(state["stateRevision"], 1);
    assert_eq!(
        fs::read_to_string(c.engine.store.path("runtime-state/recovery-state-sequence")).unwrap(),
        "1\n"
    );
    let token = c.handle("runtime:prepare-recovery", &json!({})).unwrap();
    let confirmed = c
        .handle("runtime:confirm-recovery", &json!({"token":token["token"]}))
        .unwrap();
    assert_eq!(confirmed["state"], "required");
    assert!(
        c.handle("runtime:confirm-recovery", &json!({"token":token["token"]}))
            .is_err()
    );
    assert!(
        !c.engine
            .store
            .path("runtime-state/rust-recovery-token.json")
            .exists()
    );
}

#[test]
fn corrupt_recovery_state_is_read_only_and_blocks_start() {
    let d = tempfile::tempdir().unwrap();
    let mut c = core(&d);
    atomic_write(
        &c.engine.store.path("runtime-state/recovery-state.json"),
        b"invalid",
    )
    .unwrap();
    assert_eq!(c.engine.store.recovery().unwrap()["state"], "required");
    assert!(c.handle("vpn:start", &json!({})).is_err());
    assert_eq!(
        fs::read(c.engine.store.path("runtime-state/recovery-state.json")).unwrap(),
        b"invalid"
    );
}

#[test]
fn backend_lock_excludes_another_backend_without_unlink_races() {
    let d = tempfile::tempdir().unwrap();
    let s = Storage::new(d.path().into());
    let lock = splitvpn_core::platform::BackendLock::acquire(&s).unwrap();
    assert!(splitvpn_core::platform::BackendLock::acquire(&s).is_err());
    drop(lock);
    assert!(splitvpn_core::platform::BackendLock::acquire(&s).is_ok());
}
#[test]
fn controller_requests_follow_the_running_engine_secret() {
    use std::io::{Read, Write};
    let dir = tempfile::tempdir().unwrap();
    let mut c = core(&dir);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = std::thread::spawn(move || {
        let mut seen = Vec::new();
        for _ in 0..3 {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0u8; 4096];
            let n = stream.read(&mut buffer).unwrap();
            let head = String::from_utf8_lossy(&buffer[..n]).to_ascii_lowercase();
            let ok = head.contains("authorization: bearer fixture-secret");
            seen.push(ok);
            let (status, body) = if ok {
                ("200 OK", r#"{"version":"fixture"}"#)
            } else {
                ("401 Unauthorized", r#"{"message":"Unauthorized"}"#)
            };
            write!(stream, "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
        }
        seen
    });
    c.engine.controller = port;
    atomic_write(
        &c.engine.store.path("mihomo/config.yaml"),
        b"secret: fixture-secret\n",
    )
    .unwrap();
    // The first request is rejected unapplied, then retried with the secret.
    assert_eq!(
        c.engine.api("GET", "/version", None).unwrap()["version"],
        "fixture"
    );
    assert_eq!(
        c.engine.api("GET", "/version", None).unwrap()["version"],
        "fixture"
    );
    assert_eq!(server.join().unwrap(), vec![false, true, true]);
}
#[test]
fn controller_secret_is_private_and_stable() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let store = Storage::new(dir.path().into());
    let first = store.controller_secret().unwrap();
    assert_eq!(first.len(), 64);
    assert_eq!(store.controller_secret().unwrap(), first);
    let mode = fs::metadata(store.path("runtime-state/controller-secret"))
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600);
}
#[test]
fn background_update_commits_results_downloaded_outside_the_lock() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = core(&dir);
    // A URL that must not be contacted: the prefetched result is used instead.
    let url = "http://127.0.0.1:9/prefetched";
    c.engine
        .store
        .write(
            "subscription.json",
            &json!({"entries":[{"id":"a","url":url,"enabled":true,"updateIntervalMinutes":60,"nodeCount":3,"status":"ready"}]}),
        )
        .unwrap();
    c.apply_downloaded_subscriptions(vec![(
        "a".into(),
        url.into(),
        Err(anyhow::anyhow!("fixture prefetch failed")),
    )]);
    let r = c.engine.store.subscription().unwrap();
    assert_eq!(r["entries"][0]["lastError"], "fixture prefetch failed");
    // Earlier committed nodes are kept when a background download fails.
    assert_eq!(r["entries"][0]["nodeCount"], 3);
}
#[test]
fn background_result_is_dropped_after_a_newer_update() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = core(&dir);
    let url = "http://127.0.0.1:9/prefetched";
    // Updated just now (e.g. manually) while the background download was running.
    c.engine
        .store
        .write(
            "subscription.json",
            &json!({"entries":[{"id":"a","url":url,"enabled":true,"updateIntervalMinutes":60,"nodeCount":3,"status":"ready","updatedAt":chrono::Utc::now().to_rfc3339()}]}),
        )
        .unwrap();
    c.apply_downloaded_subscriptions(vec![(
        "a".into(),
        url.into(),
        Err(anyhow::anyhow!("stale background result")),
    )]);
    let r = c.engine.store.subscription().unwrap();
    assert!(r["entries"][0]["lastError"].is_null());
    assert_eq!(r["entries"][0]["nodeCount"], 3);
}
#[test]
fn shadowsocks_link_keeps_explicit_port_80() {
    let nodes = splitvpn_core::subscription::parse_provider(
        "ss://aes-128-gcm:pwd@1.2.3.4:80#a\nss://aes-128-gcm:pwd@1.2.3.4:8388#b",
    )
    .unwrap();
    assert_eq!(nodes[0]["port"], 80);
    assert_eq!(nodes[1]["port"], 8388);
}

#[test]
fn manual_result_is_discarded_after_url_edit_or_newer_request() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = core(&dir);
    let saved = c
        .handle(
            "subscription:save",
            &json!({"url":"https://old.example.test/sub"}),
        )
        .unwrap();
    let id = saved["entries"][0]["id"].as_str().unwrap().to_owned();
    let plan = c.begin_manual_update(&json!({"id":id})).unwrap();
    let new = c
        .handle(
            "subscription:save",
            &json!({"id":id,"url":"http://127.0.0.1:9/must-not-download"}),
        )
        .unwrap();
    let discarded = c
        .finish_manual_update(
            plan,
            vec![(
                id.clone(),
                "https://old.example.test/sub".into(),
                Err(anyhow::anyhow!("stale failed request")),
            )],
        )
        .unwrap();
    assert_eq!(discarded, new);
    let old = c.begin_manual_update(&json!({"id":id})).unwrap();
    let _new = c.begin_manual_update(&json!({"id":id})).unwrap();
    let before = fs::read(c.engine.store.path("subscription.json")).unwrap();
    c.finish_manual_update(
        old,
        vec![(
            id,
            "http://127.0.0.1:9/must-not-download".into(),
            Err(anyhow::anyhow!("older failed request")),
        )],
    )
    .unwrap();
    assert_eq!(
        fs::read(c.engine.store.path("subscription.json")).unwrap(),
        before
    );
}

#[test]
fn background_result_does_not_overwrite_a_pending_manual_request() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = core(&dir);
    let url = "http://127.0.0.1:9/no-download";
    let saved = c.handle("subscription:save", &json!({"url":url})).unwrap();
    let id = saved["entries"][0]["id"].as_str().unwrap().to_owned();
    let manual = c.begin_manual_update(&json!({"id":id})).unwrap();
    let before = fs::read(c.engine.store.path("subscription.json")).unwrap();
    c.apply_downloaded_subscriptions(vec![(
        id.clone(),
        url.into(),
        Err(anyhow::anyhow!("old automatic result")),
    )]);
    assert_eq!(
        fs::read(c.engine.store.path("subscription.json")).unwrap(),
        before
    );
    c.finish_manual_update(
        manual,
        vec![(
            id,
            url.into(),
            Err(anyhow::anyhow!("current manual result")),
        )],
    )
    .unwrap();
    assert_eq!(
        c.engine.store.subscription().unwrap()["entries"][0]["lastError"],
        "current manual result"
    );
}

#[test]
fn background_result_with_changed_url_is_dropped_without_network_io() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = core(&dir);
    let old = "https://old.example.test/sub";
    let saved = c.handle("subscription:save", &json!({"url":old})).unwrap();
    let id = saved["entries"][0]["id"].as_str().unwrap().to_owned();
    c.handle(
        "subscription:save",
        &json!({"id":id,"url":"http://127.0.0.1:9/must-not-download"}),
    )
    .unwrap();
    let before = fs::read(c.engine.store.path("subscription.json")).unwrap();
    c.apply_downloaded_subscriptions(vec![(
        id,
        old.into(),
        Err(anyhow::anyhow!("old URL result")),
    )]);
    assert_eq!(
        fs::read(c.engine.store.path("subscription.json")).unwrap(),
        before
    );
}
#[test]
fn app_log_rotates_at_four_megabytes() {
    let dir = tempfile::tempdir().unwrap();
    let c = core(&dir);
    let log = c.engine.store.path("logs/app.log");
    fs::create_dir_all(log.parent().unwrap()).unwrap();
    fs::write(&log, vec![b'x'; 4 * 1024 * 1024]).unwrap();
    c.log("info", "after rotation");
    assert_eq!(
        fs::metadata(c.engine.store.path("logs/app.log.1"))
            .unwrap()
            .len(),
        4 * 1024 * 1024
    );
    assert!(fs::read_to_string(&log).unwrap().contains("after rotation"));
}

#[test]
fn windows_default_route_ignores_language_on_link_and_tun_rows() {
    // Chinese-locale `route print -4 0.0.0.0`; the TUN and persistent rows must lose.
    let text = "===========================================================================\n\
IPv4 路由表\n\
===========================================================================\n\
活动路由:\n\
网络目标        网络掩码          网关       接口   跃点数\n\
          0.0.0.0          0.0.0.0      192.168.1.1    192.168.1.23     35\n\
          0.0.0.0          0.0.0.0     10.0.0.1         10.0.0.8        25\n\
          0.0.0.0          0.0.0.0         在链路上       198.18.0.1      0\n\
          0.0.0.0          0.0.0.0      198.18.0.2       198.18.0.1      1\n\
永久路由:\n\
  网络地址          网络掩码  网关地址  跃点数\n\
          0.0.0.0          0.0.0.0      172.16.0.1  默认\n";
    assert_eq!(
        splitvpn_core::platform::windows_default_route(text),
        Some(("10.0.0.1".into(), "10.0.0.8".into()))
    );
    assert_eq!(
        splitvpn_core::platform::windows_default_route("无路由\n"),
        None
    );
}
#[test]
fn settings_channels_reject_fields_they_do_not_own() {
    let d = tempfile::tempdir().unwrap();
    let mut c = core(&d);
    let settings = c.engine.store.path("settings.json");
    assert!(
        c.handle("native:preferences", &json!({"selectedProxy":"elsewhere"}))
            .is_err()
    );
    assert!(c.handle("routing:update", &json!({"tun":false})).is_err());
    assert!(!settings.exists());
    let saved = c
        .handle("native:preferences", &json!({"lanDirect":false}))
        .unwrap();
    assert_eq!(saved["lanDirect"], false);
    assert!(
        c.handle("native:preferences", &json!({"lanDirect":"no"}))
            .is_err()
    );
}
#[test]
fn prune_keeps_only_committed_provider_revisions() {
    let d = tempfile::tempdir().unwrap();
    let s = Storage::new(d.path().into());
    let current = "a".repeat(64);
    provider(&s, "one", "node", &current);
    let stale = s.path(&format!("mihomo/providers/one.{}.yaml", "b".repeat(64)));
    let legacy = s.path("mihomo/providers/one.yaml");
    let rules = s.path("mihomo/providers/vpn-domains.yaml");
    for path in [&stale, &legacy, &rules] {
        atomic_write(path, b"payload: []\n").unwrap();
    }
    subscription::prune_providers(&s).unwrap();
    assert!(!stale.exists());
    assert!(legacy.exists() && rules.exists());
    assert!(
        s.path(&format!("mihomo/providers/one.{current}.yaml"))
            .exists()
    );
}
#[test]
fn probe_inbound_uses_its_own_selector_over_the_vpn_providers() {
    let d = tempfile::tempdir().unwrap();
    let s = Storage::new(d.path().into());
    provider(&s, "one", "node", "r1");
    let settings = s.settings().unwrap();
    let mut c = config::build(&s, &settings, 7894, 9094, None, false).unwrap();
    config::add_probe(&mut c, 7899);
    let probe = c["proxy-groups"]
        .as_array()
        .unwrap()
        .iter()
        .find(|g| g["name"] == config::PROBE)
        .unwrap();
    assert_eq!(probe["use"], json!(["one"]));
    assert_eq!(c["listeners"][0]["proxy"], config::PROBE);
    assert_eq!(c["listeners"][0]["listen"], "127.0.0.1");
    assert_eq!(config::probe_port(&c), Some(7899));
    // Rules never reference the probe selector, so user traffic cannot reach it.
    assert!(
        c["rules"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| !r.as_str().unwrap().ends_with(",PROBE"))
    );
}
