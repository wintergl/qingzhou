//! Shared rule validation and editing. Shells send an address and an outlet;
//! parsing and configuration policy stay in the core.
use crate::storage::valid_domain;
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

pub const RULE_KEYS: [&str; 2] = ["vpnDomainRules", "directDomainRules"];

fn address(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.contains("://") {
        let url = url::Url::parse(raw).ok()?;
        if !matches!(url.scheme(), "http" | "https")
            || !url.username().is_empty()
            || url.password().is_some()
        {
            return None;
        }
        Some(url.host_str()?.trim_matches(['[', ']']).to_owned())
    } else {
        Some(raw.to_owned())
    }
}

fn network(raw: &str) -> Option<(IpAddr, u8)> {
    // Brackets are how URLs and copy-paste distinguish IPv6 from a port.
    // They are not part of the address, including in `[2001:db8::8]/32`.
    let (ip, prefix) = match raw.split_once('/') {
        Some((ip, prefix)) => (
            ip.trim().trim_matches(['[', ']']).parse::<IpAddr>().ok()?,
            Some(prefix.trim().parse::<u8>().ok()?),
        ),
        None => (
            raw.trim().trim_matches(['[', ']']).parse::<IpAddr>().ok()?,
            None,
        ),
    };
    match ip {
        IpAddr::V4(ip) => {
            let prefix = prefix.unwrap_or(32);
            let mask = u32::MAX
                .checked_shl(u32::from(32u8.checked_sub(prefix)?))
                .unwrap_or(0);
            Some((Ipv4Addr::from(u32::from(ip) & mask).into(), prefix))
        }
        IpAddr::V6(ip) => {
            let prefix = prefix.unwrap_or(128);
            let mask = u128::MAX
                .checked_shl(u32::from(128u8.checked_sub(prefix)?))
                .unwrap_or(0);
            Some((Ipv6Addr::from(u128::from(ip) & mask).into(), prefix))
        }
    }
}

/// Canonical legacy matchers, plain domain/IP/CIDR or an HTTP(S) URL.
pub fn normalize_rule(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.chars().any(char::is_control) {
        return None;
    }
    let (kind, value) = raw.trim().split_once(',').unwrap_or(("AUTO", raw.trim()));
    let kind = kind.trim().to_ascii_uppercase();
    let value = value.trim();
    if value.is_empty() || value.contains(',') {
        return None;
    }
    if matches!(kind.as_str(), "AUTO" | "IP" | "IP-CIDR" | "IP-CIDR6") {
        let value = address(value)?;
        if let Some((ip, prefix)) = network(&value) {
            if (kind == "IP-CIDR" && ip.is_ipv6()) || (kind == "IP-CIDR6" && ip.is_ipv4()) {
                return None;
            }
            let kind = if ip.is_ipv4() { "IP-CIDR" } else { "IP-CIDR6" };
            return Some(format!("{kind},{ip}/{prefix}"));
        }
        if kind != "AUTO" {
            return None;
        }
    }
    let kind = if kind == "AUTO" {
        "DOMAIN-SUFFIX"
    } else {
        &kind
    };
    let value = match kind {
        "DOMAIN" | "DOMAIN-SUFFIX" => address(value)?,
        _ => value.to_owned(),
    };
    let value = value
        .trim_start_matches("*.")
        .trim_end_matches('.')
        .to_lowercase();
    // Old releases sometimes stored a plain IP as a domain matcher.
    // Keep that user's address by migrating it to the correct IP matcher.
    if matches!(kind, "DOMAIN" | "DOMAIN-SUFFIX") && value.parse::<IpAddr>().is_ok() {
        return normalize_rule(&value);
    }
    let invalid_ip = value.split('.').count() == 4
        && value.chars().all(|c| c.is_ascii_digit() || c == '.')
        && value.parse::<Ipv4Addr>().is_err();
    match kind {
        "DOMAIN" | "DOMAIN-SUFFIX"
            if valid_domain(&value) && !invalid_ip && value.parse::<IpAddr>().is_err() =>
        {
            Some(format!("{kind},{value}"))
        }
        "DOMAIN-KEYWORD" | "GEOSITE"
            if !value.is_empty() && !value.chars().any(char::is_whitespace) =>
        {
            Some(format!("{kind},{value}"))
        }
        _ => None,
    }
}

pub fn normalize_input(p: &Value) -> Result<Value> {
    let input = p["rule"].as_str().context("请输入域名、IP 或网段。")?;
    let kind = p
        .get("kind")
        .map(|v| v.as_str().context("匹配方式无效。"))
        .transpose()?
        .unwrap_or("auto");
    let raw = match kind {
        "auto" | "raw" => input.to_owned(),
        "DOMAIN" | "DOMAIN-SUFFIX" | "DOMAIN-KEYWORD" | "ip" => {
            format!("{},{}", kind.to_ascii_uppercase(), input.trim())
        }
        _ => bail!("匹配方式无效。"),
    };
    let rule = normalize_rule(&raw).context("地址格式无效。可填写 example.test、192.0.2.8、192.0.2.0/24 或完整网址；每条规则只填一个地址。")?;
    let (kind, value) = rule.split_once(',').unwrap();
    Ok(json!({"rule":rule,"kind":kind,"value":value}))
}

pub fn validate_patch(patch: &Value) -> Result<()> {
    for key in RULE_KEYS {
        if let Some(value) = patch.get(key) {
            let rules = value.as_array().context("分流规则需要是列表。")?;
            ensure!(
                rules
                    .iter()
                    .all(|r| r.as_str().and_then(normalize_rule).is_some()),
                "分流规则中有无效地址，原设置已保留。"
            );
        }
    }
    Ok(())
}

fn rule_key(target: Option<&Value>) -> Result<&'static str> {
    match target {
        None => Ok("vpnDomainRules"), // Old clients do not send an outlet.
        Some(value) if value == "vpn" => Ok("vpnDomainRules"),
        Some(value) if value == "direct" => Ok("directDomainRules"),
        _ => bail!("请选择走 VPN 或直连。"),
    }
}

/// Returns both lists as one patch so changing an outlet is atomic.
pub fn edit_patch(settings: &Value, p: &Value, operation: &str) -> Result<Value> {
    let key = rule_key(p.get("target"))?;
    let rule = normalize_input(p)?["rule"].clone();
    let mut patch = json!({"vpnDomainRules":settings["vpnDomainRules"],"directDomainRules":settings["directDomainRules"]});
    if operation == "routing:edit-rule" {
        let original_key = rule_key(p.get("originalTarget"))?;
        let original = p["originalRule"]
            .as_str()
            .and_then(normalize_rule)
            .context("缺少原规则。")?;
        let rules = patch[original_key].as_array_mut().unwrap();
        ensure!(
            rules.contains(&json!(original)),
            "这条规则已被修改或删除，请刷新后重试。"
        );
        rules.retain(|r| r != &original);
    }
    if operation == "routing:delete-rule" {
        patch[key].as_array_mut().unwrap().retain(|r| r != &rule);
    } else {
        // Identical matchers have one outlet. Broader overlaps remain in
        // both lists, with explicit direct rules evaluated first.
        for list in RULE_KEYS {
            patch[list].as_array_mut().unwrap().retain(|r| r != &rule);
        }
        patch[key].as_array_mut().unwrap().push(rule);
    }
    Ok(patch)
}

pub fn matches(rule: &str, host: &str) -> bool {
    let Some((kind, value)) = rule.split_once(',') else {
        return false;
    };
    match kind {
        "DOMAIN" => host == value,
        "DOMAIN-SUFFIX" => host == value || host.ends_with(&format!(".{value}")),
        "DOMAIN-KEYWORD" => host.contains(value),
        "IP-CIDR" | "IP-CIDR6" => network(value).is_some_and(|(ip, prefix)| {
            network(&format!("{host}/{prefix}")).is_some_and(|(host_ip, _)| host_ip == ip)
        }),
        _ => false,
    }
}

/// Pure custom-rule diagnosis; it does not resolve DNS or contact a VPN.
fn literal_host(raw: &str) -> Option<String> {
    let host = address(raw)?.trim_end_matches('.').to_lowercase();
    let bare = host.trim().trim_matches(['[', ']']);
    if bare.parse::<IpAddr>().is_ok() {
        Some(bare.to_owned())
    } else {
        Some(host)
    }
}

pub fn diagnose(settings: &Value, target: &str) -> Result<Value> {
    let host = literal_host(target).context("请输入有效域名、IP 或网址。")?;
    ensure!(
        (valid_domain(&host) || host.parse::<IpAddr>().is_ok()) && normalize_rule(&host).is_some(),
        "请输入单个域名、IP 或网址。"
    );
    let matched = |key: &str| {
        settings[key]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|r| r.as_str().is_some_and(|r| matches(r, &host)))
            .cloned()
            .collect::<Vec<_>>()
    };
    let direct = matched("directDomainRules");
    let vpn = matched("vpnDomainRules");
    let policy = if !direct.is_empty() {
        "直连"
    } else if !vpn.is_empty() {
        "VPN"
    } else {
        "由国内外自动分流或未命中策略决定"
    };
    Ok(
        json!({"target":target,"host":host,"matchedRules":if !direct.is_empty() { &direct } else { &vpn },"matchedDirectRules":direct,"matchedVpnRules":vpn,"policy":policy,"unknownTraffic":settings["unknownTraffic"]}),
    )
}
