use serde_json::json;
use splitvpn_core::{
    Core, Jobs, routing,
    storage::{Storage, normalize_rule, normalize_settings},
};
use std::{fs, path::PathBuf, sync::Arc};

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
fn addresses_urls_and_networks_have_unambiguous_matchers() {
    for (input, expected) in [
        (" Example.TEST. ", "DOMAIN-SUFFIX,example.test"),
        (
            "https://api.example.test:8443/path?q=1",
            "DOMAIN-SUFFIX,api.example.test",
        ),
        ("192.0.2.8", "IP-CIDR,192.0.2.8/32"),
        ("192.0.2.8/24", "IP-CIDR,192.0.2.0/24"),
        ("192.0.2.8/0", "IP-CIDR,0.0.0.0/0"),
        ("2001:db8::8", "IP-CIDR6,2001:db8::8/128"),
        ("2001:db8::8/32", "IP-CIDR6,2001:db8::/32"),
        ("[2001:db8::8]", "IP-CIDR6,2001:db8::8/128"),
        ("[2001:db8::8]/32", "IP-CIDR6,2001:db8::/32"),
        ("https://[2001:db8::8]/path", "IP-CIDR6,2001:db8::8/128"),
        ("DOMAIN,API.EXAMPLE.TEST", "DOMAIN,api.example.test"),
        ("DOMAIN-SUFFIX,192.0.2.8", "IP-CIDR,192.0.2.8/32"),
    ] {
        assert_eq!(normalize_rule(input).as_deref(), Some(expected), "{input}");
    }
    assert_eq!(
        routing::normalize_input(&json!({"kind":"DOMAIN","rule":"https://api.example.test/path"}))
            .unwrap()["rule"],
        "DOMAIN,api.example.test"
    );
}

#[test]
fn malformed_addresses_and_policy_injection_are_rejected() {
    for input in [
        "",
        "192.0.2.8/33",
        "999.1.1.1",
        "2001:db8::/129",
        "[2001:db8::8]/129",
        "IP-CIDR6,192.0.2.0/24",
        "IP-CIDR,2001:db8::/32",
        "https://user:secret@example.test/path",
        "ftp://example.test",
        "example.test/path",
        "DOMAIN,example.test,DIRECT",
        "DOMAIN-KEYWORD,one\nMATCH,DIRECT",
        "example.test\nother.test",
    ] {
        assert!(normalize_rule(input).is_none(), "{input}");
    }
    assert!(routing::normalize_input(&json!({"kind":"ip","rule":"example.test"})).is_err());
}

#[test]
fn existing_settings_and_unknown_fields_survive_the_new_direct_list() {
    let settings = normalize_settings(json!({"settingsVersion":10,"vpnDomainRules":["DOMAIN,example.test","GEOSITE,netflix"],"futureSetting":{"keep":true}})).unwrap();
    assert_eq!(
        settings["vpnDomainRules"],
        json!(["DOMAIN,example.test", "GEOSITE,netflix"])
    );
    assert_eq!(settings["directDomainRules"], json!([]));
    assert_eq!(settings["futureSetting"]["keep"], true);
}

#[test]
fn legacy_add_and_atomic_outlet_edits_preserve_other_rules() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = core(&dir);
    let original = c.engine.store.settings().unwrap()["vpnDomainRules"].clone();
    let saved = c
        .handle("routing:add-rule", &json!({"rule":"example.test"}))
        .unwrap();
    assert!(
        saved["vpnDomainRules"]
            .as_array()
            .unwrap()
            .contains(&json!("DOMAIN-SUFFIX,example.test"))
    );
    let moved = c.handle("routing:edit-rule", &json!({"rule":"https://example.test/path","target":"direct","originalRule":"DOMAIN-SUFFIX,example.test","originalTarget":"vpn"})).unwrap();
    assert_eq!(moved["vpnDomainRules"], original);
    assert_eq!(
        moved["directDomainRules"],
        json!(["DOMAIN-SUFFIX,example.test"])
    );
    c.handle(
        "routing:add-rule",
        &json!({"rule":"example.test","target":"vpn"}),
    )
    .unwrap();
    assert_eq!(
        c.engine.store.settings().unwrap()["directDomainRules"],
        json!([])
    );
    c.handle("routing:delete-rule", &json!({"rule":"example.test"}))
        .unwrap();
    assert_eq!(
        c.engine.store.settings().unwrap()["vpnDomainRules"],
        original
    );
}

#[test]
fn invalid_and_stale_edits_keep_the_saved_bytes() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = core(&dir);
    c.handle(
        "routing:add-rule",
        &json!({"rule":"192.0.2.0/24","target":"direct"}),
    )
    .unwrap();
    let path = c.engine.store.path("settings.json");
    let before = fs::read(&path).unwrap();
    for p in [
        json!({"rule":"999.0.0.1","target":"direct"}),
        json!({"rule":"example.test","target":"invalid"}),
    ] {
        assert!(c.handle("routing:add-rule", &p).is_err());
    }
    assert!(c.handle("routing:edit-rule", &json!({"rule":"example.test","target":"vpn","originalRule":"DOMAIN,missing.test","originalTarget":"direct"})).is_err());
    assert!(
        c.handle(
            "routing:update",
            &json!({"directDomainRules":["bad/address"]})
        )
        .is_err()
    );
    assert_eq!(fs::read(path).unwrap(), before);
}

#[test]
fn custom_match_diagnosis_handles_subdomains_ipv6_and_direct_overlaps() {
    let settings = normalize_settings(json!({"settingsVersion":10,"vpnDomainRules":["DOMAIN-SUFFIX,example.test","IP-CIDR,192.0.2.0/24"],"directDomainRules":["DOMAIN,api.example.test","IP-CIDR6,2001:db8::/32"]})).unwrap();
    for (host, policy) in [
        ("https://API.example.test/path", "直连"),
        ("other.example.test", "VPN"),
        ("badexample.test", "由国内外自动分流或未命中策略决定"),
        ("192.0.2.8", "VPN"),
        ("2001:db8::8", "直连"),
        ("[2001:db8::8]", "直连"),
    ] {
        assert_eq!(
            routing::diagnose(&settings, host).unwrap()["policy"],
            policy
        );
    }
    let result = routing::diagnose(&settings, "api.example.test").unwrap();
    assert_eq!(result["matchedVpnRules"].as_array().unwrap().len(), 1);
    assert_eq!(result["matchedDirectRules"].as_array().unwrap().len(), 1);
}

#[test]
fn normalization_and_diagnosis_do_not_write_user_files() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = core(&dir);
    c.handle("routing:normalize-rule", &json!({"rule":"example.test"}))
        .unwrap();
    c.handle("routing:diagnose", &json!({"target":"example.test"}))
        .unwrap();
    assert!(
        !Storage::new(dir.path().into())
            .path("settings.json")
            .exists()
    );
    assert!(!dir.path().join("mihomo/config.yaml").exists());
}
