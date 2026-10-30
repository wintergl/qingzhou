use anyhow::{Context, Result};
use serde_json::{Value, json};
use splitvpn_core::{
    Core, Events, Jobs,
    runtime::{prepare_network_request, start_batch, start_chain_scan},
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
    core.lock().unwrap().publish_read_views();
    let queue = Arc::new(splitvpn_core::dispatch::Dispatch::default());
    let worker_queue = queue.clone();
    let worker_core = core.clone();
    let worker_out = out.clone();
    let worker_jobs = jobs.clone();
    let worker = std::thread::spawn(move || {
        let mut network_tasks: Vec<std::thread::JoinHandle<()>> = Vec::new();
        while let Some(request) = worker_queue.pop() {
            let id = request["id"].clone();
            let channel = request["channel"].as_str().unwrap();
            let payload = request.get("payload").cloned().unwrap_or_else(|| json!({}));
            if matches!(
                channel,
                "subscription:update"
                    | "static-exit:test"
                    | "chain-scan:connect"
                    | "chain-scan:use"
                    | "connectivity:check"
                    | "connectivity:test-website-speeds"
                    | "nodes:test"
                    | "nodes:test-recommended"
                    | "nodes:check-risk"
                    | "nodes:check-current-risk"
                    | "nodes:test-udp"
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
            let result = if channel == "chain-scan:start" {
                start_chain_scan(worker_core.clone(), payload)
            } else if let Some(kind) = channel
                .strip_prefix("nodes:start-")
                .and_then(|s| s.strip_suffix("-batch"))
                .filter(|s| matches!(*s, "risk" | "speed" | "udp"))
            {
                start_batch(worker_core.clone(), kind.into(), payload)
            } else {
                match worker_core.lock() {
                    Ok(mut c) => {
                        let result = c.handle(channel, &payload);
                        if channel == "vpn:stop" {
                            worker_jobs.stop_requested.store(false, Ordering::SeqCst);
                        }
                        c.publish_read_views();
                        result
                    }
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
        let mut sample_task: Option<std::thread::JoinHandle<()>> = None;
        let mut failover_task: Option<std::thread::JoinHandle<()>> = None;
        let mut diagnostic_tasks: Vec<std::thread::JoinHandle<()>> = Vec::new();
        while !tick_jobs.shutdown.load(Ordering::SeqCst) {
            tick_jobs.wait_background(delay);
            if tick_jobs.shutdown.load(Ordering::SeqCst) {
                return;
            }
            if update.as_ref().is_some_and(|task| task.is_finished()) {
                let _ = update.take().unwrap().join();
            }
            if sample_task.as_ref().is_some_and(|t| t.is_finished()) {
                let _ = sample_task.take().unwrap().join();
            }
            if failover_task.as_ref().is_some_and(|t| t.is_finished()) {
                let _ = failover_task.take().unwrap().join();
            }
            let mut i = 0;
            while i < diagnostic_tasks.len() {
                if diagnostic_tasks[i].is_finished() {
                    let _ = diagnostic_tasks.swap_remove(i).join();
                } else {
                    i += 1;
                }
            }
            let mut diagnostics = Vec::new();
            let mut sample = None;
            let mut chain_automatic = None;
            let mut chain_failover = None;
            let due = match tick_core.try_lock() {
                Ok(mut c) => {
                    c.tick();
                    if failover_task.is_none() {
                        chain_failover = c.take_chain_failover_request();
                    }
                    chain_automatic = c.take_chain_automatic_request();
                    c.publish_read_views();
                    // Both read-only checks start after connection readiness;
                    // a slow connectivity target must not hold up website results.
                    while diagnostic_tasks.len() + diagnostics.len() < 2 {
                        let Some(plan) = c.take_due_diagnostic() else {
                            break;
                        };
                        diagnostics.push(plan);
                    }
                    if sample_task.is_none() {
                        sample = c.take_background_sample();
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
            if let Some(plan) = chain_failover {
                let failover_core = tick_core.clone();
                let failover_jobs = tick_jobs.clone();
                failover_task = Some(std::thread::spawn(move || {
                    let _ = plan.run(&failover_core);
                    failover_jobs.wake_background();
                }));
            }
            if let Some(request) = chain_automatic {
                // Revalidates enable/pause state under the core lock before starting.
                if start_chain_scan(tick_core.clone(), request).is_err() {
                    if let Ok(mut c) = tick_core.lock() {
                        c.chain_auto_error = true;
                    }
                }
            }
            for plan in diagnostics {
                let diagnostic_core = tick_core.clone();
                let diagnostic_jobs = tick_jobs.clone();
                diagnostic_tasks.push(std::thread::spawn(move || {
                    let _ = plan.run(&diagnostic_core);
                    diagnostic_jobs.wake_background();
                }));
            }
            if let Some(sample) = sample {
                let sample_core = tick_core.clone();
                sample_task = Some(std::thread::spawn(move || {
                    let result = sample.run();
                    if let Ok(mut c) = sample_core.lock() {
                        c.complete_background_sample(&sample, result);
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
        if let Some(result) = jobs.cached_read(channel) {
            reply(&out, request["id"].clone(), result);
            continue;
        }
        if channel == "chain-scan:use-state" || channel == "chain-scan:cancel-use" {
            let payload = request.get("payload").cloned().unwrap_or_else(|| json!({}));
            let result = jobs.chain_use_request(channel, &payload);
            reply(&out, request["id"].clone(), result);
            continue;
        }
        if channel == "vpn:stop" {
            jobs.stop_requested.store(true, Ordering::SeqCst);
            jobs.invalidate_diagnostics();
        } else if matches!(
            channel,
            "vpn:start"
                | "vpn:restart"
                | "nodes:select"
                | "nodes:select-v2"
                | "native:network-changed"
                | "network:repair"
        ) || channel == "native:runtime-environment"
            && request["payload"]["sleeping"] == true
        {
            jobs.invalidate_diagnostics();
        }
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
            jobs.cancel_diagnostics();
        }
        match queue.push(request) {
            Ok(cancelled) => {
                for request in cancelled {
                    reply(
                        &out,
                        request["id"].clone(),
                        Err(anyhow::anyhow!("操作已被断开请求取消。")),
                    );
                }
            }
            Err(request) => reply(
                &out,
                request["id"].clone(),
                Err(anyhow::anyhow!("后台任务较多，请稍后重试。")),
            ),
        }
    }
    queue.close();
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
