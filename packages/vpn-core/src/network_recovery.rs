//! Connection recovery policy. Network identifiers stay in memory and never
//! appear in the status payload; OS effects belong to the desktop runtime.
use crate::storage::now;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

const STABLE_FOR: Duration = Duration::from_secs(3);
const MAX_ATTEMPTS: u32 = 3;

#[derive(Clone, Default)]
pub struct NetworkRecovery {
    sequence: u64,
    active: Option<(u64, String, Instant, String)>,
    history: Vec<Value>,
    check_pending: bool,
    phase: Option<&'static str>,
    applied: Option<String>,
    pending: Option<(String, Instant)>,
    interrupted: bool,
    available_hint: Option<bool>,
    hint_at: Option<Instant>,
    state: Option<&'static str>,
    error: Option<String>,
    attempts: u32,
    retry_at: Option<Instant>,
}

impl NetworkRecovery {
    pub fn status(&self) -> Value {
        json!({"state":self.state.unwrap_or("idle"),"error":self.error,
               "attempts":self.attempts,"maxAttempts":MAX_ATTEMPTS,
               "phase":self.phase,"history":self.history,
               "startedAt":self.active.as_ref().map(|v| &v.1),
               "helperUpdateRequired":self.state == Some("helper-update-required")})
    }

    pub fn applied(&mut self, signature: Option<String>) {
        if self.active.is_some() {
            self.finish("checking");
            self.check_pending = true;
        }
        self.phase = None;
        self.applied = signature;
        self.pending = None;
        self.interrupted = false;
        self.available_hint = None;
        self.hint_at = None;
        self.state = Some("ready");
        self.error = None;
        self.attempts = 0;
        self.retry_at = None;
    }

    pub fn clear(&mut self) {
        self.invalidate_check("cancelled");
        self.finish("cancelled");
        let sequence = self.sequence.wrapping_add(1);
        let history = std::mem::take(&mut self.history);
        *self = Self {
            sequence,
            history,
            ..Self::default()
        };
    }

    /// A path event or wake must recover even if DHCP gives us the same address.
    pub fn changed(&mut self, available: Option<bool>) {
        self.begin("network-change");
        self.phase = Some("waiting-stable");
        self.interrupted = true;
        self.available_hint = available;
        self.hint_at = Some(Instant::now());
        self.pending = None;
        self.attempts = 0;
        self.retry_at = None;
        if self.state != Some("helper-update-required") {
            self.state = Some(if available == Some(false) {
                "waiting-network"
            } else {
                "recovering"
            });
            self.error = None;
        }
    }

    fn begin(&mut self, reason: &str) {
        if self.active.is_none() {
            self.invalidate_check("interrupted");
            self.sequence = self.sequence.wrapping_add(1);
            self.check_pending = false;
            self.active = Some((self.sequence, now(), Instant::now(), reason.into()));
        }
    }

    fn invalidate_check(&mut self, outcome: &str) {
        if let Some(record) = self
            .history
            .first_mut()
            .filter(|v| v["outcome"] == "checking")
        {
            record["outcome"] = json!(outcome);
        }
    }

    pub fn changed_for(&mut self, available: Option<bool>, reason: &str) {
        self.changed(available);
        if let Some(active) = &mut self.active {
            active.3 = reason.into();
        }
    }

    fn finish(&mut self, outcome: &str) {
        if let Some((id, started_at, started, reason)) = self.active.take() {
            self.history.insert(
                0,
                json!({"id":id,"startedAt":started_at,"finishedAt":now(),
                "durationMs":started.elapsed().as_millis() as u64,"reason":reason,
                "outcome":outcome,"attempts":self.attempts,"error":self.error}),
            );
            self.history.truncate(10);
        }
    }

    /// Claim one check per completed recovery; stale checks cannot overwrite a new path.
    pub fn take_check(&mut self) -> Option<u64> {
        if !self.check_pending {
            return None;
        }
        self.check_pending = false;
        Some(self.sequence)
    }

    pub fn checked(&mut self, id: u64, ok: bool) {
        if id != self.sequence || self.state != Some("ready") {
            return;
        }
        if let Some(record) = self.history.first_mut().filter(|v| v["id"] == id) {
            record["outcome"] = json!(if ok { "verified" } else { "unverified" });
            record["checkedAt"] = json!(now());
        }
    }

    pub fn require_helper_update(&mut self, message: &str) {
        self.finish("helper-update-required");
        self.check_pending = false;
        self.state = Some("helper-update-required");
        self.error = Some(message.to_owned());
        self.pending = None;
    }

    pub fn helper_update_required(&self) -> bool {
        self.state == Some("helper-update-required")
    }

    pub fn needs_fast_check(&self) -> bool {
        self.state == Some("recovering")
            || (self.state == Some("failed") && self.attempts < MAX_ATTEMPTS)
    }

    pub fn failed(&mut self, error: String, now: Instant) {
        self.interrupted = true;
        self.state = Some("failed");
        self.error = Some(error);
        self.attempts += 1;
        self.phase = Some("retry-wait");
        if self.attempts >= MAX_ATTEMPTS {
            self.finish("failed");
        }
        self.retry_at = Some(now + Duration::from_secs(3 * u64::from(self.attempts)));
    }

    /// Returns true only once the physical path is stable and a retry is due.
    /// The caller records success with applied(), or failure with failed().
    pub fn observe(&mut self, signature: Option<&str>, running: bool, now: Instant) -> bool {
        if self.helper_update_required() {
            return false;
        }
        // An OS callback is a hint, not a permanent veto. If its matching online
        // callback is lost, the slow physical-route check must be able to recover.
        let offline = self.available_hint == Some(false)
            && self
                .hint_at
                .is_some_and(|time| now.saturating_duration_since(time) < Duration::from_secs(30));
        let signature = signature.filter(|_| !offline);
        let Some(signature) = signature else {
            self.begin("network-change");
            self.interrupted = true;
            self.pending = None;
            self.state = Some("waiting-network");
            self.error = None;
            self.attempts = 0;
            self.retry_at = None;
            return false;
        };
        if running && !self.interrupted && self.applied.as_deref() == Some(signature) {
            return false;
        }
        if self.attempts < MAX_ATTEMPTS
            || self
                .pending
                .as_ref()
                .is_none_or(|(key, _)| key != signature)
        {
            self.begin("network-change");
        }
        if self
            .pending
            .as_ref()
            .is_none_or(|(key, _)| key != signature)
        {
            self.phase = Some("waiting-stable");
            self.pending = Some((signature.to_owned(), now));
            self.state = Some("recovering");
            self.error = None;
            self.attempts = 0;
            self.retry_at = None;
            return false;
        }
        if now.duration_since(self.pending.as_ref().unwrap().1) < STABLE_FOR
            || self.attempts >= MAX_ATTEMPTS
            || self.retry_at.is_some_and(|deadline| now < deadline)
        {
            return false;
        }
        self.state = Some("recovering");
        self.phase = Some("applying");
        self.error = None;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unchanged_live_network_does_not_reload_but_outage_on_same_network_does() {
        let t = Instant::now();
        let mut recovery = NetworkRecovery::default();
        recovery.applied(Some("en0|gateway|address".into()));
        assert!(!recovery.observe(Some("en0|gateway|address"), true, t));
        assert!(!recovery.observe(None, true, t));
        assert_eq!(recovery.status()["state"], "waiting-network");
        assert!(!recovery.observe(Some("en0|gateway|address"), true, t));
        assert!(recovery.observe(Some("en0|gateway|address"), true, t + STABLE_FOR));
        recovery.applied(Some("en0|gateway|address".into()));
        assert_eq!(recovery.status()["state"], "ready");
        assert!(!recovery.observe(Some("en0|gateway|address"), true, t + STABLE_FOR));
    }

    #[test]
    fn flapping_interface_restarts_the_stability_wait() {
        let t = Instant::now();
        let mut recovery = NetworkRecovery::default();
        recovery.applied(Some("en0".into()));
        assert!(!recovery.observe(Some("en16"), true, t));
        assert!(!recovery.observe(Some("en17"), true, t + Duration::from_secs(2)));
        assert!(!recovery.observe(Some("en17"), true, t + Duration::from_secs(4)));
        assert!(recovery.observe(Some("en17"), true, t + Duration::from_secs(5)));
    }

    #[test]
    fn path_loss_and_wake_force_recovery_without_address_changes() {
        let t = Instant::now();
        let mut recovery = NetworkRecovery::default();
        recovery.applied(Some("same".into()));
        recovery.changed(Some(false));
        assert!(!recovery.observe(Some("same"), true, t));
        assert_eq!(recovery.status()["state"], "waiting-network");
        recovery.changed(Some(true));
        assert!(!recovery.observe(Some("same"), true, t));
        assert!(recovery.observe(Some("same"), true, t + STABLE_FOR));
        recovery.applied(Some("same".into()));
        recovery.changed(None);
        assert!(!recovery.observe(Some("same"), true, t));
        assert!(recovery.observe(Some("same"), true, t + STABLE_FOR));
    }

    #[test]
    fn failures_back_off_and_stop_until_manual_retry_or_a_new_path() {
        let t = Instant::now();
        let mut recovery = NetworkRecovery::default();
        recovery.observe(Some("path"), true, t);
        let mut now = t + STABLE_FOR;
        for attempt in 1..=MAX_ATTEMPTS {
            assert!(recovery.observe(Some("path"), true, now));
            recovery.failed("fixture failure".into(), now);
            assert_eq!(recovery.status()["state"], "failed");
            assert!(!recovery.observe(Some("path"), true, now));
            now += Duration::from_secs(3 * u64::from(attempt));
        }
        assert!(!recovery.observe(Some("path"), true, now + Duration::from_secs(300)));
        recovery.changed(None);
        assert!(!recovery.observe(Some("path"), true, now));
        assert!(recovery.observe(Some("path"), true, now + STABLE_FOR));
        recovery.failed("fixture failure".into(), now + STABLE_FOR);
        assert!(!recovery.observe(Some("new-path"), true, now + STABLE_FOR));
        assert!(recovery.observe(Some("new-path"), true, now + STABLE_FOR * 2));
    }

    #[test]
    fn helper_update_blocks_background_retry_and_manual_stop_clears_intent() {
        let t = Instant::now();
        let mut recovery = NetworkRecovery::default();
        recovery.require_helper_update("请手动更新连接服务。");
        recovery.changed(Some(true));
        assert!(recovery.status()["helperUpdateRequired"].as_bool().unwrap());
        assert!(!recovery.observe(Some("path"), true, t + Duration::from_secs(300)));
        recovery.clear();
        assert_eq!(recovery.status()["state"], "idle");
        assert_eq!(recovery.status()["error"], Value::Null);
    }

    #[test]
    fn a_dead_engine_recovers_even_when_the_network_signature_is_unchanged() {
        let t = Instant::now();
        let mut recovery = NetworkRecovery::default();
        recovery.applied(Some("same".into()));
        assert!(!recovery.observe(Some("same"), false, t));
        assert!(recovery.observe(Some("same"), false, t + STABLE_FOR));
    }

    #[test]
    fn a_lost_online_callback_cannot_leave_a_healthy_path_offline_forever() {
        let mut recovery = NetworkRecovery::default();
        recovery.applied(Some("same".into()));
        recovery.changed(Some(false));
        let now = Instant::now();
        assert!(!recovery.observe(Some("same"), true, now));
        assert!(!recovery.needs_fast_check());
        let fallback = now + Duration::from_secs(31);
        assert!(!recovery.observe(Some("same"), true, fallback));
        assert!(recovery.needs_fast_check());
        assert!(recovery.observe(Some("same"), true, fallback + STABLE_FOR));
    }
}

#[cfg(test)]
mod visibility_tests {
    use super::*;

    #[test]
    fn history_survives_stop_and_rejects_late_checks() {
        let mut recovery = NetworkRecovery::default();
        recovery.changed(Some(true));
        recovery.applied(Some("path-a".into()));
        let old = recovery.take_check().unwrap();
        assert!(recovery.take_check().is_none());
        recovery.changed(Some(true));
        recovery.checked(old, true);
        assert_eq!(recovery.status()["history"][0]["outcome"], "interrupted");
        recovery.applied(Some("path-b".into()));
        let new = recovery.take_check().unwrap();
        recovery.clear();
        recovery.checked(new, true);
        assert_eq!(recovery.status()["state"], "idle");
        assert_eq!(recovery.status()["history"][0]["outcome"], "cancelled");
    }

    #[test]
    fn history_is_bounded_and_does_not_contain_network_identifiers() {
        let mut recovery = NetworkRecovery::default();
        for _ in 0..12 {
            recovery.changed_for(Some(true), "wake");
            recovery.applied(Some("private-network-identity".into()));
            let id = recovery.take_check().unwrap();
            recovery.checked(id, true);
        }
        let status = recovery.status();
        assert_eq!(status["history"].as_array().unwrap().len(), 10);
        assert_eq!(status["history"][0]["outcome"], "verified");
        assert_eq!(status["history"][0]["reason"], "wake");
        assert!(!status.to_string().contains("private-network-identity"));
    }

    #[test]
    fn terminal_failure_is_recorded_once_and_waiting_does_not_create_new_events() {
        let mut recovery = NetworkRecovery::default();
        let time = Instant::now();
        recovery.changed(Some(true));
        recovery.observe(Some("path"), true, time);
        for _ in 0..3 {
            recovery.failed("fixture failure".into(), time);
        }
        assert_eq!(recovery.status()["history"][0]["outcome"], "failed");
        assert!(!recovery.observe(Some("path"), true, time + Duration::from_secs(60)));
        assert!(recovery.active.is_none());
        assert!(recovery.take_check().is_none());
    }
}
