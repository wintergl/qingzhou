use serde_json::{Value, json};
use splitvpn_core::{
    static_exit::{self, EXIT},
    storage::normalize_settings,
};

fn fixture() -> (Value, Value, Value) {
    let c = json!({"proxy-providers":{"airport":{"type":"file"}},"proxies":[],"proxy-groups":[{"name":"VPN","type":"select","proxies":["airport"]},{"name":"WECHAT","type":"fallback","proxies":["DIRECT","VPN"]}],"rules":["IP-CIDR,10.0.0.0/8,DIRECT,no-resolve","DOMAIN,example.test,VPN","MATCH,VPN"]});
    let s = json!({"selectedProxy":"airport","staticExit":{"enabled":true,"protocol":"socks5","server":"proxy.example.test","port":1080,"username":"fixture","expectedIp":"203.0.113.8"}});
    let cred = json!({"configuration":s["staticExit"],"password":"fixture-only"});
    (c, s, cred)
}
#[test]
fn optional_exit_preserves_old_and_disabled_settings() {
    let normalized = normalize_settings(json!({"customFutureField":{"preserved":true}})).unwrap();
    assert_eq!(normalized["staticExit"]["enabled"], false);
    assert_eq!(normalized["customFutureField"]["preserved"], true);
    let (mut c, mut s, cred) = fixture();
    let before = c.clone();
    s["staticExit"]["enabled"] = json!(false);
    static_exit::apply(&mut c, &s, &cred, 1234).unwrap();
    assert_eq!(before, c);
}
#[test]
fn uses_airport_as_front_hop_and_keeps_direct_rules() {
    let (mut c, s, cred) = fixture();
    static_exit::apply(&mut c, &s, &cred, 1234).unwrap();
    assert_eq!(c["proxies"][0]["dialer-proxy"], "VPN");
    assert_eq!(c["proxy-groups"][0]["proxies"], json!(["airport"]));
    assert_eq!(c["proxy-groups"][1]["type"], "fallback");
    assert_eq!(c["proxy-groups"][1]["proxies"], json!(["DIRECT", EXIT]));
    assert_eq!(c["rules"][0], "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve");
    assert!(
        c["rules"]
            .as_array()
            .unwrap()
            .contains(&json!(format!("DOMAIN,example.test,{EXIT}")))
    );
    assert_eq!(c["rules"][3], "NETWORK,UDP,REJECT");
    assert_eq!(c["listeners"][0]["proxy"], EXIT);
    assert_eq!(c["listeners"][0]["listen"], "127.0.0.1");
}
#[test]
fn credentials_are_bound_to_endpoint_and_do_not_silently_fallback() {
    let (c, mut s, cred) = fixture();
    for change in ["server", "port", "username", "protocol"] {
        let mut altered = s.clone();
        altered["staticExit"][change] = if change == "port" {
            json!(8888)
        } else if change == "protocol" {
            json!("https")
        } else {
            json!("different")
        };
        assert!(static_exit::apply(&mut c.clone(), &altered, &cred, 1234).is_err());
    }
    assert!(static_exit::apply(&mut c.clone(), &s, &Value::Null, 1234).is_err());
    s["selectedProxy"] = json!("DIRECT");
    assert!(static_exit::apply(&mut c.clone(), &s, &cred, 1234).is_err());
}
#[test]
fn parses_provider_format_without_truncating_password() {
    let parsed =
        static_exit::parse_line("proxy.example.test:1080:fixture:pass:with:colons\n").unwrap();
    assert_eq!(parsed["password"], "pass:with:colons");
    assert_eq!(parsed["configuration"]["port"], 1080);
    for input in [
        "bad",
        "proxy.example.test:0:u:p",
        "proxy.example.test:70000:u:p",
        "https://example.test:80:u:p",
    ] {
        assert!(static_exit::parse_line(input).is_err());
    }
}
#[test]
fn protocol_and_whitelist_modes_and_validation() {
    let (c, mut s, cred) = fixture();
    for protocol in ["socks5", "http", "https"] {
        s["staticExit"]["protocol"] = json!(protocol);
        let cred = json!({"configuration":s["staticExit"],"password":cred["password"]});
        let mut compiled = c.clone();
        static_exit::apply(&mut compiled, &s, &cred, 1234).unwrap();
        assert_eq!(
            compiled["proxies"][0]["type"],
            if protocol == "socks5" {
                "socks5"
            } else {
                "http"
            }
        );
        assert_eq!(compiled["proxies"][0]["tls"] == true, protocol == "https");
    }
    s["staticExit"]["username"] = json!("");
    static_exit::apply(&mut c.clone(), &s, &Value::Null, 1234).unwrap();
    s["staticExit"]["expectedIp"] = json!("not-an-ip");
    assert!(static_exit::validate(&s["staticExit"]).is_err());
}

/// Runs the shipped data plane against loopback only. A fake airport records
/// the CONNECT destination and then speaks SOCKS5 as the final hop would.
#[test]
#[ignore = "runs bundled Mihomo; loopback only, TUN/DNS/health checks disabled"]
fn real_mihomo_chains_and_switches_airport_without_bypassing_exit() {
    use std::{
        io::{BufRead, BufReader, Read, Write},
        net::{TcpListener, TcpStream},
        process::{Command, Stdio},
        sync::{
            Arc, Mutex,
            atomic::{AtomicBool, Ordering},
        },
        thread,
        time::Duration,
    };
    struct Airport {
        port: u16,
        records: Arc<Mutex<Vec<String>>>,
        stop: Arc<AtomicBool>,
        thread: Option<thread::JoinHandle<()>>,
    }
    impl Airport {
        fn new() -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            let records = Arc::new(Mutex::new(Vec::new()));
            let captured = records.clone();
            let stop = Arc::new(AtomicBool::new(false));
            let stopped = stop.clone();
            let thread = thread::spawn(move || {
                for stream in listener.incoming() {
                    if stopped.load(Ordering::Relaxed) {
                        break;
                    }
                    let mut stream = stream.unwrap();
                    stream
                        .set_read_timeout(Some(Duration::from_secs(3)))
                        .unwrap();
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut line = String::new();
                    if reader.read_line(&mut line).is_err() {
                        continue;
                    }
                    captured.lock().unwrap().push(line.trim().to_owned());
                    let chained = line.contains("127.0.0.1:18888");
                    loop {
                        line.clear();
                        if reader.read_line(&mut line).unwrap() == 0 || line == "\r\n" {
                            break;
                        }
                    }
                    stream
                        .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                        .unwrap();
                    if chained {
                        let mut head = [0; 2];
                        reader.read_exact(&mut head).unwrap();
                        assert_eq!(head[0], 5);
                        let mut methods = vec![0; head[1] as usize];
                        reader.read_exact(&mut methods).unwrap();
                        assert!(methods.contains(&2));
                        stream.write_all(&[5, 2]).unwrap();
                        reader.read_exact(&mut head).unwrap();
                        assert_eq!(head[0], 1);
                        let mut user = vec![0; head[1] as usize];
                        reader.read_exact(&mut user).unwrap();
                        let mut len = [0; 1];
                        reader.read_exact(&mut len).unwrap();
                        let mut pass = vec![0; len[0] as usize];
                        reader.read_exact(&mut pass).unwrap();
                        captured
                            .lock()
                            .unwrap()
                            .push(format!("auth-user:{}", String::from_utf8(user).unwrap()));
                        if pass != b"fixture-only" {
                            stream.write_all(&[1, 1]).unwrap();
                            continue;
                        }
                        stream.write_all(&[1, 0]).unwrap();
                        let mut command = [0; 4];
                        reader.read_exact(&mut command).unwrap();
                        assert_eq!(&command[..3], &[5, 1, 0]);
                        let count = match command[3] {
                            1 => 4,
                            4 => 16,
                            3 => {
                                reader.read_exact(&mut len).unwrap();
                                len[0] as usize
                            }
                            _ => panic!("invalid SOCKS address"),
                        };
                        let mut address = vec![0; count + 2];
                        reader.read_exact(&mut address).unwrap();
                        stream.write_all(&[5, 0, 0, 1, 127, 0, 0, 1, 0, 0]).unwrap();
                    }
                    loop {
                        line.clear();
                        if reader.read_line(&mut line).unwrap() == 0 || line == "\r\n" {
                            break;
                        }
                    }
                    let body = if chained { "via-static" } else { "via-airport" };
                    write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    )
                    .unwrap();
                }
            });
            Self {
                port,
                records,
                stop,
                thread: Some(thread),
            }
        }
    }
    impl Drop for Airport {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            let _ = TcpStream::connect(("127.0.0.1", self.port));
            let _ = self.thread.take().unwrap().join();
        }
    }
    struct Engine(std::process::Child);
    impl Drop for Engine {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    fn free_port() -> u16 {
        TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port()
    }
    let a = Airport::new();
    let b = Airport::new();
    let dir = tempfile::tempdir().unwrap();
    let store = splitvpn_core::storage::Storage::new(dir.path().into());
    let provider = store.path("mihomo/providers/airport.json");
    store.write("mihomo/providers/airport.json",&json!({"proxies":[{"name":"airport-a","type":"http","server":"127.0.0.1","port":a.port},{"name":"airport-b","type":"http","server":"127.0.0.1","port":b.port}]})).unwrap();
    store
        .write(
            "subscription.json",
            &json!({"entries":[{"id":"fixture","enabled":true,"nodeCount":2}]}),
        )
        .unwrap();
    store.write("mihomo/providers/subscription-manifest.json",&json!({"schemaVersion":1,"entries":[{"subscriptionId":"fixture","providerPath":provider,"providerRevision":"fixture"}]})).unwrap();
    let mut settings = store.settings().unwrap();
    settings["selectedProxy"] = json!("airport-a");
    settings["unknownTraffic"] = json!("direct");
    settings["vpnDomainRules"] = json!(["DOMAIN,example.test"]);
    splitvpn_core::storage::atomic_write(
        &store.path("mihomo/providers/vpn-domains.yaml"),
        splitvpn_core::config::yaml(&json!({"payload":settings["vpnDomainRules"]}))
            .unwrap()
            .as_bytes(),
    )
    .unwrap();
    settings["lanDirect"] = json!(false);
    settings["geoFallback"] = json!("follow-default");
    settings["tun"] = json!(false);
    settings["specialCompatibilityRules"]["wechatImageSendFallback"] = json!(false);
    settings["staticExit"] = json!({"enabled":true,"protocol":"socks5","server":"127.0.0.1","port":18888,"username":"fixture","expectedIp":""});
    let credential = json!({"configuration":settings["staticExit"],"password":"fixture-only"});
    let mixed = free_port();
    let controller = free_port();
    let probe = free_port();
    let scan_probe = free_port();
    let mut config =
        splitvpn_core::config::build(&store, &settings, mixed, controller, None, false).unwrap();
    config["dns"]["enable"] = json!(false);
    config["geo-auto-update"] = json!(false);
    config["sniffer"]["enable"] = json!(false);
    config["log-level"] = json!("silent");
    config["hosts"] = json!({"example.test":"127.0.0.9","probe-only.example.test":"127.0.0.9"});
    config["profile"] = json!({"store-selected":false,"store-fake-ip":false});
    config["proxy-groups"]
        .as_array_mut()
        .unwrap()
        .retain(|g| g["name"] == "VPN");
    config["proxy-groups"][0]["proxies"] = json!([]);
    for p in config["proxy-providers"]
        .as_object_mut()
        .unwrap()
        .values_mut()
    {
        p["health-check"]["enable"] = json!(false);
    }
    static_exit::apply(&mut config, &settings, &credential, probe).unwrap();
    static_exit::add_scan(&mut config, scan_probe).unwrap();
    let path = store.path("mihomo/config.json");
    std::fs::write(&path, config.to_string()).unwrap();
    let arch = match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => "darwin-arm64",
        ("macos", "x86_64") => "darwin-x64",
        ("linux", "x86_64") => "linux-x64",
        v => panic!("unsupported {v:?}"),
    };
    let binary = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join(format!("../../resources/mihomo/{arch}/mihomo"));
    let mut engine = Engine(
        Command::new(binary)
            .arg("-d")
            .arg(store.path("mihomo"))
            .arg("-f")
            .arg(&path)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let api = reqwest::blocking::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(3))
        .build()
        .unwrap();
    let endpoint = format!("http://127.0.0.1:{controller}");
    let secret = config["secret"].as_str().unwrap().to_owned();
    for _ in 0..100 {
        if api
            .get(format!("{endpoint}/version"))
            .bearer_auth(&secret)
            .send()
            .is_ok()
        {
            break;
        }
        assert!(
            engine.0.try_wait().unwrap().is_none(),
            "Mihomo rejected generated config"
        );
        thread::sleep(Duration::from_millis(30));
    }
    let fetch = |port, host| {
        reqwest::blocking::Client::builder()
            .no_proxy()
            .pool_max_idle_per_host(0)
            .timeout(Duration::from_secs(3))
            .proxy(reqwest::Proxy::all(format!("http://127.0.0.1:{port}")).unwrap())
            .build()
            .unwrap()
            .get(format!("http://{host}/check"))
            .send()
            .and_then(|r| r.error_for_status())
            .and_then(|r| r.text())
    };
    for airport in ["airport-a", "airport-b"] {
        api.put(format!("{endpoint}/proxies/VPN"))
            .bearer_auth(&secret)
            .json(&json!({"name":airport}))
            .send()
            .unwrap()
            .error_for_status()
            .unwrap();
        let scan_airport = if airport == "airport-a" {
            "airport-b"
        } else {
            "airport-a"
        };
        api.put(format!("{endpoint}/proxies/{}", static_exit::SCAN_FRONT))
            .bearer_auth(&secret)
            .json(&json!({"name":scan_airport}))
            .send()
            .unwrap()
            .error_for_status()
            .unwrap();
        assert_eq!(
            fetch(scan_probe, "probe-only.example.test").unwrap(),
            "via-static"
        );
        let live: Value = api
            .get(format!("{endpoint}/proxies/VPN"))
            .bearer_auth(&secret)
            .send()
            .unwrap()
            .json()
            .unwrap();
        assert_eq!(
            live["now"], airport,
            "scan must not move the live airport selector"
        );
        assert_eq!(fetch(mixed, "example.test").unwrap(), "via-static");
        assert_eq!(
            fetch(probe, "probe-only.example.test").unwrap(),
            "via-static"
        );
    }
    for airport in [&a, &b] {
        let records = airport.records.lock().unwrap();
        assert!(records.iter().any(|s| s.contains("127.0.0.1:18888")));
        assert!(records.iter().any(|s| s == "auth-user:fixture"));
        assert!(
            !records
                .iter()
                .any(|s| s.starts_with("CONNECT example.test:"))
        );
    }
    // Wrong final-hop credentials must fail rather than return airport content.
    config["proxies"][0]["password"] = json!("wrong-fixture");
    api.put(format!("{endpoint}/configs?force=true"))
        .bearer_auth(&secret)
        .json(&json!({"payload":config.to_string()}))
        .send()
        .unwrap()
        .error_for_status()
        .unwrap();
    assert!(fetch(mixed, "example.test").is_err());
    // Disabling removes the final hop, restoring the original airport path.
    config["proxies"] = json!([]);
    config["listeners"] = json!([]);
    config["rules"] = json!(["MATCH,VPN"]);
    api.put(format!("{endpoint}/configs?force=true"))
        .bearer_auth(&secret)
        .json(&json!({"payload":config.to_string()}))
        .send()
        .unwrap()
        .error_for_status()
        .unwrap();
    assert_eq!(fetch(mixed, "example.test").unwrap(), "via-airport");
}
