use crate::{singbox::DIRECT_DOMAINS, storage::Storage, subscription::provider_name};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::fs;

/// Default when the geo rule data is missing: mainland domains and the
/// built-in direct list stay direct, everything else goes through VPN.
pub const CN_DIRECT_ELSE_VPN: &str = "cn-direct-else-vpn";
/// Geo rules are gone, so unmatched traffic follows `unknownTraffic`.
pub const FOLLOW_DEFAULT: &str = "follow-default";
/// Refuse to start while the geo rule data is missing.
pub const BLOCK: &str = "block";

pub fn geo_fallback(settings: &Value) -> &str {
    match settings["geoFallback"].as_str() {
        Some(p @ (FOLLOW_DEFAULT | BLOCK)) => p,
        _ => CN_DIRECT_ELSE_VPN,
    }
}

/// The mihomo core loads the geo rules only when all three data files exist.
pub fn geo_ready(store: &Storage) -> bool {
    ["GeoSite.dat", "country.mmdb", "geoip.metadb"]
        .iter()
        .all(|name| fs::metadata(store.path(&format!("mihomo/{name}"))).is_ok_and(|m| m.len() > 0))
}

pub const QUIC_REJECT: &str = "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT";
pub const QUIC_VPN: &str = "AND,((NETWORK,UDP),(DST-PORT,443)),VPN";
/// Explicit VPN matches must still respect the selected node's UDP support.
pub const QUIC_RULES_REJECT: &str =
    "AND,((NETWORK,UDP),(DST-PORT,443),(RULE-SET,vpn-domains)),REJECT";
/// Selector and loopback inbound used only by node checks, so a risk or UDP
/// probe never moves the user's VPN outlet.
pub const PROBE: &str = "PROBE";
pub const PROBE_LISTENER: &str = "probe-in";
pub fn add_probe(c: &mut Value, port: u16) {
    let mut group = json!({"name":PROBE,"type":"select","proxies":["DIRECT"]});
    let providers = c["proxy-groups"]
        .as_array()
        .and_then(|g| g.iter().find(|g| g["name"] == "VPN"))
        .map(|vpn| vpn["use"].clone())
        .filter(|u| u.as_array().is_some_and(|u| !u.is_empty()));
    if let Some(providers) = providers {
        group["use"] = providers;
    }
    if !c["proxy-groups"].is_array() {
        c["proxy-groups"] = json!([]);
    }
    c["proxy-groups"].as_array_mut().unwrap().push(group);
    c["listeners"] = json!([{"name":PROBE_LISTENER,"type":"mixed","port":port,"listen":"127.0.0.1","udp":true,"proxy":PROBE}]);
}
/// Port of the probe inbound in a loaded configuration, if it has one.
pub fn probe_port(c: &Value) -> Option<u16> {
    c["listeners"]
        .as_array()?
        .iter()
        .find(|l| l["name"] == PROBE_LISTENER)?["port"]
        .as_u64()
        .and_then(|p| u16::try_from(p).ok())
        .filter(|p| *p > 0)
}
pub fn parse(text: &str) -> Result<Value> {
    let v: Value = serde_yaml_ng::from_str(text).context("Mihomo YAML 配置格式无效。")?;
    anyhow::ensure!(v.is_object(), "Mihomo 配置需要是对象。");
    Ok(v)
}
pub fn yaml(v: &Value) -> Result<String> {
    Ok(serde_yaml_ng::to_string(v)?)
}
pub fn build(
    store: &Storage,
    settings: &Value,
    mixed: u16,
    controller: u16,
    interface: Option<&str>,
    udp: bool,
) -> Result<Value> {
    let mut c: Value = serde_json::from_str(include_str!("../assets/base-config.json"))?;
    c["mixed-port"] = json!(mixed);
    c["external-controller"] = json!(format!("127.0.0.1:{controller}"));
    c["secret"] = json!(store.controller_secret()?);
    c["ipv6"] = settings["ipv6"].clone();
    c["dns"]["ipv6"] = settings["ipv6"].clone();
    c["tun"]["enable"] = settings["tun"].clone();
    if cfg!(windows) {
        // The system stack needs a Windows Firewall rule for mihomo; gvisor does not.
        c["tun"]["stack"] = json!("gvisor");
    }
    if let Some(interface) = interface {
        c["interface-name"] = json!(interface);
        c["tun"]["auto-detect-interface"] = json!(false);
    }
    let mut excluded = vec!["127.0.0.0/8"];
    if settings["lanDirect"] == true {
        excluded.extend(["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]);
    }
    if settings["tailscaleDirect"] == true {
        excluded.push("100.64.0.0/10");
    }
    excluded.extend(["169.254.0.0/16", "224.0.0.0/4"]);
    c["tun"]["route-exclude-address"] = json!(excluded);
    // HTTP sniffing runs before rules and can clear the original destination
    // IP when it replaces it with a Host name. Keep local targets intact so
    // no-resolve LAN rules and private-network resource rules still match.
    let mut sniff_excluded = excluded;
    if settings["lanDirect"] == true {
        sniff_excluded.extend(["::1/128", "fc00::/7", "fe80::/10", "ff00::/8"]);
    }
    c["sniffer"]["skip-dst-address"] = json!(sniff_excluded);
    if settings["specialCompatibilityRules"]["mailMasterProxy8081"] != true {
        c["sniffer"]["sniff"]["HTTP"]["ports"] = json!([80, "8080-8880"]);
    }
    let record = store.subscription()?;
    let manifest = store.manifest()?;
    let mut providers = json!({});
    let mut names = Vec::new();
    for e in record["entries"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["enabled"] == true && e["nodeCount"].as_u64().unwrap_or(0) > 0)
    {
        let id = e["id"].as_str().context("订阅标识无效。")?;
        let p = manifest["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["subscriptionId"] == id)
            .context("订阅 provider manifest 缺失，请更新订阅。")?;
        let name = provider_name(id);
        names.push(name.clone());
        providers[&name] = json!({"type":"file","path":p["providerPath"],"health-check":{"enable":true,"url":"https://www.gstatic.com/generate_204","interval":300,"timeout":5000}});
    }
    c["proxy-providers"] = providers;
    let wechat = settings["specialCompatibilityRules"]["wechatImageSendFallback"] == true;
    for g in c["proxy-groups"].as_array_mut().unwrap() {
        if g.get("use").is_some() {
            g["use"] = json!(names);
        }
        if g["name"] == "VPN" {
            g["default-selected"] = settings["selectedProxy"].clone();
        }
    }
    let geo = geo_ready(store);
    let fallback = geo_fallback(settings);
    ensure!(
        geo || fallback != BLOCK,
        "Geo 数据不可用，已按“拒绝启动”策略停止。"
    );
    let cn_direct_fallback = !geo && fallback == CN_DIRECT_ELSE_VPN;
    let cn_direct: Vec<String> = if geo {
        vec!["GEOSITE,cn,DIRECT".into(), "GEOIP,CN,DIRECT".into()]
    } else if cn_direct_fallback {
        DIRECT_DOMAINS
            .iter()
            .map(|d| format!("DOMAIN-SUFFIX,{d},DIRECT"))
            .collect()
    } else {
        Vec::new()
    };
    if !geo {
        // The geosite:cn DNS policy needs the same missing data.
        let ali = json!([
            "https://dns.alidns.com/dns-query",
            "https://doh.pub/dns-query"
        ]);
        c["dns"]
            .as_object_mut()
            .unwrap()
            .remove("nameserver-policy");
        if cn_direct_fallback {
            let policy: serde_json::Map<String, Value> = DIRECT_DOMAINS
                .iter()
                .map(|d| (format!("+.{d}"), ali.clone()))
                .collect();
            c["dns"]["nameserver-policy"] = Value::Object(policy);
        }
    }
    let mut rules = Vec::new();
    if settings["lanDirect"] == true {
        rules.push("GEOIP,lan,DIRECT,no-resolve".into());
        if geo {
            rules.push("GEOSITE,private,DIRECT".into());
        }
    }
    if settings["tailscaleDirect"] == true {
        rules.push("IP-CIDR,100.64.0.0/10,DIRECT,no-resolve".into());
    }
    for rule in settings["directDomainRules"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        let suffix = if rule.starts_with("IP-CIDR") {
            ",DIRECT,no-resolve"
        } else {
            ",DIRECT"
        };
        rules.push(format!("{rule}{suffix}"));
    }
    if names.is_empty() {
        c.as_object_mut().unwrap().remove("proxy-groups");
        c.as_object_mut().unwrap().remove("rule-providers");
        rules.extend(cn_direct);
        rules.push("MATCH,DIRECT".into());
    } else {
        if !udp {
            rules.push(QUIC_RULES_REJECT.into());
        }
        rules.push("RULE-SET,vpn-domains,VPN".into());
        if wechat {
            rules.extend([
                "PROCESS-NAME,WeChat,WECHAT".into(),
                "PROCESS-NAME,WeChatAppEx,WECHAT".into(),
                "PROCESS-NAME,WeChatAppEx Helper,WECHAT".into(),
            ]);
        } else {
            c["proxy-groups"]
                .as_array_mut()
                .unwrap()
                .retain(|g| g["name"] != "WECHAT");
        }
        rules.extend(cn_direct);
        rules.push(if udp {
            QUIC_VPN.into()
        } else {
            QUIC_REJECT.into()
        });
        if geo {
            rules.extend(["GEOSITE,geolocation-!cn,VPN".into(), "GEOIP,!CN,VPN".into()]);
        }
        let unmatched_vpn = cn_direct_fallback || settings["unknownTraffic"] == "vpn";
        rules.push(format!(
            "MATCH,{}",
            if unmatched_vpn { "VPN" } else { "DIRECT" }
        ));
    }
    c["rules"] = json!(rules);
    Ok(c)
}
