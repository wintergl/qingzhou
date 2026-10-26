//! Desktop checks share one schedule across windows and native clients.
//! Results are memory-only; credentials and URLs never enter schedule metadata.
use serde_json::{Value, json};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum CheckKind {
    Connectivity,
    Websites,
}
impl CheckKind {
    pub fn key(self) -> &'static str {
        match self {
            Self::Connectivity => "connectivity",
            Self::Websites => "websites",
        }
    }
    pub fn interval(self, low_power: bool) -> Duration {
        Duration::from_secs(match (self, low_power) {
            (Self::Connectivity, false) => 300,
            (Self::Connectivity, true) => 900,
            (Self::Websites, false) => 900,
            (Self::Websites, true) => 1800,
        })
    }
}
#[derive(Default)]
struct Record {
    run: Option<u64>,
    next: Option<Instant>,
    next_at: Option<String>,
    started_at: Option<String>,
    checked_at: Option<String>,
    source: Option<&'static str>,
    result: Option<Value>,
    error: Option<String>,
    stale: bool,
}
pub struct Diagnostics {
    records: [Record; 2],
    sequence: u64,
    paused: Option<&'static str>,
    low_power: bool,
}
impl Default for Diagnostics {
    fn default() -> Self {
        Self {
            records: Default::default(),
            sequence: 0,
            paused: Some("disconnected"),
            low_power: false,
        }
    }
}
fn index(kind: CheckKind) -> usize {
    if kind == CheckKind::Connectivity {
        0
    } else {
        1
    }
}
fn wall_after(delay: Duration) -> String {
    (chrono::Utc::now() + chrono::Duration::seconds(delay.as_secs() as i64))
        .to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}
impl Diagnostics {
    pub fn invalidate(&mut self) {
        for record in &mut self.records {
            record.run = None;
            record.next = None;
            record.next_at = None;
            record.stale = record.checked_at.is_some();
        }
    }
    pub fn environment(&mut self, paused: Option<&'static str>, low_power: bool, now: Instant) {
        let changed_power = self.low_power != low_power;
        self.paused = paused;
        self.low_power = low_power;
        if paused.is_some() {
            return;
        }
        for kind in [CheckKind::Connectivity, CheckKind::Websites] {
            let record = &mut self.records[index(kind)];
            if record.next.is_none() || changed_power {
                let delay = if record.checked_at.is_none() || record.stale {
                    Duration::from_secs(15)
                } else {
                    kind.interval(low_power)
                };
                record.next = Some(now + delay);
                record.next_at = Some(wall_after(delay));
            }
        }
    }
    pub fn due(&self, now: Instant) -> Option<CheckKind> {
        if self.paused.is_some() {
            return None;
        }
        [CheckKind::Connectivity, CheckKind::Websites]
            .into_iter()
            .find(|kind| {
                let record = &self.records[index(*kind)];
                record.run.is_none() && record.next.is_some_and(|deadline| now >= deadline)
            })
    }
    pub fn claim(&mut self, kind: CheckKind, manual: bool) -> Result<u64, &'static str> {
        let record = &mut self.records[index(kind)];
        if record.run.is_some() {
            return Err("此项检测正在进行，请等待当前结果。");
        }
        if !manual && self.paused.is_some() {
            return Err("自动检测已暂停。");
        }
        self.sequence = self.sequence.wrapping_add(1);
        record.run = Some(self.sequence);
        record.started_at = Some(wall_after(Duration::ZERO));
        record.source = Some(if manual { "manual" } else { "automatic" });
        record.error = None;
        Ok(self.sequence)
    }
    pub fn finish(
        &mut self,
        kind: CheckKind,
        id: u64,
        result: Result<Value, String>,
        now: Instant,
    ) -> bool {
        let record = &mut self.records[index(kind)];
        if record.run != Some(id) {
            return false;
        }
        record.run = None;
        record.checked_at = Some(wall_after(Duration::ZERO));
        record.stale = false;
        match result {
            Ok(value) => {
                record.result = Some(value);
                record.error = None;
            }
            Err(error) => {
                record.result = None;
                record.error = Some(error);
            }
        }
        let delay = kind.interval(self.low_power);
        record.next = Some(now + delay);
        record.next_at = Some(wall_after(delay));
        true
    }
    pub fn status(&self) -> Value {
        let mut value = json!({"automatic":true,"pausedReason":self.paused});
        for kind in [CheckKind::Connectivity, CheckKind::Websites] {
            let record = &self.records[index(kind)];
            let state = if record.run.is_some() {
                "running"
            } else if record.stale {
                "stale"
            } else if record.error.is_some() {
                "error"
            } else if record.checked_at.is_some() {
                "ready"
            } else {
                "idle"
            };
            value[kind.key()] = json!({"state":state,"checkedAt":record.checked_at,"startedAt":record.started_at,
                "nextCheckAt":if self.paused.is_none() { record.next_at.as_ref() } else { None },
                "source":record.source,"result":record.result,"error":record.error,"intervalSeconds":kind.interval(self.low_power).as_secs()});
        }
        value
    }
}

pub fn failure_kind(error: &anyhow::Error) -> &'static str {
    if error.chain().any(|cause| {
        cause
            .downcast_ref::<reqwest::Error>()
            .is_some_and(|e| e.is_timeout())
    }) || error.to_string().to_lowercase().contains("timeout")
        || error.to_string().contains("超时")
    {
        "timeout"
    } else {
        "transport-error"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn schedule_waits_for_stability_then_runs_two_checks_without_overlap() {
        let now = Instant::now();
        let mut checks = Diagnostics::default();
        assert!(checks.due(now + Duration::from_secs(600)).is_none());
        checks.environment(None, false, now);
        assert!(checks.due(now + Duration::from_secs(14)).is_none());
        assert_eq!(
            checks.due(now + Duration::from_secs(15)),
            Some(CheckKind::Connectivity)
        );
        let id = checks.claim(CheckKind::Connectivity, false).unwrap();
        assert!(checks.claim(CheckKind::Connectivity, true).is_err());
        checks.finish(CheckKind::Connectivity, id, Ok(json!({"ok":true})), now);
        assert_eq!(
            checks.due(now + Duration::from_secs(15)),
            Some(CheckKind::Websites)
        );
        assert!(checks.status()["connectivity"]["checkedAt"].is_string());
    }
    #[test]
    fn power_sleep_and_connection_changes_preserve_history_but_reject_old_results() {
        let now = Instant::now();
        let mut checks = Diagnostics::default();
        checks.environment(None, false, now);
        let id = checks.claim(CheckKind::Websites, true).unwrap();
        checks.finish(CheckKind::Websites, id, Ok(json!({"results":[]})), now);
        checks.environment(Some("sleeping"), true, now);
        assert!(checks.due(now + Duration::from_secs(5000)).is_none());
        assert!(checks.status()["websites"]["nextCheckAt"].is_null());
        checks.invalidate();
        assert_eq!(checks.status()["websites"]["state"], "stale");
        assert!(!checks.finish(CheckKind::Websites, id, Ok(json!({"old":true})), now));
        checks.environment(None, true, now);
        assert_eq!(checks.status()["websites"]["intervalSeconds"], 1800);
    }
}
