//! A current-exit observation must never be substituted by an airport-node score.
use super::*;

impl Core {
    pub(super) fn prepare_current_exit_risk(&self) -> Result<NodeDiagnostic> {
        let settings = self.engine.store.settings()?;
        let name = settings["selectedProxy"]
            .as_str()
            .context("当前节点不存在。")?;
        let mut plan = self.prepare_node_diagnostic(name, "risk", false)?;
        let static_exit = settings["staticExit"]["enabled"] == true;
        plan.probe = if static_exit {
            self.static_exit_port()?
        } else {
            self.engine.mixed
        };
        plan.select_probe = false;
        plan.via_static_exit = static_exit;
        // Hash the non-secret route identity; never persist credentials in the key.
        plan.current_exit_key = Some(crate::storage::sha256(&serde_json::to_vec(&json!({
            "identityKey":plan.node["identityKey"],"providerRevision":plan.node["providerRevision"],
            "selectedProxy":name,"staticExit":settings["staticExit"]
        }))?));
        Ok(plan)
    }

    pub(super) fn finish_current_exit_risk(
        &mut self,
        plan: &NodeDiagnostic,
        key: &str,
        mut result: Value,
    ) -> Result<Value> {
        result["scope"] = json!("current-exit");
        result["outletKey"] = json!(key);
        result["identityKey"] = plan.node["identityKey"].clone();
        result["viaStaticExit"] = json!(plan.via_static_exit);
        let ip = result["ip"]
            .as_str()
            .context("风险服务未返回出口 IP。")?
            .to_owned();
        let mut cache = self.engine.store.read(
            "current-exit-risk-cache.json",
            json!({"schemaVersion":1,"entries":[]}),
        )?;
        let entries = cache["entries"]
            .as_array_mut()
            .context("当前出口风险缓存格式无效，原文件已保留。")?;
        entries.retain(|entry| !(entry["outletKey"] == key && entry["ip"] == ip));
        entries.insert(0, result.clone());
        self.engine
            .store
            .write("current-exit-risk-cache.json", &cache)?;
        self.current_exit_risk = Some((plan.token.clone(), result.clone()));
        Ok(result)
    }

    pub(super) fn current_exit_risk_view(&self) -> Value {
        let Some((token, result)) = &self.current_exit_risk else {
            return Value::Null;
        };
        if self.engine.pid.is_none() || !self.diagnostic_current(token) {
            return Value::Null;
        }
        let diagnostic = self.diagnostics.status();
        let check = &diagnostic["connectivity"];
        // A newer observation of a different IP invalidates this risk label.
        if check["staleResult"] != true && check["state"] == "ready" {
            let checked = check["checkedAt"]
                .as_str()
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok());
            let risk_time = result["checkedAt"]
                .as_str()
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok());
            if checked.zip(risk_time).is_some_and(|(a, b)| a > b)
                && check["result"]["connectivity"]["externalIp"].is_string()
                && check["result"]["connectivity"]["externalIp"] != result["ip"]
            {
                return Value::Null;
            }
        }
        result.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn newer_exit_ip_or_connection_intent_invalidates_risk_without_deleting_history() {
        let root = tempfile::tempdir().unwrap();
        let mut core = Core::new(
            root.path().join("data"),
            root.path().into(),
            true,
            Arc::new(|_, _| {}),
            Arc::new(Jobs::default()),
        )
        .unwrap();
        core.engine.pid = Some(1234); // Memory-only fixture; no process is started.
        let previous =
            json!({"ip":"203.0.113.8","checkedAt":"2020-01-01T00:00:00Z","riskLevel":"low"});
        core.current_exit_risk = Some((core.diagnostic_token(), previous.clone()));
        assert_eq!(core.current_exit_risk_view()["ip"], "203.0.113.8");
        let id = core
            .diagnostics
            .claim(CheckKind::Connectivity, true)
            .unwrap();
        core.diagnostics.finish(
            CheckKind::Connectivity,
            id,
            Ok(json!({"connectivity":{"externalIp":"203.0.113.9"}})),
            Instant::now(),
        );
        assert!(core.current_exit_risk_view().is_null());
        core.current_exit_risk = Some((
            core.diagnostic_token(),
            json!({"ip":"203.0.113.9","checkedAt":now()}),
        ));
        assert_eq!(core.current_exit_risk_view()["ip"], "203.0.113.9");
        core.jobs.invalidate_diagnostics();
        assert!(core.current_exit_risk_view().is_null());
        assert!(
            core.current_exit_risk.is_some(),
            "Invalidation changes presentation, not recorded evidence"
        );
    }
}
