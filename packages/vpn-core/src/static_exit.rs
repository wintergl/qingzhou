//! Optional final hop. The VPN selector remains the airport/front hop; rules
//! target a separate SOCKS/HTTP exit. Credentials are supplied only in memory.
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};

pub const EXIT: &str = "__QZ_STATIC_EXIT__";
pub const SCAN_EXIT: &str = "__QZ_CHAIN_SCAN_EXIT__";
pub const SCAN_FRONT: &str = "__QZ_CHAIN_SCAN_FRONT__";
pub const SCAN_LISTENER: &str = "chain-scan-in";
pub const LISTENER: &str = "static-exit-check";

pub fn validate(v: &Value) -> Result<()> {
    let o = v.as_object().context("静态出口设置需要是对象。")?;
    ensure!(
        o.keys().all(|k| [
            "enabled",
            "protocol",
            "server",
            "port",
            "username",
            "expectedIp"
        ]
        .contains(&k.as_str())),
        "静态出口设置包含未知字段。"
    );
    ensure!(v["enabled"].is_boolean(), "请选择是否启用静态出口。");
    ensure!(
        matches!(v["protocol"].as_str(), Some("socks5" | "http" | "https")),
        "静态出口协议无效。"
    );
    let host = v["server"].as_str().context("请填写静态出口地址。")?;
    ensure!(
        host.len() <= 253
            && !host
                .chars()
                .any(|c| c.is_whitespace() || "/@?#".contains(c)),
        "静态出口只填写主机名或 IP。"
    );
    ensure!(
        v["port"]
            .as_u64()
            .is_some_and(|n| n <= 65535 && (n > 0 || v["enabled"] == false)),
        "静态出口端口无效。"
    );
    ensure!(
        v["username"].as_str().is_some_and(|s| s.len() <= 1024),
        "静态出口用户名无效。"
    );
    let expected = v["expectedIp"].as_str().context("预期出口 IP 格式无效。")?;
    ensure!(
        expected.is_empty() || expected.parse::<std::net::IpAddr>().is_ok(),
        "预期出口请填写 IP 地址或留空。"
    );
    if v["enabled"] == true {
        ensure!(!host.is_empty(), "请先填写静态出口地址。");
        ensure!(
            url::Host::parse(host).is_ok() || host.parse::<std::net::IpAddr>().is_ok(),
            "静态出口地址无效。"
        );
    }
    Ok(())
}

pub fn credential_matches(config: &Value, credential: &Value) -> bool {
    ["protocol", "server", "port", "username"]
        .iter()
        .all(|k| config[*k] == credential["configuration"][*k])
}

/// The iOS data plane uses sing-box, sharing the same configuration and vault
/// binding as desktop/Android. Direct and private routes keep their outlets.
pub fn apply_singbox(c: &mut Value, settings: &Value, credential: &Value) -> Result<()> {
    let exit = &settings["staticExit"];
    if exit["enabled"] != true {
        return Ok(());
    }
    validate(exit)?;
    let front = c["outbounds"]
        .as_array()
        .and_then(|list| list.iter().find(|o| o["tag"] == "proxy"));
    ensure!(
        settings["selectedProxy"] != "DIRECT"
            && front.is_some_and(|p| p["default"]
                .as_str()
                .is_some_and(|s| !matches!(s, "direct" | "block"))),
        "静态 ISP 需要可用的机场前置，请先选择节点。"
    );
    if !exit["username"].as_str().unwrap_or("").is_empty() {
        ensure!(
            credential_matches(exit, credential)
                && credential["password"]
                    .as_str()
                    .is_some_and(|p| !p.is_empty()),
            "静态出口密码未从安全存储加载，请重新保存。"
        );
    }
    let mut node = json!({"tag":EXIT,"type":if exit["protocol"] == "socks5" {"socks"} else {"http"},"server":exit["server"],"server_port":exit["port"],"detour":"proxy"});
    if exit["protocol"] == "socks5" {
        node["version"] = json!("5");
    }
    if exit["protocol"] == "https" {
        node["tls"] = json!({"enabled":true,"server_name":exit["server"]});
    }
    if !exit["username"].as_str().unwrap_or("").is_empty() {
        node["username"] = exit["username"].clone();
        node["password"] = credential["password"].clone();
    }
    c["outbounds"]
        .as_array_mut()
        .context("出口列表无效。")?
        .push(node);
    let rules = c["route"]["rules"]
        .as_array_mut()
        .context("分流规则无效。")?;
    let mut guarded = Vec::new();
    for mut rule in rules.drain(..) {
        if rule["outbound"] == "proxy" {
            let mut udp = rule.clone();
            udp["network"] = json!(["udp"]);
            udp["outbound"] = json!("block");
            guarded.push(udp);
            rule["outbound"] = json!(EXIT);
        }
        guarded.push(rule);
    }
    *rules = guarded;
    if c["route"]["final"] == "proxy" {
        c["route"]["rules"]
            .as_array_mut()
            .unwrap()
            .push(json!({"network":["udp"],"outbound":"block"}));
        c["route"]["final"] = json!(EXIT);
    }
    for server in c["dns"]["servers"]
        .as_array_mut()
        .context("DNS 设置无效。")?
    {
        if server["detour"] == "proxy" {
            server["detour"] = json!(EXIT);
        }
    }
    Ok(())
}

pub fn apply(c: &mut Value, settings: &Value, credential: &Value, port: u16) -> Result<()> {
    let exit = &settings["staticExit"];
    if exit["enabled"] != true {
        return Ok(());
    }
    validate(exit)?;
    ensure!(
        settings["selectedProxy"] != "DIRECT",
        "静态出口需要机场前置，请先选择一个机场节点；或关闭静态出口后直连。"
    );
    ensure!(
        c["proxy-groups"]
            .as_array()
            .is_some_and(|g| g.iter().any(|g| g["name"] == "VPN")),
        "静态出口需要可用的机场订阅。"
    );
    ensure!(
        !c["proxy-providers"]
            .as_object()
            .is_none_or(|p| p.is_empty()),
        "静态出口需要可用的机场订阅。"
    );
    if !exit["username"].as_str().unwrap_or("").is_empty() {
        ensure!(
            credential_matches(exit, credential)
                && credential["password"]
                    .as_str()
                    .is_some_and(|p| !p.is_empty()),
            "静态出口密码未从钥匙串加载，请在设置中重新保存。"
        );
    }
    let mut node = json!({"name":EXIT,"type":if exit["protocol"] == "socks5" {"socks5"} else {"http"},"server":exit["server"],"port":exit["port"],"udp":false,"dialer-proxy":"VPN"});
    if exit["protocol"] == "https" {
        node["tls"] = json!(true);
    }
    if !exit["username"].as_str().unwrap_or("").is_empty() {
        node["username"] = exit["username"].clone();
        node["password"] = credential["password"].clone();
    }
    c["proxies"]
        .as_array_mut()
        .context("出口列表无效。")?
        .push(node);
    // Rewrite outlet tokens only: direct/LAN/private-network rules keep their semantics.
    if let Some(rules) = c["rules"].as_array_mut() {
        for r in rules {
            if let Some(s) = r.as_str() {
                *r = json!(
                    s.split(',')
                        .map(|t| if t == "VPN" { EXIT } else { t })
                        .collect::<Vec<_>>()
                        .join(",")
                );
            }
        }
    }
    if let Some(groups) = c["proxy-groups"].as_array_mut() {
        for g in groups {
            if g["name"] == "VPN" {
                if let Some(proxies) = g["proxies"].as_array_mut() {
                    proxies.retain(|p| p != "DIRECT");
                }
            }
            if g["name"] == "WECHAT" {
                // Keep direct-first compatibility for unmatched WeChat traffic;
                // only its proxy fallback should use the configured final hop.
                g["proxies"] = json!(["DIRECT", EXIT]);
            }
        }
    }
    // SOCKS5 support alone does not prove UDP relay; default to TCP only.
    let rules = c["rules"].as_array_mut().context("分流规则无效。")?;
    let mut guarded = Vec::new();
    for r in rules.drain(..) {
        if let Some(s) = r.as_str() {
            let suffix = format!(",{EXIT}");
            if let Some(matcher) = s.strip_suffix(&suffix) {
                if matcher == "MATCH" {
                    guarded.push(json!("NETWORK,UDP,REJECT"));
                } else {
                    guarded.push(json!(format!("AND,((NETWORK,UDP),({matcher})),REJECT")));
                }
            }
        }
        guarded.push(r);
    }
    c["rules"] = json!(guarded);
    if !c["listeners"].is_array() {
        c["listeners"] = json!([]);
    }
    c["listeners"].as_array_mut().unwrap().push(json!({"name":LISTENER,"type":"mixed","listen":"127.0.0.1","port":port,"udp":false,"proxy":EXIT}));
    Ok(())
}

/// Provider's hostname:port:username:password form; password may contain ':'.
pub fn parse_line(line: &str) -> Result<Value> {
    let fields: Vec<_> = line.trim_end_matches(['\r', '\n']).splitn(4, ':').collect();
    ensure!(
        fields.len() == 4,
        "请粘贴 hostname:port:username:password；IPv6 地址请在单独字段填写。"
    );
    let port = fields[1]
        .trim()
        .parse::<u16>()
        .ok()
        .filter(|p| *p > 0)
        .context("静态出口端口无效。")?;
    let config = json!({"enabled":true,"protocol":"socks5","server":fields[0].trim(),"port":port,"username":fields[2],"expectedIp":""});
    validate(&config)?;
    ensure!(
        !fields[2].is_empty() && !fields[3].is_empty(),
        "请确认用户名和密码完整。"
    );
    Ok(json!({"configuration":config,"password":fields[3]}))
}

/// A separate selector means scanning never moves the live VPN selector.
pub fn add_scan(c: &mut Value, port: u16) -> Result<()> {
    let mut exit = c["proxies"]
        .as_array()
        .and_then(|a| a.iter().find(|n| n["name"] == EXIT))
        .cloned()
        .context("静态出口尚未生成。")?;
    exit["name"] = json!(SCAN_EXIT);
    exit["dialer-proxy"] = json!(SCAN_FRONT);
    let providers = c["proxy-groups"]
        .as_array()
        .and_then(|a| a.iter().find(|n| n["name"] == "VPN"))
        .map(|g| g["use"].clone())
        .context("机场列表尚未生成。")?;
    c["proxies"].as_array_mut().unwrap().push(exit);
    c["proxy-groups"]
        .as_array_mut()
        .unwrap()
        .push(json!({"name":SCAN_FRONT,"type":"select","use":providers}));
    c["listeners"].as_array_mut().context("检测入口尚未生成。")?.push(json!({"name":SCAN_LISTENER,"type":"mixed","listen":"127.0.0.1","port":port,"udp":false,"proxy":SCAN_EXIT}));
    Ok(())
}
