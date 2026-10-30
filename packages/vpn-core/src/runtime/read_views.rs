//! Independent read views: a broken node/history file must not freeze all state.
use super::*;

pub(super) struct CachedReadView {
    result: std::result::Result<Value, String>,
    updated: Instant,
    valid_for: Duration,
}

impl Jobs {
    pub fn cached_read(&self, channel: &str) -> Option<Result<Value>> {
        let cache = self.read_views.lock().ok()?;
        let view = cache.get(channel)?;
        if view.updated.elapsed() > view.valid_for {
            self.wake_background();
            return Some(Err(anyhow::anyhow!("状态快照已过期，请稍后刷新确认连接。")));
        }
        if view.result.is_err() {
            // A normal refresh must notice repaired files even while disconnected.
            self.wake_background();
        }
        Some(view.result.clone().map_err(anyhow::Error::msg))
    }
}

fn readable(result: Result<Value>) -> std::result::Result<Value, String> {
    result.map_err(|error| redact(&error.to_string()))
}

impl Core {
    pub(super) fn bootstrap_view(
        &self,
        mut status: Value,
        nodes: Value,
        groups: Value,
        risks: Value,
        traffic: Value,
    ) -> Value {
        status["mihomo"]["viewRevision"] = json!(self.view_revision);
        json!({"status":status,"nodes":nodes,"groups":groups,"risks":risks,"traffic":traffic,
            "legacyOwnerRunning":!self.engine.isolated&&platform::legacy_owner(),"previewOnly":false,
            "ownsRuntime":self.engine.pid.is_some()&&self.engine.pid==self.engine.owned,
            "companyRouting":self.company.state(),"dataDir":self.engine.store.root,
            "diagnostics":self.diagnostics.status(),"currentExitRisk":self.current_exit_risk_view(),
            "viewRevision":self.view_revision,
            "chainScan":{"running":self.chain_scan["running"],"mode":self.chain_scan["mode"],
                "testing":self.chain_scan["testing"],"completed":self.chain_scan["completed"],"total":self.chain_scan["total"]},
            "core":{"implementation":"rust","protocolVersion":1,"version":env!("CARGO_PKG_VERSION")}})
    }

    pub fn publish_read_views(&mut self) {
        self.sync_diagnostics();
        self.view_revision = self.view_revision.saturating_add(1);
        let diagnostics = self.diagnostics.status();
        let mut status = readable(self.status());
        if let Ok(status) = &mut status {
            status["mihomo"]["viewRevision"] = json!(self.view_revision);
        }
        let nodes = readable(self.nodes().map(Value::from));
        let groups = match (&status, &nodes) {
            (Ok(status), Ok(nodes)) => {
                readable(self.groups_from_nodes(&status["settings"], nodes.as_array().unwrap()))
            }
            (Err(error), _) | (_, Err(error)) => Err(error.clone()),
        };
        let risks = readable(self.risks());
        let traffic = self.traffic();
        let bootstrap = match (&status, &nodes, &groups, &risks) {
            (Ok(status), Ok(nodes), Ok(groups), Ok(risks)) => Ok(self.bootstrap_view(
                status.clone(),
                nodes.clone(),
                groups.clone(),
                risks.clone(),
                traffic.clone(),
            )),
            (Err(error), _, _, _)
            | (_, Err(error), _, _)
            | (_, _, Err(error), _)
            | (_, _, _, Err(error)) => Err(error.clone()),
        };
        let node_state = match (&nodes, &groups) {
            (Ok(nodes), Ok(groups)) => json!({"nodes":nodes,"groups":groups,"error":null,
                "settings":status.as_ref().ok().map(|s| &s["settings"]),
                "subscription":status.as_ref().ok().map(|s| &s["subscription"])}),
            (Err(error), _) | (_, Err(error)) => json!({"nodes":null,"groups":null,"error":error}),
        };
        let views = [
            ("vpn:get-status", status),
            ("diagnostics:get-state", Ok(diagnostics.clone())),
            ("nodes:list", nodes),
            ("node-groups:list", groups),
            ("traffic:get-monitor", Ok(traffic.clone())),
            ("traffic:get-snapshot", Ok(traffic["snapshot"].clone())),
            ("native:bootstrap", bootstrap),
        ];
        let valid_for = self
            .background_interval()
            .saturating_mul(3)
            .max(Duration::from_secs(15));
        if let Ok(mut cache) = self.jobs.read_views.lock() {
            let updated = Instant::now();
            for (channel, mut result) in views {
                if let Ok(value) = &mut result {
                    if value.is_object() {
                        value["snapshotAt"] = json!(now());
                    }
                }
                cache.insert(
                    channel.into(),
                    CachedReadView {
                        result,
                        updated,
                        valid_for,
                    },
                );
            }
        }
        // Publish after the cache commit; clients can reject older in-flight snapshots.
        let serialized = diagnostics.to_string();
        if serialized != self.last_diagnostics_state {
            (self.events)("diagnostics:updated", diagnostics);
            self.last_diagnostics_state = serialized;
        }
        if node_state != self.last_nodes_state {
            self.last_nodes_state = node_state.clone();
            let mut event = node_state;
            event["viewRevision"] = json!(self.view_revision);
            (self.events)("nodes:updated", event);
        }
        let risk = self.current_exit_risk_view();
        if risk != self.last_exit_risk_state {
            self.last_exit_risk_state = risk.clone();
            (self.events)(
                "risk:current-updated",
                json!({"viewRevision":self.view_revision,"result":risk}),
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn expired_views_fail_without_returning_historical_success() {
        let jobs = Jobs::default();
        jobs.read_views.lock().unwrap().insert(
            "vpn:get-status".into(),
            CachedReadView {
                result: Ok(json!({"mihomo":{"state":"running"}})),
                updated: Instant::now() - Duration::from_secs(20),
                valid_for: Duration::from_secs(15),
            },
        );
        assert!(jobs.cached_read("vpn:get-status").unwrap().is_err());
        assert!(jobs.cached_read("not-a-cached-channel").is_none());
    }

    #[test]
    fn broken_inputs_replace_success_with_errors_and_leave_unrelated_views_available() {
        let root = tempfile::tempdir().unwrap();
        let mut core = Core::new(
            root.path().join("data"),
            root.path().into(),
            true,
            Arc::new(|_, _| {}),
            Arc::new(Jobs::default()),
        )
        .unwrap();
        core.publish_read_views();
        assert!(core.jobs.cached_read("native:bootstrap").unwrap().is_ok());
        fs::write(core.engine.store.path("ipdata-risk-cache.json"), "{broken").unwrap();
        core.publish_read_views();
        assert!(core.jobs.cached_read("native:bootstrap").unwrap().is_err());
        assert!(core.jobs.cached_read("vpn:get-status").unwrap().is_ok());
        assert!(core.jobs.cached_read("nodes:list").unwrap().is_ok());
        fs::write(core.engine.store.path("settings.json"), "{broken").unwrap();
        core.publish_read_views();
        assert!(core.jobs.cached_read("vpn:get-status").unwrap().is_err());
        assert!(
            core.jobs
                .cached_read("traffic:get-monitor")
                .unwrap()
                .is_ok()
        );
        assert!(
            core.jobs
                .cached_read("diagnostics:get-state")
                .unwrap()
                .is_ok()
        );
        fs::remove_file(core.engine.store.path("settings.json")).unwrap();
        fs::remove_file(core.engine.store.path("ipdata-risk-cache.json")).unwrap();
        core.publish_read_views();
        assert!(core.jobs.cached_read("native:bootstrap").unwrap().is_ok());
    }

    #[test]
    fn unchanged_nodes_are_not_pushed_with_every_traffic_refresh() {
        let root = tempfile::tempdir().unwrap();
        let count = Arc::new(AtomicU64::new(0));
        let observed = count.clone();
        let mut core = Core::new(
            root.path().join("data"),
            root.path().into(),
            true,
            Arc::new(move |name, _| {
                if name == "nodes:updated" {
                    observed.fetch_add(1, Ordering::SeqCst);
                }
            }),
            Arc::new(Jobs::default()),
        )
        .unwrap();
        for _ in 0..12 {
            core.publish_read_views();
        }
        assert_eq!(count.load(Ordering::SeqCst), 1);
    }
}
