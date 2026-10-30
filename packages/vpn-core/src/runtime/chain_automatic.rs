//! Application-owned routine maintenance, independent of windows and business VPN.
use super::*;
const AUTO_BATCH_INTERVAL: i64 = 2 * 60 * 60;
pub(super) fn network_settling(core: &Core) -> bool {
    core.chain_network_changed_at
        .is_some_and(|t| t.elapsed() < Duration::from_secs(120))
}
pub(super) fn battery_blocked(core: &Core) -> bool {
    core.environment.on_battery == Some(true)
        || (cfg!(target_os = "macos")
            && !core.engine.isolated
            && core.environment.on_battery.is_none())
}
pub(super) fn baseline_ready(core: &Core) -> bool {
    subscription::provider_nodes(&core.engine.store)
        .is_ok_and(|nodes| !core.maintenance_candidates(&nodes).is_empty())
}
pub(super) fn batch_due(state: &Value, now: chrono::DateTime<chrono::Utc>) -> bool {
    state["lastAutomaticBatchAt"]
        .as_str()
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .is_none_or(|t| (now - t.with_timezone(&chrono::Utc)).num_seconds() >= AUTO_BATCH_INTERVAL)
}
fn observation_due(row: &Value, now: chrono::DateTime<chrono::Utc>) -> bool {
    row["testedAt"]
        .as_str()
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .is_some_and(|t| t <= now)
        && (row["status"] != "available" || !crate::chain_scan::fresh(row, now))
        && (!crate::chain_scan::rejected(row)
            || crate::chain_scan::retry_at(row).is_none_or(|t| t <= now))
}
fn has_due_observation(state: &Value) -> bool {
    let now = chrono::Utc::now();
    state["results"].as_array().is_some_and(|rows| {
        rows.iter().any(|row| {
            state["maintenanceIdentityKeys"]
                .as_array()
                .is_none_or(|keys| keys.is_empty() || keys.contains(&row["identityKey"]))
                && observation_due(row, now)
        })
    })
}
impl Core {
    pub(super) fn configure_chain_automatic(&mut self, p: &Value) -> Result<Value> {
        allowed_keys(p, &["enabled", "intervalMinutes"])?;
        let enabled = p["enabled"].as_bool().context("自动刷新开关需要布尔值。")?;
        let minutes = p["intervalMinutes"]
            .as_u64()
            .filter(|v| [10, 30, 60].contains(v))
            .context("请选择 10、30 或 60 分钟。")?;
        let mut settings = self.engine.store.settings()?;
        settings["chainAutoRefresh"]["enabled"] = json!(enabled);
        settings["chainAutoRefresh"]["intervalMinutes"] = json!(minutes);
        settings["chainAutoRefresh"]["paused"] = json!(false);
        self.engine.store.write("settings.json", &settings)?;
        if !enabled && self.chain_scan["automatic"] == true {
            self.jobs.chain_cancel.store(true, Ordering::SeqCst);
        }
        self.chain_auto_paused_in_memory = false;
        self.chain_auto_attempt = None;
        self.chain_auto_error = false;
        self.jobs.wake_background();
        self.chain_automatic_state()
    }
    pub(super) fn pause_chain_automatic(&mut self) -> Result<()> {
        self.chain_auto_paused_in_memory = true;
        let mut settings = self.engine.store.settings()?;
        if settings["chainAutoRefresh"]["enabled"] == true {
            settings["chainAutoRefresh"]["paused"] = json!(true);
            self.engine.store.write("settings.json", &settings)?;
        }
        Ok(())
    }
    pub(super) fn chain_automatic_state(&self) -> Result<Value> {
        let s = self.engine.store.settings()?;
        let config = &s["chainAutoRefresh"];
        let status = if config["enabled"] != true {
            "disabled"
        } else if config["paused"] == true || self.chain_auto_paused_in_memory {
            "paused"
        } else if self.environment.sleeping {
            "sleeping"
        } else if self.environment.low_power {
            "low-power"
        } else if battery_blocked(self) {
            "on-battery"
        } else if s["staticExit"]["server"].as_str().unwrap_or("").is_empty()
            || s["staticExit"]["port"].as_u64().unwrap_or(0) == 0
        {
            "needs-configuration"
        } else if !s["staticExit"]["username"]
            .as_str()
            .unwrap_or("")
            .is_empty()
            && !crate::static_exit::credential_matches(&s["staticExit"], &self.exit_credential)
        {
            "needs-credential"
        } else if self.chain_scan["waitingReason"] == "network-unavailable"
            || self.chain_network_signature().is_err()
        {
            "waiting-network"
        } else if network_settling(self) {
            "network-settling"
        } else if self.chain_scan["running"] == true {
            if self.chain_scan["automatic"] == true {
                "running"
            } else {
                "manual-running"
            }
        } else if !baseline_ready(self) {
            "needs-baseline"
        } else if self.chain_scan["autoNetworkUncertain"] == true {
            "network-uncertain"
        } else if self.chain_auto_error {
            "retrying"
        } else {
            "ready"
        };
        Ok(
            json!({"enabled":config["enabled"],"intervalMinutes":config["intervalMinutes"],"paused":config["paused"] == true || self.chain_auto_paused_in_memory,"status":status}),
        )
    }
    pub fn take_chain_automatic_request(&mut self) -> Option<Value> {
        if self.jobs.shutdown.load(Ordering::SeqCst)
            || self.jobs.chain_active.load(Ordering::SeqCst)
            || self.jobs.chain_connect_active.load(Ordering::SeqCst)
            || self.environment.sleeping
            || self.environment.low_power
            || battery_blocked(self)
            || network_settling(self)
            || !batch_due(&self.chain_scan, chrono::Utc::now())
            // Check cached timestamps before reading providers or probing the network.
            || !has_due_observation(&self.chain_scan)
            || self
                .chain_auto_attempt
                .is_some_and(|t| t.elapsed() < Duration::from_secs(30))
        {
            return None;
        }
        // Tests must explicitly opt in; ordinary isolated regression fixtures stay inert.
        if self.engine.isolated
            && std::env::var("SPLITVPN_TEST_CHAIN_AUTO_REFRESH").as_deref() != Ok("1")
        {
            return None;
        }
        if !matches!(
            self.chain_automatic_state().ok()?["status"].as_str(),
            Some("ready" | "retrying" | "network-uncertain")
        ) {
            return None;
        }
        let inventory = subscription::provider_nodes(&self.engine.store).ok()?;
        let nodes = self.maintenance_candidates(&inventory);
        next_automatic_candidate(
            &nodes,
            self.chain_scan["results"].as_array()?.as_slice(),
            &Value::Null,
        )?;
        if self.chain_network_signature().is_err() {
            return None;
        }
        if !baseline_ready(self) || !batch_due(&self.chain_scan, chrono::Utc::now()) {
            return None;
        }
        self.chain_auto_attempt = Some(Instant::now());
        Some(json!({"mode":"continuous","automatic":true}))
    }
}
pub(super) fn next_automatic_candidate(
    nodes: &[Value],
    rows: &[Value],
    preferred: &Value,
) -> Option<Value> {
    let now = chrono::Utc::now();
    nodes
        .iter()
        .filter_map(|node| {
            let row = rows.iter().find(|r| {
                r["identityKey"] == node["identityKey"]
                    && r["providerRevision"] == node["providerRevision"]
            });
            let row = row.filter(|r| observation_due(r, now))?;
            let due = {
                let parse = |key: &str| {
                    row[key]
                        .as_str()
                        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                        .map(|t| t.with_timezone(&chrono::Utc))
                };
                parse("testedAt").filter(|t| *t <= now)
            }?;
            // Newly added nodes are left for a user-requested full/partial scan.
            let priority = if node["identityKey"] == *preferred {
                0
            } else {
                1
            };
            Some((priority, due, node))
        })
        .min_by_key(|(priority, due, _)| (*priority, *due))
        .map(|(_, _, node)| node.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn automatic_schedule_skips_recent_success_and_prioritizes_due_results() {
        let nodes = vec![
            json!({"identityKey":"fresh","providerRevision":"v"}),
            json!({"identityKey":"failed","providerRevision":"v"}),
            json!({"identityKey":"new","providerRevision":"v"}),
            json!({"identityKey":"old","providerRevision":"v"}),
        ];
        let now = chrono::Utc::now();
        let rows = vec![
            json!({"identityKey":"fresh","providerRevision":"v","status":"available","testedAt":now.to_rfc3339()}),
            json!({"identityKey":"failed","providerRevision":"v","status":"unreachable","testedAt":(now-chrono::Duration::minutes(10)).to_rfc3339()}),
            json!({"identityKey":"old","providerRevision":"v","status":"available","testedAt":(now-chrono::Duration::hours(25)).to_rfc3339()}),
        ];
        assert_eq!(
            next_automatic_candidate(&nodes, &rows, &json!("fresh")).unwrap()["identityKey"],
            "old"
        );
        assert_eq!(
            next_automatic_candidate(&nodes, &rows, &Value::Null).unwrap()["identityKey"],
            "old"
        );
        assert_eq!(
            next_automatic_candidate(&nodes, &rows, &json!("failed")).unwrap()["identityKey"],
            "failed"
        );
        assert!(next_automatic_candidate(&nodes[..1], &rows, &json!("fresh")).is_none());
        assert!(next_automatic_candidate(&nodes[2..3], &rows, &Value::Null).is_none());
        let mut changed = nodes[3].clone();
        changed["providerRevision"] = json!("updated");
        assert!(next_automatic_candidate(&[changed], &rows, &Value::Null).is_none());
    }
    #[test]
    fn automatic_due_policy_keeps_day_recent_results_and_honors_failure_cooldown() {
        let now = chrono::Utc::now();
        let mut row =
            json!({"status":"available","testedAt":(now-chrono::Duration::hours(23)).to_rfc3339()});
        assert!(!observation_due(&row, now));
        row["testedAt"] = json!((now - chrono::Duration::hours(25)).to_rfc3339());
        assert!(observation_due(&row, now));
        row["testedAt"] = json!(now.to_rfc3339());
        row["environmentUncertain"] = json!(true);
        assert!(observation_due(&row, now));
        row["status"] = json!("unreachable");
        row["nextRetryAt"] = json!((now + chrono::Duration::minutes(5)).to_rfc3339());
        assert!(!observation_due(&row, now));
        assert!(observation_due(&row, now + chrono::Duration::minutes(6)));
        row["testedAt"] = json!((now + chrono::Duration::hours(1)).to_rfc3339());
        assert!(!observation_due(&row, now));
        assert!(!observation_due(&json!({}), now));
    }
    #[test]
    fn batch_budget_survives_restart_and_future_clock_changes() {
        let now = chrono::Utc::now();
        let recent =
            json!({"lastAutomaticBatchAt": (now - chrono::Duration::minutes(119)).to_rfc3339()});
        assert!(!batch_due(&recent, now));
        assert!(batch_due(&recent, now + chrono::Duration::minutes(2)));
        assert!(!batch_due(
            &json!({"lastAutomaticBatchAt": (now + chrono::Duration::hours(1)).to_rfc3339()}),
            now
        ));
    }
    #[test]
    fn network_stability_and_battery_gate_automatic_work() {
        let root = tempfile::tempdir().unwrap();
        let mut core = Core::new(
            root.path().join("data"),
            root.path().into(),
            true,
            Arc::new(|_, _| {}),
            Arc::new(Jobs::default()),
        )
        .unwrap();
        core.environment.on_battery = Some(true);
        assert!(battery_blocked(&core));
        core.environment.on_battery = Some(false);
        assert!(!battery_blocked(&core));
        core.chain_network_changed_at = Some(Instant::now());
        assert!(network_settling(&core));
        core.chain_network_changed_at = Some(Instant::now() - Duration::from_secs(121));
        assert!(!network_settling(&core));
    }
    #[test]
    fn automatic_settings_are_backward_compatible_and_preserve_unknown_fields() {
        let value = crate::storage::normalize_settings(json!({"chainAutoRefresh":{"future":"keep","enabled":true,"intervalMinutes":7},"customFuture":42})).unwrap();
        assert_eq!(value["chainAutoRefresh"]["intervalMinutes"], 30);
        assert_eq!(value["chainAutoRefresh"]["future"], "keep");
        assert_eq!(value["customFuture"], 42);
        assert_eq!(
            crate::storage::normalize_settings(json!({})).unwrap()["chainAutoRefresh"]["enabled"],
            false
        );
    }
    #[test]
    fn paused_memory_guard_also_blocks_a_previously_planned_start() {
        let root = tempfile::tempdir().unwrap();
        let mut core = Core::new(
            root.path().join("data"),
            root.path().into(),
            true,
            Arc::new(|_, _| {}),
            Arc::new(Jobs::default()),
        )
        .unwrap();
        core.configure_chain_automatic(&json!({"enabled":true,"intervalMinutes":30}))
            .unwrap();
        core.pause_chain_automatic().unwrap();
        // Simulate a persisted flag not being available yet: runtime intent still wins.
        let mut settings = core.engine.store.settings().unwrap();
        settings["chainAutoRefresh"]["paused"] = json!(false);
        core.engine.store.write("settings.json", &settings).unwrap();
        assert_eq!(core.chain_automatic_state().unwrap()["paused"], true);
        let error = start_chain_scan(
            Arc::new(Mutex::new(core)),
            json!({"mode":"continuous","automatic":true}),
        )
        .unwrap_err();
        assert!(error.to_string().contains("暂停"));
    }
}
