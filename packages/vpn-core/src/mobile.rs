//! Mobile entry point. iOS and Android link this crate as a static/shared
//! library and call `qz_core_call` with the same `{channel, payload}` JSON
//! shape as the desktop pipe. The app downloads subscriptions with the
//! platform HTTP stack and hands each response to `subscription:accept`;
//! the iOS packet tunnel only receives the generated sing-box document, while
//! Android runs mihomo behind tun2socks with the config from `mihomo:generate`.
use crate::{
    config, singbox,
    storage::{Storage, atomic_write, normalize_settings, now, redact, summarize_subscription},
    subscription::{
        ACCEPT, ACTIVATION_ERROR, Downloaded, MAX_BYTES, commit_update, download_plan, due_ids,
        enabled_providers, needs_activation, parse_provider, prepare_content, provider_nodes,
        prune_providers, user_agent, validate_url,
    },
};
use anyhow::{Context, Result, anyhow, bail, ensure};
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char},
    path::PathBuf,
    sync::Mutex,
};

/// Settings the mobile shells own; anything else is rejected.
const SETTINGS_KEYS: &[&str] = &[
    "selectedProxy",
    "defaultOutlet",
    "unknownTraffic",
    "geoFallback",
    "vpnDomainRules",
    "directDomainRules",
    "specialCompatibilityRules",
    "favoriteNodeNames",
    "nodeGroups",
    "ipv6",
    "lanDirect",
    "tailscaleDirect",
];

/// Serializes read-modify-write cycles on the shared data directory.
static LOCK: Mutex<()> = Mutex::new(());

// Android's userspace bridge forwards this virtual server through SOCKS; the
// DNS outbound handles both UDP and TCP inside Mihomo without binding port 53.
const ANDROID_DNS_SERVER: &str = "172.19.0.2";
const ANDROID_DNS_OUTBOUND: &str = "__QZ_ANDROID_DNS__";

fn string<'a>(p: &'a Value, k: &str) -> Result<&'a str> {
    p[k].as_str()
        .filter(|s| !s.is_empty())
        .with_context(|| format!("缺少参数 {k}。"))
}

pub fn handle(store: &Storage, channel: &str, p: &Value) -> Result<Value> {
    match channel {
        "bootstrap" => Ok(json!({
            "settings":store.settings()?,
            "subscription":store.subscription()?,
            "nodes":nodes(store)?,
        })),
        "settings:get" => store.settings(),
        "settings:patch" => {
            crate::routing::validate_patch(p)?;
            let mut s = store.settings()?;
            let patch = p.as_object().context("设置参数需要是对象。")?;
            if let Some(key) = patch.keys().find(|k| !SETTINGS_KEYS.contains(&k.as_str())) {
                bail!("此操作不能修改设置项 {key}。");
            }
            for (k, v) in patch {
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
            let s = normalize_settings(s)?;
            store.write("settings.json", &s)?;
            Ok(s)
        }
        "subscription:get-status" => store.subscription(),
        "subscription:save" => save(store, p),
        "subscription:set-enabled"
        | "subscription:delete"
        | "subscription:clear-all"
        | "subscription:configure-update" => change(store, channel, p),
        "subscription:due" => Ok(json!(due_ids(&store.subscription()?))),
        "subscription:plan" => {
            let mut record = store.subscription()?;
            let id = string(p, "id")?;
            let (urls, compat) = download_plan(entry_url(&record, id)?)?;
            let token = uuid::Uuid::new_v4().to_string();
            record["entries"]
                .as_array_mut()
                .unwrap()
                .iter_mut()
                .find(|e| e["id"] == id)
                .unwrap()["downloadToken"] = json!(token);
            store.write("subscription.json", &record)?;
            Ok(json!({
                "token":token,
                "urls":urls.iter().map(|u| u.as_str()).collect::<Vec<_>>(),
                "headers":{"accept":ACCEPT,"user-agent":user_agent(compat)},
                "maxBytes":MAX_BYTES,
            }))
        }
        "subscription:accept" => accept(store, p),
        "nodes:list" => Ok(json!(nodes(store)?)),
        "singbox:generate" => singbox::generate(
            store,
            &store.settings()?,
            &singbox::Options::from_payload(p),
        ),
        "mihomo:generate" => mihomo(store, p),
        _ => bail!("未知的移动端请求：{channel}"),
    }
}

/// Desktop node list plus `server` / `port`, which the iOS node list and
/// diagnostics show. `provider_nodes` emits one entry per provider node in
/// the same order, so the two lists zip.
fn nodes(store: &Storage) -> Result<Vec<Value>> {
    let mut out = provider_nodes(store)?;
    let raw = enabled_providers(store)?
        .into_iter()
        .flat_map(|(_, _, n)| n);
    for (node, raw) in out.iter_mut().zip(raw) {
        node["server"] = raw["server"].clone();
        node["port"] = raw["port"].clone();
    }
    Ok(out)
}

/// Android data plane: writes `mihomo/config.yaml` and the VPN domain rule
/// provider under the core root for a mihomo process behind tun2socks.
/// Payload: `{mixedPort?, controllerPort?}`.
fn mihomo(store: &Storage, p: &Value) -> Result<Value> {
    let port = |k: &str, default: u16| match p.get(k) {
        None | Some(Value::Null) => Ok(default),
        Some(v) => v
            .as_u64()
            .and_then(|n| u16::try_from(n).ok())
            .filter(|n| *n > 0)
            .with_context(|| format!("参数 {k} 不是有效端口。")),
    };
    let (mixed, controller) = (port("mixedPort", 7890)?, port("controllerPort", 9090)?);
    let mut settings = store.settings()?;
    // tun2socks owns the Android TUN; mihomo only serves the mixed port and
    // cannot see the originating app, so PROCESS-NAME rules never match.
    settings["tun"] = json!(false);
    settings["specialCompatibilityRules"]["wechatImageSendFallback"] = json!(false);
    let selected = &settings["selectedProxy"];
    let nodes = nodes(store)?;
    let selected_node = nodes.iter().find(|n| &n["name"] == selected);
    let selection_error = if selected == "DIRECT" {
        ""
    } else if nodes.is_empty() {
        "订阅没有可用节点，VPN 已停止，请先更新或启用订阅。"
    } else if selected == "AUTO" || selected == "BALANCE" {
        ""
    } else if selected_node.is_some_and(|n| n["identityAmbiguous"] == true) {
        "所选节点存在同名冲突，VPN 已停止，请选择其他节点。"
    } else if selected_node.is_none() {
        "所选节点已移除或订阅已停用，VPN 已停止，请重新选择节点。"
    } else {
        ""
    };
    let udp = selected == "DIRECT"
        || nodes.iter().any(|n| {
            &n["name"] == selected
                && n["runtimeUdpSupported"] == true
                && !n["identityAmbiguous"].as_bool().unwrap_or(false)
        });
    let mut c = config::build(store, &settings, mixed, controller, None, udp)?;
    let mut dns_outbound = ANDROID_DNS_OUTBOUND.to_owned();
    let mut suffix = 0;
    while nodes.iter().any(|node| node["name"] == dns_outbound)
        || c["proxy-groups"]
            .as_array()
            .is_some_and(|groups| groups.iter().any(|group| group["name"] == dns_outbound))
    {
        suffix += 1;
        dns_outbound = format!("{ANDROID_DNS_OUTBOUND}{suffix}");
    }
    c["proxies"]
        .as_array_mut()
        .unwrap()
        .push(json!({"name":dns_outbound,"type":"dns"}));
    // Keep the virtual DNS endpoint ahead of LAN/direct and user rules. This
    // does not redirect explicitly addressed private/company DNS servers.
    c["rules"].as_array_mut().unwrap().insert(
        0,
        json!(format!(
            "AND,((IP-CIDR,{ANDROID_DNS_SERVER}/32,no-resolve),(DST-PORT,53)),{dns_outbound}"
        )),
    );
    // Geodata ships in the APK, and an app process cannot bind :53.
    c["geo-auto-update"] = json!(false);
    // Android must not continuously probe an unused subscription/group. Keep
    // automatic selection available, with lazy health checks every 15 minutes.
    // This profile is local to the generated document, never user settings or
    // the desktop defaults. Child-exit recovery is independent of these probes.
    if let Some(providers) = c["proxy-providers"].as_object_mut() {
        for provider in providers.values_mut() {
            provider["health-check"]["lazy"] = json!(true);
            provider["health-check"]["interval"] = json!(900);
        }
    }
    if let Some(groups) = c["proxy-groups"].as_array_mut() {
        for group in groups {
            if group.get("url").is_some() {
                group["lazy"] = json!(true);
                group["interval"] = json!(900);
            }
        }
    }
    // Using a fixed node still touches its whole provider in mihomo, so lazy
    // checks alone can test every subscription node. Keep manual test URLs,
    // but stop periodic checks outside automatic selection modes. This only
    // changes the generated Android config, never saved or desktop settings.
    if !matches!(selected.as_str(), Some("AUTO" | "BALANCE")) {
        if let Some(providers) = c["proxy-providers"].as_object_mut() {
            for provider in providers.values_mut() {
                provider["health-check"]["enable"] = json!(false);
                provider["health-check"]["interval"] = json!(0);
            }
        }
        if let Some(groups) = c["proxy-groups"].as_array_mut() {
            for group in groups {
                if group.get("url").is_some() {
                    // Matching provider/group URLs prevent a second periodic task.
                    group["interval"] = json!(0);
                }
            }
        }
    }
    if let Some(dns) = c["dns"].as_object_mut() {
        dns.remove("listen");
    }
    atomic_write(
        &store.path("mihomo/providers/vpn-domains.yaml"),
        config::yaml(&json!({"payload":settings["vpnDomainRules"]}))?.as_bytes(),
    )?;
    let path = store.path("mihomo/config.yaml");
    atomic_write(&path, config::yaml(&c)?.as_bytes())?;
    Ok(json!({
        "home":store.path("mihomo").to_string_lossy(),
        "config":path.to_string_lossy(),
        "controller":c["external-controller"],
        "secret":c["secret"],
        "selectedProxy":selected,
        "selectionValid":selection_error.is_empty(),
        "selectionError":selection_error,
        "providerCount":c["proxy-providers"].as_object().map_or(0, |m| m.len()),
        "udp":udp,
    }))
}

fn entry_url<'a>(record: &'a Value, id: &str) -> Result<&'a str> {
    record["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["id"] == id)
        .context("找不到这条订阅。")?["url"]
        .as_str()
        .context("订阅链接无效。")
}

fn save(store: &Storage, p: &Value) -> Result<Value> {
    let url = validate_url(string(p, "url")?)?.to_string();
    let name = p["name"]
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or("订阅");
    let mut record = store.subscription()?;
    let entries = record["entries"].as_array_mut().unwrap();
    if let Some(id) = p["id"].as_str().filter(|s| !s.is_empty()) {
        let e = entries
            .iter_mut()
            .find(|e| e["id"] == id)
            .context("找不到这条订阅。")?;
        if e["url"] != url {
            e.as_object_mut().unwrap().remove("downloadToken");
        }
        e["url"] = json!(url);
        e["name"] = json!(name);
    } else if let Some(e) = entries.iter_mut().find(|e| e["url"] == url) {
        e["name"] = json!(name);
    } else {
        entries.push(json!({"id":uuid::Uuid::new_v4().to_string(),"name":name,"url":url,"enabled":true,"nodeCount":0,"status":"saved","updatedAt":null,"lastError":null,"lastAttemptAt":null,"updateIntervalMinutes":1440}));
    }
    summarize_subscription(&mut record);
    store.write("subscription.json", &record)?;
    Ok(record)
}

fn change(store: &Storage, channel: &str, p: &Value) -> Result<Value> {
    let mut r = store.subscription()?;
    let entries = r["entries"].as_array_mut().unwrap();
    let id = if channel == "subscription:clear-all" {
        ""
    } else {
        string(p, "id")?
    };
    if channel != "subscription:clear-all" {
        ensure!(entries.iter().any(|e| e["id"] == id), "找不到这条订阅。");
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
    summarize_subscription(&mut r);
    store.write("subscription.json", &r)?;
    if channel == "subscription:delete" || channel == "subscription:clear-all" {
        let mut m = store.manifest()?;
        m["entries"].as_array_mut().unwrap().retain(|e| {
            r["entries"]
                .as_array()
                .unwrap()
                .iter()
                .any(|s| s["id"] == e["subscriptionId"])
        });
        store.save_manifest(m)?;
        let _ = prune_providers(store);
    }
    Ok(r)
}

/// Judges one HTTP attempt from `subscription:plan` with the desktop
/// downloader's fallback rules. Payload: `{id, token, index, status, content}` for a
/// response or `{id, token, index, error}` for a transport failure. Returns
/// `{done:false, next}` when the next candidate URL should be tried.
fn accept(store: &Storage, p: &Value) -> Result<Value> {
    let id = string(p, "id")?;
    let token = string(p, "token")?;
    let mut record = store.subscription()?;
    let entry = record["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["id"] == id);
    if entry.is_none_or(|e| e["downloadToken"] != token) {
        return Ok(json!({"done":true,"ok":false,"stale":true,
            "error":"订阅已修改或已有更新请求，本次过期结果已丢弃。","subscription":record}));
    }
    let (urls, compat) = download_plan(entry_url(&record, id)?)?;
    let index = p["index"].as_u64().context("缺少参数 index。")? as usize;
    ensure!(index < urls.len(), "订阅下载序号无效。");
    let last = index + 1 == urls.len();
    let outcome = (|| -> Result<Option<Downloaded>> {
        if let Some(error) = p["error"].as_str() {
            return if index == 0 || last {
                Err(anyhow!("订阅下载失败：{error}"))
            } else {
                Ok(None)
            };
        }
        let status = p["status"].as_u64().context("缺少参数 status。")? as u16;
        let text = p["content"].as_str().unwrap_or("");
        ensure!(text.len() <= MAX_BYTES, "订阅内容超过 8 MB，旧节点已保留。");
        if !(200..300).contains(&status) {
            if needs_activation(compat, status, text) {
                bail!(ACTIVATION_ERROR);
            }
            if index == 0 {
                bail!("订阅下载失败（HTTP {status}），旧节点已保留。");
            }
            if last {
                bail!("订阅格式错误，未获取到 Mihomo 节点。");
            }
            return Ok(None);
        }
        let prepared = prepare_content(text).and_then(|content| {
            Ok(Downloaded {
                nodes: parse_provider(&content)?,
                content,
            })
        });
        match prepared {
            Ok(d) => Ok(Some(d)),
            Err(e) if last => Err(e),
            Err(_) => Ok(None),
        }
    })();
    match outcome {
        Ok(None) => Ok(json!({"done":false,"next":index + 1})),
        Ok(Some(downloaded)) => {
            record["entries"]
                .as_array_mut()
                .unwrap()
                .iter_mut()
                .find(|e| e["id"] == id)
                .unwrap()
                .as_object_mut()
                .unwrap()
                .remove("downloadToken");
            let mut manifest = store.manifest()?;
            let changed = commit_update(store, &mut record, &mut manifest, id, downloaded)?;
            if changed {
                store.save_manifest(manifest)?;
            }
            store.write("subscription.json", &record)?;
            let _ = prune_providers(store);
            Ok(json!({"done":true,"ok":true,"changed":changed,"subscription":record}))
        }
        Err(error) => {
            let message = redact(&error.to_string());
            let entry = record["entries"]
                .as_array_mut()
                .unwrap()
                .iter_mut()
                .find(|e| e["id"] == id)
                .unwrap();
            entry.as_object_mut().unwrap().remove("downloadToken");
            entry["lastError"] = json!(message);
            entry["lastAttemptAt"] = json!(now());
            if entry["nodeCount"].as_u64().unwrap_or(0) == 0 {
                entry["status"] = json!("error");
            }
            summarize_subscription(&mut record);
            store.write("subscription.json", &record)?;
            Ok(json!({"done":true,"ok":false,"error":message,"subscription":record}))
        }
    }
}

/// Handles one JSON request (`{channel, payload}`) against `root` and
/// returns the desktop-style reply (`{ok, data}` or `{ok:false, error}`).
pub fn call(root: &str, request: &str) -> String {
    let result = (|| -> Result<Value> {
        ensure!(!root.is_empty(), "缺少数据目录。");
        let request: Value = serde_json::from_str(request).context("请求格式无效。")?;
        let channel = request["channel"].as_str().context("缺少请求通道。")?;
        let payload = request.get("payload").cloned().unwrap_or_else(|| json!({}));
        let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        handle(&Storage::new(PathBuf::from(root)), channel, &payload)
    })();
    match result {
        Ok(data) => json!({"ok":true,"data":data}),
        Err(error) => {
            json!({"ok":false,"error":{"code":"CORE_OPERATION_FAILED","message":redact(&error.to_string())}})
        }
    }
    .to_string()
}

/// C ABI for Swift / JNI. Both arguments are NUL-terminated UTF-8; the reply
/// must be released with `qz_core_free`.
///
/// # Safety
/// `root` and `request` must be valid NUL-terminated strings or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qz_core_call(root: *const c_char, request: *const c_char) -> *mut c_char {
    let text = |p: *const c_char| {
        if p.is_null() {
            String::new()
        } else {
            // SAFETY: the caller passes a valid NUL-terminated string.
            unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
        }
    };
    let (root, request) = (text(root), text(request));
    let reply = std::panic::catch_unwind(|| call(&root, &request)).unwrap_or_else(|_| {
        json!({"ok":false,"error":{"code":"CORE_PANIC","message":"核心内部错误。"}}).to_string()
    });
    CString::new(reply).map_or(std::ptr::null_mut(), CString::into_raw)
}

/// # Safety
/// `reply` must come from `qz_core_call` and be freed at most once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qz_core_free(reply: *mut c_char) {
    if !reply.is_null() {
        // SAFETY: allocated by `CString::into_raw` in `qz_core_call`.
        drop(unsafe { CString::from_raw(reply) });
    }
}
