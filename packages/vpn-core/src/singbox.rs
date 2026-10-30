//! sing-box configuration for the mobile packet tunnels. Subscriptions keep
//! the Mihomo node format on disk; this module converts committed nodes and
//! the shared split rules into one sing-box JSON document.
use crate::{
    config,
    storage::{Storage, identity},
    subscription::{enabled_providers, udp_capability},
};
use anyhow::{Result, ensure};
use serde_json::{Map, Value, json};
use std::collections::HashSet;

pub const TUN_ADDRESS: &str = "198.18.0.1/30";
/// The tunnel also claims IPv6 so that traffic cannot bypass the rules.
pub const TUN_ADDRESS6: &str = "fdfe:dcba:9876::1/126";
pub const DEFAULT_MTU: u64 = 1400;
const MTUS: [u64; 3] = [1280, 1400, 1500];
const RESOLVERS: [&str; 2] = ["cloudflare-direct", "ali"];
const RESERVED_TAGS: [&str; 9] = [
    "__QZ_MOBILE_AUTO__",
    "__QZ_MOBILE_BALANCE__",
    "proxy",
    "direct",
    "block",
    crate::static_exit::EXIT,
    config::PROBE,
    crate::static_exit::SCAN_FRONT,
    crate::static_exit::SCAN_EXIT,
];
const RESERVED_CIDRS: [&str; 5] = [
    "0.0.0.0/8",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "224.0.0.0/4",
    "240.0.0.0/4",
];
const LAN_CIDRS: [&str; 3] = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"];
const TAILSCALE_CIDR: &str = "100.64.0.0/10";
/// Mainland services that must stay direct even before geo rule sets exist.
pub(crate) const DIRECT_DOMAINS: &[&str] = &[
    "cn",
    "com.cn",
    "net.cn",
    "org.cn",
    "gov.cn",
    "edu.cn",
    "baidu.com",
    "bdstatic.com",
    "shifen.com",
    "qq.com",
    "tencent.com",
    "weixin.qq.com",
    "weixinbridge.com",
    "alibaba.com",
    "alicdn.com",
    "aliyun.com",
    "taobao.com",
    "tmall.com",
    "jd.com",
    "360buyimg.com",
    "bytedance.com",
    "douyin.com",
    "byteimg.com",
    "snssdk.com",
    "toutiao.com",
    "autonavi.com",
    "amap.com",
    "gaode.com",
    "xiaomi.com",
    "mi.com",
    "huawei.com",
    "hicloud.com",
    "meituan.com",
    "dianping.com",
    "bilibili.com",
    "biliapi.net",
    "163.com",
    "126.net",
    "sina.com.cn",
    "sinaimg.cn",
    "weibo.com",
    "douban.com",
    "zhihu.com",
    "xiaohongshu.com",
    "pinduoduo.com",
    "pddpic.com",
    "alipay.com",
    "alipayobjects.com",
    "apple.com.cn",
    "icloud.com.cn",
    "aaplimg.com",
];

/// Local binary rule sets staged by the app (`.srs`).
pub struct Geo {
    pub geosite_cn: String,
    pub geoip_cn: String,
    pub geosite_non_cn: String,
}
pub struct Options {
    pub mtu: u64,
    pub domain_resolver: String,
    pub geo: Option<Geo>,
    pub exit_credential: Value,
    pub company_tunnel: Value,
    pub(crate) ports: crate::mobile::profile::Ports,
}
impl Options {
    pub fn from_payload(p: &Value) -> Self {
        let geo = &p["geo"];
        let path = |k: &str| geo[k].as_str().filter(|s| !s.is_empty()).map(str::to_owned);
        Self {
            exit_credential: p["exitCredential"].clone(),
            company_tunnel: p["companyTunnel"].clone(),
            ports: crate::mobile::profile::Ports::from_payload(p),
            mtu: p["mtu"]
                .as_u64()
                .filter(|m| MTUS.contains(m))
                .unwrap_or(DEFAULT_MTU),
            domain_resolver: p["domainResolver"]
                .as_str()
                .filter(|r| RESOLVERS.contains(r))
                .unwrap_or(RESOLVERS[0])
                .to_owned(),
            geo: match (path("geositeCn"), path("geoipCn"), path("geositeNonCn")) {
                (Some(geosite_cn), Some(geoip_cn), Some(geosite_non_cn)) => Some(Geo {
                    geosite_cn,
                    geoip_cn,
                    geosite_non_cn,
                }),
                _ => None,
            },
        }
    }
}

struct Converted {
    name: String,
    identity: String,
    tag: String,
    udp: bool,
}

fn text(v: &Value) -> Option<String> {
    match v {
        Value::String(s) if !s.trim().is_empty() => Some(s.trim().to_owned()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}
fn first(n: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|k| text(&n[*k]))
}
fn truthy(v: &Value) -> bool {
    v.as_bool().unwrap_or_else(|| {
        matches!(
            v.as_str().map(|s| s.trim().to_ascii_lowercase()).as_deref(),
            Some("1" | "true" | "yes" | "on")
        )
    })
}
fn port(v: &Value) -> Option<u64> {
    v.as_u64()
        .or_else(|| v.as_str()?.trim().parse().ok())
        .filter(|p| (1..=65535).contains(p))
}
/// Mihomo bandwidth values may be numbers or strings such as `100 Mbps`.
fn mbps(v: &Value) -> Option<u64> {
    v.as_u64().or_else(|| {
        let digits: String = v
            .as_str()?
            .trim()
            .chars()
            .take_while(char::is_ascii_digit)
            .collect();
        digits.parse().ok()
    })
}
fn list(v: &Value) -> Vec<String> {
    match v {
        Value::Array(a) => a.iter().filter_map(text).collect(),
        Value::String(s) => s
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect(),
        _ => Vec::new(),
    }
}

fn tls(n: &Value, required: bool, default_alpn: &[&str]) -> Option<Value> {
    let reality = text(&n["reality-opts"]["public-key"]);
    if !required && !truthy(&n["tls"]) && reality.is_none() {
        return None;
    }
    let mut t = json!({"enabled":true});
    if let Some(name) = first(n, &["sni", "servername", "server"]) {
        t["server_name"] = json!(name);
    }
    if truthy(&n["skip-cert-verify"]) {
        t["insecure"] = json!(true);
    }
    let alpn = list(&n["alpn"]);
    if !alpn.is_empty() {
        t["alpn"] = json!(alpn);
    } else if !default_alpn.is_empty() {
        t["alpn"] = json!(default_alpn);
    }
    let fingerprint = first(n, &["client-fingerprint", "fingerprint"]);
    if let Some(fp) = &fingerprint {
        t["utls"] = json!({"enabled":true,"fingerprint":fp});
    }
    if let Some(key) = reality {
        t["reality"] = json!({"enabled":true,"public_key":key});
        if let Some(id) = text(&n["reality-opts"]["short-id"]) {
            t["reality"]["short_id"] = json!(id);
        }
        // sing-box only performs REALITY handshakes through uTLS.
        if fingerprint.is_none() {
            t["utls"] = json!({"enabled":true,"fingerprint":"chrome"});
        }
    }
    Some(t)
}

/// Outer `None` means the transport has no sing-box equivalent.
fn transport(n: &Value) -> Option<Option<Value>> {
    let network = n["network"].as_str().unwrap_or("tcp").to_ascii_lowercase();
    Some(match network.as_str() {
        "" | "tcp" => None,
        "ws" => {
            let o = &n["ws-opts"];
            let path = text(&o["path"]).unwrap_or_else(|| "/".into());
            let headers: Map<String, Value> = o["headers"]
                .as_object()
                .into_iter()
                .flatten()
                .filter_map(|(k, v)| Some((k.clone(), json!(text(v)?))))
                .collect();
            if truthy(&o["v2ray-http-upgrade"]) {
                let mut t = json!({"type":"httpupgrade","path":path});
                if let Some(host) = headers.get("Host") {
                    t["host"] = host.clone();
                }
                Some(t)
            } else {
                let mut t = json!({"type":"ws","path":path});
                if !headers.is_empty() {
                    t["headers"] = Value::Object(headers);
                }
                if let Some(early) = o["max-early-data"].as_u64().filter(|e| *e > 0) {
                    t["max_early_data"] = json!(early);
                    t["early_data_header_name"] = json!(
                        text(&o["early-data-header-name"])
                            .unwrap_or_else(|| "Sec-WebSocket-Protocol".into())
                    );
                }
                Some(t)
            }
        }
        "grpc" => {
            let mut t = json!({"type":"grpc"});
            if let Some(name) = text(&n["grpc-opts"]["grpc-service-name"]) {
                t["service_name"] = json!(name);
            }
            Some(t)
        }
        "h2" => {
            let o = &n["h2-opts"];
            let mut t = json!({"type":"http"});
            let hosts = list(&o["host"]);
            if !hosts.is_empty() {
                t["host"] = json!(hosts);
            }
            if let Some(path) = text(&o["path"]) {
                t["path"] = json!(path);
            }
            Some(t)
        }
        _ => return None,
    })
}

fn ss_plugin(n: &Value, o: &mut Value) -> Option<()> {
    let Some(plugin) = text(&n["plugin"]) else {
        return Some(());
    };
    let opts = &n["plugin-opts"];
    let (name, args) = match plugin.as_str() {
        "obfs" | "obfs-local" => {
            let mut args = vec![format!(
                "obfs={}",
                text(&opts["mode"]).unwrap_or_else(|| "http".into())
            )];
            if let Some(host) = text(&opts["host"]) {
                args.push(format!("obfs-host={host}"));
            }
            ("obfs-local", args)
        }
        "v2ray-plugin" => {
            let mut args = vec![format!(
                "mode={}",
                text(&opts["mode"]).unwrap_or_else(|| "websocket".into())
            )];
            if truthy(&opts["tls"]) {
                args.push("tls".into());
            }
            if let Some(host) = text(&opts["host"]) {
                args.push(format!("host={host}"));
            }
            if let Some(path) = text(&opts["path"]) {
                args.push(format!("path={path}"));
            }
            ("v2ray-plugin", args)
        }
        _ => return None,
    };
    o["plugin"] = json!(name);
    o["plugin_opts"] = json!(args.join(";"));
    Some(())
}

/// Converts one Mihomo proxy object into a sing-box outbound without a tag.
/// `None` means the node cannot run on the mobile data plane.
pub fn outbound(n: &Value) -> Option<Value> {
    let server = text(&n["server"])?;
    let server_port = port(&n["port"])?;
    let mut o = json!({"server":server,"server_port":server_port});
    let with_transport = |o: &mut Value| -> Option<()> {
        if let Some(t) = transport(n)? {
            o["transport"] = t;
        }
        Some(())
    };
    match n["type"].as_str()? {
        "ss" => {
            o["type"] = json!("shadowsocks");
            o["method"] = json!(first(n, &["cipher", "method"])?);
            o["password"] = json!(first(n, &["password"])?);
            ss_plugin(n, &mut o)?;
            if truthy(&n["udp-over-tcp"]) {
                o["udp_over_tcp"] = json!(true);
            }
        }
        "vmess" => {
            o["type"] = json!("vmess");
            o["uuid"] = json!(first(n, &["uuid", "id"])?);
            o["security"] =
                json!(first(n, &["cipher", "security"]).unwrap_or_else(|| "auto".into()));
            o["alter_id"] = json!(n["alterId"].as_u64().unwrap_or(0));
            if let Some(t) = tls(n, false, &[]) {
                o["tls"] = t;
            }
            with_transport(&mut o)?;
        }
        "vless" => {
            o["type"] = json!("vless");
            o["uuid"] = json!(first(n, &["uuid", "id"])?);
            if let Some(flow) = first(n, &["flow"]) {
                o["flow"] = json!(flow);
            }
            if let Some(enc) = first(n, &["packet-encoding"]) {
                o["packet_encoding"] = json!(enc);
            }
            if let Some(t) = tls(n, false, &[]) {
                o["tls"] = t;
            }
            with_transport(&mut o)?;
        }
        "trojan" => {
            o["type"] = json!("trojan");
            o["password"] = json!(first(n, &["password"])?);
            o["tls"] = tls(n, true, &[])?;
            with_transport(&mut o)?;
        }
        "hysteria2" => {
            o["type"] = json!("hysteria2");
            o["password"] = json!(first(n, &["password", "auth"])?);
            o["tls"] = tls(n, true, &[])?;
            let ranges: Vec<String> = list(&n["ports"])
                .iter()
                .map(|r| match r.split_once('-') {
                    Some((a, b)) => format!("{}:{}", a.trim(), b.trim()),
                    None => format!("{r}:{r}"),
                })
                .collect();
            if !ranges.is_empty() {
                o["server_ports"] = json!(ranges);
            }
            if let Some(up) = mbps(&n["up"]) {
                o["up_mbps"] = json!(up);
            }
            if let Some(down) = mbps(&n["down"]) {
                o["down_mbps"] = json!(down);
            }
            if let (Some(kind), Some(password)) =
                (first(n, &["obfs"]), first(n, &["obfs-password"]))
            {
                o["obfs"] = json!({"type":kind,"password":password});
            }
        }
        "hysteria" => {
            o["type"] = json!("hysteria");
            o["up_mbps"] = json!(mbps(&n["up"])?);
            o["down_mbps"] = json!(mbps(&n["down"])?);
            if let Some(auth) = first(n, &["auth-str", "auth_str"]) {
                o["auth_str"] = json!(auth);
            }
            if let Some(obfs) = first(n, &["obfs"]) {
                o["obfs"] = json!(obfs);
            }
            o["tls"] = tls(n, true, &[])?;
        }
        "tuic" => {
            o["type"] = json!("tuic");
            o["uuid"] = json!(first(n, &["uuid"])?);
            if let Some(password) = first(n, &["password"]) {
                o["password"] = json!(password);
            }
            if let Some(cc) = first(n, &["congestion-controller"]) {
                o["congestion_control"] = json!(cc);
            }
            if let Some(mode) = first(n, &["udp-relay-mode"]) {
                o["udp_relay_mode"] = json!(mode);
            }
            if truthy(&n["reduce-rtt"]) {
                o["zero_rtt_handshake"] = json!(true);
            }
            if let Some(ms) = n["heartbeat-interval"].as_u64() {
                o["heartbeat"] = json!(format!("{ms}ms"));
            }
            // Mihomo negotiates h3 when a TUIC node does not list ALPN.
            o["tls"] = tls(n, true, &["h3"])?;
        }
        "anytls" => {
            o["type"] = json!("anytls");
            o["password"] = json!(first(n, &["password"])?);
            o["tls"] = tls(n, true, &[])?;
        }
        "http" => {
            o["type"] = json!("http");
            if let Some(user) = first(n, &["username"]) {
                o["username"] = json!(user);
            }
            if let Some(password) = first(n, &["password"]) {
                o["password"] = json!(password);
            }
            if let Some(t) = tls(n, false, &[]) {
                o["tls"] = t;
            }
        }
        "socks5" => {
            if truthy(&n["tls"]) {
                return None;
            }
            o["type"] = json!("socks");
            o["version"] = json!("5");
            if let Some(user) = first(n, &["username"]) {
                o["username"] = json!(user);
            }
            if let Some(password) = first(n, &["password"]) {
                o["password"] = json!(password);
            }
        }
        _ => return None,
    }
    if udp_capability(n).0 == Some(false) {
        o["network"] = json!("tcp");
    }
    Some(o)
}

fn unique_tag(name: &str, used: &mut HashSet<String>) -> String {
    let sanitized: String = name
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '-'
            }
        })
        .collect();
    let base = sanitized.trim_matches(['-', '_']);
    let base = if base.is_empty() { "proxy-node" } else { base };
    let mut tag = base.to_owned();
    let mut suffix = 2;
    while used.contains(&tag) {
        tag = format!("{base}-{suffix}");
        suffix += 1;
    }
    used.insert(tag.clone());
    tag
}

/// `(selector default tag, status, message)`.
fn resolve(
    settings: &Value,
    all: &[(String, String)],
    converted: &[Converted],
) -> (String, &'static str, String) {
    let selected = settings["selectedProxy"].as_str().unwrap_or("").trim();
    let label = if selected.is_empty() {
        "AUTO"
    } else {
        selected
    };
    let outlet = &settings["defaultOutlet"];
    if label.eq_ignore_ascii_case("DIRECT") {
        return ("direct".into(), "direct-selected", "已选择直连。".into());
    }
    // Without any subscription node there is nothing to protect; blocking
    // here would also cut off the subscription download that fixes it.
    if all.is_empty() {
        return (
            "direct".into(),
            "direct-only",
            "没有订阅节点，全部直连。".into(),
        );
    }
    if matches!(label, "AUTO" | "BALANCE") {
        return match converted.first() {
            Some(c) => (
                c.tag.clone(),
                "automatic-fallback",
                format!("移动端暂不支持自动选择，使用第一个可用节点「{}」。", c.name),
            ),
            None if all.is_empty() => (
                "direct".into(),
                "direct-only",
                "没有订阅节点，全部直连。".into(),
            ),
            None => (
                "direct".into(),
                "automatic-no-converted-outbounds",
                "订阅节点都无法转换，自动选择回退为直连。".into(),
            ),
        };
    }
    if outlet["kind"] == "group" {
        let members: Vec<String> = settings["nodeGroups"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|g| g["id"] == outlet["groupId"])
            .and_then(|g| g["members"].as_array())
            .into_iter()
            .flatten()
            .filter_map(|m| m["identityKey"].as_str().map(str::to_owned))
            .collect();
        return match converted.iter().find(|c| members.contains(&c.identity)) {
            Some(c) => (
                c.tag.clone(),
                "group-fallback",
                format!(
                    "移动端暂不支持节点组测速，使用组内第一个可用节点「{}」。",
                    c.name
                ),
            ),
            None => (
                "block".into(),
                "group-empty",
                "所选节点组没有可用节点。".into(),
            ),
        };
    }
    let key = outlet["identityKey"]
        .as_str()
        .filter(|_| outlet["name"] == label);
    let hit = key
        .and_then(|k| converted.iter().find(|c| c.identity == k))
        .or_else(|| {
            key.is_none()
                .then(|| converted.iter().find(|c| c.name == label))
                .flatten()
        });
    if let Some(c) = hit {
        return (
            c.tag.clone(),
            "manual-converted",
            format!("已选择节点「{label}」。"),
        );
    }
    match all.iter().find(|(name, _)| name == label) {
        Some((_, kind)) => (
            "block".into(),
            "manual-unsupported",
            format!("节点「{label}」的协议 {kind} 暂不支持移动端。"),
        ),
        None => (
            "block".into(),
            "manual-missing",
            format!("节点「{label}」已不在当前订阅中。"),
        ),
    }
}

/// Private measurement listeners never alter the business selector.
fn add_mobile_probes(
    store: &Storage,
    c: &mut Value,
    settings: &Value,
    opts: &Options,
    nodes: &[Converted],
) -> Result<()> {
    let ports = &opts.ports;
    let members: Vec<_> = if nodes.is_empty() {
        vec!["direct".to_owned()]
    } else {
        nodes.iter().map(|node| node.tag.clone()).collect()
    };
    let mut declarations = vec![
        ("mobile-mixed", ports.mixed, None),
        (
            "mobile-current",
            ports.current,
            Some(if settings["staticExit"]["enabled"] == true {
                crate::static_exit::EXIT
            } else {
                "proxy"
            }),
        ),
        (config::PROBE_LISTENER, ports.probe, Some(config::PROBE)),
    ];
    c["outbounds"].as_array_mut().unwrap().push(json!({"type":"selector","tag":config::PROBE,"outbounds":members,"default":members[0],"interrupt_exist_connections":true}));
    if !nodes.is_empty()
        && !settings["staticExit"]["server"]
            .as_str()
            .unwrap_or("")
            .is_empty()
        && !opts.exit_credential.is_null()
    {
        let mut temporary = c.clone();
        let mut s = settings.clone();
        s["staticExit"]["enabled"] = json!(true);
        s["selectedProxy"] = json!(&nodes[0].name);
        temporary["outbounds"][0]["default"] = json!(members[0]);
        if crate::static_exit::apply_singbox(&mut temporary, &s, &opts.exit_credential).is_ok() {
            let mut exit = temporary["outbounds"]
                .as_array()
                .unwrap()
                .last()
                .unwrap()
                .clone();
            exit["tag"] = json!(crate::static_exit::SCAN_EXIT);
            exit["detour"] = json!(crate::static_exit::SCAN_FRONT);
            c["outbounds"].as_array_mut().unwrap().extend([json!({"type":"selector","tag":crate::static_exit::SCAN_FRONT,"outbounds":members,"default":members[0],"interrupt_exist_connections":true}),exit]);
            declarations.push((
                crate::static_exit::SCAN_LISTENER,
                ports.scan,
                Some(crate::static_exit::SCAN_EXIT),
            ));
        }
    }
    for (name, port, outbound) in declarations {
        c["inbounds"]
            .as_array_mut()
            .unwrap()
            .push(json!({"type":"mixed","tag":name,"listen":"127.0.0.1","listen_port":port}));
        if let Some(outbound) = outbound {
            c["route"]["rules"]
                .as_array_mut()
                .unwrap()
                .insert(0, json!({"inbound":[name],"outbound":outbound}));
        }
    }
    c["experimental"]["clash_api"] = json!({"external_controller":format!("127.0.0.1:{}",ports.controller),"secret":store.controller_secret()?});
    Ok(())
}

fn matchers(settings: &Value, list: &str) -> (Map<String, Value>, usize) {
    let mut m = Map::new();
    let mut skipped = 0;
    for r in settings[list].as_array().into_iter().flatten() {
        let Some((kind, value)) = r.as_str().and_then(|r| r.split_once(',')) else {
            continue;
        };
        let key = match kind {
            "DOMAIN" => "domain",
            "DOMAIN-SUFFIX" => "domain_suffix",
            "DOMAIN-KEYWORD" => "domain_keyword",
            "IP-CIDR" | "IP-CIDR6" => "ip_cidr",
            _ => {
                skipped += 1;
                continue;
            }
        };
        m.entry(key)
            .or_insert_with(|| json!([]))
            .as_array_mut()
            .unwrap()
            .push(json!(value));
    }
    (m, skipped)
}
fn rule(matcher: &Map<String, Value>, extra: Value) -> Value {
    let mut r = Value::Object(matcher.clone());
    for (k, v) in extra.as_object().unwrap() {
        r[k] = v.clone();
    }
    r
}
fn rule_set(tag: &str) -> Map<String, Value> {
    let mut m = Map::new();
    m.insert("rule_set".into(), json!([tag]));
    m
}
fn block_quic(matcher: &Map<String, Value>, rules: &mut Vec<Value>) {
    rules.push(rule(
        matcher,
        json!({"network":["udp"],"port":[443],"outbound":"block"}),
    ));
    rules.push(rule(
        matcher,
        json!({"protocol":["quic"],"outbound":"block"}),
    ));
}
/// Proxied names resolve to fake IPs so the real lookup happens remotely.
fn proxied_dns(matcher: &Map<String, Value>, rules: &mut Vec<Value>) {
    rules.push(rule(
        matcher,
        json!({"query_type":["HTTPS","SVCB"],"action":"predefined","rcode":"NOERROR"}),
    ));
    rules.push(rule(
        matcher,
        json!({"query_type":["AAAA"],"action":"predefined","rcode":"NOERROR"}),
    ));
    rules.push(rule(matcher, json!({"query_type":["A"],"server":"fakeip"})));
    rules.push(rule(matcher, json!({"server":"cloudflare"})));
}

/// Addresses the packet tunnel must route around the TUN.
pub fn direct_cidrs(settings: &Value) -> Vec<&'static str> {
    let mut out = RESERVED_CIDRS.to_vec();
    if settings["lanDirect"] == true {
        out.extend(LAN_CIDRS);
    }
    if settings["tailscaleDirect"] == true {
        out.push(TAILSCALE_CIDR);
    }
    out
}

/// Builds the sing-box document from committed subscriptions and settings.
/// Returns `{config, summary}`; `config` is the JSON text to stage.
pub fn generate(store: &Storage, settings: &Value, opts: &Options) -> Result<Value> {
    opts.ports.validate()?;
    let mut used: HashSet<String> = RESERVED_TAGS.iter().map(|s| s.to_string()).collect();
    let mut all = Vec::new();
    let mut converted = Vec::new();
    let mut node_outbounds = Vec::new();
    for (e, _, nodes) in enabled_providers(store)? {
        let id = e["id"].as_str().unwrap();
        for n in nodes {
            let name = n["name"].as_str().unwrap().to_owned();
            all.push((name.clone(), n["type"].as_str().unwrap_or("").to_owned()));
            let Some(mut o) = outbound(&n) else { continue };
            let tag = unique_tag(&name, &mut used);
            o["tag"] = json!(tag);
            node_outbounds.push(o);
            converted.push(Converted {
                identity: identity(id, &name),
                udp: udp_capability(&n).0 == Some(true),
                name,
                tag,
            });
        }
    }
    let (mut selected, mut status, mut message) = resolve(settings, &all, &converted);
    let quic = converted.iter().any(|c| c.tag == selected && !c.udp);
    let fallback = config::geo_fallback(settings);
    ensure!(
        opts.geo.is_some() || fallback != config::BLOCK,
        "Geo 数据不可用，已按“拒绝启动”策略停止。"
    );
    let cn_direct_fallback = opts.geo.is_none() && fallback == config::CN_DIRECT_ELSE_VPN;
    let final_outbound = if cn_direct_fallback || settings["unknownTraffic"] == "vpn" {
        "proxy"
    } else {
        "direct"
    };
    // Without geo DNS, mainland names use the domestic resolver and the rest
    // resolves through the proxy, mirroring the geo split.
    let mut dns_final = "ali";
    let (vpn, skipped_vpn) = matchers(settings, "vpnDomainRules");
    let (direct, skipped_direct) = matchers(settings, "directDomainRules");
    // DNS rules match names; CIDRs belong only in the traffic rules.
    let mut vpn_dns = vpn.clone();
    vpn_dns.remove("ip_cidr");
    let mut direct_dns = direct.clone();
    direct_dns.remove("ip_cidr");
    let cidrs = direct_cidrs(settings);
    let non_cn = rule_set("geosite-geolocation-!cn");

    // Explicit direct rules win overlaps, then VPN exceptions precede the
    // automatic mainland/foreign split and the unknown-traffic default.
    let mut dns_rules = Vec::new();
    let mut route_rules = vec![
        json!({"inbound":["tun-in"],"action":"sniff"}),
        json!({"network":["udp","tcp"],"port":[53],"action":"hijack-dns"}),
    ];
    if !direct_dns.is_empty() {
        dns_rules.push(rule(&direct_dns, json!({"server":"ali"})));
    }
    if !direct.is_empty() {
        route_rules.push(rule(&direct, json!({"outbound":"direct"})));
    }
    if !vpn.is_empty() {
        if !vpn_dns.is_empty() {
            proxied_dns(&vpn_dns, &mut dns_rules);
        }
        if quic {
            block_quic(&vpn, &mut route_rules);
        }
        route_rules.push(rule(&vpn, json!({"outbound":"proxy"})));
    }
    let mut rule_sets = Vec::new();
    if let Some(g) = &opts.geo {
        for (tag, path) in [
            ("geosite-cn", &g.geosite_cn),
            ("geoip-cn", &g.geoip_cn),
            ("geosite-geolocation-!cn", &g.geosite_non_cn),
        ] {
            rule_sets.push(json!({"type":"local","tag":tag,"format":"binary","path":path}));
        }
        dns_rules.push(rule(&rule_set("geosite-cn"), json!({"server":"ali"})));
        proxied_dns(&non_cn, &mut dns_rules);
        route_rules.push(rule(&rule_set("geosite-cn"), json!({"outbound":"direct"})));
        route_rules.push(rule(&rule_set("geoip-cn"), json!({"outbound":"direct"})));
    } else if cn_direct_fallback {
        dns_rules.push(json!({"domain_suffix":DIRECT_DOMAINS,"server":"ali"}));
        dns_final = "cloudflare";
    }
    route_rules.push(json!({"domain_suffix":DIRECT_DOMAINS,"outbound":"direct"}));
    route_rules.push(json!({"ip_cidr":cidrs,"outbound":"direct"}));
    if quic && opts.geo.is_some() {
        block_quic(&non_cn, &mut route_rules);
    }
    if quic && final_outbound == "proxy" {
        block_quic(&Map::new(), &mut route_rules);
    }
    if opts.geo.is_some() {
        route_rules.push(rule(&non_cn, json!({"outbound":"proxy"})));
        route_rules.push(rule(
            &rule_set("geoip-cn"),
            json!({"invert":true,"outbound":"proxy"}),
        ));
    }

    let automatic = settings["selectedProxy"] == "AUTO" && !converted.is_empty();
    if automatic {
        selected = "__QZ_MOBILE_AUTO__".into();
        status = "automatic-urltest";
        message = "按延迟自动选择可用节点，间隔 10 分钟，闲置时暂停。".into();
    }
    let balanced = settings["selectedProxy"] == "BALANCE" && !converted.is_empty();
    if balanced {
        selected = "__QZ_MOBILE_BALANCE__".into();
        status = "destination-load-balance";
        message = "按目标稳定分配节点；建连失败时切换其他可用节点。".into();
    }
    let mut selector: Vec<String> = converted.iter().map(|c| c.tag.clone()).collect();
    selector.push("direct".into());
    if !selector.contains(&selected) {
        selector.push(selected.clone());
    }
    let mut outbounds = vec![
        json!({"type":"selector","tag":"proxy","outbounds":selector,"default":selected,"interrupt_exist_connections":true}),
        json!({"type":"direct","tag":"direct"}),
        json!({"type":"block","tag":"block"}),
    ];
    outbounds.extend(node_outbounds);
    if automatic {
        outbounds.push(json!({"type":"urltest","tag":"__QZ_MOBILE_AUTO__","outbounds":converted.iter().map(|c|c.tag.clone()).collect::<Vec<_>>(),"url":"https://www.gstatic.com/generate_204","interval":"10m","idle_timeout":"15m","tolerance":50,"interrupt_exist_connections":true}));
    }
    if balanced {
        outbounds.push(json!({"type":"qz-load-balance","tag":"__QZ_MOBILE_BALANCE__","outbounds":converted.iter().map(|c|c.tag.clone()).collect::<Vec<_>>() }));
    }
    let mut route = json!({
        "auto_detect_interface":true,
        "default_domain_resolver":opts.domain_resolver,
        "rules":route_rules,
        "final":final_outbound,
    });
    if !rule_sets.is_empty() {
        route["rule_set"] = json!(rule_sets);
    }
    let mut config = json!({
        "log":{"level":"warn","timestamp":true},
        "dns":{
            "servers":[
                {"tag":"ali","type":"udp","server":"223.5.5.5","server_port":53},
                {"tag":"cloudflare-direct","type":"tcp","server":"1.1.1.1","server_port":53},
                {"tag":"cloudflare","type":"tcp","server":"1.1.1.1","server_port":53,"detour":"proxy"},
                {"tag":"fakeip","type":"fakeip","inet4_range":"198.19.0.0/16"},
            ],
            "rules":dns_rules,
            "strategy":"ipv4_only",
            "reverse_mapping":true,
            "final":dns_final,
        },
        "inbounds":[{"type":"tun","tag":"tun-in","address":[TUN_ADDRESS,TUN_ADDRESS6],"mtu":opts.mtu,"auto_route":false,"strict_route":true}],
        "outbounds":outbounds,
        "route":route,
        "experimental":{"cache_file":{"enabled":true,"store_fakeip":true}},
    });
    crate::static_exit::apply_singbox(&mut config, settings, &opts.exit_credential)?;
    add_mobile_probes(store, &mut config, settings, opts, &converted)?;
    crate::mobile::company::apply_singbox(store, &mut config, &opts.company_tunnel)?;
    let runtime_revision = crate::mobile::profile::persist(
        store,
        "singbox",
        &config,
        settings,
        &opts.ports,
        converted
            .iter()
            .map(|node| (node.identity.clone(), node.tag.clone()))
            .collect(),
        json!(selected),
    )?;
    Ok(json!({
        "config":serde_json::to_string_pretty(&config)?,
        "summary":{
            "selectedProxy":settings["selectedProxy"],
            "providerNodeCount":all.len(),
            "convertedOutboundCount":converted.len(),
            "unsupportedNodeCount":all.len() - converted.len(),
            "selectedOutboundTag":selected,
            "selectedProxyStatus":status,
            "selectedProxyMessage":message,
            "unknownTrafficPolicy":settings["unknownTraffic"],
            "packetTunnelMTU":opts.mtu,
            "skippedRuleCount":skipped_vpn + skipped_direct,
            "directCidrs":cidrs,
            "geoRuleSets":opts.geo.is_some(),
            "geoFallback":fallback,
            "viaStaticExit":settings["staticExit"]["enabled"] == true,
            "runtimeRevision":runtime_revision,
        },
    }))
}
