use serde_json::json;
use splitvpn_core::platform::{HelperState, classify_helper};
use std::path::Path;

fn plist(data: &str, shell: bool) -> serde_json::Value {
    let mut args = vec![
        "/Library/PrivilegedHelperTools/com.split-vpn.helper",
        "daemon",
        data,
    ];
    if shell {
        args.insert(0, "/bin/sh");
    }
    json!({"Label":"com.split-vpn.helper", "ProgramArguments":args,
        "StandardOutPath": "/correct/logs/helper.out.log"})
}
#[test]
fn previous_helper_can_disconnect_without_reauthorization() {
    let old = "HELPER_VERSION=\"2026.08.15.3\"\nHELPER_SCRIPT_REVISION=\"2026.10.08.1\"\n";
    for shell in [false, true] {
        let state = classify_helper(old, &plist("/correct", shell), Path::new("/correct"), true);
        assert_eq!(state, HelperState::Outdated);
        for action in ["status", "stop", "start", "restore-orphan-dns"] {
            assert!(state.supports(action));
        }
        assert!(!state.supports("refresh-dns"));
        assert!(!state.supports("invalid"));
    }
}
#[test]
fn helper_binding_uses_arguments_not_unrelated_log_paths() {
    let current = include_str!("../assets/macos-helper.sh");
    let state = classify_helper(
        current,
        &plist("/other", false),
        Path::new("/correct"),
        true,
    );
    assert_eq!(state, HelperState::OtherData);
    assert!(!state.supports("stop"));
    let data = "/tmp/目录 & a'\"";
    assert_eq!(
        classify_helper(current, &plist(data, true), Path::new(data), true),
        HelperState::Current
    );
}
#[test]
fn commented_revision_and_missing_binary_are_not_current() {
    let current = include_str!("../assets/macos-helper.sh");
    let commented = current.replace("\nHELPER_SCRIPT_REVISION=", "\n# HELPER_SCRIPT_REVISION=");
    let args = plist("/correct", false);
    assert_eq!(
        classify_helper(&commented, &args, Path::new("/correct"), true),
        HelperState::Outdated
    );
    assert_eq!(
        classify_helper(current, &args, Path::new("/correct"), false),
        HelperState::Outdated
    );
    assert_eq!(
        classify_helper("", &args, Path::new("/correct"), true),
        HelperState::Missing
    );
    let incompatible = current.replace("2026.08.15.3", "incompatible");
    assert_eq!(
        classify_helper(&incompatible, &args, Path::new("/correct"), true),
        HelperState::Incompatible
    );
}

#[cfg(unix)]
#[test]
fn fifo_retries_while_replacement_daemon_is_starting() {
    use std::{
        ffi::CString,
        io::{Read, Write},
        time::Duration,
    };
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("control.pipe");
    let cpath = CString::new(path.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(cpath.as_ptr(), 0o600) }, 0);
    let reader_path = path.clone();
    let reader = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(200));
        let mut result = String::new();
        std::fs::File::open(reader_path)
            .unwrap()
            .read_to_string(&mut result)
            .unwrap();
        result
    });
    let mut writer =
        splitvpn_core::platform::open_helper_fifo(&path, Duration::from_secs(2)).unwrap();
    writer.write_all(b"fixture status\n").unwrap();
    drop(writer);
    assert_eq!(reader.join().unwrap(), "fixture status\n");
}

#[cfg(unix)]
#[test]
fn stale_fifo_times_out_and_symlink_is_rejected() {
    use std::{
        ffi::CString,
        time::{Duration, Instant},
    };
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("control.pipe");
    let cpath = CString::new(path.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(cpath.as_ptr(), 0o600) }, 0);
    let start = Instant::now();
    assert!(splitvpn_core::platform::open_helper_fifo(&path, Duration::from_millis(20)).is_err());
    assert!(start.elapsed() < Duration::from_secs(1));
    let symlink = dir.path().join("symlink");
    std::os::unix::fs::symlink(&path, &symlink).unwrap();
    assert!(splitvpn_core::platform::open_helper_fifo(&symlink, Duration::from_secs(2)).is_err());
}
#[test]
fn hardened_helper_stays_current_for_earlier_clients_and_upgrades_previous_revision() {
    let current = include_str!("../assets/macos-helper.sh");
    // 0.4.6 and 0.4.7 compare their exact line, so every build accepts the new helper.
    for revision in ["2026.10.09.1", "2026.10.09.2"] {
        let line = format!("HELPER_SCRIPT_REVISION=\"{revision}\"");
        assert!(current.lines().any(|l| l.trim() == line));
    }
    let previous = current.replace("HELPER_SCRIPT_REVISION=\"2026.10.11.1\"\n", "");
    let args = plist("/correct", false);
    assert_eq!(
        classify_helper(&previous, &args, Path::new("/correct"), true),
        HelperState::Outdated
    );
    assert_eq!(
        classify_helper(current, &args, Path::new("/correct"), true),
        HelperState::Current
    );
}
