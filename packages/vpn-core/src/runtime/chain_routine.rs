//! A small, stable set of verified routes for everyday use.
use super::*;

fn successful(row: &Value) -> bool {
    row["status"] == "available"
        && row["exitIp"]
            .as_str()
            .is_some_and(|ip| ip.parse::<std::net::IpAddr>().is_ok())
}

pub(super) fn pool(
    nodes: &[Value],
    rows: &[Value],
    previous: &Value,
    selected: &Value,
) -> Vec<Value> {
    let matches = |node: &Value| {
        node["identityAmbiguous"] != true
            && rows.iter().any(|row| {
                successful(row)
                    && row["identityKey"] == node["identityKey"]
                    && row["providerRevision"] == node["providerRevision"]
            })
    };
    let ranked = crate::chain_scan::ranked(&json!({"results":rows}), "balanced")
        .unwrap_or_else(|_| json!({"results":[]}));
    let mut keys = Vec::new();
    if let Some(node) = nodes.iter().find(|n| n["name"] == *selected && matches(n)) {
        keys.push(node["identityKey"].clone());
    }
    // The current route is separate from each subscription's two backups.
    let mut counts = std::collections::HashMap::new();
    for key in previous.as_array().into_iter().flatten().chain(
        ranked["results"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|r| &r["identityKey"]),
    ) {
        if keys.contains(key) {
            continue;
        }
        if let Some(node) = nodes
            .iter()
            .find(|n| n["identityKey"] == *key && matches(n))
        {
            let count = counts
                .entry(node["subscriptionId"].clone().to_string())
                .or_insert(0);
            if *count >= 2 {
                continue;
            }
            keys.push(key.clone());
            *count += 1;
        }
    }
    keys.iter()
        .filter_map(|key| nodes.iter().find(|n| n["identityKey"] == *key).cloned())
        .collect()
}

pub(super) fn quick_candidates(
    nodes: &[Value],
    rows: &[Value],
    selected: &Value,
    favorites: &Value,
) -> Vec<Value> {
    let mut candidates: Vec<_> = nodes
        .iter()
        .enumerate()
        .filter_map(|(index, node)| {
            let row = rows.iter().find(|r| {
                r["identityKey"] == node["identityKey"]
                    && r["providerRevision"] == node["providerRevision"]
            });
            if row.is_some_and(|r| {
                crate::chain_scan::rejected(r)
                    && crate::chain_scan::retry_at(r).is_some_and(|t| t > chrono::Utc::now())
            }) {
                return None;
            }
            let priority = if node["name"] == *selected {
                0
            } else if favorites
                .as_array()
                .is_some_and(|names| names.contains(&node["name"]))
            {
                1
            } else if row.is_some_and(successful) {
                2
            } else if row.is_none() {
                3
            } else {
                4
            };
            Some((priority, index, node.clone()))
        })
        .collect();
    candidates.sort_by_key(|(priority, index, _)| (*priority, *index));
    candidates
        .into_iter()
        .take(3)
        .map(|(_, _, node)| node)
        .collect()
}

impl Core {
    pub(super) fn selected_route(&self, settings: &Value) -> Value {
        self.live_proxies
            .as_ref()
            .filter(|_| self.engine.pid.is_some())
            .and_then(|v| v["proxies"]["VPN"]["now"].as_str())
            .map(|name| json!(name))
            .unwrap_or_else(|| settings["selectedProxy"].clone())
    }

    pub(super) fn record_connection_check(&mut self, node: &Value, status: &str) {
        let stamp = now();
        if let Some(row) = self.chain_scan["results"].as_array_mut().and_then(|rows| {
            rows.iter_mut()
                .find(|r| r["identityKey"] == node["identityKey"])
        }) {
            row["lastVerificationAt"] = json!(stamp);
            row["lastVerificationStatus"] = json!(status);
        }
        if self.engine.pid.is_some()
            && self.engine.store.settings().is_ok_and(|s| {
                self.selected_route(&s) == node["name"] && s["staticExit"]["enabled"] == true
            })
        {
            if let Ok(context) = self.chain_cache_identity() {
                self.chain_scan["connectionCheck"] = json!({"identityKey":node["identityKey"],
                    "status":status,"checkedAt":stamp,"context":context});
            }
        }
    }

    pub(super) fn record_diagnostic_connection_check(&mut self, context: &Value, value: &Value) {
        if !self
            .chain_cache_identity()
            .is_ok_and(|current| current == *context)
        {
            return;
        }
        let Ok(settings) = self.engine.store.settings() else {
            return;
        };
        if self.engine.pid.is_none() || settings["staticExit"]["enabled"] != true {
            return;
        }
        let Ok(nodes) = subscription::provider_nodes(&self.engine.store) else {
            return;
        };
        let Some(node) = nodes.iter().find(|n| {
            n["name"] == self.selected_route(&settings) && n["identityAmbiguous"] != true
        }) else {
            return;
        };
        let result = value.get("connectivity").unwrap_or(value);
        if !result["proxyOk"].is_boolean() {
            return;
        }
        let previous = self.chain_scan["results"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|r| {
                r["identityKey"] == node["identityKey"]
                    && r["providerRevision"] == node["providerRevision"]
            });
        let expected = settings["staticExit"]["expectedIp"]
            .as_str()
            .filter(|s| !s.is_empty())
            .or_else(|| previous.and_then(|r| r["exitIp"].as_str()));
        let status =
            if result["proxyOk"] != true || expected.is_some_and(|ip| result["externalIp"] != ip) {
                "failed"
            } else if expected.is_some() {
                "passed"
            } else {
                "pending"
            };
        self.record_connection_check(node, status);
        // Accepted diagnostics can confirm the same failure as the lightweight
        // path sampler. Only explicit DNS evidence distinguishes an ISP fault.
        if self.wants_running && self.engine.owned == self.engine.pid {
            use crate::path_health::PathOutcome;
            let outcome = match result["systemDns"]["ok"].as_bool() {
                Some(false) => PathOutcome::DnsFailure,
                Some(true) if status == "failed" => PathOutcome::EgressFailure,
                Some(true) if status == "passed" => PathOutcome::Healthy,
                _ => PathOutcome::Skipped,
            };
            self.accept_path_health(outcome);
        }
        let _ = self.save_chain_cache();
    }

    pub(super) fn maintenance_candidates(&self, inventory: &[Value]) -> Vec<Value> {
        let Ok(key) = self.chain_cache_identity() else {
            return Vec::new();
        };
        if key["settings"].is_null() || key["settings"] != self.chain_cache_key["settings"] {
            return Vec::new();
        }
        let selected = self
            .engine
            .store
            .settings()
            .ok()
            .map(|s| self.selected_route(&s))
            .unwrap_or(Value::Null);
        pool(
            inventory,
            self.chain_scan["results"]
                .as_array()
                .map(Vec::as_slice)
                .unwrap_or_default(),
            &self.chain_scan["maintenanceIdentityKeys"],
            &selected,
        )
    }

    pub(super) fn refresh_maintenance_candidates(&mut self, rebuild: bool) {
        // Missing network/provider evidence is temporary; do not erase the
        // remembered set and accidentally rotate into the rest of a subscription.
        let (Ok(context), Ok(inventory), Ok(settings)) = (
            self.chain_cache_identity(),
            subscription::provider_nodes(&self.engine.store),
            self.engine.store.settings(),
        ) else {
            return;
        };
        let selected = self.selected_route(&settings);
        let previous = if rebuild {
            Value::Null
        } else {
            self.chain_scan["maintenanceIdentityKeys"].clone()
        };
        let nodes = if !context["settings"].is_null()
            && context["settings"] == self.chain_cache_key["settings"]
        {
            pool(
                &inventory,
                self.chain_scan["results"]
                    .as_array()
                    .map(Vec::as_slice)
                    .unwrap_or_default(),
                &previous,
                &selected,
            )
        } else {
            Vec::new()
        };
        self.chain_scan["maintenanceIdentityKeys"] = json!(
            nodes
                .iter()
                .map(|n| n["identityKey"].clone())
                .collect::<Vec<_>>()
        );
    }

    pub(super) fn routine_state(
        &self,
        state: &Value,
        inventory: &[Value],
        settings: &Value,
    ) -> Value {
        let current = inventory
            .iter()
            .find(|n| n["name"] == self.selected_route(settings) && n["identityAmbiguous"] != true);
        let connected = self.engine.pid.is_some() && settings["staticExit"]["enabled"] == true;
        let key = current
            .map(|n| n["identityKey"].clone())
            .unwrap_or(Value::Null);
        let row = state["results"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|r| r["identityKey"] == key);
        let mut verification = json!({"status":"pending","checkedAt":null});
        if connected {
            if let Some(row) = row.filter(|r| r["otherEnvironment"] != true) {
                if row["lastVerificationAt"].is_string() {
                    verification = json!({"status":row["lastVerificationStatus"],"checkedAt":row["lastVerificationAt"]});
                } else if row["lastVerifiedAt"].is_string() {
                    verification = json!({"status":"passed","checkedAt":row["lastVerifiedAt"]});
                }
            }
            let check = &self.chain_scan["connectionCheck"];
            if check["identityKey"] == key
                && self.chain_cache_identity().is_ok_and(|k| {
                    check["context"]["settings"] == k["settings"]
                        && check["context"]["network"] == k["network"]
                })
            {
                verification = json!({"status":check["status"],"checkedAt":check["checkedAt"]});
            }
        }
        let maintained = self.maintenance_candidates(inventory);
        let preferred = if connected {
            key.clone()
        } else {
            maintained
                .first()
                .map(|n| n["identityKey"].clone())
                .unwrap_or(Value::Null)
        };
        let performance = state["results"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|r| r["identityKey"] == preferred);
        let quick = quick_candidates(
            inventory,
            state["results"]
                .as_array()
                .map(Vec::as_slice)
                .unwrap_or_default(),
            &settings["selectedProxy"],
            &settings["favoriteNodeNames"],
        );
        let selection_confirmed = self
            .live_proxies
            .as_ref()
            .is_some_and(|v| v["proxies"]["VPN"]["now"] == self.selected_route(settings))
            || (!key.is_null() && self.chain_scan["connectedIdentityKey"] == key);
        json!({"connectionState":if connected {"connected"} else {"disconnected"},
            "currentSelectionConfirmed":selection_confirmed,
            "currentIdentityKey":if connected {key.clone()} else {Value::Null},
            "currentNodeName":if connected {current.map(|n| n["name"].clone()).unwrap_or(Value::Null)} else {Value::Null},
            "preferredIdentityKey":preferred.clone(),
            "verification":verification,"performanceTestedAt":performance.map(|r| r["testedAt"].clone()),
            "performanceOtherEnvironment":performance.is_some_and(|r| r["otherEnvironment"] == true),
            "maintenanceIdentityKeys":maintained.iter().map(|n| n["identityKey"].clone()).collect::<Vec<_>>(),
            "backupIdentityKeys":maintained.iter().filter(|n| n["identityKey"] != preferred).map(|n| n["identityKey"].clone()).collect::<Vec<_>>(),
            "quickIdentityKeys":quick.iter().map(|n| n["identityKey"].clone()).collect::<Vec<_>>()})
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn node(index: usize) -> Value {
        json!({"identityKey":format!("id-{index}"),"name":format!("node-{index}"),
            "providerRevision":"v1","identityAmbiguous":false})
    }
    fn row(index: usize) -> Value {
        json!({"identityKey":format!("id-{index}"),"providerRevision":"v1","status":"available",
            "exitIp":"203.0.113.8","downloadMbps":10+index,"latencyMs":100,"jitterMs":1,
            "testedAt":crate::storage::now()})
    }
    #[test]
    fn one_success_can_be_maintained_and_two_hundred_nodes_do_not_expand_the_pool() {
        let nodes: Vec<_> = (0..200).map(node).collect();
        let rows = vec![row(4)];
        let selected = pool(&nodes, &rows, &Value::Null, &json!("node-4"));
        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0]["identityKey"], "id-4");
        let rows: Vec<_> = (0..200).map(row).collect();
        let selected = pool(
            &nodes,
            &rows,
            &json!(["id-1", "id-2", "id-3"]),
            &json!("node-4"),
        );
        assert_eq!(
            selected
                .iter()
                .map(|n| n["identityKey"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["id-4", "id-1", "id-2"]
        );
    }
    #[test]
    fn failed_changed_and_unknown_routes_cannot_become_maintained_backups() {
        let mut nodes: Vec<_> = (0..4).map(node).collect();
        let mut rows: Vec<_> = (0..3).map(row).collect();
        nodes[1]["providerRevision"] = json!("v2");
        rows[2]["status"] = json!("unstable");
        let selected = pool(
            &nodes,
            &rows,
            &json!(["id-1", "id-2", "id-3"]),
            &json!("node-1"),
        );
        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0]["identityKey"], "id-0");
        let verified = vec![row(0), row(1), row(2)];
        let selected = pool(&nodes, &verified, &Value::Null, &json!("node-3"));
        assert!(selected.len() <= 2);
        assert!(selected.iter().all(|n| n["identityKey"] != "id-3"));
    }
    #[test]
    fn quick_search_is_bounded_and_skips_cooling_failures() {
        let nodes: Vec<_> = (0..200).map(node).collect();
        let mut failed = row(0);
        failed["status"] = json!("unreachable");
        failed["nextRetryAt"] =
            json!((chrono::Utc::now() + chrono::Duration::minutes(5)).to_rfc3339());
        let selected = quick_candidates(&nodes, &[failed], &json!("node-0"), &json!(["node-9"]));
        assert_eq!(selected.len(), 3);
        assert_eq!(selected[0]["identityKey"], "id-9");
        assert!(selected.iter().all(|n| n["identityKey"] != "id-0"));
    }
    #[test]
    fn each_subscription_keeps_two_backups_in_addition_to_the_current_route() {
        let mut nodes: Vec<_> = (0..20).map(node).collect();
        for (i, node) in nodes.iter_mut().enumerate() {
            node["subscriptionId"] = json!(if i < 10 { "one" } else { "two" });
        }
        let rows: Vec<_> = (0..20).map(row).collect();
        let first = pool(&nodes, &rows, &json!(["id-1", "id-2"]), &json!("node-0"));
        assert_eq!(first.len(), 5);
        let backups: Vec<_> = first
            .iter()
            .filter(|n| n["identityKey"] != "id-0")
            .collect();
        for subscription in ["one", "two"] {
            assert_eq!(
                backups
                    .iter()
                    .filter(|n| n["subscriptionId"] == subscription)
                    .count(),
                2
            );
        }
        // Ranking changes do not rotate the remembered backup set.
        let keys = json!(
            first
                .iter()
                .map(|n| n["identityKey"].clone())
                .collect::<Vec<_>>()
        );
        let mut changed = rows.clone();
        changed[8]["downloadMbps"] = json!(999);
        assert_eq!(pool(&nodes, &changed, &keys, &json!("node-0")), first);
        // Removed providers and changed node revisions lose their eligibility.
        nodes.retain(|n| n["subscriptionId"] != "two");
        nodes[1]["providerRevision"] = json!("changed");
        let after = pool(&nodes, &rows, &keys, &json!("node-0"));
        assert_eq!(after.len(), 3);
        assert!(after.iter().all(|n| n["identityKey"] != "id-1"));
    }
}
