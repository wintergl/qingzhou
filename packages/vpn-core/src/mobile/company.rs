//! Native Go owns authentication and the socket; Rust owns every routing rule.
use crate::{
    company,
    storage::{Storage, sha256},
};
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};

pub(crate) fn record(store: &Storage) -> Result<Value> {
    store.read("mobile-company.json",json!({"enabled":false,"origin":"","username":"","domain":"","fingerprint":"","resources":[],"remember":false,"passwordChangeUncertain":false}))
}
pub(crate) fn record_key(store: &Storage) -> Result<String> {
    let r = record(store)?;
    let mut relevant = json!({});
    for key in ["enabled", "origin", "username", "fingerprint", "resources"] {
        relevant[key] = r[key].clone();
    }
    Ok(sha256(&serde_json::to_vec(&relevant)?))
}
fn name(record: &Value) -> String {
    format!(
        "COMPANY-{}",
        &sha256(
            format!(
                "{}|{}|{}",
                record["origin"], record["username"], record["fingerprint"]
            )
            .as_bytes()
        )[..16]
    )
}
fn plan(record: &Value, port: u16, base: Value) -> Result<company::Plan> {
    company::compile_mobile(base, port, &name(record), &record["resources"])
}
fn tunnel_port(record: &Value, transport: &Value) -> u16 {
    if ["origin", "username", "fingerprint"]
        .iter()
        .all(|k| record[*k] == transport[*k])
    {
        transport["port"]
            .as_u64()
            .and_then(|p| u16::try_from(p).ok())
            .filter(|p| *p > 0)
            .unwrap_or(9)
    } else {
        9
    }
}
pub(super) fn handles(channel: &str) -> bool {
    channel.starts_with("company:mobile:")
}
pub(super) fn handle(store: &Storage, channel: &str, p: &Value) -> Result<Value> {
    match channel {
        "company:mobile:get" => record(store),
        "company:mobile:configure" => {
            let mut r = record(store)?;
            let patch = p.as_object().context("接入设置格式无效。")?;
            for (key, value) in patch {
                ensure!(
                    [
                        "enabled",
                        "origin",
                        "username",
                        "domain",
                        "fingerprint",
                        "resources",
                        "remember",
                        "passwordChangeUncertain"
                    ]
                    .contains(&key.as_str()),
                    "此接口不接受接入密码或会话数据。"
                );
                r[key] = value.clone();
            }
            for flag in ["enabled", "remember", "passwordChangeUncertain"] {
                ensure!(r[flag].is_boolean(), "接入开关格式无效。");
            }
            if r["enabled"] == true || !r["origin"].as_str().unwrap_or("").is_empty() {
                let u = url::Url::parse(r["origin"].as_str().context("接入地址格式无效。")?)?;
                ensure!(
                    u.scheme() == "https"
                        && u.host_str().is_some()
                        && u.username().is_empty()
                        && u.password().is_none()
                        && matches!(u.path(), "" | "/")
                        && u.query().is_none()
                        && u.fragment().is_none(),
                    "请填写不含账号、路径或令牌的 HTTPS 接入地址。"
                );
                r["origin"] = json!(u.as_str().trim_end_matches('/'));
            }
            if r["enabled"] == true {
                ensure!(
                    r["username"].as_str().is_some_and(|s| !s.trim().is_empty()),
                    "缺少接入账号。"
                );
                let pin = r["fingerprint"].as_str().unwrap_or("").replace(':', "");
                ensure!(
                    pin.len() == 64 && pin.chars().all(|v| v.is_ascii_hexdigit()),
                    "请先检测并确认网关证书。"
                );
                plan(&r, 9, json!({"rules":[],"proxies":[]}))?;
            }
            store.write("mobile-company.json", &r)?;
            Ok(r)
        }
        "company:mobile:bind" => {
            let profile = store.read("runtime-state/mobile-profile.json", Value::Null)?;
            ensure!(
                profile["revision"] == p["expectedRevision"] && p["expectedRevision"].is_string(),
                "运行配置已变化，未绑定旧接入会话。"
            );
            ensure!(
                profile["settingsKey"] == super::profile::settings_key(&store.settings()?)?
                    && profile["manifestRevision"] == store.manifest()?["revision"],
                "分流或订阅已变化，请重新生成配置。"
            );
            let r = record(store)?;
            ensure!(
                r["enabled"] == true && tunnel_port(&r, &p["transport"]) != 9,
                "接入会话与当前网关或账号不匹配。"
            );
            ensure!(
                profile["companyKey"] == record_key(store)?,
                "接入授权已变化，请重新生成配置。"
            );
            let mut config: Value =
                serde_json::from_str(p["config"].as_str().context("缺少待绑定的配置。")?)?;
            ensure!(
                sha256(&serde_json::to_vec(&config)?) == p["expectedRevision"],
                "待绑定配置与已生成配置不一致。"
            );
            let engine = profile["engine"].as_str().context("缺少运行内核。")?;
            let tag = name(&r);
            let (list, key) = if engine == "singbox" {
                ("outbounds", "tag")
            } else {
                ("proxies", "name")
            };
            let outbound = config[list]
                .as_array_mut()
                .and_then(|nodes| nodes.iter_mut().find(|n| n[key] == tag))
                .context("配置未包含当前接入出口。")?;
            if engine == "singbox" {
                *outbound = json!({"type":"socks","tag":tag,"server":"127.0.0.1","server_port":tunnel_port(&r,&p["transport"]),"version":"5"});
            } else {
                outbound["port"] = json!(tunnel_port(&r, &p["transport"]));
            }
            let mut ports = super::profile::Ports::from_payload(&json!({}));
            for (field, target) in [
                ("mixed", &mut ports.mixed),
                ("controller", &mut ports.controller),
                ("probe", &mut ports.probe),
                ("current", &mut ports.current),
            ] {
                *target = profile[field].as_u64().context("运行端口无效。")? as u16;
            }
            ports.scan = profile["scanPort"].as_u64().unwrap_or(9093) as u16;
            let tags = serde_json::from_value(profile["nodes"].clone())?;
            let revision = super::profile::persist(
                store,
                engine,
                &config,
                &store.settings()?,
                &ports,
                tags,
                profile["selectedTag"].clone(),
            )?;
            Ok(json!({"config":serde_json::to_string(&config)?,"runtimeRevision":revision}))
        }
        _ => bail!("移动接入操作无效。"),
    }
}
pub(crate) fn apply_mihomo(store: &Storage, mut config: Value, transport: &Value) -> Result<Value> {
    let r = record(store)?;
    if r["enabled"] != true {
        return Ok(config);
    }
    let p = plan(&r, tunnel_port(&r, transport), config)?;
    config = p.config;
    if tunnel_port(&r, transport) == 9 {
        let suffix = format!(",{}", name(&r));
        for rule in config["rules"].as_array_mut().unwrap() {
            if let Some(text) = rule.as_str().and_then(|v| v.strip_suffix(&suffix)) {
                *rule = json!(format!("{text},REJECT"));
            }
        }
    }
    // The Android virtual DNS listener belongs ahead of all business routes.
    if let Some(rules) = config["rules"].as_array_mut() {
        if let Some(index) = rules.iter().position(|v| {
            v.as_str().is_some_and(|s| {
                s.starts_with("AND,((IP-CIDR,172.19.0.2/32,no-resolve),(DST-PORT,53))")
            })
        }) {
            let dns = rules.remove(index);
            rules.insert(0, dns);
        }
    }
    Ok(config)
}
pub(crate) fn apply_singbox(store: &Storage, config: &mut Value, transport: &Value) -> Result<()> {
    let r = record(store)?;
    if r["enabled"] != true {
        return Ok(());
    }
    let plan = plan(
        &r,
        tunnel_port(&r, transport),
        json!({"rules":[],"proxies":[]}),
    )?;
    let tag = name(&r);
    config["outbounds"].as_array_mut().context("缺少出口配置。")?.push(if tunnel_port(&r,transport)==9 {json!({"type":"block","tag":tag})}else{json!({"type":"socks","tag":tag,"server":"127.0.0.1","server_port":tunnel_port(&r,transport),"version":"5"})});
    let mut allow = Vec::new();
    let mut deny = Vec::new();
    let mut dns = Vec::new();
    for policy in plan.policy {
        let (kind, value) = policy["match"].as_str().unwrap().split_once(',').unwrap();
        let matcher = match kind {
            "IP-CIDR" => json!({"ip_cidr":[value]}),
            "DOMAIN" => json!({"domain":[value]}),
            "DOMAIN-SUFFIX" => json!({"domain_suffix":[value]}),
            _ => bail!("接入资源类型无效。"),
        };
        if policy["tcp"] == true {
            let mut conditions = vec![matcher.clone(), json!({"network":["tcp"]})];
            let ports = policy["ports"].as_array().unwrap();
            if !ports.contains(&json!("")) {
                let mut numbers = Vec::new();
                let mut ranges = Vec::new();
                for port in ports {
                    let port = port.as_str().unwrap().trim_start_matches("DST-PORT,");
                    if port.contains('-') {
                        ranges.push(port.replace('-', ":"));
                    } else {
                        numbers.push(port.parse::<u16>()?);
                    }
                }
                let mut values = json!({});
                if !numbers.is_empty() {
                    values["port"] = json!(numbers)
                };
                if !ranges.is_empty() {
                    values["port_range"] = json!(ranges)
                };
                conditions.push(values);
            }
            allow.push(json!({"type":"logical","mode":"and","rules":conditions,"outbound":tag}));
        }
        let mut block = matcher.clone();
        block["action"] = json!("reject");
        deny.push(block);
        if kind != "IP-CIDR" {
            for query in [
                json!({"query_type":["AAAA","HTTPS","SVCB"],"action":"predefined","rcode":"NOERROR"}),
                json!({"query_type":["A"],"server":"fakeip"}),
            ] {
                let mut rule = matcher.clone();
                rule.as_object_mut()
                    .unwrap()
                    .extend(query.as_object().unwrap().clone());
                dns.push(rule);
            }
        }
    }
    allow.extend(deny);
    let rules = config["route"]["rules"]
        .as_array_mut()
        .context("缺少路由配置。")?;
    let first = rules
        .iter()
        .position(|v| v["outbound"].is_string() && v.get("inbound").is_none())
        .unwrap_or(rules.len());
    rules.splice(first..first, allow);
    let rules = config["dns"]["rules"]
        .as_array_mut()
        .context("缺少 DNS 规则。")?;
    rules.splice(0..0, dns);
    Ok(())
}
