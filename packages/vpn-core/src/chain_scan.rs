//! Bounded, end-to-end observations through an isolated chain listener.
use anyhow::{Context, Result, ensure};
use reqwest::blocking::Client;
use serde_json::{Value, json};
use std::{
    io::Read,
    time::{Duration, Instant},
};

pub const DOWNLOAD_BYTES: u64 = 512 * 1024;
/// Suggested performance refresh interval, never a record retention limit.
pub const MAX_AGE_SECONDS: u64 = 24 * 60 * 60;
pub struct Targets {
    pub latency: String,
    pub download: String,
    pub ip: String,
    pub bytes: u64,
}
impl Default for Targets {
    fn default() -> Self {
        Self {
            latency: "https://speed.cloudflare.com/__down?bytes=0".into(),
            download: format!("https://speed.cloudflare.com/__down?bytes={DOWNLOAD_BYTES}"),
            ip: "https://api.ipify.org?format=json".into(),
            bytes: DOWNLOAD_BYTES,
        }
    }
}
fn client(port: u16) -> Result<Client> {
    Ok(Client::builder()
        .no_proxy()
        .pool_max_idle_per_host(0)
        .connect_timeout(Duration::from_secs(3))
        .timeout(Duration::from_secs(8))
        .redirect(reqwest::redirect::Policy::none())
        .gzip(false)
        .proxy(reqwest::Proxy::all(format!("http://127.0.0.1:{port}"))?)
        .build()?)
}
fn request_error(stage: &str, error: reqwest::Error) -> anyhow::Error {
    let reason = if error.is_timeout() {
        "超时，请稍后重试或换一条备用线路"
    } else if error.is_connect() {
        "未能建立连接，请检查线路和 ISP 服务"
    } else if error.status().is_some() {
        "服务未正常响应，请稍后重试"
    } else {
        "请求未完成，请检查线路后重试"
    };
    anyhow::anyhow!("{stage}{reason}")
}
pub fn verify_ip(port: u16, url: &str, expected: &str) -> Result<String> {
    let response = client(port)?
        .get(url)
        .header("Accept-Encoding", "identity")
        .send()
        .map_err(|e| request_error("ISP 出口查询", e))?
        .error_for_status()
        .map_err(|e| request_error("ISP 出口查询", e))?;
    let mut body = Vec::new();
    response
        .take(2049)
        .read_to_end(&mut body)
        .context("ISP 出口查询响应未完整收到。")?;
    ensure!(body.len() <= 2048, "出口查询响应过长。");
    let v: Value = serde_json::from_slice(&body).context("ISP 出口查询未返回有效结果。")?;
    let ip = v["ip"]
        .as_str()
        .and_then(|s| s.parse::<std::net::IpAddr>().ok())
        .context("出口查询未返回有效 IP。")?;
    if !expected.is_empty() {
        ensure!(
            expected.parse::<std::net::IpAddr>().ok() == Some(ip),
            "实际出口与预期 ISP 不一致，请检查 ISP 配置。"
        );
    }
    Ok(ip.to_string())
}
pub fn recheck(
    port: u16,
    latency_url: &str,
    ip_url: &str,
    expected: &str,
) -> Result<(String, f64)> {
    let client = client(port)?;
    let start = Instant::now();
    let response = client
        .get(latency_url)
        .header("Cache-Control", "no-cache")
        .header("Accept-Encoding", "identity")
        .send()
        .map_err(|e| request_error("目标线路响应复核", e))?
        .error_for_status()
        .map_err(|e| request_error("目标线路响应复核", e))?;
    let mut body = Vec::new();
    response
        .take(2049)
        .read_to_end(&mut body)
        .context("目标线路响应未完整收到。")?;
    ensure!(body.len() <= 2048, "连通性复核响应无效。");
    let elapsed = start.elapsed().as_secs_f64() * 1000.0;
    Ok((verify_ip(port, ip_url, expected)?, elapsed))
}
fn median(values: &mut [f64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(f64::total_cmp);
    let mid = values.len() / 2;
    Some(if values.len() % 2 == 0 {
        (values[mid - 1] + values[mid]) / 2.0
    } else {
        values[mid]
    })
}
pub fn measure(
    port: u16,
    node: &Value,
    targets: &Targets,
    expected: &str,
    current: impl Fn() -> bool,
    progress: impl Fn(&str, usize, usize),
) -> Value {
    let client = match client(port) {
        Ok(client) => client,
        Err(_) => return failed(node, "client-failed"),
    };
    let mut samples = Vec::new();
    let mut rates = Vec::new();
    let mut errors = Vec::new();
    let mut ip = None;
    let mut latency_attempts = 0;
    let mut download_attempts = 0;
    for _ in 0..3 {
        if !current() {
            return failed(node, "cancelled");
        }
        latency_attempts += 1;
        progress("latency", latency_attempts, 3);
        let start = Instant::now();
        let result = (|| -> Result<f64> {
            let response = client
                .get(&targets.latency)
                .timeout(Duration::from_secs(4))
                .header("Accept-Encoding", "identity")
                .header("Cache-Control", "no-cache")
                .send()?
                .error_for_status()?;
            let mut bytes = Vec::new();
            response.take(2049).read_to_end(&mut bytes)?;
            ensure!(bytes.len() <= 2048, "延迟响应无效。");
            Ok(start.elapsed().as_secs_f64() * 1000.0)
        })();
        match result {
            Ok(ms) => samples.push(ms),
            Err(_) => errors.push("latency-failed"),
        }
        // Two entirely failed attempts already exclude a complete result.
        // Keep one retry for transient errors, then move to the next node.
        if latency_attempts == 2 && samples.is_empty() {
            break;
        }
    }
    if !samples.is_empty() {
        for _ in 0..2 {
            if !current() {
                return failed(node, "cancelled");
            }
            download_attempts += 1;
            progress("download", download_attempts, 2);
            let start = Instant::now();
            let result = (|| -> Result<f64> {
                let response = client
                    .get(&targets.download)
                    .header("Accept-Encoding", "identity")
                    .header("Cache-Control", "no-cache")
                    .send()?
                    .error_for_status()?;
                let mut response = response.take(targets.bytes + 1);
                let mut received = 0;
                let mut buffer = [0; 16384];
                loop {
                    ensure!(current(), "检测已取消。");
                    let n = response.read(&mut buffer)?;
                    if n == 0 {
                        break;
                    }
                    received += n as u64;
                }
                ensure!(received == targets.bytes, "下载响应长度不符。");
                Ok(received as f64 * 8.0
                    / start.elapsed().as_secs_f64().max(0.000001)
                    / 1_000_000.0)
            })();
            match result {
                Ok(mbps) => rates.push(mbps),
                Err(_) => {
                    errors.push("download-failed");
                    break;
                }
            }
        }
        if !current() {
            return failed(node, "cancelled");
        }
        progress("exit-ip", 1, 1);
        match verify_ip(port, &targets.ip, expected) {
            Ok(value) => ip = Some(value),
            Err(_) => errors.push("exit-ip-failed"),
        }
    }
    let successes = samples.len();
    let downloads = rates.len();
    let latency = median(&mut samples);
    let speed = median(&mut rates);
    let jitter = samples.first().zip(samples.last()).map(|(a, b)| b - a);
    json!({"identityKey":node["identityKey"],"nodeName":node["name"],"providerRevision":node["providerRevision"],"latencyMs":latency,"jitterMs":jitter,"downloadMbps":speed,"latencySuccesses":successes,"latencyAttempts":latency_attempts,"downloadSuccesses":downloads,"downloadAttempts":download_attempts,"exitIp":ip,
        "status":if successes==3&&downloads==2&&ip.is_some(){"available"}else if successes>0{"unstable"}else{"unreachable"},"errors":errors,"testedAt":crate::storage::now()})
}
pub fn failed(node: &Value, reason: &str) -> Value {
    json!({"identityKey":node["identityKey"],"nodeName":node["name"],"providerRevision":node["providerRevision"],"status":"unreachable","latencyMs":null,"jitterMs":null,"downloadMbps":null,"exitIp":null,"latencySuccesses":0,"latencyAttempts":3,"downloadSuccesses":0,"downloadAttempts":2,"errors":[reason],"testedAt":crate::storage::now()})
}
/// Fixed saturation points avoid one outlier changing every other candidate's
/// score. Weighted geometric utility penalizes a seriously weak dimension.
/// These are product defaults, not a calibrated prediction of user experience.
fn balanced_score(row: &Value) -> Option<f64> {
    if row["status"] != "available" {
        return None;
    }
    let download = row["downloadMbps"]
        .as_f64()
        .filter(|v| v.is_finite() && *v > 0.0)?;
    let latency = row["latencyMs"]
        .as_f64()
        .filter(|v| v.is_finite() && *v > 0.0)?;
    let jitter = row["jitterMs"]
        .as_f64()
        .filter(|v| v.is_finite() && *v >= 0.0)?;
    let download_utility = download / (download + 10.0);
    let latency_utility = 150.0 / (150.0 + latency);
    let jitter_utility = 30.0 / (30.0 + jitter);
    Some(
        100.0
            * (0.45 * download_utility.ln()
                + 0.45 * latency_utility.ln()
                + 0.10 * jitter_utility.ln())
            .exp(),
    )
}
pub fn ranked(state: &Value, strategy: &str) -> Result<Value> {
    ensure!(
        matches!(strategy, "balanced" | "download" | "latency"),
        "请选择综合推荐、下载优先或响应优先。"
    );
    let mut state = state.clone();
    let mut rows = state["results"].as_array().cloned().unwrap_or_default();
    for row in &mut rows {
        row["requiresRefresh"] = json!(!fresh(row, chrono::Utc::now()));
        row["balancedScore"] = json!(balanced_score(row));
    }
    rows.sort_by(|a, b| {
        let ready = |v: &Value| {
            v["status"] == "available"
                && v["otherEnvironment"] != true
                && (strategy != "balanced" || v["balancedScore"].is_number())
        };
        ready(b)
            .cmp(&ready(a))
            .then_with(|| {
                let low = |key: &str| {
                    a[key]
                        .as_f64()
                        .unwrap_or(f64::INFINITY)
                        .total_cmp(&b[key].as_f64().unwrap_or(f64::INFINITY))
                };
                let high = |key: &str| {
                    b[key]
                        .as_f64()
                        .unwrap_or(0.0)
                        .total_cmp(&a[key].as_f64().unwrap_or(0.0))
                };
                if strategy == "balanced" {
                    high("balancedScore")
                        .then_with(|| low("latencyMs"))
                        .then_with(|| high("downloadMbps"))
                } else if strategy == "download" {
                    high("downloadMbps").then_with(|| low("latencyMs"))
                } else {
                    low("latencyMs").then_with(|| high("downloadMbps"))
                }
            })
            .then_with(|| a["identityKey"].as_str().cmp(&b["identityKey"].as_str()))
    });
    let mut rank = 0;
    for row in &mut rows {
        if row["status"] == "available"
            && row["otherEnvironment"] != true
            && (strategy != "balanced" || row["balancedScore"].is_number())
        {
            rank += 1;
            row["rank"] = json!(rank);
        } else {
            row["rank"] = Value::Null;
        }
    }
    state["recommendedIdentityKey"] = rows
        .iter()
        .find(|r| {
            r["status"] == "available"
                && (strategy != "balanced" || r["balancedScore"].is_number())
                && r["otherEnvironment"] != true
        })
        .map(|r| r["identityKey"].clone())
        .unwrap_or(Value::Null);
    let valid = rows
        .iter()
        .filter(|r| {
            r["status"] == "available"
                && (strategy != "balanced" || r["balancedScore"].is_number())
                && r["otherEnvironment"] != true
        })
        .count();
    let recent = rows
        .iter()
        .filter(|r| r["status"] == "available" && r["otherEnvironment"] != true)
        .all(|r| r["requiresRefresh"] != true);
    let period = if recent {
        "最近 24 小时已测的"
    } else {
        "已保存测量的"
    };
    state["recommendationSummary"] = if state["recommendedIdentityKey"].is_null() {
        Value::Null
    } else {
        json!(match strategy {
            "balanced" => format!(
                "{period} {valid} 条完整通过测试的链路中，这条综合表现排名第一，兼顾下载、响应与波动。"
            ),
            "download" =>
                format!("{period} {valid} 条完整通过测试的链路中，这条按下载优先排名第一。"),
            _ => format!("{period} {valid} 条完整通过测试的链路中，这条按响应优先排名第一。"),
        })
    };
    state["results"] = json!(rows);
    state["strategy"] = json!(strategy);
    state["scorePolicy"] = json!({"version":1,"downloadWeight":0.45,"latencyWeight":0.45,"jitterWeight":0.10,"downloadReferenceMbps":10,"latencyReferenceMs":150,"jitterReferenceMs":30,"aggregation":"weighted-geometric-utility"});
    state["recommendationExplanation"] = json!(match strategy {
        "balanced" => "综合分同时考虑下载 45%、响应 45%、波动 10%；明显偏慢的单项会拉低得分。",
        "download" => "先比较短下载速率，速率相同时再比较响应延迟。",
        _ => "先比较响应延迟，延迟相同时再比较短下载速率。",
    });
    Ok(state)
}
pub fn idle() -> Value {
    json!({"id":"","running":false,"cancelled":false,"completed":0,"total":0,"currentNode":null,"results":[],"stale":true,"error":null})
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ranking_distinguishes_bandwidth_from_latency_and_excludes_partial_success() {
        let s = json!({"results":[{"identityKey":"quick","status":"available","latencyMs":40,"downloadMbps":2},{"identityKey":"fast","status":"available","latencyMs":150,"downloadMbps":20},{"identityKey":"failed","status":"unstable","latencyMs":1,"downloadMbps":1000}]});
        assert_eq!(
            ranked(&s, "download").unwrap()["recommendedIdentityKey"],
            "fast"
        );
        assert_eq!(
            ranked(&s, "latency").unwrap()["recommendedIdentityKey"],
            "quick"
        );
        assert!(ranked(&s, "bad").is_err());
    }
    #[test]
    fn ranks_follow_strategy_and_exclude_failed_observations() {
        let state = json!({"results":[
            {"identityKey":"responsive","status":"available","latencyMs":10,"downloadMbps":2,"jitterMs":1,"testedAt":crate::storage::now()},
            {"identityKey":"download","status":"available","latencyMs":100,"downloadMbps":20,"jitterMs":1,"testedAt":crate::storage::now()},
            {"identityKey":"failed","status":"unstable","latencyMs":1,"downloadMbps":200}
        ]});
        let download = ranked(&state, "download").unwrap();
        assert_eq!(download["results"][0]["identityKey"], "download");
        assert_eq!(download["results"][0]["rank"], 1);
        assert_eq!(download["results"][1]["rank"], 2);
        assert!(download["results"][2]["rank"].is_null());
        assert_eq!(
            ranked(&state, "latency").unwrap()["results"][0]["identityKey"],
            "responsive"
        );
    }
    #[test]
    fn no_recommendation_when_all_candidates_failed() {
        let s = json!({"results":[{"identityKey":"bad","status":"unstable","downloadMbps":30}]});
        assert!(ranked(&s, "download").unwrap()["recommendedIdentityKey"].is_null());
    }
    #[test]
    fn balanced_prefers_a_middle_ground_over_high_bandwidth_with_bad_latency() {
        let s = json!({"results":[
            {"identityKey":"download","status":"available","downloadMbps":100,"latencyMs":1200,"jitterMs":80},
            {"identityKey":"responsive","status":"available","downloadMbps":2,"latencyMs":40,"jitterMs":5},
            {"identityKey":"balanced","status":"available","downloadMbps":20,"latencyMs":150,"jitterMs":15}
        ]});
        assert_eq!(
            ranked(&s, "download").unwrap()["recommendedIdentityKey"],
            "download"
        );
        assert_eq!(
            ranked(&s, "latency").unwrap()["recommendedIdentityKey"],
            "responsive"
        );
        let ranked = ranked(&s, "balanced").unwrap();
        assert_eq!(ranked["recommendedIdentityKey"], "balanced");
        let score = ranked["results"][0]["balancedScore"].as_f64().unwrap();
        assert!(score > 50.0 && score < 70.0);
    }
    #[test]
    fn balanced_penalizes_jitter_and_excludes_incomplete_or_invalid_observations() {
        let s = json!({"results":[
            {"identityKey":"steady","status":"available","downloadMbps":20,"latencyMs":150,"jitterMs":10},
            {"identityKey":"jittery","status":"available","downloadMbps":20,"latencyMs":150,"jitterMs":300},
            {"identityKey":"missing","status":"available","downloadMbps":999,"latencyMs":1},
            {"identityKey":"zero","status":"available","downloadMbps":999,"latencyMs":0,"jitterMs":0},
            {"identityKey":"partial","status":"unstable","downloadMbps":999,"latencyMs":1,"jitterMs":0}
        ]});
        let ranked = ranked(&s, "balanced").unwrap();
        assert_eq!(ranked["recommendedIdentityKey"], "steady");
        assert_eq!(ranked["results"][1]["identityKey"], "jittery");
        for row in ranked["results"].as_array().unwrap().iter().skip(2) {
            assert!(row["balancedScore"].is_null());
        }
    }
    #[test]
    fn balanced_scores_are_independent_of_other_candidates_and_monotonic() {
        let good = json!({"status":"available","downloadMbps":20,"latencyMs":150,"jitterMs":10});
        let score = balanced_score(&good).unwrap();
        for (field, value) in [("downloadMbps", 10), ("latencyMs", 300), ("jitterMs", 100)] {
            let mut worse = good.clone();
            worse[field] = json!(value);
            assert!(balanced_score(&worse).unwrap() < score);
        }
        let mut available = good.clone();
        available["identityKey"] = json!("good");
        let s = json!({"results":[available,{"identityKey":"outlier","status":"available","downloadMbps":1000000,"latencyMs":50000,"jitterMs":10000}]});
        let result = ranked(&s, "balanced").unwrap();
        let row = result["results"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["identityKey"] == "good")
            .unwrap();
        assert_eq!(row["balancedScore"].as_f64().unwrap(), score);
    }
}

/// Failed observations use a bounded retry cooldown. Cancellation and local
/// selector/client errors are not evidence about a proxy's quality.
pub fn rejected(row: &Value) -> bool {
    if row["errors"].as_array().is_some_and(|errors| {
        errors.iter().any(|e| {
            matches!(
                e.as_str(),
                Some("cancelled" | "selector-failed" | "client-failed")
            )
        })
    }) {
        return false;
    }
    matches!(row["status"].as_str(), Some("unreachable" | "unstable"))
}

/// A cooldown expiry or confirmed address change unlocks a failed observation.
/// DNS failure cannot extend a cooldown. Hashes keep addresses private.
pub fn skip_rejected(cached: &Value, address_key: &str, ip_key: Option<&str>) -> bool {
    cached["proxyAddressKey"] == address_key
        && rejected(cached)
        && match (cached["proxyIpKey"].as_str(), ip_key) {
            (Some(old), Some(new)) => old == new,
            _ => true,
        }
        && retry_at(cached).is_some_and(|t| t > chrono::Utc::now())
}

pub fn retry_at(row: &Value) -> Option<chrono::DateTime<chrono::Utc>> {
    row["nextRetryAt"]
        .as_str()
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|t| t.with_timezone(&chrono::Utc))
        .or_else(|| {
            row["testedAt"]
                .as_str()
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                .map(|t| t.with_timezone(&chrono::Utc) + chrono::Duration::seconds(60))
        })
}
/// 1, 2, 4, 8… minutes, capped at one hour; local failures are not node failures.
pub fn set_retry(result: &mut Value, previous: Option<&Value>, now: chrono::DateTime<chrono::Utc>) {
    if rejected(result) {
        let streak = previous
            .filter(|r| rejected(r))
            .and_then(|r| r["failureStreak"].as_u64())
            .unwrap_or(0)
            .saturating_add(1);
        let seconds = (60u64.saturating_mul(1u64 << streak.saturating_sub(1).min(6))).min(3600);
        result["failureStreak"] = json!(streak);
        result["nextRetryAt"] =
            json!((now + chrono::Duration::seconds(seconds as i64)).to_rfc3339());
    } else {
        result["failureStreak"] = json!(0);
        result["nextRetryAt"] = Value::Null;
    }
}

/// Resolve only the server address, never connect a VPN or download a sample.
/// Subprocesses are bounded and reaped; isolated tests never consult real DNS.
pub fn proxy_ip_key(server: &str, isolated: bool) -> Option<String> {
    use std::net::IpAddr;
    let mut ips = if let Ok(ip) = server.parse::<IpAddr>() {
        vec![ip.to_string()]
    } else {
        if isolated
            || server.is_empty()
            || !server
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b".-_".contains(&c))
            || server.starts_with('-')
        {
            return None;
        }
        let output = if cfg!(target_os = "macos") {
            crate::platform::command("/usr/bin/dscacheutil", &["-q", "host", "-a", "name", server], Duration::from_secs(4))
        } else if cfg!(windows) {
            crate::platform::command("powershell.exe", &["-NoProfile", "-NonInteractive", "-Command", &format!("[System.Net.Dns]::GetHostAddresses('{server}') | ForEach-Object {{ $_.IPAddressToString }}")], Duration::from_secs(4))
        } else {
            crate::platform::command("getent", &["ahosts", server], Duration::from_secs(4))
        }.ok()?;
        output
            .split_whitespace()
            .filter_map(|s| s.parse::<IpAddr>().ok())
            .map(|ip| ip.to_string())
            .collect::<Vec<_>>()
    };
    ips.sort();
    ips.dedup();
    if ips.is_empty() {
        return None;
    }
    Some(crate::storage::sha256(ips.join(",").as_bytes()))
}

pub fn fresh(row: &Value, now: chrono::DateTime<chrono::Utc>) -> bool {
    row["environmentUncertain"] != true
        && row["testedAt"]
            .as_str()
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .is_some_and(|t| {
                let age = now.signed_duration_since(t).num_seconds();
                (0..=MAX_AGE_SECONDS as i64).contains(&age)
            })
}
pub fn upsert(rows: &mut Vec<Value>, mut result: Value) {
    let previous = rows
        .iter()
        .position(|r| r["identityKey"] == result["identityKey"]);
    let count = previous
        .map(|i| rows[i]["observationCount"].as_u64().unwrap_or(1))
        .unwrap_or(0);
    result["observationCount"] = json!(count.saturating_add(1));
    if let Some(index) = previous {
        rows[index] = result;
    } else {
        rows.push(result);
    }
}
/// Revisit the best recent candidate every third turn; other turns explore
/// unmeasured and then oldest observations. Never retain a historical peak.
pub fn next_candidate(nodes: &[Value], rows: &[Value], turn: usize) -> Option<Value> {
    let now = chrono::Utc::now();
    if turn % 3 == 2 {
        let valid = rows.to_vec();
        let state = ranked(&json!({"results":valid}), "balanced").ok()?;
        if let Some(best) = nodes
            .iter()
            .find(|n| n["identityKey"] == state["recommendedIdentityKey"])
        {
            return Some(best.clone());
        }
    }
    nodes
        .iter()
        .min_by_key(|node| {
            rows.iter()
                .find(|r| {
                    r["identityKey"] == node["identityKey"]
                        && r["providerRevision"] == node["providerRevision"]
                })
                .and_then(|r| r["testedAt"].as_str())
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                .filter(|t| *t <= now)
                .map(|t| t.timestamp_millis())
                .unwrap_or(i64::MIN)
        })
        .cloned()
}

#[cfg(test)]
mod accumulation_tests {
    use super::*;
    #[test]
    fn latest_failure_replaces_success_and_retest_increments_count() {
        let mut rows = vec![];
        upsert(&mut rows, json!({"identityKey":"one","status":"available"}));
        upsert(
            &mut rows,
            json!({"identityKey":"one","status":"unreachable"}),
        );
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["status"], "unreachable");
        assert_eq!(rows[0]["observationCount"], 2);
    }
    #[test]
    fn scheduler_explores_missing_nodes_and_periodically_rechecks_the_best() {
        let nodes = vec![
            json!({"identityKey":"best","providerRevision":"v1"}),
            json!({"identityKey":"new","providerRevision":"v1"}),
        ];
        let rows = vec![
            json!({"identityKey":"best","providerRevision":"v1","status":"available","downloadMbps":20,"latencyMs":100,"jitterMs":10,"testedAt":crate::storage::now()}),
        ];
        assert_eq!(
            next_candidate(&nodes, &rows, 0).unwrap()["identityKey"],
            "new"
        );
        assert_eq!(
            next_candidate(&nodes, &rows, 2).unwrap()["identityKey"],
            "best"
        );
    }
    #[test]
    fn negative_cache_expires_and_address_changes_bypass_cooldown() {
        let mut row = failed(&json!({"identityKey":"one"}), "latency-failed");
        row["proxyAddressKey"] = json!("server");
        row["proxyIpKey"] = json!("old-ip");
        set_retry(&mut row, None, chrono::Utc::now());
        assert!(skip_rejected(&row, "server", Some("old-ip")));
        assert!(skip_rejected(&row, "server", None));
        assert!(!skip_rejected(&row, "server", Some("new-ip")));
        assert!(!skip_rejected(&row, "new-server", Some("old-ip")));
        row["proxyIpKey"] = Value::Null;
        assert!(skip_rejected(&row, "server", Some("first-known-ip")));
        row["nextRetryAt"] = json!("2000-01-01T00:00:00Z");
        assert!(!skip_rejected(&row, "server", Some("old-ip")));
        row.as_object_mut().unwrap().remove("nextRetryAt");
        row["testedAt"] = json!("2000-01-01T00:00:00Z");
        assert!(!skip_rejected(&row, "server", None));
    }
    #[test]
    fn cooldown_backs_off_caps_and_resets_on_success() {
        let now = chrono::Utc::now();
        let mut previous = Value::Null;
        for expected in [60, 120, 240, 480, 960, 1920, 3600, 3600] {
            let mut row = failed(&json!({}), "latency-failed");
            set_retry(&mut row, Some(&previous), now);
            assert_eq!((retry_at(&row).unwrap() - now).num_seconds(), expected);
            previous = row;
        }
        let mut success = json!({"status":"available"});
        set_retry(&mut success, Some(&previous), now);
        assert_eq!(success["failureStreak"], 0);
        assert!(success["nextRetryAt"].is_null());
    }
    #[test]
    fn old_success_retains_its_score_and_ranking_when_another_route_is_refreshed() {
        let mut old = json!({"identityKey":"old","status":"available","downloadMbps":100,"latencyMs":10,"jitterMs":1,"testedAt":"2000-01-01T00:00:00Z"});
        let state = ranked(&json!({"results":[old.clone()]}), "balanced").unwrap();
        assert_eq!(state["recommendedIdentityKey"], "old");
        assert!(state["results"][0]["balancedScore"].is_number());
        assert_eq!(state["results"][0]["requiresRefresh"], true);
        old["identityKey"] = json!("recent");
        old["downloadMbps"] = json!(1);
        old["testedAt"] = json!(crate::storage::now());
        let state = ranked(&json!({"results":[state["results"][0],old]}), "balanced").unwrap();
        assert_eq!(state["recommendedIdentityKey"], "old");
    }
    #[test]
    fn failure_policy_keeps_slow_success_and_excludes_local_errors() {
        assert!(!rejected(
            &json!({"status":"available","downloadMbps":0.1,"latencyMs":2000,"jitterMs":300})
        ));
        assert!(!rejected(
            &json!({"status":"available","downloadMbps":20,"latencyMs":100,"jitterMs":10})
        ));
        for reason in ["cancelled", "selector-failed", "client-failed"] {
            assert!(!rejected(&failed(&json!({}), reason)));
        }
        assert_eq!(proxy_ip_key("example.test", true), None);
        assert_ne!(
            proxy_ip_key("10.0.0.8", true),
            proxy_ip_key("10.0.0.9", true)
        );
    }
    #[test]
    fn expired_or_future_observations_are_not_fresh() {
        let now = chrono::Utc::now();
        for seconds in [-86401, 60] {
            assert!(!fresh(
                &json!({"testedAt":(now+chrono::Duration::seconds(seconds)).to_rfc3339()}),
                now
            ));
        }
        for seconds in [0, 601, 6 * 3600, 86399, 86400] {
            let row = json!({"testedAt":(now-chrono::Duration::seconds(seconds)).to_rfc3339()});
            assert!(
                fresh(&row, now),
                "{seconds} seconds old should remain fresh"
            );
            let mut uncertain = row;
            uncertain["environmentUncertain"] = json!(true);
            assert!(!fresh(&uncertain, now));
        }
    }
    #[test]
    fn day_recent_success_remains_eligible_for_recommendation() {
        let now = chrono::Utc::now();
        let best = json!({"identityKey":"best","status":"available","downloadMbps":100,"latencyMs":10,"jitterMs":1,"testedAt":(now-chrono::Duration::hours(23)).to_rfc3339()});
        let recent = json!({"identityKey":"recent","status":"available","downloadMbps":1,"latencyMs":100,"jitterMs":10,"testedAt":now.to_rfc3339()});
        let mut state = json!({"results":[best,recent]});
        let ranked_state = ranked(&state, "balanced").unwrap();
        assert_eq!(ranked_state["recommendedIdentityKey"], "best");
        assert_eq!(ranked_state["results"][0]["requiresRefresh"], false);
        assert!(
            ranked_state["recommendationSummary"]
                .as_str()
                .unwrap()
                .contains("最近 24 小时已测的 2 条")
        );
        state["results"][0]["testedAt"] = json!((now - chrono::Duration::hours(25)).to_rfc3339());
        let ranked_state = ranked(&state, "balanced").unwrap();
        assert_eq!(ranked_state["recommendedIdentityKey"], "best");
        assert_eq!(ranked_state["results"][0]["requiresRefresh"], true);
        assert!(ranked_state["results"][0]["balancedScore"].is_number());
    }
}
