use crate::{
    config, platform,
    runtime::Engine,
    storage::{now, sha256, valid_domain},
};
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    fs,
    net::Ipv4Addr,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

#[derive(Clone)]
pub struct Plan {
    pub config: Value,
    pub routes: Vec<String>,
    pub rule_count: usize,
    pub policy: Vec<Value>,
}
#[derive(Clone, Copy)]
struct Block {
    start: u32,
    bits: u8,
}
impl Block {
    fn parse(s: &str) -> Result<Self> {
        let (ip, bits) = s.split_once('/').unwrap_or((s, "32"));
        let bits: u8 = bits.parse()?;
        ensure!(bits <= 32, "私有网络网段前缀无效。");
        let ip: u32 = ip.parse::<Ipv4Addr>()?.into();
        let mask = if bits == 0 {
            0
        } else {
            u32::MAX << (32 - bits)
        };
        Ok(Self {
            start: ip & mask,
            bits,
        })
    }
    fn end(self) -> u64 {
        self.start as u64 + (1u64 << (32 - self.bits)) - 1
    }
    fn text(self) -> String {
        format!("{}/{}", Ipv4Addr::from(self.start), self.bits)
    }
    fn subtract(self, cut: Self) -> Vec<Self> {
        if self.end() < cut.start as u64 || cut.end() < self.start as u64 {
            return vec![self];
        }
        if cut.start <= self.start && cut.end() >= self.end() {
            return vec![];
        }
        let bits = self.bits + 1;
        let half = 1u32 << (32 - bits);
        [
            Self {
                start: self.start,
                bits,
            },
            Self {
                start: self.start + half,
                bits,
            },
        ]
        .into_iter()
        .flat_map(|b| b.subtract(cut))
        .collect()
    }
}
pub fn subtract_routes(excluded: &[String], included: &[String]) -> Result<Vec<String>> {
    let cuts = included
        .iter()
        .map(|s| Block::parse(s))
        .collect::<Result<Vec<_>>>()?;
    let mut out = Vec::new();
    for s in excluded {
        if s.contains(':') {
            out.push(s.clone());
            continue;
        }
        let mut blocks = vec![Block::parse(s)?];
        for cut in &cuts {
            blocks = blocks.into_iter().flat_map(|b| b.subtract(*cut)).collect();
        }
        out.extend(blocks.into_iter().map(Block::text));
    }
    Ok(out)
}
type AddressRule = (String, Option<String>, Option<String>);
fn addresses(raw: &str) -> Result<Vec<AddressRule>> {
    let mut result = Vec::new();
    for raw in raw
        .split(|c: char| c == ',' || c == ';' || c.is_whitespace())
        .filter(|s| !s.is_empty())
    {
        let v = if raw.contains("://") {
            let u = business_target(raw)?;
            u.host_str().context("接入网址缺少主机。")?.to_owned()
        } else {
            raw.into()
        };
        ensure!(
            !v.contains(':'),
            "当前私有网络 TCP 接入暂不支持 IPv6 授权地址。"
        );
        if let Some((a, b)) = v
            .split_once('-')
            .filter(|(a, _)| a.parse::<Ipv4Addr>().is_ok())
        {
            let mut first = u32::from(a.parse::<Ipv4Addr>()?) as u64;
            let last = u32::from(b.parse::<Ipv4Addr>()?) as u64;
            ensure!(first <= last, "授权 IP 范围无效。");
            while first <= last {
                let mut bits = 32;
                while bits > 0
                    && first % (1u64 << (33 - bits)) == 0
                    && first + (1u64 << (33 - bits)) - 1 <= last
                {
                    bits -= 1;
                }
                let block = Block {
                    start: first as u32,
                    bits,
                };
                validate_block(block)?;
                let cidr = block.text();
                result.push((format!("IP-CIDR,{cidr}"), Some(cidr), None));
                first = block.end() + 1;
            }
            continue;
        }
        if v.contains('/') || v.parse::<Ipv4Addr>().is_ok() {
            let b = Block::parse(&v)?;
            validate_block(b)?;
            let cidr = b.text();
            result.push((format!("IP-CIDR,{cidr}"), Some(cidr), None));
        } else {
            let suffix = v.starts_with("*.");
            let d = v
                .trim_start_matches("*.")
                .trim_end_matches('.')
                .to_lowercase();
            ensure!(valid_domain(&d) && d.contains('.'), "授权域名无效。");
            result.push((
                format!("{},{d}", if suffix { "DOMAIN-SUFFIX" } else { "DOMAIN" }),
                None,
                Some(d),
            ));
        }
    }
    Ok(result)
}
fn validate_block(b: Block) -> Result<()> {
    ensure!(
        b.start >= 0x01000000
            && b.end() < 0xe0000000
            && !(b.start <= 0x7fffffff && b.end() >= 0x7f000000),
        "授权资源包含无效的业务网段。"
    );
    Ok(())
}
fn ports(s: &str) -> Result<Vec<String>> {
    let s = s.trim().to_lowercase();
    if matches!(s.as_str(), "all" | "any" | "*" | "1-65535" | "0-65535") {
        return Ok(vec![String::new()]);
    }
    ensure!(!s.is_empty(), "授权未明确提供端口，不能扩大为所有端口。");
    s.split(|c: char| c == ',' || c == ';' || c.is_whitespace())
        .filter(|s| !s.is_empty())
        .map(|s| {
            let (a, b) = s.split_once('-').unwrap_or((s, s));
            let a: u16 = a.parse()?;
            let b: u16 = b.parse()?;
            ensure!(a > 0 && b >= a, "授权端口无效。");
            Ok(format!(
                "DST-PORT,{}",
                if a == b {
                    a.to_string()
                } else {
                    format!("{a}-{b}")
                }
            ))
        })
        .collect()
}
pub fn compile(base: Value, port: u16, name: &str, rows: &Value) -> Result<Plan> {
    compile_with_underlay(base, port, name, rows, &[])
}

pub fn compile_with_underlay(
    base: Value,
    port: u16,
    name: &str,
    rows: &Value,
    protected_networks: &[String],
) -> Result<Plan> {
    compile_inner(base, port, name, rows, protected_networks, true)
}

pub(crate) fn compile_mobile(base: Value, port: u16, name: &str, rows: &Value) -> Result<Plan> {
    compile_inner(base, port, name, rows, &[], false)
}

fn compile_inner(
    mut base: Value,
    port: u16,
    name: &str,
    rows: &Value,
    protected_networks: &[String],
    system_tun: bool,
) -> Result<Plan> {
    ensure!(
        port > 0
            && name.starts_with("COMPANY-")
            && name[8..].len() >= 8
            && name[8..].len() <= 32
            && name[8..].chars().all(|c| c.is_ascii_hexdigit()),
        "私有网络隧道出口无效。"
    );
    ensure!(
        !system_tun
            || (base["mode"] == "rule"
                && base["tun"]["enable"] == true
                && base["tun"]["auto-route"] == true),
        "私有网络统一分流需要启用 TUN 和规则模式。"
    );
    let rows = rows.as_array().context("授权资源格式无效。")?;
    ensure!(
        !rows.is_empty() && rows.len() <= 5000,
        "授权资源为空或超过支持数量。"
    );
    let mut allow = Vec::new();
    let mut deny = Vec::new();
    let mut routes = Vec::new();
    let mut domains = Vec::new();
    let mut policy = Vec::new();
    for row in rows {
        let address = row["address"].as_str().context("授权地址格式无效。")?;
        let network = row["network"]
            .as_str()
            .context("授权协议格式无效。")?
            .trim()
            .to_lowercase();
        let rawports = row["ports"].as_str().context("授权端口格式无效。")?;
        if address.trim().is_empty() || (network.is_empty() && rawports.trim().is_empty()) {
            continue;
        }
        ensure!(
            matches!(network.as_str(), "tcp" | "udp" | "all"),
            "授权资源协议不受支持。"
        );
        let ports = ports(rawports)?;
        for (rule, cidr, domain) in addresses(address)? {
            if !system_tun {
                policy.push(json!({"match":rule,"ports":ports,"tcp":network != "udp"}));
            }
            if let Some(cidr) = &cidr {
                routes.push(cidr.clone());
            }
            if let Some(domain) = domain {
                domains.push(domain);
            }
            let no_resolve = if cidr.is_some() { ",no-resolve" } else { "" };
            deny.push(format!("{rule},REJECT{no_resolve}"));
            if network != "udp" {
                for p in &ports {
                    allow.push(format!(
                        "AND,((NETWORK,TCP),({rule}{no_resolve}){}),{name}",
                        if p.is_empty() {
                            String::new()
                        } else {
                            format!(",({p})")
                        }
                    ));
                }
            }
        }
    }
    let unique = |v: &mut Vec<String>| {
        let mut set = HashSet::new();
        v.retain(|s| set.insert(s.clone()));
    };
    unique(&mut allow);
    unique(&mut deny);
    unique(&mut routes);
    unique(&mut domains);
    ensure!(!allow.is_empty(), "接入网关没有下发可用的 TCP 授权资源。");
    let count = allow.len();
    let mut rules = allow;
    rules.extend(deny);
    rules.extend(
        base["rules"]
            .as_array()
            .context("基础分流规则无效。")?
            .iter()
            .filter_map(|r| r.as_str().map(str::to_owned)),
    );
    base["rules"] = json!(rules);
    if let Some(sniffer) = base["sniffer"].as_object_mut() {
        let mut skip = sniffer
            .get("skip-dst-address")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for route in &routes {
            if !skip.contains(&json!(route)) {
                skip.push(json!(route));
            }
        }
        sniffer.insert("skip-dst-address".into(), json!(skip));
    }
    if !base["proxies"].is_array() {
        base["proxies"] = json!([]);
    }
    base["proxies"]
        .as_array_mut()
        .unwrap()
        .push(json!({"name":name,"type":"socks5","server":"127.0.0.1","port":port,"udp":false}));
    let excluded = base["tun"]["route-exclude-address"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|s| s.as_str().map(str::to_owned))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let mut excluded = subtract_routes(&excluded, &routes)?;
    // Native connected routes cannot be replaced by a TUN route on macOS.
    // Keep office LANs and the tunnel's physical gateway outside the TUN;
    // remote authorized resources retain their company rules and interception.
    for network in protected_networks {
        let protected = Block::parse(network)?;
        if !excluded
            .iter()
            .filter_map(|s| Block::parse(s).ok())
            .any(|b| b.start <= protected.start && b.end() >= protected.end())
        {
            excluded.push(protected.text());
        }
    }
    base["tun"]["route-exclude-address"] = json!(excluded);
    if let Some(custom) = base["tun"]["route-address"]
        .as_array_mut()
        .filter(|a| !a.is_empty())
    {
        for r in &routes {
            if !custom.contains(&json!(r)) {
                custom.push(json!(r));
            }
        }
    }
    if let Some(filters) = base
        .get_mut("dns")
        .and_then(|d| d.get_mut("fake-ip-filter"))
        .and_then(Value::as_array_mut)
    {
        filters.retain(|f| {
            f.as_str().is_none_or(|f| {
                let f = f.trim_start_matches("+.").trim_start_matches("*.");
                !domains
                    .iter()
                    .any(|d| d == f || d.ends_with(&format!(".{f}")))
            })
        });
    }
    Ok(Plan {
        config: base,
        routes,
        rule_count: count,
        policy,
    })
}

fn compile_for_engine(
    e: &Engine,
    base: Value,
    port: u16,
    name: &str,
    rows: &Value,
) -> Result<Plan> {
    let protected = if e.isolated {
        Vec::new()
    } else {
        platform::protected_physical_networks()?
    };
    compile_with_underlay(base, port, name, rows, &protected)
}
#[derive(Clone)]
struct Session {
    port: u16,
    helper_pid: u32,
    core_pid: u32,
    name: String,
    rows: Value,
    plan: Plan,
}
#[derive(Default)]
pub struct Company {
    session: Option<Session>,
    proof: Option<Value>,
    internet: Option<Value>,
    last_error: Option<String>,
    applied: bool,
    recovering: bool,
    recovery_count: u32,
    pending: Option<(String, Instant)>,
    attempts: Vec<Instant>,
    paused: bool,
    next: Option<Instant>,
}
impl Company {
    pub fn state(&self) -> Value {
        json!({"active":self.applied&&self.session.is_some(),"verified":self.applied&&self.proof.is_some(),"recovering":self.recovering,"recoveryCount":self.recovery_count,"proxyName":self.session.as_ref().map(|s|&s.name),"ruleCount":self.session.as_ref().map_or(0,|s|s.plan.rule_count),"routes":self.session.as_ref().map(|s|&s.plan.routes).cloned().unwrap_or_default(),"lastError":self.last_error,"proof":self.proof,"internet":self.internet})
    }
    fn journal(&self, engine: &Engine) -> Result<()> {
        if let Some(s) = &self.session {
            engine.store.write("runtime-state/native-company-routing.json",&json!({"proxyName":s.name,"port":s.port,"corePid":s.core_pid,"ownerPid":std::process::id()}))?;
        }
        Ok(())
    }
    pub fn recover(&mut self, e: &mut Engine) -> Result<()> {
        let j = e
            .store
            .read("runtime-state/native-company-routing.json", Value::Null)?;
        if j.is_null() {
            return Ok(());
        }
        if j["ownerPid"]
            .as_u64()
            .is_some_and(|p| p as u32 != std::process::id() && platform::pid_alive(p as u32))
        {
            bail!("另一个原生窗口仍在管理私有网络连接，请先关闭旧窗口。");
        }
        let name = j["proxyName"].as_str().context("私有网络恢复记录无效。")?;
        ensure!(
            name.starts_with("COMPANY-") && name[8..].chars().all(|c| c.is_ascii_hexdigit()),
            "私有网络恢复记录无效。"
        );
        e.attach()?;
        if e.pid.is_none() {
            let recorded_pid = j["corePid"]
                .as_u64()
                .filter(|p| *p > 0 && *p <= u32::MAX as u64)
                .context("私有网络恢复记录缺少内核标识，记录已保留。")?
                as u32;
            ensure!(
                !platform::pid_alive(recorded_pid),
                "暂无法确认现有内核，私有网络恢复记录已保留。"
            );
            let _ = fs::remove_file(e.store.path("runtime-state/native-company-routing.json"));
            return Ok(());
        }
        if e.has_proxy(name)? {
            let picks = e.selections()?;
            let base = config::parse(&fs::read_to_string(e.store.path("mihomo/config.yaml"))?)?;
            e.reload(&config::yaml(&base)?)?;
            e.restore_selections(&picks);
            e.confirm_routing_config(&base)?;
        }
        let _ = fs::remove_file(e.store.path("runtime-state/native-company-routing.json"));
        Ok(())
    }
    pub fn install(&mut self, e: &mut Engine, p: &Value) -> Result<Value> {
        let port = p["port"]
            .as_u64()
            .filter(|p| *p > 0 && *p <= 65535)
            .context("私有网络隧道端口无效。")? as u16;
        let helper = p["helperPid"]
            .as_u64()
            .filter(|p| *p > 0 && *p <= u32::MAX as u64)
            .context("私有网络认证服务标识无效。")? as u32;
        ensure!(
            platform::pid_alive(helper),
            "私有网络认证服务已结束，请重新登录。"
        );
        e.attach()?;
        let pid = e.pid.context("请先连接现有 VPN，再接入私有网络分流。")?;
        if let Some(s) = &self.session {
            if s.port == port && s.helper_pid == helper {
                self.paused = false;
                self.attempts.clear();
                self.next = None;
                self.repair(e)?;
                return Ok(self.state());
            }
            self.remove(e)?;
        }
        let base = fs::read_to_string(e.store.path("mihomo/config.yaml"))?;
        let name = format!(
            "COMPANY-{}",
            &uuid::Uuid::new_v4().simple().to_string()[..16]
        );
        let plan = compile_for_engine(e, config::parse(&base)?, port, &name, &p["rows"])?;
        platform::validate(&e.binary, &e.store, &config::yaml(&plan.config)?)?;
        let selections = e.selections()?;
        ensure!(
            base == fs::read_to_string(e.store.path("mihomo/config.yaml"))? && e.pid == Some(pid),
            "现有 VPN 配置正在变化，请稍后重新接入。"
        );
        self.session = Some(Session {
            port,
            helper_pid: helper,
            core_pid: pid,
            name: name.clone(),
            rows: p["rows"].clone(),
            plan: plan.clone(),
        });
        self.journal(e)?;
        self.proof = None;
        self.internet = None;
        self.last_error = None;
        self.recovery_count = 0;
        self.pending = None;
        self.attempts.clear();
        self.paused = false;
        let result = e.reload(&config::yaml(&plan.config)?).and_then(|_| {
            e.restore_selections(&selections);
            e.confirm_routing_config(&plan.config)?;
            ensure!(e.has_proxy(&name)?, "私有网络分流未完成接入。");
            Ok(())
        });
        if let Err(error) = result {
            if self.remove(e).is_err() {
                self.last_error =
                    Some("私有网络接入失败，恢复记录已保留，请断开私有网络后重试。".into());
            }
            return Err(error);
        }
        self.applied = true;
        self.recovering = false;
        Ok(self.state())
    }
    pub fn reload_base(&mut self, e: &mut Engine, base: &str) -> Result<()> {
        let picks = e.selections()?;
        if let Some(s) = &mut self.session {
            let plan = compile_for_engine(e, config::parse(base)?, s.port, &s.name, &s.rows)?;
            platform::validate(&e.binary, &e.store, &config::yaml(&plan.config)?)?;
            e.reload(&config::yaml(&plan.config)?)?;
            e.confirm_routing_config(&plan.config)?;
            s.plan = plan;
            s.core_pid = e.pid.context("私有网络分流内核已停止。")?;
            self.applied = true;
            self.proof = None;
            self.internet = None;
            self.last_error = None;
            self.journal(e)?;
        } else {
            e.reload(base)?;
        }
        e.restore_selections(&picks);
        Ok(())
    }
    pub fn remove(&mut self, e: &mut Engine) -> Result<Value> {
        let journal = e
            .store
            .read("runtime-state/native-company-routing.json", Value::Null)?;
        ensure!(
            !journal["ownerPid"]
                .as_u64()
                .is_some_and(|p| p as u32 != std::process::id() && platform::pid_alive(p as u32)),
            "另一原生窗口仍在管理私有网络连接，未移除它的出口。"
        );
        e.attach()?;
        // Startup recovery can fail before a session is adopted. Retain that
        // journal until the controller confirms its outlet has been removed.
        if self.session.is_none() && !journal.is_null() {
            self.recover(e)?;
        }
        self.proof = None;
        self.internet = None;
        if let Some(s) = &self.session {
            if e.pid.is_none() && !platform::pid_alive(s.core_pid) {
                self.session = None;
            }
        }
        if let Some(s) = &self.session {
            ensure!(
                e.pid.is_some(),
                "暂无法确认现有内核，私有网络恢复记录已保留。"
            );
            if e.has_proxy(&s.name)? {
                let picks = e.selections()?;
                let base = config::parse(&fs::read_to_string(e.store.path("mihomo/config.yaml"))?)?;
                e.reload(&config::yaml(&base)?)?;
                e.restore_selections(&picks);
                e.confirm_routing_config(&base)?;
            }
        }
        self.session = None;
        self.applied = false;
        self.recovering = false;
        self.paused = false;
        self.pending = None;
        self.last_error = None;
        let _ = fs::remove_file(e.store.path("runtime-state/native-company-routing.json"));
        Ok(self.state())
    }
    fn repair(&mut self, e: &mut Engine) -> Result<()> {
        let s = self
            .session
            .as_ref()
            .context("私有网络会话已结束。")?
            .clone();
        e.attach()?;
        let pid = e.pid.context("请先恢复现有 VPN 连接。")?;
        let base = fs::read_to_string(e.store.path("mihomo/config.yaml"))?;
        let plan = compile_for_engine(e, config::parse(&base)?, s.port, &s.name, &s.rows)?;
        platform::validate(&e.binary, &e.store, &config::yaml(&plan.config)?)?;
        e.attach()?;
        ensure!(
            e.pid == Some(pid) && base == fs::read_to_string(e.store.path("mihomo/config.yaml"))?,
            "现有配置仍在变化，私有网络隧道保留，稍后重试。"
        );
        let picks = e.selections()?;
        e.reload(&config::yaml(&plan.config)?)?;
        e.restore_selections(&picks);
        e.confirm_routing_config(&plan.config)?;
        ensure!(e.has_proxy(&s.name)?, "私有网络分流恢复尚未完成。");
        self.session = Some(Session {
            plan,
            core_pid: pid,
            ..s
        });
        self.journal(e)?;
        self.applied = true;
        self.recovering = false;
        self.proof = None;
        self.internet = None;
        self.last_error = None;
        self.pending = None;
        Ok(())
    }
    pub fn monitor(&mut self, e: &mut Engine) -> Result<()> {
        let Some(s) = self.session.clone() else {
            return Ok(());
        };
        if !platform::pid_alive(s.helper_pid) {
            self.remove(e)?;
            return Ok(());
        }
        e.attach()?;
        let Some(pid) = e.pid else {
            self.applied = false;
            self.proof = None;
            self.recovering = true;
            return Ok(());
        };
        match e.has_proxy(&s.name) {
            Ok(true) => {
                if let Err(error) = e.confirm_routing_config(&s.plan.config) {
                    self.applied = false;
                    self.proof = None;
                    self.recovering = true;
                    self.last_error = Some(crate::storage::redact(&error.to_string()));
                    return Err(error);
                }
                if pid != s.core_pid {
                    self.session.as_mut().unwrap().core_pid = pid;
                    self.proof = None;
                    self.journal(e)?;
                }
                self.applied = true;
                self.recovering = false;
                self.pending = None;
                return Ok(());
            }
            Err(error) => {
                self.last_error = Some("私有网络分流状态暂无法核对，现有会话保留。".into());
                return Err(error);
            }
            Ok(false) => {}
        }
        self.applied = false;
        self.proof = None;
        if self.paused {
            return Ok(());
        }
        self.recovering = true;
        let base = fs::read(e.store.path("mihomo/config.yaml"))?;
        let key = format!("{pid}:{}", sha256(&base));
        if self.pending.as_ref().is_none_or(|(k, _)| k != &key) {
            self.pending = Some((key, Instant::now()));
            self.last_error = Some("正在等待现有配置稳定后恢复私有网络分流。".into());
            return Ok(());
        }
        if self.pending.as_ref().unwrap().1.elapsed() < Duration::from_millis(2500)
            || self.next.is_some_and(|t| Instant::now() < t)
        {
            return Ok(());
        }
        self.attempts
            .retain(|t| t.elapsed() < Duration::from_secs(60));
        if self.attempts.len() >= 3 {
            self.paused = true;
            self.recovering = false;
            self.last_error = Some(
                "现有 VPN 频繁覆盖配置，已暂停自动恢复；私有网络隧道保留，请手动重新接入。".into(),
            );
            return Ok(());
        }
        self.attempts.push(Instant::now());
        self.next = Some(Instant::now() + Duration::from_secs(10));
        match self.repair(e) {
            Ok(()) => self.recovery_count += 1,
            Err(error) => {
                self.last_error = Some("恢复暂未完成，私有网络隧道保留，稍后重试。".into());
                return Err(error);
            }
        }
        Ok(())
    }
    pub fn internet_check(&mut self) -> Result<Value> {
        let start = Instant::now();
        let response = reqwest::blocking::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(8))
            .build()?
            .get("https://chatgpt.com/cdn-cgi/trace")
            .send()
            .and_then(|r| r.error_for_status());
        self.internet = Some(
            json!({"checkedAt":now(),"result":{"ok":response.is_ok(),"httpStatus":response.as_ref().ok().map(|r|r.status().as_u16()),"elapsedMs":start.elapsed().as_millis(),"error":response.err().map(|e|crate::storage::redact(&e.to_string()))}}),
        );
        Ok(self.state())
    }
    pub fn verify(&mut self, e: &mut Engine, raw: &str) -> Result<Value> {
        self.proof = None;
        let result = self.verify_internal(e, raw);
        if let Err(error) = &result {
            self.last_error = Some(crate::storage::redact(&error.to_string()));
        }
        result
    }
    fn verify_internal(&mut self, e: &mut Engine, raw: &str) -> Result<Value> {
        let s = self
            .session
            .as_ref()
            .context("私有网络分流尚未接入。")?
            .clone();
        ensure!(self.applied, "私有网络分流正在恢复，请稍后验证。");
        let target = business_target(raw)?;
        let listener = std::net::TcpListener::bind("0.0.0.0:0")?;
        let local = listener.local_addr()?.port();
        drop(listener);
        let started = Instant::now();
        let mut child = Command::new("curl")
            .args([
                "--silent",
                "--show-error",
                "--noproxy",
                "*",
                "--max-time",
                "25",
                "--local-port",
                &local.to_string(),
                "--output",
                if cfg!(windows) { "NUL" } else { "/dev/null" },
                "--write-out",
                "%{json}",
                target.as_str(),
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let mut evidence = None;
        loop {
            if let Ok(v) = e.api("GET", "/connections", None) {
                if let Some(c) = v["connections"].as_array().and_then(|cs| {
                    cs.iter().find(|c| {
                        c["chains"]
                            .as_array()
                            .is_some_and(|a| a.contains(&json!(s.name)))
                            && c["metadata"]["sourcePort"]
                                .as_str()
                                .and_then(|p| p.parse::<u16>().ok())
                                .or_else(|| c["metadata"]["sourcePort"].as_u64().map(|p| p as u16))
                                == Some(local)
                            && c["metadata"]["destinationPort"]
                                .as_str()
                                .and_then(|p| p.parse::<u16>().ok())
                                .or_else(|| {
                                    c["metadata"]["destinationPort"].as_u64().map(|p| p as u16)
                                })
                                == target.port_or_known_default()
                            && (c["metadata"]["destinationIP"] == target.host_str().unwrap()
                                || c["metadata"]["host"] == target.host_str().unwrap())
                    })
                }) {
                    evidence = Some(c["chains"].clone());
                }
            }
            if child.try_wait()?.is_some() {
                break;
            }
            if started.elapsed() > Duration::from_secs(27) {
                let _ = child.kill();
                let _ = child.wait();
                bail!("内网访问超时，连接保持。");
            }
            std::thread::sleep(Duration::from_millis(45));
        }
        let response = child.wait_with_output()?;
        ensure!(response.status.success(), "内网业务请求失败，连接保持。");
        let output: Value = serde_json::from_slice(&response.stdout)?;
        ensure!(
            output["local_port"].as_u64() == Some(local as u64),
            "未取得本次请求的源端口证据。"
        );
        let status = output["http_code"].as_u64().context("未取得 HTTP 状态。")?;
        ensure!((200..400).contains(&status), "内网业务返回 HTTP {status}。");
        let chains = evidence.context("业务有响应，但未取得这次请求经过私有网络出口的证据。")?;
        let interface = platform::route(output["remote_ip"].as_str().context("未取得目标地址。")?)?;
        ensure!(
            platform::is_tun_interface(&interface),
            "业务请求没有使用系统 TUN 路由。"
        );
        e.attach()?;
        ensure!(
            e.pid == Some(s.core_pid),
            "验证期间内核发生变化，请重新验证。"
        );
        self.proof = Some(
            json!({"target":target.as_str(),"httpStatus":status,"elapsedMs":started.elapsed().as_millis(),"interfaceName":interface,"sourcePort":local,"chains":chains,"corePid":s.core_pid,"verifiedAt":now()}),
        );
        self.last_error = None;
        Ok(self.state())
    }
}
pub fn business_target(raw: &str) -> Result<url::Url> {
    let u = url::Url::parse(&if raw.contains("://") {
        raw.into()
    } else {
        format!("http://{raw}")
    })?;
    ensure!(
        matches!(u.scheme(), "http" | "https")
            && u.host_str().is_some()
            && u.username().is_empty()
            && u.password().is_none()
            && u.query().is_none()
            && u.fragment().is_none(),
        "业务地址需要是不含账号或令牌的 HTTP/HTTPS 地址。"
    );
    Ok(u)
}
