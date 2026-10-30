//! Read-only scoped ranking, evidence-bound explanations and task progress.
use super::*;
impl Core {
    pub(super) fn record_chain_progress(&mut self, node: &Value, elapsed: Option<f64>) {
        if let Some(keys) = self.chain_scan["processedIdentityKeys"].as_array_mut() {
            if !keys.contains(&node["identityKey"]) {
                keys.push(node["identityKey"].clone());
            }
        }
        if let Some(ms) = elapsed {
            if let Some(samples) = self.chain_scan["sampleDurationsMs"].as_array_mut() {
                samples.push(json!(ms));
                if samples.len() > 20 {
                    samples.remove(0);
                }
            }
        }
    }
    pub(super) fn chain_scan_view(
        &self,
        strategy: &str,
        subscription_id: Option<&str>,
    ) -> Result<Value> {
        let mut state = self.chain_scan_state(strategy)?;
        let inventory = subscription::provider_nodes(&self.engine.store)?;
        let scope_keys = subscription_id.map(|id| {
            inventory
                .iter()
                .filter(|n| n["subscriptionId"] == id)
                .filter_map(|n| n["identityKey"].as_str())
                .collect::<HashSet<_>>()
        });
        let in_scope = |key: &Value| {
            scope_keys
                .as_ref()
                .is_none_or(|keys| key.as_str().is_some_and(|id| keys.contains(id)))
        };
        let mut scoped = state.clone();
        scoped["results"] = json!(
            state["results"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|r| in_scope(&r["identityKey"]))
                .cloned()
                .collect::<Vec<_>>()
        );
        let mut ranked = crate::chain_scan::ranked(&scoped, strategy)?;
        let settings = self.engine.store.settings()?;
        let baseline_key = inventory
            .iter()
            .find(|n| n["name"] == settings["selectedProxy"] && n["identityAmbiguous"] == false)
            .map(|n| &n["identityKey"]);
        let baseline = if self.engine.pid.is_some() && settings["staticExit"]["enabled"] == true {
            state["results"]
                .as_array()
                .and_then(|rs| rs.iter().find(|r| Some(&r["identityKey"]) == baseline_key))
        } else {
            None
        };
        let winner = ranked["recommendedIdentityKey"].clone();
        for row in ranked["results"].as_array_mut().into_iter().flatten() {
            let reason = comparison_reason(row, baseline, state["stale"] == true);
            row["comparisonReason"] = json!(if row["identityKey"] == winner
                && state["stale"] == false
                && row["requiresRefresh"] != true
            {
                let category = match strategy {
                    "download" => "下载",
                    "latency" => "响应",
                    _ => "综合",
                };
                format!("已测{category}第一 · {reason}")
            } else {
                reason
            });
        }
        let leaders = json!({
            "balanced":crate::chain_scan::ranked(&scoped, "balanced")?["recommendedIdentityKey"],
            "download":crate::chain_scan::ranked(&scoped, "download")?["recommendedIdentityKey"],
            "latency":crate::chain_scan::ranked(&scoped, "latency")?["recommendedIdentityKey"]
        });
        let tasks = self.chain_scan["taskIdentityKeys"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|key| in_scope(key))
            .cloned()
            .collect::<Vec<_>>();
        let processed = self.chain_scan["processedIdentityKeys"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect::<HashSet<_>>();
        let done = tasks
            .iter()
            .filter(|key| key.as_str().is_some_and(|id| processed.contains(id)))
            .count();
        let remaining = tasks.len().saturating_sub(done);
        let active_here =
            self.chain_scan["testing"] == true && in_scope(&self.chain_scan["currentIdentityKey"]);
        let durations = self.chain_scan["sampleDurationsMs"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_f64)
            .filter(|v| v.is_finite() && *v > 0.0)
            .collect::<Vec<_>>();
        let estimate = if state["running"] == true
            && state["mode"] != "continuous"
            && state["waitingReason"].is_null()
            && durations.len() >= 2
            && remaining > 0
        {
            let average = durations.iter().sum::<f64>() / durations.len() as f64;
            let elapsed = if active_here {
                self.chain_scan["currentSampleStartedAt"]
                    .as_str()
                    .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                    .map(|t| {
                        (chrono::Utc::now() - t.with_timezone(&chrono::Utc))
                            .num_milliseconds()
                            .max(0) as f64
                    })
                    .unwrap_or(0.0)
            } else {
                0.0
            };
            // Do not promise zero seconds while the final request is still running.
            Some(
                ((average * remaining as f64 - elapsed.min(average * 0.9)).max(1000.0) / 1000.0)
                    .ceil() as u64,
            )
        } else {
            None
        };
        let retry = self.chain_scan["results"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|r| in_scope(&r["identityKey"]))
            .filter_map(|r| r["nextRetryAt"].as_str())
            .filter_map(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .filter(|t| *t > chrono::Utc::now())
            .min()
            .map(|t| t.to_rfc3339());
        let progress = json!({"total":tasks.len(),"completed":done,"remaining":remaining,"estimatedSeconds":estimate,"sampleCount":state["completed"],"stage":if active_here {self.chain_scan["sampleStage"].clone()} else {Value::Null},"stageAttempt":if active_here {self.chain_scan["stageAttempt"].clone()} else {Value::Null},"stageTotal":if active_here {self.chain_scan["stageTotal"].clone()} else {Value::Null},"currentNode":if active_here {state["currentNode"].clone()} else {Value::Null},"testingOtherScope":state["testing"] == true && !active_here,"nextTestAt":state["nextTestAt"],"earliestRetryAt":retry});
        state["routine"] = self.routine_state(&state, &inventory, &settings);
        state["view"] = json!({"subscriptionId":subscription_id.unwrap_or(""),"results":ranked["results"],"leaders":leaders,"recommendedIdentityKey":ranked["recommendedIdentityKey"],"recommendationSummary":ranked["recommendationSummary"],"progress":progress});
        // Internal timing samples and key sets need not be copied into every UI reply.
        for key in [
            "taskIdentityKeys",
            "processedIdentityKeys",
            "sampleDurationsMs",
            "currentSampleStartedAt",
            "stageAttempt",
            "stageTotal",
            "sampleStage",
            "currentIdentityKey",
        ] {
            if let Some(object) = state.as_object_mut() {
                object.remove(key);
            }
        }
        Ok(state)
    }
}
fn metric(row: &Value, name: &str) -> Option<f64> {
    row[name].as_f64().filter(|v| v.is_finite() && *v >= 0.0)
}
fn comparison_reason(row: &Value, baseline: Option<&Value>, stale: bool) -> String {
    if row["status"] != "available" {
        return "尚未完整通过，不参与推荐。".into();
    }
    if stale || row["otherEnvironment"] == true {
        return "其他网络或配置下的成绩，仅供参考；请在当前环境重测。".into();
    }
    if row["requiresRefresh"] == true {
        return "性能测量时间较早，原成绩保留；可先复核使用，比较收益前再补测。".into();
    }
    let stats = format!(
        "下载 {:.1} Mbps · 响应 {:.0} ms · 波动 {:.0} ms",
        metric(row, "downloadMbps").unwrap_or(0.0),
        metric(row, "latencyMs").unwrap_or(0.0),
        metric(row, "jitterMs").unwrap_or(0.0)
    );
    let Some(base) =
        baseline.filter(|b| b["status"] == "available" && b["requiresRefresh"] != true)
    else {
        return format!("{stats}；当前线路暂无近期完整成绩可比较。");
    };
    if base["identityKey"] == row["identityKey"] {
        return format!("当前正在使用 · {stats}");
    }
    if !row["comparisonRound"].is_string() || row["comparisonRound"] != base["comparisonRound"] {
        return format!("{stats}；与当前线路不是同一轮测量，补测两条后再判断切换收益。");
    }
    let mut differences = Vec::new();
    if let Some((v, b)) = metric(row, "downloadMbps")
        .zip(metric(base, "downloadMbps"))
        .filter(|(_, b)| *b > 0.0)
    {
        let percent = ((v / b - 1.0) * 100.0).round();
        differences.push(if percent.abs() < 1.0 {
            "下载相近".into()
        } else {
            format!(
                "下载{} {:.0}%",
                if percent > 0.0 { "快" } else { "慢" },
                percent.abs()
            )
        });
    }
    for (key, label) in [("latencyMs", "响应"), ("jitterMs", "波动")] {
        if let Some((v, b)) = metric(row, key).zip(metric(base, key)) {
            let delta = (v - b).round();
            differences.push(if delta.abs() < 1.0 {
                format!("{label}相近")
            } else {
                format!(
                    "{label}{} {:.0} ms",
                    if key == "jitterMs" {
                        if delta > 0.0 { "更大" } else { "更小" }
                    } else if delta > 0.0 {
                        "慢"
                    } else {
                        "快"
                    },
                    delta.abs()
                )
            });
        }
    }
    if differences.is_empty() {
        format!("{stats}；缺少可比较的指标。")
    } else {
        format!("相对当前线路：{}", differences.join(" · "))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn row(id: &str, download: f64, latency: f64, jitter: f64) -> Value {
        json!({"identityKey":id,"status":"available","downloadMbps":download,"latencyMs":latency,"jitterMs":jitter,"requiresRefresh":false,"comparisonRound":"fixture"})
    }
    #[test]
    fn explanations_show_tradeoffs_and_never_claim_long_term_stability() {
        let base = row("base", 20.0, 100.0, 12.0);
        let reason = comparison_reason(&row("candidate", 27.0, 120.0, 8.0), Some(&base), false);
        assert!(reason.contains("下载快 35%"));
        assert!(reason.contains("响应慢 20 ms"));
        assert!(reason.contains("波动更小 4 ms"));
        assert!(!reason.contains("稳定"));
    }
    #[test]
    fn stale_incomplete_or_missing_baselines_cannot_invent_a_switching_benefit() {
        let candidate = row("candidate", 27.0, 120.0, 8.0);
        let mut base = row("base", 20.0, 100.0, 12.0);
        base["requiresRefresh"] = json!(true);
        assert!(comparison_reason(&candidate, Some(&base), false).contains("暂无近期完整成绩"));
        assert!(!comparison_reason(&candidate, Some(&base), false).contains("35%"));
        base["requiresRefresh"] = json!(false);
        base["status"] = json!("unstable");
        assert!(comparison_reason(&candidate, Some(&base), false).contains("暂无近期完整成绩"));
        assert!(comparison_reason(&candidate, None, true).contains("其他网络"));
        let mut old = candidate.clone();
        old["requiresRefresh"] = json!(true);
        assert!(comparison_reason(&old, Some(&base), false).contains("测量时间较早"));
    }
    #[test]
    fn current_route_and_equal_metrics_are_explicit() {
        let base = row("base", 20.0, 100.0, 12.0);
        assert!(comparison_reason(&base, Some(&base), false).contains("当前正在使用"));
        let equal = row("candidate", 20.0, 100.0, 12.0);
        assert!(comparison_reason(&equal, Some(&base), false).contains("下载相近"));
    }
    #[test]
    fn progress_uses_unique_task_keys_and_only_estimates_finite_active_work() {
        let root = tempfile::tempdir().unwrap();
        let mut core = Core::new(
            root.path().join("data"),
            root.path().into(),
            true,
            Arc::new(|_, _| {}),
            Arc::new(Jobs::default()),
        )
        .unwrap();
        core.chain_scan = json!({"id":"fixture","mode":"full","running":true,"results":[],"taskIdentityKeys":["a","b","c"],"processedIdentityKeys":[],"sampleDurationsMs":[],"completed":0});
        let a = json!({"identityKey":"a"});
        core.record_chain_progress(&a, Some(1000.0));
        core.record_chain_progress(&a, None);
        let first = core.chain_scan_view("balanced", None).unwrap();
        assert_eq!(first["view"]["progress"]["completed"], 1);
        assert!(first["view"]["progress"]["estimatedSeconds"].is_null());
        core.record_chain_progress(&json!({"identityKey":"b"}), Some(3000.0));
        let second = core.chain_scan_view("balanced", None).unwrap();
        assert_eq!(second["view"]["progress"]["remaining"], 1);
        assert_eq!(second["view"]["progress"]["estimatedSeconds"], 2);
        core.chain_scan["waitingReason"] = json!("network-unavailable");
        assert!(
            core.chain_scan_view("balanced", None).unwrap()["view"]["progress"]["estimatedSeconds"]
                .is_null()
        );
        core.chain_scan["waitingReason"] = Value::Null;
        core.chain_scan["mode"] = json!("continuous");
        assert!(
            core.chain_scan_view("balanced", None).unwrap()["view"]["progress"]["estimatedSeconds"]
                .is_null()
        );
    }
}
