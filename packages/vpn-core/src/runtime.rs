use crate::{
    background::RuntimeEnvironment,
    company::Company,
    config,
    connection_health::ConnectionHealth,
    network,
    network_recovery::NetworkRecovery,
    platform,
    storage::{
        Storage, atomic_write, encode, group_runtime_name, normalize_settings, now, redact,
        summarize_subscription,
    },
    subscription,
};
use anyhow::{Context, Result, bail, ensure};
use reqwest::blocking::Client;
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    fs,
    io::{Read, Write},
    net::{TcpListener, TcpStream, UdpSocket},
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

pub type Events = Arc<dyn Fn(&str, Value) + Send + Sync>;
/// Due `(id, url)` pairs plus the proxy port to download through.
pub type DueDownloads = (Vec<(String, String)>, Option<u16>);

#[cfg(all(test, unix))]
mod helper_upgrade_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    struct Controller {
        port: u16,
        selected: Arc<Mutex<String>>,
        writes: Arc<AtomicU64>,
        configuration: Arc<Mutex<String>>,
        deletes: Arc<Mutex<Vec<String>>>,
        fail_reload: Arc<AtomicBool>,
        fail_delete: Arc<AtomicBool>,
        stop: Arc<AtomicBool>,
        thread: Option<std::thread::JoinHandle<()>>,
    }
    impl Controller {
        fn new() -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            let selected = Arc::new(Mutex::new("原节点".to_owned()));
            let writes = Arc::new(AtomicU64::new(0));
            let configuration = Arc::new(Mutex::new(
                "interface-name: en0\ntun:\n  enable: false\n".to_owned(),
            ));
            let deletes = Arc::new(Mutex::new(Vec::new()));
            let fail_reload = Arc::new(AtomicBool::new(false));
            let fail_delete = Arc::new(AtomicBool::new(false));
            let stop = Arc::new(AtomicBool::new(false));
            let (choice, count, done) = (selected.clone(), writes.clone(), stop.clone());
            let (current_config, closed, fail) =
                (configuration.clone(), deletes.clone(), fail_reload.clone());
            let fail_close = fail_delete.clone();
            let thread = std::thread::spawn(move || {
                for stream in listener.incoming() {
                    if done.load(Ordering::SeqCst) {
                        break;
                    }
                    let mut stream = stream.unwrap();
                    stream
                        .set_read_timeout(Some(Duration::from_secs(3)))
                        .unwrap();
                    let mut request = Vec::new();
                    let mut byte = [0];
                    while !request.ends_with(b"\r\n\r\n") {
                        if stream.read(&mut byte).unwrap() == 0 {
                            break;
                        }
                        request.push(byte[0]);
                    }
                    let head = String::from_utf8(request).unwrap();
                    let length = head
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length: ")?
                                .parse::<usize>()
                                .ok()
                        })
                        .unwrap_or(0);
                    let mut body = vec![0; length];
                    stream.read_exact(&mut body).unwrap();
                    let failed = (head.starts_with("PUT /configs")
                        && fail.swap(false, Ordering::SeqCst))
                        || (head.starts_with("DELETE ")
                            && fail_close.swap(false, Ordering::SeqCst));
                    let response = if head.starts_with("PUT /configs") {
                        if !failed {
                            *current_config.lock().unwrap() =
                                serde_json::from_slice::<Value>(&body).unwrap()["payload"]
                                    .as_str()
                                    .unwrap()
                                    .to_owned();
                        }
                        json!({})
                    } else if head.starts_with("PUT ") {
                        *choice.lock().unwrap() =
                            serde_json::from_slice::<Value>(&body).unwrap()["name"]
                                .as_str()
                                .unwrap()
                                .to_owned();
                        count.fetch_add(1, Ordering::SeqCst);
                        json!({})
                    } else if head.starts_with("GET /proxies ") {
                        json!({"proxies":{"VPN":{"type":"Selector","now":choice.lock().unwrap().clone()}}})
                    } else if head.starts_with("GET /configs ") {
                        config::parse(&current_config.lock().unwrap()).unwrap()
                    } else if head.starts_with("GET /connections ") {
                        json!({"connections":[
                            {"id":"keep-company","chains":["COMPANY-fixture","VPN"]},
                            {"id":"old-proxy","chains":["node-fixture","VPN"]},
                            {"id":"old-direct","chains":["DIRECT"]},
                            {"id":"keep-unknown","chains":[]}
                        ]})
                    } else if head.starts_with("DELETE ") {
                        if !failed {
                            closed
                                .lock()
                                .unwrap()
                                .push(head.split_whitespace().nth(1).unwrap().to_owned());
                        }
                        json!({})
                    } else {
                        json!({"version":"fixture"})
                    };
                    let response = response.to_string();
                    let status = if failed { "500 Failed" } else { "200 OK" };
                    write!(stream, "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", response.len(), response).unwrap();
                }
            });
            Self {
                port,
                selected,
                writes,
                configuration,
                deletes,
                fail_reload,
                fail_delete,
                stop,
                thread: Some(thread),
            }
        }
    }
    impl Drop for Controller {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::SeqCst);
            let _ = TcpStream::connect(("127.0.0.1", self.port));
            self.thread.take().unwrap().join().unwrap();
        }
    }
    fn exercise(cancel: bool, fail: bool) {
        let root = tempfile::tempdir().unwrap();
        let binary = root.path().join("mihomo");
        fs::write(
            &binary,
            "#!/bin/sh\nif [ \"$1\" = -t ]; then exit 0; fi\nexec /bin/sleep 60\n",
        )
        .unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).unwrap();
        let controller = Controller::new();
        let mut old = Command::new("/bin/sleep").arg("60").spawn().unwrap();
        let mut core = Core::new(
            root.path().join("data"),
            root.path().into(),
            true,
            Arc::new(|_, _| {}),
            Arc::new(Jobs::default()),
        )
        .unwrap();
        core.engine.pid = Some(old.id());
        core.engine.controller = controller.port;
        core.wants_running = true;
        atomic_write(
            &core.engine.store.path("mihomo/config.yaml"),
            b"mixed-port: 0\n",
        )
        .unwrap();
        core.engine
            .store
            .write(
                "settings.json",
                &json!({"selectedProxy":"原节点","tun":true}),
            )
            .unwrap();
        let settings = fs::read(core.engine.store.path("settings.json")).unwrap();
        let before = old.id();
        let result = core.upgrade_running_helper(|| {
            if cancel {
                bail!("authorization cancelled");
            }
            old.kill().unwrap();
            old.wait().unwrap();
            *controller.selected.lock().unwrap() = "DIRECT".into();
            if fail {
                bail!("installer rolled back");
            }
            Ok(())
        });
        assert_eq!(result.is_err(), cancel || fail);
        assert_eq!(
            fs::read(core.engine.store.path("settings.json")).unwrap(),
            settings
        );
        assert_eq!(*controller.selected.lock().unwrap(), "原节点");
        assert!(core.wants_running);
        if cancel {
            assert_eq!(core.engine.pid, Some(before));
            assert!(old.try_wait().unwrap().is_none());
            assert_eq!(controller.writes.load(Ordering::SeqCst), 0);
            assert_eq!(
                fs::read(core.engine.store.path("mihomo/config.yaml")).unwrap(),
                b"mixed-port: 0\n"
            );
            old.kill().unwrap();
            old.wait().unwrap();
            core.engine.pid = None;
        } else {
            assert_ne!(core.engine.pid, Some(before));
            assert!(
                core.engine
                    .child
                    .as_mut()
                    .unwrap()
                    .try_wait()
                    .unwrap()
                    .is_none()
            );
            assert_eq!(controller.writes.load(Ordering::SeqCst), 1);
            assert_eq!(core.engine.store.recovery().unwrap()["state"], "clear");
        }
        core.shutdown();
    }
    #[test]
    fn cancelled_authorization_keeps_connection_config_and_node() {
        exercise(true, false);
    }
    #[test]
    fn upgraded_helper_resumes_connection_and_original_node() {
        exercise(false, false);
    }
    #[test]
    fn installer_rollback_resumes_original_connection_without_new_authorization() {
        exercise(false, true);
    }

    fn recovery_fixture() -> (tempfile::TempDir, Core, Controller) {
        let root = tempfile::tempdir().unwrap();
        let binary = root.path().join("mihomo");
        fs::write(&binary, "#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).unwrap();
        let controller = Controller::new();
        let mut core = Core::new(
            root.path().join("data"),
            root.path().into(),
            true,
            Arc::new(|_, _| {}),
            Arc::new(Jobs::default()),
        )
        .unwrap();
        core.engine.pid = Some(std::process::id());
        core.engine.owned = core.engine.pid;
        core.engine.controller = controller.port;
        core.wants_running = true;
        core.engine
            .store
            .write(
                "settings.json",
                &json!({"selectedProxy":"DIRECT","tun":true}),
            )
            .unwrap();
        atomic_write(
            &core.engine.store.path("mihomo/config.yaml"),
            controller.configuration.lock().unwrap().as_bytes(),
        )
        .unwrap();
        (root, core, controller)
    }

    #[test]
    fn consecutive_health_failures_recover_even_with_the_same_live_path() {
        let (_root, mut core, _controller) = recovery_fixture();
        core.network_recovery.applied(Some("same".into()));
        core.record_tunnel_health(false);
        core.record_tunnel_health(false);
        assert_eq!(core.network_recovery.status()["state"], "ready");
        core.record_tunnel_health(true);
        assert_eq!(core.health_failures, 0);
        for _ in 0..3 {
            core.record_tunnel_health(false);
        }
        assert_eq!(core.network_recovery.status()["state"], "recovering");
        let t = Instant::now();
        assert!(!core.network_recovery.observe(Some("same"), true, t));
        assert!(
            core.network_recovery
                .observe(Some("same"), true, t + Duration::from_secs(3))
        );
    }

    #[test]
    fn targeted_retry_preserves_other_sockets_and_never_logs_the_identifier() {
        let (_root, core, controller) = recovery_fixture();
        let id = "fixture-private-identifier";
        core.retry_wechat_connection(id);
        assert_eq!(
            *controller.deletes.lock().unwrap(),
            [format!("/connections/{id}")]
        );
        let log = fs::read_to_string(core.engine.store.path("logs/app.log")).unwrap();
        assert!(!log.contains(id));
        assert!(log.contains("socket-closed-awaiting-app-retry"));
        assert_eq!(controller.writes.load(Ordering::SeqCst), 0);
        controller.fail_delete.store(true, Ordering::SeqCst);
        core.retry_wechat_connection(id);
        let log = fs::read_to_string(core.engine.store.path("logs/app.log")).unwrap();
        assert!(log.contains("close-failed"));
        assert!(!log.contains(id));
        assert_eq!(controller.deletes.lock().unwrap().len(), 1);
    }

    #[test]
    fn recovery_rebinds_the_interface_and_preserves_company_and_unknown_sockets() {
        let (_root, mut core, controller) = recovery_fixture();
        core.network_recovery.changed(None);
        core.recover_network(&json!({"interfaceName":"en16","signature":"fixture-path"}))
            .unwrap();
        let applied = config::parse(&controller.configuration.lock().unwrap()).unwrap();
        assert_eq!(applied["interface-name"], "en16");
        assert_eq!(applied["tun"]["enable"], false);
        assert_eq!(applied["dns"]["enable"], false);
        assert_eq!(core.runtime_status()["networkRecovery"]["state"], "ready");
        assert_eq!(
            *controller.deletes.lock().unwrap(),
            ["/connections/old-proxy", "/connections/old-direct"]
        );
    }

    #[test]
    fn failed_reload_rolls_back_without_discarding_existing_connections() {
        let (_root, mut core, controller) = recovery_fixture();
        let before = fs::read(core.engine.store.path("mihomo/config.yaml")).unwrap();
        core.network_recovery.changed(None);
        controller.fail_reload.store(true, Ordering::SeqCst);
        let error = core
            .recover_network(&json!({"interfaceName":"en16","signature":"fixture-path"}))
            .unwrap_err();
        core.network_recovery
            .failed(redact(&error.to_string()), Instant::now());
        assert_eq!(
            fs::read(core.engine.store.path("mihomo/config.yaml")).unwrap(),
            before
        );
        assert_eq!(
            config::parse(&controller.configuration.lock().unwrap()).unwrap()["interface-name"],
            "en0"
        );
        assert!(controller.deletes.lock().unwrap().is_empty());
        assert_eq!(core.runtime_status()["state"], "running");
        assert_eq!(core.runtime_status()["networkRecovery"]["state"], "failed");
    }

    #[test]
    fn socket_cleanup_failure_keeps_the_bounded_retry_count_after_config_reload() {
        let (_root, mut core, controller) = recovery_fixture();
        let context = json!({"interfaceName":"en16","signature":"fixture-path"});
        let mut time = Instant::now();
        core.network_recovery.changed(None);
        assert!(
            !core
                .network_recovery
                .observe(Some("fixture-path"), true, time)
        );
        time += Duration::from_secs(3);
        for attempt in 1..=3 {
            assert!(
                core.network_recovery
                    .observe(Some("fixture-path"), true, time)
            );
            controller.fail_delete.store(true, Ordering::SeqCst);
            let error = core.recover_network(&context).unwrap_err();
            core.network_recovery
                .failed(redact(&error.to_string()), time);
            assert_eq!(core.network_recovery.status()["attempts"], attempt);
            time += Duration::from_secs(3 * attempt);
        }
        assert!(!core.network_recovery.observe(
            Some("fixture-path"),
            true,
            time + Duration::from_secs(300)
        ));
        assert_eq!(core.runtime_status()["networkRecovery"]["state"], "failed");
        assert_eq!(
            config::parse(&controller.configuration.lock().unwrap()).unwrap()["interface-name"],
            "en16"
        );
    }

    #[test]
    fn outdated_helper_blocks_startup_without_writes_or_administrator_requests() {
        let (_root, mut core, controller) = recovery_fixture();
        core.engine.owned = None;
        let config = fs::read(core.engine.store.path("mihomo/config.yaml")).unwrap();
        let result = core
            .startup_connect_with_helper(Some(platform::HelperState::Outdated))
            .unwrap();
        assert_eq!(result["startupOutcome"], "helper-update-required");
        assert_eq!(result["mihomo"]["state"], "running");
        assert_eq!(
            result["mihomo"]["networkRecovery"]["helperUpdateRequired"],
            true
        );
        assert!(core.engine.owned.is_none());
        assert_eq!(
            fs::read(core.engine.store.path("mihomo/config.yaml")).unwrap(),
            config
        );
        assert_eq!(controller.writes.load(Ordering::SeqCst), 0);
        assert!(controller.deletes.lock().unwrap().is_empty());
    }

    #[test]
    fn manual_stop_cancels_pending_recovery_and_late_path_notifications() {
        let (_root, mut core, _controller) = recovery_fixture();
        core.engine.pid = None;
        core.engine.owned = None;
        core.network_recovery.changed(Some(false));
        core.handle("vpn:stop", &json!({})).unwrap();
        assert!(!core.wants_running);
        let result = core
            .handle("native:network-changed", &json!({"available":true}))
            .unwrap();
        assert_eq!(result["state"], "stopped");
        assert_eq!(result["networkRecovery"]["state"], "idle");
    }

    #[test]
    fn configuration_confirmation_rejects_a_stale_interface() {
        let (_root, mut core, _controller) = recovery_fixture();
        // Only this read-only controller check uses the non-isolated branch.
        core.engine.isolated = false;
        assert!(
            core.engine
                .confirm_network_binding(Some("en16"), false)
                .is_err()
        );
        assert!(
            core.engine
                .confirm_network_binding(Some("en0"), false)
                .is_ok()
        );
        assert!(
            core.engine
                .confirm_network_binding(Some("en0"), true)
                .is_err()
        );
        core.engine.isolated = true;
    }

    #[test]
    fn sleep_stops_maintenance_and_wake_preserves_only_existing_connection_intent() {
        let (_root, mut core, controller) = recovery_fixture();
        core.network_recovery.applied(Some("same".into()));
        core.handle(
            "native:runtime-environment",
            &json!({"sleeping":true,"lowPower":true,"networkEvents":true}),
        )
        .unwrap();
        assert_eq!(core.background_interval(), Duration::from_secs(60));
        let before = controller.writes.load(Ordering::SeqCst);
        core.tick();
        assert!(core.due_subscription_downloads().is_none());
        assert_eq!(controller.writes.load(Ordering::SeqCst), before);
        core.handle("native:runtime-environment", &json!({"sleeping":false}))
            .unwrap();
        assert_eq!(core.network_recovery.status()["state"], "recovering");
        assert_eq!(core.background_interval(), Duration::from_secs(1));
        core.engine.pid = None;
        core.engine.owned = None;
        core.handle("vpn:stop", &json!({})).unwrap();
        core.handle("native:runtime-environment", &json!({"sleeping":true}))
            .unwrap();
        core.handle("native:runtime-environment", &json!({"sleeping":false}))
            .unwrap();
        assert!(!core.wants_running);
        assert_eq!(core.network_recovery.status()["state"], "idle");
    }

    #[test]
    fn unchanged_company_state_does_not_repeatedly_wake_the_ui() {
        let (_root, mut core, _controller) = recovery_fixture();
        let events = Arc::new(AtomicU64::new(0));
        let count = events.clone();
        core.events = Arc::new(move |name, _| {
            if name == "company:routing-state" {
                count.fetch_add(1, Ordering::SeqCst);
            }
        });
        core.publish_company();
        let before = events.load(Ordering::SeqCst);
        for _ in 0..50 {
            core.publish_company();
        }
        assert_eq!(events.load(Ordering::SeqCst), before);
    }

    #[test]
    fn background_notifications_are_retained_and_shutdown_interrupts_a_long_wait() {
        let jobs = Arc::new(Jobs::default());
        jobs.wake_background(); // A change arriving before the wait is not lost.
        let start = Instant::now();
        jobs.wait_background(Duration::from_secs(60));
        assert!(start.elapsed() < Duration::from_secs(1));
        let worker_jobs = jobs.clone();
        let worker = std::thread::spawn(move || {
            worker_jobs.wait_background(Duration::from_secs(60));
            worker_jobs.shutdown.load(Ordering::SeqCst)
        });
        jobs.shutdown.store(true, Ordering::SeqCst);
        jobs.wake_background();
        assert!(worker.join().unwrap());
        assert!(start.elapsed() < Duration::from_secs(1));
    }
}

#[derive(Default)]
pub struct Jobs {
    background_pending: Mutex<bool>,
    background_wake: Condvar,
    /// Tokens of manual subscription downloads in flight. Removed by
    /// `ManualUpdate`'s `Drop`, so a panicking download cannot leave one behind.
    pub pending_downloads: Mutex<HashSet<String>>,
    pub speed: AtomicBool,
    pub risk: AtomicBool,
    pub udp: AtomicBool,
    pub shutdown: AtomicBool,
    pub risk_active: AtomicBool,
    pub speed_active: AtomicBool,
    pub udp_active: AtomicBool,
}
impl Jobs {
    pub fn wake_background(&self) {
        if let Ok(mut pending) = self.background_pending.lock() {
            *pending = true;
            self.background_wake.notify_one();
        }
    }
    pub fn wait_background(&self, delay: Duration) {
        if let Ok(pending) = self.background_pending.lock() {
            if let Ok((mut pending, _)) =
                self.background_wake
                    .wait_timeout_while(pending, delay, |pending| {
                        !*pending && !self.shutdown.load(Ordering::SeqCst)
                    })
            {
                *pending = false;
            }
        }
    }
    pub fn cancel(&self, kind: &str) {
        match kind {
            "risk" => &self.risk,
            "udp" => &self.udp,
            _ => &self.speed,
        }
        .store(true, Ordering::SeqCst);
    }
    pub fn cancel_all(&self) {
        for flag in [&self.speed, &self.risk, &self.udp] {
            flag.store(true, Ordering::SeqCst);
        }
    }
    pub fn cancelled(&self, kind: &str) -> bool {
        self.shutdown.load(Ordering::SeqCst)
            || match kind {
                "risk" => &self.risk,
                "udp" => &self.udp,
                _ => &self.speed,
            }
            .load(Ordering::SeqCst)
    }
}
pub struct Engine {
    pub store: Storage,
    pub binary: PathBuf,
    pub pid: Option<u32>,
    pub owned: Option<u32>,
    pub mixed: u16,
    pub controller: u16,
    /// Loopback inbound bound to the PROBE selector; 0 until configured.
    pub probe: u16,
    pub mode: String,
    pub isolated: bool,
    child: Option<Child>,
    client: Client,
    /// Controller secret the running engine is believed to accept.
    secret: Mutex<String>,
    pub last_error: Option<String>,
    pub started: Option<String>,
    reload_attempts: AtomicU64,
}
impl Engine {
    pub fn new(store: Storage, resources: PathBuf, isolated: bool) -> Result<Self> {
        let mut e = Self {
            store,
            binary: resources.join(if cfg!(windows) {
                "mihomo.exe"
            } else {
                "mihomo"
            }),
            pid: None,
            owned: None,
            mixed: 7890,
            controller: 9090,
            probe: 0,
            mode: "vpn".into(),
            isolated,
            child: None,
            client: Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(6))
                .build()?,
            secret: Mutex::new(String::new()),
            last_error: None,
            started: None,
            reload_attempts: AtomicU64::new(0),
        };
        if isolated {
            if let Ok(port) = std::env::var("SPLITVPN_TEST_CONTROLLER_PORT") {
                e.controller = port.parse()?;
                ensure!(
                    e.controller != 9090 && e.controller != 9091,
                    "隔离控制器不能使用正式端口。"
                );
                e.mixed = std::env::var("SPLITVPN_TEST_MIXED_PORT")
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0);
                e.probe = std::env::var("SPLITVPN_TEST_PROBE_PORT")
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(e.mixed);
                e.pid = Some(std::process::id());
            }
        } else {
            let _ = e.attach();
        }
        Ok(e)
    }
    /// Send with the believed secret. A 401 means the request was not applied,
    /// so retry with the other known values while an engine started before or
    /// after the secret migration is still running.
    fn authorized(
        &self,
        method: &str,
        path: &str,
        payload: Option<&Value>,
    ) -> Result<reqwest::blocking::Response> {
        let url = format!("http://127.0.0.1:{}{path}", self.controller);
        let send = |secret: &str| -> Result<reqwest::blocking::Response> {
            let mut request = self.client.request(method.parse()?, &url);
            if !secret.is_empty() {
                request = request.bearer_auth(secret);
            }
            if let Some(p) = payload {
                request = request.json(p);
            }
            Ok(request.send()?)
        };
        let current = self.secret.lock().map(|s| s.clone()).unwrap_or_default();
        let response = send(&current)?;
        if response.status() != 401 {
            return Ok(response);
        }
        let mut candidates = Vec::new();
        if let Ok(text) = fs::read_to_string(self.store.path("mihomo/config.yaml")) {
            if let Ok(c) = config::parse(&text) {
                candidates.push(c["secret"].as_str().unwrap_or("").to_owned());
            }
        }
        if !self.isolated {
            if let Ok(secret) = self.store.controller_secret() {
                candidates.push(secret);
            }
        }
        candidates.push(String::new());
        let mut tried = vec![current];
        let mut last = response;
        for candidate in candidates {
            if tried.contains(&candidate) {
                continue;
            }
            let response = send(&candidate)?;
            if response.status() != 401 {
                if let Ok(mut secret) = self.secret.lock() {
                    *secret = candidate;
                }
                return Ok(response);
            }
            tried.push(candidate);
            last = response;
        }
        Ok(last)
    }
    pub fn api(&self, method: &str, path: &str, payload: Option<&Value>) -> Result<Value> {
        let response = self.authorized(method, path, payload)?;
        let status = response.status();
        if !status.is_success() {
            // mihomo explains rejections in {"message": "..."}; keep it for diagnosis.
            let body = response.text().unwrap_or_default();
            let reason = serde_json::from_str::<Value>(&body)
                .ok()
                .and_then(|v| v["message"].as_str().map(str::to_owned))
                .unwrap_or(body);
            let reason: String = reason.trim().chars().take(300).collect();
            if reason.is_empty() {
                bail!("内核操作失败（HTTP {}）。", status.as_u16());
            }
            bail!("内核操作失败（HTTP {}）：{reason}", status.as_u16());
        }
        if response.status() == 204 {
            return Ok(Value::Null);
        }
        Ok(response.json()?)
    }
    pub fn has_proxy(&self, name: &str) -> Result<bool> {
        let r = self.authorized("GET", &format!("/proxies/{}", encode(name)), None)?;
        if r.status() == 404 {
            return Ok(false);
        }
        ensure!(
            r.status().is_success(),
            "内核状态核对失败（HTTP {}）。",
            r.status().as_u16()
        );
        Ok(true)
    }
    pub fn reload(&self, yaml: &str) -> Result<()> {
        // Isolation applies to every controller reload, including company routing.
        let isolated_yaml;
        let yaml = if self.isolated {
            let mut c = config::parse(yaml)?;
            isolate_config(&mut c)?;
            isolated_yaml = config::yaml(&c)?;
            isolated_yaml.as_str()
        } else {
            yaml
        };
        self.reload_attempts.fetch_add(1, Ordering::SeqCst);
        self.api(
            "PUT",
            "/configs?force=false",
            Some(&json!({"payload":yaml})),
        )?;
        if let Ok(c) = config::parse(yaml) {
            if let Ok(mut secret) = self.secret.lock() {
                *secret = c["secret"].as_str().unwrap_or("").to_owned();
            }
        }
        Ok(())
    }
    pub fn select(&self, name: &str) -> Result<()> {
        self.api("PUT", "/proxies/VPN", Some(&json!({"name":name})))?;
        Ok(())
    }
    fn confirm_network_binding(&self, interface: Option<&str>, tun: bool) -> Result<()> {
        if self.isolated {
            return Ok(());
        }
        let config = self.api("GET", "/configs", None)?;
        ensure!(
            interface.is_none_or(|name| config["interface-name"] == name)
                && config["tun"]["enable"] == tun
                && (!tun
                    || platform::tun_device_ready(config["tun"]["device"].as_str().unwrap_or(""))),
            "内核尚未确认新网卡和系统分流配置。"
        );
        Ok(())
    }

    pub(crate) fn confirm_routing_config(&self, expected: &Value) -> Result<()> {
        let current = self.api("GET", "/configs", None)?;
        let interface = expected["interface-name"].as_str();
        let tun = expected["tun"]["enable"] == true && !self.isolated;
        ensure!(
            interface.is_none_or(|name| current["interface-name"] == name)
                && current["tun"]["enable"] == tun,
            "内核尚未确认私有网络接管后的网卡和 TUN 状态。"
        );
        Ok(())
    }
    /// Discard sockets bound to the departed path. Company sockets have their
    /// own tunnel recovery and are never closed by this personal VPN action.
    fn close_departed_path_connections(&self) -> Result<()> {
        let connections = self.api("GET", "/connections", None)?;
        for connection in connections["connections"].as_array().into_iter().flatten() {
            let chains = connection["chains"].as_array();
            if chains.is_some_and(|items| {
                items.iter().any(|name| {
                    name.as_str()
                        .is_some_and(|name| name.starts_with("COMPANY-"))
                })
            }) {
                continue;
            }
            if !chains
                .is_some_and(|items| items.iter().any(|name| name == "VPN" || name == "DIRECT"))
            {
                continue;
            }
            if let Some(id) = connection["id"].as_str().filter(|id| !id.is_empty()) {
                let response =
                    self.authorized("DELETE", &format!("/connections/{}", encode(id)), None)?;
                ensure!(
                    response.status().is_success() || response.status() == 404,
                    "旧网络连接清理未确认（HTTP {}）。",
                    response.status().as_u16()
                );
            }
        }
        Ok(())
    }
    /// Points the check-only PROBE selector at `name` and returns its inbound
    /// port. The user's VPN outlet is never touched.
    fn select_probe(&self, name: &str) -> Result<u16> {
        ensure!(
            self.probe != 0 && self.has_proxy(config::PROBE)?,
            "检测入口尚未就绪，请断开后重新连接 VPN。"
        );
        self.api(
            "PUT",
            &format!("/proxies/{}", config::PROBE),
            Some(&json!({"name":name})),
        )?;
        Ok(self.probe)
    }
    /// mihomo answers the controller before file providers finish loading;
    /// slow TUN setup on Windows widens that gap, so wait for the member.
    fn wait_for_vpn_member(&self, name: &str, timeout: Duration) {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            let ready = self.api("GET", "/proxies/VPN", None).is_ok_and(|g| {
                g["all"]
                    .as_array()
                    .is_some_and(|all| all.iter().any(|n| n == name))
            });
            if ready {
                return;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    }
    pub fn refresh_dns(&self) -> Result<()> {
        if self.isolated || !cfg!(target_os = "macos") {
            return Ok(());
        }
        let pid = self.pid.context("请先恢复 VPN 连接，再刷新系统 DNS。")?;
        let response = platform::helper(&self.store, "refresh-dns", &self.binary, false)?;
        ensure!(
            response["identityVerified"] == true
                && response["dnsRefreshOk"] == true
                && response["pid"].as_u64() == Some(pid as u64)
                && response["targetPid"].as_u64() == Some(pid as u64),
            "系统 DNS 刷新未确认，现有连接已保留。"
        );
        Ok(())
    }
    pub fn selections(&self) -> Result<Value> {
        let proxies = self.api("GET", "/proxies", None)?;
        let mut result = json!({});
        if let Some(ps) = proxies["proxies"].as_object() {
            for (name, p) in ps {
                if p["type"] == "Selector" && p["now"].is_string() {
                    result[name] = p["now"].clone();
                }
            }
        }
        Ok(result)
    }
    pub fn restore_selections(&self, picks: &Value) {
        if let Some(picks) = picks.as_object() {
            for (name, pick) in picks {
                let _ = self.api(
                    "PUT",
                    &format!("/proxies/{}", encode(name)),
                    Some(&json!({"name":pick})),
                );
            }
        }
    }
    fn restore_selections_checked(&self, picks: &Value) -> Result<()> {
        if let Some(picks) = picks.as_object() {
            for (name, pick) in picks {
                self.api(
                    "PUT",
                    &format!("/proxies/{}", encode(name)),
                    Some(&json!({"name":pick})),
                )?;
            }
        }
        ensure!(
            self.selections()? == *picks,
            "服务已更新，但原节点尚未恢复，请重新选择节点。"
        );
        Ok(())
    }
    pub fn attach(&mut self) -> Result<()> {
        if self.isolated {
            if let Some(child) = &mut self.child {
                if child.try_wait()?.is_some() {
                    self.pid = None;
                    self.owned = None;
                    self.started = None;
                }
            }
            return Ok(());
        }
        // Off macOS the engine is our own child and no helper writes mihomo.pid.
        if let Some(child) = &mut self.child {
            if child.try_wait()?.is_none() {
                return Ok(());
            }
            self.child = None;
            self.started = None;
        }
        let pid = fs::read_to_string(self.store.path("mihomo/mihomo.pid"))
            .ok()
            .and_then(|s| s.trim().parse::<u32>().ok())
            .filter(|p| platform::pid_alive(*p));
        if let Ok(text) = fs::read_to_string(self.store.path("mihomo/config.yaml")) {
            let c = config::parse(&text)?;
            if let Some(p) = c["mixed-port"].as_u64() {
                self.mixed = p as u16;
            }
            if let Some(p) = c["external-controller"]
                .as_str()
                .and_then(|s| s.rsplit(':').next())
                .and_then(|s| s.parse().ok())
            {
                self.controller = p;
            }
            self.probe = config::probe_port(&c).unwrap_or(0);
            if let Ok(mut secret) = self.secret.lock() {
                *secret = c["secret"].as_str().unwrap_or("").to_owned();
            }
        }
        if self.pid != pid || (pid.is_some() && self.started.is_none()) {
            self.started = pid.and_then(platform::process_started_at);
        }
        self.pid = pid;
        if self.owned != pid {
            self.owned = None;
        }
        if pid.is_some() {
            self.api("GET", "/version", None)?;
        }
        Ok(())
    }
    pub fn status(&self) -> Value {
        json!({"state":if self.last_error.is_some(){"error"}else if self.pid.is_some(){"running"}else{"stopped"},"mode":if self.pid.is_some(){json!(self.mode)}else{Value::Null},"pid":self.pid,"startedAt":self.started,"lastError":self.last_error})
    }
    pub fn protected(&self) -> bool {
        !self.isolated && self.pid.is_some() && self.owned != self.pid && platform::legacy_owner()
    }
    pub fn prepare_ports(&mut self) -> Result<()> {
        if self.pid.is_none() {
            self.mixed = available_port(if self.isolated { 0 } else { 7890 })?;
            self.controller = available_port(if self.isolated { 0 } else { 9090 })?;
            if self.mixed == self.controller {
                self.controller = available_port(0)?;
            }
            self.probe = available_port(0)?;
            while self.probe == self.mixed || self.probe == self.controller {
                self.probe = available_port(0)?;
            }
        }
        Ok(())
    }
    pub fn prepare_geodata(&self) -> Result<()> {
        let Some(resources) = self.binary.parent() else {
            return Ok(());
        };
        let source = resources.join("geodata");
        if !source.is_dir() {
            return Ok(());
        }
        for name in ["GeoSite.dat", "country.mmdb", "geoip.metadb"] {
            let path = source.join(name);
            let target = self.store.path(&format!("mihomo/{name}"));
            if path.is_file() && fs::metadata(&target).map_or(true, |m| m.len() == 0) {
                atomic_write(&target, &fs::read(path)?)?;
            }
        }
        Ok(())
    }
    pub fn start(&mut self) -> Result<()> {
        self.start_authorized(true)
    }
    fn start_authorized(&mut self, allow_install: bool) -> Result<()> {
        if self.pid.is_some() {
            return Ok(());
        }
        ensure!(self.binary.is_file(), "应用缺少 Mihomo 内核。");
        self.prepare_geodata()?;
        let mut c = config::parse(&fs::read_to_string(self.store.path("mihomo/config.yaml"))?)?;
        if self.isolated {
            isolate_config(&mut c)?;
        }
        let text = config::yaml(&c)?;
        platform::validate(&self.binary, &self.store, &text)?;
        atomic_write(&self.store.path("mihomo/config.yaml"), text.as_bytes())?;
        if self.isolated || !cfg!(target_os = "macos") {
            fs::create_dir_all(self.store.path("logs"))?;
            let log = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(self.store.path("logs/mihomo.log"))?;
            // A core killed without shutdown leaves its engine holding :53 and the TUN.
            let stale = self.store.path("mihomo/child.pid");
            if cfg!(windows) && !self.isolated {
                if let Some(pid) = fs::read_to_string(&stale)
                    .ok()
                    .and_then(|s| s.trim().parse::<u32>().ok())
                {
                    let _ = platform::command(
                        "taskkill",
                        &[
                            "/F",
                            "/FI",
                            "IMAGENAME eq mihomo.exe",
                            "/PID",
                            &pid.to_string(),
                        ],
                        Duration::from_secs(5),
                    );
                }
            }
            let child = Command::new(&self.binary)
                .args([
                    "-d",
                    self.store.path("mihomo").to_str().unwrap(),
                    "-f",
                    self.store.path("mihomo/config.yaml").to_str().unwrap(),
                ])
                .stdin(Stdio::null())
                .stdout(log.try_clone()?)
                .stderr(log)
                .spawn()?;
            if cfg!(windows) && !self.isolated {
                let _ = fs::write(&stale, child.id().to_string());
            }
            self.pid = Some(child.id());
            self.owned = self.pid;
            self.child = Some(child);
        } else {
            let p = platform::helper(&self.store, "start", &self.binary, allow_install)?;
            ensure!(p["identityVerified"] == true, "内核启动身份尚未确认。");
            self.pid = Some(
                p["pid"]
                    .as_u64()
                    .filter(|p| *p > 0 && *p <= u32::MAX as u64)
                    .context("内核启动没有返回有效进程标识。")? as u32,
            );
            self.owned = self.pid;
        }
        self.started = Some(now());
        let until = Instant::now() + Duration::from_secs(15);
        while Instant::now() < until {
            if self.api("GET", "/version", None).is_ok() {
                self.last_error = None;
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(150));
        }
        let err = "内核启动后控制器未就绪，已尝试安全断开。";
        let _ = self.stop();
        self.last_error = Some(err.into());
        bail!(err)
    }
    pub fn stop(&mut self) -> Result<()> {
        ensure!(!self.protected(), "当前连接由原版维护，请先在原版断开。");
        if self.pid.is_none() {
            return Ok(());
        }
        if let Some(child) = &mut self.child {
            child.kill()?;
            child.wait()?;
            self.child = None;
        } else if cfg!(target_os = "macos") && !self.isolated {
            let status = platform::helper(&self.store, "status", &self.binary, false)?;
            ensure!(
                status["pid"].as_u64().map(|p| p as u32) == self.pid,
                "运行进程身份发生变化，未停止其他内核。"
            );
            let r = platform::helper(&self.store, "stop", &self.binary, false)?;
            ensure!(
                r["processExitConfirmed"] == true && r["dnsRestoreOk"] == true,
                "内核退出或 DNS 恢复尚未确认，恢复记录已保留。"
            );
        } else {
            bail!("无法确认此进程由本应用启动，未停止其他内核。");
        }
        self.pid = None;
        self.owned = None;
        self.started = None;
        self.last_error = None;
        let _ = fs::remove_file(self.store.path("mihomo/mihomo.pid"));
        Ok(())
    }
}
fn available_port(preferred: u16) -> Result<u16> {
    let socket = TcpListener::bind(("127.0.0.1", preferred))
        .or_else(|_| TcpListener::bind("127.0.0.1:0"))?;
    Ok(socket.local_addr()?.port())
}
fn isolate_config(c: &mut Value) -> Result<()> {
    ensure!(
        (c["tun"].is_null() || c["tun"].is_object())
            && (c["dns"].is_null() || c["dns"].is_object()),
        "TUN 或 DNS 配置格式无效。"
    );
    c["tun"]["enable"] = json!(false);
    c["dns"]["enable"] = json!(false);
    c["geo-auto-update"] = json!(false);
    if let Some(providers) = c["proxy-providers"].as_object_mut() {
        for provider in providers.values_mut() {
            ensure!(
                provider.is_object()
                    && (provider["health-check"].is_null() || provider["health-check"].is_object()),
                "节点 provider 配置格式无效。"
            );
            provider["health-check"]["enable"] = json!(false);
        }
    }
    c["allow-lan"] = json!(false);
    c["secret"] = json!("");
    Ok(())
}

pub struct Core {
    pub engine: Engine,
    pub company: Company,
    pub events: Events,
    pub jobs: Arc<Jobs>,
    started: String,
    risk_key: String,
    samples: Vec<Value>,
    last_totals: Option<(u64, u64, Instant)>,
    last_tick: Instant,
    network_recovery: NetworkRecovery,
    last_network_tick: Option<Instant>,
    last_health_tick: Option<Instant>,
    health_pid: Option<u32>,
    health_failures: u32,
    connection_health: ConnectionHealth,
    wechat_route: Option<&'static str>,
    environment: RuntimeEnvironment,
    revision: u64,
    wants_running: bool,
    auto_starting: bool,
    startup_connect_attempted: bool,
    last_core_state: String,
    last_company_state: String,
    last_monitor_error: Option<String>,
    recovery_token: Option<(String, String, u64, Instant)>,
    recovery_authorized: Option<(String, u64, Instant)>,
}
impl Core {
    pub fn new(
        data: PathBuf,
        resources: PathBuf,
        isolated: bool,
        events: Events,
        jobs: Arc<Jobs>,
    ) -> Result<Self> {
        let mut engine = Engine::new(Storage::new(data), resources, isolated)?;
        let mut company = Company::default();
        if !isolated {
            if let Err(e) = company.recover(&mut engine) {
                engine.last_error = Some(redact(&e.to_string()));
            }
        }
        let mut c = Self {
            engine,
            company,
            events,
            jobs,
            started: now(),
            risk_key: String::new(),
            samples: Vec::new(),
            last_totals: None,
            last_tick: Instant::now(),
            network_recovery: NetworkRecovery::default(),
            last_network_tick: None,
            last_health_tick: None,
            health_pid: None,
            health_failures: 0,
            connection_health: ConnectionHealth::default(),
            wechat_route: None,
            environment: RuntimeEnvironment::default(),
            revision: 0,
            wants_running: false,
            auto_starting: false,
            startup_connect_attempted: false,
            last_core_state: String::new(),
            last_company_state: String::new(),
            last_monitor_error: None,
            recovery_token: None,
            recovery_authorized: None,
        };
        c.recover_transaction()?;
        Ok(c)
    }
    pub fn shutdown(&mut self) {
        if let Err(error) = self.company.remove(&mut self.engine) {
            self.log("warn", &format!("私有网络分流退出恢复未完成：{error}"));
        }
        // Without a privileged helper the engine is our child: stop it with the UI.
        if (self.engine.isolated || !cfg!(target_os = "macos")) && self.engine.owned.is_some() {
            let _ = self.engine.stop();
        }
    }
    pub fn log(&self, level: &str, message: &str) {
        let text = format!("{} [{level}] {}\n", now(), redact(message));
        let p = self.engine.store.path("logs/app.log");
        // Same scheme as the legacy logs: 4 MB per file, three rotations.
        if fs::metadata(&p).is_ok_and(|m| m.len() >= 4 * 1024 * 1024) {
            for i in (1..3).rev() {
                let _ = fs::rename(
                    p.with_extension(format!("log.{i}")),
                    p.with_extension(format!("log.{}", i + 1)),
                );
            }
            let _ = fs::rename(&p, p.with_extension("log.1"));
        }
        if fs::create_dir_all(p.parent().unwrap()).is_ok() {
            if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(p) {
                let _ = file.write_all(text.as_bytes());
            }
        }
    }
    fn runtime_status(&self) -> Value {
        let mut status = self.engine.status();
        status["networkRecovery"] = self.network_recovery.status();
        status
    }
    fn publish_runtime_status(&mut self) {
        let state = self.runtime_status();
        let serialized = state.to_string();
        if serialized != self.last_core_state {
            (self.events)("vpn:status", state);
            self.last_core_state = serialized;
        }
    }
    /// Detect an upgrade before automatic connection or any background reload.
    /// Only an explicit user action may install the privileged service.
    fn check_helper_update(&mut self) -> bool {
        if self.engine.isolated || !cfg!(target_os = "macos") || self.engine.protected() {
            return false;
        }
        let required = matches!(
            platform::helper_state(&self.engine.store),
            platform::HelperState::Outdated
                | platform::HelperState::Missing
                | platform::HelperState::Incompatible
        );
        if required {
            self.network_recovery.require_helper_update(
                "连接服务需要更新。请点击「更新连接服务」，按 macOS 提示完成授权后再连接。",
            );
        } else if self.network_recovery.helper_update_required() {
            self.network_recovery.clear();
            self.network_recovery.changed(None);
        }
        required
    }
    fn publish_company(&mut self) {
        let state = self.company.state();
        let serialized = state.to_string();
        if serialized != self.last_company_state {
            self.log("info", &format!(
                "私有网络分流状态：active={} recovering={} ruleCount={} recoveryCount={} error={}",
                state["active"], state["recovering"], state["ruleCount"], state["recoveryCount"],
                state["lastError"].is_string()
            ));
            (self.events)("company:routing-state", state);
            self.last_company_state = serialized;
        }
    }
    fn recover_transaction(&mut self) -> Result<()> {
        let j = self
            .engine
            .store
            .read("runtime-state/rust-pending.json", Value::Null)?;
        if j.is_null() {
            return Ok(());
        }
        ensure!(
            !j["ownerPid"]
                .as_u64()
                .is_some_and(|p| p as u32 != std::process::id() && platform::pid_alive(p as u32)),
            "另一个 Rust 后台仍在应用配置，请先关闭旧窗口。"
        );
        self.restore_transaction(&j)?;
        if self.engine.pid.is_some() {
            let base = fs::read_to_string(self.engine.store.path("mihomo/config.yaml"))?;
            self.company.reload_base(&mut self.engine, &base)?;
        }
        self.finish_transaction();
        self.log("info", "已恢复中断前的配置与订阅指针。");
        Ok(())
    }
    fn begin_transaction(&self) -> Result<Value> {
        let mut files = json!({});
        for p in [
            "settings.json",
            "subscription.json",
            "mihomo/config.yaml",
            "mihomo/providers/subscription-manifest.json",
            "mihomo/providers/vpn-domains.yaml",
        ] {
            files[p] = match fs::read_to_string(self.engine.store.path(p)) {
                Ok(v) => json!(v),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Value::Null,
                Err(e) => return Err(e.into()),
            };
        }
        let selections = if self.engine.pid.is_some() {
            self.engine.selections().unwrap_or_else(|_| json!({}))
        } else {
            json!({})
        };
        let j = json!({"schemaVersion":1,"ownerPid":std::process::id(),"createdAt":now(),"files":files,"selections":selections});
        self.engine
            .store
            .write("runtime-state/rust-pending.json", &j)?;
        Ok(j)
    }
    fn restore_transaction(&self, j: &Value) -> Result<()> {
        let files = j["files"].as_object().context("配置恢复记录无效。")?;
        for (p, bytes) in files {
            ensure!(
                [
                    "settings.json",
                    "subscription.json",
                    "mihomo/config.yaml",
                    "mihomo/providers/subscription-manifest.json",
                    "mihomo/providers/vpn-domains.yaml"
                ]
                .contains(&p.as_str()),
                "配置恢复路径无效。"
            );
            if let Some(s) = bytes.as_str() {
                atomic_write(&self.engine.store.path(p), s.as_bytes())?;
            } else {
                match fs::remove_file(self.engine.store.path(p)) {
                    Ok(()) => (),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
                    Err(e) => return Err(e.into()),
                }
            }
        }
        Ok(())
    }
    fn finish_transaction(&self) {
        let _ = fs::remove_file(self.engine.store.path("runtime-state/rust-pending.json"));
    }
    fn transaction<T>(&mut self, op: impl FnOnce(&mut Self) -> Result<T>) -> Result<T> {
        let j = self.begin_transaction()?;
        let network_before = self.network_recovery.clone();
        let reload_before = self.engine.reload_attempts.load(Ordering::SeqCst);
        let result = op(self);
        if result.is_err() {
            self.network_recovery = network_before;
            self.restore_transaction(&j)?;
            if self.engine.pid.is_some()
                && self.engine.reload_attempts.load(Ordering::SeqCst) != reload_before
            {
                if let Some(base) = j["files"]["mihomo/config.yaml"].as_str() {
                    if self.company.reload_base(&mut self.engine, base).is_err() {
                        self.engine
                            .store
                            .set_recovery(true, Some("configuration-rollback-failed"))?;
                        self.log("error", "配置回滚未完成，需要确认恢复。恢复记录已保留。");
                        return result;
                    }
                    self.engine.restore_selections(&j["selections"]);
                }
            }
        }
        self.finish_transaction();
        result
    }
    fn selected_udp(&self, settings: &Value) -> Result<bool> {
        Ok(settings["selectedProxy"] == "DIRECT"
            || self.nodes()?.iter().any(|n| {
                n["name"] == settings["selectedProxy"]
                    && n["runtimeUdpSupported"] == true
                    && !n["identityAmbiguous"].as_bool().unwrap_or(false)
            }))
    }
    fn apply_config(&mut self, settings: &Value) -> Result<()> {
        if self.engine.pid.is_none() {
            return Ok(());
        }
        let context = if self.engine.isolated {
            Value::Null
        } else {
            platform::context()?
        };
        self.apply_config_in_context(settings, &context)
    }
    fn apply_config_in_context(&mut self, settings: &Value, context: &Value) -> Result<()> {
        let interface = context["interfaceName"].as_str().map(str::to_owned);
        // The geo check in config::build reads the staged geodata.
        self.engine.prepare_geodata()?;
        let mut c = config::build(
            &self.engine.store,
            settings,
            self.engine.mixed,
            self.engine.controller,
            interface.as_deref(),
            self.selected_udp(settings)?,
        )?;
        // An engine started by an earlier build gains the probe inbound here.
        if self.engine.probe == 0 {
            self.engine.probe = available_port(0)?;
        }
        config::add_probe(&mut c, self.engine.probe);
        // Company compilation uses the retained base TUN setting; isolation
        // tests for company routing call its compiler without starting a TUN.
        let text = config::yaml(&c)?;
        atomic_write(
            &self.engine.store.path("mihomo/providers/vpn-domains.yaml"),
            config::yaml(&json!({"payload":settings["vpnDomainRules"]}))?.as_bytes(),
        )?;
        platform::validate(&self.engine.binary, &self.engine.store, &text)?;
        self.company.reload_base(&mut self.engine, &text)?;
        self.engine
            .confirm_network_binding(interface.as_deref(), settings["tun"] == true)?;
        atomic_write(
            &self.engine.store.path("mihomo/config.yaml"),
            text.as_bytes(),
        )?;
        if settings["tun"] == true {
            self.engine.refresh_dns()?;
        }
        self.network_recovery
            .applied(context["signature"].as_str().map(str::to_owned));
        self.publish_company();
        Ok(())
    }
    fn settings_patch(&mut self, patch: &Value, apply: bool) -> Result<Value> {
        crate::routing::validate_patch(patch)?;
        self.transaction(|c| {
            let mut s = c.engine.store.settings()?;
            let p = patch.as_object().context("设置参数需要是对象。")?;
            for (k, v) in p {
                if k == "specialCompatibilityRules" {
                    let obj = v.as_object().context("兼容设置格式无效。")?;
                    for (k, v) in obj {
                        ensure!(v.is_boolean(), "兼容设置需要布尔值。");
                        s["specialCompatibilityRules"][k] = v.clone();
                    }
                } else {
                    s[k] = v.clone();
                }
            }
            s = normalize_settings(s)?;
            if apply {
                c.ensure_user_helper()?;
                c.apply_config(&s)?;
            }
            c.engine.store.write("settings.json", &s)?;
            Ok(s)
        })
    }
    pub fn nodes(&self) -> Result<Vec<Value>> {
        let s = self.engine.store.settings()?;
        let mut nodes = subscription::provider_nodes(&self.engine.store)?;
        let live = if self.engine.pid.is_some() {
            self.engine.api("GET", "/proxies", None).ok()
        } else {
            None
        };
        let cache = self
            .engine
            .store
            .read("runtime-state/speed-cache.json", json!({"entries":[]}))?;
        for n in &mut nodes {
            n["selected"] = json!(n["name"] == s["selectedProxy"]);
            if let Some(live) = &live {
                if let Some(p) = live["proxies"].get(n["name"].as_str().unwrap()) {
                    n["type"] = p["type"].clone();
                    if let Some(last) = p["history"].as_array().and_then(|a| a.last()) {
                        n["delay"] = last["delay"].clone();
                        n["available"] = json!(last["delay"].as_u64().unwrap_or(0) > 0);
                    }
                    n["runtimeUdpSupported"] = if p["udp"].is_boolean() {
                        p["udp"].clone()
                    } else {
                        Value::Null
                    };
                }
            }
            if n["delay"].is_null() {
                if let Some(saved) = cache["entries"].as_array().and_then(|a| {
                    a.iter().find(|e| {
                        e["identityKey"] == n["identityKey"]
                            && e["providerRevision"] == n["providerRevision"]
                    })
                }) {
                    let fresh = saved["testedAt"]
                        .as_str()
                        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                        .is_some_and(|t| {
                            (chrono::Utc::now() - t.with_timezone(&chrono::Utc)).num_minutes()
                                < if saved["targetSetId"] == "default-latency" {
                                    10
                                } else {
                                    30
                                }
                        });
                    if fresh {
                        n["delay"] = saved
                            .get("medianDelayMs")
                            .unwrap_or(&saved["medianMs"])
                            .clone();
                        n["available"] =
                            json!(saved["status"] == "available" || saved["status"] == "success");
                    }
                }
            }
        }
        nodes.push(json!({"name":"DIRECT","type":"Direct","selected":s["selectedProxy"]=="DIRECT","delay":null,"available":true,"identityKey":null}));
        Ok(nodes)
    }
    fn groups(&self) -> Result<Value> {
        let settings = self.engine.store.settings()?;
        let nodes = self.nodes()?;
        let mut groups = Vec::new();
        for g in settings["nodeGroups"].as_array().unwrap() {
            let subscription_id = g["id"]
                .as_str()
                .and_then(|id| id.strip_prefix("subscription:"));
            let refs = if subscription_id.is_none() && g["members"].is_array() {
                g["members"].as_array().unwrap().clone()
            } else {
                g["nodeNames"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|name| json!({"lastKnownName":name}))
                    .collect()
            };
            let members = refs.iter().map(|r| {
                let node = nodes.iter().find(|n| match r["identityKey"].as_str() {
                    Some(key) => n["identityKey"] == key,
                    None => n["name"] == r["lastKnownName"] && subscription_id.is_none_or(|id| n["subscriptionId"] == id),
                });
                let issue = if node.is_none() { Some("节点已移除或订阅停用") } else if node.is_some_and(|n| n["identityAmbiguous"] == true) { Some("同名节点或内核名称冲突") } else { None };
                json!({"identityKey":r["identityKey"].as_str().or_else(|| node.and_then(|n| n["identityKey"].as_str())),"lastKnownName":r["lastKnownName"],"issue":issue,"available":node.map(|n|n["available"].clone()),"delay":node.map(|n|n["delay"].clone()),"current":node.is_some_and(|n| n["selected"]==true)})
            }).collect::<Vec<_>>();
            let good = members.iter().filter(|m| m["available"] == true).count();
            let bad = members.iter().filter(|m| m["available"] == false).count();
            groups.push(json!({"group":g,"runtimeName":group_runtime_name(g["id"].as_str().unwrap()),"selected":false,"applied":false,"currentMember":members.iter().find(|m|m["current"]==true).map(|m|m["lastKnownName"].clone()),"members":members,"availableCount":good,"failedCount":bad,"untestedCount":members.len()-good-bad}));
        }
        Ok(json!(groups))
    }
    fn status(&self) -> Result<Value> {
        Ok(
            json!({"appStartedAt":self.started,"mihomo":self.runtime_status(),"subscription":self.engine.store.subscription()?,"settings":self.engine.store.settings()?,"routingInfo":serde_json::from_str::<Value>(include_str!("../assets/routing-info.json"))?,"recovery":self.engine.store.recovery()?}),
        )
    }
    fn risks(&self) -> Result<Value> {
        Ok(self
            .engine
            .store
            .read("ipdata-risk-cache.json", json!({"version":1,"entries":[]}))?["entries"]
            .clone())
    }
    fn bootstrap(&mut self) -> Result<Value> {
        let _ = self.engine.attach();
        self.check_helper_update();
        Ok(
            json!({"status":self.status()?,"nodes":self.nodes()?,"groups":self.groups()?,"risks":self.risks()?,"traffic":self.traffic(),"legacyOwnerRunning":!self.engine.isolated&&platform::legacy_owner(),"previewOnly":false,"ownsRuntime":self.engine.pid.is_some()&&self.engine.pid==self.engine.owned,"companyRouting":self.company.state(),"dataDir":self.engine.store.root,"core":{"implementation":"rust","protocolVersion":1,"version":env!("CARGO_PKG_VERSION")}}),
        )
    }
    pub fn handle(&mut self, channel: &str, p: &Value) -> Result<Value> {
        if matches!(
            channel,
            "native:group-connect" | "native:group-disconnect" | "node-groups:select"
        ) {
            bail!("分组连接已取消，请选择具体节点。");
        }
        if channel == "nodes:select" && p["nodeName"] != "DIRECT" {
            bail!("请在节点页面选择具体节点。");
        }
        if !self.engine.isolated
            && !matches!(
                channel,
                "native:network-changed" | "native:runtime-environment"
            )
        {
            let _ = self.engine.attach();
        }
        if !matches!(
            channel,
            "core:capabilities"
                | "native:bootstrap"
                | "native:startup-connect"
                | "native:network-changed"
                | "native:runtime-environment"
                | "vpn:get-status"
                | "nodes:list"
                | "node-groups:list"
                | "subscription:get-status"
                | "traffic:get-monitor"
                | "traffic:get-snapshot"
                | "nodes:get-risk-cache"
                | "ipdata:get-status"
                | "logs:get"
                | "logs:export-redacted"
                | "routing:get-state"
                | "routing:diagnose"
                | "routing:normalize-rule"
                | "native:company-context"
                | "native:risk-key"
                | "connectivity:check"
                | "connectivity:test-website-speeds"
                | "runtime:get-recovery-state"
        ) {
            self.assert_company_owner()?;
        }
        let disruptive = matches!(
            channel,
            "vpn:stop" | "network:repair" | "subscription-probe:start" | "subscription:clear-all"
        );
        if disruptive {
            ensure!(
                !self.engine.protected(),
                "原版当前维护 VPN 连接，请先在原版结束连接。"
            );
        }
        match channel {
            "core:capabilities" => Ok(
                json!({"implementation":"rust","protocolVersion":1,"version":env!("CARGO_PKG_VERSION"),"nodeRuntimeRequired":false,"platform":std::env::consts::OS,"arch":std::env::consts::ARCH}),
            ),
            "native:bootstrap" => self.bootstrap(),
            "native:startup-connect" => self.startup_connect(),
            "native:runtime-environment" => {
                allowed_keys(p, &["sleeping", "lowPower", "networkEvents"])?;
                for key in ["sleeping", "lowPower", "networkEvents"] {
                    ensure!(
                        p.get(key).is_none_or(Value::is_boolean),
                        "运行环境参数需要是布尔值。"
                    );
                }
                let was_sleeping = self.environment.sleeping;
                if let Some(value) = p["sleeping"].as_bool() {
                    self.environment.sleeping = value;
                }
                if let Some(value) = p["lowPower"].as_bool() {
                    self.environment.low_power = value;
                }
                if let Some(value) = p["networkEvents"].as_bool() {
                    self.environment.network_events = value;
                }
                if self.environment.sleeping {
                    self.jobs.cancel_all();
                }
                if was_sleeping
                    && !self.environment.sleeping
                    && (self.wants_running || self.engine.owned.is_some())
                {
                    self.network_recovery.changed_for(None, "wake");
                    self.last_network_tick = None;
                    self.publish_runtime_status();
                }
                self.jobs.wake_background();
                Ok(json!(true))
            }
            "native:network-changed" => {
                if (self.engine.owned.is_some() || self.wants_running) && !self.engine.protected() {
                    self.network_recovery.changed(p["available"].as_bool());
                    self.last_network_tick = None;
                    self.jobs.cancel_all();
                    self.publish_runtime_status();
                    self.jobs.wake_background();
                }
                Ok(self.runtime_status())
            }
            "native:upgrade-helper" => self.update_connection_service(),
            "vpn:get-status" => self.status(),
            "nodes:list" => Ok(json!(self.nodes()?)),
            "node-groups:list" => self.groups(),
            "subscription:get-status" => self.engine.store.subscription(),
            "native:favorite" => {
                let name = string(p, "name")?;
                let mut s = self.engine.store.settings()?;
                let a = s["favoriteNodeNames"].as_array_mut().unwrap();
                if a.contains(&json!(name)) {
                    a.retain(|n| n != name);
                } else {
                    a.push(json!(name));
                }
                self.settings_patch(&json!({"favoriteNodeNames":a}), false)
            }
            "native:preferences" => {
                allowed_keys(
                    p,
                    &[
                        "tun",
                        "ipv6",
                        "lanDirect",
                        "tailscaleDirect",
                        "launchAtLogin",
                    ],
                )?;
                ensure!(
                    p.as_object().unwrap().values().all(Value::is_boolean),
                    "设置值格式无效。"
                );
                ensure!(
                    !(p["tun"] == false && self.company.state()["active"] == true),
                    "请先断开私有网络，再关闭系统分流。"
                );
                self.settings_patch(
                    p,
                    p.as_object()
                        .is_some_and(|m| m.keys().any(|k| k != "launchAtLogin")),
                )
            }
            "native:risk-key" => {
                let key = p["apiKey"].as_str().context("风险检测密钥格式无效。")?;
                ensure!(key.len() <= 512, "风险检测密钥过长。");
                self.risk_key = key.trim().into();
                Ok(json!({"configured":!self.risk_key.is_empty()}))
            }
            "ipdata:get-status" => Ok(
                json!({"configured":!self.risk_key.is_empty(),"maskedKey":if self.risk_key.is_empty(){Value::Null}else{json!(format!("****{}",self.risk_key.chars().rev().take(4).collect::<String>().chars().rev().collect::<String>()))},"storage":"encrypted","updatedAt":null,"routeConfigured":self.engine.store.settings()?["vpnDomainRules"].as_array().unwrap().contains(&json!("DOMAIN-SUFFIX,ipdata.co")),"requiredRule":"DOMAIN-SUFFIX,ipdata.co"}),
            ),
            "native:save-subscription" | "subscription:save" => self.save_subscription(p),
            "subscription:set-enabled"
            | "subscription:delete"
            | "subscription:clear-all"
            | "subscription:configure-update" => self.change_subscription(channel, p),
            "subscription:update" => {
                let plan = self.begin_manual_update(p)?;
                let downloaded = plan.download();
                self.finish_manual_update(plan, downloaded)
            }
            "node-groups:save" => {
                let g = p["nodeGroups"].as_array().context("节点组格式无效。")?;
                let mut ids = HashSetNames::default();
                for group in g {
                    let id = string(group, "id")?;
                    ensure!(
                        ids.add(id)
                            && group["name"].as_str().is_some_and(|s| !s.trim().is_empty())
                            && group["nodeNames"]
                                .as_array()
                                .is_some_and(|ns| ns.iter().all(Value::is_string)),
                        "节点组标识、名称或成员格式无效。"
                    );
                }
                self.settings_patch(&json!({"nodeGroups":g}), false)
            }
            "nodes:select" | "nodes:select-v2" => self.select_node(channel, p),
            "routing:update" => {
                allowed_keys(
                    p,
                    &[
                        "unknownTraffic",
                        "geoFallback",
                        "vpnDomainRules",
                        "directDomainRules",
                        "specialCompatibilityRules",
                    ],
                )?;
                ensure!(
                    p["unknownTraffic"].is_null()
                        || matches!(p["unknownTraffic"].as_str(), Some("direct" | "vpn")),
                    "默认分流策略无效。"
                );
                ensure!(
                    p["geoFallback"].is_null()
                        || matches!(
                            p["geoFallback"].as_str(),
                            Some("cn-direct-else-vpn" | "follow-default" | "block")
                        ),
                    "Geo 降级策略无效。"
                );
                self.settings_patch(p, true)
            }
            "routing:normalize-rule" => crate::routing::normalize_input(p),
            "routing:add-rule" | "routing:edit-rule" | "routing:delete-rule" => {
                allowed_keys(
                    p,
                    &["rule", "kind", "target", "originalRule", "originalTarget"],
                )?;
                let patch = crate::routing::edit_patch(&self.engine.store.settings()?, p, channel)?;
                self.settings_patch(&patch, true)
            }
            "routing:get-state" => {
                Ok(json!({"settings":self.engine.store.settings()?,"mihomo":self.runtime_status()}))
            }
            "routing:diagnose" => self.diagnose(string(p, "target")?),
            "vpn:start" => {
                if let Some(token) = p["recoveryToken"].as_str() {
                    self.confirm_recovery(token)?;
                }
                self.start_vpn(false)
            }
            "vpn:retry-recovery" => {
                ensure!(!self.engine.protected(), "当前连接由原版维护。");
                ensure!(
                    self.wants_running || self.engine.owned.is_some(),
                    "请先连接 VPN。"
                );
                ensure!(
                    !self.network_recovery.helper_update_required(),
                    "请先更新连接服务。"
                );
                self.network_recovery.changed_for(None, "manual-retry");
                self.last_network_tick = None;
                self.jobs.cancel_all();
                self.jobs.wake_background();
                self.publish_runtime_status();
                Ok(self.runtime_status())
            }
            "vpn:restart" => {
                let s = self.engine.store.settings()?;
                self.ensure_user_helper()?;
                self.network_recovery.changed(None);
                let result = self.transaction(|c| {
                    c.apply_config(&s)?;
                    Ok(c.runtime_status())
                });
                if let Err(error) = &result {
                    self.network_recovery
                        .failed(redact(&error.to_string()), Instant::now());
                }
                self.publish_runtime_status();
                result
            }
            "vpn:stop" => {
                self.wants_running = false;
                self.stop_runtime()?;
                self.network_recovery.clear();
                self.publish_company();
                Ok(self.runtime_status())
            }
            "subscription-probe:start" => self.start_vpn(true),
            "subscription-probe:stop" => {
                self.wants_running = false;
                if self.engine.mode == "subscription-probe" {
                    self.engine.stop()?;
                }
                Ok(self.runtime_status())
            }
            "traffic:get-monitor" => Ok(self.traffic()),
            "traffic:get-snapshot" | "subscription-probe:get-snapshot" => {
                Ok(self.traffic()["snapshot"].clone())
            }
            "connectivity:check" => self.network_check()?.connectivity(),
            "connectivity:test-website-speeds" => self.network_check()?.websites(),
            "nodes:test" => self.speed(string(p, "nodeName")?, false),
            "nodes:test-recommended" => {
                let node = self.node_identity(string(p, "identityKey")?)?;
                self.speed(node["name"].as_str().unwrap(), true)
            }
            "nodes:check-current-risk" => {
                let s = self.engine.store.settings()?;
                self.risk(s["selectedProxy"].as_str().unwrap())
            }
            "nodes:check-risk" => self.risk(string(p, "nodeName")?),
            "nodes:get-risk-cache" => self.risks(),
            "nodes:test-udp" => self.udp(string(p, "nodeName")?),
            "native:company-context" => {
                if self.engine.isolated {
                    Ok(json!({"interfaceName":"fixture"}))
                } else {
                    platform::context()
                }
            }
            "native:company-apply" => {
                self.ensure_user_helper()?;
                let r = self.company.install(&mut self.engine, p);
                if let Err(error) = &r {
                    self.log(
                        "warn",
                        &format!("私有网络接管未完成，已尝试恢复原配置：{error}"),
                    );
                }
                self.publish_company();
                r
            }
            "native:company-remove" => {
                let r = self.company.remove(&mut self.engine);
                self.publish_company();
                r
            }
            "native:company-verify" => {
                let r = self.company.verify(&mut self.engine, string(p, "target")?);
                self.publish_company();
                r
            }
            "native:company-internet-check" => {
                ensure!(!self.engine.isolated, "隔离模式不自动请求外网。");
                let r = self.company.internet_check();
                self.publish_company();
                r
            }
            "logs:get" => self.logs(p),
            "logs:export-redacted" => {
                let a = self.logs(&json!({"kind":"app"}))?;
                let m = self.logs(&json!({"kind":"mihomo"}))?;
                Ok(json!(format!(
                    "轻舟 Rust 核心 {}\n内核启动时间：{}\n网络恢复：{}\n{}\n{}",
                    env!("CARGO_PKG_VERSION"),
                    self.engine.started.as_deref().unwrap_or("未知"),
                    redact(&self.network_recovery.status().to_string()),
                    a.as_array()
                        .unwrap()
                        .iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join("\n"),
                    m.as_array()
                        .unwrap()
                        .iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join("\n")
                )))
            }
            "network:repair" => {
                self.wants_running = false;
                self.stop_runtime()?;
                // Windows has no DNS snapshot to restore: mihomo hijacks DNS
                // inside its own TUN, so stopping it plus a cache flush is enough.
                if cfg!(windows) && !self.engine.isolated {
                    let _ = platform::command("ipconfig", &["/flushdns"], Duration::from_secs(10));
                } else if !self.engine.isolated {
                    let restored = platform::helper(
                        &self.engine.store,
                        "restore-orphan-dns",
                        &self.engine.binary,
                        true,
                    )?;
                    ensure!(
                        restored["dnsRestoreOk"] == true,
                        "DNS 恢复尚未确认，恢复记录已保留。"
                    );
                    #[cfg(target_os = "macos")]
                    {
                        let _ = platform::command(
                            "/usr/bin/dscacheutil",
                            &["-flushcache"],
                            Duration::from_secs(5),
                        );
                    }
                }
                self.engine.store.set_recovery(false, None)?;
                self.recovery_authorized = None;
                Ok(json!({"ok":true,"message":"VPN 已安全停止并恢复 DNS。"}))
            }
            "runtime:get-recovery-state" => self.engine.store.recovery(),
            "runtime:prepare-recovery" => {
                let state = self.engine.store.recovery()?;
                ensure!(state["state"] == "required", "当前没有需要确认的恢复操作。");
                let token = uuid::Uuid::new_v4().to_string();
                let transaction = state["transactionId"]
                    .as_str()
                    .context("恢复事务无效。")?
                    .to_owned();
                let revision = state["stateRevision"].as_u64().context("恢复版本无效。")?;
                self.recovery_token =
                    Some((token.clone(), transaction.clone(), revision, Instant::now()));
                Ok(
                    json!({"token":token,"transactionId":transaction,"stateRevision":revision,"expiresAt":(chrono::Utc::now()+chrono::Duration::minutes(5)).to_rfc3339()}),
                )
            }
            "runtime:confirm-recovery" => {
                self.confirm_recovery(string(p, "token")?)?;
                self.engine.store.recovery()
            }
            _ => bail!("不支持的后台操作：{channel}"),
        }
    }
    fn assert_company_owner(&self) -> Result<()> {
        let journal = self
            .engine
            .store
            .read("runtime-state/native-company-routing.json", Value::Null)?;
        ensure!(
            !journal["ownerPid"]
                .as_u64()
                .is_some_and(|p| p as u32 != std::process::id() && platform::pid_alive(p as u32)),
            "另一原生窗口仍在管理私有网络连接，请先关闭它再应用变更。"
        );
        Ok(())
    }
    /// Called only by explicit user connection/configuration actions. Background
    /// DNS polling, startup attachment and automatic recovery never request auth.
    fn ensure_user_helper(&mut self) -> Result<()> {
        if self.engine.isolated || !cfg!(target_os = "macos") || self.engine.pid.is_none() {
            return Ok(());
        }
        let state = platform::helper_state(&self.engine.store);
        if state == platform::HelperState::Current {
            return Ok(());
        }
        ensure!(
            !self.engine.protected(),
            "当前连接由原版维护，请先在原版断开。"
        );
        self.assert_company_owner()?;
        ensure!(
            state == platform::HelperState::Outdated,
            "当前连接的特权服务绑定或协议无法确认，未修改其他连接。"
        );
        match platform::helper(&self.engine.store, "status", &self.engine.binary, false) {
            Ok(status) => ensure!(
                status["identityVerified"] == true
                    && status["pid"].as_u64().map(|p| p as u32) == self.engine.pid,
                "运行进程身份发生变化，未更新其他连接的服务。"
            ),
            // A legacy daemon compares local-time process tokens. The new
            // root-owned daemon migrates that record and independently verifies
            // PID, executable and start time before it can adopt/stop anything.
            Err(error) if error.to_string().contains("identity_mismatch") => {
                self.engine.api("GET", "/version", None)?;
                self.log(
                    "info",
                    "旧服务身份核对失败，将在用户授权更新后重新核对原进程。",
                );
            }
            Err(error) => return Err(error),
        }
        let store = self.engine.store.clone();
        let binary = self.engine.binary.clone();
        self.log("info", "特权服务需要更新，正在请求 macOS 授权。");
        self.upgrade_running_helper(|| platform::upgrade_helper(&store, &binary))?;
        self.network_recovery.clear();
        self.network_recovery.changed(None);
        Ok(())
    }
    fn update_connection_service(&mut self) -> Result<Value> {
        ensure!(
            !self.engine.protected(),
            "当前连接由原版维护，请先在原版断开。"
        );
        if !self.engine.isolated && cfg!(target_os = "macos") {
            if self.engine.pid.is_some() {
                self.ensure_user_helper()?;
                let status =
                    platform::helper(&self.engine.store, "status", &self.engine.binary, false)?;
                ensure!(
                    status["identityVerified"] == true
                        && status["pid"].as_u64().map(|p| p as u32) == self.engine.pid,
                    "更新后原进程身份尚未确认，未接管其他连接。"
                );
                self.engine.owned = self.engine.pid;
            } else {
                let state = platform::helper_state(&self.engine.store);
                ensure!(
                    state != platform::HelperState::OtherData,
                    "连接服务绑定了其他数据目录，未修改其他连接。"
                );
                if state != platform::HelperState::Current {
                    platform::upgrade_helper(&self.engine.store, &self.engine.binary)?;
                }
            }
        }
        self.network_recovery.clear();
        self.network_recovery.changed(None);
        if self.engine.pid.is_some() {
            self.wants_running = self.engine.mode == "vpn";
            let settings = self.engine.store.settings()?;
            let result = self.transaction(|c| c.apply_config(&settings));
            if let Err(error) = &result {
                self.network_recovery
                    .failed(redact(&error.to_string()), Instant::now());
            }
            self.publish_runtime_status();
            result?;
            Ok(json!({"mihomo":self.runtime_status()}))
        } else {
            self.start_vpn(false)
        }
    }
    fn upgrade_running_helper(&mut self, install: impl FnOnce() -> Result<()>) -> Result<()> {
        let before_pid = self.engine.pid.context("没有可接续的连接。")?;
        let picks = self.engine.selections()?;
        let base = fs::read_to_string(self.engine.store.path("mihomo/config.yaml"))?;
        let installed = install();
        // Cancelled authorization (or staging failure) leaves the old connection
        // intact. Do not stop it, change DNS, or save the requested new settings.
        if installed.is_err()
            && platform::pid_alive(before_pid)
            && self.engine.api("GET", "/version", None).is_ok()
        {
            return installed;
        }
        self.engine.pid = None;
        self.engine.owned = None;
        let resumed = (|| -> Result<()> {
            // Reuse the saved config and ports. On installer rollback the old,
            // protocol-compatible helper may start it without another auth UI.
            self.engine.start_authorized(false)?;
            if self.company.state()["active"] == true {
                self.company.reload_base(&mut self.engine, &base)?;
            }
            self.engine.restore_selections_checked(&picks)?;
            self.wants_running = self.engine.mode == "vpn";
            self.publish_company();
            Ok(())
        })();
        if let Err(error) = resumed {
            let message =
                format!("服务更新后未能恢复原连接：{error}。恢复记录已保留，请修复网络后重试。");
            self.engine.last_error = Some(message.clone());
            self.engine
                .store
                .set_recovery(true, Some("helper-upgrade-reconnect-failed"))?;
            self.log("error", &message);
            bail!(message);
        }
        if installed.is_ok() {
            self.log("info", "特权服务已更新，原连接和节点已恢复。");
        }
        installed
    }
    fn stop_runtime(&mut self) -> Result<()> {
        if let Err(error) = self.company.remove(&mut self.engine) {
            if self.engine.owned != self.engine.pid || self.engine.owned.is_none() {
                return Err(error);
            }
            self.engine.stop()?;
            self.company.remove(&mut self.engine)?;
            return Ok(());
        }
        self.engine.stop()
    }
    fn confirm_recovery(&mut self, token: &str) -> Result<()> {
        let (saved, transaction, revision, time) = self
            .recovery_token
            .take()
            .context("恢复确认已过期或已使用。")?;
        let state = self.engine.store.recovery()?;
        ensure!(
            saved == token
                && time.elapsed() < Duration::from_secs(300)
                && state["state"] == "required"
                && state["transactionId"] == transaction
                && state["stateRevision"] == revision,
            "恢复确认已过期或状态发生变化。"
        );
        self.recovery_authorized = Some((transaction, revision, time));
        Ok(())
    }
    fn save_subscription(&mut self, p: &Value) -> Result<Value> {
        let url = subscription::validate_url(string(p, "url")?)?.to_string();
        let id = p["id"].as_str().filter(|s| !s.is_empty());
        let mut record = self.engine.store.subscription()?;
        let entries = record["entries"].as_array_mut().unwrap();
        if let Some(id) = id {
            let e = entries
                .iter_mut()
                .find(|e| e["id"] == id)
                .context("找不到这条订阅。")?;
            if e["url"] != url {
                e.as_object_mut().unwrap().remove("downloadToken");
            }
            e["url"] = json!(url);
            e["name"] = json!(p["name"].as_str().unwrap_or("订阅"));
        } else if let Some(e) = entries.iter_mut().find(|e| e["url"] == url) {
            e["name"] = json!(p["name"].as_str().unwrap_or("订阅"));
        } else {
            entries.push(json!({"id":uuid::Uuid::new_v4().to_string(),"name":p["name"].as_str().unwrap_or("订阅"),"url":url,"enabled":true,"nodeCount":0,"status":"saved","updatedAt":null,"lastError":null,"lastAttemptAt":null,"updateIntervalMinutes":1440}));
        }
        summarize_subscription(&mut record);
        self.engine.store.write("subscription.json", &record)?;
        Ok(record)
    }
    fn change_subscription(&mut self, channel: &str, p: &Value) -> Result<Value> {
        let result = self.transaction(|c| {
            let mut r = c.engine.store.subscription()?;
            let entries = r["entries"].as_array_mut().unwrap();
            let id = if channel == "subscription:clear-all" {
                ""
            } else {
                string(p, "id")?
            };
            if channel != "subscription:clear-all" {
                ensure!(entries.iter().any(|e| e["id"] == id), "找不到这条订阅。");
            }
            let removes = channel == "subscription:delete"
                || (channel == "subscription:set-enabled" && p["enabled"] == false);
            if removes && c.engine.protected() {
                ensure!(
                    entries
                        .iter()
                        .any(|e| e["id"] != id && e["enabled"] == true),
                    "这是最后一条启用订阅，请先在原版断开。"
                );
            }
            match channel {
                "subscription:clear-all" => entries.clear(),
                "subscription:delete" => entries.retain(|e| e["id"] != id),
                "subscription:set-enabled" => {
                    ensure!(p["enabled"].is_boolean(), "启用参数无效。");
                    let entry = entries.iter_mut().find(|e| e["id"] == id).unwrap();
                    entry["enabled"] = p["enabled"].clone();
                    entry.as_object_mut().unwrap().remove("downloadToken");
                }
                _ => {
                    ensure!(
                        p.get("intervalMinutes").is_some()
                            && (p["intervalMinutes"].is_null()
                                || p["intervalMinutes"]
                                    .as_u64()
                                    .is_some_and(|n| (5..=10080).contains(&n))),
                        "更新间隔需要是 5～10080 分钟，或仅手动更新。"
                    );
                    entries.iter_mut().find(|e| e["id"] == id).unwrap()["updateIntervalMinutes"] =
                        p["intervalMinutes"].clone();
                }
            }
            if channel != "subscription:configure-update" {
                c.ensure_user_helper()?;
            }
            summarize_subscription(&mut r);
            c.engine.store.write("subscription.json", &r)?;
            if channel == "subscription:delete" || channel == "subscription:clear-all" {
                let mut m = c.engine.store.manifest()?;
                m["entries"].as_array_mut().unwrap().retain(|e| {
                    r["entries"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|s| s["id"] == e["subscriptionId"])
                });
                c.engine.store.save_manifest(m)?;
            }
            if channel != "subscription:configure-update" {
                c.maintain_after_subscription()?;
            }
            Ok(r)
        });
        if result.is_ok() {
            let _ = subscription::prune_providers(&self.engine.store);
        }
        result
    }
    pub fn update_subscriptions(&mut self, ids: Option<Vec<String>>) -> Result<Value> {
        self.update_subscriptions_with(ids, |_, url, mixed| subscription::download(url, mixed))
    }
    fn update_subscriptions_with(
        &mut self,
        ids: Option<Vec<String>>,
        mut download: impl FnMut(&str, &str, Option<u16>) -> Result<subscription::Downloaded>,
    ) -> Result<Value> {
        let result = self.transaction(|c| {
            let mut r = c.engine.store.subscription()?;
            if let Some(ids) = &ids {
                ensure!(
                    ids.iter().all(|id| r["entries"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|e| e["id"] == *id)),
                    "找不到这条订阅。"
                );
            }
            let targets = r["entries"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|e| {
                    e["enabled"] == true
                        && ids
                            .as_ref()
                            .is_none_or(|ids| ids.iter().any(|id| e["id"] == *id))
                })
                .cloned()
                .collect::<Vec<_>>();
            ensure!(!targets.is_empty(), "没有可更新的启用订阅。");
            let mut manifest = c.engine.store.manifest()?;
            let mut changed = false;
            for e in targets {
                let id = e["id"].as_str().context("订阅标识无效。")?;
                let url = e["url"].as_str().context("订阅链接无效。")?;
                r["entries"]
                    .as_array_mut()
                    .unwrap()
                    .iter_mut()
                    .find(|e| e["id"] == id)
                    .unwrap()
                    .as_object_mut()
                    .unwrap()
                    .remove("downloadToken");
                let result = download(id, url, c.engine.pid.map(|_| c.engine.mixed));
                match result {
                    Ok(nodes) => {
                        changed |= subscription::commit_update(
                            &c.engine.store,
                            &mut r,
                            &mut manifest,
                            id,
                            nodes,
                        )?
                    }
                    Err(error) => {
                        let entry = r["entries"]
                            .as_array_mut()
                            .unwrap()
                            .iter_mut()
                            .find(|e| e["id"] == id)
                            .unwrap();
                        entry["lastError"] = json!(redact(&error.to_string()));
                        entry["lastAttemptAt"] = json!(now());
                        if entry["nodeCount"].as_u64().unwrap_or(0) == 0 {
                            entry["status"] = json!("error");
                        }
                        c.log("warn", "订阅下载失败，保留上次已提交节点。");
                    }
                }
            }
            summarize_subscription(&mut r);
            if changed {
                c.engine.store.save_manifest(manifest)?;
            }
            c.engine.store.write("subscription.json", &r)?;
            c.sync_subscription_groups()?;
            if changed {
                c.maintain_after_subscription()?;
            }
            Ok(r)
        });
        // Only a committed manifest may drop the revisions it replaced.
        if result.is_ok() {
            let _ = subscription::prune_providers(&self.engine.store);
        }
        result
    }
    /// Preflight of a manual `subscription:update` under the core lock. The
    /// downloads then run without it so status requests keep being served.
    pub fn begin_manual_update(&mut self, p: &Value) -> Result<ManualUpdate> {
        if !self.engine.isolated {
            let _ = self.engine.attach();
        }
        self.assert_company_owner()?;
        self.ensure_user_helper()?;
        let ids = p["id"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(|s| vec![s.to_owned()]);
        let mut r = self.engine.store.subscription()?;
        let entries = r["entries"].as_array().context("订阅数据格式无效。")?;
        if let Some(ids) = &ids {
            ensure!(
                ids.iter().all(|id| entries.iter().any(|e| e["id"] == *id)),
                "找不到这条订阅。"
            );
        }
        let targets = entries
            .iter()
            .filter(|e| {
                e["enabled"] == true
                    && ids
                        .as_ref()
                        .is_none_or(|ids| ids.iter().any(|id| e["id"] == *id))
            })
            .filter_map(|e| {
                Some((
                    e["id"].as_str()?.to_owned(),
                    e["url"].as_str()?.to_owned(),
                    uuid::Uuid::new_v4().to_string(),
                ))
            })
            .collect::<Vec<_>>();
        ensure!(!targets.is_empty(), "没有可更新的启用订阅。");
        for (id, _, token) in &targets {
            r["entries"]
                .as_array_mut()
                .unwrap()
                .iter_mut()
                .find(|e| e["id"] == *id)
                .unwrap()["downloadToken"] = json!(token);
        }
        self.engine.store.write("subscription.json", &r)?;
        self.jobs
            .pending_downloads
            .lock()
            .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?
            .extend(targets.iter().map(|(_, _, token)| token.clone()));
        Ok(ManualUpdate {
            targets,
            mixed: self.engine.pid.map(|_| self.engine.mixed),
            jobs: self.jobs.clone(),
        })
    }
    /// Commits only the still-current requests. Never downloads under the lock.
    pub fn finish_manual_update(
        &mut self,
        plan: ManualUpdate,
        mut downloaded: Vec<(String, String, Result<subscription::Downloaded>)>,
    ) -> Result<Value> {
        ensure!(!self.jobs.shutdown.load(Ordering::SeqCst), "后台正在退出。");
        let record = self.engine.store.subscription()?;
        let ids: Vec<_> = plan
            .targets
            .iter()
            .filter(|(id, url, token)| {
                record["entries"].as_array().unwrap().iter().any(|e| {
                    e["id"] == *id
                        && e["url"] == *url
                        && e["enabled"] == true
                        && e["downloadToken"] == *token
                })
            })
            .map(|(id, _, _)| id.clone())
            .collect();
        if ids.is_empty() {
            return Ok(record);
        }
        self.update_subscriptions_with(Some(ids), |id, url, _| {
            match downloaded.iter().position(|(i, u, _)| i == id && u == url) {
                Some(index) => downloaded.swap_remove(index).2,
                None => bail!("订阅下载结果缺失，旧节点已保留。"),
            }
        })
    }
    fn sync_subscription_groups(&mut self) -> Result<()> {
        let nodes = subscription::provider_nodes(&self.engine.store)?;
        let record = self.engine.store.subscription()?;
        let mut s = self.engine.store.settings()?;
        let groups = s["nodeGroups"].as_array_mut().unwrap();
        groups.retain(|g| {
            !g["id"]
                .as_str()
                .is_some_and(|id| id.starts_with("subscription:"))
        });
        for e in record["entries"].as_array().unwrap() {
            let id = e["id"].as_str().unwrap();
            let members = nodes
                .iter()
                .filter(|n| n["subscriptionId"] == id)
                .collect::<Vec<_>>();
            groups.push(json!({"id":format!("subscription:{id}"),"name":e["name"],"nodeNames":members.iter().map(|n|n["name"].clone()).collect::<Vec<_>>(),"members":members.iter().map(|n|json!({"identityKey":n["identityKey"],"lastKnownName":n["name"]})).collect::<Vec<_>>(),"strategy":"manual"}));
        }
        self.engine.store.write("settings.json", &s)
    }
    fn maintain_after_subscription(&mut self) -> Result<()> {
        let s = self.engine.store.settings()?;
        let selected = s["selectedProxy"].as_str().unwrap();
        let nodes = subscription::provider_nodes(&self.engine.store)?;
        if selected != "DIRECT"
            && !nodes
                .iter()
                .any(|n| n["name"] == selected && n["identityAmbiguous"] == false)
        {
            if self.engine.pid.is_some() {
                ensure!(
                    !self.engine.protected(),
                    "当前节点已不可用，请先在原版断开后应用订阅变更。"
                );
                self.wants_running = false;
                self.stop_runtime()?;
            }
            return Ok(());
        }
        self.apply_config(&s)
    }
    fn node_identity(&self, key: &str) -> Result<Value> {
        let n = subscription::provider_nodes(&self.engine.store)?
            .into_iter()
            .find(|n| n["identityKey"] == key)
            .context("节点已移除或订阅停用。");
        let n = n?;
        ensure!(
            n["identityAmbiguous"] == false,
            "同名节点存在于多个订阅，不能进行可信选择或检测。"
        );
        Ok(n)
    }
    fn select_node(&mut self, channel: &str, p: &Value) -> Result<Value> {
        let node = if channel == "nodes:select-v2" {
            self.node_identity(string(p, "identityKey")?)?
        } else {
            json!({"name":"DIRECT","identityKey":null})
        };
        let name = node["name"].as_str().unwrap().to_owned();
        self.ensure_user_helper()?;
        self.revision += 1;
        self.transaction(|c| {
            let mut s = c.engine.store.settings()?;
            let before = if c.engine.pid.is_some() {
                c.engine.selections()?["VPN"]
                    .as_str()
                    .context("当前出口无法核对。")?
                    .to_owned()
            } else {
                s["selectedProxy"].as_str().unwrap().to_owned()
            };
            s["selectedProxy"] = json!(name);
            s["defaultOutlet"] =
                json!({"kind":"node","identityKey":node["identityKey"],"name":name});
            if c.engine.pid.is_some() {
                c.engine.select(&name)?;
                if let Err(error) = c.apply_config(&s) {
                    let _ = c.engine.select(&before);
                    return Err(error);
                }
            }
            c.engine.store.write("settings.json", &s)?;
            Ok(s)
        })
    }
    fn startup_connect(&mut self) -> Result<Value> {
        let helper = (!self.engine.isolated && cfg!(target_os = "macos"))
            .then(|| platform::helper_state(&self.engine.store));
        self.startup_connect_with_helper(helper)
    }
    fn startup_connect_with_helper(
        &mut self,
        helper: Option<platform::HelperState>,
    ) -> Result<Value> {
        if self.startup_connect_attempted {
            return Ok(
                json!({"startupOutcome":"already-attempted","mihomo":self.runtime_status()}),
            );
        }
        self.startup_connect_attempted = true;
        self.engine.attach()?;
        if !self.engine.protected()
            && helper.is_some_and(|state| {
                matches!(
                    state,
                    platform::HelperState::Outdated
                        | platform::HelperState::Missing
                        | platform::HelperState::Incompatible
                )
            })
        {
            self.network_recovery.require_helper_update(
                "连接服务需要更新。请点击「更新连接服务」，按 macOS 提示完成授权后再连接。",
            );
            return Ok(
                json!({"startupOutcome":"helper-update-required","mihomo":self.runtime_status()}),
            );
        }
        if self.engine.pid.is_some() {
            // After a native app crash the verified helper may still own the
            // engine. Resume monitoring that connection, but protect legacy UI.
            if !self.engine.isolated && cfg!(target_os = "macos") && !self.engine.protected() {
                self.assert_company_owner()?;
                let status =
                    platform::helper(&self.engine.store, "status", &self.engine.binary, false)?;
                ensure!(
                    status["identityVerified"] == true
                        && status["pid"].as_u64().map(|p| p as u32) == self.engine.pid,
                    "现有内核身份尚未确认，未自动接管连接。"
                );
                self.engine.owned = self.engine.pid;
                self.wants_running = true;
                let context = platform::context().ok();
                let config = fs::read_to_string(self.engine.store.path("mihomo/config.yaml"))
                    .ok()
                    .and_then(|text| config::parse(&text).ok());
                if let (Some(context), Some(config)) = (context, config) {
                    if config["interface-name"] == context["interfaceName"] {
                        self.network_recovery
                            .applied(context["signature"].as_str().map(str::to_owned));
                    } else {
                        self.network_recovery.changed(None);
                    }
                } else {
                    self.network_recovery.changed(None);
                }
            }
            return Ok(json!({"startupOutcome":"already-running","mihomo":self.runtime_status()}));
        }
        self.assert_company_owner()?;
        // A launch is one automatic attempt, never a request to install a
        // privileged service or to restart a connection owned by another app.
        self.auto_starting = true;
        let result = self.start_vpn(false);
        self.auto_starting = false;
        match result {
            Ok(mut value) => {
                value["startupOutcome"] = json!("connected");
                self.log("info", "启动后已自动连接 VPN。");
                Ok(value)
            }
            // Right after boot or login the default route is often not up yet.
            // Keep wanting the connection; tick() starts it once the network
            // signature has been stable for a few seconds.
            Err(error) if !self.engine.isolated && platform::context().is_err() => {
                self.wants_running = true;
                self.network_recovery.observe(None, false, Instant::now());
                self.log(
                    "info",
                    &format!("网络尚未就绪，就绪后自动连接 VPN：{error}"),
                );
                Ok(json!({"startupOutcome":"waiting-network","mihomo":self.runtime_status()}))
            }
            Err(error) => {
                self.wants_running = false;
                self.log("warn", &format!("启动自动连接未完成：{error}"));
                Err(error)
            }
        }
    }
    fn start_vpn(&mut self, probe: bool) -> Result<Value> {
        self.engine.attach()?;
        if !probe && !self.auto_starting {
            self.ensure_user_helper()?;
        }
        if self.engine.pid.is_some() {
            if probe {
                ensure!(
                    !self.engine.protected(),
                    "原版维护当前连接，不能进入探测模式。"
                );
                self.engine.stop()?;
            } else {
                return Ok(
                    json!({"mihomo":self.runtime_status(),"controllerOk":true,"controllerError":null}),
                );
            }
        }
        let recovery = self.engine.store.recovery()?;
        ensure!(
            recovery["state"] != "required"
                || self.recovery_authorized.as_ref().is_some_and(
                    |(transaction, revision, time)| recovery["transactionId"] == *transaction
                        && recovery["stateRevision"] == *revision
                        && time.elapsed() < Duration::from_secs(300)
                ),
            "RECOVERY_REQUIRED：请先修复网络或确认恢复后再连接。"
        );
        let s = self.engine.store.settings()?;
        ensure!(
            probe
                || (s["defaultOutlet"]["kind"] != "group" && s["selectedProxy"] == "DIRECT")
                || subscription::provider_nodes(&self.engine.store)?
                    .iter()
                    .any(|n| n["name"] == s["selectedProxy"] && n["identityAmbiguous"] == false),
            "请选择一个具体节点后连接 VPN。"
        );
        self.engine.prepare_ports()?;
        let context = if self.engine.isolated {
            Value::Null
        } else {
            platform::context()?
        };
        let interface = context["interfaceName"].as_str().map(str::to_owned);
        let udp_before = self.selected_udp(&s)?;
        // A fresh data directory must see bundled geo rules before choosing a fallback.
        self.engine.prepare_geodata()?;
        let mut cfg = config::build(
            &self.engine.store,
            &s,
            self.engine.mixed,
            self.engine.controller,
            interface.as_deref(),
            udp_before,
        )?;
        if probe {
            cfg["proxy-groups"] = json!([]);
            cfg["proxy-providers"] = json!({});
            cfg["rule-providers"] = json!({});
            cfg["rules"] = json!(["MATCH,DIRECT"]);
        } else {
            config::add_probe(&mut cfg, self.engine.probe);
        }
        atomic_write(
            &self.engine.store.path("mihomo/providers/vpn-domains.yaml"),
            config::yaml(&json!({"payload":s["vpnDomainRules"]}))?.as_bytes(),
        )?;
        atomic_write(
            &self.engine.store.path("mihomo/config.yaml"),
            config::yaml(&cfg)?.as_bytes(),
        )?;
        self.engine.mode = if probe { "subscription-probe" } else { "vpn" }.into();
        self.engine.start_authorized(!self.auto_starting)?;
        self.wants_running = !probe;
        if !probe && self.engine.has_proxy("VPN")? {
            let selected = s["selectedProxy"].as_str().unwrap();
            self.engine
                .wait_for_vpn_member(selected, Duration::from_secs(20));
            if let Err(error) = self.engine.select(selected) {
                let _ = self.engine.stop();
                return Err(error);
            }
            if self.selected_udp(&s)? != udp_before {
                self.transaction(|c| c.apply_config(&s))?;
            }
        }
        if recovery["state"] == "required" {
            self.engine.store.set_recovery(false, None)?;
            self.recovery_authorized = None;
        }
        let confirmed = self
            .engine
            .confirm_network_binding(interface.as_deref(), s["tun"] == true)
            .and_then(|_| {
                if s["tun"] == true {
                    self.engine.refresh_dns()
                } else {
                    Ok(())
                }
            });
        if let Err(error) = confirmed {
            if !self.auto_starting {
                self.network_recovery
                    .failed(redact(&error.to_string()), Instant::now());
            }
            return Err(error);
        }
        self.network_recovery
            .applied(context["signature"].as_str().map(str::to_owned));
        Ok(
            json!({"mihomo":self.runtime_status(),"controllerOk":true,"controllerError":null,"runtimePorts":{"mixedPort":self.engine.mixed,"externalControllerPort":self.engine.controller}}),
        )
    }
    pub fn traffic(&mut self) -> Value {
        let mut error = None;
        let mut snapshot = Value::Null;
        let mut rates = json!({"upload":0,"download":0});
        if self.engine.pid.is_some() {
            match self.engine.api("GET", "/connections", None) {
                Ok(v) => {
                    let up = v["uploadTotal"].as_u64().unwrap_or(0);
                    let down = v["downloadTotal"].as_u64().unwrap_or(0);
                    if let Some((a, b, time)) = self.last_totals {
                        let secs = time.elapsed().as_secs_f64().max(0.01);
                        rates = json!({"upload":up.saturating_sub(a) as f64/secs,"download":down.saturating_sub(b) as f64/secs});
                    }
                    self.last_totals = Some((up, down, Instant::now()));
                    let connections=v["connections"].as_array().map(|a|a.iter().map(|c|json!({"id":c["id"].as_str().unwrap_or(""),"host":c["metadata"]["host"].as_str().unwrap_or(""),"network":c["metadata"]["network"].as_str().unwrap_or(""),"type":c["metadata"]["type"].as_str().unwrap_or(""),"rule":c["rule"].as_str().unwrap_or(""),"rulePayload":c["rulePayload"].as_str().unwrap_or(""),"chains":c["chains"].as_array().cloned().unwrap_or_default(),"upload":c["upload"].as_u64().unwrap_or(0),"download":c["download"].as_u64().unwrap_or(0),"process":c["metadata"]["process"],"destination":format!("{}:{}",c["metadata"]["destinationIP"].as_str().unwrap_or(""),c["metadata"]["destinationPort"].as_str().map(str::to_owned).unwrap_or_else(||c["metadata"]["destinationPort"].to_string()))})).collect::<Vec<_>>()).unwrap_or_default();
                    snapshot = json!({"uploadTotal":up,"downloadTotal":down,"connectionCount":connections.len(),"connections":connections});
                }
                Err(e) => error = Some(redact(&e.to_string())),
            }
        }
        self.samples
            .push(json!({"upload":rates["upload"],"download":rates["download"],"sampledAt":now()}));
        if self.samples.len() > 120 {
            self.samples.remove(0);
        }
        json!({"snapshot":snapshot,"rates":rates,"samples":self.samples,"running":self.engine.pid.is_some(),"updatedAt":now(),"error":error})
    }
    /// State a connectivity check needs, taken under the core lock so the
    /// network requests themselves run without it.
    pub fn network_check(&mut self) -> Result<NetworkCheck> {
        if !self.engine.isolated {
            let _ = self.engine.attach();
        }
        let settings = self.engine.store.settings()?;
        Ok(NetworkCheck {
            isolated: self.engine.isolated,
            tun: settings["tun"] == true,
            running: self.engine.pid.is_some(),
            mixed: self.engine.mixed,
            selected: settings["selectedProxy"].clone(),
        })
    }
    pub fn speed(&mut self, name: &str, recommended: bool) -> Result<Value> {
        let n = self
            .nodes()?
            .into_iter()
            .find(|n| n["name"] == name && n["identityKey"].is_string())
            .context("节点不存在。");
        let n = n?;
        ensure!(
            n["identityAmbiguous"] == false,
            "同名节点不能进行可信测速。"
        );
        ensure!(self.engine.pid.is_some(), "请先连接 VPN。");
        let before = self.engine.pid;
        let mut samples = Vec::new();
        let mut target_samples = Vec::new();
        let config_before = fs::read(self.engine.store.path("mihomo/config.yaml")).ok();
        let mut errors = Vec::new();
        for _ in 0..if recommended { 3 } else { 1 } {
            match self.engine.api(
                "GET",
                &format!(
                    "/proxies/{}/delay?timeout=8000&url={}",
                    encode(name),
                    encode("https://www.gstatic.com/generate_204")
                ),
                None,
            ) {
                Ok(v) if v["delay"].as_u64().unwrap_or(0) > 0 => {
                    samples.push(v["delay"].as_u64().unwrap());
                    target_samples.push(json!({"targetId":"gstatic-204","delayMs":v["delay"],"transportOk":true,"expectedStatusMatched":null,"failureReason":null,"checkedAt":now()}));
                }
                Ok(_) => {
                    errors.push("节点未返回有效延迟。".into());
                    target_samples.push(json!({"targetId":"gstatic-204","delayMs":null,"transportOk":false,"expectedStatusMatched":null,"failureReason":"transport-error","checkedAt":now()}));
                }
                Err(e) => {
                    errors.push(redact(&e.to_string()));
                    target_samples.push(json!({"targetId":"gstatic-204","delayMs":null,"transportOk":false,"expectedStatusMatched":null,"failureReason":"transport-error","checkedAt":now()}));
                }
            }
        }
        samples.sort_unstable();
        self.engine.attach()?;
        let changed = before != self.engine.pid
            || config_before != fs::read(self.engine.store.path("mihomo/config.yaml")).ok();
        let median = samples.get(samples.len() / 2).copied();
        let result = json!({"identityKey":n["identityKey"],"nodeName":name,"runtimeName":name,"targetSetId":if recommended{"recommended-latency"}else{"default-latency"},"targetSetVersion":1,"status":if changed{"runtime-changed"}else if median.is_none(){"unreachable"}else if recommended && samples.len()<2{"unstable"}else{"available"},"medianDelayMs":if changed{None}else{median},"medianMs":if changed{None}else{median},"delay":median,"p95Ms":samples.last(),"samples":target_samples,"results":[],"error":errors.first(),"errors":errors,"checkedAt":now(),"schemaVersion":1,"providerRevision":n["providerRevision"],"testedAt":now()});
        if !changed {
            let mut cache = self.engine.store.read(
                "runtime-state/speed-cache.json",
                json!({"schemaVersion":1,"entries":[]}),
            )?;
            let es = cache["entries"]
                .as_array_mut()
                .context("测速缓存格式无效。")?;
            es.retain(|e| {
                !(e["identityKey"] == n["identityKey"] && e["targetSetId"] == result["targetSetId"])
            });
            es.insert(0, result.clone());
            es.truncate(500);
            self.engine
                .store
                .write("runtime-state/speed-cache.json", &cache)?;
        }
        Ok(result)
    }
    pub fn risk(&mut self, name: &str) -> Result<Value> {
        ensure!(
            !self.risk_key.is_empty(),
            "请先在风险页面配置 ipdata 密钥。"
        );
        let s = self.engine.store.settings()?;
        ensure!(
            s["vpnDomainRules"]
                .as_array()
                .unwrap()
                .contains(&json!("DOMAIN-SUFFIX,ipdata.co")),
            "请先将 ipdata.co 加入 VPN 分流。"
        );
        ensure!(self.engine.pid.is_some(), "请先连接 VPN。");
        let endpoint = if self.engine.isolated {
            let raw =
                std::env::var("SPLITVPN_TEST_IPDATA_URL").context("隔离检测需要回环测试端点。")?;
            let url = url::Url::parse(&raw)?;
            ensure!(
                url.scheme() == "http" && matches!(url.host_str(), Some("127.0.0.1" | "::1")),
                "隔离测试端点必须为回环地址。"
            );
            url
        } else {
            url::Url::parse("https://api.ipdata.co/")?
        };
        ensure!(
            name == "DIRECT"
                || subscription::provider_nodes(&self.engine.store)?
                    .iter()
                    .any(|n| n["name"] == name && n["identityAmbiguous"] == false),
            "节点不存在或存在同名冲突。"
        );
        let port = self.engine.select_probe(name)?;
        let result = (|| -> Result<Value> {
            let mut v: Value = proxied(port, 15)?
                .get(endpoint.clone())
                .query(&[("api-key", &self.risk_key)])
                .send()?
                .error_for_status()?
                .json()?;
            ensure!(v["ip"].as_str().is_some(), "风险服务未返回出口 IP。");
            if v["threat"].is_null() {
                let threat: Value = proxied(port, 15)?
                    .get(endpoint.join(&format!("{}/threat", encode(v["ip"].as_str().unwrap())))?)
                    .query(&[("api-key", &self.risk_key)])
                    .send()?
                    .error_for_status()?
                    .json()?;
                v["threat"] = threat.get("threat").unwrap_or(&threat).clone();
                if v["scores"].is_null() {
                    v["scores"] = threat["scores"].clone();
                }
            }
            Ok(risk_result(name, &v))
        })();
        let result = result?;
        let mut cache = self
            .engine
            .store
            .read("ipdata-risk-cache.json", json!({"version":1,"entries":[]}))?;
        let a = cache["entries"]
            .as_array_mut()
            .context("风险缓存格式无效。")?;
        a.retain(|e| e["nodeName"] != name);
        a.insert(0, result.clone());
        self.engine.store.write("ipdata-risk-cache.json", &cache)?;
        Ok(result)
    }
    pub fn udp(&mut self, name: &str) -> Result<Value> {
        let n = self
            .nodes()?
            .into_iter()
            .find(|n| n["name"] == name && n["identityKey"].is_string())
            .context("节点不存在。");
        let n = n?;
        ensure!(
            n["identityAmbiguous"] == false,
            "同名节点不能进行可信探测。"
        );
        if n["runtimeUdpSupported"] != true {
            return Ok(
                json!({"nodeName":name,"supported":false,"ok":false,"error":"此节点不支持 UDP，未发送探测。","checkedAt":now()}),
            );
        }
        ensure!(self.engine.pid.is_some(), "请先连接 VPN。");
        let result = udp_stun(self.engine.select_probe(name)?);
        Ok(
            json!({"nodeName":name,"supported":result.is_ok(),"ok":result.is_ok(),"error":result.err().map(|e|redact(&e.to_string())),"checkedAt":now()}),
        )
    }
    fn diagnose(&self, target: &str) -> Result<Value> {
        crate::routing::diagnose(&self.engine.store.settings()?, target)
    }
    fn logs(&self, p: &Value) -> Result<Value> {
        let kind = p["kind"].as_str().unwrap_or("app");
        ensure!(matches!(kind, "app" | "mihomo"), "日志类型无效。");
        let path = self.engine.store.path(&format!("logs/{kind}.log"));
        let mut file = match fs::File::open(path) {
            Ok(f) => f,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(json!([])),
            Err(e) => return Err(e.into()),
        };
        use std::io::{Seek, SeekFrom};
        let size = file.metadata()?.len();
        file.seek(SeekFrom::Start(size.saturating_sub(1024 * 1024)))?;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)?;
        let text = String::from_utf8_lossy(&bytes);
        let mut lines = text
            .lines()
            .rev()
            .take(1000)
            .map(redact)
            .collect::<Vec<_>>();
        lines.reverse();
        Ok(json!(lines))
    }
    pub fn background_interval(&self) -> Duration {
        self.environment.maintenance_interval(
            self.wants_running
                || self.engine.pid.is_some()
                || self.company.state()["proxyName"].is_string(),
            self.network_recovery.needs_fast_check() || self.company.state()["recovering"] == true,
        )
    }
    /// All diagnostics below use fixed categories, never upstream error text,
    /// socket IDs, hostnames, process paths, node names or addresses.
    fn check_connection_health(&mut self) {
        if self.health_pid != self.engine.pid {
            self.health_pid = self.engine.pid;
            self.connection_health = ConnectionHealth::default();
            self.last_health_tick = None;
            self.health_failures = 0;
            self.wechat_route = None;
        }
        if self.engine.pid.is_none()
            || self.engine.owned != self.engine.pid
            || self.network_recovery.status()["state"] != "ready"
            || self
                .last_health_tick
                .is_some_and(|t| t.elapsed() < Duration::from_secs(30))
        {
            // Never carry suspected stalls across a physical network recovery.
            if self.network_recovery.status()["state"] != "ready" {
                self.connection_health = ConnectionHealth::default();
            }
            return;
        }
        let now = Instant::now();
        self.last_health_tick = Some(now);
        let Ok(settings) = self.engine.store.settings() else {
            return;
        };
        let context = platform::context().ok();
        // Missing physical connectivity belongs to the existing path monitor.
        let Some(context) = context else { return };
        let healthy = self
            .engine
            .confirm_network_binding(context["interfaceName"].as_str(), settings["tun"] == true)
            .is_ok();
        self.record_tunnel_health(healthy);
        if !healthy {
            self.connection_health.observe(&Value::Null, now);
            return;
        }
        if settings["specialCompatibilityRules"]["wechatImageSendFallback"] != true {
            self.connection_health = ConnectionHealth::default();
            self.wechat_route = None;
            return;
        }
        if let Ok(group) = self.engine.api("GET", "/proxies/WECHAT", None) {
            let route = match group["now"].as_str() {
                Some("DIRECT") => "direct",
                Some("VPN") => "proxy",
                _ => "unknown",
            };
            if self.wechat_route != Some(route) {
                self.log(
                    "info",
                    &format!("connection-health scope=wechat route={route} outcome=route-observed"),
                );
                self.wechat_route = Some(route);
            }
        }
        let snapshot = self
            .engine
            .api("GET", "/connections", None)
            .unwrap_or(Value::Null);
        if let Some(id) = self.connection_health.observe(&snapshot, now) {
            self.retry_wechat_connection(&id);
        }
    }
    fn record_tunnel_health(&mut self, healthy: bool) {
        if healthy {
            if self.health_failures > 0 {
                self.log(
                    "info",
                    "connection-health reason=tunnel-check outcome=healthy",
                );
            }
            self.health_failures = 0;
            return;
        }
        self.health_failures = self.health_failures.saturating_add(1);
        if self.health_failures == 1 {
            self.log(
                "warn",
                "connection-health reason=tunnel-or-controller-unavailable outcome=observing",
            );
        }
        if self.health_failures == 3 {
            self.log("warn", "connection-health reason=tunnel-or-controller-unavailable samples=3 outcome=recovery-requested");
            self.network_recovery.changed_for(None, "health-check");
            self.last_network_tick = None;
        }
    }
    fn retry_wechat_connection(&self, id: &str) {
        self.log("warn", "connection-health scope=wechat reason=no-response-120s quiet=30s outcome=targeted-retry-requested");
        let result =
            self.engine
                .authorized("DELETE", &format!("/connections/{}", encode(id)), None);
        let outcome = if result.is_ok_and(|r| r.status().is_success() || r.status() == 404) {
            "socket-closed-awaiting-app-retry"
        } else {
            "close-failed"
        };
        self.log(
            "info",
            &format!("connection-health scope=wechat outcome={outcome}"),
        );
    }

    pub fn tick(&mut self) {
        if self.environment.sleeping
            || self.jobs.shutdown.load(Ordering::SeqCst)
            || self.assert_company_owner().is_err()
        {
            return;
        }
        if let Err(error) = self.company.monitor(&mut self.engine) {
            let message = redact(&error.to_string());
            if self.last_monitor_error.as_ref() != Some(&message) {
                self.log("warn", &format!("私有网络分流核对未完成：{message}"));
                self.last_monitor_error = Some(message);
            }
        } else {
            self.last_monitor_error = None;
        }
        self.publish_company();
        if self.engine.isolated {
            return;
        }
        let previous_pid = self.engine.pid;
        let _ = self.engine.attach();
        if previous_pid.is_some() && self.engine.pid.is_none() {
            self.last_network_tick = None;
        }
        if self.wants_running && self.engine.pid.is_some() && self.engine.owned != self.engine.pid {
            self.wants_running = false;
        }
        self.check_connection_health();
        self.publish_runtime_status();
        if (self.engine.owned.is_some() || self.wants_running)
            && self.last_network_tick.is_none_or(|time| {
                time.elapsed()
                    >= self
                        .environment
                        .network_interval(self.network_recovery.needs_fast_check())
            })
        {
            self.last_network_tick = Some(Instant::now());
            if self.check_helper_update() {
                self.publish_runtime_status();
                return;
            }
            let context = platform::context().ok();
            let signature = context
                .as_ref()
                .and_then(|value| value["signature"].as_str());
            if self
                .network_recovery
                .observe(signature, self.engine.pid.is_some(), Instant::now())
                && !platform::legacy_owner()
            {
                // A network change invalidates in-flight node checks too; they
                // must not defer recovery indefinitely or restore a stale outlet.
                self.jobs.cancel_all();
                self.publish_runtime_status();
                let retry_state = self.network_recovery.clone();
                let result = if self.engine.pid.is_none() && self.wants_running {
                    self.auto_starting = true;
                    let result = self.start_vpn(false).map(|_| ());
                    self.auto_starting = false;
                    result
                } else {
                    self.recover_network(context.as_ref().unwrap())
                };
                if let Err(error) = result {
                    self.network_recovery = retry_state;
                    let message = redact(&error.to_string());
                    self.network_recovery
                        .failed(message.clone(), Instant::now());
                    self.log("warn", &format!("网络恢复未完成：{message}"));
                } else {
                    self.log("info", "网络恢复完成，新网卡配置与系统 DNS 已确认。");
                }
            }
            self.publish_runtime_status();
        }
    }
    pub fn take_recovery_check(&mut self) -> Option<(u64, u32, NetworkCheck)> {
        if self.engine.isolated
            || self.environment.sleeping
            || self.jobs.shutdown.load(Ordering::SeqCst)
        {
            return None;
        }
        let id = self.network_recovery.take_check()?;
        let pid = self.engine.pid?;
        match self.network_check() {
            Ok(check) => Some((id, pid, check)),
            Err(_) => {
                self.network_recovery.checked(id, false);
                self.publish_runtime_status();
                None
            }
        }
    }
    pub fn complete_recovery_check(&mut self, id: u64, pid: u32, ok: bool) {
        if self.engine.pid == Some(pid) && !self.jobs.shutdown.load(Ordering::SeqCst) {
            self.network_recovery.checked(id, ok);
            self.publish_runtime_status();
        }
    }

    fn recover_network(&mut self, context: &Value) -> Result<()> {
        let retry_state = self.network_recovery.clone();
        let settings = self.engine.store.settings()?;
        self.transaction(|core| core.apply_config_in_context(&settings, context))?;
        if let Err(error) = self.engine.close_departed_path_connections() {
            self.network_recovery = retry_state;
            return Err(error);
        }
        Ok(())
    }
    /// Due automatic updates as (id, url) plus the proxy port to download
    /// through. The caller downloads without holding the core lock, so UI
    /// requests are not blocked by a slow subscription server.
    pub fn due_subscription_downloads(&mut self) -> Option<DueDownloads> {
        if self.environment.sleeping
            || self.jobs.shutdown.load(Ordering::SeqCst)
            || self.engine.isolated
            || self.assert_company_owner().is_err()
            || self.last_tick.elapsed() < Duration::from_secs(60)
        {
            return None;
        }
        self.last_tick = Instant::now();
        if self.jobs.risk_active.load(Ordering::SeqCst)
            || self.jobs.speed_active.load(Ordering::SeqCst)
            || self.jobs.udp_active.load(Ordering::SeqCst)
        {
            return None;
        }
        let r = self.engine.store.subscription().ok()?;
        let ids = subscription::due_ids(&r);
        let due = r["entries"]
            .as_array()?
            .iter()
            .filter(|e| ids.iter().any(|id| e["id"] == *id))
            .filter_map(|e| Some((e["id"].as_str()?.to_owned(), e["url"].as_str()?.to_owned())))
            .collect::<Vec<_>>();
        (!due.is_empty()).then(|| (due, self.engine.pid.map(|_| self.engine.mixed)))
    }
    /// Commit only still-due downloads with the same URL and no newer request.
    pub fn apply_downloaded_subscriptions(
        &mut self,
        mut downloaded: Vec<(String, String, Result<subscription::Downloaded>)>,
    ) {
        if self.environment.sleeping
            || self.jobs.shutdown.load(Ordering::SeqCst)
            || self.network_recovery.needs_fast_check()
        {
            return;
        }
        // An entry no longer due was updated during the download (e.g. manually);
        // its committed nodes are newer than this result.
        let record = match self.engine.store.subscription() {
            Ok(r) => r,
            Err(_) => return,
        };
        let due = subscription::due_ids(&record);
        let Ok(pending) = self.jobs.pending_downloads.lock() else {
            return;
        };
        downloaded.retain(|(id, url, _)| {
            due.contains(id)
                && record["entries"].as_array().unwrap().iter().any(|e| {
                    e["id"] == *id
                        && e["url"] == *url
                        && e["downloadToken"]
                            .as_str()
                            .is_none_or(|t| !pending.contains(t))
                })
        });
        drop(pending);
        if downloaded.is_empty() {
            return;
        }
        let ids = downloaded.iter().map(|(id, _, _)| id.clone()).collect();
        let result = self.update_subscriptions_with(Some(ids), |id, url, _| {
            match downloaded.iter().position(|(i, u, _)| i == id && u == url) {
                Some(index) => downloaded.swap_remove(index).2,
                None => bail!("订阅下载结果缺失，旧节点已保留。"),
            }
        });
        if let Err(e) = result {
            self.log("warn", &format!("自动订阅更新未完成：{e}"));
        }
    }
}
#[derive(Default)]
struct HashSetNames(std::collections::HashSet<String>);
impl HashSetNames {
    fn add(&mut self, s: &str) -> bool {
        self.0.insert(s.into())
    }
}
/// Rejects keys a settings channel does not own, so one channel cannot rewrite
/// fields guarded by another (for example the selected node).
fn allowed_keys(p: &Value, keys: &[&str]) -> Result<()> {
    let object = p.as_object().context("设置参数需要是对象。")?;
    if let Some(key) = object.keys().find(|k| !keys.contains(&k.as_str())) {
        bail!("此操作不能修改设置项 {key}。");
    }
    Ok(())
}
/// Targets of a manual subscription update, prepared under the core lock.
pub struct ManualUpdate {
    targets: Vec<(String, String, String)>,
    mixed: Option<u16>,
    jobs: Arc<Jobs>,
}
impl Drop for ManualUpdate {
    fn drop(&mut self) {
        if let Ok(mut pending) = self.jobs.pending_downloads.lock() {
            for (_, _, token) in &self.targets {
                pending.remove(token);
            }
        }
    }
}
impl ManualUpdate {
    pub fn download(&self) -> Vec<(String, String, Result<subscription::Downloaded>)> {
        self.targets
            .iter()
            .map(|(id, url, _)| {
                (
                    id.clone(),
                    url.clone(),
                    subscription::download(url, self.mixed),
                )
            })
            .collect()
    }
}
fn proxied(port: u16, timeout: u64) -> Result<Client> {
    Ok(Client::builder()
        .no_proxy()
        .pool_max_idle_per_host(0)
        .timeout(Duration::from_secs(timeout))
        .proxy(reqwest::Proxy::all(format!("http://127.0.0.1:{port}"))?)
        .build()?)
}
/// Connectivity and website checks, run without the core lock.
pub struct NetworkCheck {
    isolated: bool,
    tun: bool,
    running: bool,
    mixed: u16,
    selected: Value,
}
impl NetworkCheck {
    fn proxied(&self, timeout: u64) -> Result<Client> {
        ensure!(self.running, "请先连接 VPN。");
        proxied(self.mixed, timeout)
    }
    /// One bounded proxy request, without switching nodes or probing private resources.
    pub fn recovery_connectivity(&self) -> bool {
        if self.isolated {
            return false;
        }
        let result = (|| -> Result<bool> {
            ensure!(self.running, "内核未运行。");
            let client = Client::builder()
                .no_proxy()
                .pool_max_idle_per_host(0)
                .timeout(Duration::from_secs(8))
                .redirect(reqwest::redirect::Policy::none())
                .proxy(reqwest::Proxy::all(format!(
                    "http://127.0.0.1:{}",
                    self.mixed
                ))?)
                .build()?;
            Ok(client
                .get("https://www.gstatic.com/generate_204")
                .send()?
                .status()
                == 204)
        })();
        result.unwrap_or(false)
    }
    pub fn connectivity(&self) -> Result<Value> {
        let test_url = if self.isolated {
            Some(network::fixture_url("SPLITVPN_TEST_CONNECTIVITY_URL")?)
        } else {
            None
        };
        let chatgpt_url = if self.isolated {
            network::fixture_url("SPLITVPN_TEST_CHATGPT_URL")?
        } else {
            "https://chatgpt.com/cdn-cgi/trace".into()
        };
        let (domestic, foreign, dns, chatgpt) = std::thread::scope(|scope| {
            let domestic = scope.spawn(|| {
                self.measure(
                    test_url.as_deref().unwrap_or("https://www.baidu.com"),
                    false,
                )
            });
            let foreign = scope.spawn(|| {
                self.measure(
                    test_url
                        .as_deref()
                        .unwrap_or("https://www.google.com/generate_204"),
                    true,
                )
            });
            let dns = scope.spawn(|| network::system_dns(self.isolated, self.tun));
            let web = scope.spawn(|| system_website(&chatgpt_url));
            (
                domestic.join().unwrap(),
                foreign.join().unwrap(),
                dns.join().unwrap(),
                web.join().unwrap(),
            )
        });
        let ip = if self.isolated {
            Value::Null
        } else {
            self.proxied(8)
                .ok()
                .and_then(|c| {
                    c.get("https://api.ipify.org?format=json")
                        .send()
                        .ok()?
                        .json::<Value>()
                        .ok()
                })
                .map(|v| v["ip"].clone())
                .unwrap_or(Value::Null)
        };
        Ok(
            json!({"connectivity":network::complete_connectivity(&domestic,&foreign,&dns,&chatgpt,ip),"nodeRisk":null,"nodeRiskError":null}),
        )
    }
    fn measure(&self, url: &str, proxy: bool) -> Value {
        let start = Instant::now();
        let client = if proxy {
            self.proxied(8)
        } else {
            Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(8))
                .build()
                .map_err(Into::into)
        };
        let result = client.and_then(|c| Ok(c.get(url).send()?.error_for_status()?));
        json!({"url":url,"ok":result.is_ok(),"delay":if result.is_ok(){json!(start.elapsed().as_millis())}else{Value::Null},"error":result.err().map(|e|redact(&e.to_string()))})
    }
    pub fn websites(&self) -> Result<Value> {
        ensure!(self.running, "请先连接 VPN。");
        let mut results = Vec::new();
        for (id, label, url) in [
            ("google", "Google", "https://www.google.com/generate_204"),
            ("chatgpt", "ChatGPT", "https://chatgpt.com/cdn-cgi/trace"),
            ("claude", "Claude", "https://claude.ai"),
        ] {
            let mut v = self.measure(url, true);
            v["id"] = json!(id);
            v["label"] = json!(label);
            results.push(v);
        }
        Ok(json!({"proxyName":self.selected,"results":results}))
    }
}
fn system_website(url: &str) -> Value {
    let start = Instant::now();
    let result = Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(8))
        .build()
        .and_then(|client| client.get(url).send());
    match result {
        Ok(response) => {
            let status = response.status().as_u16();
            json!({"ok":status == 200,"httpStatus":status,"elapsedMs":start.elapsed().as_millis(),
                "error":if status == 200 {None}else{Some(format!("ChatGPT 返回 HTTP {status}。"))}})
        }
        Err(error) => {
            json!({"ok":false,"httpStatus":null,"elapsedMs":null,"error":redact(&error.to_string())})
        }
    }
}
/// Preflight stays in RPC order; only network IO moves to another thread.
pub enum NetworkRequest {
    Subscription(ManualUpdate),
    Connectivity(NetworkCheck),
    Websites(NetworkCheck),
}
impl NetworkRequest {
    pub fn run(self, core: &Mutex<Core>) -> Result<Value> {
        match self {
            Self::Subscription(plan) => {
                let downloaded = plan.download();
                core.lock()
                    .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?
                    .finish_manual_update(plan, downloaded)
            }
            Self::Connectivity(check) => check.connectivity(),
            Self::Websites(check) => check.websites(),
        }
    }
}
pub fn prepare_network_request(
    core: &Mutex<Core>,
    channel: &str,
    payload: &Value,
) -> Option<Result<NetworkRequest>> {
    let lock = || core.lock().map_err(|_| anyhow::anyhow!("后台状态不可用。"));
    Some(match channel {
        "subscription:update" => lock()
            .and_then(|mut c| c.begin_manual_update(payload))
            .map(NetworkRequest::Subscription),
        "connectivity:check" => lock()
            .and_then(|mut c| c.network_check())
            .map(NetworkRequest::Connectivity),
        "connectivity:test-website-speeds" => lock()
            .and_then(|mut c| c.network_check())
            .map(NetworkRequest::Websites),
        _ => return None,
    })
}
pub fn handle_unlocked(
    core: &Mutex<Core>,
    channel: &str,
    payload: &Value,
) -> Option<Result<Value>> {
    prepare_network_request(core, channel, payload).map(|request| request.and_then(|r| r.run(core)))
}
pub fn string<'a>(p: &'a Value, k: &str) -> Result<&'a str> {
    p[k].as_str()
        .filter(|s| !s.trim().is_empty())
        .with_context(|| format!("参数 {k} 无效。"))
}
pub fn risk_result(name: &str, v: &Value) -> Value {
    let t = &v["threat"];
    let scores = v
        .get("scores")
        .or_else(|| t.get("scores"))
        .unwrap_or(&Value::Null);
    let mut high = false;
    let mut medium = false;
    let mut reasons = Vec::new();
    let mut threat = json!({});
    for (key, field, reason) in [
        ("is_known_attacker", "isKnownAttacker", "known attacker"),
        ("is_known_abuser", "isKnownAbuser", "known abuser"),
        ("is_threat", "isThreat", "threat"),
        ("is_tor", "isTor", "Tor exit"),
        ("is_bogon", "isBogon", "bogon IP"),
    ] {
        if t[key].is_boolean() {
            threat[field] = t[key].clone();
        }
        if t[key] == true {
            high = true;
            reasons.push(reason.to_owned());
        }
    }
    for (key, field, reason) in [
        ("is_proxy", "isProxy", "proxy"),
        ("is_anonymous", "isAnonymous", "anonymous IP"),
        ("is_datacenter", "isDatacenter", "datacenter IP"),
    ] {
        if t[key].is_boolean() {
            threat[field] = t[key].clone();
        }
        if !high && t[key] == true {
            medium = true;
            reasons.push(reason.to_owned());
        }
    }
    let mut normalized_scores = json!({});
    for (key, field) in [
        ("trust_score", "trustScore"),
        ("vpn_score", "vpnScore"),
        ("proxy_score", "proxyScore"),
        ("threat_score", "threatScore"),
    ] {
        if scores[key].is_number() {
            normalized_scores[field] = scores[key].clone();
        }
    }
    if let Some(score) = scores["trust_score"].as_f64() {
        if score < 40.0 {
            high = true;
            reasons.push(format!("trust_score {}", scores["trust_score"]));
        } else if score <= 60.0 && !high {
            medium = true;
            reasons.push(format!("trust_score {}", scores["trust_score"]));
        } else if !high && !medium {
            reasons.push(format!("trust_score {}", scores["trust_score"]));
        }
    }
    for key in ["threat_score", "proxy_score", "vpn_score"] {
        if scores[key].as_f64().is_some_and(|s| s >= 80.0) {
            reasons.push(format!("{key} {}", scores[key]));
        }
    }
    let known = !threat.as_object().unwrap().is_empty()
        || !normalized_scores.as_object().unwrap().is_empty();
    if !known {
        reasons.push("ipdata threat 字段缺失，无法判断风险。".into());
    } else if reasons.is_empty() {
        reasons.push("未命中风险字段".into());
    }
    json!({"nodeName":name,"ip":v["ip"],"riskLevel":if !known{"unknown"}else if high{"high"}else if medium{"medium"}else{"low"},"reasons":reasons,"checkedAt":now(),"error":null,"threat":threat,"scores":normalized_scores})
}

fn udp_stun(port: u16) -> Result<()> {
    let mut tcp = TcpStream::connect_timeout(
        &format!("127.0.0.1:{port}").parse()?,
        Duration::from_secs(5),
    )?;
    tcp.set_read_timeout(Some(Duration::from_secs(5)))?;
    tcp.write_all(&[5, 1, 0])?;
    let mut greeting = [0; 2];
    tcp.read_exact(&mut greeting)?;
    ensure!(greeting == [5, 0], "SOCKS UDP 探测认证失败。");
    tcp.write_all(&[5, 3, 0, 1, 0, 0, 0, 0, 0, 0])?;
    let mut head = [0; 4];
    tcp.read_exact(&mut head)?;
    ensure!(head[0] == 5 && head[1] == 0, "节点不支持 UDP relay。");
    let host = match head[3] {
        1 => {
            let mut ip = [0; 4];
            tcp.read_exact(&mut ip)?;
            std::net::Ipv4Addr::from(ip).to_string()
        }
        3 => {
            let mut len = [0];
            tcp.read_exact(&mut len)?;
            let mut host = vec![0; len[0] as usize];
            tcp.read_exact(&mut host)?;
            String::from_utf8(host)?
        }
        4 => {
            let mut ip = [0; 16];
            tcp.read_exact(&mut ip)?;
            std::net::Ipv6Addr::from(ip).to_string()
        }
        _ => bail!("SOCKS 地址类型无效。"),
    };
    let mut p = [0; 2];
    tcp.read_exact(&mut p)?;
    let host = if host == "0.0.0.0" {
        "127.0.0.1".into()
    } else {
        host
    };
    let udp = UdpSocket::bind("0.0.0.0:0")?;
    udp.set_read_timeout(Some(Duration::from_secs(5)))?;
    let mut packet = vec![0, 0, 0, 3, 19];
    packet.extend_from_slice(b"stun.l.google.com"); // Correct length is set below rather than trusting a constant.
    packet[4] = b"stun.l.google.com".len() as u8;
    packet.extend_from_slice(&19302u16.to_be_bytes());
    let txn = uuid::Uuid::new_v4();
    packet.extend_from_slice(&[0, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42]);
    packet.extend_from_slice(&txn.as_bytes()[..12]);
    udp.send_to(&packet, (host.as_str(), u16::from_be_bytes(p)))?;
    let mut response = [0; 2048];
    let (len, _) = udp.recv_from(&mut response)?;
    ensure!(len >= 30, "UDP relay 返回无效响应。");
    let offset = match response[3] {
        1 => 10,
        3 => 7 + response[4] as usize,
        4 => 22,
        _ => bail!("UDP relay 地址无效。"),
    };
    ensure!(
        len >= offset + 20
            && response[offset..offset + 2] == [1, 1]
            && response[offset + 4..offset + 8] == [0x21, 0x12, 0xa4, 0x42]
            && response[offset + 8..offset + 20] == txn.as_bytes()[..12],
        "没有收到本次 STUN 探测的有效响应。"
    );
    Ok(())
}

pub fn start_batch(core: Arc<Mutex<Core>>, kind: String, payload: Value) -> Result<Value> {
    let (names, jobs, events) = {
        let c = core
            .lock()
            .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
        let names = payload["nodeNames"]
            .as_array()
            .context("请先选择节点。")
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect::<Vec<_>>()
            })?;
        ensure!(
            !names.is_empty() && names.len() <= 5000,
            "请选择 1～5000 个节点。"
        );
        (names, c.jobs.clone(), c.events.clone())
    };
    let active = match kind.as_str() {
        "risk" => &jobs.risk_active,
        "udp" => &jobs.udp_active,
        _ => &jobs.speed_active,
    };
    ensure!(!active.swap(true, Ordering::SeqCst), "此类检测正在进行。");
    match kind.as_str() {
        "risk" => &jobs.risk,
        "udp" => &jobs.udp,
        _ => &jobs.speed,
    }
    .store(false, Ordering::SeqCst);
    let id = uuid::Uuid::new_v4().to_string();
    let reply = json!({"id":id,"total":names.len(),"intervalMs":1200});
    std::thread::spawn(move || {
        let total = names.len();
        let mut checked = 0;
        let mut last_error = None;
        for name in names {
            if jobs.cancelled(&kind) {
                break;
            }
            let result = if let Ok(mut c) = core.lock() {
                match kind.as_str() {
                    "risk" => c.risk(&name),
                    "udp" => c.udp(&name),
                    _ => c.speed(&name, false),
                }
            } else {
                Err(anyhow::anyhow!("后台状态不可用。"))
            };
            checked += 1;
            // `error` belongs to this node; `last_error` summarises the batch.
            let (result, error) = match result {
                Ok(r) => (Some(r), None),
                Err(e) => (None, Some(redact(&e.to_string()))),
            };
            if error.is_some() {
                last_error = error.clone();
            }
            events(
                &format!("nodes:{kind}-progress"),
                json!({"id":id,"checked":checked,"total":total,"nodeName":name,"result":result,"finished":false,"cancelled":false,"error":error}),
            );
            if error.is_some() && kind == "risk" {
                break;
            }
            for _ in 0..12 {
                if jobs.cancelled(&kind) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        }
        match kind.as_str() {
            "risk" => &jobs.risk_active,
            "udp" => &jobs.udp_active,
            _ => &jobs.speed_active,
        }
        .store(false, Ordering::SeqCst);
        events(
            &format!("nodes:{kind}-progress"),
            json!({"id":id,"checked":checked,"total":total,"finished":true,"cancelled":jobs.cancelled(&kind),"error":last_error,"stoppedReason":last_error}),
        );
    });
    Ok(reply)
}
