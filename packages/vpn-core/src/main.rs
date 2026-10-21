use anyhow::{Context, Result};
use serde_json::{Value, json};
use splitvpn_core::{
    Core, Events, Jobs,
    runtime::{prepare_network_request, start_batch},
    storage::redact,
};
use std::{
    io::{BufRead, Read, Write},
    path::PathBuf,
    sync::{Arc, Mutex, atomic::Ordering},
    time::Duration,
};

fn output(out: &Arc<Mutex<std::io::Stdout>>, value: Value) {
    if let Ok(mut out) = out.lock() {
        if serde_json::to_writer(&mut *out, &value).is_ok() {
            let _ = out.write_all(b"\n");
            let _ = out.flush();
        }
    }
}
fn reply(out: &Arc<Mutex<std::io::Stdout>>, id: Value, result: Result<Value>) {
    match result {
        Ok(value) => output(out, json!({"id":id,"ok":true,"data":value})),
        Err(error) => output(
            out,
            json!({"id":id,"ok":false,"error":{
            "code":"CORE_OPERATION_FAILED","message":redact(&error.to_string())}}),
        ),
    }
}
fn run() -> Result<()> {
    let isolated = std::env::var("SPLITVPN_ISOLATED").is_ok_and(|s| s == "1");
    let data = std::env::var_os("SPLITVPN_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            if cfg!(target_os = "macos") {
                PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                    .join("Library/Application Support/@split-vpn/desktop")
            } else if cfg!(windows) {
                PathBuf::from(std::env::var_os("APPDATA").unwrap_or_default())
                    .join("@split-vpn/desktop")
            } else {
                PathBuf::from(std::env::var_os("XDG_CONFIG_HOME").unwrap_or_else(|| {
                    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                        .join(".config")
                        .into_os_string()
                }))
                .join("split-vpn")
            }
        });
    anyhow::ensure!(
        !isolated || std::env::var_os("SPLITVPN_DATA_DIR").is_some(),
        "隔离模式需要独立的数据目录。"
    );
    let _backend_lock = splitvpn_core::platform::BackendLock::acquire(
        &splitvpn_core::storage::Storage::new(data.clone()),
    )?;
    let resources = std::env::var_os("SPLITVPN_RESOURCES")
        .map(PathBuf::from)
        .unwrap_or(
            std::env::current_exe()?
                .parent()
                .context("后台路径无效。")?
                .to_path_buf(),
        );
    let out = Arc::new(Mutex::new(std::io::stdout()));
    let event_out = out.clone();
    let events: Events =
        Arc::new(move |event, data| output(&event_out, json!({"event":event,"data":data})));
    let jobs = Arc::new(Jobs::default());
    let core = Arc::new(Mutex::new(Core::new(
        data,
        resources,
        isolated,
        events,
        jobs.clone(),
    )?));
    let (tx, rx) = std::sync::mpsc::sync_channel::<Value>(64);
    let worker_core = core.clone();
    let worker_out = out.clone();
    let worker_jobs = jobs.clone();
    let worker = std::thread::spawn(move || {
        let mut network_tasks: Vec<std::thread::JoinHandle<()>> = Vec::new();
        for request in rx {
            let id = request["id"].clone();
            let channel = request["channel"].as_str().unwrap();
            let payload = request.get("payload").cloned().unwrap_or_else(|| json!({}));
            if matches!(
                channel,
                "subscription:update" | "connectivity:check" | "connectivity:test-website-speeds"
            ) {
                network_tasks.retain(|t| !t.is_finished());
                if network_tasks.len() >= 8 {
                    reply(
                        &worker_out,
                        id,
                        Err(anyhow::anyhow!("网络任务较多，请稍后重试。")),
                    );
                    continue;
                }
                match prepare_network_request(&worker_core, channel, &payload).unwrap() {
                    Ok(task) => {
                        let task_core = worker_core.clone();
                        let task_out = worker_out.clone();
                        network_tasks.push(std::thread::spawn(move || {
                            reply(&task_out, id, task.run(&task_core))
                        }));
                    }
                    Err(error) => reply(&worker_out, id, Err(error)),
                }
                continue;
            }
            let result = if let Some(kind) = channel
                .strip_prefix("nodes:start-")
                .and_then(|s| s.strip_suffix("-batch"))
                .filter(|s| matches!(*s, "risk" | "speed" | "udp"))
            {
                start_batch(worker_core.clone(), kind.into(), payload)
            } else {
                match worker_core.lock() {
                    Ok(mut c) => c.handle(channel, &payload),
                    Err(_) => Err(anyhow::anyhow!("后台状态不可用。")),
                }
            };
            reply(&worker_out, id, result);
            if matches!(
                channel,
                "vpn:start"
                    | "vpn:stop"
                    | "vpn:restart"
                    | "native:startup-connect"
                    | "native:company-apply"
                    | "native:company-remove"
            ) {
                worker_jobs.wake_background();
            }
        }
        worker_jobs.shutdown.store(true, Ordering::SeqCst);
        worker_jobs.wake_background();
        worker_jobs.cancel_all();
        // Wait only for commits already past their shutdown check (they hold the
        // lock). Downloads still in flight are abandoned instead of blocking exit.
        drop(worker_core.lock());
        drop(network_tasks);
    });
    let tick_core = core.clone();
    let tick_jobs = jobs.clone();
    let background = std::thread::spawn(move || {
        let mut delay = Duration::from_secs(1);
        let mut update: Option<std::thread::JoinHandle<()>> = None;
        let mut recovery_check: Option<std::thread::JoinHandle<()>> = None;
        while !tick_jobs.shutdown.load(Ordering::SeqCst) {
            tick_jobs.wait_background(delay);
            if tick_jobs.shutdown.load(Ordering::SeqCst) {
                return;
            }
            if update.as_ref().is_some_and(|task| task.is_finished()) {
                let _ = update.take().unwrap().join();
            }
            if recovery_check
                .as_ref()
                .is_some_and(|task| task.is_finished())
            {
                let _ = recovery_check.take().unwrap().join();
            }
            let mut check = None;
            let due = match tick_core.try_lock() {
                Ok(mut c) => {
                    c.tick();
                    if recovery_check.is_none() {
                        check = c.take_recovery_check();
                    }
                    delay = c.background_interval();
                    if update.is_none() {
                        c.due_subscription_downloads()
                    } else {
                        None
                    }
                }
                Err(_) => {
                    delay = Duration::from_secs(1);
                    None
                }
            };
            if let Some((id, pid, check)) = check {
                let check_core = tick_core.clone();
                recovery_check = Some(std::thread::spawn(move || {
                    let ok = check.recovery_connectivity();
                    if let Ok(mut c) = check_core.lock() {
                        c.complete_recovery_check(id, pid, ok);
                    }
                }));
            }
            // Downloads must not block either UI requests or path recovery.
            // Only one automatic batch exists; shutdown abandons in-flight I/O.
            if let Some((due, mixed)) = due {
                let update_core = tick_core.clone();
                let update_jobs = tick_jobs.clone();
                update = Some(std::thread::spawn(move || {
                    let mut downloaded = Vec::new();
                    for (id, url) in due {
                        if update_jobs.shutdown.load(Ordering::SeqCst) {
                            return;
                        }
                        let result = splitvpn_core::subscription::download(&url, mixed);
                        downloaded.push((id, url, result));
                    }
                    if let Ok(mut c) = update_core.lock() {
                        c.apply_downloaded_subscriptions(downloaded);
                    }
                }));
            }
        }
    });
    let stdin = std::io::stdin();
    let mut input = stdin.lock();
    loop {
        let mut bytes = Vec::new();
        let count = input
            .by_ref()
            .take(2 * 1024 * 1024 + 1)
            .read_until(b'\n', &mut bytes)?;
        if count == 0 {
            break;
        }
        if bytes.len() > 2 * 1024 * 1024 {
            output(
                &out,
                json!({"id":null,"ok":false,"error":{"message":"请求超过 2 MB。"}}),
            );
            break;
        }
        let request: Value = match serde_json::from_slice(&bytes) {
            Ok(v) => v,
            Err(_) => {
                output(
                    &out,
                    json!({"id":null,"ok":false,"error":{"message":"请求需要有效 JSON。"}}),
                );
                continue;
            }
        };
        let Some(channel) = request["channel"]
            .as_str()
            .filter(|_| request["id"].is_string())
        else {
            output(
                &out,
                json!({"id":request["id"],"ok":false,"error":{"message":"请求缺少 id 或 channel。"}}),
            );
            continue;
        };
        if let Some(kind) = channel
            .strip_prefix("nodes:cancel-")
            .and_then(|s| s.strip_suffix("-batch"))
            .filter(|s| matches!(*s, "risk" | "speed" | "udp"))
        {
            jobs.cancel(kind);
            output(&out, json!({"id":request["id"],"ok":true,"data":true}));
            continue;
        }
        if matches!(
            channel,
            "vpn:stop"
                | "vpn:restart"
                | "nodes:select"
                | "nodes:select-v2"
                | "native:company-remove"
                | "network:repair"
        ) {
            jobs.cancel_all();
        }
        if tx.send(request).is_err() {
            break;
        }
    }
    drop(tx);
    let _ = worker.join();
    jobs.shutdown.store(true, Ordering::SeqCst);
    jobs.wake_background();
    jobs.cancel_all();
    let _ = background.join();
    // A batch can still be restoring its outlet when the UI closes stdin.
    // Taking this lock waits for that request before removing company routing.
    if let Ok(mut c) = core.lock() {
        c.shutdown();
    }
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("{}", redact(&error.to_string()));
        std::process::exit(1);
    }
}
