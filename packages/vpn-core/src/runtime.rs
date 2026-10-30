mod chain_automatic;
mod chain_failover;
mod chain_history;
mod chain_lifecycle;
mod chain_presentation;
mod chain_probe;
mod chain_routine;
mod chain_use;
mod exit_risk;
mod read_views;
use crate::{
    background::RuntimeEnvironment,
    company::Company,
    config,
    connection_health::ConnectionHealth,
    diagnostics::{CheckKind, Diagnostics},
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
    fn same_path_egress_repair_does_not_close_direct_or_company_sockets() {
        let (_root, mut core, controller) = recovery_fixture();
        core.network_recovery.applied(Some("fixture-path".into()));
        core.network_recovery.changed_for(None, "egress-health");
        core.recover_network(&json!({"interfaceName":"en0","signature":"fixture-path"}))
            .unwrap();
        assert!(controller.deletes.lock().unwrap().is_empty());
        assert!(controller.writes.load(Ordering::SeqCst) > 0);
    }

    #[test]
    fn stale_sampler_cannot_change_health_or_traffic_after_stop_intent() {
        let (_root, mut core, _controller) = recovery_fixture();
        core.network_recovery.applied(Some("fixture-path".into()));
        let sample = core.take_background_sample().unwrap();
        core.jobs.stop_requested.store(true, Ordering::SeqCst);
        core.jobs.invalidate_diagnostics();
        core.complete_background_sample(
            &sample,
            SampleResult {
                proxies: Ok(json!({"proxies":{}})),
                connections: Ok(json!({"uploadTotal":999,"connections":[]})),
                controller: Some(false),
                path: crate::path_health::PathOutcome::EgressFailure,
                retry_outcome: None,
            },
        );
        assert!(core.traffic()["snapshot"].is_null());
        assert_eq!(core.health_failures, 0);
        assert_eq!(core.path_health.status()["state"], "unknown");
    }

    #[test]
    fn failed_stop_still_cancels_personal_reconnect_intent() {
        let (_root, mut core, _controller) = recovery_fixture();
        core.network_recovery.changed_for(None, "health-check");
        // A fixture PID without a child cannot be killed: no real process is touched.
        assert!(core.handle("vpn:stop", &json!({})).is_err());
        assert!(!core.wants_running);
        assert_eq!(core.network_recovery.status()["state"], "idle");
        core.handle("native:network-changed", &json!({"available":true}))
            .unwrap();
        assert_eq!(core.network_recovery.status()["state"], "idle");
    }

    #[test]
    fn diagnostic_schedule_rejects_duplicates_and_results_after_stop() {
        let (_root, mut core, _controller) = recovery_fixture();
        core.network_recovery.applied(Some("fixture-path".into()));
        let plan = core
            .begin_diagnostic(CheckKind::Connectivity, true)
            .unwrap();
        assert!(
            core.begin_diagnostic(CheckKind::Connectivity, true)
                .is_err()
        );
        core.complete_diagnostic(&plan, Ok(json!({"connectivity":{"foreignOk":true}})))
            .unwrap();
        assert_eq!(
            core.diagnostics.status()["connectivity"]["source"],
            "manual"
        );
        assert!(core.diagnostics.status()["connectivity"]["checkedAt"].is_string());
        let pending = core.begin_diagnostic(CheckKind::Websites, true).unwrap();
        let _ = core.handle("vpn:stop", &json!({}));
        assert!(
            core.complete_diagnostic(&pending, Ok(json!({"old":true})))
                .is_err()
        );
        assert_eq!(core.diagnostics.status()["connectivity"]["state"], "stale");
        assert_eq!(core.diagnostics.status()["pausedReason"], "disconnected");
    }

    #[test]
    fn automatic_checks_start_on_readiness_and_recheck_after_same_process_network_change() {
        let (_root, mut core, _controller) = recovery_fixture();
        core.network_recovery.applied(Some("fixture-path".into()));
        core.sync_diagnostics();
        assert_eq!(
            core.diagnostics.due(Instant::now()),
            Some(CheckKind::Connectivity)
        );
        let connection = core
            .begin_diagnostic(CheckKind::Connectivity, false)
            .unwrap();
        assert_eq!(
            core.diagnostics.due(Instant::now()),
            Some(CheckKind::Websites)
        );
        let sites = core.begin_diagnostic(CheckKind::Websites, false).unwrap();
        core.complete_diagnostic(&connection, Ok(json!({"connectivity":{"foreignOk":true}})))
            .unwrap();
        assert_eq!(
            core.diagnostics.status()["connectivity"]["source"],
            "automatic"
        );

        core.handle("native:network-changed", &json!({"available":true}))
            .unwrap();
        assert_eq!(core.diagnostics.status()["pausedReason"], "recovering");
        assert!(!core.diagnostic_current(&sites.token));
        assert!(
            core.complete_diagnostic(&sites, Ok(json!({"old":true})))
                .is_err()
        );
        core.network_recovery.applied(Some("fixture-path".into()));
        core.sync_diagnostics();
        assert_eq!(
            core.diagnostics.due(Instant::now()),
            Some(CheckKind::Connectivity)
        );
        assert_eq!(
            core.diagnostics.status()["connectivity"]["staleResult"],
            true
        );
    }

    #[test]
    fn exhausted_repair_budget_does_not_disable_informational_periodic_checks() {
        let (_root, mut core, _controller) = recovery_fixture();
        core.network_recovery.applied(Some("fixture-path".into()));
        for _ in 0..3 {
            core.network_recovery
                .failed("fixture".into(), Instant::now());
        }
        core.sync_diagnostics();
        assert!(core.diagnostics.status()["pausedReason"].is_null());
        assert_eq!(core.network_recovery.status()["state"], "failed");
    }

    #[test]
    fn hidden_sampling_is_slow_but_recovery_verification_is_not_delayed() {
        let (_root, mut core, _controller) = recovery_fixture();
        core.environment.visible = Some(false);
        core.last_health_tick = Some(Instant::now());
        core.last_sample_tick = Some(Instant::now());
        core.network_recovery.applied(Some("fixture-path".into()));
        assert!(core.take_background_sample().is_none());
        core.network_recovery.changed_for(None, "egress-health");
        core.network_recovery.applied(Some("fixture-path".into()));
        assert!(core.take_background_sample().is_some());
    }

    #[test]
    fn probe_lease_prevents_concurrent_selector_changes_without_core_lock() {
        let (_root, core, controller) = recovery_fixture();
        let _lease = core.jobs.probe_gate.lock().unwrap();
        let plan = NodeDiagnostic {
            io: core.engine.io(),
            node: json!({"runtimeUdpSupported":true}),
            name: "DIRECT".into(),
            kind: "risk".into(),
            recommended: false,
            probe: controller.port,
            select_probe: true,
            via_static_exit: false,
            current_exit_key: None,
            risk_key: String::new(),
            endpoint: None,
            token: core.diagnostic_token(),
            jobs: core.jobs.clone(),
        };
        assert!(
            plan.measure()
                .unwrap_err()
                .to_string()
                .contains("检测入口正在使用")
        );
        assert_eq!(controller.writes.load(Ordering::SeqCst), 0);
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
    /// Set by the input reader, before the stop can acquire the writer lock.
    pub stop_requested: Arc<AtomicBool>,
    pub intent_epoch: AtomicU64,
    read_views: Mutex<std::collections::HashMap<String, read_views::CachedReadView>>,
    probe_gate: Arc<Mutex<()>>,
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
    pub chain_active: AtomicBool,
    pub chain_cancel: AtomicBool,
    pub chain_sampling: AtomicBool,
    pub chain_connect_active: AtomicBool,
    pub chain_connect_cancel: AtomicBool,
    pub chain_use_state: Mutex<Value>,
    pub chain_use_cancelled: Mutex<std::collections::VecDeque<String>>,
    pub chain_priority: Mutex<std::collections::VecDeque<String>>,
}
impl Jobs {
    pub fn invalidate_diagnostics(&self) {
        self.intent_epoch.fetch_add(1, Ordering::SeqCst);
        self.cancel_diagnostics();
        self.wake_background();
    }
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
            "chain" => &self.chain_cancel,
            "risk" => &self.risk,
            "udp" => &self.udp,
            _ => &self.speed,
        }
        .store(true, Ordering::SeqCst);
    }
    pub fn cancel_diagnostics(&self) {
        for flag in [
            &self.speed,
            &self.risk,
            &self.udp,
            &self.chain_connect_cancel,
        ] {
            flag.store(true, Ordering::SeqCst);
        }
    }
    pub fn cancel_all(&self) {
        self.cancel_diagnostics();
        self.chain_cancel.store(true, Ordering::SeqCst);
    }
    fn requeue_chain_priority(&self, key: &str) {
        if let Ok(mut queue) = self.chain_priority.lock() {
            if !queue.iter().any(|id| id == key) {
                queue.push_front(key.to_owned());
            }
        }
    }
    pub fn cancelled(&self, kind: &str) -> bool {
        self.shutdown.load(Ordering::SeqCst)
            || match kind {
                "chain" => &self.chain_cancel,
                "risk" => &self.risk,
                "udp" => &self.udp,
                _ => &self.speed,
            }
            .load(Ordering::SeqCst)
    }
}
/// A controller handle has no authority to start/stop a process or change core state.
#[derive(Clone)]
struct ControllerIo {
    store: Storage,
    isolated: bool,
    controller: u16,
    client: Client,
    secret: Arc<Mutex<String>>,
}
impl ControllerIo {
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
            let mut request =
                self.client
                    .request(method.parse()?, &url)
                    .timeout(Duration::from_secs(if path.contains("/delay?") {
                        9
                    } else if method == "GET" {
                        2
                    } else if method == "DELETE" {
                        1
                    } else {
                        6
                    }));
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
}
pub struct Engine {
    stop_requested: Arc<AtomicBool>,
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
    secret: Arc<Mutex<String>>,
    pub last_error: Option<String>,
    pub started: Option<String>,
    reload_attempts: AtomicU64,
}
impl Engine {
    pub fn new(store: Storage, resources: PathBuf, isolated: bool) -> Result<Self> {
        let mut e = Self {
            stop_requested: Arc::new(AtomicBool::new(false)),
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
            secret: Arc::new(Mutex::new(String::new())),
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
    fn io(&self) -> ControllerIo {
        ControllerIo {
            store: self.store.clone(),
            isolated: self.isolated,
            controller: self.controller,
            client: self.client.clone(),
            secret: self.secret.clone(),
        }
    }
    fn authorized(
        &self,
        method: &str,
        path: &str,
        payload: Option<&Value>,
    ) -> Result<reqwest::blocking::Response> {
        self.io().authorized(method, path, payload)
    }
    pub fn api(&self, method: &str, path: &str, payload: Option<&Value>) -> Result<Value> {
        self.io().api(method, path, payload)
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
    fn close_departed_path_connections(&self, stop: &AtomicBool, proxy_only: bool) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(3);
        let connections = self.api("GET", "/connections", None)?;
        for connection in connections["connections"].as_array().into_iter().flatten() {
            ensure!(!stop.load(Ordering::SeqCst), "连接清理已被断开请求取消。");
            ensure!(
                Instant::now() < deadline,
                "旧连接清理达到时间上限，等待下一次恢复。"
            );
            let chains = connection["chains"].as_array();
            if chains.is_some_and(|items| {
                items.iter().any(|name| {
                    name.as_str()
                        .is_some_and(|name| name.starts_with("COMPANY-"))
                })
            }) {
                continue;
            }
            if !chains.is_some_and(|items| {
                items.iter().any(|name| {
                    name == "VPN"
                        || name == crate::static_exit::EXIT
                        || (!proxy_only && name == "DIRECT")
                })
            }) {
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
    /// mihomo answers the controller before file providers finish loading;
    /// slow TUN setup on Windows widens that gap, so wait for the member.
    fn wait_for_vpn_member(&self, name: &str, timeout: Duration) {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline && !self.stop_requested.load(Ordering::SeqCst) {
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
    exit_credential: Value,
    exit_probe: u16,
    exit_scan_probe: u16,
    chain_scan: Value,
    chain_auto_attempt: Option<Instant>,
    chain_failover_attempt: Option<Instant>,
    pub chain_auto_error: bool,
    chain_auto_paused_in_memory: bool,
    chain_network_changed_at: Option<Instant>,
    chain_probe: Option<Arc<Mutex<chain_probe::ChainProbe>>>,
    chain_token: Option<DiagnosticToken>,
    chain_manifest: Value,
    chain_settings: Value,
    chain_cache_key: Value,
    chain_cache_checked: bool,
    chain_network: Mutex<chain_lifecycle::NetworkCache>,
    samples: Vec<Value>,
    live_proxies: Option<Value>,
    traffic_snapshot: Value,
    last_totals: Option<(u64, u64, Instant)>,
    last_tick: Instant,
    network_recovery: NetworkRecovery,
    last_network_tick: Option<Instant>,
    last_health_tick: Option<Instant>,
    last_sample_tick: Option<Instant>,
    health_pid: Option<u32>,
    health_failures: u32,
    path_health: crate::path_health::PathHealth,
    diagnostics: Diagnostics,
    diagnostics_context: Option<DiagnosticToken>,
    last_diagnostics_state: String,
    view_revision: u64,
    last_nodes_state: Value,
    last_exit_risk_state: Value,
    current_exit_risk: Option<(DiagnosticToken, Value)>,
    connection_health: ConnectionHealth,
    wechat_route: Option<&'static str>,
    pending_wechat: Option<String>,
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
        engine.stop_requested = jobs.stop_requested.clone();
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
            exit_credential: Value::Null,
            exit_probe: 0,
            exit_scan_probe: 0,
            chain_scan: crate::chain_scan::idle(),
            chain_auto_attempt: None,
            chain_failover_attempt: None,
            chain_auto_error: false,
            chain_auto_paused_in_memory: false,
            chain_network_changed_at: None,
            chain_probe: None,
            chain_token: None,
            chain_manifest: Value::Null,
            chain_settings: Value::Null,
            chain_cache_key: Value::Null,
            chain_cache_checked: false,
            chain_network: Mutex::new(chain_lifecycle::NetworkCache::default()),
            samples: Vec::new(),
            live_proxies: None,
            traffic_snapshot: Value::Null,
            last_totals: None,
            last_tick: Instant::now(),
            network_recovery: NetworkRecovery::default(),
            last_network_tick: None,
            last_health_tick: None,
            last_sample_tick: None,
            health_pid: None,
            health_failures: 0,
            path_health: crate::path_health::PathHealth::default(),
            diagnostics: Diagnostics::default(),
            diagnostics_context: None,
            last_diagnostics_state: String::new(),
            view_revision: 0,
            last_nodes_state: Value::Null,
            last_exit_risk_state: Value::Null,
            current_exit_risk: None,
            connection_health: ConnectionHealth::default(),
            wechat_route: None,
            pending_wechat: None,
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
        c.load_chain_cache();
        chain_history::migrate(&c.engine.store, &c.chain_scan, &c.chain_cache_key)?;
        Ok(c)
    }
    pub fn shutdown(&mut self) {
        if self.chain_scan["running"] == true {
            self.chain_scan["running"] = json!(false);
            self.chain_scan["testing"] = json!(false);
            self.chain_scan["cancelled"] = json!(true);
            self.chain_scan["waitingReason"] = Value::Null;
            self.chain_scan["stopReason"] = json!("shutdown");
            self.chain_scan["finishedAt"] = json!(now());
            let _ = self.save_chain_cache();
        }
        if let Some(probe) = self.chain_probe.take() {
            if let Ok(mut probe) = probe.lock() {
                probe.stop();
            }
        }
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
        status["connectionHealth"] = self.path_health.status();
        status
    }
    fn publish_runtime_status(&mut self) {
        let mut state = self.runtime_status();
        let serialized = state.to_string();
        if serialized != self.last_core_state {
            self.last_core_state = serialized;
            self.publish_read_views();
            state["viewRevision"] = json!(self.view_revision);
            (self.events)("vpn:status", state);
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
        if let Some(was_running) = j["chainUseWasRunning"].as_bool() {
            let expected_pid = if was_running {
                &j["chainUseOriginalPid"]
            } else {
                &j["chainUseStartedPid"]
            };
            if self.engine.pid.is_some()
                && (self.engine.protected()
                    || expected_pid.as_u64() != self.engine.pid.map(u64::from))
            {
                self.engine
                    .store
                    .set_recovery(true, Some("chain-use-interrupted"))?;
                self.engine.last_error = Some("上次线路连接已中断，请检查实际状态。".into());
                self.network_recovery.failed(
                    "上次线路连接已中断，请检查实际状态。".into(),
                    Instant::now(),
                );
                self.log(
                    "warn",
                    "上次线路连接已中断，运行身份尚未确认，恢复记录已保留。",
                );
                return Ok(());
            }
            if !was_running && self.engine.pid.is_some() {
                self.stop_runtime()?;
            }
        }
        self.restore_transaction(&j)?;
        if self.engine.pid.is_some() {
            let base = fs::read_to_string(self.engine.store.path("mihomo/config.yaml"))?;
            self.company.reload_base(&mut self.engine, &base)?;
            if j["chainUseWasRunning"] == true {
                self.engine.restore_selections_checked(&j["selections"])?;
            }
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
        if settings["staticExit"]["enabled"] == true {
            return Ok(false);
        }
        Ok(settings["selectedProxy"] == "DIRECT"
            || self.nodes()?.iter().any(|n| {
                n["name"] == settings["selectedProxy"]
                    && n["runtimeUdpSupported"] == true
                    && !n["identityAmbiguous"].as_bool().unwrap_or(false)
            }))
    }
    fn apply_static_exit(&mut self, config: &mut Value, settings: &Value) -> Result<()> {
        if settings["staticExit"]["enabled"] != true {
            return Ok(());
        }
        ensure!(
            !subscription::provider_nodes(&self.engine.store)?
                .iter()
                .any(|n| [
                    crate::static_exit::EXIT,
                    crate::static_exit::SCAN_EXIT,
                    crate::static_exit::SCAN_FRONT
                ]
                .iter()
                .any(|name| n["name"] == *name)),
            "订阅节点名称与静态出口保留名称冲突。"
        );
        if self.exit_probe == 0 {
            self.exit_probe = available_port(0)?;
        }
        crate::static_exit::apply(config, settings, &self.exit_credential, self.exit_probe)?;
        if self.exit_scan_probe == 0 {
            self.exit_scan_probe = available_port(0)?;
        }
        crate::static_exit::add_scan(config, self.exit_scan_probe)
    }
    fn chain_scan_port(&self) -> Result<u16> {
        if self.engine.isolated && std::env::var_os("SPLITVPN_TEST_CHAIN_PROXY_URL").is_some() {
            return url::Url::parse(&network::fixture_url("SPLITVPN_TEST_CHAIN_PROXY_URL")?)?
                .port()
                .context("隔离代理端口无效。");
        }
        let loaded = config::parse(&fs::read_to_string(
            self.engine.store.path("mihomo/config.yaml"),
        )?)?;
        loaded["listeners"]
            .as_array()
            .and_then(|a| {
                a.iter()
                    .find(|l| l["name"] == crate::static_exit::SCAN_LISTENER)
            })
            .and_then(|l| l["port"].as_u64())
            .and_then(|p| u16::try_from(p).ok())
            .context("请重新连接 VPN，以启用链路扫描入口。")
    }
    fn chain_context(&self) -> Result<Value> {
        let settings = self.engine.store.settings()?;
        let mut value = json!({});
        for key in [
            "staticExit",
            "lanDirect",
            "tailscaleDirect",
            "ipv6",
            "geoFallback",
            "unknownTraffic",
            "vpnDomainRules",
            "directDomainRules",
            "specialCompatibilityRules",
        ] {
            value[key] = settings[key].clone();
        }
        // Business on/off does not change the path measured by the scanner.
        value["staticExit"]["enabled"] = json!(false);
        Ok(value)
    }
    fn chain_environment_valid(&self) -> bool {
        !self.jobs.shutdown.load(Ordering::SeqCst)
            && self
                .chain_cache_identity()
                .is_ok_and(|key| key == self.chain_cache_key)
    }

    fn chain_cache_identity(&self) -> Result<Value> {
        let digest = |v: &Value| crate::storage::sha256(&serde_json::to_vec(v).unwrap_or_default());
        let network = self.chain_network_signature()?;
        Ok(
            json!({"settings":digest(&self.chain_context()?),"manifest":digest(&self.chain_manifest_identity()?),"network":digest(&network)}),
        )
    }
    fn save_chain_cache(&self) -> Result<()> {
        self.engine.store.write(
            "runtime-state/chain-scan-cache.json",
            &json!({"schemaVersion":1,"key":self.chain_cache_key,"state":self.chain_scan}),
        )
    }
    fn load_chain_cache(&mut self) {
        let Ok(cache) = self
            .engine
            .store
            .read("runtime-state/chain-scan-cache.json", Value::Null)
        else {
            return;
        };
        if cache["schemaVersion"] != 1 || !cache["state"].is_object() {
            return;
        }
        let Some(rows) = cache["state"]["results"].as_array() else {
            return;
        };
        if rows.len() > 5000
            || !rows.iter().all(|r| {
                r.is_object()
                    && r["identityKey"].is_string()
                    && r["providerRevision"].is_string()
                    && r["testedAt"].is_string()
            })
        {
            return;
        }
        self.chain_cache_key = cache["key"].clone();
        self.chain_scan = cache["state"].clone();
        self.chain_scan["running"] = json!(false);
        self.chain_scan["testing"] = json!(false);
        self.chain_scan["currentNode"] = Value::Null;
        self.chain_scan["nextTestAt"] = Value::Null;
        self.chain_scan["cancelled"] = json!(self.chain_scan["cacheUsable"] != true);
    }
    fn restore_chain_cache_context(&mut self) {
        if self.chain_token.is_none() && !self.chain_cache_checked {
            self.chain_cache_checked = true;
            if self
                .chain_cache_identity()
                .is_ok_and(|k| k == self.chain_cache_key)
            {
                if let (Ok(manifest), Ok(settings)) =
                    (self.chain_manifest_identity(), self.chain_context())
                {
                    self.chain_manifest = manifest;
                    self.chain_settings = settings;
                    self.chain_token = Some(self.diagnostic_token());
                }
            }
        }
    }
    fn chain_scan_state(&self, strategy: &str) -> Result<Value> {
        let key = self.chain_cache_identity().unwrap_or(Value::Null);
        let inventory = subscription::provider_nodes(&self.engine.store).unwrap_or_default();
        let mut source = self.chain_scan.clone();
        for row in source["results"].as_array_mut().into_iter().flatten() {
            if let Some(node) = inventory
                .iter()
                .find(|n| n["identityKey"] == row["identityKey"])
            {
                row["subscriptionId"] = node["subscriptionId"].clone();
                row["subscriptionName"] = node["subscriptionName"].clone();
            }
            let context = row
                .get("measurementContext")
                .unwrap_or(&self.chain_cache_key);
            let same_settings =
                !key["settings"].is_null() && context["settings"] == key["settings"];
            let node_matches = inventory.iter().any(|n| {
                n["identityAmbiguous"] != true
                    && n["identityKey"] == row["identityKey"]
                    && n["providerRevision"] == row["providerRevision"]
            });
            let other_environment = !same_settings
                || !node_matches
                || key["network"].is_null()
                || context["network"] != key["network"];
            row["otherEnvironment"] = json!(other_environment);
            row["connectionEligible"] = json!(
                same_settings
                    && node_matches
                    && row["status"] == "available"
                    && self.chain_scan["cacheUsable"] == true
                    && self.chain_scan["error"].is_null()
            );
        }
        let mut state = crate::chain_scan::ranked(&source, strategy)?;
        state["leaders"] = json!({
            "balanced":crate::chain_scan::ranked(&source, "balanced")?["recommendedIdentityKey"],
            "download":crate::chain_scan::ranked(&source, "download")?["recommendedIdentityKey"],
            "latency":crate::chain_scan::ranked(&source, "latency")?["recommendedIdentityKey"]
        });
        // Age affects confidence; a different environment affects applicability.
        state["stale"] = json!(!self.chain_environment_valid());
        state["canUseCachedResults"] = json!(
            state["stale"] == false && state["cacheUsable"] == true && state["error"].is_null()
        );
        state["workerActive"] = json!(self.jobs.chain_active.load(Ordering::SeqCst));
        state["queuedIdentityKeys"] = json!(
            self.jobs
                .chain_priority
                .lock()
                .map(|q| q.iter().cloned().collect::<Vec<_>>())
                .unwrap_or_default()
        );
        state["autoRefresh"] = self.chain_automatic_state()?;
        state["suggestedRefreshSeconds"] = json!(crate::chain_scan::MAX_AGE_SECONDS);
        state["validitySeconds"] = Value::Null;
        Ok(state)
    }
    fn prepare_chain_connect(&self, p: &Value) -> Result<ChainConnect> {
        allowed_keys(p, &["scanId", "identityKey", "strategy"])?;
        self.assert_company_owner()?;
        ensure!(
            !self.engine.protected(),
            "请在当前轻舟连接 VPN 后再应用链路。"
        );
        ensure!(
            !self.jobs.chain_connect_active.load(Ordering::SeqCst),
            "连接操作正在进行。"
        );
        ensure!(
            self.engine.pid.is_some()
                && self.engine.store.settings()?["staticExit"]["enabled"] == true,
            "测试结果已保存；请先连接 VPN 并启用 ISP，再应用推荐链路。"
        );
        let (node, expected) = self.chain_connection_target(p)?;
        Ok(ChainConnect {
            node,
            environment: self.chain_cache_identity()?,
            port: self.chain_scan_port()?,
            expected,
            token: self.diagnostic_token(),
            jobs: self.jobs.clone(),
            io: self.engine.io(),
            ip_url: chain_targets(self.engine.isolated)?.ip,
            latency_url: chain_targets(self.engine.isolated)?.latency,
        })
    }
    fn chain_connection_target(&self, p: &Value) -> Result<(Value, String)> {
        let strategy = p["strategy"].as_str().unwrap_or("balanced");
        let state = self.chain_scan_state(strategy)?;
        ensure!(
            state["id"] == p["scanId"]
                && (state["cancelled"] == false || state["cacheUsable"] == true)
                && (!self.jobs.chain_active.load(Ordering::SeqCst) || state["cacheUsable"] == true)
                && state["error"].is_null(),
            "扫描结果已失效，请重新扫描。"
        );
        let key = p
            .get("identityKey")
            .unwrap_or(&state["recommendedIdentityKey"]);
        let result = state["results"]
            .as_array()
            .and_then(|a| {
                a.iter().find(|r| {
                    r["identityKey"] == *key
                        && r["status"] == "available"
                        && r["connectionEligible"] == true
                        && (strategy != "balanced" || r["balancedScore"].is_number())
                })
            })
            .context("没有完整通过测试的链路，请重试扫描。")?;
        let node = self.node_identity(result["identityKey"].as_str().context("节点标识无效。")?)?;
        ensure!(
            node["providerRevision"] == result["providerRevision"],
            "节点订阅已更新，请重新扫描。"
        );
        Ok((
            node,
            result["exitIp"]
                .as_str()
                .context("出口尚未确认。")?
                .to_owned(),
        ))
    }
    fn set_static_exit_enabled(&mut self, p: &Value) -> Result<Value> {
        allowed_keys(p, &["enabled"])?;
        let enabled = p["enabled"].as_bool().context("ISP 出口开关需要布尔值。")?;
        let settings = self.engine.store.settings()?;
        let mut exit = settings["staticExit"].clone();
        exit["enabled"] = json!(enabled);
        crate::static_exit::validate(&exit)?;
        if enabled {
            ensure!(
                settings["selectedProxy"] != "DIRECT",
                "请先选择一个机场节点，再启用 ISP 出口。"
            );
            if !exit["username"].as_str().unwrap_or("").is_empty() {
                ensure!(
                    crate::static_exit::credential_matches(&exit, &self.exit_credential)
                        && self.exit_credential["password"]
                            .as_str()
                            .is_some_and(|p| !p.is_empty()),
                    "ISP 密码尚未加载，请打开 ISP 配置重新保存。"
                );
            }
        }
        self.revision += 1;
        self.settings_patch(&json!({"staticExit":exit}), true)
    }
    fn configure_static_exit(&mut self, p: &Value) -> Result<Value> {
        allowed_keys(p, &["configuration", "password"])?;
        crate::static_exit::validate(&p["configuration"])?;
        let password = p["password"].as_str().context("静态出口密码格式无效。")?;
        ensure!(password.len() <= 4096, "静态出口密码过长。");
        self.revision += 1;
        let previous = self.exit_credential.clone();
        self.exit_credential = p.clone();
        let result = self.settings_patch(&json!({"staticExit":p["configuration"]}), true);
        if result.is_err() {
            self.exit_credential = previous;
        }
        result
    }
    fn static_exit_port(&self) -> Result<u16> {
        if self.exit_probe != 0 {
            return Ok(self.exit_probe);
        }
        let loaded = config::parse(&fs::read_to_string(
            self.engine.store.path("mihomo/config.yaml"),
        )?)?;
        loaded["listeners"]
            .as_array()
            .and_then(|a| a.iter().find(|l| l["name"] == crate::static_exit::LISTENER))
            .and_then(|l| l["port"].as_u64())
            .and_then(|p| u16::try_from(p).ok())
            .context("当前运行版本没有静态出口检测入口，请重新连接。")
    }
    fn begin_static_exit_check(&self) -> Result<StaticExitCheck> {
        ensure!(!self.engine.isolated, "隔离测试不访问真实出口。");
        ensure!(self.engine.pid.is_some(), "请先连接 VPN，再测试静态出口。");
        let s = self.engine.store.settings()?;
        ensure!(
            s["staticExit"]["enabled"] == true,
            "请先保存并启用静态出口。"
        );
        Ok(StaticExitCheck {
            port: self.static_exit_port()?,
            expected: s["staticExit"]["expectedIp"]
                .as_str()
                .unwrap_or("")
                .to_owned(),
            token: self.diagnostic_token(),
        })
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
        self.apply_static_exit(&mut c, settings)?;
        // Company compilation uses the retained base TUN setting; isolation
        // tests for company routing call its compiler without starting a TUN.
        let text = config::yaml(&c)?;
        atomic_write(
            &self.engine.store.path("mihomo/providers/vpn-domains.yaml"),
            config::yaml(&json!({"payload":settings["vpnDomainRules"]}))?.as_bytes(),
        )?;
        platform::validate(&self.engine.binary, &self.engine.store, &text)?;
        ensure!(
            !self.jobs.stop_requested.load(Ordering::SeqCst),
            "恢复已被断开请求取消。"
        );
        self.company.reload_base(&mut self.engine, &text)?;
        ensure!(
            !self.jobs.stop_requested.load(Ordering::SeqCst),
            "恢复已被断开请求取消。"
        );
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
                if p.contains_key("staticExit") && c.engine.pid.is_some() {
                    c.engine
                        .close_departed_path_connections(&c.jobs.stop_requested, true)?;
                }
            }
            c.engine.store.write("settings.json", &s)?;
            Ok(s)
        })
    }
    pub fn nodes(&self) -> Result<Vec<Value>> {
        let s = self.engine.store.settings()?;
        let mut nodes = subscription::provider_nodes(&self.engine.store)?;
        let live = if self.engine.pid.is_some() {
            self.live_proxies.as_ref()
        } else {
            None
        };
        let cache = self
            .engine
            .store
            .read("runtime-state/speed-cache.json", json!({"entries":[]}))?;
        let empty = Vec::new();
        let cached = cache["entries"].as_array().unwrap_or(&empty);
        for n in &mut nodes {
            n["selected"] = json!(n["name"] == s["selectedProxy"]);
            let proxy = live.and_then(|v| v["proxies"].get(n["name"].as_str().unwrap()));
            if let Some(proxy) = proxy {
                n["type"] = proxy["type"].clone();
                n["runtimeUdpSupported"] = proxy["udp"].clone();
            }
            crate::node_latency::apply(n, proxy, cached, chrono::Utc::now());
        }
        nodes.push(json!({"name":"DIRECT","type":"Direct","selected":s["selectedProxy"]=="DIRECT","delay":null,"available":true,"identityKey":null}));
        Ok(nodes)
    }
    fn groups(&self) -> Result<Value> {
        let settings = self.engine.store.settings()?;
        let nodes = self.nodes()?;
        self.groups_from_nodes(&settings, &nodes)
    }
    fn groups_from_nodes(&self, settings: &Value, nodes: &[Value]) -> Result<Value> {
        let mut groups = Vec::new();
        let mut identities = std::collections::HashMap::new();
        let mut names = std::collections::HashMap::new();
        let mut subscription_names = std::collections::HashMap::new();
        for node in nodes {
            if let Some(key) = node["identityKey"].as_str() {
                identities.entry(key).or_insert(node);
            }
            if let Some(name) = node["name"].as_str() {
                names.entry(name).or_insert(node);
                if let Some(id) = node["subscriptionId"].as_str() {
                    subscription_names.entry((id, name)).or_insert(node);
                }
            }
        }
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
                let node = match r["identityKey"].as_str() {
                    Some(key) => identities.get(key).copied(),
                    None => r["lastKnownName"].as_str().and_then(|name| match subscription_id {
                        Some(id) => subscription_names.get(&(id, name)).copied(),
                        None => names.get(name).copied(),
                    }),
                };
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
        let status = self.status()?;
        let nodes = self.nodes()?;
        let groups = self.groups_from_nodes(&status["settings"], &nodes)?;
        let risks = self.risks()?;
        let traffic = self.traffic();
        Ok(self.bootstrap_view(status, json!(nodes), groups, risks, traffic))
    }
    pub fn handle(&mut self, channel: &str, p: &Value) -> Result<Value> {
        if self
            .jobs
            .chain_use_state
            .lock()
            .is_ok_and(|state| state["finished"] == false)
            && !matches!(
                channel,
                "core:capabilities"
                    | "native:bootstrap"
                    | "native:network-changed"
                    | "native:runtime-environment"
                    | "vpn:get-status"
                    | "vpn:stop"
                    | "diagnostics:get-state"
                    | "chain-scan:get"
                    | "chain-scan:history"
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
                    | "static-exit:needs-credential"
                    | "runtime:get-recovery-state"
            )
        {
            bail!("正在使用所选线路，请等待或取消当前操作。");
        }
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
                | "diagnostics:get-state"
                | "chain-scan:get"
                | "chain-scan:history"
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
            "chain-scan:history" => chain_history::page(
                &self.engine.store,
                p,
                &self.chain_cache_identity().unwrap_or(Value::Null),
            ),
            "chain-scan:get" => {
                allowed_keys(p, &["strategy", "subscriptionId"])?;
                self.restore_chain_cache_context();
                let subscription_id = p
                    .get("subscriptionId")
                    .map(|v| {
                        v.as_str()
                            .filter(|id| !id.is_empty())
                            .context("请选择有效订阅。")
                    })
                    .transpose()?;
                self.chain_scan_view(
                    p["strategy"].as_str().unwrap_or("balanced"),
                    subscription_id,
                )
            }
            "chain-scan:prioritize" => {
                allowed_keys(p, &["identityKey"])?;
                ensure!(
                    self.chain_scan["running"] == true
                        && self.jobs.chain_active.load(Ordering::SeqCst)
                        && !self.jobs.cancelled("chain"),
                    "请先开始测试，或在停止后单独测试这条线路。"
                );
                ensure!(
                    self.chain_configuration_current(),
                    "配置已变化，请重新开始测试。"
                );
                let key = string(p, "identityKey")?;
                ensure!(
                    self.chain_scan["candidateIdentityKeys"]
                        .as_array()
                        .is_some_and(|keys| keys.contains(&json!(key))),
                    "这条线路不在当前测试范围内，请暂停后重新开始。"
                );
                let node = self.node_identity(key)?;
                ensure!(
                    node["identityAmbiguous"] == false,
                    "同名冲突线路暂不能单独重测。"
                );
                if self.chain_scan["testing"] == true
                    && self.chain_scan["currentNode"] == node["name"]
                {
                    return Ok(json!({"alreadyTesting":true,"queued":false}));
                }
                ensure!(
                    self.chain_scan["mode"] == "continuous"
                        || !self.chain_scan["results"].as_array().is_some_and(|rows| {
                            rows.iter().any(|row| row["identityKey"] == key)
                        }),
                    "单轮比较中只能优先测试尚未采样的线路；已测线路可在本轮结束后重测。"
                );
                let mut queue = self
                    .jobs
                    .chain_priority
                    .lock()
                    .map_err(|_| anyhow::anyhow!("重测队列不可用。"))?;
                if !queue.iter().any(|id| id == key) {
                    ensure!(queue.len() < 32, "优先重测队列已满，请稍后再试。");
                    queue.push_back(key.to_owned());
                }
                Ok(json!({"queued":true,"alreadyTesting":false}))
            }
            "chain-scan:auto-configure" => self.configure_chain_automatic(p),
            "chain-scan:cancel" => {
                self.jobs.chain_cancel.store(true, Ordering::SeqCst);
                self.pause_chain_automatic()?;
                Ok(json!(true))
            }
            "static-exit:needs-credential" => {
                let s = self.engine.store.settings()?;
                Ok(json!(
                    s["staticExit"]["enabled"] == true
                        && !s["staticExit"]["username"]
                            .as_str()
                            .unwrap_or("")
                            .is_empty()
                        && !crate::static_exit::credential_matches(
                            &s["staticExit"],
                            &self.exit_credential
                        )
                ))
            }
            "static-exit:parse" => crate::static_exit::parse_line(string(p, "line")?),
            "static-exit:configure" => self.configure_static_exit(p),
            "static-exit:set-enabled" => self.set_static_exit_enabled(p),
            "static-exit:credential" => {
                allowed_keys(p, &["configuration", "password"])?;
                crate::static_exit::validate(&p["configuration"])?;
                ensure!(
                    p["password"].as_str().is_some_and(|s| s.len() <= 4096),
                    "静态出口密码格式无效。"
                );
                self.exit_credential = p.clone();
                Ok(json!({"loaded":true}))
            }
            "static-exit:test" => self.begin_static_exit_check()?.measure(),
            "native:bootstrap" => self.bootstrap(),
            "native:startup-connect" => self.startup_connect(),
            "native:runtime-environment" => {
                allowed_keys(
                    p,
                    &[
                        "sleeping",
                        "lowPower",
                        "onBattery",
                        "networkEvents",
                        "visible",
                    ],
                )?;
                for key in [
                    "sleeping",
                    "lowPower",
                    "onBattery",
                    "networkEvents",
                    "visible",
                ] {
                    ensure!(
                        p.get(key)
                            .is_none_or(|v| v.is_boolean() || (key == "onBattery" && v.is_null())),
                        "运行环境参数需要是布尔值。"
                    );
                }
                let was_sleeping = self.environment.sleeping;
                if let Some(visible) = p["visible"].as_bool() {
                    if visible && self.environment.visible == Some(false) {
                        self.last_sample_tick = None;
                    }
                    self.environment.visible = Some(visible);
                }
                if let Some(value) = p["sleeping"].as_bool() {
                    self.environment.sleeping = value;
                }
                if let Some(value) = p["lowPower"].as_bool() {
                    self.environment.low_power = value;
                }
                if p.get("onBattery").is_some() {
                    self.environment.on_battery = p["onBattery"].as_bool();
                }
                if let Some(value) = p["networkEvents"].as_bool() {
                    self.environment.network_events = value;
                }
                if was_sleeping != self.environment.sleeping {
                    self.invalidate_chain_network();
                    self.jobs.invalidate_diagnostics();
                    if was_sleeping {
                        self.chain_network_changed_at = Some(Instant::now());
                    }
                }
                if was_sleeping && !self.environment.sleeping && self.wants_running {
                    self.network_recovery.changed_for(None, "wake");
                    self.last_network_tick = None;
                    self.publish_runtime_status();
                }
                self.jobs.wake_background();
                Ok(json!(true))
            }
            "native:network-changed" => {
                self.observe_chain_path(p["available"].as_bool());
                self.chain_network_changed_at = Some(Instant::now());
                self.jobs.wake_background();
                if self.wants_running && !self.engine.protected() {
                    self.path_health.invalidate();
                    self.live_proxies = None;
                    self.pending_wechat = None;
                    self.network_recovery.changed(p["available"].as_bool());
                    self.last_network_tick = None;
                    self.jobs.invalidate_diagnostics();
                    self.publish_runtime_status();
                    self.jobs.wake_background();
                }
                Ok(self.runtime_status())
            }
            "native:upgrade-helper" => self.update_connection_service(),
            "vpn:get-status" => self.status(),
            "diagnostics:get-state" => {
                self.sync_diagnostics();
                Ok(self.diagnostics.status())
            }
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
                self.wants_running = true;
                self.last_network_tick = None;
                self.jobs.invalidate_diagnostics();
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
                self.jobs.invalidate_diagnostics();
                self.wants_running = false;
                self.network_recovery.clear();
                self.path_health.invalidate();
                self.stop_runtime()?;
                self.path_health = crate::path_health::PathHealth::default();
                self.live_proxies = None;
                self.pending_wechat = None;
                self.last_totals = None;
                self.health_failures = 0;
                self.health_pid = None;
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
                let plan = self.prepare_current_exit_risk()?;
                let result = plan.measure()?;
                self.finish_node_diagnostic(&plan, result)
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
        ensure!(
            name != "DIRECT" || self.engine.store.settings()?["staticExit"]["enabled"] != true,
            "请先关闭静态出口，再选择直连。"
        );
        self.ensure_user_helper()?;
        self.revision += 1;
        let result = self.transaction(|c| {
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
                if p["rebuildProxyConnections"] == true {
                    c.engine
                        .close_departed_path_connections(&c.jobs.stop_requested, true)?;
                }
            }
            c.engine.store.write("settings.json", &s)?;
            Ok(s)
        })?;
        if let Some(proxies) = self.live_proxies.as_mut() {
            proxies["proxies"]["VPN"]["now"] = json!(name);
        }
        if self.chain_scan["id"]
            .as_str()
            .is_some_and(|id| !id.is_empty())
        {
            self.refresh_maintenance_candidates(false);
            let _ = self.save_chain_cache();
        }
        Ok(result)
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
        ensure!(
            !self.jobs.stop_requested.load(Ordering::SeqCst),
            "连接已被断开请求取消。"
        );
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
            self.apply_static_exit(&mut cfg, &s)?;
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
        ensure!(
            !self.jobs.stop_requested.load(Ordering::SeqCst),
            "连接已取消。"
        );
        self.engine.start_authorized(!self.auto_starting)?;
        ensure!(
            !self.jobs.stop_requested.load(Ordering::SeqCst),
            "连接已取消，正在断开。"
        );
        self.wants_running = !probe;
        if !probe && self.engine.has_proxy("VPN")? {
            let selected = s["selectedProxy"].as_str().unwrap();
            self.engine
                .wait_for_vpn_member(selected, Duration::from_secs(20));
            ensure!(
                !self.jobs.stop_requested.load(Ordering::SeqCst),
                "连接已取消，正在断开。"
            );
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
    fn accept_traffic(&mut self, result: Result<Value>) -> Value {
        let mut error = None;
        let mut snapshot = Value::Null;
        let mut rates = json!({"upload":0,"download":0});
        if self.engine.pid.is_some() {
            match result {
                Ok(v) => {
                    let up = v["uploadTotal"].as_u64().unwrap_or(0);
                    let down = v["downloadTotal"].as_u64().unwrap_or(0);
                    if let Some((a, b, time)) = self.last_totals {
                        let secs = time.elapsed().as_secs_f64().max(0.01);
                        rates = json!({"upload":up.saturating_sub(a) as f64/secs,"download":down.saturating_sub(b) as f64/secs});
                    }
                    self.last_totals = Some((up, down, Instant::now()));
                    let connections=v["connections"].as_array().map(|a|a.iter().map(|c|json!({"id":c["id"].as_str().unwrap_or(""),"host":c["metadata"]["host"].as_str().unwrap_or(""),"network":c["metadata"]["network"].as_str().unwrap_or(""),"type":c["metadata"]["type"].as_str().unwrap_or(""),"rule":c["rule"].as_str().unwrap_or(""),"rulePayload":c["rulePayload"].as_str().unwrap_or(""),"chains":c["chains"].as_array().cloned().unwrap_or_default(),"routeKind":crate::traffic::route_kind(&c["chains"]),"upload":c["upload"].as_u64().unwrap_or(0),"download":c["download"].as_u64().unwrap_or(0),"process":c["metadata"]["process"],"destination":format!("{}:{}",c["metadata"]["destinationIP"].as_str().unwrap_or(""),c["metadata"]["destinationPort"].as_str().map(str::to_owned).unwrap_or_else(||c["metadata"]["destinationPort"].to_string()))})).collect::<Vec<_>>()).unwrap_or_default();
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
    pub fn traffic(&mut self) -> Value {
        if self.traffic_snapshot.is_null() {
            json!({"snapshot":null,"rates":{"upload":0,"download":0},"samples":[],"running":self.engine.pid.is_some(),"updatedAt":null,"error":null})
        } else {
            let mut value = self.traffic_snapshot.clone();
            value["running"] = json!(self.engine.pid.is_some());
            if self.engine.pid.is_none() {
                value["snapshot"] = Value::Null;
                value["rates"] = json!({"upload":0,"download":0});
            }
            value
        }
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
            mixed: if settings["staticExit"]["enabled"] == true && self.engine.pid.is_some() {
                self.static_exit_port()?
            } else {
                self.engine.mixed
            },
            selected: settings["selectedProxy"].clone(),
        })
    }
    fn prepare_node_diagnostic(
        &self,
        name: &str,
        kind: &str,
        recommended: bool,
    ) -> Result<NodeDiagnostic> {
        ensure!(
            !self.jobs.stop_requested.load(Ordering::SeqCst),
            "检测已被断开请求取消。"
        );
        ensure!(
            !self.jobs.chain_sampling.load(Ordering::SeqCst),
            "ISP 链路扫描正在使用检测入口，请先等待或取消扫描。"
        );
        let node = self
            .nodes()?
            .into_iter()
            .find(|n| {
                n["name"] == name
                    && (n["identityKey"].is_string() || (kind == "risk" && name == "DIRECT"))
            })
            .context("节点不存在。")?;
        ensure!(
            node["identityAmbiguous"] != true,
            "同名节点不能进行可信检测。"
        );
        ensure!(self.engine.pid.is_some(), "请先连接 VPN。");
        let mut endpoint = None;
        if kind == "risk" {
            ensure!(
                !self.risk_key.is_empty(),
                "请先在风险页面配置 ipdata 密钥。"
            );
            let settings = self.engine.store.settings()?;
            ensure!(
                settings["vpnDomainRules"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("DOMAIN-SUFFIX,ipdata.co")),
                "请先将 ipdata.co 加入 VPN 分流。"
            );
            endpoint = Some(if self.engine.isolated {
                url::Url::parse(&network::fixture_url("SPLITVPN_TEST_IPDATA_URL")?)?
            } else {
                url::Url::parse("https://api.ipdata.co/")?
            });
        }
        Ok(NodeDiagnostic {
            io: self.engine.io(),
            node,
            name: name.into(),
            kind: kind.into(),
            recommended,
            probe: self.engine.probe,
            select_probe: true,
            via_static_exit: false,
            current_exit_key: None,
            risk_key: self.risk_key.clone(),
            endpoint,
            token: self.diagnostic_token(),
            jobs: self.jobs.clone(),
        })
    }
    fn finish_node_diagnostic(
        &mut self,
        plan: &NodeDiagnostic,
        mut result: Value,
    ) -> Result<Value> {
        if !self.diagnostic_current(&plan.token) {
            ensure!(plan.kind == "speed", "连接已变化，检测结果已丢弃。");
            result["status"] = json!("runtime-changed");
            result["delay"] = Value::Null;
            result["medianDelayMs"] = Value::Null;
            result["medianMs"] = Value::Null;
            result["ok"] = json!(false);
            result["error"] = json!("连接已变化，检测结果已丢弃。");
            return Ok(result);
        }
        if plan.kind == "speed" {
            let mut cache = self.engine.store.read(
                "runtime-state/speed-cache.json",
                json!({"schemaVersion":1,"entries":[]}),
            )?;
            let entries = cache["entries"]
                .as_array_mut()
                .context("测速缓存格式无效。")?;
            entries.retain(|e| {
                !(e["identityKey"] == plan.node["identityKey"]
                    && e["targetSetId"] == result["targetSetId"])
            });
            entries.insert(0, result.clone());
            entries.truncate(500);
            self.engine
                .store
                .write("runtime-state/speed-cache.json", &cache)?;
        } else if plan.kind == "risk" {
            if let Some(key) = &plan.current_exit_key {
                return self.finish_current_exit_risk(plan, key, result);
            }
            let mut cache = self
                .engine
                .store
                .read("ipdata-risk-cache.json", json!({"version":1,"entries":[]}))?;
            let entries = cache["entries"]
                .as_array_mut()
                .context("风险缓存格式无效。")?;
            entries.retain(|e| e["nodeName"] != plan.name);
            entries.insert(0, result.clone());
            self.engine.store.write("ipdata-risk-cache.json", &cache)?;
        }
        Ok(result)
    }
    pub fn speed(&mut self, name: &str, recommended: bool) -> Result<Value> {
        let plan = self.prepare_node_diagnostic(name, "speed", recommended)?;
        let result = plan.measure()?;
        self.finish_node_diagnostic(&plan, result)
    }
    pub fn risk(&mut self, name: &str) -> Result<Value> {
        let plan = self.prepare_node_diagnostic(name, "risk", false)?;
        let result = plan.measure()?;
        self.finish_node_diagnostic(&plan, result)
    }
    pub fn udp(&mut self, name: &str) -> Result<Value> {
        let plan = self.prepare_node_diagnostic(name, "udp", false)?;
        let result = plan.measure()?;
        self.finish_node_diagnostic(&plan, result)
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
    fn diagnostic_token(&self) -> DiagnosticToken {
        DiagnosticToken {
            epoch: self.jobs.intent_epoch.load(Ordering::SeqCst),
            revision: self.revision,
            pid: self.engine.pid,
            config: fs::read(self.engine.store.path("mihomo/config.yaml")).ok(),
        }
    }
    fn diagnostic_current(&self, token: &DiagnosticToken) -> bool {
        !self.jobs.shutdown.load(Ordering::SeqCst)
            && !self.jobs.stop_requested.load(Ordering::SeqCst)
            && *token == self.diagnostic_token()
    }
    fn sync_diagnostics(&mut self) {
        let token = self.diagnostic_token();
        if self.diagnostics_context.as_ref() != Some(&token) {
            self.diagnostics.invalidate();
            self.diagnostics_context = Some(token);
        }
        let recovery = self.network_recovery.status();
        let paused = if self.environment.sleeping {
            Some("sleeping")
        } else if self.jobs.stop_requested.load(Ordering::SeqCst)
            || !self.wants_running
            || self.engine.pid.is_none()
            || self.engine.owned != self.engine.pid
        {
            Some("disconnected")
        } else if matches!(
            recovery["state"].as_str(),
            Some("waiting-network" | "recovering" | "helper-update-required")
        ) || self.network_recovery.needs_fast_check()
        {
            Some("recovering")
        } else if self.jobs.speed_active.load(Ordering::SeqCst)
            || self.jobs.risk_active.load(Ordering::SeqCst)
            || self.jobs.udp_active.load(Ordering::SeqCst)
            || self.jobs.chain_sampling.load(Ordering::SeqCst)
        {
            Some("node-test")
        } else {
            None
        };
        self.diagnostics
            .environment(paused, self.environment.low_power, Instant::now());
    }
    fn begin_diagnostic(&mut self, kind: CheckKind, manual: bool) -> Result<DiagnosticRequest> {
        let check = self.network_check()?;
        self.sync_diagnostics();
        let id = self
            .diagnostics
            .claim(kind, manual)
            .map_err(anyhow::Error::msg)?;
        let plan = DiagnosticRequest {
            kind,
            id,
            check,
            token: self.diagnostic_token(),
            jobs: self.jobs.clone(),
            chain_context: self
                .engine
                .store
                .settings()
                .ok()
                .filter(|s| s["staticExit"]["enabled"] == true)
                .and_then(|_| self.chain_cache_identity().ok()),
        };
        self.publish_read_views();
        Ok(plan)
    }
    pub fn take_due_diagnostic(&mut self) -> Option<DiagnosticRequest> {
        self.sync_diagnostics();
        if self.engine.isolated
            || self.jobs.shutdown.load(Ordering::SeqCst)
            || self.jobs.speed_active.load(Ordering::SeqCst)
            || self.jobs.risk_active.load(Ordering::SeqCst)
            || self.jobs.udp_active.load(Ordering::SeqCst)
            || self.jobs.chain_sampling.load(Ordering::SeqCst)
        {
            return None;
        }
        let kind = self.diagnostics.due(Instant::now())?;
        self.begin_diagnostic(kind, false).ok()
    }
    fn complete_diagnostic(
        &mut self,
        plan: &DiagnosticRequest,
        result: Result<Value>,
    ) -> Result<Value> {
        self.sync_diagnostics();
        if !self.diagnostic_current(&plan.token) {
            self.publish_read_views();
            bail!("连接已变化，检测结果已丢弃。");
        }
        let record = result
            .as_ref()
            .map(Clone::clone)
            .map_err(|e| redact(&e.to_string()));
        let accepted = self
            .diagnostics
            .finish(plan.kind, plan.id, record, Instant::now());
        if accepted && plan.kind == CheckKind::Connectivity {
            if let (Some(context), Ok(value)) = (&plan.chain_context, &result) {
                self.record_diagnostic_connection_check(context, value);
            }
        }
        self.publish_read_views();
        ensure!(accepted, "检测结果已过期，未覆盖新的检测状态。");
        result
    }
    pub fn take_background_sample(&mut self) -> Option<BackgroundSample> {
        if self.environment.sleeping
            || self.engine.pid.is_none()
            || self.jobs.stop_requested.load(Ordering::SeqCst)
        {
            return None;
        }
        let health = self.wants_running
            && self.engine.owned == self.engine.pid
            && self.network_recovery.status()["state"] == "ready"
            && (self.network_recovery.needs_verification()
                || self
                    .last_health_tick
                    .is_none_or(|t| t.elapsed() >= Duration::from_secs(30)));
        if !health
            && self
                .last_sample_tick
                .is_some_and(|t| t.elapsed() < self.environment.sample_interval())
        {
            return None;
        }
        self.last_sample_tick = Some(Instant::now());
        let recovery_id = if !self.engine.isolated {
            self.network_recovery.take_check()
        } else {
            None
        };
        if health {
            self.last_health_tick = Some(Instant::now());
        }
        let settings = self.engine.store.settings().ok()?;
        Some(BackgroundSample {
            io: self.engine.io(),
            token: self.diagnostic_token(),
            health,
            recovery_id,
            retry_socket: self.pending_wechat.take(),
            isolated: self.engine.isolated,
            tun: settings["tun"] == true,
            selected: settings["selectedProxy"]
                .as_str()
                .unwrap_or("DIRECT")
                .into(),
            probe: if settings["staticExit"]["enabled"] == true {
                self.static_exit_port().ok()?
            } else {
                self.engine.probe
            },
            static_exit: settings["staticExit"]["enabled"] == true,
            jobs: self.jobs.clone(),
            wechat: settings["specialCompatibilityRules"]["wechatImageSendFallback"] == true,
        })
    }
    pub fn complete_background_sample(&mut self, sample: &BackgroundSample, result: SampleResult) {
        if !self.diagnostic_current(&sample.token) {
            return;
        }
        if self.health_pid != self.engine.pid {
            self.health_pid = self.engine.pid;
            self.connection_health = ConnectionHealth::default();
            self.health_failures = 0;
            self.wechat_route = None;
            self.last_totals = None;
        }
        self.live_proxies = result.proxies.ok();
        if sample.wechat && sample.health {
            let group = self.live_proxies.as_ref().map(|v| &v["proxies"]["WECHAT"]);
            let route = match group.and_then(|g| g["now"].as_str()) {
                Some("DIRECT") => "direct",
                Some("VPN" | crate::static_exit::EXIT) => "proxy",
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
        let snapshot = result
            .connections
            .as_ref()
            .ok()
            .cloned()
            .unwrap_or(Value::Null);
        self.traffic_snapshot = self.accept_traffic(result.connections);
        if let Some(outcome) = result.retry_outcome {
            self.log(
                "info",
                &format!("connection-health scope=wechat outcome={outcome}"),
            );
        }
        if sample.health {
            if let Some(id) = sample.recovery_id {
                if result.path == crate::path_health::PathOutcome::Skipped
                    && result.controller == Some(true)
                    && sample.selected != "DIRECT"
                {
                    self.network_recovery.defer_check(id);
                } else {
                    self.network_recovery
                        .checked(id, result.path == crate::path_health::PathOutcome::Healthy);
                }
            }
            if let Some(healthy) = result.controller {
                self.record_tunnel_health(healthy);
            }
            self.accept_path_health(result.path);
            if sample.wechat && result.controller == Some(true) {
                if let Some(id) = self.connection_health.observe(&snapshot, Instant::now()) {
                    self.log("warn", "connection-health scope=wechat reason=no-response-120s quiet=30s outcome=targeted-retry-requested");
                    self.pending_wechat = Some(id);
                }
            } else {
                self.connection_health = ConnectionHealth::default();
            }
        }
        self.publish_runtime_status();
        self.publish_read_views();
    }
    fn accept_path_health(&mut self, outcome: crate::path_health::PathOutcome) {
        use crate::path_health::{PathAction, PathOutcome};
        let action = self.path_health.observe(outcome, Instant::now());
        match action {
            PathAction::None => {}
            PathAction::Recheck => {
                self.last_health_tick = Some(Instant::now() - Duration::from_secs(25))
            }
            PathAction::Recover => {
                if outcome == PathOutcome::EgressFailure && self.chain_failover_ready() {
                    self.jobs.wake_background();
                    return;
                }
                let reason = if outcome == PathOutcome::DnsFailure {
                    "dns-health"
                } else {
                    "egress-health"
                };
                self.network_recovery.changed_for(None, reason);
                self.last_network_tick = None;
                self.jobs.wake_background();
            }
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
        if self.health_failures < 3 {
            self.last_health_tick = Some(Instant::now() - Duration::from_secs(25));
        }
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
    #[cfg(test)]
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
            || self.jobs.stop_requested.load(Ordering::SeqCst)
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
        self.publish_runtime_status();
        if self.wants_running
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
                self.jobs.invalidate_diagnostics();
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
    fn recover_network(&mut self, context: &Value) -> Result<()> {
        let retry_state = self.network_recovery.clone();
        let same_path = self
            .network_recovery
            .same_path(context["signature"].as_str());
        use crate::network_recovery::RecoveryAction;
        let can_restart = self.engine.owned.is_some()
            && self.engine.owned == self.engine.pid
            && !self.company.state()["proxyName"].is_string();
        let action =
            self.network_recovery
                .action(same_path, cfg!(target_os = "macos"), can_restart);
        if action == RecoveryAction::RefreshDns {
            ensure!(
                !self.jobs.stop_requested.load(Ordering::SeqCst),
                "恢复已取消。"
            );
            self.engine.refresh_dns()?;
            self.network_recovery
                .applied(context["signature"].as_str().map(str::to_owned));
            return Ok(());
        }
        // A failed reload of an owned, unhealthy controller may escalate once.
        // Company routing requires an independent recovery and must be preserved.
        if action == RecoveryAction::Restart {
            ensure!(
                !self.jobs.stop_requested.load(Ordering::SeqCst),
                "恢复已取消。"
            );
            self.engine.stop()?;
            self.auto_starting = true;
            let result = self.start_vpn(false).map(|_| ());
            self.auto_starting = false;
            return result;
        }
        let settings = self.engine.store.settings()?;
        self.transaction(|core| core.apply_config_in_context(&settings, context))?;
        if !same_path {
            if let Err(error) = self
                .engine
                .close_departed_path_connections(&self.jobs.stop_requested, false)
            {
                self.network_recovery = retry_state;
                return Err(error);
            }
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
            || self.jobs.chain_sampling.load(Ordering::SeqCst)
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
    pub(crate) fn mobile(port: u16, selected: Value) -> Self {
        Self {
            isolated: false,
            tun: true,
            running: true,
            mixed: port,
            selected,
        }
    }
    fn proxied(&self, timeout: u64) -> Result<Client> {
        ensure!(self.running, "请先连接 VPN。");
        proxied(self.mixed, timeout)
    }
    pub fn connectivity(&self) -> Result<Value> {
        self.connectivity_with(|| true)
    }
    fn connectivity_with(&self, current: impl Fn() -> bool) -> Result<Value> {
        ensure!(current(), "连接已变化，检测已取消。");
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
        ensure!(current(), "连接已变化，检测已取消。");
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
            json!({"connectivity":network::complete_connectivity(&domestic,&foreign,&dns,&chatgpt,ip),"nodeRisk":null,"nodeRiskError":null,"checkedAt":now()}),
        )
    }
    pub(crate) fn measure(&self, url: &str, proxy: bool) -> Value {
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
        match client.and_then(|c| Ok(c.get(url).send()?)) {
            Ok(response) => {
                let status = response.status().as_u16();
                let ok = response.status().is_success();
                let elapsed = start.elapsed().as_millis();
                json!({"url":url,"ok":ok,"delay":if ok {json!(elapsed)}else{Value::Null},"responseMs":elapsed,
                    "httpStatus":status,"failureReason":if ok {None}else{Some(if matches!(status,403|429|451){"restricted"}else{"http-status"})},
                    "error":if ok {None}else{Some(format!("站点返回 HTTP {status}。"))},"checkedAt":now()})
            }
            Err(error) => {
                json!({"url":url,"ok":false,"delay":null,"responseMs":null,"httpStatus":null,
                "failureReason":crate::diagnostics::failure_kind(&error),"error":redact(&error.to_string()),"checkedAt":now()})
            }
        }
    }

    pub fn websites(&self) -> Result<Value> {
        self.websites_with(|| true)
    }
    fn websites_with(&self, current: impl Fn() -> bool) -> Result<Value> {
        ensure!(self.running, "请先连接 VPN。");
        ensure!(current(), "连接已变化，检测已取消。");
        let fixture = if self.isolated {
            Some(network::fixture_url("SPLITVPN_TEST_CONNECTIVITY_URL")?)
        } else {
            None
        };
        let targets = [
            ("google", "Google", "https://www.google.com/generate_204"),
            ("chatgpt", "ChatGPT", "https://chatgpt.com/cdn-cgi/trace"),
            ("claude", "Claude", "https://claude.ai"),
        ];
        let results = std::thread::scope(|scope| {
            let tasks: Vec<_> = targets
                .into_iter()
                .map(|(id, label, url)| {
                    let url = fixture.as_deref().unwrap_or(url);
                    scope.spawn(move || {
                        let mut value = self.measure(url, true);
                        value["id"] = json!(id);
                        value["label"] = json!(label);
                        value
                    })
                })
                .collect();
            tasks
                .into_iter()
                .map(|task| task.join().unwrap())
                .collect::<Vec<_>>()
        });
        ensure!(current(), "连接已变化，检测已取消。");
        Ok(json!({"proxyName":self.selected,"results":results,"checkedAt":now()}))
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
                "failureReason":if status == 200 {None}else{Some(if matches!(status,403|429|451){"restricted"}else{"http-status"})},
                "error":if status == 200 {None}else{Some(format!("ChatGPT 返回 HTTP {status}。"))}})
        }
        Err(error) => {
            let error: anyhow::Error = error.into();
            json!({"ok":false,"httpStatus":null,"elapsedMs":null,
                "failureReason":crate::diagnostics::failure_kind(&error),"error":redact(&error.to_string())})
        }
    }
}
/// Preflight stays in RPC order; only network IO moves to another thread.
#[derive(Clone, PartialEq)]
struct DiagnosticToken {
    epoch: u64,
    revision: u64,
    pid: Option<u32>,
    config: Option<Vec<u8>>,
}

pub struct NodeDiagnostic {
    io: ControllerIo,
    node: Value,
    name: String,
    kind: String,
    recommended: bool,
    probe: u16,
    select_probe: bool,
    via_static_exit: bool,
    current_exit_key: Option<String>,
    risk_key: String,
    endpoint: Option<url::Url>,
    token: DiagnosticToken,
    jobs: Arc<Jobs>,
}
impl NodeDiagnostic {
    fn check_current(&self) -> Result<()> {
        ensure!(
            !self.jobs.shutdown.load(Ordering::SeqCst)
                && !self.jobs.stop_requested.load(Ordering::SeqCst)
                && self.jobs.intent_epoch.load(Ordering::SeqCst) == self.token.epoch,
            "检测已取消。"
        );
        Ok(())
    }
    fn measure(&self) -> Result<Value> {
        self.check_current()?;
        if self.kind == "speed" {
            return self.latency();
        }
        if self.kind == "udp" {
            let live = self.io.api("GET", "/proxies", None)?;
            let supported = live["proxies"][&self.name]["udp"]
                .as_bool()
                .context("尚未确认内核的 UDP 能力，请稍后重试。")?;
            if !supported {
                return Ok(
                    json!({"nodeName":self.name,"supported":false,"ok":false,"error":"此节点不支持 UDP，未发送探测。","checkedAt":now()}),
                );
            }
        }
        // The selector belongs to the probe listener. Never hold the core lock
        // while waiting for this lease or while sending traffic through it.
        let _lease = self
            .jobs
            .probe_gate
            .try_lock()
            .map_err(|_| anyhow::anyhow!("检测入口正在使用，请稍后重试。"))?;
        ensure!(self.probe != 0, "检测入口尚未就绪，请断开后重新连接 VPN。");
        if self.select_probe {
            self.io
                .api("PUT", "/proxies/PROBE", Some(&json!({"name":self.name})))?;
        }
        let port = self.probe;
        if self.kind == "udp" {
            let result = udp_stun(port);
            return Ok(
                json!({"nodeName":self.name,"supported":result.is_ok(),"ok":result.is_ok(),"error":result.err().map(|e|redact(&e.to_string())),"checkedAt":now()}),
            );
        }
        let result = (|| -> Result<Value> {
            let mut v: Value = proxied(port, 15)?
                .get(self.endpoint.clone().unwrap())
                .query(&[("api-key", &self.risk_key)])
                .send()?
                .error_for_status()?
                .json()?;
            ensure!(v["ip"].as_str().is_some(), "风险服务未返回出口 IP。");
            if v["threat"].is_null() {
                self.check_current()?;
                let threat: Value = proxied(port, 15)?
                    .get(
                        self.endpoint
                            .as_ref()
                            .unwrap()
                            .join(&format!("{}/threat", encode(v["ip"].as_str().unwrap())))?,
                    )
                    .query(&[("api-key", &self.risk_key)])
                    .send()?
                    .error_for_status()?
                    .json()?;
                v["threat"] = threat.get("threat").unwrap_or(&threat).clone();
                if v["scores"].is_null() {
                    v["scores"] = threat["scores"].clone();
                }
            }
            Ok(risk_result(&self.name, &v))
        })();
        let result = result?;
        Ok(result)
    }
    fn latency(&self) -> Result<Value> {
        let targets = [
            (
                "gstatic-204",
                "Google",
                "https://www.gstatic.com/generate_204",
            ),
            (
                "apple-success",
                "Apple",
                "https://www.apple.com/library/test/success.html",
            ),
            (
                "chatgpt-trace",
                "ChatGPT",
                "https://chatgpt.com/cdn-cgi/trace",
            ),
        ];
        let targets = &targets[..if self.recommended { 3 } else { 1 }];
        let mut samples = Vec::new();
        let mut target_samples = Vec::new();
        let mut errors = Vec::new();
        let mut failure = "transport-error";
        for (id, label, url) in targets {
            self.check_current()?;
            let value = self.io.api(
                "GET",
                &format!(
                    "/proxies/{}/delay?timeout=8000&url={}",
                    encode(&self.name),
                    encode(url)
                ),
                None,
            );
            match value {
                Ok(v) if v["delay"].as_u64().unwrap_or(0) > 0 => {
                    samples.push(v["delay"].as_u64().unwrap());
                    target_samples.push(json!({"targetId":id,"label":label,"delayMs":v["delay"],"transportOk":true,"expectedStatusMatched":null,"failureReason":null,"checkedAt":now()}));
                }
                value => {
                    let error = match value {
                        Err(error) => error,
                        _ => anyhow::anyhow!("节点未返回有效延迟。"),
                    };
                    let kind = crate::diagnostics::failure_kind(&error);
                    if kind == "timeout" {
                        failure = kind;
                    }
                    errors.push(redact(&error.to_string()));
                    target_samples.push(json!({"targetId":id,"label":label,"delayMs":null,"transportOk":false,"expectedStatusMatched":null,"failureReason":kind,"checkedAt":now()}));
                }
            }
        }
        samples.sort_unstable();
        let median = samples.get(samples.len() / 2).copied();
        Ok(
            json!({"identityKey":self.node["identityKey"],"nodeName":self.name,"runtimeName":self.name,
            "targetSetId":if self.recommended {"recommended-latency"}else{"default-latency"},"targetSetVersion":2,
            "status":if median.is_none(){if failure=="timeout" {"timeout"}else{"unreachable"}}else if samples.len()<targets.len(){"unstable"}else{"available"},
            "failureReason":if errors.is_empty(){Value::Null}else{json!(failure)},
            "medianDelayMs":median,"medianMs":median,"delay":median,"p95Ms":samples.last(),"samples":target_samples,
            "results":[],"error":errors.first(),"errors":errors,"checkedAt":now(),"schemaVersion":1,
            "providerRevision":self.node["providerRevision"],"testedAt":now()}),
        )
    }
}

pub struct BackgroundSample {
    io: ControllerIo,
    token: DiagnosticToken,
    health: bool,
    recovery_id: Option<u64>,
    retry_socket: Option<String>,
    isolated: bool,
    tun: bool,
    selected: String,
    probe: u16,
    static_exit: bool,
    jobs: Arc<Jobs>,
    wechat: bool,
}
pub struct SampleResult {
    proxies: Result<Value>,
    connections: Result<Value>,
    controller: Option<bool>,
    path: crate::path_health::PathOutcome,
    retry_outcome: Option<&'static str>,
}
impl BackgroundSample {
    pub fn run(&self) -> SampleResult {
        use crate::path_health::PathOutcome;
        let current = || {
            !self.jobs.shutdown.load(Ordering::SeqCst)
                && self.jobs.intent_epoch.load(Ordering::SeqCst) == self.token.epoch
        };
        let retry_outcome = self.retry_socket.as_ref().filter(|_| current()).map(|id| {
            if self
                .io
                .authorized("DELETE", &format!("/connections/{}", encode(id)), None)
                .is_ok_and(|r| r.status().is_success() || r.status() == 404)
            {
                "socket-closed-awaiting-app-retry"
            } else {
                "close-failed"
            }
        });
        let proxies = self.io.api("GET", "/proxies", None);
        let connections = if current() {
            self.io.api("GET", "/connections", None)
        } else {
            Err(anyhow::anyhow!("采样已取消。"))
        };
        let mut result = SampleResult {
            proxies,
            connections,
            controller: None,
            path: PathOutcome::Skipped,
            retry_outcome,
        };
        if !self.health || !current() {
            return result;
        }
        let binding = (|| -> Result<()> {
            let config = self.io.api("GET", "/configs", None)?;
            if !self.isolated {
                let context = platform::context()?;
                ensure!(
                    config["interface-name"] == context["interfaceName"],
                    "网卡绑定尚未就绪。"
                );
                ensure!(config["tun"]["enable"] == self.tun, "TUN 配置尚未就绪。");
                ensure!(
                    !self.tun
                        || platform::tun_device_ready(
                            config["tun"]["device"].as_str().unwrap_or("")
                        ),
                    "TUN 尚未就绪。"
                );
            }
            Ok(())
        })();
        result.controller = Some(binding.is_ok());
        if binding.is_err() || !current() || self.selected == "DIRECT" || self.isolated {
            return result;
        }
        // A lease prevents risk/UDP checks changing the probe selector midway.
        let Ok(_lease) = self.jobs.probe_gate.try_lock() else {
            return result;
        };
        if self.probe == 0 {
            return result;
        }
        if !self.static_exit
            && self
                .io
                .api(
                    "PUT",
                    "/proxies/PROBE",
                    Some(&json!({"name":self.selected})),
                )
                .is_err()
        {
            return result;
        }
        let client = Client::builder()
            .no_proxy()
            .pool_max_idle_per_host(0)
            .timeout(Duration::from_secs(5))
            .redirect(reqwest::redirect::Policy::none())
            .proxy(
                match reqwest::Proxy::all(format!("http://127.0.0.1:{}", self.probe)) {
                    Ok(proxy) => proxy,
                    Err(_) => return result,
                },
            )
            .build();
        let Ok(client) = client else {
            return result;
        };
        let mut healthy = false;
        for (url, expected) in [
            ("https://www.gstatic.com/generate_204", 204),
            ("https://www.apple.com/library/test/success.html", 200),
        ] {
            if !current() {
                return result;
            }
            if client.get(url).send().is_ok_and(|r| {
                r.status().as_u16() == expected
                    && (expected == 204 || r.text().is_ok_and(|body| body.contains("Success")))
            }) {
                healthy = true;
                break;
            }
        }
        if !current() {
            return result;
        }
        // DNS evidence is gathered separately from the explicit VPN outlet.
        let dns = network::automatic_dns_health();
        result.path = if !dns {
            PathOutcome::DnsFailure
        } else if healthy {
            PathOutcome::Healthy
        } else {
            PathOutcome::EgressFailure
        };
        result
    }
}

pub struct DiagnosticRequest {
    kind: CheckKind,
    id: u64,
    check: NetworkCheck,
    token: DiagnosticToken,
    jobs: Arc<Jobs>,
    chain_context: Option<Value>,
}
impl DiagnosticRequest {
    pub fn run(self, core: &Mutex<Core>) -> Result<Value> {
        let current = || {
            !self.jobs.shutdown.load(Ordering::SeqCst)
                && !self.jobs.stop_requested.load(Ordering::SeqCst)
                && self.jobs.intent_epoch.load(Ordering::SeqCst) == self.token.epoch
        };
        let result = match self.kind {
            CheckKind::Connectivity => self.check.connectivity_with(current),
            CheckKind::Websites => self.check.websites_with(current),
        };
        core.lock()
            .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?
            .complete_diagnostic(&self, result)
    }
}
pub struct StaticExitCheck {
    port: u16,
    expected: String,
    token: DiagnosticToken,
}
impl StaticExitCheck {
    fn measure(&self) -> Result<Value> {
        // Fixed loopback inbound pins this request to the final hop even when
        // the user's default rule is DIRECT. Never use ambient system proxies.
        let port = self.port;
        let client = proxied(port, 12)?;
        let started = Instant::now();
        let ip: Value = client
            .get("https://api.ipify.org?format=json")
            .send()
            .and_then(|r| r.error_for_status())
            .and_then(|r| r.json())
            .map_err(|_| anyhow::anyhow!("静态出口测试失败，请检查机场、协议、地址与账号密码。"))?;
        let ip = ip["ip"]
            .as_str()
            .and_then(|s| s.parse::<std::net::IpAddr>().ok())
            .context("出口检测没有返回有效 IP。")?
            .to_string();
        let expected = self.expected.as_str();
        let matches = expected
            .parse::<std::net::IpAddr>()
            .ok()
            .map(|e| e.to_string() == ip);
        Ok(
            json!({"ip":ip,"expectedIp":expected,"matchesExpected":matches,"elapsedMs":started.elapsed().as_millis(),"chain":"airport-static-exit","udpSupported":false}),
        )
    }
}
pub enum NetworkRequest {
    Subscription(ManualUpdate),
    Diagnostic(Box<DiagnosticRequest>),
    Node(Box<NodeDiagnostic>),
    StaticExit(StaticExitCheck),
    ChainConnect(Box<ChainConnect>),
    ChainUse(Box<chain_use::ChainUse>),
}
impl NetworkRequest {
    pub fn run(self, core: &Mutex<Core>) -> Result<Value> {
        match self {
            Self::ChainConnect(plan) => plan.run(core),
            Self::ChainUse(plan) => plan.run(core),
            Self::StaticExit(plan) => {
                let result = plan.measure()?;
                let c = core
                    .lock()
                    .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
                ensure!(
                    c.diagnostic_current(&plan.token),
                    "连接已变化，请重新测试静态出口。"
                );
                Ok(result)
            }
            Self::Subscription(plan) => {
                let downloaded = plan.download();
                let mut c = core
                    .lock()
                    .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
                let result = c.finish_manual_update(plan, downloaded);
                c.publish_read_views();
                result
            }
            Self::Diagnostic(plan) => plan.run(core),
            Self::Node(plan) => {
                let result = plan.measure()?;
                let mut c = core
                    .lock()
                    .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
                let result = c.finish_node_diagnostic(&plan, result);
                c.publish_read_views();
                result
            }
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
        "chain-scan:use" => lock()
            .and_then(|c| c.prepare_chain_use(payload))
            .map(Box::new)
            .map(NetworkRequest::ChainUse),
        "chain-scan:connect" => lock()
            .and_then(|c| c.prepare_chain_connect(payload))
            .map(Box::new)
            .map(NetworkRequest::ChainConnect),
        "static-exit:test" => lock()
            .and_then(|c| c.begin_static_exit_check())
            .map(NetworkRequest::StaticExit),
        "subscription:update" => lock()
            .and_then(|mut c| c.begin_manual_update(payload))
            .map(NetworkRequest::Subscription),
        "connectivity:check" | "connectivity:test-website-speeds" => lock()
            .and_then(|mut c| {
                c.begin_diagnostic(
                    if channel == "connectivity:check" {
                        CheckKind::Connectivity
                    } else {
                        CheckKind::Websites
                    },
                    true,
                )
            })
            .map(|plan| NetworkRequest::Diagnostic(Box::new(plan))),
        "nodes:check-current-risk" => lock()
            .and_then(|c| c.prepare_current_exit_risk())
            .map(|plan| NetworkRequest::Node(Box::new(plan))),
        "nodes:test" | "nodes:test-recommended" | "nodes:check-risk" | "nodes:test-udp" => lock()
            .and_then(|c| {
                let name = if channel == "nodes:test-recommended" {
                    c.node_identity(string(payload, "identityKey")?)?["name"]
                        .as_str()
                        .context("节点不存在。")?
                        .to_owned()
                } else {
                    string(payload, "nodeName")?.to_owned()
                };
                c.prepare_node_diagnostic(
                    &name,
                    if channel.contains("risk") {
                        "risk"
                    } else if channel.ends_with("udp") {
                        "udp"
                    } else {
                        "speed"
                    },
                    channel == "nodes:test-recommended",
                )
            })
            .map(|plan| NetworkRequest::Node(Box::new(plan))),
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
        ensure!(
            !c.jobs.chain_sampling.load(Ordering::SeqCst),
            "请先等待当前 ISP 链路采样完成。"
        );
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
            events(
                &format!("nodes:{kind}-progress"),
                json!({"id":id,"checked":checked,"total":total,"nodeName":name,"phase":"testing","finished":false,"cancelled":false}),
            );
            let plan = core
                .lock()
                .map_err(|_| anyhow::anyhow!("后台状态不可用。"))
                .and_then(|c| c.prepare_node_diagnostic(&name, &kind, false));
            let result = plan.and_then(|plan| {
                let result = plan.measure()?;
                core.lock()
                    .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?
                    .finish_node_diagnostic(&plan, result)
            });
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

fn chain_targets(isolated: bool) -> Result<crate::chain_scan::Targets> {
    if !isolated {
        return Ok(crate::chain_scan::Targets::default());
    }
    // Isolated runtime may only use explicit loopback fixtures.
    Ok(crate::chain_scan::Targets {
        latency: network::fixture_url("SPLITVPN_TEST_CHAIN_LATENCY_URL")?,
        download: network::fixture_url("SPLITVPN_TEST_CHAIN_DOWNLOAD_URL")?,
        ip: network::fixture_url("SPLITVPN_TEST_CHAIN_IP_URL")?,
        bytes: crate::chain_scan::DOWNLOAD_BYTES,
    })
}
struct ChainActivity(Arc<Jobs>);
impl Drop for ChainActivity {
    fn drop(&mut self) {
        self.0.chain_active.store(false, Ordering::SeqCst);
        self.0.wake_background();
    }
}

pub struct ChainConnect {
    node: Value,
    environment: Value,
    port: u16,
    expected: String,
    token: DiagnosticToken,
    jobs: Arc<Jobs>,
    io: ControllerIo,
    ip_url: String,
    latency_url: String,
}
struct ChainConnectActivity(Arc<Jobs>);
impl Drop for ChainConnectActivity {
    fn drop(&mut self) {
        self.0.chain_connect_active.store(false, Ordering::SeqCst);
    }
}
impl ChainConnect {
    fn run(self, core: &Mutex<Core>) -> Result<Value> {
        ensure!(
            !self.jobs.chain_connect_active.swap(true, Ordering::SeqCst),
            "链路任务正在运行。"
        );
        self.jobs
            .chain_connect_cancel
            .store(false, Ordering::SeqCst);
        let _active = ChainConnectActivity(self.jobs.clone());
        let _lease = self
            .jobs
            .probe_gate
            .lock()
            .map_err(|_| anyhow::anyhow!("检测入口不可用。"))?;
        {
            let c = core
                .lock()
                .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
            ensure!(
                c.diagnostic_current(&self.token)
                    && c.chain_cache_identity()
                        .is_ok_and(|k| k == self.environment),
                "连接环境已变化，请重新复核。"
            );
        }
        self.io.api(
            "PUT",
            &format!("/proxies/{}", encode(crate::static_exit::SCAN_FRONT)),
            Some(&json!({"name":self.node["name"]})),
        )?;
        let (ip, verification_ms) = match crate::chain_scan::recheck(
            self.port,
            &self.latency_url,
            &self.ip_url,
            &self.expected,
        ) {
            Ok(result) => result,
            Err(_) => {
                if let Ok(mut c) = core.lock() {
                    if c.diagnostic_current(&self.token) {
                        c.record_connection_check(&self.node, "failed");
                        let _ = c.save_chain_cache();
                    }
                }
                bail!("链路连通性或出口复核失败，当前连接已保留。");
            }
        };
        let mut c = core
            .lock()
            .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
        ensure!(
            !self.jobs.chain_connect_cancel.load(Ordering::SeqCst)
                && c.diagnostic_current(&self.token)
                && c.chain_cache_identity()
                    .is_ok_and(|k| k == self.environment),
            "连接环境已变化，请重新扫描。"
        );
        c.assert_company_owner()?;
        let already_selected = c.engine.store.settings()?["selectedProxy"] == self.node["name"]
            && c.engine.selections()?["VPN"] == self.node["name"];
        if !already_selected {
            c.select_node(
                "nodes:select-v2",
                &json!({"identityKey":self.node["identityKey"],"rebuildProxyConnections":true}),
            )?;
        }
        c.chain_token = Some(c.diagnostic_token());
        c.chain_scan["connectedIdentityKey"] = self.node["identityKey"].clone();
        c.record_connection_check(&self.node, "passed");
        if let Some(row) = c.chain_scan["results"].as_array_mut().and_then(|rows| {
            rows.iter_mut()
                .find(|r| r["identityKey"] == self.node["identityKey"])
        }) {
            row["lastVerifiedAt"] = json!(now());
            row["verificationLatencyMs"] = json!(verification_ms);
        }
        let measurement_context = c.chain_cache_key.clone();
        for row in c.chain_scan["results"].as_array_mut().into_iter().flatten() {
            if row.get("measurementContext").is_none() {
                row["measurementContext"] = measurement_context.clone();
            }
        }
        if let Ok(key) = c.chain_cache_identity() {
            c.chain_cache_key = key;
        }
        if c.save_chain_cache().is_err() {
            c.chain_scan["cacheError"] = json!("结果暂未保存到磁盘。");
        }
        c.publish_read_views();
        Ok(
            json!({"connected":true,"nodeName":self.node["name"],"exitIp":ip,"verificationLatencyMs":verification_ms,"verifiedAt":now()}),
        )
    }
}

struct ChainSampling(Arc<Jobs>);
impl Drop for ChainSampling {
    fn drop(&mut self) {
        self.0.chain_sampling.store(false, Ordering::SeqCst);
    }
}
fn chain_interval(isolated: bool) -> Duration {
    let ms = if isolated {
        std::env::var("SPLITVPN_TEST_CHAIN_INTERVAL_MS")
            .ok()
            .and_then(|s| s.parse::<u64>().ok())
            .map(|n| n.clamp(100, 60000))
            .unwrap_or(60000)
    } else {
        60000
    };
    Duration::from_millis(ms)
}
pub fn start_chain_scan(core: Arc<Mutex<Core>>, payload: Value) -> Result<Value> {
    let (
        nodes,
        candidates,
        port,
        io,
        jobs,
        targets,
        expected,
        id,
        mode,
        interval,
        probe,
        force_retest,
        automatic,
    ) = {
        let mut c = core
            .lock()
            .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
        allowed_keys(
            &payload,
            &[
                "identityKeys",
                "subscriptionId",
                "mode",
                "forceRetest",
                "automatic",
            ],
        )?;
        let force_retest = payload
            .get("forceRetest")
            .map(|v| v.as_bool().context("重测开关需要布尔值。"))
            .transpose()?
            .unwrap_or(false);
        let mode = payload["mode"].as_str().unwrap_or("accumulate").to_owned();
        let automatic = payload
            .get("automatic")
            .map(|v| v.as_bool().context("自动任务标识需要布尔值。"))
            .transpose()?
            .unwrap_or(false);
        if automatic {
            let settings = c.engine.store.settings()?;
            ensure!(
                mode == "continuous"
                    && payload.get("identityKeys").is_none()
                    && payload.get("subscriptionId").is_none()
                    && settings["chainAutoRefresh"]["enabled"] == true
                    && settings["chainAutoRefresh"]["paused"] != true
                    && !c.chain_auto_paused_in_memory
                    && !c.environment.sleeping
                    && !c.environment.low_power
                    && !chain_automatic::battery_blocked(&c)
                    && !chain_automatic::network_settling(&c)
                    && chain_automatic::baseline_ready(&c)
                    && chain_automatic::batch_due(&c.chain_scan, chrono::Utc::now()),
                "日常自动刷新未开启或已暂停。"
            );
        }

        ensure!(
            matches!(
                mode.as_str(),
                "full" | "accumulate" | "continuous" | "quick"
            ),
            "请选择全部重测、积累测试或持续测试。"
        );
        c.assert_company_owner()?;

        let s = c.engine.store.settings()?;
        ensure!(
            s["staticExit"]["server"]
                .as_str()
                .is_some_and(|v| !v.is_empty())
                && s["staticExit"]["port"].as_u64().is_some_and(|v| v > 0),
            "请先保存 ISP 出口配置，无需开启 ISP。"
        );
        ensure!(
            !c.jobs.chain_active.load(Ordering::SeqCst)
                && !c.jobs.chain_connect_active.load(Ordering::SeqCst),
            "后台链路任务正在运行，请先暂停。"
        );
        ensure!(
            !c.jobs.speed_active.load(Ordering::SeqCst)
                && !c.jobs.risk_active.load(Ordering::SeqCst)
                && !c.jobs.udp_active.load(Ordering::SeqCst),
            "请先等待当前节点检测完成。"
        );
        let keys = payload
            .get("identityKeys")
            .map(|v| v.as_array().context("节点列表格式无效。"))
            .transpose()?;
        let subscription_id = payload
            .get("subscriptionId")
            .map(|v| {
                v.as_str()
                    .filter(|id| !id.is_empty())
                    .context("请选择有效订阅。")
            })
            .transpose()?;
        ensure!(
            subscription_id.is_none() || keys.is_none(),
            "订阅范围与节点列表不能同时指定。"
        );
        ensure!(
            subscription_id.is_none() || mode != "full",
            "按订阅全量重测请使用积累模式并开启重测，其他订阅的成绩会保留。"
        );
        ensure!(
            !force_retest
                || (mode == "accumulate"
                    && (keys.is_some_and(|k| !k.is_empty()) || subscription_id.is_some())),
            "重测需要指定节点或订阅，并使用积累模式。"
        );
        let inventory = subscription::provider_nodes(&c.engine.store)?
            .into_iter()
            .filter(|n| n["identityAmbiguous"] == false)
            .collect::<Vec<_>>();
        let maintained = c.maintenance_candidates(&inventory);
        if automatic {
            // Recheck under the start lock: a manual test may have refreshed a
            // planned candidate. Never launch an idle probe for fresh results.
            ensure!(
                chain_automatic::next_automatic_candidate(
                    &maintained,
                    c.chain_scan["results"]
                        .as_array()
                        .map(Vec::as_slice)
                        .unwrap_or_default(),
                    &Value::Null,
                )
                .is_some(),
                "当前成绩无需自动重测。"
            );
        }
        // Keep raw server addresses inside the worker only, never in RPC rows or
        // persisted observations.
        let mut servers = std::collections::HashMap::new();
        for (entry, _, raw_nodes) in subscription::enabled_providers(&c.engine.store)? {
            for node in raw_nodes {
                let identity = crate::storage::identity(
                    entry["id"].as_str().unwrap_or(""),
                    node["name"].as_str().unwrap_or(""),
                );
                servers.insert(identity, node["server"].as_str().unwrap_or("").to_owned());
            }
        }
        let mut all = inventory
            .iter()
            .filter(|n| {
                keys.is_none_or(|a| a.contains(&n["identityKey"]))
                    && subscription_id.is_none_or(|id| n["subscriptionId"] == id)
                    && (!automatic
                        || maintained
                            .iter()
                            .any(|m| m["identityKey"] == n["identityKey"]))
            })
            .cloned()
            .map(|mut node| {
                node["scanServer"] = json!(
                    servers
                        .get(node["identityKey"].as_str().unwrap_or(""))
                        .cloned()
                        .unwrap_or_default()
                );
                node
            })
            .collect::<Vec<_>>();
        if mode == "quick" {
            let compatible = c.chain_cache_identity().is_ok_and(|k| {
                !k["settings"].is_null() && k["settings"] == c.chain_cache_key["settings"]
            });
            all = chain_routine::quick_candidates(
                &all,
                if compatible {
                    c.chain_scan["results"]
                        .as_array()
                        .map(Vec::as_slice)
                        .unwrap_or_default()
                } else {
                    &[]
                },
                &s["selectedProxy"],
                &s["favoriteNodeNames"],
            );
        }
        ensure!(
            !all.is_empty() && all.len() <= 5000,
            "没有可测试的机场节点，或节点数量超过 5000。"
        );
        let targets = chain_targets(c.engine.isolated)?;
        // Always isolate scanning from connection rebuilds and business selectors.
        let probe = if !c.engine.isolated {
            Some(chain_probe::ChainProbe::start(&c, &s)?)
        } else {
            None
        };
        let port = if let Some(probe) = &probe {
            probe.port
        } else {
            c.chain_scan_port()?
        };
        let mut io = probe
            .as_ref()
            .map(|p| p.io.clone())
            .unwrap_or_else(|| c.engine.io());
        if c.engine.isolated {
            // Explicit loopback fixture also implements the scan controller.
            io.controller = port;
        }
        let key = c.chain_cache_identity()?;
        let manifest = c.chain_manifest_identity()?;
        let context = c.chain_context()?;
        let rejection_context = crate::storage::sha256(&serde_json::to_vec(
            &json!({"settings":context,"network":key["network"]}),
        )?);
        let rejected_rows = if c.chain_scan["rejectionContext"] == rejection_context {
            c.chain_scan["rejectedResults"]
                .as_array()
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter(crate::chain_scan::rejected)
                .filter(|r| {
                    inventory
                        .iter()
                        .any(|n| n["identityKey"] == r["identityKey"])
                })
                .collect::<Vec<_>>()
        } else {
            vec![]
        };
        let previous = c.chain_scan["results"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let same_settings =
            !key["settings"].is_null() && c.chain_cache_key["settings"] == key["settings"];
        let rows = if mode != "full" && same_settings {
            previous
                .into_iter()
                .filter(|r| {
                    inventory.iter().any(|n| {
                        n["identityKey"] == r["identityKey"]
                            && n["providerRevision"] == r["providerRevision"]
                    })
                })
                .map(|mut row| {
                    if row.get("measurementContext").is_none() {
                        row["measurementContext"] = c.chain_cache_key.clone();
                    }
                    row
                })
                .collect::<Vec<_>>()
        } else {
            vec![]
        };
        let nodes = if mode == "accumulate" && !force_retest {
            all.iter()
                .filter(|n| {
                    !rows.iter().any(|r| {
                        r["identityKey"] == n["identityKey"]
                            && r["status"] == "available"
                            && crate::chain_scan::fresh(r, chrono::Utc::now())
                    })
                })
                .cloned()
                .collect::<Vec<_>>()
        } else {
            all.clone()
        };
        let id = uuid::Uuid::new_v4().to_string();
        let interval = chain_interval(c.engine.isolated);
        let last_automatic_sample = c.chain_scan["lastAutomaticSampleAt"].clone();
        let last_batch = c.chain_scan["lastAutomaticBatchAt"].clone();
        let uncertain = c.chain_scan["autoNetworkUncertain"].clone();
        let baseline = chain_automatic::baseline_ready(&c);
        let previous_pool = c.chain_scan["maintenanceIdentityKeys"].clone();
        let connection_check = c.chain_scan["connectionCheck"].clone();
        let failover_attempt = c.chain_scan["lastFailoverAttemptAt"].clone();
        let failover_at = c.chain_scan["lastFailoverAt"].clone();
        let connected = if same_settings {
            c.chain_scan["connectedIdentityKey"].clone()
        } else {
            Value::Null
        };
        c.chain_scan = json!({"id":id,"mode":mode,"running":!nodes.is_empty(),"testing":false,"cancelled":false,"completed":0,"total":nodes.len(),"candidateCount":all.len(),"currentNode":null,"results":rows,"error":null,"startedAt":now(),"cacheUsable":mode!="full","nextTestAt":null,"intervalSeconds":60,"waitingReason":null,"stopReason":null,"networkRestarts":0});
        c.chain_scan["baselineReady"] = json!(baseline && mode != "full");
        c.chain_scan["baselineEligible"] =
            json!(mode == "full" && keys.is_none() && subscription_id.is_none());
        c.chain_scan["connectedIdentityKey"] = connected;
        c.chain_scan["maintenanceIdentityKeys"] = if automatic {
            json!(
                maintained
                    .iter()
                    .map(|n| n["identityKey"].clone())
                    .collect::<Vec<_>>()
            )
        } else {
            previous_pool
        };
        c.chain_scan["connectionCheck"] = connection_check;
        c.chain_scan["lastFailoverAttemptAt"] = failover_attempt;
        c.chain_scan["lastFailoverAt"] = failover_at;
        c.chain_scan["lastAutomaticBatchAt"] = if automatic { json!(now()) } else { last_batch };
        c.chain_scan["autoNetworkUncertain"] = uncertain;
        if automatic {
            c.chain_auto_error = false;
        }
        c.chain_scan["automatic"] = json!(automatic);
        c.chain_scan["lastAutomaticSampleAt"] = last_automatic_sample;
        c.chain_scan["taskIdentityKeys"] = json!(
            nodes
                .iter()
                .map(|n| n["identityKey"].clone())
                .collect::<Vec<_>>()
        );
        c.chain_scan["processedIdentityKeys"] = json!([]);
        c.chain_scan["sampleDurationsMs"] = json!([]);
        c.chain_scan["candidateIdentityKeys"] = json!(
            all.iter()
                .map(|n| n["identityKey"].clone())
                .collect::<Vec<_>>()
        );
        c.chain_scan["rejectedResults"] = json!(rejected_rows);
        c.chain_scan["rejectionContext"] = json!(rejection_context);
        c.chain_token = Some(c.diagnostic_token());
        c.chain_manifest = manifest;
        c.chain_settings = context;
        c.chain_cache_key = key;
        c.jobs
            .chain_priority
            .lock()
            .map_err(|_| anyhow::anyhow!("重测队列不可用。"))?
            .clear();
        c.jobs.chain_cancel.store(false, Ordering::SeqCst);
        if nodes.is_empty() {
            c.chain_scan["stopReason"] = json!("completed");
            c.chain_scan["finishedAt"] = json!(now());
            c.chain_scan["cacheUsable"] = json!(true);
            c.save_chain_cache()?;
            return Ok(json!({"id":id,"total":0,"reusedCount":rows.len()}));
        }
        c.save_chain_cache()?;
        ensure!(
            !c.jobs.chain_active.swap(true, Ordering::SeqCst),
            "后台链路任务正在运行。"
        );
        let probe = probe.map(|p| Arc::new(Mutex::new(p)));
        c.chain_probe = probe.clone();
        (
            nodes,
            all,
            port,
            io,
            c.jobs.clone(),
            targets,
            s["staticExit"]["expectedIp"]
                .as_str()
                .unwrap_or("")
                .to_owned(),
            id,
            mode,
            interval,
            probe,
            force_retest,
            automatic,
        )
    };
    let reply = json!({"id":id,"total":nodes.len(),"mode":mode,"downloadBytesPerNode":crate::chain_scan::DOWNLOAD_BYTES*2});
    std::thread::spawn(move || {
        let _active = ChainActivity(jobs.clone());
        let _probe = probe;
        let keep_running = || {
            !jobs.cancelled("chain")
                && core
                    .lock()
                    .is_ok_and(|c| c.chain_scan["id"] == id && c.chain_configuration_current())
        };
        let current = || {
            keep_running()
                && core.lock().is_ok_and(|c| {
                    !c.environment.sleeping
                        && c.chain_environment_valid()
                        && (!automatic
                            || (!c.environment.low_power
                                && !chain_automatic::battery_blocked(&c)
                                && !chain_automatic::network_settling(&c)))
                })
        };
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<()> {
            let mut turn = 0;
            let mut active_nodes = nodes.clone();
            let mut queue = std::collections::VecDeque::from(active_nodes.clone());
            let mut generation = 0;
            let mut skipped = HashSet::new();
            let mut auto_failures = 0usize;
            let mut network_checked = false;
            while keep_running() {
                let ready = {
                    let mut c = core
                        .lock()
                        .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
                    let ready = c.prepare_chain_cycle()?;
                    let observed = c.chain_scan["networkRestarts"].as_u64().unwrap_or(0);
                    if observed != generation {
                        generation = observed;
                        active_nodes = candidates.clone();
                        queue = std::collections::VecDeque::from(active_nodes.clone());
                        skipped.clear();
                        turn = 0;
                        c.chain_scan["total"] = json!(active_nodes.len());
                        c.chain_scan["taskIdentityKeys"] = json!(
                            active_nodes
                                .iter()
                                .map(|n| n["identityKey"].clone())
                                .collect::<Vec<_>>()
                        );
                    }
                    ready
                };
                if !ready {
                    // Do not keep a dedicated worker waking once a second while
                    // automatic maintenance is blocked by power or network state.
                    if automatic {
                        break;
                    }
                    std::thread::sleep(interval.min(Duration::from_secs(1)));
                    continue;
                }
                if automatic && !network_checked {
                    network_checked = true;
                    let uncertain = core
                        .lock()
                        .is_ok_and(|c| c.chain_scan["autoNetworkUncertain"] == true);
                    if uncertain {
                        // This is only a low-cost path check, not proof that any ISP route works.
                        let url = if io.isolated {
                            &targets.latency
                        } else {
                            "https://www.baidu.com"
                        };
                        let ok = Client::builder()
                            .no_proxy()
                            .timeout(Duration::from_secs(4))
                            .redirect(reqwest::redirect::Policy::none())
                            .build()
                            .and_then(|client| client.get(url).send())
                            .is_ok_and(|response| response.status().is_success());
                        if !ok {
                            break;
                        }
                    }
                }
                if jobs.chain_connect_active.load(Ordering::SeqCst)
                    || jobs.speed_active.load(Ordering::SeqCst)
                    || jobs.risk_active.load(Ordering::SeqCst)
                    || jobs.udp_active.load(Ordering::SeqCst)
                {
                    std::thread::sleep(Duration::from_millis(100));
                    continue;
                }
                let priority = jobs
                    .chain_priority
                    .lock()
                    .map_err(|_| anyhow::anyhow!("重测队列不可用。"))?
                    .pop_front();
                let prioritized = priority.is_some();
                let node = if let Some(key) = priority {
                    // Move the existing finite-scan candidate forward, rather than
                    // adding a duplicate sample and inflating completion counts.
                    if mode != "continuous" {
                        queue.retain(|n| n["identityKey"] != key);
                    }
                    active_nodes
                        .iter()
                        .find(|n| n["identityKey"] == key)
                        .cloned()
                } else if mode == "continuous" {
                    let c = core
                        .lock()
                        .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
                    let eligible = active_nodes
                        .iter()
                        .filter(|n| !skipped.contains(n["identityKey"].as_str().unwrap_or("")))
                        .cloned()
                        .collect::<Vec<_>>();
                    if automatic {
                        let preferred = if turn == 0 {
                            let selected = c.engine.store.settings()?["selectedProxy"].clone();
                            eligible
                                .iter()
                                .find(|n| {
                                    n["identityKey"] == c.chain_scan["connectedIdentityKey"]
                                        && n["name"] == selected
                                })
                                .map(|n| n["identityKey"].clone())
                                .unwrap_or(Value::Null)
                        } else if turn == 1 {
                            crate::chain_scan::ranked(&c.chain_scan, "balanced")?["recommendedIdentityKey"].clone()
                        } else {
                            Value::Null
                        };
                        chain_automatic::next_automatic_candidate(
                            &eligible,
                            c.chain_scan["results"]
                                .as_array()
                                .map(Vec::as_slice)
                                .unwrap_or_default(),
                            &preferred,
                        )
                    } else {
                        crate::chain_scan::next_candidate(
                            &eligible,
                            c.chain_scan["results"]
                                .as_array()
                                .map(Vec::as_slice)
                                .unwrap_or_default(),
                            turn,
                        )
                    }
                } else {
                    queue.pop_front()
                };
                let Some(node) = node else {
                    if automatic {
                        break;
                    }
                    if mode != "continuous" {
                        break;
                    }
                    let until = Instant::now() + interval;
                    while keep_running()
                        && current()
                        && Instant::now() < until
                        && jobs.chain_priority.lock().is_ok_and(|q| q.is_empty())
                    {
                        std::thread::sleep(interval.min(Duration::from_secs(1)));
                    }
                    skipped.clear();
                    continue;
                };
                let server = node["scanServer"].as_str().unwrap_or("");
                let address_key = crate::storage::sha256(server.as_bytes());
                let ip_key = crate::chain_scan::proxy_ip_key(server, io.isolated);
                if mode != "full" && !force_retest && !prioritized && !automatic {
                    let mut c = core
                        .lock()
                        .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
                    let cached = c.chain_scan["rejectedResults"]
                        .as_array()
                        .and_then(|rows| {
                            rows.iter()
                                .find(|r| r["identityKey"] == node["identityKey"])
                        })
                        .cloned();
                    if let Some(mut row) = cached.filter(|r| {
                        crate::chain_scan::skip_rejected(r, &address_key, ip_key.as_deref())
                    }) {
                        // A previously unknown address can now be pinned without a
                        // new quality test. Do not refresh testedAt or observationCount.
                        if row["proxyIpKey"].is_null() {
                            row["proxyIpKey"] = json!(ip_key);
                        }
                        row["cachedSkip"] = json!(true);
                        if let Some(rows) = c.chain_scan["rejectedResults"].as_array_mut() {
                            if let Some(old) = rows
                                .iter_mut()
                                .find(|r| r["identityKey"] == node["identityKey"])
                            {
                                *old = row.clone();
                            }
                        }
                        let rows = c.chain_scan["results"]
                            .as_array_mut()
                            .context("结果缓存无效。")?;
                        if let Some(old) = rows
                            .iter_mut()
                            .find(|r| r["identityKey"] == node["identityKey"])
                        {
                            *old = row;
                        } else {
                            rows.push(row);
                        }
                        c.record_chain_progress(&node, None);
                        c.save_chain_cache()?;
                        skipped.insert(node["identityKey"].as_str().unwrap_or("").to_owned());
                        continue;
                    }
                }
                let lease = jobs
                    .probe_gate
                    .lock()
                    .map_err(|_| anyhow::anyhow!("检测入口不可用。"))?;
                if !current() {
                    if prioritized {
                        jobs.requeue_chain_priority(node["identityKey"].as_str().unwrap_or(""));
                    } else if mode != "continuous" {
                        queue.push_front(node);
                    }
                    drop(lease);
                    continue;
                }
                if jobs.chain_connect_active.load(Ordering::SeqCst) {
                    if prioritized {
                        jobs.requeue_chain_priority(node["identityKey"].as_str().unwrap_or(""));
                    } else if mode != "continuous" {
                        queue.push_front(node);
                    }
                    drop(lease);
                    std::thread::sleep(Duration::from_millis(100));
                    continue;
                }
                let sample_started = Instant::now();
                let sampling = ChainSampling(jobs.clone());
                {
                    let mut c = core
                        .lock()
                        .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
                    jobs.chain_sampling.store(true, Ordering::SeqCst);
                    c.chain_scan["testing"] = json!(true);
                    c.chain_scan["currentNode"] = node["name"].clone();
                    c.chain_scan["currentIdentityKey"] = node["identityKey"].clone();
                    c.chain_scan["currentSampleStartedAt"] = json!(now());
                    c.chain_scan["sampleStage"] = json!("preparing");
                    c.chain_scan["nextTestAt"] = Value::Null;
                }
                let mut result = if io
                    .api(
                        "PUT",
                        &format!("/proxies/{}", encode(crate::static_exit::SCAN_FRONT)),
                        Some(&json!({"name":node["name"]})),
                    )
                    .is_ok()
                {
                    crate::chain_scan::measure(
                        port,
                        &node,
                        &targets,
                        &expected,
                        current,
                        |stage, attempt, total| {
                            if let Ok(mut c) = core.lock() {
                                if c.chain_scan["id"] == id && c.chain_scan["testing"] == true {
                                    c.chain_scan["sampleStage"] = json!(stage);
                                    c.chain_scan["stageAttempt"] = json!(attempt);
                                    c.chain_scan["stageTotal"] = json!(total);
                                }
                            }
                        },
                    )
                } else {
                    crate::chain_scan::failed(&node, "selector-failed")
                };
                result["proxyAddressKey"] = json!(address_key);
                result["proxyIpKey"] = json!(ip_key);
                let sample_passed = result["status"] == "available";
                if !current() {
                    if prioritized {
                        jobs.requeue_chain_priority(node["identityKey"].as_str().unwrap_or(""));
                    } else if mode != "continuous" {
                        queue.push_front(node);
                    }
                    continue;
                }
                {
                    let mut c = core
                        .lock()
                        .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
                    let previous_failure =
                        c.chain_scan["rejectedResults"].as_array().and_then(|rows| {
                            rows.iter()
                                .find(|r| r["identityKey"] == node["identityKey"])
                        });
                    crate::chain_scan::set_retry(&mut result, previous_failure, chrono::Utc::now());
                    result["comparisonRound"] = json!(id);
                    result["measurementContext"] = c.chain_cache_key.clone();
                    // Write immutable evidence before replacing the current ranking row.
                    if automatic && result["status"] != "available" {
                        result["environmentUncertain"] = json!(true);
                        auto_failures += 1;
                        if auto_failures >= 2 {
                            c.chain_scan["autoNetworkUncertain"] = json!(true);
                        }
                    } else if automatic && result["status"] == "available" {
                        auto_failures = 0;
                        c.chain_scan["autoNetworkUncertain"] = json!(false);
                    }
                    chain_history::append(
                        &c.engine.store,
                        &id,
                        &c.chain_cache_key,
                        &result,
                        false,
                    )?;
                    let preserve = automatic
                        && result["status"] != "available"
                        && c.chain_scan["results"].as_array().is_some_and(|rows| {
                            rows.iter().any(|r| {
                                r["identityKey"] == node["identityKey"]
                                    && r["status"] == "available"
                            })
                        });
                    if preserve {
                        if let Some(old) = c.chain_scan["results"].as_array_mut().and_then(|rows| {
                            rows.iter_mut()
                                .find(|r| r["identityKey"] == node["identityKey"])
                        }) {
                            old["environmentUncertain"] = json!(true);
                        }
                    } else {
                        crate::chain_scan::upsert(
                            c.chain_scan["results"]
                                .as_array_mut()
                                .context("结果缓存无效。")?,
                            result.clone(),
                        );
                    }
                    if result["status"] == "available" {
                        // A complete route can be used while the wider comparison continues.
                        c.chain_scan["cacheUsable"] = json!(true);
                    }
                    let rejected = c.chain_scan["rejectedResults"]
                        .as_array_mut()
                        .context("失败缓存无效。")?;
                    rejected.retain(|r| r["identityKey"] != node["identityKey"]);
                    if crate::chain_scan::rejected(&result) {
                        rejected.push(result);
                    }
                    if automatic {
                        c.chain_scan["lastAutomaticSampleAt"] = json!(now());
                        c.chain_scan["lastAutomaticBatchAt"] =
                            c.chain_scan["lastAutomaticSampleAt"].clone();
                    }
                    c.record_chain_progress(
                        &node,
                        Some(sample_started.elapsed().as_secs_f64() * 1000.0),
                    );
                    c.chain_scan["completed"] =
                        json!(c.chain_scan["completed"].as_u64().unwrap_or(0) + 1);
                    c.chain_scan["testing"] = json!(false);
                    c.chain_scan["currentNode"] = Value::Null;
                    c.save_chain_cache()?;
                }
                drop(sampling);
                drop(lease);
                turn += 1;
                if mode == "quick" && sample_passed {
                    if let Ok(mut c) = core.lock() {
                        let processed = c.chain_scan["processedIdentityKeys"].clone();
                        c.chain_scan["total"] = json!(processed.as_array().map_or(0, Vec::len));
                        c.chain_scan["taskIdentityKeys"] = processed;
                    }
                    break;
                }
                if automatic {
                    skipped.insert(node["identityKey"].as_str().unwrap_or("").to_owned());
                    if turn >= 3 || auto_failures >= 2 {
                        break;
                    }
                }
                // Finish a bounded automatic batch together, then release its
                // private engine. Only manual continuous scans wait a minute.
                if mode == "continuous" && !automatic {
                    skipped.clear();
                    {
                        if let Ok(mut c) = core.lock() {
                            c.chain_scan["nextTestAt"] = json!(
                                (chrono::Utc::now()
                                    + chrono::Duration::milliseconds(interval.as_millis() as i64))
                                .to_rfc3339()
                            );
                        }
                    }
                    let until = Instant::now() + interval;
                    while keep_running()
                        && current()
                        && Instant::now() < until
                        && jobs.chain_priority.lock().is_ok_and(|q| q.is_empty())
                    {
                        std::thread::sleep(interval.min(Duration::from_secs(1)));
                    }
                }
            }
            Ok(())
        }));
        if let Ok(mut c) = core.lock() {
            if let Ok(mut priority) = jobs.chain_priority.lock() {
                priority.clear();
            }
            if let Some(probe) = c.chain_probe.take() {
                if let Ok(mut probe) = probe.lock() {
                    probe.stop();
                }
            }
            c.chain_scan["running"] = json!(false);
            c.chain_scan["testing"] = json!(false);
            c.chain_scan["currentNode"] = Value::Null;
            c.chain_scan["nextTestAt"] = Value::Null;
            let reason = if jobs.shutdown.load(Ordering::SeqCst) {
                "shutdown"
            } else if jobs.cancelled("chain") {
                "user-paused"
            } else if !c.chain_configuration_current() {
                "configuration-changed"
            } else if !matches!(outcome, Ok(Ok(()))) {
                "error"
            } else {
                "completed"
            };
            let cancelled = reason != "completed";
            c.chain_scan["cancelled"] = json!(cancelled);
            c.chain_scan["waitingReason"] = Value::Null;
            c.chain_scan["stopReason"] = json!(reason);
            c.log("info", &format!("ISP 测试结束：{reason}。"));
            c.chain_scan["finishedAt"] = json!(now());
            if !matches!(outcome, Ok(Ok(()))) {
                c.chain_scan["error"] = json!("后台测试未完成，请重试。");
            }
            if mode == "full" && !cancelled && c.chain_scan["error"].is_null() {
                c.chain_scan["cacheUsable"] = json!(true);
                c.chain_scan["baselineReady"] = json!(c.chain_scan["baselineEligible"] == true);
                c.chain_scan["autoNetworkUncertain"] = json!(false);
            }
            c.refresh_maintenance_candidates(!automatic);
            c.chain_scan["baselineReady"] = json!(chain_automatic::baseline_ready(&c));
            if c.save_chain_cache().is_err() {
                c.chain_scan["error"] = json!("测试结果暂未保存，请检查数据目录。");
            }
        }
    });
    Ok(reply)
}
