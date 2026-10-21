use crate::storage::{
    Storage, atomic_write, encode, filename, identity, now, sha256, summarize_subscription,
};
use anyhow::{Context, Result, bail};
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD},
};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    fs,
    sync::{LazyLock, Mutex},
    time::Duration,
};
use url::Url;

pub fn validate_url(raw: &str) -> Result<Url> {
    let u = Url::parse(raw.trim()).context("订阅需要有效的 HTTP/HTTPS 链接。")?;
    if !matches!(u.scheme(), "http" | "https")
        || u.host_str().is_none()
        || !u.username().is_empty()
        || u.password().is_some()
    {
        bail!("订阅需要不含账号密码的 HTTP/HTTPS 链接。");
    }
    Ok(u)
}
pub fn parse_provider(text: &str) -> Result<Vec<Value>> {
    if let Ok(v) = serde_yaml_ng::from_str::<Value>(text) {
        if let Some(proxies) = v["proxies"].as_array() {
            let nodes: Vec<_> = proxies
                .iter()
                .filter(|n| {
                    n["name"].as_str().is_some_and(|s| !s.trim().is_empty())
                        && n["type"].is_string()
                })
                .filter(|n| !is_notice(n))
                .cloned()
                .collect();
            if !nodes.is_empty() {
                return Ok(nodes);
            }
        }
    }
    let compact: String = text.chars().filter(|c| !c.is_whitespace()).collect();
    let decoded = [STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD]
        .iter()
        .find_map(|e| e.decode(&compact).ok())
        .and_then(|bytes| String::from_utf8(bytes).ok());
    let source = decoded
        .as_deref()
        .filter(|s| s.contains("://"))
        .unwrap_or(text);
    let mut nodes = Vec::new();
    let mut saw_uri = false;
    for line in source
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
    {
        // Shadowrocket exports include STATUS= and REMARKS= metadata. Like
        // the original client, parse only URI lines while keeping the original
        // wire content untouched for Mihomo. A malformed URI still fails.
        if !is_node_uri_line(line) {
            continue;
        }
        saw_uri = true;
        if let Some(raw) = line.strip_prefix("vmess://") {
            let v: Value = serde_json::from_slice(
                &STANDARD
                    .decode(raw)
                    .or_else(|_| STANDARD_NO_PAD.decode(raw))?,
            )?;
            nodes.push(json!({"name":v["ps"].as_str().unwrap_or("VMess"),"type":"vmess","server":v["add"],"port":v["port"].as_u64().or_else(||v["port"].as_str()?.parse().ok()).context("VMess 端口无效。")?,"uuid":v["id"],"alterId":v["aid"].as_u64().unwrap_or(0),"cipher":"auto","tls":v["tls"] == "tls","network":v["net"].as_str().unwrap_or("tcp"),"servername":v["sni"],"ws-opts":{"path":v["path"].as_str().unwrap_or("/"),"headers":{"Host":v["host"]}},"grpc-opts":{"grpc-service-name":v["path"]}}));
            continue;
        }
        if line.starts_with("ss://") {
            nodes.push(parse_ss(line)?);
            continue;
        }
        let u = Url::parse(line).context("订阅既不是有效的 Mihomo YAML，也不是支持的节点 URI。")?;
        let kind = match u.scheme() {
            "trojan" | "vless" | "anytls" | "socks5" | "http" | "https" | "hysteria"
            | "hysteria2" | "tuic" | "wireguard" | "snell" | "mieru" | "ssr" => u.scheme(),
            "hy2" => "hysteria2",
            "wg" => "wireguard",
            "socks" => "socks5",
            _ => bail!("暂不支持订阅中的节点协议 {}，旧节点已保留。", u.scheme()),
        };
        let name = percent_encoding::percent_decode_str(
            u.fragment()
                .filter(|s| !s.is_empty())
                .or(u.host_str())
                .unwrap_or(kind),
        )
        .decode_utf8()?
        .to_string();
        let host = u.host_str().context("节点缺少服务器地址。")?;
        let port = u
            .port()
            .or_else(|| u.port_or_known_default())
            .unwrap_or(443);
        let mut n = json!({"name":name,"type":if kind == "https" { "http" } else { kind },"server":host,"port":port});
        let user = percent_encoding::percent_decode_str(u.username())
            .decode_utf8()?
            .to_string();
        let pwd = percent_encoding::percent_decode_str(u.password().unwrap_or(""))
            .decode_utf8()?
            .to_string();
        match kind {
            "vless" => {
                n["uuid"] = json!(user);
                n["tls"] = json!(u.query_pairs().any(|(k, v)| k == "security" && v != "none"));
            }
            "tuic" => {
                n["uuid"] = json!(user);
                n["password"] = json!(pwd);
            }
            "http" | "https" | "socks5" => {
                n["username"] = json!(user);
                n["password"] = json!(pwd);
                if kind == "https" {
                    n["tls"] = json!(true);
                }
            }
            _ => n["password"] = json!(user),
        }
        for (k, v) in u.query_pairs() {
            match k.as_ref() {
                "sni" | "peer" | "serverName" => n["sni"] = json!(v),
                "insecure" | "allowInsecure" => {
                    n["skip-cert-verify"] = json!(matches!(v.as_ref(), "1" | "true"))
                }
                "type" if matches!(kind, "vless" | "trojan") => n["network"] = json!(v),
                "serviceName" => n["grpc-opts"]["grpc-service-name"] = json!(v),
                "congestion_control" => n["congestion-controller"] = json!(v),
                "flow" => n["flow"] = json!(v),
                "fp" => n["client-fingerprint"] = json!(v),
                "pbk" => n["reality-opts"]["public-key"] = json!(v),
                "sid" => n["reality-opts"]["short-id"] = json!(v),
                "path" => n["ws-opts"]["path"] = json!(v),
                "host" => n["ws-opts"]["headers"]["Host"] = json!(v),
                "alpn" => n["alpn"] = json!(v.split(',').collect::<Vec<_>>()),
                "udp" => n["udp"] = json!(matches!(v.as_ref(), "1" | "true" | "yes" | "on")),
                "network" | "packet-encoding" | "packetEncoding" => {
                    n[if k == "packetEncoding" {
                        "packet-encoding"
                    } else {
                        k.as_ref()
                    }] = json!(v)
                }
                "obfs" | "obfs-password" | "congestion-controller" | "udp-relay-mode" => {
                    n[k.as_ref()] = json!(v)
                }
                _ => {}
            }
        }
        nodes.push(n);
    }
    nodes.retain(|n| !is_notice(n));
    if nodes.is_empty() {
        if !saw_uri {
            bail!("订阅既不是有效的 Mihomo YAML，也不是支持的节点 URI。");
        }
        bail!("订阅没有真实可用节点，旧节点已保留。");
    }
    Ok(nodes)
}
fn is_node_uri_line(line: &str) -> bool {
    let Some((scheme, _)) = line.split_once("://") else {
        return false;
    };
    let mut bytes = scheme.bytes();
    bytes.next().is_some_and(|b| b.is_ascii_alphabetic())
        && bytes.all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'-' | b'.'))
}
fn is_notice(n: &Value) -> bool {
    matches!(
        n["server"].as_str(),
        Some("127.0.0.1" | "localhost" | "::1")
    ) && [
        "客户端版本太旧",
        "请升级",
        "安装方式看官网",
        "不懂的问题联系",
    ]
    .iter()
    .any(|t| n["name"].as_str().unwrap_or("").contains(t))
}
fn parse_ss(line: &str) -> Result<Value> {
    let (link, name) = line
        .strip_prefix("ss://")
        .unwrap()
        .split_once('#')
        .unwrap_or((&line[5..], "Shadowsocks"));
    let link = if link.contains('@') {
        link.to_owned()
    } else {
        // Legacy `ss://base64(method:pass@host:port)?query`: only the part
        // before `?` is encoded.
        let (encoded, query) = link.split_once('?').unwrap_or((link, ""));
        let mut decoded = String::from_utf8(
            STANDARD
                .decode(encoded)
                .or_else(|_| STANDARD_NO_PAD.decode(encoded))
                .or_else(|_| URL_SAFE_NO_PAD.decode(encoded))?,
        )?;
        if !query.is_empty() {
            decoded = format!("{decoded}?{query}");
        }
        decoded
    };
    let (user, host) = link.split_once('@').context("Shadowsocks 节点格式无效。")?;
    let user = if user.contains(':') {
        user.into()
    } else {
        String::from_utf8(
            STANDARD
                .decode(user)
                .or_else(|_| STANDARD_NO_PAD.decode(user))
                .or_else(|_| URL_SAFE_NO_PAD.decode(user))?,
        )?
    };
    let (cipher, pwd) = user
        .split_once(':')
        .context("Shadowsocks 节点凭据格式无效。")?;
    let u = Url::parse(&format!("http://{host}"))?;
    let mut node = json!({"name":percent_encoding::percent_decode_str(name).decode_utf8()?,"type":"ss","server":u.host_str(),"port":u.port_or_known_default().context("节点缺少端口。")?,"cipher":cipher,"password":pwd,"udp":true});
    if let Some((_, plugin)) = u.query_pairs().find(|(k, _)| k == "plugin") {
        let mut parts = plugin.split(';');
        node["plugin"] = json!(parts.next().unwrap_or(""));
        let mut opts = json!({});
        for part in parts {
            let (k, v) = part.split_once('=').unwrap_or((part, "true"));
            opts[k] = if v == "true" { json!(true) } else { json!(v) };
        }
        node["plugin-opts"] = opts;
    }
    Ok(node)
}
/// Committed provider content of every enabled subscription with nodes:
/// `(subscription entry, manifest pointer, parsed raw nodes)`.
pub fn enabled_providers(store: &Storage) -> Result<Vec<(Value, Value, Vec<Value>)>> {
    let record = store.subscription()?;
    let manifest = store.manifest()?;
    let mut out = Vec::new();
    for e in record["entries"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["enabled"] == true && e["nodeCount"].as_u64().unwrap_or(0) > 0)
    {
        let id = e["id"].as_str().context("订阅缺少标识。")?;
        let p = manifest["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["subscriptionId"] == id);
        if let Some(p) = p {
            let path = p["providerPath"]
                .as_str()
                .context("订阅 provider 路径无效。")?;
            out.push((e.clone(), p.clone(), cached_nodes(path)?));
        }
    }
    Ok(out)
}
/// Node lists are rebuilt on nearly every request and a provider can be
/// megabytes of YAML, so parsed nodes are kept per file version.
fn cached_nodes(path: &str) -> Result<Vec<Value>> {
    type Key = (String, u64, Option<std::time::SystemTime>);
    static CACHE: LazyLock<Mutex<HashMap<Key, Vec<Value>>>> = LazyLock::new(Default::default);
    let meta = fs::metadata(path)?;
    let key = (path.to_owned(), meta.len(), meta.modified().ok());
    if let Some(nodes) = CACHE.lock().ok().and_then(|c| c.get(&key).cloned()) {
        return Ok(nodes);
    }
    let nodes = parse_provider(&fs::read_to_string(path)?)?;
    if let Ok(mut cache) = CACHE.lock() {
        cache.retain(|(p, _, _), _| p != path);
        if cache.len() >= 32 {
            cache.clear();
        }
        cache.insert(key, nodes.clone());
    }
    Ok(nodes)
}
/// Removes committed provider revisions (`<id>.<sha256>.yaml`) that no
/// manifest entry points at. Call only after the manifest is committed: a
/// rolled-back transaction restores pointers to the previous revisions.
pub fn prune_providers(store: &Storage) -> Result<()> {
    let manifest = store.manifest()?;
    let keep: HashSet<String> = manifest["entries"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|p| {
            std::path::Path::new(p["providerPath"].as_str()?)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
        })
        .collect();
    let dir = match fs::read_dir(store.path("mihomo/providers")) {
        Ok(dir) => dir,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e.into()),
    };
    for entry in dir {
        let path = entry?.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let revision = name
            .strip_suffix(".yaml")
            .and_then(|s| s.rsplit_once('.'))
            .is_some_and(|(_, rev)| rev.len() == 64 && rev.bytes().all(|b| b.is_ascii_hexdigit()));
        if revision && !keep.contains(name) {
            let _ = fs::remove_file(&path);
        }
    }
    Ok(())
}
/// `(udp capability, whether the provider declared it explicitly)`.
pub fn udp_capability(n: &Value) -> (Option<bool>, bool) {
    let boolean = |v: &Value| {
        v.as_bool()
            .or_else(|| match v.as_str()?.to_ascii_lowercase().as_str() {
                "true" | "1" | "yes" | "on" => Some(true),
                "false" | "0" | "no" | "off" => Some(false),
                _ => None,
            })
    };
    let explicit_udp = boolean(&n["udp"]);
    let udp = explicit_udp.or_else(|| {
        let packet = n["packet-encoding"].as_str();
        let relay = n["udp-relay-mode"].as_str();
        (matches!(
            n["type"].as_str(),
            Some("hysteria" | "hysteria2" | "tuic" | "wireguard")
        ) || packet.is_some_and(|p| p != "none" && p != "packetaddr")
            || relay.is_some_and(|p| p != "none")
            || n["network"]
                .as_str()
                .is_some_and(|p| p.split([',', ' ', '/']).any(|p| p == "udp")))
        .then_some(true)
    });
    (udp, explicit_udp.is_some())
}
pub fn provider_nodes(store: &Storage) -> Result<Vec<Value>> {
    let mut out = Vec::new();
    for (e, p, nodes) in enabled_providers(store)? {
        let id = e["id"].as_str().unwrap();
        for n in nodes {
            let name = n["name"].as_str().unwrap().to_owned();
            let (udp, explicit) = udp_capability(&n);
            out.push(json!({"name":name,"type":n["type"],"identityKey":identity(id,&name),"subscriptionId":id,"subscriptionName":e["name"],"providerRevision":p["providerRevision"],"identityAmbiguous":false,"selected":false,"delay":null,"available":null,"location":location(&name),"transport":{"tcp":"supported","udp":match udp {Some(true)=>"supported",Some(false)=>"unsupported",None=>"unknown"},"udpSource":if explicit{json!("provider-explicit")}else if udp == Some(true){json!("protocol-capability")}else{Value::Null}},"runtimeUdpSupported":udp}));
        }
    }
    let mut counts = HashMap::new();
    for n in &out {
        *counts
            .entry(n["name"].as_str().unwrap().to_string())
            .or_insert(0) += 1;
    }
    for n in &mut out {
        let name = n["name"].as_str().unwrap();
        n["identityAmbiguous"] = json!(
            counts[name] > 1
                || [
                    "DIRECT",
                    "REJECT",
                    "REJECT-DROP",
                    "VPN",
                    "AUTO",
                    "BALANCE",
                    "THROUGHPUT",
                    "WECHAT",
                    "PROBE"
                ]
                .contains(&name)
                || name.starts_with("COMPANY-")
                || name.starts_with("SG_")
                || name.starts_with("SGN_")
        );
    }
    Ok(out)
}
pub fn location(name: &str) -> Value {
    let lower = name.to_lowercase();
    let mapping = [
        ("日本", "东京", ["日本", "东京", "tokyo", "japan", "🇯🇵"]),
        (
            "美国",
            "",
            ["美国", "us ", "united states", "america", "🇺🇸"],
        ),
        ("香港", "", ["香港", "hong kong", "hongkong", "hk ", "🇭🇰"]),
        ("新加坡", "", ["新加坡", "singapore", "sg ", "🇸🇬", "狮城"]),
        ("台湾", "", ["台湾", "taiwan", "tw ", "🇹🇼", "台北"]),
        ("韩国", "", ["韩国", "korea", "seoul", "🇰🇷", "首尔"]),
        ("英国", "", ["英国", "uk ", "london", "🇬🇧", "伦敦"]),
        (
            "德国",
            "",
            ["德国", "germany", "frankfurt", "🇩🇪", "法兰克福"],
        ),
    ];
    for (country, city, keys) in mapping {
        if keys.iter().any(|k| lower.contains(k)) {
            return json!({"country":country,"city":if city.is_empty(){Value::Null}else{json!(city)},"source":"name"});
        }
    }
    json!({"country":null,"city":null,"source":"unknown"})
}
pub struct Downloaded {
    pub nodes: Vec<Value>,
    pub content: String,
}
/// Preserve protocol-specific fields for Mihomo's own parser. Only notice
/// removal and the existing AnyTLS URI alias are applied to the wire content.
pub fn prepare_content(text: &str) -> Result<String> {
    if let Ok(mut v) = serde_yaml_ng::from_str::<Value>(text) {
        if let Some(proxies) = v.get_mut("proxies").and_then(Value::as_array_mut) {
            let count = proxies.len();
            proxies.retain(|n| !is_notice(n));
            if proxies.is_empty() {
                bail!("订阅没有真实可用节点，旧节点已保留。");
            }
            return if proxies.len() == count {
                Ok(text.into())
            } else {
                Ok(serde_yaml_ng::to_string(&v)?)
            };
        }
    }
    let compact: String = text.chars().filter(|c| !c.is_whitespace()).collect();
    let decoded = [STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD]
        .iter()
        .find_map(|e| e.decode(&compact).ok())
        .and_then(|b| String::from_utf8(b).ok())
        .filter(|s| s.contains("://"));
    let source = decoded.as_deref().unwrap_or(text);
    let mut changed = false;
    let mut lines = Vec::new();
    for line in source.lines() {
        if let Ok(mut u) = Url::parse(line.trim()) {
            let name = percent_encoding::percent_decode_str(u.fragment().unwrap_or(""))
                .decode_utf8_lossy();
            if is_notice(&json!({"name":name,"server":u.host_str()})) {
                changed = true;
                continue;
            }
            let pairs = u.query_pairs().collect::<Vec<_>>();
            let alias = pairs
                .iter()
                .find(|(k, _)| k == "allowInsecure")
                .map(|(_, v)| v.to_ascii_lowercase());
            if u.scheme() == "anytls" && !pairs.iter().any(|(k, _)| k == "insecure") {
                if let Some(alias) =
                    alias.filter(|a| ["0", "1", "true", "false"].contains(&a.as_str()))
                {
                    u.query_pairs_mut().append_pair(
                        "insecure",
                        if alias == "1" || alias == "true" {
                            "1"
                        } else {
                            "0"
                        },
                    );
                    lines.push(u.to_string());
                    changed = true;
                    continue;
                }
            }
        }
        lines.push(line.to_owned());
    }
    if !changed {
        return Ok(text.into());
    }
    let content = lines.join(if source.contains("\r\n") {
        "\r\n"
    } else {
        "\n"
    });
    Ok(if decoded.is_some() {
        STANDARD.encode(content)
    } else {
        content
    })
}
pub const ACCEPT: &str = "application/x-yaml, application/yaml, text/yaml, text/plain, */*";
pub const MAX_BYTES: usize = 8 * 1024 * 1024;
/// Candidate URLs in request order, and whether the provider needs the
/// Shadowrocket compatibility request.
pub fn download_plan(raw: &str) -> Result<(Vec<Url>, bool)> {
    let mut u = validate_url(raw)?;
    // The subscription owner explicitly selects this response format. Do not
    // infer a user's provider from a hard-coded service hostname.
    let compat = u
        .query_pairs()
        .any(|(k, v)| k == "list" && v == "shadowrocket");
    let mut urls = Vec::new();
    if compat {
        let pairs: Vec<_> = u
            .query_pairs()
            .filter(|(k, _)| !matches!(k.as_ref(), "clash" | "flag" | "target" | "list"))
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect();
        u.set_query(None);
        u.query_pairs_mut()
            .extend_pairs(pairs)
            .append_pair("list", "shadowrocket");
        urls.push(u);
    } else {
        urls.push(u.clone());
        for (key, value) in [("flag", "clash"), ("target", "clash"), ("clash", "1")] {
            if !u.query_pairs().any(|(k, _)| k == key) {
                let mut candidate = u.clone();
                candidate.query_pairs_mut().append_pair(key, value);
                urls.push(candidate);
            }
        }
    }
    Ok((urls, compat))
}
pub fn user_agent(compat: bool) -> &'static str {
    if compat {
        "Shadowrocket/2997 CFNetwork/3860.500.111.2.2 Darwin/25.0.0"
    } else {
        "Clash.Meta/1.19.13 mihomo/1.19.13 split-vpn/0.1"
    }
}
/// Activation pages of the compatibility provider answer 404 with a notice.
pub fn needs_activation(compat: bool, status: u16, text: &str) -> bool {
    compat && status == 404 && text.contains("订阅已过期") && text.contains("点击激活")
}
pub const ACTIVATION_ERROR: &str = "机场订阅需要重新激活，请登录官网点击激活后再更新。";
pub fn download(raw: &str, mixed_port: Option<u16>) -> Result<Downloaded> {
    let (urls, compat) = download_plan(raw)?;
    let mut client = reqwest::blocking::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(30))
        .redirect(reqwest::redirect::Policy::limited(5));
    if let Some(port) = mixed_port {
        client = client.proxy(reqwest::Proxy::all(format!("http://127.0.0.1:{port}"))?);
    }
    let client = client.build()?;
    let mut last_error = None;
    for (index, u) in urls.into_iter().enumerate() {
        let response = client
            .get(u)
            .header("accept", ACCEPT)
            .header("user-agent", user_agent(compat))
            .send();
        let response = match response {
            Ok(response) => response,
            Err(e) if index == 0 => return Err(e.into()),
            Err(e) => {
                last_error = Some(e.into());
                continue;
            }
        };
        let status = response.status();
        let mut bytes = Vec::new();
        use std::io::Read;
        response
            .take(MAX_BYTES as u64 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > MAX_BYTES {
            bail!("订阅内容超过 8 MB，旧节点已保留。");
        }
        let text = std::str::from_utf8(&bytes)?;
        if !status.is_success() {
            if needs_activation(compat, status.as_u16(), text) {
                bail!(ACTIVATION_ERROR);
            }
            if index == 0 {
                bail!("订阅下载失败（HTTP {}），旧节点已保留。", status.as_u16());
            }
            continue;
        }
        let prepared = prepare_content(text).and_then(|content| {
            Ok(Downloaded {
                nodes: parse_provider(&content)?,
                content,
            })
        });
        match prepared {
            Ok(downloaded) => return Ok(downloaded),
            Err(e) => last_error = Some(e),
        }
    }
    Err(last_error.unwrap_or_else(|| anyhow::anyhow!("订阅格式错误，未获取到 Mihomo 节点。")))
}
pub fn commit_update(
    store: &Storage,
    record: &mut Value,
    manifest: &mut Value,
    id: &str,
    downloaded: Downloaded,
) -> Result<bool> {
    let nodes = downloaded.nodes;
    let yaml = downloaded.content;
    let rev = sha256(yaml.as_bytes());
    let changed = !manifest["entries"]
        .as_array()
        .unwrap()
        .iter()
        .any(|p| p["subscriptionId"] == id && p["providerRevision"] == rev);
    let p = store.path(&format!("mihomo/providers/{}.{}.yaml", filename(id), rev));
    atomic_write(&p, yaml.as_bytes())?;
    let legacy = store.path(&format!("mihomo/providers/{}.yaml", filename(id)));
    if !legacy.exists() {
        atomic_write(&legacy, yaml.as_bytes())?;
    }
    let pointers = manifest["entries"].as_array_mut().unwrap();
    pointers.retain(|p| p["subscriptionId"] != id);
    pointers.push(json!({"subscriptionId":id,"providerPath":p,"providerRevision":rev}));
    let entry = record["entries"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|e| e["id"] == id)
        .context("找不到这条订阅。")?;
    entry["nodeCount"] = json!(nodes.len());
    entry["status"] = json!("ready");
    entry["lastError"] = Value::Null;
    entry["updatedAt"] = json!(now());
    entry["lastAttemptAt"] = json!(now());
    summarize_subscription(record);
    Ok(changed)
}
pub fn due_ids(record: &Value) -> Vec<String> {
    let now = chrono::Utc::now();
    record["entries"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["enabled"] == true && !e["updateIntervalMinutes"].is_null())
        .filter_map(|e| {
            let interval = e["updateIntervalMinutes"].as_i64().unwrap_or(1440);
            let failed = !e["lastError"].is_null();
            let last = e[if failed { "lastAttemptAt" } else { "updatedAt" }]
                .as_str()
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok());
            if last.is_none_or(|t| {
                (now - t.with_timezone(&chrono::Utc)).num_minutes()
                    >= if failed { interval.min(60) } else { interval }
            }) {
                e["id"].as_str().map(str::to_owned)
            } else {
                None
            }
        })
        .collect()
}

pub fn provider_name(id: &str) -> String {
    filename(id)
}
pub fn controller_component(name: &str) -> String {
    encode(name)
}
