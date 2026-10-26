use crate::{platform, storage::redact};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::{net::Ipv4Addr, time::Duration};

/// Automatic repair only needs evidence that the OS resolver works. Comparing
/// CDN answers from two separate queries can incorrectly classify healthy DNS.
/// Both targets and every subprocess are bounded; no resolver worker is leaked.
pub fn automatic_dns_health() -> bool {
    for host in ["www.gstatic.com", "www.apple.com"] {
        let result = if cfg!(target_os = "macos") {
            platform::command(
                "/usr/bin/dscacheutil",
                &["-q", "host", "-a", "name", host],
                Duration::from_secs(4),
            )
            .map(|text| {
                text.lines().any(|line| {
                    line.trim()
                        .strip_prefix("ip_address: ")
                        .or_else(|| line.trim().strip_prefix("ipv6_address: "))
                        .is_some_and(|ip| ip.parse::<std::net::IpAddr>().is_ok())
                })
            })
        } else if cfg!(windows) {
            let script = format!(
                "[System.Net.Dns]::GetHostAddresses('{host}') | ForEach-Object {{ $_.IPAddressToString }}"
            );
            platform::command(
                "powershell.exe",
                &["-NoProfile", "-NonInteractive", "-Command", &script],
                Duration::from_secs(4),
            )
            .map(|text| {
                text.lines()
                    .any(|ip| ip.trim().parse::<std::net::IpAddr>().is_ok())
            })
        } else {
            platform::command("getent", &["ahosts", host], Duration::from_secs(4)).map(|text| {
                text.split_whitespace()
                    .any(|ip| ip.parse::<std::net::IpAddr>().is_ok())
            })
        };
        if result.unwrap_or(false) {
            return true;
        }
    }
    false
}

pub fn dns_evidence(system: Result<Vec<String>>, vpn: Option<Result<Vec<String>>>) -> Value {
    let result = (|| {
        let addresses = system?;
        ensure!(!addresses.is_empty(), "系统 DNS 未返回 ChatGPT 地址。");
        if let Some(vpn) = vpn {
            let vpn = vpn?;
            ensure!(
                addresses.iter().any(|ip| vpn.contains(ip)),
                "系统 DNS 与 VPN DNS 不一致，请刷新网络连接。"
            );
        }
        Ok::<(), anyhow::Error>(())
    })();
    json!({"ok":result.is_ok(),"error":result.err().map(|e|redact(&e.to_string()))})
}

pub fn system_dns(isolated: bool, tun: bool) -> Value {
    let system = if isolated {
        fixture_addresses("SPLITVPN_TEST_SYSTEM_DNS_ADDRESSES")
    } else if cfg!(windows) {
        platform::command("powershell.exe", &["-NoProfile", "-NonInteractive", "-Command", "[System.Net.Dns]::GetHostAddresses('chatgpt.com') | ForEach-Object { $_.IPAddressToString }"], Duration::from_secs(6))
            .map(|text| text.lines().filter_map(|ip| ip.trim().parse::<Ipv4Addr>().ok()).map(|ip| ip.to_string()).collect())
    } else if !cfg!(target_os = "macos") {
        // getaddrinfo goes through the OS resolver, as browsers do.
        use std::net::ToSocketAddrs;
        ("chatgpt.com", 443)
            .to_socket_addrs()
            .map(|addrs| {
                addrs
                    .filter(|a| a.is_ipv4())
                    .map(|a| a.ip().to_string())
                    .collect()
            })
            .map_err(Into::into)
    } else {
        platform::command(
            "/usr/bin/dscacheutil",
            &["-q", "host", "-a", "name", "chatgpt.com"],
            Duration::from_secs(6),
        )
        .map(|text| {
            text.lines()
                .filter_map(|line| line.trim().strip_prefix("ip_address: "))
                .filter_map(|ip| ip.parse::<Ipv4Addr>().ok())
                .map(|ip| ip.to_string())
                .collect()
        })
    };
    // dig ships only with macOS; elsewhere the system lookup above is the evidence.
    let vpn = (tun && (isolated || cfg!(target_os = "macos"))).then(|| {
        if isolated {
            fixture_addresses("SPLITVPN_TEST_VPN_DNS_ADDRESSES")
        } else {
            platform::command(
                "/usr/bin/dig",
                &[
                    "+short",
                    "+time=2",
                    "+tries=1",
                    "@127.0.0.1",
                    "chatgpt.com",
                    "A",
                ],
                Duration::from_secs(4),
            )
            .map(|text| {
                text.lines()
                    .filter_map(|ip| ip.parse::<Ipv4Addr>().ok())
                    .map(|ip| ip.to_string())
                    .collect()
            })
        }
    });
    dns_evidence(system, vpn)
}

fn fixture_addresses(key: &str) -> Result<Vec<String>> {
    std::env::var(key)
        .context("隔离模式需要 DNS 测试数据。")?
        .split(',')
        .map(|ip| Ok(ip.trim().parse::<Ipv4Addr>()?.to_string()))
        .collect()
}

pub fn fixture_url(key: &str) -> Result<String> {
    let value = std::env::var(key).context("隔离模式需要回环测试地址。")?;
    let url = url::Url::parse(&value)?;
    ensure!(
        url.scheme() == "http" && matches!(url.host_str(), Some("127.0.0.1" | "::1")),
        "隔离检测只能访问回环地址。"
    );
    Ok(value)
}

pub fn complete_connectivity(
    domestic: &Value,
    foreign: &Value,
    dns: &Value,
    chatgpt: &Value,
    ip: Value,
) -> Value {
    let healthy = foreign["ok"] == true && dns["ok"] == true && chatgpt["ok"] == true;
    let errors = [domestic, foreign, dns, chatgpt]
        .into_iter()
        .filter_map(|result| result["error"].as_str())
        .filter(|error| !error.is_empty())
        .collect::<Vec<_>>();
    json!({"domesticOk":domestic["ok"],"foreignOk":healthy,"proxyOk":foreign["ok"],
        "systemDns":dns,"chatgpt":chatgpt,"externalIp":ip,"error":if errors.is_empty(){None}else{Some(errors.join("；"))},
        "latency":{"domesticMs":domestic["delay"],"foreignMs":foreign["delay"]}})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proxy_success_cannot_mask_system_dns_mismatch() {
        let dns = dns_evidence(
            Ok(vec!["203.0.113.1".into()]),
            Some(Ok(vec!["198.18.0.65".into()])),
        );
        let good = json!({"ok":true,"delay":20});
        let result = complete_connectivity(&good, &good, &dns, &good, Value::Null);
        assert_eq!(result["proxyOk"], true);
        assert_eq!(result["foreignOk"], false);
        assert!(result["error"].as_str().unwrap().contains("DNS"));
    }

    #[test]
    fn chatgpt_http_failure_is_reported_separately() {
        let dns = dns_evidence(Ok(vec!["198.18.0.65".into()]), None);
        let good = json!({"ok":true,"delay":20});
        let blocked = json!({"ok":false,"httpStatus":403,"error":"ChatGPT 返回 HTTP 403。"});
        let result = complete_connectivity(&good, &good, &dns, &blocked, Value::Null);
        assert_eq!(result["proxyOk"], true);
        assert_eq!(result["foreignOk"], false);
        assert_eq!(result["systemDns"]["ok"], true);
        assert_eq!(result["chatgpt"]["httpStatus"], 403);
    }

    #[test]
    fn matching_dns_and_http_success_make_connectivity_healthy() {
        let dns = dns_evidence(
            Ok(vec!["198.18.0.65".into()]),
            Some(Ok(vec!["198.18.0.65".into()])),
        );
        let good = json!({"ok":true,"delay":20});
        assert_eq!(
            complete_connectivity(&good, &good, &dns, &good, Value::Null)["foreignOk"],
            true
        );
        assert_eq!(dns_evidence(Ok(vec![]), None)["ok"], false);
    }
}
