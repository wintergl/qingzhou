use serde_json::{Value, json};
use splitvpn_core::{mobile, storage::Storage};
fn request(dir: &tempfile::TempDir, channel: &str, payload: Value) -> Value {
    serde_json::from_str(&mobile::call(
        dir.path().to_str().unwrap(),
        &json!({"channel":channel,"payload":payload}).to_string(),
    ))
    .unwrap()
}
fn call(dir: &tempfile::TempDir, channel: &str, payload: Value) -> Value {
    let r = request(dir, channel, payload);
    assert_eq!(r["ok"], true, "{r}");
    r["data"].clone()
}
fn fixture() -> (tempfile::TempDir, Value) {
    let dir = tempfile::tempdir().unwrap();
    let record = json!({"enabled":true,"origin":"https://vpn.example.test","username":"fixture","domain":"local","fingerprint":"ab".repeat(32),"resources":[{"name":"测试业务","address":"10.0.0.8/32","ports":"443,8000-8010","network":"tcp"},{"name":"内网域名","address":"*.internal.example.test","ports":"443","network":"all"}]});
    call(&dir, "company:mobile:configure", record.clone());
    call(&dir, "settings:patch", json!({"selectedProxy":"DIRECT"}));
    (dir, record)
}
#[test]
fn company_metadata_is_atomic_and_rejects_secrets_and_widened_grants() {
    let (dir, _) = fixture();
    let path = dir.path().join("mobile-company.json");
    let before = std::fs::read(&path).unwrap();
    for p in [
        json!({"password":"never-store"}),
        json!({"session":{"SID":"never-store"}}),
        json!({"origin":"http://vpn.example.test"}),
        json!({"resources":[{"address":"0.0.0.0/0","ports":"all","network":"tcp"}]}),
        json!({"resources":[{"address":"10.0.0.8","ports":"","network":"tcp"}]}),
    ] {
        assert_eq!(request(&dir, "company:mobile:configure", p)["ok"], false);
        assert_eq!(std::fs::read(&path).unwrap(), before);
    }
}
#[test]
fn android_keeps_virtual_dns_first_and_blocks_when_backend_is_missing() {
    let (dir, r) = fixture();
    let out = call(&dir, "mihomo:generate", json!({}));
    let c: Value =
        serde_yaml_ng::from_str(&std::fs::read_to_string(out["config"].as_str().unwrap()).unwrap())
            .unwrap();
    let rules = c["rules"].as_array().unwrap();
    assert!(rules[0].as_str().unwrap().contains("172.19.0.2/32"));
    assert!(
        rules
            .iter()
            .any(|v| v.as_str().unwrap().contains("IP-CIDR,10.0.0.8/32")
                && v.as_str().unwrap().ends_with("REJECT"))
    );
    assert!(
        !rules
            .iter()
            .any(|v| v.as_str().unwrap().ends_with(",COMPANY-"))
    );
    let mut transport = r;
    transport["port"] = json!(25000);
    let out = call(&dir, "mihomo:generate", json!({"companyTunnel":transport}));
    let c: Value =
        serde_yaml_ng::from_str(&std::fs::read_to_string(out["config"].as_str().unwrap()).unwrap())
            .unwrap();
    assert!(
        c["rules"].as_array().unwrap().iter().any(|v| v
            .as_str()
            .unwrap()
            .contains("DST-PORT,8000-8010")
            && v.as_str().unwrap().contains("COMPANY-"))
    );
    assert_eq!(c["tun"]["enable"], false);
}
#[test]
fn iphone_requires_exact_config_and_matching_session_before_binding() {
    let (dir, r) = fixture();
    let generated = call(&dir, "singbox:generate", json!({}));
    let c: Value = serde_json::from_str(generated["config"].as_str().unwrap()).unwrap();
    let backend = c["outbounds"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["tag"].as_str().is_some_and(|s| s.starts_with("COMPANY-")))
        .unwrap();
    assert_eq!(backend["type"], "block");
    let mut transport = r;
    transport["port"] = json!(25000);
    let p = json!({"expectedRevision":generated["summary"]["runtimeRevision"],"config":generated["config"],"transport":transport});
    let mut wrong = p.clone();
    wrong["transport"]["username"] = json!("other-user");
    assert_eq!(request(&dir, "company:mobile:bind", wrong)["ok"], false);
    let mut changed = c.clone();
    changed["route"]["final"] = json!("block");
    let mut wrong = p.clone();
    wrong["config"] = json!(changed.to_string());
    assert_eq!(request(&dir, "company:mobile:bind", wrong)["ok"], false);
    let bound = call(&dir, "company:mobile:bind", p.clone());
    let c: Value = serde_json::from_str(bound["config"].as_str().unwrap()).unwrap();
    assert!(
        c["outbounds"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v["type"] == "socks" && v["server_port"] == 25000)
    );
    assert_ne!(
        bound["runtimeRevision"],
        generated["summary"]["runtimeRevision"]
    );
    assert_eq!(request(&dir, "company:mobile:bind", p)["ok"], false);
}
#[test]
fn iphone_authorization_precedes_lan_and_proxy_and_rejects_udp_and_other_ports() {
    let (dir, _) = fixture();
    let generated = call(&dir, "singbox:generate", json!({}));
    let c: Value = serde_json::from_str(generated["config"].as_str().unwrap()).unwrap();
    let rules = c["route"]["rules"].as_array().unwrap();
    let company = rules
        .iter()
        .position(|v| {
            v["outbound"]
                .as_str()
                .is_some_and(|s| s.starts_with("COMPANY-"))
        })
        .unwrap();
    let lan = rules
        .iter()
        .position(|v| v["outbound"] == "direct" && v["ip_cidr"].is_array())
        .unwrap();
    assert!(company < lan);
    assert!(
        rules[company]["rules"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["network"] == json!(["tcp"]))
    );
    assert!(
        rules
            .iter()
            .any(|r| r["action"] == "reject" && r["ip_cidr"] == json!(["10.0.0.8/32"]))
    );
    assert!(
        c["dns"]["rules"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["domain_suffix"] == json!(["internal.example.test"])
                && r["server"] == "fakeip")
    );
}
#[test]
fn authorization_changes_invalidate_diagnostics_without_marking_authenticated() {
    let (dir, _) = fixture();
    let g = call(&dir, "singbox:generate", json!({}));
    let p = json!({"connected":true,"runtimeRevision":g["summary"]["runtimeRevision"],"networkEpoch":"fixture"});
    call(&dir, "company:mobile:configure", json!({"enabled":false}));
    let r = request(&dir, "mobile:diagnostics:cached", p);
    assert_eq!(r["ok"], false);
    let r = call(&dir, "company:mobile:get", json!({}));
    assert!(r.get("authenticated").is_none() && r.get("connected").is_none());
    let store = Storage::new(dir.path().into());
    assert!(
        store
            .read("runtime-state/mobile-profile.json", json!({}))
            .unwrap()["companyKey"]
            .is_string()
    );
}

#[test]
fn iphone_balance_is_a_real_group_and_never_silently_picks_first() {
    let dir = tempfile::tempdir().unwrap();
    let entry = call(
        &dir,
        "subscription:save",
        json!({"url":"https://example.test/sub"}),
    );
    let id = &entry["entries"][0]["id"];
    let plan = call(&dir, "subscription:plan", json!({"id":id}));
    call(
        &dir,
        "subscription:accept",
        json!({"id":id,"token":plan["token"],"index":0,"status":200,"content":"proxies:\n  - {name: A, type: socks5, server: example.test, port: 1080}\n  - {name: B, type: http, server: example.test, port: 1081}\n"}),
    );
    call(&dir, "settings:patch", json!({"selectedProxy":"BALANCE"}));
    let g = call(&dir, "singbox:generate", json!({}));
    let c: Value = serde_json::from_str(g["config"].as_str().unwrap()).unwrap();
    assert_eq!(
        g["summary"]["selectedProxyStatus"],
        "destination-load-balance"
    );
    let group = c["outbounds"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["type"] == "qz-load-balance")
        .unwrap();
    assert_eq!(group["outbounds"].as_array().unwrap().len(), 2);
    assert!(
        !group["outbounds"]
            .as_array()
            .unwrap()
            .contains(&json!("direct"))
    );
}

#[cfg(unix)]
#[test]
fn native_transaction_keeps_lock_until_native_write_finishes() {
    use std::os::fd::AsRawFd;
    use std::sync::mpsc;
    use std::time::Duration;
    let (dir, _) = fixture();
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(dir.path().join(".mobile-transaction.lock"))
        .unwrap();
    assert_eq!(unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) }, 0);
    let reply: Value = serde_json::from_str(&mobile::call(
        dir.path().to_str().unwrap(),
        &json!({"channel":"settings:get","transactionFd":file.as_raw_fd()}).to_string(),
    ))
    .unwrap();
    assert_eq!(reply["ok"], true);
    let (tx, rx) = mpsc::channel();
    let root = dir.path().to_str().unwrap().to_owned();
    let thread = std::thread::spawn(move || {
        let result = mobile::call(&root, &json!({"channel":"settings:get"}).to_string());
        tx.send(result).unwrap()
    });
    assert!(rx.recv_timeout(Duration::from_millis(75)).is_err());
    assert_eq!(unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) }, 0);
    assert!(
        rx.recv_timeout(Duration::from_secs(3))
            .unwrap()
            .contains("\"ok\":true")
    );
    thread.join().unwrap();
    let other = tempfile::tempfile().unwrap();
    let reply: Value = serde_json::from_str(&mobile::call(
        dir.path().to_str().unwrap(),
        &json!({"channel":"settings:get","transactionFd":other.as_raw_fd()}).to_string(),
    ))
    .unwrap();
    assert_eq!(reply["ok"], false);
}

#[test]
fn connection_only_does_not_take_over_resources_or_change_saved_outlet() {
    let (dir, _) = fixture();
    call(&dir, "company:mobile:configure", json!({"enabled":false}));
    call(&dir, "settings:patch", json!({"selectedProxy":"AUTO"}));
    let g = call(
        &dir,
        "mihomo:generate",
        json!({"companyConnectionRequested":true}),
    );
    assert_eq!(g["selectionValid"], true);
    let c: Value =
        serde_yaml_ng::from_str(&std::fs::read_to_string(g["config"].as_str().unwrap()).unwrap())
            .unwrap();
    assert!(
        !c["rules"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r.as_str().unwrap().contains("COMPANY-"))
    );
    assert_eq!(
        call(&dir, "settings:get", json!({}))["selectedProxy"],
        "AUTO"
    );
    let g = call(&dir, "singbox:generate", json!({}));
    let c: Value = serde_json::from_str(g["config"].as_str().unwrap()).unwrap();
    assert!(
        !c["outbounds"]
            .as_array()
            .unwrap()
            .iter()
            .any(|o| o["tag"].as_str().unwrap_or("").starts_with("COMPANY-"))
    );
}

#[test]
fn settings_changed_during_authentication_cannot_bind_a_stale_candidate() {
    let (dir, r) = fixture();
    let g = call(&dir, "singbox:generate", json!({}));
    let mut transport = r;
    transport["port"] = json!(25000);
    let previous = call(&dir, "settings:get", json!({}));
    let changed = if previous["unknownTraffic"] == "direct" {
        "vpn"
    } else {
        "direct"
    };
    call(&dir, "settings:patch", json!({"unknownTraffic":changed}));
    let reply = request(
        &dir,
        "company:mobile:bind",
        json!({"expectedRevision":g["summary"]["runtimeRevision"],"config":g["config"],"transport":transport}),
    );
    assert_eq!(reply["ok"], false);
}
