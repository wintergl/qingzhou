use serde_json::{Value, json};
use splitvpn_core::{company, config, platform, routing, storage::Storage};

fn settings_and_store(dir: &tempfile::TempDir) -> (Storage, Value) {
    let store = Storage::new(dir.path().into());
    store
        .write(
            "subscription.json",
            &json!({"entries":[{"id":"fixture","enabled":true,"nodeCount":1}]}),
        )
        .unwrap();
    store
        .write(
            "mihomo/providers/subscription-manifest.json",
            &json!({"schemaVersion":1,"entries":[{"subscriptionId":"fixture","providerPath":"fixture.yaml","providerRevision":"fixture"}]}),
        )
        .unwrap();
    let mut settings = store.settings().unwrap();
    settings["unknownTraffic"] = json!("vpn");
    settings["geoFallback"] = json!("follow-default");
    settings["vpnDomainRules"] = json!(["DOMAIN,example.test"]);
    settings["specialCompatibilityRules"]["wechatImageSendFallback"] = json!(false);
    (store, settings)
}

fn contains_ip(cidrs: &Value, ip: &str) -> bool {
    cidrs
        .as_array()
        .unwrap()
        .iter()
        .any(|cidr| routing::matches(&format!("IP-CIDR,{}", cidr.as_str().unwrap()), ip))
}

#[test]
fn lan_ips_keep_their_destination_before_geo_or_unmatched_routing() {
    for geo in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let (store, mut settings) = settings_and_store(&dir);
        if geo {
            for name in ["GeoSite.dat", "country.mmdb", "geoip.metadb"] {
                std::fs::write(store.path(&format!("mihomo/{name}")), b"fixture").unwrap();
            }
        }
        for unknown in ["direct", "vpn"] {
            settings["unknownTraffic"] = json!(unknown);
            let c = config::build(&store, &settings, 7894, 9094, None, false).unwrap();
            let skipped = &c["sniffer"]["skip-dst-address"];
            for ip in [
                "10.0.0.8",
                "172.16.0.8",
                "192.168.0.8",
                "100.64.0.8",
                "127.0.0.1",
                "169.254.0.8",
                "::1",
                "fd00::8",
                "fe80::8",
            ] {
                assert!(
                    contains_ip(skipped, ip),
                    "{ip}, geo={geo}, default={unknown}"
                );
            }
            assert!(!contains_ip(skipped, "203.0.113.8"));
            let rules = c["rules"].as_array().unwrap();
            assert_eq!(rules[0], "GEOIP,lan,DIRECT,no-resolve");
            assert_eq!(
                rules.last().unwrap(),
                &format!("MATCH,{}", if unknown == "vpn" { "VPN" } else { "DIRECT" })
            );
        }
    }
}

#[test]
fn local_sniffing_exclusions_follow_the_direct_settings() {
    let dir = tempfile::tempdir().unwrap();
    let (store, mut settings) = settings_and_store(&dir);
    settings["lanDirect"] = json!(false);
    settings["tailscaleDirect"] = json!(false);
    let c = config::build(&store, &settings, 7894, 9094, None, false).unwrap();
    for ip in [
        "10.0.0.8",
        "172.16.0.8",
        "192.168.0.8",
        "100.64.0.8",
        "fd00::8",
    ] {
        assert!(!contains_ip(&c["sniffer"]["skip-dst-address"], ip));
    }
    assert!(contains_ip(&c["sniffer"]["skip-dst-address"], "127.0.0.1"));
    assert!(
        !c["rules"]
            .as_array()
            .unwrap()
            .contains(&json!("GEOIP,lan,DIRECT,no-resolve"))
    );
}

#[test]
fn physical_connected_networks_ignore_tunnels_inactive_links_and_invalid_masks() {
    let fixture = "en16: flags=8863<UP,BROADCAST,RUNNING> mtu 1500\n\tinet 10.0.0.8 netmask 0xffffff00 broadcast 10.0.0.255\n\tstatus: active\nen0: flags=8863<UP,BROADCAST,RUNNING> mtu 1500\n\tinet 192.0.2.8 netmask 0xffffff00 broadcast 192.0.2.255\n\tinet 192.0.2.9 netmask 0xffffff00 broadcast 192.0.2.255\n\tstatus: active\nen4: flags=8863<UP,BROADCAST> mtu 1500\n\tinet 10.1.0.8 netmask 0xffffff00\n\tstatus: inactive\nutun7: flags=8051<UP,POINTOPOINT,RUNNING> mtu 1500\n\tinet 198.18.0.1 netmask 0xfffffffc\n\tstatus: active\nbridge100: flags=8863<UP,BROADCAST,RUNNING> mtu 1500\n\tinet 10.2.0.8 netmask 0xffffff00\n\tstatus: active\nen5: flags=8863<UP,BROADCAST,RUNNING> mtu 1500\n\tinet 169.254.0.8 netmask 0xffffff00\n\tinet 10.3.0.8 netmask 0xff00ff00\n\tstatus: active\n";
    assert_eq!(
        platform::connected_ipv4_networks(fixture),
        ["10.0.0.0/24", "192.0.2.0/24"]
    );
}

#[test]
fn office_network_is_preserved_while_remote_company_addresses_are_intercepted() {
    let dir = tempfile::tempdir().unwrap();
    let (store, settings) = settings_and_store(&dir);
    let c = config::build(&store, &settings, 7894, 9094, None, false).unwrap();
    let rows = json!([{"address":"10.0.0.0/8","ports":"443","network":"tcp"}]);
    let original = company::compile(c.clone(), 1080, "COMPANY-01234567", &rows).unwrap();
    assert!(!contains_ip(
        &original.config["tun"]["route-exclude-address"],
        "10.0.0.8"
    ));
    let plan =
        company::compile_with_underlay(c, 1080, "COMPANY-01234567", &rows, &["10.0.0.0/24".into()])
            .unwrap();
    assert!(contains_ip(
        &plan.config["tun"]["route-exclude-address"],
        "10.0.0.8"
    ));
    assert!(!contains_ip(
        &plan.config["tun"]["route-exclude-address"],
        "10.20.0.8"
    ));
    assert!(
        plan.config["rules"][0]
            .as_str()
            .unwrap()
            .contains("COMPANY-01234567")
    );
    assert_eq!(plan.rule_count, original.rule_count);
}

#[test]
fn company_resource_matching_a_connected_route_cannot_install_that_tun_route() {
    let dir = tempfile::tempdir().unwrap();
    let (store, settings) = settings_and_store(&dir);
    let c = config::build(&store, &settings, 7894, 9094, None, false).unwrap();
    let rows = json!([{"address":"10.0.0.0/24","ports":"443","network":"tcp"}]);
    let original = company::compile(c.clone(), 1080, "COMPANY-01234567", &rows).unwrap();
    let ranges = |c: &Value| {
        let excluded = c["tun"]["route-exclude-address"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s.as_str().unwrap().to_owned())
            .collect::<Vec<_>>();
        company::subtract_routes(&["0.0.0.0/0".into()], &excluded).unwrap()
    };
    assert!(ranges(&original.config).contains(&"10.0.0.0/24".into()));
    let plan =
        company::compile_with_underlay(c, 1080, "COMPANY-01234567", &rows, &["10.0.0.0/24".into()])
            .unwrap();
    assert!(!ranges(&plan.config).contains(&"10.0.0.0/24".into()));
    assert!(!contains_ip(&json!(ranges(&plan.config)), "10.0.0.8"));
}

#[test]
fn authorized_private_resources_keep_priority_over_lan_direct() {
    let dir = tempfile::tempdir().unwrap();
    let (store, settings) = settings_and_store(&dir);
    let c = config::build(&store, &settings, 7894, 9094, None, false).unwrap();
    let plan = company::compile(
        c,
        1080,
        "COMPANY-01234567",
        &json!([{"address":"10.0.0.8","ports":"80","network":"tcp"}]),
    )
    .unwrap();
    assert!(
        plan.config["rules"][0]
            .as_str()
            .unwrap()
            .ends_with(",COMPANY-01234567")
    );
    assert!(contains_ip(
        &plan.config["sniffer"]["skip-dst-address"],
        "10.0.0.8"
    ));
    assert!(!contains_ip(
        &plan.config["tun"]["route-exclude-address"],
        "10.0.0.8"
    ));
}

#[test]
#[ignore = "runs bundled Mihomo with loopback proxy sinks; TUN and DNS are disabled"]
fn real_mihomo_preserves_private_ip_when_http_host_is_a_domain() {
    use std::{
        io::{BufRead, BufReader, Read, Write},
        net::{SocketAddr, TcpListener, TcpStream},
        process::{Child, Command, Stdio},
        sync::{
            Arc, Mutex,
            atomic::{AtomicBool, Ordering},
        },
        thread,
        time::Duration,
    };

    struct Sink {
        address: SocketAddr,
        targets: Arc<Mutex<Vec<String>>>,
        stopping: Arc<AtomicBool>,
        worker: Option<thread::JoinHandle<()>>,
    }
    impl Sink {
        fn new() -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            let targets = Arc::new(Mutex::new(Vec::new()));
            let stopping = Arc::new(AtomicBool::new(false));
            let (recorded, stopped) = (targets.clone(), stopping.clone());
            let worker = thread::spawn(move || {
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
                    reader.read_line(&mut line).unwrap();
                    recorded.lock().unwrap().push(line.trim().to_owned());
                    loop {
                        line.clear();
                        if reader.read_line(&mut line).unwrap() == 0 || line == "\r\n" {
                            break;
                        }
                    }
                    stream
                        .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                        .unwrap();
                    loop {
                        line.clear();
                        if reader.read_line(&mut line).unwrap() == 0 || line == "\r\n" {
                            break;
                        }
                    }
                    stream.write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
                }
            });
            Self {
                address,
                targets,
                stopping,
                worker: Some(worker),
            }
        }
    }
    impl Drop for Sink {
        fn drop(&mut self) {
            self.stopping.store(true, Ordering::Relaxed);
            let _ = TcpStream::connect(self.address);
            let _ = self.worker.take().unwrap().join();
        }
    }
    struct Engine(Child);
    impl Drop for Engine {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let dir = tempfile::tempdir().unwrap();
    let (store, settings) = settings_and_store(&dir);
    let (lan, vpn) = (Sink::new(), Sink::new());
    let mixed_listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let mixed = mixed_listener.local_addr().unwrap();
    drop(mixed_listener);
    let mut c = config::build(&store, &settings, mixed.port(), 0, None, false).unwrap();
    c["tun"]["enable"] = json!(false);
    c["dns"]["enable"] = json!(false);
    c["geo-auto-update"] = json!(false);
    c["external-controller"] = json!("");
    c["log-level"] = json!("error");
    c["profile"] = json!({"store-selected":false,"store-fake-ip":false});
    c["proxy-providers"] = json!({});
    c["proxy-groups"] = json!([{"name":"VPN","type":"select","proxies":["fixture-vpn"]}]);
    c["proxies"] = json!([
        {"name":"fixture-lan","type":"http","server":"127.0.0.1","port":lan.address.port()},
        {"name":"fixture-vpn","type":"http","server":"127.0.0.1","port":vpn.address.port()}
    ]);
    // Both outlets terminate at loopback sinks; no target is ever contacted.
    for rule in c["rules"].as_array_mut().unwrap() {
        *rule = json!(rule.as_str().unwrap().replace(",DIRECT", ",fixture-lan"));
    }
    let provider = store.path("mihomo/providers/vpn-domains.yaml");
    store
        .write(
            "mihomo/providers/vpn-domains.yaml",
            &json!({"payload":settings["vpnDomainRules"]}),
        )
        .unwrap();
    c["rule-providers"]["vpn-domains"]["path"] = json!(provider);
    let path = store.path("mihomo/config.json");
    std::fs::write(&path, c.to_string()).unwrap();
    let arch = match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => "darwin-arm64",
        ("macos", "x86_64") => "darwin-x64",
        ("linux", "x86_64") => "linux-x64",
        other => panic!("no bundled fixture engine for {other:?}"),
    };
    let binary = std::env::var_os("SPLITVPN_TEST_MIHOMO")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join(format!("../../resources/mihomo/{arch}/mihomo"))
        });
    let mut engine = Engine(
        Command::new(binary)
            .args([
                "-d",
                store.path("mihomo").to_str().unwrap(),
                "-f",
                path.to_str().unwrap(),
            ])
            .env("SPLITVPN_ISOLATED", "1")
            .env("SPLITVPN_DATA_DIR", dir.path())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let mut ready = false;
    for _ in 0..100 {
        assert!(
            engine.0.try_wait().unwrap().is_none(),
            "Mihomo exited during startup"
        );
        if TcpStream::connect(mixed).is_ok() {
            ready = true;
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    assert!(ready, "isolated mixed port not ready");
    for (ip, host, expected_lan) in [
        ("10.0.0.8", "10.0.0.8", true),
        ("10.0.0.8", "example.test", true),
        ("172.16.0.8", "example.test", true),
        ("192.168.0.8", "example.test", true),
        ("100.64.0.8", "example.test", true),
        ("fd00::8", "example.test", true),
        ("203.0.113.8", "example.test", false),
    ] {
        let before = (
            lan.targets.lock().unwrap().len(),
            vpn.targets.lock().unwrap().len(),
        );
        let mut stream = TcpStream::connect(mixed).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(4)))
            .unwrap();
        stream.write_all(&[5, 1, 0]).unwrap();
        let mut greeting = [0; 2];
        stream.read_exact(&mut greeting).unwrap();
        assert_eq!(greeting, [5, 0]);
        let mut request = vec![5, 1, 0];
        match ip.parse::<std::net::IpAddr>().unwrap() {
            std::net::IpAddr::V4(ip) => {
                request.push(1);
                request.extend(ip.octets());
            }
            std::net::IpAddr::V6(ip) => {
                request.push(4);
                request.extend(ip.octets());
            }
        }
        request.extend(80_u16.to_be_bytes());
        stream.write_all(&request).unwrap();
        let mut reply = [0; 4];
        stream.read_exact(&mut reply).unwrap();
        assert_eq!(reply[1], 0);
        let mut address = vec![
            0;
            match reply[3] {
                1 => 6,
                4 => 18,
                other => panic!("unexpected reply {other}"),
            }
        ];
        stream.read_exact(&mut address).unwrap();
        stream
            .write_all(
                format!("GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n").as_bytes(),
            )
            .unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).unwrap();
        assert!(response.contains("204 No Content"), "{ip}: {response}");
        let after = (
            lan.targets.lock().unwrap().len(),
            vpn.targets.lock().unwrap().len(),
        );
        assert_eq!(
            after,
            if expected_lan {
                (before.0 + 1, before.1)
            } else {
                (before.0, before.1 + 1)
            },
            "{ip}, Host={host}"
        );
        if expected_lan {
            assert_eq!(
                lan.targets.lock().unwrap().last().unwrap(),
                &format!("CONNECT {ip}:80 HTTP/1.1")
                    .replace("CONNECT fd00::8:", "CONNECT [fd00::8]:")
            );
        }
    }
}
