use serde_json::{Value, json};
use splitvpn_core::{
    mobile, static_exit,
    storage::{Storage, identity},
};

fn request(dir: &tempfile::TempDir, channel: &str, payload: Value) -> Value {
    serde_json::from_str(&mobile::call(
        dir.path().to_str().unwrap(),
        &json!({"channel":channel,"payload":payload}).to_string(),
    ))
    .unwrap()
}
fn call(dir: &tempfile::TempDir, channel: &str, payload: Value) -> Value {
    let reply = request(dir, channel, payload);
    assert_eq!(reply["ok"], true, "{reply}");
    reply["data"].clone()
}
fn fixture() -> (tempfile::TempDir, Value) {
    let dir = tempfile::tempdir().unwrap();
    let store = Storage::new(dir.path().into());
    let provider = store.path("mihomo/providers/fixture.json");
    store.write("mihomo/providers/fixture.json", &json!({"proxies":[{"name":"fixture-node","type":"http","server":"127.0.0.1","port":9}]})).unwrap();
    store.write("subscription.json", &json!({"entries":[{"id":"fixture","url":"https://example.test/subscription","enabled":true,"nodeCount":1}]})).unwrap();
    store.write("mihomo/providers/subscription-manifest.json", &json!({"schemaVersion":1,"entries":[{"subscriptionId":"fixture","providerPath":provider,"providerRevision":"fixture"}]})).unwrap();
    let config = json!({"enabled":true,"protocol":"socks5","server":"proxy.example.test","port":1080,"username":"fixture","expectedIp":"203.0.113.8"});
    call(
        &dir,
        "settings:patch",
        json!({"selectedProxy":"fixture-node","vpnDomainRules":["DOMAIN,proxy.example.test"],"directDomainRules":["DOMAIN,direct.example.test"],"staticExit":config}),
    );
    (dir, config)
}

#[test]
fn portable_rule_edits_are_atomic_and_preserve_the_other_outlet() {
    let dir = tempfile::tempdir().unwrap();
    call(
        &dir,
        "routing:add-rule",
        json!({"rule":"https://api.example.test/path","target":"direct"}),
    );
    let edited = call(
        &dir,
        "routing:edit-rule",
        json!({"originalRule":"DOMAIN-SUFFIX,api.example.test","originalTarget":"direct","rule":"192.0.2.8/24","target":"vpn"}),
    );
    assert_eq!(edited["directDomainRules"], json!([]));
    assert!(
        edited["vpnDomainRules"]
            .as_array()
            .unwrap()
            .contains(&json!("IP-CIDR,192.0.2.0/24"))
    );
    let path = dir.path().join("settings.json");
    let before = std::fs::read(&path).unwrap();
    for payload in [
        json!({"unknownTraffic":"invalid"}),
        json!({"geoFallback":"invalid"}),
        json!({"lanDirect":"yes"}),
        json!({"directDomainRules":["bad/address"]}),
    ] {
        assert_eq!(request(&dir, "settings:patch", payload)["ok"], false);
        assert_eq!(std::fs::read(&path).unwrap(), before);
    }
    let result = call(&dir, "routing:diagnose", json!({"target":"192.0.2.9"}));
    assert_eq!(result["policy"], "VPN");
}

#[test]
fn node_identity_favorites_and_groups_use_the_shared_model() {
    let (dir, _) = fixture();
    let selected = call(
        &dir,
        "nodes:select-v2",
        json!({"identityKey":identity("fixture", "fixture-node")}),
    );
    assert_eq!(
        selected["defaultOutlet"]["identityKey"],
        identity("fixture", "fixture-node")
    );
    assert_eq!(
        request(&dir, "nodes:select-v2", json!({"identityKey":"removed"}))["ok"],
        false
    );
    call(&dir, "native:favorite", json!({"name":"fixture-node"}));
    let settings = call(&dir, "native:favorite", json!({"name":"fixture-node"}));
    assert_eq!(settings["favoriteNodeNames"], json!([]));
    let groups = json!([{"id":"fixture-group","name":"常用","strategy":"manual","nodeNames":["fixture-node"],"members":[{"identityKey":identity("fixture","fixture-node"),"lastKnownName":"fixture-node"}]}]);
    call(&dir, "node-groups:save", json!({"nodeGroups":groups}));
    assert_eq!(
        call(&dir, "node-groups:list", json!({}))[0]["members"][0]["identityKey"],
        identity("fixture", "fixture-node")
    );
    assert_eq!(
        request(&dir, "nodes:select", json!({"nodeName":"DIRECT"}))["ok"],
        false
    );
}

#[test]
fn iphone_fixed_exit_preserves_direct_and_routes_proxy_dns_through_the_final_hop() {
    let (dir, config) = fixture();
    for protocol in ["socks5", "http", "https"] {
        let mut config = config.clone();
        config["protocol"] = json!(protocol);
        call(
            &dir,
            "static-exit:configure",
            json!({"configuration":config}),
        );
        let credential = json!({"configuration":config,"password":"fixture-only"});
        let reply = call(
            &dir,
            "singbox:generate",
            json!({"exitCredential":credential}),
        );
        let document: Value = serde_json::from_str(reply["config"].as_str().unwrap()).unwrap();
        let exit = document["outbounds"]
            .as_array()
            .unwrap()
            .iter()
            .find(|o| o["tag"] == static_exit::EXIT)
            .unwrap();
        assert_eq!(exit["detour"], "proxy");
        assert_eq!(exit["password"], "fixture-only");
        assert_eq!(exit["tls"]["enabled"] == true, protocol == "https");
        let rules = document["route"]["rules"].as_array().unwrap();
        assert!(rules.iter().any(|r| r["outbound"] == "direct" && r["domain"] == json!(["direct.example.test"])));
        assert!(
            rules.iter().any(|r| r["outbound"] == static_exit::EXIT
                && r["domain"] == json!(["proxy.example.test"]))
        );
        assert!(rules.iter().any(|r| r["outbound"] == "block"
            && r["network"] == json!(["udp"])
            && r["domain"] == json!(["proxy.example.test"])));
        assert!(
            document["dns"]["servers"]
                .as_array()
                .unwrap()
                .iter()
                .any(|s| s["tag"] == "cloudflare" && s["detour"] == static_exit::EXIT)
        );
        assert!(
            !std::fs::read_to_string(dir.path().join("settings.json"))
                .unwrap()
                .contains("fixture-only")
        );
    }
}

#[test]
fn mobile_exits_require_endpoint_bound_credentials_and_never_persist_passwords() {
    let (dir, config) = fixture();
    for channel in ["singbox:generate", "mihomo:generate"] {
        assert_eq!(request(&dir, channel, json!({}))["ok"], false);
        let mut wrong = config.clone();
        wrong["port"] = json!(9999);
        let reply = request(
            &dir,
            channel,
            json!({"exitCredential":{"configuration":wrong,"password":"fixture-only"}}),
        );
        assert_eq!(reply["ok"], false);
        assert!(!reply.to_string().contains("fixture-only"));
    }
    call(&dir, "static-exit:set-enabled", json!({"enabled":false}));
    assert_eq!(
        call(&dir, "settings:get", json!({}))["staticExit"]["enabled"],
        false
    );
    call(&dir, "singbox:generate", json!({}));
}

#[test]
fn android_fixed_exit_keeps_virtual_dns_and_separate_probe_outlets() {
    let (dir, config) = fixture();
    let result = call(
        &dir,
        "mihomo:generate",
        json!({"exitCredential":{"configuration":config,"password":"fixture-only"}}),
    );
    let text = std::fs::read_to_string(result["config"].as_str().unwrap()).unwrap();
    let document: Value = serde_yaml_ng::from_str(&text).unwrap();
    assert!(
        document["rules"][0]
            .as_str()
            .unwrap()
            .contains("__QZ_ANDROID_DNS__")
    );
    assert!(
        document["rules"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| !r.as_str().unwrap().starts_with("PROCESS-NAME"))
    );
    assert!(
        document["rules"]
            .as_array()
            .unwrap()
            .contains(&json!("DOMAIN,direct.example.test,DIRECT"))
    );
    assert_eq!(document["listeners"].as_array().unwrap().len(), 3);
    assert_eq!(document["proxies"][1]["dialer-proxy"], "VPN");
    assert!(
        !std::fs::read_to_string(dir.path().join("settings.json"))
            .unwrap()
            .contains("fixture-only")
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(result["config"].as_str().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}

// Pure loopback HTTP proxy/controller; this does not start a VPN or touch routes.
struct Loopback {
    port: u16,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl Loopback {
    fn new() -> Self {
        use std::{
            io::{Read, Write},
            sync::{
                Arc,
                atomic::{AtomicBool, Ordering},
            },
            time::Duration,
        };
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        let worker = std::thread::spawn(move || {
            let mut selected = String::new();
            while !flag.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        stream
                            .set_read_timeout(Some(Duration::from_secs(2)))
                            .unwrap();
                        let mut bytes = Vec::new();
                        while bytes.len() < 8192 && !bytes.windows(4).any(|v| v == b"\r\n\r\n") {
                            let mut chunk = [0; 1024];
                            let n = stream.read(&mut chunk).unwrap_or(0);
                            if n == 0 {
                                break;
                            };
                            bytes.extend_from_slice(&chunk[..n]);
                        }
                        let headers = String::from_utf8_lossy(&bytes).to_string();
                        let header_end = bytes
                            .windows(4)
                            .position(|v| v == b"\r\n\r\n")
                            .map(|i| i + 4)
                            .unwrap_or(bytes.len());
                        let length = headers
                            .lines()
                            .find_map(|line| {
                                line.to_ascii_lowercase()
                                    .strip_prefix("content-length:")
                                    .and_then(|v| v.trim().parse::<usize>().ok())
                            })
                            .unwrap_or(0);
                        while bytes.len() < header_end + length {
                            let mut chunk = [0; 1024];
                            let n = stream.read(&mut chunk).unwrap_or(0);
                            if n == 0 {
                                break;
                            };
                            bytes.extend_from_slice(&chunk[..n]);
                        }
                        let request = String::from_utf8_lossy(&bytes);
                        if request.starts_with("PUT ") {
                            if let Ok(value) = serde_json::from_slice::<Value>(&bytes[header_end..])
                            {
                                selected = value["name"].as_str().unwrap_or("").to_owned();
                            }
                        }
                        let (status, body) = if request.contains("/proxies/") {
                            ("200 OK", json!({"now":selected}).to_string())
                        } else if request.contains("/download") {
                            ("200 OK", "x".repeat(512 * 1024))
                        } else if request.contains("/restricted") {
                            ("403 Forbidden", "restricted".to_owned())
                        } else if request.contains("/risk") {
                            (
                                "200 OK",
                                json!({"ip":"203.0.113.8","threat":{"is_threat":true}}).to_string(),
                            )
                        } else {
                            ("200 OK", json!({"ip":"203.0.113.8"}).to_string())
                        };
                        let response = format!(
                            "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                            body.len()
                        );
                        let _ = stream.write_all(response.as_bytes());
                    }
                    Err(_) => std::thread::sleep(Duration::from_millis(2)),
                }
            }
        });
        Self {
            port,
            stop,
            worker: Some(worker),
        }
    }
}
impl Drop for Loopback {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            worker.join().unwrap();
        }
    }
}
fn diagnostic_fixture(server: &Loopback) -> (tempfile::TempDir, Value) {
    let (dir, configuration) = fixture();
    let mut ports = vec![7890u16, 9090, 9091, 9093];
    ports.retain(|p| *p != server.port);
    while ports.len() < 4 {
        ports.push(19000 + ports.len() as u16);
    }
    let generated = call(
        &dir,
        "mihomo:generate",
        json!({"mixedPort":ports[0],"controllerPort":ports[1],"probePort":ports[2],"scanPort":ports[3],"exitProbePort":server.port,"exitCredential":{"configuration":configuration,"password":"fixture-password"}}),
    );
    let payload = json!({"connected":true,"runtimeRevision":generated["runtimeRevision"],"networkEpoch":"fixture-epoch","testUrl":format!("http://127.0.0.1:{}/ip",server.port),"systemDns":{"ok":true},"chatgpt":{"ok":true,"httpStatus":200}});
    (dir, payload)
}
#[test]
fn mobile_diagnostics_use_applied_revision_and_separate_dns_from_proxy() {
    let server = Loopback::new();
    let (dir, mut p) = diagnostic_fixture(&server);
    p["systemDns"] = json!({"ok":false,"error":"fixture DNS failure"});
    let result = call(&dir, "mobile:diagnostics:connectivity", p.clone());
    assert_eq!(result["connectivity"]["proxyOk"], true);
    assert_eq!(result["connectivity"]["foreignOk"], false);
    assert_eq!(result["connectivity"]["externalIp"], "203.0.113.8");
    p["runtimeRevision"] = json!("generated-but-not-applied");
    assert_eq!(
        request(&dir, "mobile:diagnostics:connectivity", p)["ok"],
        false
    );
}
#[test]
fn mobile_restricted_http_is_not_reported_as_a_dns_failure() {
    let server = Loopback::new();
    let (dir, mut p) = diagnostic_fixture(&server);
    p["testUrl"] = json!(format!("http://127.0.0.1:{}/restricted", server.port));
    let result = call(&dir, "mobile:diagnostics:websites", p);
    assert_eq!(
        result["results"][0]["failureReason"], "restricted",
        "{result}"
    );
    assert_eq!(result["results"][0]["httpStatus"], 403);
}
#[test]
fn mobile_risk_uses_shared_scoring_and_does_not_persist_the_key() {
    let server = Loopback::new();
    let (dir, mut p) = diagnostic_fixture(&server);
    p["testUrl"] = json!(format!("http://127.0.0.1:{}/risk", server.port));
    p["apiKey"] = json!("fixture-secret-risk-key");
    let result = call(&dir, "mobile:diagnostics:risk", p.clone());
    assert_eq!(result["riskLevel"], "high");
    assert_eq!(result["ip"], "203.0.113.8");
    assert_eq!(result["viaStaticExit"], true);
    let cached = call(&dir, "mobile:diagnostics:cached", p.clone());
    assert_eq!(cached["risk"]["riskLevel"], "high");
    assert!(!cached.to_string().contains("fixture-secret-risk-key"));
    p["networkEpoch"] = json!("new-network");
    assert!(
        call(&dir, "mobile:diagnostics:cached", p)
            .as_object()
            .unwrap()
            .is_empty()
    );
}
#[test]
fn mobile_scans_cancel_without_mutating_the_business_route() {
    let server = Loopback::new();
    let (dir, p) = diagnostic_fixture(&server);
    let before = std::fs::read(dir.path().join("settings.json")).unwrap();
    let mut start = p.clone();
    start["mode"] = json!("full");
    let scan = call(&dir, "mobile:chain:start", start);
    assert_eq!(
        request(&dir, "mobile:chain:cancel", json!({"id":"other-session"}))["ok"],
        false
    );
    let stopped = call(&dir, "mobile:chain:cancel", json!({"id":scan["id"]}));
    assert_eq!(stopped["cancelled"], true);
    let mut next = p;
    next["id"] = scan["id"].clone();
    assert_eq!(request(&dir, "mobile:chain:next", next)["ok"], false);
    assert_eq!(
        std::fs::read(dir.path().join("settings.json")).unwrap(),
        before
    );
}
#[test]
fn mobile_scans_reject_changed_settings_and_forged_use_tickets() {
    let server = Loopback::new();
    let (dir, mut p) = diagnostic_fixture(&server);
    p["ticket"] = json!("not-issued");
    assert_eq!(
        request(&dir, "mobile:chain:commit-use", p.clone())["ok"],
        false
    );
    let scan = call(&dir, "mobile:chain:start", p.clone());
    call(&dir, "settings:patch", json!({"geoFallback":"block"}));
    p["id"] = scan["id"].clone();
    assert_eq!(request(&dir, "mobile:chain:next", p)["ok"], false);
    let history = call(
        &dir,
        "mobile:chain:history",
        json!({"offset":0,"limit":500}),
    );
    assert_eq!(history["total"], 0);
}
#[test]
fn iphone_auto_selection_uses_urltest_and_all_probes_are_private() {
    let (dir, _) = fixture();
    call(
        &dir,
        "settings:patch",
        json!({"selectedProxy":"AUTO","staticExit":{"enabled":false}}),
    );
    let output = call(&dir, "singbox:generate", json!({}));
    let config: Value = serde_json::from_str(output["config"].as_str().unwrap()).unwrap();
    assert_eq!(
        output["summary"]["selectedProxyStatus"],
        "automatic-urltest"
    );
    assert!(
        config["outbounds"]
            .as_array()
            .unwrap()
            .iter()
            .any(|o| o["type"] == "urltest" && o["interval"] == "10m")
    );
    assert!(
        config["inbounds"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|i| i["type"] == "mixed")
            .all(|i| i["listen"] == "127.0.0.1")
    );
    assert!(
        config["experimental"]["clash_api"]["secret"]
            .as_str()
            .is_some_and(|s| s.len() > 20)
    );
}

#[test]
fn mobile_blocking_io_does_not_hold_the_management_lock_or_publish_after_stop() {
    use std::{
        io::{Read, Write},
        sync::mpsc,
        time::{Duration, Instant},
    };
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut b = [0; 8192];
        let _ = stream.read(&mut b);
        entered_tx.send(()).unwrap();
        release_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        let _ =
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    });
    let server = Loopback {
        port,
        stop: Default::default(),
        worker: None,
    };
    let (dir, p) = diagnostic_fixture(&server);
    let root = dir.path().to_str().unwrap().to_owned();
    let task = std::thread::spawn(move || {
        mobile::call(
            &root,
            &json!({"channel":"mobile:diagnostics:websites","payload":p}).to_string(),
        )
    });
    entered_rx.recv_timeout(Duration::from_secs(3)).unwrap();
    let start = Instant::now();
    call(&dir, "mobile:runtime:invalidate", json!({}));
    call(&dir, "settings:get", json!({}));
    assert!(start.elapsed() < Duration::from_secs(1));
    release_tx.send(()).unwrap();
    let reply: Value = serde_json::from_str(&task.join().unwrap()).unwrap();
    assert_eq!(reply["ok"], false);
    worker.join().unwrap();
    assert!(!dir.path().join("cache/mobile-diagnostics.json").exists());
}
#[test]
fn mobile_presentation_edits_keep_runtime_diagnostics_valid() {
    let server = Loopback::new();
    let (dir, p) = diagnostic_fixture(&server);
    call(&dir, "native:favorite", json!({"name":"fixture-node"}));
    assert_eq!(
        call(&dir, "mobile:diagnostics:websites", p)["results"][0]["ok"],
        true
    );
}

#[test]
fn mobile_chain_measures_ranks_persists_and_commits_only_a_verified_ticket() {
    let http = Loopback::new();
    let controller = Loopback::new();
    let current = Loopback::new();
    let (dir, configuration) = fixture();
    let generated = call(
        &dir,
        "mihomo:generate",
        json!({"controllerPort":controller.port,"exitProbePort":current.port,"scanPort":http.port,"exitCredential":{"configuration":configuration,"password":"fixture-password"}}),
    );
    let mut p = json!({"connected":true,"runtimeRevision":generated["runtimeRevision"],"networkEpoch":"fixture-success","testTargets":{"latency":format!("http://127.0.0.1:{}/latency",http.port),"download":format!("http://127.0.0.1:{}/download",http.port),"ip":format!("http://127.0.0.1:{}/ip",http.port)},"mode":"full"});
    let before = std::fs::read(dir.path().join("settings.json")).unwrap();
    let scan = call(&dir, "mobile:chain:start", p.clone());
    p["id"] = scan["id"].clone();
    let measured = call(&dir, "mobile:chain:next", p.clone());
    assert_eq!(measured["running"], false);
    assert_eq!(measured["results"][0]["status"], "available", "{measured}");
    assert!(measured["results"][0]["downloadMbps"].as_f64().unwrap() > 0.0);
    assert_eq!(
        std::fs::read(dir.path().join("settings.json")).unwrap(),
        before,
        "测量改变了业务配置"
    );
    assert_eq!(
        call(&dir, "mobile:chain:history", json!({"limit":30}))["total"],
        1
    );
    let copy = tempfile::tempdir().unwrap();
    let destination = Storage::new(copy.path().into());
    let source = Storage::new(dir.path().into());
    for file in [
        "cache/mobile-chain.json",
        "runtime-state/mobile-profile.json",
    ] {
        destination
            .write(file, &source.read(file, Value::Null).unwrap())
            .unwrap();
    }
    assert_eq!(
        call(&copy, "mobile:chain:get", json!({}))["results"][0]["status"],
        "available"
    );
    p["identityKey"] = measured["results"][0]["identityKey"].clone();
    let checked = call(&dir, "mobile:chain:prepare-use", p.clone());
    p["ticket"] = checked["ticket"].clone();
    let settings = call(&dir, "mobile:chain:commit-use", p.clone());
    assert_eq!(settings["staticExit"]["enabled"], true);
    assert_eq!(settings["defaultOutlet"]["identityKey"], p["identityKey"]);
    assert_eq!(
        request(&dir, "mobile:chain:commit-use", p)["ok"],
        false,
        "复核票据被重复使用"
    );
}
