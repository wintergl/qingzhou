//! OS effects stay outside the shared policy and data modules.
use crate::storage::{Storage, atomic_write};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::{
    fs,
    io::{Read, Write},
    path::Path,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

pub fn pid_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        let result = unsafe { libc::kill(pid as i32, 0) };
        result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }
    #[cfg(not(unix))]
    {
        Command::new("tasklist")
            .args(["/FI", &format!("PID eq {pid}"), "/NH"])
            .output()
            .is_ok_and(|o| String::from_utf8_lossy(&o.stdout).contains(&pid.to_string()))
    }
}
pub fn command(command: &str, args: &[&str], timeout: Duration) -> Result<String> {
    let mut child = Command::new(command)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    // Drain both pipes while waiting, including validation diagnostics larger
    // than a pipe buffer. Never let an engine child inherit the RPC stdout.
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let read = |mut pipe: Box<dyn std::io::Read + Send>| {
        let mut data = Vec::new();
        let mut bytes = [0; 8192];
        while let Ok(n) = pipe.read(&mut bytes) {
            if n == 0 {
                break;
            }
            let keep = n.min((2 * 1024 * 1024usize).saturating_sub(data.len()));
            data.extend_from_slice(&bytes[..keep]);
        }
        data
    };
    let out = std::thread::spawn(move || read(Box::new(stdout)));
    let err = std::thread::spawn(move || read(Box::new(stderr)));
    let until = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= until {
            let _ = child.kill();
            let _ = child.wait();
            let _ = out.join();
            let _ = err.join();
            bail!("系统操作超时。");
        }
        std::thread::sleep(Duration::from_millis(40));
    };
    let out = out.join().unwrap_or_default();
    let err = err.join().unwrap_or_default();
    if !status.success() {
        bail!("{}", crate::storage::redact(&String::from_utf8_lossy(&err)));
    }
    Ok(String::from_utf8_lossy(&out).into_owned())
}
/// The private stdio backend is single-instance per data directory. The lock
/// stays on disk so a second process cannot race an unlinked inode.
pub struct BackendLock(std::fs::File);
impl BackendLock {
    pub fn acquire(store: &Storage) -> Result<Self> {
        let path = store.path("runtime-state/rust-core.lock");
        fs::create_dir_all(path.parent().unwrap())?;
        let mut options = fs::OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let file = options.open(path)?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            anyhow::ensure!(
                unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
                "同一数据目录已有 Rust 后台，请先关闭旧窗口。"
            );
        }
        Ok(Self(file))
    }
}
impl Drop for BackendLock {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            unsafe {
                libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
            }
        }
    }
}
pub fn route(address: &str) -> Result<String> {
    #[cfg(target_os = "macos")]
    {
        let text = command(
            "/sbin/route",
            &["-n", "get", address],
            Duration::from_secs(5),
        )?;
        text.lines()
            .find_map(|l| l.trim().strip_prefix("interface:").map(str::trim))
            .map(str::to_owned)
            .context("默认物理路由不可用。")
    }
    #[cfg(target_os = "linux")]
    {
        let text = command("ip", &["route", "get", address], Duration::from_secs(5))?;
        let words: Vec<_> = text.split_whitespace().collect();
        words
            .windows(2)
            .find(|p| p[0] == "dev")
            .map(|p| p[1].to_owned())
            .context("默认物理路由不可用。")
    }
    #[cfg(windows)]
    {
        // Parsed first, so only a literal address reaches the PowerShell command.
        let ip: std::net::IpAddr = address.parse().context("目标地址无效。")?;
        let text = command(
            "powershell",
            &[
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                &format!(
                    "(Find-NetRoute -RemoteIPAddress '{ip}' | Select-Object -First 1).InterfaceAlias"
                ),
            ],
            Duration::from_secs(10),
        )?;
        text.lines()
            .map(str::trim)
            .find(|l| !l.is_empty())
            .map(str::to_owned)
            .context("默认物理路由不可用。")
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
    {
        let _ = address;
        bail!("该平台需要实现物理路由适配器。");
    }
}
/// mihomo names its TUN `utun*` on macOS and `Meta` elsewhere (wintun on Windows).
pub fn is_tun_interface(name: &str) -> bool {
    if cfg!(target_os = "macos") {
        name.starts_with("utun")
    } else {
        name.starts_with("Meta")
    }
}

/// Read-only verification of the actual device, not merely the controller flag.
pub fn tun_device_ready(name: &str) -> bool {
    #[cfg(target_os = "macos")]
    {
        if !name.starts_with("utun")
            || !name[4..].chars().all(|c| c.is_ascii_digit())
            || name.len() <= 4
        {
            return false;
        }
        command("/sbin/ifconfig", &[name], Duration::from_secs(2)).is_ok_and(|text| {
            text.lines()
                .next()
                .is_some_and(|s| s.contains("<UP,") || s.contains(",UP,"))
                && text.lines().any(|s| s.trim().starts_with("inet "))
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = name;
        true
    }
}
pub fn context() -> Result<Value> {
    #[cfg(target_os = "macos")]
    {
        let text = command(
            "/sbin/route",
            &["-n", "get", "default"],
            Duration::from_secs(5),
        )?;
        let field = |key: &str| {
            text.lines()
                .find_map(|l| l.trim().strip_prefix(key).map(str::trim))
        };
        let interface = field("interface:").context("默认物理路由不可用。")?;
        anyhow::ensure!(
            is_physical_interface(interface),
            "默认路由没有指向物理网卡。"
        );
        let gateway = field("gateway:").unwrap_or("on-link");
        let addresses = command("/sbin/ifconfig", &[interface], Duration::from_secs(5))?;
        let link = addresses
            .lines()
            .find_map(|line| line.trim().strip_prefix("status: "));
        anyhow::ensure!(
            link.is_none_or(|status| status == "active"),
            "默认物理网卡尚未连通。"
        );
        let address = addresses
            .lines()
            .find_map(|l| {
                l.trim()
                    .strip_prefix("inet ")
                    .and_then(|s| s.split_whitespace().next())
            })
            .filter(|s| !s.starts_with("169.254.") && !s.starts_with("127."))
            .context("默认物理网卡还没有可用的 IPv4 地址。")?;
        Ok(
            json!({"interfaceName":interface,"gateway":gateway,"address":address,"signature":format!("{interface}|{gateway}|{address}")}),
        )
    }
    // Windows: mihomo keeps auto-detect-interface; the signature only tracks
    // network changes. Numeric route columns do not depend on the UI language.
    #[cfg(windows)]
    {
        let text = command("route", &["print", "-4", "0.0.0.0"], Duration::from_secs(5))?;
        let (gateway, address) = windows_default_route(&text).context("默认物理路由不可用。")?;
        Ok(json!({"gateway":gateway,"address":address,"signature":format!("{gateway}|{address}")}))
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        let interface = route("default")?;
        anyhow::ensure!(
            is_physical_interface(&interface),
            "默认路由没有指向物理网卡。"
        );
        Ok(json!({"interfaceName":interface,"signature":interface}))
    }
}
/// Lowest-metric `0.0.0.0 0.0.0.0 <gateway> <interface> <metric>` row from
/// `route print`, skipping on-link rows and the mihomo TUN (198.18.0.0/15).
pub fn windows_default_route(text: &str) -> Option<(String, String)> {
    text.lines()
        .filter_map(|line| {
            let w: Vec<&str> = line.split_whitespace().collect();
            let gateway = w.get(2)?.parse::<std::net::Ipv4Addr>().ok()?;
            let address = w.get(3)?.parse::<std::net::Ipv4Addr>().ok()?;
            let metric = w.get(4)?.parse::<u32>().ok()?;
            (w[0] == "0.0.0.0"
                && w[1] == "0.0.0.0"
                && address.octets()[..2] != [198, 18]
                && address.octets()[..2] != [198, 19])
            .then(|| (metric, gateway.to_string(), address.to_string()))
        })
        .min_by_key(|r| r.0)
        .map(|(_, gateway, address)| (gateway, address))
}
pub fn is_physical_interface(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    ![
        "lo", "utun", "tun", "tap", "awdl", "llw", "bridge", "gif", "stf", "anpi",
    ]
    .iter()
    .any(|p| name.starts_with(p))
}

/// Active physical IPv4 networks already have connected routes on macOS.
/// A TUN must leave those routes in place, including the network carrying its
/// own gateway. Parse fixtures here without reading or changing the host.
pub fn connected_ipv4_networks(text: &str) -> Vec<String> {
    fn collect(block: &[&str], out: &mut Vec<String>) {
        let Some(name) = block
            .first()
            .and_then(|line| line.split_once(':'))
            .map(|p| p.0)
        else {
            return;
        };
        if !is_physical_interface(name) || !block.iter().any(|line| line.trim() == "status: active")
        {
            return;
        }
        for line in block {
            let words: Vec<_> = line.split_whitespace().collect();
            if words.first() != Some(&"inet") || words.get(2) != Some(&"netmask") {
                continue;
            }
            let Some(address) = words
                .get(1)
                .and_then(|s| s.parse::<std::net::Ipv4Addr>().ok())
            else {
                continue;
            };
            if address.is_loopback() || address.is_link_local() || address.is_unspecified() {
                continue;
            }
            let Some(mask) = words
                .get(3)
                .and_then(|s| s.strip_prefix("0x"))
                .and_then(|s| u32::from_str_radix(s, 16).ok())
            else {
                continue;
            };
            let bits = mask.leading_ones();
            if bits == 0 || mask != u32::MAX.checked_shl(32 - bits).unwrap_or(0) {
                continue;
            }
            let network = std::net::Ipv4Addr::from(u32::from(address) & mask);
            out.push(format!("{network}/{bits}"));
        }
    }
    let mut out = Vec::new();
    let mut block = Vec::new();
    for line in text.lines() {
        if !line.starts_with(char::is_whitespace) && line.contains(": flags=") {
            collect(&block, &mut out);
            block.clear();
        }
        block.push(line);
    }
    collect(&block, &mut out);
    out.sort();
    out.dedup();
    out
}

pub fn protected_physical_networks() -> Result<Vec<String>> {
    #[cfg(target_os = "macos")]
    {
        let text = command("/sbin/ifconfig", &[], Duration::from_secs(5))?;
        let networks = connected_ipv4_networks(&text);
        anyhow::ensure!(
            !networks.is_empty(),
            "暂无法确认本地物理网段，私有网络分流尚未修改。"
        );
        Ok(networks)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(Vec::new())
    }
}
pub fn legacy_owner() -> bool {
    #[cfg(target_os = "macos")]
    {
        command("/bin/ps", &["-axo", "comm="], Duration::from_secs(3))
            .map(|s| {
                s.lines().any(|l| {
                    l.trim()
                        .ends_with("/split-vpn.app/Contents/MacOS/split-vpn")
                })
            })
            .unwrap_or(true)
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}
pub fn validate(binary: &Path, store: &Storage, yaml: &str) -> Result<()> {
    let candidate = store.path(&format!("mihomo/.candidate-{}.yaml", uuid::Uuid::new_v4()));
    atomic_write(&candidate, yaml.as_bytes())?;
    let result = command(
        binary.to_str().context("内核路径无效。")?,
        &[
            "-t",
            "-d",
            store.path("mihomo").to_str().unwrap(),
            "-f",
            candidate.to_str().unwrap(),
        ],
        Duration::from_secs(20),
    );
    let _ = fs::remove_file(candidate);
    result.map(|_| ())
}
const HELPER_PROTOCOL: &str = "HELPER_VERSION=\"2026.08.15.3\"";
const HELPER_REVISION: &str = "HELPER_SCRIPT_REVISION=\"2026.10.11.1\"";

#[derive(Debug, PartialEq, Eq)]
pub enum HelperState {
    Current,
    Outdated,
    Missing,
    Incompatible,
    OtherData,
}
impl HelperState {
    pub fn supports(&self, action: &str) -> bool {
        (*self == Self::Current && action == "refresh-dns")
            || (matches!(self, Self::Current | Self::Outdated)
                && matches!(action, "start" | "stop" | "status" | "restore-orphan-dns"))
    }
    fn message(&self) -> &'static str {
        match self {
            Self::Outdated => "特权服务需要更新；连接或切换节点时会自动请求系统授权。",
            Self::Missing => "特权服务尚未安装；连接时会自动请求系统授权。",
            Self::OtherData => "特权服务绑定了其他数据目录，未修改其他连接。",
            _ => "特权服务协议不兼容，需要通过连接操作重新授权安装。",
        }
    }
}
/// Parse the launchd arguments, rather than searching arbitrary XML strings.
/// Both older /bin/sh launchers and direct executable launchers are supported.
pub fn classify_helper(
    script: &str,
    plist: &Value,
    root: &Path,
    binary_present: bool,
) -> HelperState {
    if script.is_empty() || plist.is_null() {
        return HelperState::Missing;
    }
    if !script.lines().any(|l| l.trim() == HELPER_PROTOCOL)
        || plist["Label"] != "com.split-vpn.helper"
    {
        return HelperState::Incompatible;
    }
    let Some(args) = plist["ProgramArguments"].as_array() else {
        return HelperState::Incompatible;
    };
    let args = if args.first().is_some_and(|a| a == "/bin/sh") {
        &args[1..]
    } else {
        args.as_slice()
    };
    if args.len() != 3
        || args[0] != "/Library/PrivilegedHelperTools/com.split-vpn.helper"
        || args[1] != "daemon"
    {
        return HelperState::Incompatible;
    }
    if args[2].as_str() != root.to_str() {
        return HelperState::OtherData;
    }
    if script.lines().any(|l| l.trim() == HELPER_REVISION) && binary_present {
        HelperState::Current
    } else {
        HelperState::Outdated
    }
}
pub fn helper_state(store: &Storage) -> HelperState {
    #[cfg(target_os = "macos")]
    {
        let script = fs::read_to_string("/Library/PrivilegedHelperTools/com.split-vpn.helper")
            .unwrap_or_default();
        let plist = command(
            "/usr/bin/plutil",
            &[
                "-convert",
                "json",
                "-o",
                "-",
                "/Library/LaunchDaemons/com.split-vpn.helper.plist",
            ],
            Duration::from_secs(3),
        )
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null);
        classify_helper(
            &script,
            &plist,
            &store.root,
            Path::new("/Library/PrivilegedHelperTools/com.split-vpn.mihomo").is_file(),
        )
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = store;
        HelperState::Current
    }
}
pub fn upgrade_helper(store: &Storage, binary: &Path) -> Result<()> {
    #[cfg(target_os = "macos")]
    {
        install_helper(store, binary)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (store, binary);
        bail!("该平台需要独立的特权服务适配器。");
    }
}
#[cfg(unix)]
pub fn open_helper_fifo(fifo: &Path, timeout: Duration) -> Result<fs::File> {
    use std::os::unix::{fs::FileTypeExt, fs::OpenOptionsExt};
    let until = Instant::now() + timeout;
    loop {
        match fs::symlink_metadata(fifo) {
            Ok(m) => anyhow::ensure!(m.file_type().is_fifo(), "特权服务管道无效。"),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            Err(e) => return Err(e.into()),
        }
        match fs::OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
            .open(fifo)
        {
            Ok(writer) => return Ok(writer),
            Err(e) if matches!(e.raw_os_error(), Some(libc::ENOENT | libc::ENXIO)) => (),
            Err(e) => return Err(e.into()),
        }
        if Instant::now() >= until {
            bail!("特权服务尚未就绪，请稍后重试。");
        }
        std::thread::sleep(Duration::from_millis(120));
    }
}
pub fn helper(store: &Storage, action: &str, binary: &Path, allow_install: bool) -> Result<Value> {
    anyhow::ensure!(
        matches!(
            action,
            "start" | "stop" | "status" | "restore-orphan-dns" | "refresh-dns"
        ),
        "特权服务命令无效。"
    );
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (store, binary, allow_install);
        bail!("该平台需要独立的特权服务适配器。");
    }
    #[cfg(target_os = "macos")]
    {
        let state = helper_state(store);
        if state != HelperState::Current && (allow_install || !state.supports(action)) {
            anyhow::ensure!(state != HelperState::OtherData, "{}", state.message());
            if !allow_install {
                bail!("{}", state.message());
            }
            install_helper(store, binary)?;
        }
        let id = format!("svpn_{}", uuid::Uuid::new_v4().simple());
        let fifo = store.path("helper/control.pipe");
        // Nonblocking open prevents a stale FIFO from hanging the RPC forever.
        let mut writer = open_helper_fifo(&fifo, Duration::from_secs(6))?;
        writer.write_all(format!("{id} {action}\n").as_bytes())?;
        drop(writer);
        let response = store.path(&format!("helper/responses/{id}.json"));
        let until = Instant::now() + Duration::from_secs(if action == "stop" { 30 } else { 20 });
        while Instant::now() < until {
            if let Ok(bytes) = fs::read(&response) {
                if let Ok(v) = serde_json::from_slice::<Value>(&bytes) {
                    let _ = fs::remove_file(response);
                    anyhow::ensure!(
                        v["ok"] == true,
                        "特权服务执行失败：{}",
                        v["error"].as_str().unwrap_or("未知错误")
                    );
                    anyhow::ensure!(
                        v["protocolVersion"] == "2026.08.15.3",
                        "特权服务响应协议不兼容。"
                    );
                    return Ok(v);
                }
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        bail!("特权服务响应超时；运行状态需要重新核对，恢复记录已保留。");
    }
}
#[cfg(target_os = "macos")]
fn install_helper(store: &Storage, binary: &Path) -> Result<()> {
    use crate::storage::sha256;
    let stage = store.path(&format!("helper/staging-rust-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&stage)?;
    let script = include_bytes!("../assets/macos-helper.sh");
    atomic_write(&stage.join("helper.sh"), script)?;
    let data = xml(&store.root.to_string_lossy());
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Label</key><string>com.split-vpn.helper</string><key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/com.split-vpn.helper</string><string>daemon</string><string>{data}</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>StandardOutPath</key><string>/var/log/com.split-vpn.helper.out.log</string><key>StandardErrorPath</key><string>/var/log/com.split-vpn.helper.err.log</string></dict></plist>"#
    );
    atomic_write(&stage.join("helper.plist"), plist.as_bytes())?;
    fs::create_dir_all(store.path("logs"))?;
    // The installer itself travels inline; it re-hashes root-owned copies of
    // the staged files, so swapping them in the user directory fails closed.
    let installer = std::str::from_utf8(include_bytes!("../assets/macos-helper-install.sh"))?;
    let shell = format!(
        "/bin/sh -c {} install {} {} /Library/PrivilegedHelperTools /Library/LaunchDaemons /var/db/com.split-vpn.helper /bin/launchctl /usr/bin/install {} {} {}",
        quote(installer),
        quote(&stage.to_string_lossy()),
        quote(&binary.to_string_lossy()),
        sha256(script),
        sha256(plist.as_bytes()),
        sha256(&fs::read(binary)?)
    );
    let apple = format!(
        "do shell script {} with administrator privileges",
        serde_json::to_string(&shell)?
    );
    let result = command(
        "/usr/bin/osascript",
        &["-e", &apple],
        Duration::from_secs(120),
    );
    let _ = fs::remove_dir_all(stage);
    result.map(|_| ())
}
pub fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}
pub fn xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

/// Read the existing process age, never substitute application launch time.
pub fn process_started_at(pid: u32) -> Option<String> {
    if !cfg!(unix) {
        return None;
    }
    let age = command(
        "/bin/ps",
        &["-o", "etime=", "-p", &pid.to_string()],
        Duration::from_secs(2),
    )
    .ok()?;
    let seconds = process_elapsed_seconds(age.trim())?;
    Some((chrono::Utc::now() - chrono::Duration::seconds(seconds)).to_rfc3339())
}

fn process_elapsed_seconds(value: &str) -> Option<i64> {
    let (days, clock) = match value.split_once('-') {
        Some((days, clock)) => (days.parse::<i64>().ok()?, clock),
        None => (0, value),
    };
    let parts = clock
        .split(':')
        .map(str::parse::<i64>)
        .collect::<Result<Vec<_>, _>>()
        .ok()?;
    let seconds = match parts.as_slice() {
        [minutes, seconds] => minutes.checked_mul(60)?.checked_add(*seconds)?,
        [hours, minutes, seconds] => hours
            .checked_mul(3600)?
            .checked_add(minutes.checked_mul(60)?)?
            .checked_add(*seconds)?,
        _ => return None,
    };
    let total = days.checked_mul(86400)?.checked_add(seconds)?;
    (total >= 0).then_some(total)
}

#[cfg(test)]
mod process_time_tests {
    #[test]
    fn parses_process_age_without_locale_or_app_launch_time() {
        use super::process_elapsed_seconds as parse;
        assert_eq!(parse("02:18:05"), Some(8285));
        assert_eq!(parse("2-01:02:03"), Some(176523));
        assert_eq!(parse("00:05"), Some(5));
        assert_eq!(parse("unknown"), None);
        assert_eq!(parse("999999999999999999999-01:02:03"), None);
    }
}
