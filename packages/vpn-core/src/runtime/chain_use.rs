//! Cancellable ISP connection and verified automatic failover. Performance records are
//! never refreshed by connection verification; the business path changes only
//! after an independent, loopback-only preflight succeeds.
use super::*;

impl Jobs {
    pub fn chain_use_request(&self, channel: &str, payload: &Value) -> Result<Value> {
        allowed_keys(
            payload,
            if channel == "chain-scan:cancel-use" {
                &["operationId"]
            } else {
                &[]
            },
        )?;
        let mut state = self
            .chain_use_state
            .lock()
            .map_err(|_| anyhow::anyhow!("连接状态暂不可用。"))?;
        if channel == "chain-scan:cancel-use" {
            let id = string(payload, "operationId")?;
            ensure!(uuid::Uuid::parse_str(id).is_ok(), "连接操作标识无效。");
            let mut cancelled = self
                .chain_use_cancelled
                .lock()
                .map_err(|_| anyhow::anyhow!("取消状态暂不可用。"))?;
            if !cancelled.iter().any(|value| value == id) {
                cancelled.push_back(id.to_owned());
                if cancelled.len() > 32 {
                    cancelled.pop_front();
                }
            }
            if state["operationId"] != id {
                return Ok(
                    json!({"operationId":id,"cancelRequested":true,"finished":false,"phase":"waiting"}),
                );
            }
            if state["finished"] != true {
                state["cancelRequested"] = json!(true);
            }
        }
        Ok(state.clone())
    }
}

pub struct ChainUse {
    id: String,
    node: Value,
    expected: String,
    environment: Value,
    token: DiagnosticToken,
    jobs: Arc<Jobs>,
    events: Events,
    failover_origin: Option<Value>,
    fallback_targets: Vec<(Value, String)>,
}
impl Drop for ChainUse {
    fn drop(&mut self) {
        if let Ok(mut state) = self.jobs.chain_use_state.lock() {
            if state["operationId"] == self.id && state["finished"] != true {
                state["phase"] = json!("unknown");
                state["finished"] = json!(true);
                state["error"] = json!("连接操作已中断，请刷新实际状态。");
            }
        }
        self.jobs
            .chain_connect_active
            .store(false, Ordering::SeqCst);
        self.jobs.wake_background();
    }
}
impl Core {
    pub(super) fn prepare_chain_use(&self, p: &Value) -> Result<ChainUse> {
        allowed_keys(p, &["scanId", "identityKey", "strategy", "operationId"])?;
        self.assert_company_owner()?;
        ensure!(
            !self.engine.protected(),
            "当前连接由其他客户端维护，请先在原客户端断开。"
        );
        ensure!(
            !self.jobs.stop_requested.load(Ordering::SeqCst),
            "断开操作尚未结束，请稍后重试。"
        );
        ensure!(
            self.engine.store.recovery()?["state"] != "required"
                && !self
                    .engine
                    .store
                    .path("runtime-state/rust-pending.json")
                    .exists(),
            "RECOVERY_REQUIRED：上次恢复尚未确认，请先检查并恢复网络。"
        );
        let id = string(p, "operationId")?.to_owned();
        ensure!(uuid::Uuid::parse_str(&id).is_ok(), "连接操作标识无效。");
        ensure!(
            !self
                .jobs
                .chain_use_cancelled
                .lock()
                .map_err(|_| anyhow::anyhow!("取消状态暂不可用。"))?
                .contains(&id),
            "连接已取消，原配置未改动。"
        );
        let (node, expected) = self.chain_connection_target(p)?;
        let environment = self.chain_cache_identity()?;
        let settings = self.engine.store.settings()?;
        let mut exit = settings["staticExit"].clone();
        exit["enabled"] = json!(true);
        crate::static_exit::validate(&exit)?;
        ensure!(
            exit["username"].as_str().unwrap_or("").is_empty()
                || crate::static_exit::credential_matches(&exit, &self.exit_credential)
                    && self.exit_credential["password"]
                        .as_str()
                        .is_some_and(|p| !p.is_empty()),
            "ISP 密码尚未加载，请打开 ISP 配置重新保存。"
        );
        ensure!(
            self.jobs
                .chain_connect_active
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok(),
            "连接操作正在进行，请等待或取消当前操作。"
        );
        let plan = ChainUse {
            id,
            node,
            expected,
            environment,
            token: self.diagnostic_token(),
            jobs: self.jobs.clone(),
            events: self.events.clone(),
            failover_origin: None,
            fallback_targets: Vec::new(),
        };
        if let Ok(mut state) = plan.jobs.chain_use_state.lock() {
            *state = json!({"operationId":plan.id,"identityKey":plan.node["identityKey"],"nodeName":plan.node["name"],"phase":"verifying","finished":false,"cancelRequested":false,"automatic":false,
                "previousNodeName":if self.engine.pid.is_some() && settings["staticExit"]["enabled"] == true {self.selected_route(&settings)} else {Value::Null}});
        }
        plan.phase("verifying");
        Ok(plan)
    }

    fn restore_chain_use(
        &mut self,
        journal: &Value,
        was_running: bool,
        reload_before: u64,
    ) -> Result<()> {
        if !was_running && self.engine.pid.is_some() {
            // Only stop the new engine owned by this operation. An unconfirmed
            // process is retained together with the recovery journal.
            ensure!(
                self.engine.owned == self.engine.pid,
                "新连接身份尚未确认，恢复记录已保留。"
            );
            self.stop_runtime()?;
            self.live_proxies = None;
        }
        self.restore_transaction(journal)?;
        if was_running {
            ensure!(
                self.engine.pid.is_some()
                    && journal["chainUseOriginalPid"].as_u64() == self.engine.pid.map(u64::from),
                "原连接的运行身份已变化，恢复尚未确认。"
            );
            if self.engine.reload_attempts.load(Ordering::SeqCst) != reload_before {
                let base = journal["files"]["mihomo/config.yaml"]
                    .as_str()
                    .context("原配置恢复记录缺失。");
                self.company.reload_base(&mut self.engine, base?)?;
            }
            self.engine
                .restore_selections_checked(&journal["selections"])?;
            if let Some(live) = self.live_proxies.as_mut() {
                live["proxies"]["VPN"]["now"] = journal["selections"]["VPN"].clone();
            }
        }
        Ok(())
    }
}

impl ChainUse {
    pub(super) fn with_failover(mut self, origin: Value, targets: Vec<(Value, String)>) -> Self {
        if let Ok(mut state) = self.jobs.chain_use_state.lock() {
            state["automatic"] = json!(true);
            state["previousNodeName"] = origin.clone();
        }
        self.failover_origin = Some(origin);
        self.fallback_targets = targets;
        self.phase("verifying");
        self
    }
    fn check_failover_origin(&self, c: &Core) -> Result<()> {
        if let Some(origin) = &self.failover_origin {
            ensure!(
                c.diagnostic_current(&self.token)
                    && c.selected_route(&c.engine.store.settings()?) == *origin
                    && c.path_health.status()["state"] == "degraded"
                    && c.path_health.status()["failureKind"] == "egress",
                "当前线路或健康状态已变化，已取消自动切换。"
            );
        }
        Ok(())
    }
    fn phase(&self, phase: &str) {
        if let Ok(mut state) = self.jobs.chain_use_state.lock() {
            state["phase"] = json!(phase);
            (self.events)("chain-scan:use-status", state.clone());
        }
    }
    fn check(&self, c: &Core) -> Result<()> {
        if self.failover_origin.is_some() {
            ensure!(
                c.wants_running
                    && c.engine.pid.is_some()
                    && c.engine.owned == c.engine.pid
                    && c.engine.store.settings()?["staticExit"]["enabled"] == true,
                "ISP 连接已变化，已取消自动切换。"
            );
        }
        ensure!(
            !self.jobs.shutdown.load(Ordering::SeqCst)
                && !self.jobs.stop_requested.load(Ordering::SeqCst)
                && !self
                    .jobs
                    .chain_use_state
                    .lock()
                    .map_err(|_| anyhow::anyhow!("连接状态暂不可用。"))?["cancelRequested"]
                    .as_bool()
                    .unwrap_or(false),
            "连接已取消。"
        );
        ensure!(
            !self
                .jobs
                .chain_use_cancelled
                .lock()
                .map_err(|_| anyhow::anyhow!("取消状态暂不可用。"))?
                .contains(&self.id),
            "连接已取消。"
        );
        ensure!(
            self.jobs.intent_epoch.load(Ordering::SeqCst) == self.token.epoch
                && c.revision == self.token.revision
                && !c.environment.sleeping
                && c.chain_cache_identity()
                    .is_ok_and(|key| key == self.environment),
            "连接环境已变化，请重新复核。"
        );
        c.assert_company_owner()?;
        ensure!(!c.engine.protected(), "当前连接由其他客户端维护。");
        Ok(())
    }
    pub(super) fn run(mut self, core: &Mutex<Core>) -> Result<Value> {
        let gate = self.jobs.probe_gate.clone();
        let _lease = gate
            .lock()
            .map_err(|_| anyhow::anyhow!("检测入口不可用。"))?;
        let result = self.perform(core);
        if result.is_err() && self.failover_origin.is_some() {
            if let Ok(mut c) = core.lock() {
                if self.check(&c).is_ok() && self.check_failover_origin(&c).is_ok() {
                    c.network_recovery.changed_for(None, "egress-health");
                    c.last_network_tick = None;
                }
            }
        }
        let mut state = self
            .jobs
            .chain_use_state
            .lock()
            .map_err(|_| anyhow::anyhow!("连接状态暂不可用。"))?;
        state["finished"] = json!(true);
        match &result {
            Ok(value) => {
                state["phase"] = json!("connected");
                state["result"] = value.clone();
            }
            Err(error) => {
                state["phase"] = json!(if state["cancelRequested"] == true
                    || self.jobs.stop_requested.load(Ordering::SeqCst)
                {
                    "cancelled"
                } else {
                    "failed"
                });
                state["error"] = json!(redact(&error.to_string()));
            }
        }
        (self.events)("chain-scan:use-status", state.clone());
        result
    }
    fn perform(&mut self, core: &Mutex<Core>) -> Result<Value> {
        let (probe, io, port, targets) = {
            let c = core
                .lock()
                .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
            self.check(&c)?;
            self.check_failover_origin(&c)?;
            ensure!(
                c.diagnostic_current(&self.token),
                "连接已变化，请重新复核。"
            );
            let probe = if c.engine.isolated {
                None
            } else {
                Some(chain_probe::ChainProbe::start(
                    &c,
                    &c.engine.store.settings()?,
                )?)
            };
            let mut io = probe
                .as_ref()
                .map(|p| p.io.clone())
                .unwrap_or_else(|| c.engine.io());
            if c.engine.isolated {
                io.controller = c.chain_scan_port()?;
            }
            let port = match &probe {
                Some(p) => p.port,
                None => c.chain_scan_port()?,
            };
            (probe, io, port, chain_targets(c.engine.isolated)?)
        };
        let mut candidates =
            std::collections::VecDeque::from(std::mem::take(&mut self.fallback_targets));
        let preflight = loop {
            {
                let c = core
                    .lock()
                    .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
                self.check(&c)?;
                self.check_failover_origin(&c)?;
            }
            io.api(
                "PUT",
                &format!("/proxies/{}", encode(crate::static_exit::SCAN_FRONT)),
                Some(&json!({"name":self.node["name"]})),
            )?;
            let result =
                crate::chain_scan::recheck(port, &targets.latency, &targets.ip, &self.expected);
            if result.is_ok() || candidates.is_empty() {
                break result;
            }
            {
                let mut c = core
                    .lock()
                    .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
                self.check(&c)?;
                c.record_connection_check(&self.node, "failed");
            }
            (self.node, self.expected) = candidates.pop_front().unwrap();
            if let Ok(mut state) = self.jobs.chain_use_state.lock() {
                state["identityKey"] = self.node["identityKey"].clone();
                state["nodeName"] = self.node["name"].clone();
            }
            self.phase("verifying");
        };
        drop(probe);
        let mut c = core
            .lock()
            .map_err(|_| anyhow::anyhow!("后台状态不可用。"))?;
        self.check(&c)?;
        self.check_failover_origin(&c)?;
        if let Err(error) = preflight {
            c.record_connection_check(&self.node, "failed");
            let _ = c.save_chain_cache();
            bail!("目标线路复核失败：{error}；原配置与连接未改动。");
        }
        c.engine.attach()?;
        ensure!(
            c.diagnostic_current(&self.token),
            "连接已变化，原连接未改动。"
        );
        self.phase("authorizing");
        if self.failover_origin.is_none() {
            c.ensure_user_helper()?;
        }
        self.check(&c)?;
        // Updating an existing helper may legitimately reattach the same route.
        self.token = c.diagnostic_token();
        let was_running = c.engine.pid.is_some();
        let wants_before = c.wants_running;
        let network_before = c.network_recovery.clone();
        let reload_before = c.engine.reload_attempts.load(Ordering::SeqCst);
        let selections = if was_running {
            let selections = c
                .engine
                .selections()
                .context("当前线路无法核对，原配置与连接未改动。")?;
            ensure!(
                selections["VPN"].is_string(),
                "当前线路无法核对，原配置与连接未改动。"
            );
            if let Some(origin) = &self.failover_origin {
                ensure!(
                    selections["VPN"] == *origin,
                    "实际线路已变化，已取消自动切换。"
                );
            }
            selections
        } else {
            json!({})
        };
        let mut journal = c.begin_transaction()?;
        journal["selections"] = selections;
        journal["chainUseWasRunning"] = json!(was_running);
        journal["chainUseOriginalPid"] = json!(c.engine.pid);
        c.engine
            .store
            .write("runtime-state/rust-pending.json", &journal)?;
        let applied = (|| -> Result<Value> {
            self.check(&c)?;
            self.phase("applying");
            let mut settings = c.engine.store.settings()?;
            let unchanged = was_running
                && settings["staticExit"]["enabled"] == true
                && settings["selectedProxy"] == self.node["name"]
                && c.engine.selections()?["VPN"] == self.node["name"];
            settings["staticExit"]["enabled"] = json!(true);
            settings["selectedProxy"] = self.node["name"].clone();
            settings["defaultOutlet"] = json!({"kind":"node","identityKey":self.node["identityKey"],"name":self.node["name"]});
            settings = normalize_settings(settings)?;
            if !unchanged {
                if was_running {
                    c.apply_config(&settings)?;
                    c.engine.select(self.node["name"].as_str().unwrap())?;
                    c.engine.store.write("settings.json", &settings)?;
                } else {
                    c.engine.store.write("settings.json", &settings)?;
                    c.start_vpn(false)?;
                    journal["chainUseStartedPid"] = json!(c.engine.pid);
                    c.engine
                        .store
                        .write("runtime-state/rust-pending.json", &journal)?;
                }
            }
            self.check(&c)?;
            self.phase("confirming");
            let business_port = if c.engine.isolated {
                c.chain_scan_port()?
            } else {
                c.static_exit_port()?
            };
            let (ip, latency) = crate::chain_scan::recheck(
                business_port,
                &targets.latency,
                &targets.ip,
                &self.expected,
            )
            .context("实际连接的连通性或出口尚未确认。")?;
            self.check(&c)?;
            ensure!(
                c.engine.selections()?["VPN"] == self.node["name"],
                "实际线路尚未确认。"
            );
            if !unchanged {
                c.engine
                    .close_departed_path_connections(&c.jobs.stop_requested, true)?;
            }
            Ok(json!({"exitIp":ip,"verificationLatencyMs":latency}))
        })();
        // This match also covers start, authorization, cancellation and final
        // verification failures; a rollback failure never reports restoration.
        let result = match applied {
            Ok(value) => {
                if let Err(error) = self.check(&c).and_then(|_| {
                    ensure!(
                        c.engine.selections()?["VPN"] == self.node["name"],
                        "实际线路尚未确认。"
                    );
                    Ok(())
                }) {
                    Err(error)
                } else {
                    Ok(value)
                }
            }
            Err(error) => Err(error),
        };
        if let Err(error) = result {
            self.phase("restoring");
            let restored = c.restore_chain_use(&journal, was_running, reload_before);
            c.wants_running = wants_before && !self.jobs.stop_requested.load(Ordering::SeqCst);
            c.network_recovery = network_before;
            if restored.is_err() {
                c.wants_running = false;
                c.engine.last_error = Some("原连接恢复尚未确认，请检查实际状态。".into());
                c.network_recovery.failed(
                    "原连接恢复尚未确认，请检查实际状态。".into(),
                    Instant::now(),
                );
                let _ = c
                    .engine
                    .store
                    .set_recovery(true, Some("chain-use-rollback-failed"));
                c.publish_read_views();
                bail!(
                    "{}；原连接恢复尚未确认，恢复记录已保留，请检查实际状态。",
                    redact(&error.to_string())
                );
            }
            c.finish_transaction();
            c.publish_read_views();
            bail!(
                "{}；{}。",
                redact(&error.to_string()),
                if was_running {
                    "原配置与线路已恢复"
                } else {
                    "原配置已恢复，VPN 未连接"
                }
            );
        }
        let value = result?;
        c.revision += 1;
        c.wants_running = true;
        if let Some(live) = c.live_proxies.as_mut() {
            live["proxies"]["VPN"]["now"] = self.node["name"].clone();
        }
        c.chain_scan["connectedIdentityKey"] = self.node["identityKey"].clone();
        c.record_connection_check(&self.node, "passed");
        if self.failover_origin.is_some() {
            c.path_health.invalidate();
            c.chain_scan["lastFailoverAt"] = json!(now());
            c.log("info", "ISP 已切换到复核通过的备用线路。");
        }
        c.chain_token = Some(c.diagnostic_token());
        c.refresh_maintenance_candidates(false);
        let _ = c.save_chain_cache();
        c.finish_transaction();
        c.publish_runtime_status();
        c.publish_read_views();
        Ok(
            json!({"connected":true,"nodeName":self.node["name"],"identityKey":self.node["identityKey"],"exitIp":value["exitIp"],"verificationLatencyMs":value["verificationLatencyMs"],"verifiedAt":now(),"operationId":self.id}),
        )
    }
}
