//! Mobile diagnostics use dedicated listeners. They never change the business
//! selector while measuring a candidate, and reject observations from old runs.
use super::{string, transaction};
use crate::{
    chain_scan, network,
    runtime::NetworkCheck,
    static_exit,
    storage::{Storage, now},
};
use anyhow::{Context, Result, bail, ensure};
use reqwest::blocking::Client;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::Read,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

#[derive(Clone)]
struct ContextToken {
    profile: Value,
    epoch: String,
    revision: String,
}
struct Scan {
    id: String,
    token: ContextToken,
    nodes: Vec<Value>,
    budget: usize,
    state: Value,
    cancelled: Arc<AtomicBool>,
    busy: bool,
}
static PROBE: Mutex<()> = Mutex::new(());
static SCANS: OnceLock<Mutex<HashMap<String, Scan>>> = OnceLock::new();
fn isolated() -> bool {
    std::env::var("SPLITVPN_ISOLATED").is_ok_and(|v| v == "1")
}
fn scans() -> &'static Mutex<HashMap<String, Scan>> {
    SCANS.get_or_init(Default::default)
}
fn key(store: &Storage) -> String {
    store.root.to_string_lossy().into_owned()
}
fn token(store: &Storage, p: &Value) -> Result<ContextToken> {
    let profile = store.read("runtime-state/mobile-profile.json", Value::Null)?;
    let revision = string(p, "runtimeRevision")?.to_owned();
    let epoch = string(p, "networkEpoch")?.to_owned();
    ensure!(
        p["connected"] == true && profile["revision"] == revision,
        "当前运行配置与保存配置不同，请等待重载完成或重新连接。"
    );
    ensure!(
        profile["settingsKey"] == super::profile::settings_key(&store.settings()?)?
            && profile["manifestRevision"] == store.manifest()?["revision"]
            && profile["companyKey"] == super::company::record_key(store)?,
        "配置或订阅已变化，请先应用配置。"
    );
    let context = ContextToken {
        profile,
        revision,
        epoch,
    };
    store.write(
        "runtime-state/mobile-active.json",
        &json!({"revision":context.revision,"epoch":context.epoch}),
    )?;
    Ok(context)
}
fn current(store: &Storage, token: &ContextToken) -> bool {
    let Ok(_guard) = transaction(store) else {
        return false;
    };
    let check = || -> Result<bool> {
        let active = store.read("runtime-state/mobile-active.json", Value::Null)?;
        let profile = store.read("runtime-state/mobile-profile.json", Value::Null)?;
        Ok(active["revision"] == token.revision
            && active["epoch"] == token.epoch
            && profile["revision"] == token.revision
            && profile["settingsKey"] == super::profile::settings_key(&store.settings()?)?
            && profile["manifestRevision"] == store.manifest()?["revision"]
            && profile["companyKey"] == super::company::record_key(store)?)
    };
    check().unwrap_or(false)
}
fn api(t: &ContextToken, method: &str, path: &str, body: Option<Value>) -> Result<Value> {
    let port = t.profile["controller"].as_u64().context("控制器不可用。")?;
    let client = Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(5))
        .build()?;
    let mut req = client
        .request(method.parse()?, format!("http://127.0.0.1:{port}{path}"))
        .bearer_auth(t.profile["secret"].as_str().unwrap_or(""));
    if let Some(body) = body {
        req = req.json(&body);
    }
    let response = req.send()?.error_for_status()?;
    if response.status().as_u16() == 204 {
        return Ok(Value::Null);
    }
    let mut bytes = Vec::new();
    response.take(1024 * 1024 + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= 1024 * 1024, "控制器响应过大。");
    if bytes.is_empty() {
        Ok(Value::Null)
    } else {
        Ok(serde_json::from_slice(&bytes)?)
    }
}
fn select(t: &ContextToken, group: &str, tag: &str) -> Result<()> {
    let group: String = url::form_urlencoded::byte_serialize(group.as_bytes()).collect();
    let path = format!("/proxies/{group}");
    api(t, "PUT", &path, Some(json!({"name":tag})))?;
    ensure!(
        api(t, "GET", &path, None)?["now"] == tag,
        "检测选择器未切换到目标节点。"
    );
    Ok(())
}
fn check(t: &ContextToken) -> NetworkCheck {
    NetworkCheck::mobile(
        t.profile["current"].as_u64().unwrap_or(9092) as u16,
        t.profile["selectedTag"].clone(),
    )
}
fn targets(_store: &Storage, p: &Value) -> Result<chain_scan::Targets> {
    let mut targets = chain_scan::Targets::default();
    if let Some(values) = p["testTargets"].as_object() {
        ensure!(isolated(), "仅隔离测试允许覆盖检测地址。");
        let read = |key: &str| -> Result<String> {
            let value = values
                .get(key)
                .and_then(Value::as_str)
                .context("缺少回环检测地址。")?;
            let url = url::Url::parse(value)?;
            ensure!(
                url.scheme() == "http" && matches!(url.host_str(), Some("127.0.0.1" | "::1")),
                "测试只能访问回环地址。"
            );
            Ok(value.to_owned())
        };
        targets.latency = read("latency")?;
        targets.download = read("download")?;
        targets.ip = read("ip")?;
    } else if let Some(url) = p["testUrl"].as_str() {
        ensure!(isolated(), "仅隔离测试允许覆盖检测地址。");
        let parsed = url::Url::parse(url)?;
        ensure!(
            parsed.scheme() == "http" && matches!(parsed.host_str(), Some("127.0.0.1" | "::1")),
            "测试只能访问回环地址。"
        );
        targets.latency = url.into();
        targets.download = url.into();
        targets.ip = url.into();
    } else {
        ensure!(!isolated(), "隔离检测需要回环测试地址。");
    }
    Ok(targets)
}
fn bounded_json(response: reqwest::blocking::Response) -> Result<Value> {
    let mut bytes = Vec::new();
    response
        .error_for_status()
        .context("检测服务返回错误状态。")?
        .take(256 * 1024 + 1)
        .read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= 256 * 1024, "检测响应过大。");
    Ok(serde_json::from_slice(&bytes)?)
}

pub(super) fn handles(channel: &str) -> bool {
    channel.starts_with("mobile:diagnostics:")
        || channel.starts_with("mobile:chain:")
        || channel == "mobile:runtime:invalidate"
}
pub(super) fn handle(store: &Storage, channel: &str, p: &Value) -> Result<Value> {
    if channel == "mobile:runtime:invalidate" {
        {
            let _guard = transaction(store)?;
            if let Some(expected) = p["expectedEpoch"].as_str() {
                let active = store.read("runtime-state/mobile-active.json", Value::Null)?;
                if active["epoch"] != expected {
                    return Ok(json!({"invalidated":false}));
                }
            }
            store.write("runtime-state/mobile-active.json", &Value::Null)?;
        }
        if let Some(scan) = scans().lock().unwrap().get_mut(&key(store)) {
            scan.cancelled.store(true, Ordering::SeqCst);
            scan.state["running"] = json!(false);
            scan.state["cancelled"] = json!(true);
        }
        return Ok(json!({"invalidated":true}));
    }
    if channel == "mobile:chain:cancel" {
        if let Some(scan) = scans().lock().unwrap().get_mut(&key(store)) {
            ensure!(scan.id == string(p, "id")?, "测试任务已变化。");
            scan.cancelled.store(true, Ordering::SeqCst);
            scan.state["running"] = json!(false);
            scan.state["cancelled"] = json!(true);
            return Ok(scan.state.clone());
        }
        return Ok(chain_scan::idle());
    }
    if channel == "mobile:chain:history" {
        let _guard = transaction(store)?;
        let rows = store.read("cache/mobile-chain-history.json", json!([]))?;
        let offset = p["offset"].as_u64().unwrap_or(0) as usize;
        let limit = p["limit"].as_u64().unwrap_or(30).clamp(1, 100) as usize;
        let rows = rows.as_array().context("历史记录格式无效。")?;
        return Ok(
            json!({"items":rows.iter().rev().skip(offset).take(limit).collect::<Vec<_>>(),"total":rows.len(),"offset":offset}),
        );
    }
    if channel == "mobile:chain:get" {
        let memory = scans()
            .lock()
            .unwrap()
            .get(&key(store))
            .map(|s| s.state.clone());
        let mut state =
            memory.unwrap_or(store.read("cache/mobile-chain.json", chain_scan::idle())?);
        let profile = store.read("runtime-state/mobile-profile.json", Value::Null)?;
        if state["scanKey"] != profile["scanKey"] {
            state["stale"] = json!(true);
            if let Some(rows) = state["results"].as_array_mut() {
                for row in rows {
                    row["otherEnvironment"] = json!(true);
                }
            }
        }
        return chain_scan::ranked(&state, p["strategy"].as_str().unwrap_or("balanced"));
    }
    let t = {
        let _guard = transaction(store)?;
        token(store, p)?
    };
    if channel == "mobile:diagnostics:cached" {
        let cached = store.read("cache/mobile-diagnostics.json", json!({}))?;
        return Ok(
            if cached["revision"] == t.revision && cached["epoch"] == t.epoch {
                cached
            } else {
                json!({})
            },
        );
    }
    let targets = targets(store, p)?;
    let output = match channel {
        "mobile:diagnostics:connectivity" => {
            let c = check(&t);
            let fixture = isolated().then_some(targets.latency.as_str());
            let (domestic, foreign) = std::thread::scope(|s| {
                let a = s.spawn(|| c.measure(fixture.unwrap_or("https://www.baidu.com"), false));
                let b = s.spawn(|| {
                    c.measure(
                        fixture.unwrap_or("https://www.google.com/generate_204"),
                        true,
                    )
                });
                (a.join().unwrap(), b.join().unwrap())
            });
            // A loopback HTTP proxy cannot prove that the native system resolver
            // works. Only the native probe supplies that evidence.
            let missing = json!({"ok":false,"error":"尚未取得系统 DNS／ChatGPT 检测结果。","status":"untested"});
            let dns = p.get("systemDns").unwrap_or(&missing);
            let web = p.get("chatgpt").unwrap_or(&missing);
            let ip = chain_scan::verify_ip(
                t.profile["current"].as_u64().unwrap() as u16,
                &targets.ip,
                "",
            )
            .ok();
            json!({"connectivity":network::complete_connectivity(&domestic,&foreign,dns,web,json!(ip)),"checkedAt":now()})
        }
        "mobile:diagnostics:websites" => {
            if isolated() {
                json!({"results":[check(&t).measure(&targets.latency,true)],"checkedAt":now()})
            } else {
                check(&t).websites()?
            }
        }
        "mobile:diagnostics:node" => {
            let _probe = PROBE
                .try_lock()
                .map_err(|_| anyhow::anyhow!("已有节点检测正在进行。"))?;
            let identity = string(p, "identityKey")?;
            let tag = t.profile["nodes"][identity]
                .as_str()
                .context("节点已失效或当前平台不支持。")?;
            select(&t, "PROBE", tag)?;
            let c = NetworkCheck::mobile(
                t.profile["probe"].as_u64().context("缺少节点检测入口。")? as u16,
                json!(tag),
            );
            let mut result = c.measure(
                if isolated() {
                    &targets.latency
                } else {
                    "https://www.gstatic.com/generate_204"
                },
                true,
            );
            result["identityKey"] = json!(identity);
            result
        }
        "mobile:diagnostics:risk" => {
            let secret = string(p, "apiKey")?;
            let client = Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(8))
                .proxy(reqwest::Proxy::all(format!(
                    "http://127.0.0.1:{}",
                    t.profile["current"]
                ))?)
                .build()?;
            let url = if isolated() {
                targets.ip.clone()
            } else {
                "https://api.ipdata.co/".into()
            };
            let profile = bounded_json(
                client
                    .get(url)
                    .query(&[("api-key", secret)])
                    .send()
                    .context("风险服务请求失败。")?,
            )?;
            ensure!(
                profile["ip"]
                    .as_str()
                    .is_some_and(|v| v.parse::<std::net::IpAddr>().is_ok()),
                "风险服务未返回有效出口 IP。"
            );
            let mut risk = crate::runtime::risk_result(
                t.profile["selectedTag"].as_str().unwrap_or("当前出口"),
                &profile,
            );
            risk["country"] = profile["country_name"].clone();
            risk["organization"] = profile["asn"]["name"].clone();
            risk["viaStaticExit"] = json!(store.settings()?["staticExit"]["enabled"] == true);
            risk
        }
        "mobile:chain:start" => {
            ensure!(
                t.profile["scan"].is_number(),
                "请先保存 ISP 配置及密码并应用配置，再测试线路。"
            );
            let mode = p["mode"].as_str().unwrap_or("quick");
            ensure!(
                matches!(mode, "quick" | "full" | "continuous" | "maintenance"),
                "测试模式无效。"
            );
            let nodes = {
                let _guard = transaction(store)?;
                super::nodes(store)?
            };
            let mut nodes: Vec<_> = nodes
                .into_iter()
                .filter(|n| {
                    n["identityAmbiguous"] != true
                        && t.profile["nodes"][n["identityKey"].as_str().unwrap_or("")].is_string()
                        && (!p["subscriptionId"].is_string()
                            || p["subscriptionId"] == n["subscriptionId"])
                })
                .collect();
            ensure!(!nodes.is_empty(), "此范围内没有可测试节点。");
            let previous = store.read("cache/mobile-chain.json", chain_scan::idle())?;
            let rows = if previous["scanKey"] == t.profile["scanKey"] {
                previous["results"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|r| nodes.iter().any(|n| n["identityKey"] == r["identityKey"]))
                    .collect::<Vec<_>>()
            } else {
                vec![]
            };
            if mode == "maintenance" {
                ensure!(!rows.is_empty(), "请先手动完整测试一轮，再使用少量复测。");
                nodes.retain(|n| {
                    rows.iter().any(|r| {
                        r["identityKey"] == n["identityKey"]
                            && (!chain_scan::fresh(r, chrono::Utc::now())
                                || r["status"] != "available")
                    })
                });
            } else if mode == "quick" {
                let ranked = chain_scan::ranked(&json!({"results":rows}), "balanced")?;
                nodes.sort_by_key(|n| {
                    if n["identityKey"] == ranked["recommendedIdentityKey"] {
                        0
                    } else {
                        1
                    }
                });
            }
            let budget = if mode == "maintenance" {
                nodes.len().min(3)
            } else {
                nodes.len()
            };
            let id = uuid::Uuid::new_v4().to_string();
            let state = json!({"id":id,"mode":mode,"scanKey":t.profile["scanKey"],"running":budget>0,"cancelled":false,"completed":0,"total":budget,"results":rows,"startedAt":now(),"stale":false});
            let mut sessions = scans().lock().unwrap();
            if let Some(old) = sessions.get(&key(store)) {
                ensure!(!old.busy, "上一项检测正在退出，请稍后重试。");
                old.cancelled.store(true, Ordering::SeqCst);
            }
            sessions.insert(
                key(store),
                Scan {
                    id,
                    token: t.clone(),
                    nodes,
                    budget,
                    state: state.clone(),
                    cancelled: Arc::new(AtomicBool::new(false)),
                    busy: false,
                },
            );
            state
        }
        "mobile:chain:next" => return scan_next(store, p, &t, &targets),
        "mobile:chain:prepare-use" => {
            let node = {
                let _guard = transaction(store)?;
                super::nodes(store)?
                    .into_iter()
                    .find(|n| {
                        n["identityKey"] == p["identityKey"] && n["identityAmbiguous"] != true
                    })
                    .context("节点已变化。")?
            };
            let tag = t.profile["nodes"][string(&node, "identityKey")?]
                .as_str()
                .context("此节点不支持当前平台。")?;
            ensure!(t.profile["scan"].is_number(), "请先应用 ISP 配置。");
            let busy = {
                let mut sessions = scans().lock().unwrap();
                let scan = sessions.get_mut(&key(store)).context("请先测试线路。")?;
                ensure!(
                    !scan.busy && scan.state["running"] != true,
                    "请先暂停测试。"
                );
                scan.busy = true;
                scan.cancelled = Arc::new(AtomicBool::new(false));
                scan.cancelled.clone()
            };
            let result = (|| {
                select(&t, static_exit::SCAN_FRONT, tag)?;
                chain_scan::recheck(
                    t.profile["scan"].as_u64().unwrap() as u16,
                    &targets.latency,
                    &targets.ip,
                    store.settings()?["staticExit"]["expectedIp"]
                        .as_str()
                        .unwrap_or(""),
                )
            })();
            if let Some(scan) = scans().lock().unwrap().get_mut(&key(store)) {
                scan.busy = false;
            }
            let (ip, latency) = result?;
            ensure!(
                !busy.load(Ordering::SeqCst) && current(store, &t),
                "连接已变化或操作已取消。"
            );
            let ticket = uuid::Uuid::new_v4().to_string();
            {
                let _guard = transaction(store)?;
                store.write("runtime-state/mobile-prepared-use.json",&json!({"ticket":ticket,"identityKey":node["identityKey"],"revision":t.revision,"epoch":t.epoch,"at":chrono::Utc::now().timestamp()}))?;
            }
            json!({"ticket":ticket,"identityKey":node["identityKey"],"nodeName":node["name"],"externalIp":ip,"latencyMs":latency,"verifiedAt":now()})
        }
        "mobile:chain:commit-use" => {
            ensure!(current(store, &t), "连接或配置已变化，请重新复核。");
            let _guard = transaction(store)?;
            let active = store.read("runtime-state/mobile-active.json", Value::Null)?;
            ensure!(
                active["epoch"] == t.epoch
                    && active["revision"] == t.revision
                    && t.profile["settingsKey"]
                        == super::profile::settings_key(&store.settings()?)?,
                "连接或设置已变化，请重新复核。"
            );
            let prepared = store.read("runtime-state/mobile-prepared-use.json", Value::Null)?;
            ensure!(
                prepared["ticket"] == p["ticket"]
                    && prepared["ticket"].is_string()
                    && prepared["revision"] == t.revision
                    && prepared["epoch"] == t.epoch
                    && chrono::Utc::now().timestamp() - prepared["at"].as_i64().unwrap_or(0) <= 60,
                "线路复核已失效，请重新测试。"
            );
            let node = super::nodes(store)?
                .into_iter()
                .find(|n| {
                    n["identityKey"] == prepared["identityKey"] && n["identityAmbiguous"] != true
                })
                .context("节点已失效。")?;
            let mut configuration = store.settings()?["staticExit"].clone();
            configuration["enabled"] = json!(true);
            let result = super::handle(
                store,
                "settings:patch",
                &json!({"staticExit":configuration,"selectedProxy":node["name"],"defaultOutlet":{"kind":"node","name":node["name"],"identityKey":node["identityKey"],"subscriptionId":node["subscriptionId"]}}),
            )?;
            store.write("runtime-state/mobile-prepared-use.json", &Value::Null)?;
            return Ok(result);
        }
        "mobile:diagnostics:verify-exit" => {
            json!({"externalIp":chain_scan::verify_ip(t.profile["current"].as_u64().unwrap() as u16,&targets.ip,store.settings()?["staticExit"]["expectedIp"].as_str().unwrap_or(""))?,"checkedAt":now()})
        }
        _ => bail!("移动端检测通道无效。"),
    };
    ensure!(current(store, &t), "连接或配置已变化，本次结果已丢弃。");
    if channel.starts_with("mobile:diagnostics:") {
        let _guard = transaction(store)?;
        let mut cached = store.read("cache/mobile-diagnostics.json", json!({}))?;
        if cached["revision"] != t.revision || cached["epoch"] != t.epoch {
            cached = json!({"revision":t.revision,"epoch":t.epoch});
        }
        cached[channel.rsplit(':').next().unwrap()] = output.clone();
        store.write("cache/mobile-diagnostics.json", &cached)?;
    }
    Ok(output)
}
fn scan_next(
    store: &Storage,
    p: &Value,
    t: &ContextToken,
    targets: &chain_scan::Targets,
) -> Result<Value> {
    let (id, node, cancelled) = {
        let mut sessions = scans().lock().unwrap();
        let scan = sessions.get_mut(&key(store)).context("请先开始测试。")?;
        ensure!(
            scan.id == string(p, "id")?
                && scan.token.revision == t.revision
                && scan.token.epoch == t.epoch,
            "测试上下文已变化。"
        );
        ensure!(
            !scan.busy && scan.state["running"] == true,
            "测试已停止或正在执行。"
        );
        let index = scan.state["completed"].as_u64().unwrap_or(0) as usize % scan.nodes.len();
        scan.busy = true;
        (
            scan.id.clone(),
            scan.nodes[index].clone(),
            scan.cancelled.clone(),
        )
    };
    let result = (|| -> Result<Value> {
        let tag = t.profile["nodes"][string(&node, "identityKey")?]
            .as_str()
            .context("检测节点已失效。")?;
        select(t, static_exit::SCAN_FRONT, tag)?;
        Ok(chain_scan::measure(
            t.profile["scan"].as_u64().context("缺少检测监听器。")? as u16,
            &node,
            targets,
            store.settings()?["staticExit"]["expectedIp"]
                .as_str()
                .unwrap_or(""),
            || !cancelled.load(Ordering::SeqCst) && current(store, t),
            |_, _, _| {},
        ))
    })();
    let valid = current(store, t) && !cancelled.load(Ordering::SeqCst);
    let mut sessions = scans().lock().unwrap();
    let scan = sessions.get_mut(&key(store)).context("测试任务已结束。")?;
    ensure!(scan.id == id, "测试任务已变化。");
    scan.busy = false;
    if !valid {
        scan.state["running"] = json!(false);
        bail!("连接已变化或测试已取消，结果已丢弃。");
    }
    let row = result.unwrap_or_else(|_| chain_scan::failed(&node, "measurement-failed"));
    let mut rows = scan.state["results"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    chain_scan::upsert(&mut rows, row.clone());
    scan.state["results"] = json!(rows);
    let done = scan.state["completed"].as_u64().unwrap_or(0) + 1;
    scan.state["completed"] = json!(done);
    if (scan.state["mode"] == "quick" && row["status"] == "available")
        || (scan.state["mode"] != "continuous" && done >= scan.budget as u64)
    {
        scan.state["running"] = json!(false);
    }
    let _guard = transaction(store)?;
    let mut history = store
        .read("cache/mobile-chain-history.json", json!([]))?
        .as_array()
        .cloned()
        .unwrap_or_default();
    history.push(json!({"id":id,"result":row,"checkedAt":now()}));
    store.write("cache/mobile-chain-history.json", &json!(history))?;
    let mut saved = scan.state.clone();
    saved["running"] = json!(false);
    store.write("cache/mobile-chain.json", &saved)?;
    chain_scan::ranked(&scan.state, p["strategy"].as_str().unwrap_or("balanced"))
}
