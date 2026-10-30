use serde_json::{Value, json};
use splitvpn_core::{
    company, config, static_exit,
    storage::{Storage, normalize_settings},
};

fn fixture(dir: &tempfile::TempDir, geo: bool) -> (Storage, Value) {
    let store = Storage::new(dir.path().into());
    let provider = store.path("mihomo/providers/fixture.json");
    store
        .write(
            "mihomo/providers/fixture.json",
            &json!({"proxies":[{"name":"fixture","type":"http","server":"127.0.0.1","port":9}]}),
        )
        .unwrap();
    store
        .write(
            "subscription.json",
            &json!({"entries":[{"id":"fixture","enabled":true,"nodeCount":1}]}),
        )
        .unwrap();
    store
        .write(
            "mihomo/providers/subscription-manifest.json",
            &json!({"schemaVersion":1,"entries":[{"subscriptionId":"fixture","providerPath":provider,"providerRevision":"fixture"}]}),
        )
        .unwrap();
    if geo {
        for name in ["GeoSite.dat", "country.mmdb", "geoip.metadb"] {
            std::fs::write(store.path(&format!("mihomo/{name}")), b"fixture").unwrap();
        }
    }
    let mut settings = store.settings().unwrap();
    settings["selectedProxy"] = json!("fixture");
    settings["unknownTraffic"] = json!("vpn");
    settings["directDomainRules"] = json!(["DOMAIN,direct.example.test"]);
    settings["vpnDomainRules"] = json!(["DOMAIN,proxy.example.test"]);
    std::fs::write(
        store.path("mihomo/providers/vpn-domains.yaml"),
        config::yaml(&json!({"payload":settings["vpnDomainRules"]})).unwrap(),
    )
    .unwrap();
    (store, settings)
}

#[test]
fn domestic_wechat_bypasses_compatibility_while_explicit_outlets_keep_priority() {
    for geo in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let (store, mut settings) = fixture(&dir, geo);
        for udp in [false, true] {
            for fixed_exit in [false, true] {
                settings["staticExit"] = json!({"enabled":fixed_exit,"protocol":"http","server":"proxy.example.test","port":1080,"username":"","expectedIp":""});
                let mut c = config::build(&store, &settings, 7890, 9090, None, udp).unwrap();
                static_exit::apply(&mut c, &settings, &Value::Null, 7891).unwrap();
                let rules = c["rules"].as_array().unwrap();
                let at = |r: &str| rules.iter().position(|v| v == r).unwrap();
                let proxy = if fixed_exit { static_exit::EXIT } else { "VPN" };
                let direct = if geo {
                    "GEOSITE,cn,DIRECT"
                } else {
                    "DOMAIN-SUFFIX,qq.com,DIRECT"
                };
                assert!(
                    at("DOMAIN,direct.example.test,DIRECT")
                        < at(&format!("RULE-SET,vpn-domains,{proxy}"))
                );
                assert!(at(&format!("RULE-SET,vpn-domains,{proxy}")) < at(direct));
                for process in ["WeChat", "WeChatAppEx", "WeChatAppEx Helper"] {
                    assert!(at(direct) < at(&format!("PROCESS-NAME,{process},WECHAT")));
                    if geo {
                        assert!(
                            at("GEOIP,CN,DIRECT") < at(&format!("PROCESS-NAME,{process},WECHAT"))
                        );
                    }
                }
                let wechat = c["proxy-groups"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|g| g["name"] == "WECHAT")
                    .unwrap();
                assert_eq!(wechat["type"], "fallback");
                assert_eq!(wechat["proxies"], json!(["DIRECT", proxy]));
            }
        }
    }
}

#[test]
fn disabling_wechat_compatibility_leaves_regular_split_rules() {
    let dir = tempfile::tempdir().unwrap();
    let (store, mut settings) = fixture(&dir, true);
    settings["specialCompatibilityRules"]["wechatImageSendFallback"] = json!(false);
    let c = config::build(&store, &settings, 7890, 9090, None, false).unwrap();
    assert!(
        !c["proxy-groups"]
            .as_array()
            .unwrap()
            .iter()
            .any(|g| g["name"] == "WECHAT")
    );
    let rules = c["rules"].as_array().unwrap();
    assert!(
        !rules
            .iter()
            .any(|r| r.as_str().unwrap().contains(",WECHAT"))
    );
    assert!(rules.contains(&json!("GEOSITE,cn,DIRECT")));
    assert!(rules.contains(&json!("GEOSITE,geolocation-!cn,VPN")));
}

#[test]
fn no_subscription_does_not_leave_dangling_app_groups() {
    let dir = tempfile::tempdir().unwrap();
    let store = Storage::new(dir.path().into());
    let c = config::build(&store, &store.settings().unwrap(), 7890, 9090, None, false).unwrap();
    assert!(c.get("proxy-groups").is_none());
    assert_eq!(
        c["rules"].as_array().unwrap().last().unwrap(),
        "MATCH,DIRECT"
    );
    assert!(
        !c["rules"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r.as_str().unwrap().contains(",WECHAT"))
    );
}

#[test]
fn mailmaster_direct_applies_to_the_app_and_can_be_disabled_without_affecting_8081() {
    let dir = tempfile::tempdir().unwrap();
    let (store, mut settings) = fixture(&dir, true);
    settings["specialCompatibilityRules"]["mailMasterProxy8081"] = json!(false);
    for enabled in [true, false] {
        settings["specialCompatibilityRules"]["mailMasterDirect"] = json!(enabled);
        for fixed in [true, false] {
            settings["staticExit"] = json!({"enabled":fixed,"protocol":"http","server":"proxy.example.test","port":1080,"username":"","expectedIp":""});
            let mut c = config::build(&store, &settings, 7890, 9090, None, false).unwrap();
            static_exit::apply(&mut c, &settings, &Value::Null, 7891).unwrap();
            let rules = c["rules"].as_array().unwrap();
            for process in ["MailMaster", "MailMaster.exe", "mailmaster.exe"] {
                let rule = json!(format!("PROCESS-NAME,{process},DIRECT"));
                assert_eq!(rules.contains(&rule), enabled);
                if enabled {
                    let at = rules.iter().position(|r| r == &rule).unwrap();
                    let explicit = format!(
                        "RULE-SET,vpn-domains,{}",
                        if fixed { static_exit::EXIT } else { "VPN" }
                    );
                    assert!(rules.iter().position(|r| r == &explicit).unwrap() < at);
                    assert!(
                        at < rules
                            .iter()
                            .position(|r| r == "GEOSITE,geolocation-!cn,VPN"
                                || r == &format!("GEOSITE,geolocation-!cn,{}", static_exit::EXIT))
                            .unwrap()
                    );
                }
            }
            assert_eq!(
                c["sniffer"]["sniff"]["HTTP"]["ports"],
                json!([80, "8080-8880"])
            );
            assert!(
                !rules
                    .iter()
                    .any(|r| r.as_str().unwrap().starts_with("DST-PORT,993,"))
            );
        }
    }
}

#[test]
fn private_resources_precede_both_app_policies() {
    let dir = tempfile::tempdir().unwrap();
    let (store, settings) = fixture(&dir, false);
    let c = config::build(&store, &settings, 7890, 9090, None, false).unwrap();
    let private = company::compile(
        c,
        1080,
        "COMPANY-01234567",
        &json!([{"address":"10.0.0.8","ports":"993","network":"tcp"}]),
    )
    .unwrap();
    assert!(
        private.config["rules"][0]
            .as_str()
            .unwrap()
            .ends_with(",COMPANY-01234567")
    );
    assert!(
        private.config["rules"]
            .as_array()
            .unwrap()
            .contains(&json!("PROCESS-NAME,MailMaster,DIRECT"))
    );
}

#[test]
fn old_compatibility_settings_keep_existing_choices_and_unknown_fields() {
    let old = json!({"specialCompatibilityRules":{"mailMasterProxy8081":false,"wechatImageSendFallback":false,"futureFlag":"keep"},"futureSetting":{"keep":true}});
    let normalized = normalize_settings(old).unwrap();
    assert_eq!(
        normalized["specialCompatibilityRules"]["mailMasterDirect"],
        true
    );
    assert_eq!(
        normalized["specialCompatibilityRules"]["mailMasterProxy8081"],
        false
    );
    assert_eq!(
        normalized["specialCompatibilityRules"]["wechatImageSendFallback"],
        false
    );
    assert_eq!(
        normalized["specialCompatibilityRules"]["futureFlag"],
        "keep"
    );
    assert_eq!(normalized["futureSetting"]["keep"], true);
}

#[test]
#[ignore = "bundled Mihomo; app metadata supplied by test inbounds, TUN/DNS disabled"]
fn real_mihomo_app_routes() {
    use std::{
        io::{BufRead, BufReader, Write},
        net::TcpListener,
        process::{Child, Command, Stdio},
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        },
        thread,
        time::{Duration, Instant},
    };
    struct Server {
        port: u16,
        healthy: Arc<AtomicBool>,
        stop: Arc<AtomicBool>,
        worker: Option<thread::JoinHandle<()>>,
    }
    impl Server {
        fn new(proxy: bool) -> Self {
            let socket = TcpListener::bind("127.0.0.1:0").unwrap();
            let port = socket.local_addr().unwrap().port();
            socket.set_nonblocking(true).unwrap();
            let healthy = Arc::new(AtomicBool::new(true));
            let stop = Arc::new(AtomicBool::new(false));
            let (h, s) = (healthy.clone(), stop.clone());
            let worker = thread::spawn(move || {
                while !s.load(Ordering::Relaxed) {
                    let Ok((mut stream, _)) = socket.accept() else {
                        thread::sleep(Duration::from_millis(5));
                        continue;
                    };
                    stream.set_nonblocking(false).unwrap();
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut tunnels = 0;
                    let request = loop {
                        let mut line = String::new();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 {
                            break None;
                        }
                        let first = line.clone();
                        loop {
                            line.clear();
                            if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                                break;
                            }
                        }
                        if first.starts_with("CONNECT ") && proxy {
                            tunnels += 1;
                            let _ =
                                stream.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n");
                        } else {
                            break Some(first);
                        }
                    };
                    if let Some(request) = request {
                        if !proxy && request.contains("/health") && !h.load(Ordering::Relaxed) {
                            continue; // Refuse only the direct health endpoint.
                        }
                        let body = if !proxy {
                            "via-direct"
                        } else if tunnels > 1 {
                            "via-static"
                        } else {
                            "via-airport"
                        };
                        let _ = write!(
                            stream,
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                            body.len()
                        );
                    }
                }
            });
            Self {
                port,
                healthy,
                stop,
                worker: Some(worker),
            }
        }
    }
    impl Drop for Server {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            self.worker.take().unwrap().join().unwrap();
        }
    }
    struct Engine(Child);
    impl Drop for Engine {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let port = || {
        TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port()
    };
    let arch = match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => "darwin-arm64",
        ("macos", "x86_64") => "darwin-x64",
        ("linux", "x86_64") => "linux-x64",
        other => panic!("unsupported {other:?}"),
    };
    let binary = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join(format!("../../resources/mihomo/{arch}/mihomo"));
    for fixed in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let (store, mut settings) = fixture(&dir, false);
        let direct = Server::new(false);
        let airport = Server::new(true);
        store.write("mihomo/providers/fixture.json", &json!({"proxies":[{"name":"fixture","type":"http","server":"127.0.0.1","port":airport.port}]})).unwrap();
        settings["tun"] = json!(false);
        settings["lanDirect"] = json!(false);
        settings["tailscaleDirect"] = json!(false);
        settings["staticExit"] = json!({"enabled":fixed,"protocol":"http","server":"127.0.0.1","port":18888,"username":"","expectedIp":""});
        let (mixed, controller) = (port(), port());
        let mut c = config::build(&store, &settings, mixed, controller, None, false).unwrap();
        c["dns"]["enable"] = json!(false);
        c["geo-auto-update"] = json!(false);
        c["sniffer"]["enable"] = json!(false);
        c["log-level"] = json!("debug");
        c["find-process-mode"] = json!("off");
        c["hosts"] = json!({"weixin.qq.com":"127.0.0.1","unclassified.example.test":"127.0.0.1"});
        c["profile"] = json!({"store-selected":false,"store-fake-ip":false});
        c["proxy-groups"]
            .as_array_mut()
            .unwrap()
            .retain(|g| g["name"] == "VPN" || g["name"] == "WECHAT");
        for group in c["proxy-groups"].as_array_mut().unwrap() {
            if group["name"] == "VPN" {
                group["proxies"] = json!([]);
            } else {
                group["url"] = json!(format!("http://127.0.0.1:{}/health", direct.port));
                group["expected-status"] = json!("200");
                group["interval"] = json!(1);
                group["timeout"] = json!(300);
            }
        }
        for provider in c["proxy-providers"].as_object_mut().unwrap().values_mut() {
            provider["health-check"]["enable"] = json!(false);
        }
        static_exit::apply(&mut c, &settings, &Value::Null, port()).unwrap();
        // Production process ownership comes from the privileged TUN. Supply
        // equivalent app identity via named test inbounds in this unprivileged
        // fixture; the policy order, groups and outbound chain stay unchanged.
        for rule in c["rules"].as_array_mut().unwrap() {
            if let Some(process) = rule.as_str().and_then(|r| r.strip_prefix("PROCESS-NAME,")) {
                *rule = json!(format!("IN-NAME,{process}"));
            }
        }
        let (wechat, mail) = (port(), port());
        if !c["listeners"].is_array() {
            c["listeners"] = json!([]);
        }
        for (name, listen_port) in [("WeChat", wechat), ("MailMaster", mail)] {
            c["listeners"]
                .as_array_mut()
                .unwrap()
                .push(json!({"name":name,"type":"mixed","listen":"127.0.0.1","port":listen_port}));
        }
        let path = store.path("mihomo/config.json");
        std::fs::write(&path, c.to_string()).unwrap();
        let log_path = store.path("mihomo/native.log");
        let log = std::fs::File::create(&log_path).unwrap();
        let mut engine = Engine(
            Command::new(&binary)
                .arg("-d")
                .arg(store.path("mihomo"))
                .arg("-f")
                .arg(&path)
                .stdout(Stdio::from(log.try_clone().unwrap()))
                .stderr(Stdio::from(log))
                .spawn()
                .unwrap(),
        );
        let api = reqwest::blocking::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(2))
            .build()
            .unwrap();
        let endpoint = format!("http://127.0.0.1:{controller}");
        let secret = c["secret"].as_str().unwrap();
        let health_check = || {
            let result = api
                .get(format!("{endpoint}/group/WECHAT/delay"))
                .bearer_auth(secret)
                .query(&[
                    ("url", format!("http://127.0.0.1:{}/health", direct.port)),
                    ("timeout", "300".into()),
                    ("expected", "200".into()),
                ])
                .send()
                .unwrap();
            let status = result.status();
            let body = result.text().unwrap();
            assert!(
                status.is_success(),
                "{status}: {body}\n{}",
                std::fs::read_to_string(&log_path).unwrap_or_default()
            );
        };
        let wait = |expected: &str| {
            let deadline = Instant::now() + Duration::from_secs(10);
            loop {
                let current = api
                    .get(format!("{endpoint}/proxies/WECHAT"))
                    .bearer_auth(secret)
                    .send()
                    .ok()
                    .and_then(|r| r.json::<Value>().ok());
                if current.as_ref().is_some_and(|v| v["now"] == expected) {
                    break;
                }
                assert!(
                    Instant::now() < deadline,
                    "fixed={fixed}, expected={expected}, got={current:?}\n{}",
                    std::fs::read_to_string(&log_path).unwrap_or_default()
                );
                thread::sleep(Duration::from_millis(50));
            }
        };
        wait("DIRECT");
        assert!(engine.0.try_wait().unwrap().is_none());
        api.put(format!("{endpoint}/proxies/VPN"))
            .bearer_auth(secret)
            .json(&json!({"name":"fixture"}))
            .send()
            .unwrap()
            .error_for_status()
            .unwrap();
        health_check();
        let request = |name: &str, host: &str, expected: &str| {
            let listen_port = if name == "WeChat" { wechat } else { mail };
            let response = reqwest::blocking::Client::builder()
                .no_proxy()
                .proxy(reqwest::Proxy::all(format!("http://127.0.0.1:{listen_port}")).unwrap())
                .timeout(Duration::from_secs(4))
                .build()
                .unwrap()
                .get(format!("http://{host}:{}/check", direct.port))
                .send()
                .unwrap();
            let status = response.status();
            let body = response.text().unwrap();
            assert!(
                status.is_success(),
                "{status}: {body}\n{}",
                std::fs::read_to_string(&log_path).unwrap_or_default()
            );
            assert_eq!(
                body,
                expected,
                "{name}, fixed={fixed}\n{}",
                std::fs::read_to_string(&log_path).unwrap_or_default()
            );
        };
        request("WeChat", "127.0.0.1", "via-direct");
        direct.healthy.store(false, Ordering::Relaxed);
        health_check();
        wait(if fixed { static_exit::EXIT } else { "VPN" });
        let proxied = if fixed { "via-static" } else { "via-airport" };
        request("WeChat", "127.0.0.1", proxied);
        request("WeChat", "weixin.qq.com", "via-direct");
        request("MailMaster", "127.0.0.1", "via-direct");
        request("MailMaster", "proxy.example.test", proxied);
        direct.healthy.store(true, Ordering::Relaxed);
        health_check();
        wait("DIRECT");
        request("WeChat", "127.0.0.1", "via-direct");
    }
}
