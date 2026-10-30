//! A user-owned, loopback-only engine for ISP tests without a VPN connection.
use super::*;

pub(super) struct ChainProbe {
    child: Option<Child>,
    store: Storage,
    pub io: ControllerIo,
    pub port: u16,
}
impl Drop for ChainProbe {
    fn drop(&mut self) {
        self.stop();
    }
}
impl ChainProbe {
    pub fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = fs::remove_dir_all(&self.store.root);
    }
}
impl ChainProbe {
    pub fn start(c: &Core, settings: &Value) -> Result<Self> {
        let store = Storage::new(
            c.engine
                .store
                .path(&format!("runtime-state/isp-test/{}", uuid::Uuid::new_v4())),
        );
        let port = available_port(0)?;
        let mut controller = available_port(0)?;
        while controller == port {
            controller = available_port(0)?;
        }
        let secret = uuid::Uuid::new_v4().simple().to_string();
        let config = configuration(
            &c.engine.store,
            settings,
            &c.exit_credential,
            port,
            controller,
            &secret,
        )?;
        let io = ControllerIo {
            store: store.clone(),
            isolated: false,
            controller,
            client: c.engine.client.clone(),
            secret: Arc::new(Mutex::new(secret)),
        };
        let mut probe = Self {
            child: None,
            store,
            io,
            port,
        };
        atomic_write(
            &probe.store.path("mihomo/config.yaml"),
            config::yaml(&config)?.as_bytes(),
        )?;
        // No helper, TUN, system proxy, DNS listener, or privileged operation.
        probe.child = Some(
            Command::new(&c.engine.binary)
                .arg("-d")
                .arg(probe.store.path("mihomo"))
                .arg("-f")
                .arg(probe.store.path("mihomo/config.yaml"))
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .context("无法启动 ISP 独立测试内核。")?,
        );
        let until = Instant::now() + Duration::from_secs(8);
        while Instant::now() < until {
            ensure!(
                probe.child.as_mut().unwrap().try_wait()?.is_none(),
                "ISP 测试内核启动失败，请检查已保存配置。"
            );
            if probe.io.api("GET", "/version", None).is_ok() {
                return Ok(probe);
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        bail!("ISP 测试内核未就绪，请重试。")
    }
}
fn configuration(
    store: &Storage,
    settings: &Value,
    credential: &Value,
    port: u16,
    controller: u16,
    secret: &str,
) -> Result<Value> {
    let inventory = subscription::provider_nodes(store)?;
    let mut providers = serde_json::Map::new();
    let mut names = Vec::new();
    for (entry, _, nodes) in subscription::enabled_providers(store)? {
        let nodes: Vec<_> = nodes
            .into_iter()
            .filter(|n| {
                inventory.iter().any(|i| {
                    i["identityKey"]
                        == crate::storage::identity(
                            entry["id"].as_str().unwrap_or(""),
                            n["name"].as_str().unwrap_or(""),
                        )
                        && i["identityAmbiguous"] == false
                })
            })
            .collect();
        if nodes.is_empty() {
            continue;
        }
        let name = format!("provider-{}", names.len());
        names.push(name.clone());
        providers.insert(name, json!({"type":"inline","payload":nodes}));
    }
    ensure!(!names.is_empty(), "没有可测试的机场节点。");
    let mut s = settings.clone();
    s["staticExit"]["enabled"] = json!(true);
    s["selectedProxy"] = json!("test-front");
    let mut config = json!({"mode":"rule","log-level":"silent","allow-lan":false,"bind-address":"127.0.0.1","external-controller":format!("127.0.0.1:{controller}"),"secret":secret,"tun":{"enable":false},"dns":{"enable":false},"geo-auto-update":false,"profile":{"store-selected":false},"proxies":[],"proxy-providers":providers,"proxy-groups":[{"name":"VPN","type":"select","use":names}],"rules":["MATCH,REJECT"]});
    crate::static_exit::apply(&mut config, &s, credential, port)?;
    // Only the scanner listener is exposed; no business proxy listener.
    config["listeners"] = json!([]);
    crate::static_exit::add_scan(&mut config, port)?;
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_isp_builds_a_loopback_only_scanner_and_requires_credentials() {
        let root = tempfile::tempdir().unwrap();
        let store = Storage::new(root.path().to_path_buf());
        store
            .write(
                "subscription.json",
                &json!({"entries":[{"id":"one","enabled":true,"nodeCount":1}]}),
            )
            .unwrap();
        store
            .write(
                "mihomo/providers/one.yaml",
                &json!({"proxies":[{"name":"node-a","type":"http","server":"127.0.0.1","port":9}]}),
            )
            .unwrap();
        store.write("mihomo/providers/subscription-manifest.json", &json!({"schemaVersion":1,"revision":"test","entries":[{"subscriptionId":"one","providerPath":store.path("mihomo/providers/one.yaml"),"providerRevision":"test"}]})).unwrap();
        let settings = json!({"selectedProxy":"DIRECT","staticExit":{"enabled":false,"protocol":"socks5","server":"proxy.example.test","port":1080,"username":"fixture","expectedIp":""}});
        assert!(
            configuration(&store, &settings, &Value::Null, 12345, 12346, "test-secret").is_err()
        );
        let credential = json!({"configuration":settings["staticExit"],"password":"fixture-only"});
        let config =
            configuration(&store, &settings, &credential, 12345, 12346, "test-secret").unwrap();
        assert_eq!(settings["staticExit"]["enabled"], false);
        assert_eq!(config["tun"]["enable"], false);
        assert_eq!(config["dns"]["enable"], false);
        assert_eq!(config["allow-lan"], false);
        assert!(config["mixed-port"].is_null());
        assert_eq!(config["listeners"].as_array().unwrap().len(), 1);
        assert_eq!(config["listeners"][0]["listen"], "127.0.0.1");
        assert_eq!(
            config["listeners"][0]["proxy"],
            crate::static_exit::SCAN_EXIT
        );
        assert_eq!(config["rules"], json!(["MATCH,REJECT"]));
        // Validate with the shipped parser, without launching a data plane.
        #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
        {
            let binary = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../resources/mihomo/darwin-arm64/mihomo");
            if binary.is_file() {
                let path = store.path("probe.yaml");
                atomic_write(&path, config::yaml(&config).unwrap().as_bytes()).unwrap();
                let result = Command::new(binary)
                    .arg("-t")
                    .arg("-d")
                    .arg(root.path())
                    .arg("-f")
                    .arg(path)
                    .output()
                    .unwrap();
                assert!(
                    result.status.success(),
                    "{}",
                    String::from_utf8_lossy(&result.stdout)
                );
                let resources = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("../../resources/mihomo/darwin-arm64");
                let mut core = Core::new(
                    store.root.clone(),
                    resources,
                    true,
                    Arc::new(|_, _| {}),
                    Arc::new(Jobs::default()),
                )
                .unwrap();
                core.exit_credential = credential;
                let probe = ChainProbe::start(&core, &settings).unwrap();
                assert!(probe.io.api("GET", "/version", None).is_ok());
                let directory = probe.store.root.clone();
                let probe = Arc::new(Mutex::new(probe));
                core.chain_probe = Some(probe.clone());
                core.shutdown();
                assert!(probe.lock().unwrap().child.is_none());
                assert!(!directory.exists());
            }
        }
    }
}
