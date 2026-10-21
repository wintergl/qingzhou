use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::LazyLock,
};
use uuid::Uuid;

#[derive(Clone)]
pub struct Storage {
    pub root: PathBuf,
}
impl Storage {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }
    pub fn path(&self, relative: &str) -> PathBuf {
        self.root.join(relative)
    }
    pub fn read(&self, relative: &str, default: Value) -> Result<Value> {
        read_json(&self.path(relative), default)
    }
    pub fn write(&self, relative: &str, value: &Value) -> Result<()> {
        atomic_write(&self.path(relative), &serde_json::to_vec_pretty(value)?)
    }
    pub fn settings(&self) -> Result<Value> {
        normalize_settings(self.read("settings.json", json!({}))?)
    }
    /// Stable private credential for the local controller. Without it any web
    /// page can send no-CORS POST requests such as restart or core upgrade.
    pub fn controller_secret(&self) -> Result<String> {
        let path = self.path("runtime-state/controller-secret");
        if let Ok(text) = fs::read_to_string(&path) {
            let text = text.trim();
            if text.len() >= 32 && text.chars().all(|c| c.is_ascii_alphanumeric()) {
                return Ok(text.to_owned());
            }
        }
        let secret = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
        atomic_write(&path, secret.as_bytes())?;
        Ok(secret)
    }
    pub fn subscription(&self) -> Result<Value> {
        let mut v = self.read("subscription.json", json!({"entries":[]}))?;
        if !v.is_object() {
            bail!("订阅数据格式无效，原文件已保留。");
        }
        if !v["entries"].is_array() {
            let url = v["url"].as_str().unwrap_or("").to_owned();
            v["entries"] = if url.is_empty() {
                json!([])
            } else {
                json!([{
                    "id":"subscription", "name":"订阅", "url":url,"enabled":true,
                    "updatedAt":v["updatedAt"],"nodeCount":v["nodeCount"].as_u64().unwrap_or(0),
                    "status":v["status"].as_str().unwrap_or("saved"),"lastError":v["lastError"],
                    "updateIntervalMinutes":1440,"lastAttemptAt":null
                }])
            };
        }
        for entry in v["entries"].as_array_mut().unwrap() {
            let defaults = json!({"name":"订阅","enabled":true,"updatedAt":null,"nodeCount":0,"status":"saved","lastError":null,"updateIntervalMinutes":1440,"lastAttemptAt":null});
            merge_missing(entry, &defaults);
        }
        summarize_subscription(&mut v);
        Ok(v)
    }
    pub fn manifest(&self) -> Result<Value> {
        let existing = self.read("mihomo/providers/subscription-manifest.json", Value::Null)?;
        if !existing.is_null() {
            if existing["schemaVersion"] != 1 || !existing["entries"].is_array() {
                bail!("订阅 provider manifest 格式无效。");
            }
            for e in existing["entries"].as_array().unwrap() {
                if !e["subscriptionId"].is_string()
                    || !e["providerPath"].is_string()
                    || !e["providerRevision"].is_string()
                {
                    bail!("订阅 provider manifest 条目无效。");
                }
            }
            return Ok(existing);
        }
        let mut entries = Vec::new();
        for entry in self.subscription()?["entries"].as_array().unwrap() {
            let id = entry["id"].as_str().context("订阅缺少标识。")?;
            let p = self.path(&format!("mihomo/providers/{}.yaml", filename(id)));
            if let Ok(bytes) = fs::read(&p) {
                entries.push(
                    json!({"subscriptionId":id,"providerPath":p,"providerRevision":sha256(&bytes)}),
                );
            }
        }
        Ok(json!({"schemaVersion":1,"revision":"legacy","entries":entries}))
    }
    pub fn save_manifest(&self, mut v: Value) -> Result<()> {
        v["revision"] = json!(sha256(&serde_json::to_vec(&v["entries"])?));
        self.write("mihomo/providers/subscription-manifest.json", &v)
    }
    pub fn recovery(&self) -> Result<Value> {
        let sequence = fs::read_to_string(self.path("runtime-state/recovery-state-sequence"));
        let revision = match sequence {
            Ok(s) => s
                .trim()
                .parse::<u64>()
                .ok()
                .filter(|r| *r <= 9_007_199_254_740_991),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(0),
            Err(e) => return Err(e.into()),
        };
        let state = self
            .read("runtime-state/recovery-state.json", Value::Null)
            .unwrap_or(Value::Null);
        if let Some(revision) = revision {
            if state.is_null()
                && revision == 0
                && !self.path("runtime-state/recovery-state.json").exists()
            {
                return Ok(
                    json!({"schemaVersion":1,"stateRevision":0,"state":"clear","transactionId":null,"selectedProxy":null,"reason":null,"updatedAt":"1970-01-01T00:00:00.000Z"}),
                );
            }
            if state["schemaVersion"] == 1
                && state["stateRevision"] == revision
                && matches!(state["state"].as_str(), Some("clear" | "required"))
            {
                return Ok(state);
            }
        }
        Ok(
            json!({"schemaVersion":1,"stateRevision":revision.unwrap_or(0),"state":"required","transactionId":"damaged-ledger","selectedProxy":null,"reason":"恢复状态无法校验，请先修复网络。","updatedAt":now()}),
        )
    }
    pub fn set_recovery(&self, required: bool, reason: Option<&str>) -> Result<Value> {
        let revision = self.recovery()?["stateRevision"]
            .as_u64()
            .unwrap_or(0)
            .checked_add(1)
            .context("恢复状态版本超出范围。")?;
        let state = json!({"schemaVersion":1,"stateRevision":revision,"state":if required{"required"}else{"clear"},"transactionId":if required{json!(Uuid::new_v4().to_string())}else{Value::Null},"selectedProxy":if required{self.settings()?["selectedProxy"].clone()}else{Value::Null},"reason":reason,"updatedAt":now()});
        atomic_write(
            &self.path("runtime-state/recovery-state-sequence"),
            format!("{revision}\n").as_bytes(),
        )?;
        self.write("runtime-state/recovery-state.json", &state)?;
        Ok(state)
    }
}

pub fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
pub fn sha256(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
pub fn filename(value: &str) -> String {
    let mut result = String::new();
    for ch in value.chars() {
        if ch.is_ascii_alphanumeric() || ch == '_' || ch == '-' {
            result.push(ch);
        } else if !result.ends_with('-') {
            result.push('-');
        }
    }
    let result = result.trim_matches('-');
    if result.is_empty() {
        "subscription".into()
    } else {
        result.into()
    }
}
pub fn encode(value: &str) -> String {
    const SET: &percent_encoding::AsciiSet = &percent_encoding::NON_ALPHANUMERIC
        .remove(b'-')
        .remove(b'_')
        .remove(b'.')
        .remove(b'~')
        .remove(b'!')
        .remove(b'\'')
        .remove(b'(')
        .remove(b')')
        .remove(b'*');
    percent_encoding::utf8_percent_encode(value, SET).to_string()
}
pub fn identity(id: &str, name: &str) -> String {
    format!("v1:{}:{}", encode(id), encode(name))
}
pub fn read_json(path: &Path, default: Value) -> Result<Value> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).with_context(|| {
            format!(
                "数据文件 {} 无法读取，原文件已保留。",
                path.file_name().unwrap_or_default().to_string_lossy()
            )
        }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(default),
        Err(e) => Err(e.into()),
    }
}
pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let dir = path.parent().context("文件路径无效。")?;
    fs::create_dir_all(dir)?;
    let temp = dir.join(format!(
        ".{}.{}.tmp",
        path.file_name().unwrap_or_default().to_string_lossy(),
        Uuid::new_v4()
    ));
    let result = (|| -> Result<()> {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temp, path)?;
        #[cfg(unix)]
        fs::File::open(dir)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}
pub fn merge_missing(value: &mut Value, defaults: &Value) {
    if let (Some(value), Some(defaults)) = (value.as_object_mut(), defaults.as_object()) {
        for (key, default) in defaults {
            if let Some(v) = value.get_mut(key) {
                if v.is_object() && default.is_object() {
                    merge_missing(v, default);
                }
            } else {
                value.insert(key.clone(), default.clone());
            }
        }
    }
}
pub use crate::routing::normalize_rule;
pub fn valid_domain(p: &str) -> bool {
    p.len() <= 253
        && p.split('.').all(|part| {
            !part.is_empty()
                && part.len() <= 63
                && !part.starts_with('-')
                && !part.ends_with('-')
                && part.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        })
}
pub fn normalize_settings(mut v: Value) -> Result<Value> {
    if !v.is_object() {
        bail!("设置数据格式无效，原文件已保留。");
    }
    let defaults: Value = serde_json::from_str(include_str!("../assets/default-settings.json"))?;
    let version = v["settingsVersion"].as_u64().unwrap_or(0);
    merge_missing(&mut v, &defaults);
    for k in [
        "launchAtLogin",
        "tun",
        "ipv6",
        "lanDirect",
        "tailscaleDirect",
    ] {
        if !v[k].is_boolean() {
            v[k] = defaults[k].clone();
        }
    }
    if version < 9 || !matches!(v["unknownTraffic"].as_str(), Some("direct" | "vpn")) {
        v["unknownTraffic"] = json!("direct");
    }
    if !matches!(
        v["geoFallback"].as_str(),
        Some("cn-direct-else-vpn" | "follow-default" | "block")
    ) {
        v["geoFallback"] = defaults["geoFallback"].clone();
    }
    if version < 9 && v["selectedProxy"] == "THROUGHPUT" {
        v["selectedProxy"] = json!("AUTO");
    }
    if !v["selectedProxy"].is_string() {
        v["selectedProxy"] = defaults["selectedProxy"].clone();
    }
    for key in [
        "favoriteNodeNames",
        "nodeGroups",
        "vpnDomainRules",
        "directDomainRules",
    ] {
        if !v[key].is_array() {
            v[key] = defaults[key].clone();
        }
    }
    v["favoriteNodeNames"] = json!(strings(&v["favoriteNodeNames"]));
    let mut ids = std::collections::HashSet::new();
    let mut groups = Vec::new();
    for (index, group) in v["nodeGroups"].as_array().unwrap().iter().enumerate() {
        let Some(name) = group["name"]
            .as_str()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        else {
            continue;
        };
        let mut group = group.clone();
        let raw = group["id"]
            .as_str()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| format!("group_{}", index + 1));
        let id = if ids.contains(&raw) {
            format!("{raw}_{}", index + 1)
        } else {
            raw
        };
        ids.insert(id.clone());
        group["id"] = json!(id);
        group["name"] = json!(name);
        group["nodeNames"] = json!(strings(&group["nodeNames"]));
        if let Some(members) = group["members"].as_array() {
            let mut seen = std::collections::HashSet::new();
            group["members"] = json!(
                members
                    .iter()
                    .filter_map(|m| {
                        let name = m["lastKnownName"].as_str()?.trim();
                        let key = m["identityKey"]
                            .as_str()
                            .map(str::trim)
                            .filter(|s| !s.is_empty());
                        if name.is_empty() || !seen.insert(key.unwrap_or(name)) {
                            return None;
                        }
                        Some(json!({"identityKey":key,"lastKnownName":name}))
                    })
                    .collect::<Vec<_>>()
            );
        }
        groups.push(group);
    }
    let selected = v["selectedProxy"].as_str().unwrap();
    v["defaultOutlet"] = if let Some(g) = groups.iter().find(|g| {
        !g["id"].as_str().unwrap().starts_with("subscription:")
            && group_runtime_name(g["id"].as_str().unwrap()) == selected
    }) {
        json!({"kind":"group","groupId":g["id"]})
    } else if ["AUTO", "BALANCE", "DIRECT"].contains(&selected) {
        json!({"kind":"builtin","name":selected})
    } else {
        json!({"kind":"node","name":selected,"identityKey":if v["defaultOutlet"]["kind"] == "node" && v["defaultOutlet"]["name"] == selected {v["defaultOutlet"]["identityKey"].clone()} else {Value::Null}})
    };
    v["nodeGroups"] = json!(groups);
    let mut rules = Vec::new();
    if version < 9 {
        rules.extend(
            defaults["vpnDomainRules"]
                .as_array()
                .unwrap()
                .iter()
                .cloned(),
        );
    }
    for rule in v["vpnDomainRules"].as_array().unwrap() {
        if let Some(r) = rule.as_str().and_then(normalize_rule) {
            if !rules.contains(&json!(r)) {
                rules.push(json!(r));
            }
        }
    }
    v["vpnDomainRules"] = json!(rules);
    let direct = v["directDomainRules"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|r| r.as_str().and_then(normalize_rule))
        .fold(Vec::new(), |mut rules, r| {
            if !rules.contains(&json!(r)) {
                rules.push(json!(r));
            }
            rules
        });
    v["directDomainRules"] = json!(direct);
    v["settingsVersion"] = json!(10);
    if !v["specialCompatibilityRules"].is_object() {
        v["specialCompatibilityRules"] = defaults["specialCompatibilityRules"].clone();
    }
    for k in ["mailMasterProxy8081", "wechatImageSendFallback"] {
        if !v["specialCompatibilityRules"][k].is_boolean() {
            v["specialCompatibilityRules"][k] = json!(true);
        }
    }
    Ok(v)
}
fn strings(v: &Value) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    v.as_array()
        .into_iter()
        .flatten()
        .filter_map(|s| s.as_str().map(str::trim).filter(|s| !s.is_empty()))
        .filter(|s| seen.insert(*s))
        .map(str::to_owned)
        .collect()
}
pub fn group_runtime_name(id: &str) -> String {
    format!("SG_{}", &sha256(id.as_bytes())[..24])
}
pub fn summarize_subscription(v: &mut Value) {
    let entries = v["entries"].as_array().unwrap();
    let active: Vec<_> = entries.iter().filter(|e| e["enabled"] == true).collect();
    let count: u64 = active
        .iter()
        .map(|e| e["nodeCount"].as_u64().unwrap_or(0))
        .sum();
    let status = if active.is_empty() {
        "not-configured"
    } else if active.iter().any(|e| e["status"] == "updating") {
        "updating"
    } else if count > 0 {
        "ready"
    } else if active.iter().any(|e| e["status"] == "error") {
        "error"
    } else {
        "saved"
    };
    let url = active
        .first()
        .map(|e| e["url"].clone())
        .unwrap_or(json!(""));
    let updated = active
        .iter()
        .filter_map(|e| e["updatedAt"].as_str())
        .max()
        .map(str::to_owned);
    let error = active
        .iter()
        .filter_map(|e| e["lastError"].as_str())
        .collect::<Vec<_>>()
        .join("；");
    v["url"] = url;
    v["nodeCount"] = json!(count);
    v["status"] = json!(status);
    v["updatedAt"] = json!(updated);
    v["lastError"] = if error.is_empty() {
        Value::Null
    } else {
        json!(error)
    };
}

pub fn redact(text: &str) -> String {
    // Compiled once: log export redacts up to a thousand lines per call.
    static URLS: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r#"(?i)(?:https?|socks5h?)://[^\s\"'<>]+"#).unwrap());
    static SECRETS: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(
            r#"(?i)(api[_-]?key|password|token|secret|authorization)([\"'\s:=]+)[^\s,}\"]+"#,
        )
        .unwrap()
    });
    // URLs may contain subscription tokens in paths as well as query strings.
    let t = URLS.replace_all(text, |cap: &regex::Captures| {
        url::Url::parse(&cap[0])
            .ok()
            .and_then(|u| {
                u.host_str()
                    .map(|h| format!("{}://{h}/[已脱敏]", u.scheme()))
            })
            .unwrap_or("[已脱敏网址]".into())
    });
    SECRETS.replace_all(&t, "$1$2[已脱敏]").into_owned()
}
