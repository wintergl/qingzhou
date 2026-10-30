//! Recover an unhealthy ISP path using the small verified backup pool.
use super::*;

const COOLDOWN: Duration = Duration::from_secs(300);

impl Core {
    pub(super) fn chain_failover_ready(&self) -> bool {
        let health = self.path_health.status();
        if health["state"] != "degraded"
            || health["failureKind"] != "egress"
            || self.environment.sleeping
            || chain_automatic::network_settling(self)
            || !self.wants_running
            || self.engine.pid.is_none()
            || self.engine.owned != self.engine.pid
            || self.engine.mode != "vpn"
            || self.health_failures != 0
            || self.jobs.stop_requested.load(Ordering::SeqCst)
            || self.jobs.shutdown.load(Ordering::SeqCst)
            || self.jobs.chain_active.load(Ordering::SeqCst)
            || self.jobs.chain_connect_active.load(Ordering::SeqCst)
            || self.jobs.speed_active.load(Ordering::SeqCst)
            || self.jobs.risk_active.load(Ordering::SeqCst)
            || self.jobs.udp_active.load(Ordering::SeqCst)
            || self.network_recovery.status()["state"] != "ready"
            || self
                .chain_failover_attempt
                .is_some_and(|t| t.elapsed() < COOLDOWN)
            || self.chain_scan["lastFailoverAttemptAt"]
                .as_str()
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                .is_some_and(|t| {
                    (chrono::Utc::now() - t.with_timezone(&chrono::Utc)).num_seconds()
                        < COOLDOWN.as_secs() as i64
                })
        {
            return false;
        }
        let Ok(settings) = self.engine.store.settings() else {
            return false;
        };
        settings["staticExit"]["enabled"] == true && !self.failover_targets().is_empty()
    }

    fn failover_targets(&self) -> Vec<(Value, String)> {
        let (Ok(settings), Ok(inventory)) = (
            self.engine.store.settings(),
            subscription::provider_nodes(&self.engine.store),
        ) else {
            return Vec::new();
        };
        let selected = self.selected_route(&settings);
        let current = inventory.iter().find(|n| n["name"] == selected);
        let mut targets: Vec<_> = self
            .maintenance_candidates(&inventory)
            .iter()
            .filter(|n| n["name"] != selected)
            .filter_map(|n| {
                self.chain_connection_target(
                    &json!({"scanId":self.chain_scan["id"],"identityKey":n["identityKey"]}),
                )
                .ok()
            })
            .collect();
        // A different subscription avoids repeating a provider-wide failure.
        targets.sort_by_key(|(n, _)| {
            current.is_some_and(|c| c["subscriptionId"] == n["subscriptionId"])
        });
        targets
    }

    pub fn take_chain_failover_request(&mut self) -> Option<NetworkRequest> {
        if !self.chain_failover_ready() {
            return None;
        }
        let mut targets = self.failover_targets();
        let (node, _) = targets.first()?;
        let origin = self.selected_route(&self.engine.store.settings().ok()?);
        self.chain_failover_attempt = Some(Instant::now());
        self.chain_scan["lastFailoverAttemptAt"] = json!(now());
        let _ = self.save_chain_cache();
        let payload = json!({"scanId":self.chain_scan["id"],"identityKey":node["identityKey"],"operationId":uuid::Uuid::new_v4().to_string()});
        match self.prepare_chain_use(&payload) {
            Ok(plan) => {
                targets.remove(0);
                self.log("warn", "ISP 出口连续异常，正在复核备用线路。");
                Some(NetworkRequest::ChainUse(Box::new(
                    plan.with_failover(origin, targets),
                )))
            }
            Err(_) => {
                self.network_recovery.changed_for(None, "egress-health");
                self.last_network_tick = None;
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (tempfile::TempDir, Core) {
        let root = tempfile::tempdir().unwrap();
        let mut c = Core::new(
            root.path().join("data"),
            root.path().into(),
            true,
            Arc::new(|_, _| {}),
            Arc::new(Jobs::default()),
        )
        .unwrap();
        let mut settings = c.engine.store.settings().unwrap();
        settings["selectedProxy"] = json!("one-0");
        settings["staticExit"] = json!({"enabled":true,"protocol":"socks5","server":"proxy.example.test","port":1080,"username":"","expectedIp":"203.0.113.8"});
        c.engine.store.write("settings.json", &settings).unwrap();
        let mut entries = Vec::new();
        let mut pointers = Vec::new();
        for id in ["one", "two"] {
            let nodes: Vec<_> = (0..4).map(|i| json!({"name":format!("{id}-{i}"),"type":"http","server":"example.test","port":80})).collect();
            let path = format!("mihomo/providers/{id}.yaml");
            c.engine
                .store
                .write(&path, &json!({"proxies":nodes}))
                .unwrap();
            entries.push(json!({"id":id,"name":id,"enabled":true,"nodeCount":4,"status":"ready","url":"https://example.test/subscription"}));
            pointers.push(json!({"subscriptionId":id,"providerPath":c.engine.store.path(&path),"providerRevision":"v1"}));
        }
        c.engine
            .store
            .write("subscription.json", &json!({"entries":entries}))
            .unwrap();
        c.engine
            .store
            .write(
                "mihomo/providers/subscription-manifest.json",
                &json!({"schemaVersion":1,"revision":"v1","entries":pointers}),
            )
            .unwrap();
        let nodes = subscription::provider_nodes(&c.engine.store).unwrap();
        c.chain_cache_key = c.chain_cache_identity().unwrap();
        c.chain_scan = json!({"id":"fixture","cacheUsable":true,"cancelled":false,"running":false,"results":nodes.iter().map(|n|
            json!({"identityKey":n["identityKey"],"nodeName":n["name"],"providerRevision":n["providerRevision"],"status":"available","exitIp":"203.0.113.8","latencyMs":100,"jitterMs":1,"downloadMbps":10,"testedAt":now()})).collect::<Vec<_>>()});
        c.engine.pid = Some(std::process::id());
        c.engine.owned = c.engine.pid;
        c.wants_running = true;
        c.network_recovery.applied(Some("isolated".into()));
        (root, c)
    }

    #[test]
    fn confirmed_failures_prefer_the_other_subscription_and_persist_cooldown() {
        let (_root, mut c) = fixture();
        for _ in 0..2 {
            c.accept_path_health(crate::path_health::PathOutcome::EgressFailure);
            assert!(!c.chain_failover_ready());
        }
        c.accept_path_health(crate::path_health::PathOutcome::EgressFailure);
        assert!(c.chain_failover_ready());
        assert_eq!(c.network_recovery.status()["state"], "ready");
        let targets = c.failover_targets();
        assert_eq!(targets.len(), 4);
        assert_eq!(targets[0].0["subscriptionId"], "two");
        assert_eq!(targets[1].0["subscriptionId"], "two");
        let plan = c.take_chain_failover_request().unwrap();
        assert!(c.jobs.chain_connect_active.load(Ordering::SeqCst));
        drop(plan);
        assert!(!c.jobs.chain_connect_active.load(Ordering::SeqCst));
        assert!(!c.chain_failover_ready());
        c.chain_failover_attempt = None;
        c.load_chain_cache();
        assert!(!c.chain_failover_ready());
    }

    #[test]
    fn dns_faults_recovery_sleep_network_changes_and_foreign_connections_never_switch() {
        let (_root, mut c) = fixture();
        for _ in 0..3 {
            c.path_health
                .observe(crate::path_health::PathOutcome::DnsFailure, Instant::now());
        }
        assert!(!c.chain_failover_ready());
        c.path_health.invalidate();
        for _ in 0..3 {
            c.path_health.observe(
                crate::path_health::PathOutcome::EgressFailure,
                Instant::now(),
            );
        }
        assert!(c.chain_failover_ready());
        c.environment.sleeping = true;
        assert!(!c.chain_failover_ready());
        c.environment.sleeping = false;
        c.chain_network_changed_at = Some(Instant::now());
        assert!(!c.chain_failover_ready());
        c.chain_network_changed_at = None;
        c.health_failures = 1;
        assert!(!c.chain_failover_ready());
        c.health_failures = 0;
        c.engine.owned = None;
        assert!(!c.chain_failover_ready());
        c.engine.owned = c.engine.pid;
        c.wants_running = false;
        assert!(!c.chain_failover_ready());
        c.wants_running = true;
        c.network_recovery.changed_for(None, "network-change");
        assert!(!c.chain_failover_ready());
    }
}
