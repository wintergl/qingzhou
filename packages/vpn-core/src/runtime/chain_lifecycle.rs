//! Scanner lifetime follows user intent, independently of business VPN checks.
use super::*;
#[derive(Default)]
pub(super) struct NetworkCache {
    checked: Option<Instant>,
    signature: Option<Value>,
}
impl Core {
    pub(super) fn invalidate_chain_network(&self) {
        if let Ok(mut cache) = self.chain_network.lock() {
            cache.checked = None;
        }
    }
    pub(super) fn observe_chain_path(&self, available: Option<bool>) {
        if let Ok(mut cache) = self.chain_network.lock() {
            if available == Some(false) {
                cache.signature = None;
                cache.checked = Some(Instant::now());
            } else {
                cache.checked = None;
            }
        }
    }
    pub(super) fn chain_network_signature(&self) -> Result<Value> {
        if self.engine.isolated {
            if let Some(path) = std::env::var_os("SPLITVPN_TEST_CHAIN_NETWORK_FILE") {
                let value: Value = serde_json::from_slice(&fs::read(path)?)?;
                ensure!(value["available"] == true, "测试网络暂不可用。");
                return Ok(value["signature"].clone());
            }
            return Ok(json!("isolated"));
        }
        let mut cache = self
            .chain_network
            .lock()
            .map_err(|_| anyhow::anyhow!("网络状态暂不可用。"))?;
        if cache
            .checked
            .is_none_or(|t| t.elapsed() >= Duration::from_secs(2))
        {
            cache.signature = platform::context().ok().map(|v| v["signature"].clone());
            cache.checked = Some(Instant::now());
        }
        cache.signature.clone().context("网络状态暂不可用。")
    }
    pub(super) fn chain_manifest_identity(&self) -> Result<Value> {
        let subscriptions = self.engine.store.subscription()?;
        let manifest = self.engine.store.manifest()?;
        let mut entries = manifest["entries"].as_array().context("订阅列表不可用。")?.iter()
            .filter(|p| subscriptions["entries"].as_array().is_some_and(|items| items.iter().any(|e|
                e["id"] == p["subscriptionId"] && e["enabled"] == true && e["nodeCount"].as_u64().unwrap_or(0) > 0)))
            .map(|p| json!({"subscriptionId":p["subscriptionId"],"providerRevision":p["providerRevision"]})).collect::<Vec<_>>();
        entries.sort_by(|a, b| {
            a["subscriptionId"]
                .as_str()
                .cmp(&b["subscriptionId"].as_str())
        });
        Ok(json!(entries))
    }
    pub(super) fn chain_configuration_current(&self) -> bool {
        self.chain_manifest_identity()
            .is_ok_and(|m| m == self.chain_manifest)
            && self.chain_context().is_ok_and(|s| s == self.chain_settings)
    }
    pub(super) fn prepare_chain_cycle(&mut self) -> Result<bool> {
        if self.chain_scan["automatic"] == true && self.environment.low_power {
            self.chain_scan["waitingReason"] = json!("low-power");
            self.chain_scan["testing"] = json!(false);
            self.chain_scan["currentNode"] = Value::Null;
            self.chain_scan["nextTestAt"] = Value::Null;
            return Ok(false);
        }
        if self.chain_scan["automatic"] == true && super::chain_automatic::battery_blocked(self) {
            self.chain_scan["waitingReason"] = json!("on-battery");
            self.chain_scan["testing"] = json!(false);
            self.chain_scan["currentNode"] = Value::Null;
            return Ok(false);
        }
        if self.chain_scan["automatic"] == true && super::chain_automatic::network_settling(self) {
            self.chain_scan["waitingReason"] = json!("network-settling");
            self.chain_scan["testing"] = json!(false);
            self.chain_scan["currentNode"] = Value::Null;
            return Ok(false);
        }
        if self.environment.sleeping {
            self.chain_scan["waitingReason"] = json!("sleeping");
            self.chain_scan["testing"] = json!(false);
            self.chain_scan["currentNode"] = Value::Null;
            self.chain_scan["nextTestAt"] = Value::Null;
            return Ok(false);
        }
        let Ok(key) = self.chain_cache_identity() else {
            self.chain_scan["waitingReason"] = json!("network-unavailable");
            self.chain_scan["testing"] = json!(false);
            self.chain_scan["currentNode"] = Value::Null;
            self.chain_scan["nextTestAt"] = Value::Null;
            return Ok(false);
        };
        if key != self.chain_cache_key {
            // Configuration/subscription changes stop the job via its outer guard.
            // A confirmed physical network change starts a new comparison set.
            self.chain_cache_key = key;
            self.chain_scan["results"] = json!([]);
            self.chain_scan["rejectedResults"] = json!([]);
            self.chain_scan["connectedIdentityKey"] = Value::Null;
            self.chain_scan["completed"] = json!(0);
            self.chain_scan["processedIdentityKeys"] = json!([]);
            self.chain_scan["sampleDurationsMs"] = json!([]);
            self.chain_scan["cacheUsable"] = json!(self.chain_scan["mode"] != "full");
            self.chain_scan["baselineReady"] = json!(false);
            self.chain_scan["networkRestarts"] =
                json!(self.chain_scan["networkRestarts"].as_u64().unwrap_or(0) + 1);
            self.save_chain_cache()?;
        }
        self.chain_scan["waitingReason"] = Value::Null;
        Ok(true)
    }
}
