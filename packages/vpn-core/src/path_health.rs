//! Application-path failures do not imply a dead engine. Confirm a failure,
//! permit one configuration repair, then cool down instead of restart loops.
use serde_json::{Value, json};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum PathOutcome {
    Healthy,
    DnsFailure,
    EgressFailure,
    Skipped,
}
#[derive(PartialEq, Eq, Debug)]
pub enum PathAction {
    None,
    Recheck,
    Recover,
}
#[derive(Default)]
pub struct PathHealth {
    failures: u32,
    kind: Option<&'static str>,
    repaired_at: Option<Instant>,
    healthy_since: Option<Instant>,
}
impl PathHealth {
    pub fn invalidate(&mut self) {
        self.failures = 0;
        self.kind = None;
        self.healthy_since = None;
    }
    pub fn status(&self) -> Value {
        json!({"state": if self.failures == 0 { if self.kind == Some("healthy") { "healthy" } else { "unknown" } }
            else if self.failures < 3 { "checking" } else { "degraded" },
            "failureKind":self.kind.filter(|kind| *kind != "healthy"),"consecutiveFailures":self.failures})
    }
    pub fn observe(&mut self, outcome: PathOutcome, now: Instant) -> PathAction {
        match outcome {
            PathOutcome::Skipped => return PathAction::None,
            PathOutcome::Healthy => {
                self.failures = 0;
                self.kind = Some("healthy");
                let since = *self.healthy_since.get_or_insert(now);
                if now.saturating_duration_since(since) >= Duration::from_secs(60) {
                    self.repaired_at = None;
                }
                return PathAction::None;
            }
            PathOutcome::DnsFailure => self.kind = Some("dns"),
            PathOutcome::EgressFailure => self.kind = Some("egress"),
        }
        self.healthy_since = None;
        self.failures = self.failures.saturating_add(1);
        if self.failures < 3 {
            return PathAction::Recheck;
        }
        if self
            .repaired_at
            .is_none_or(|t| now.saturating_duration_since(t) >= Duration::from_secs(300))
        {
            self.repaired_at = Some(now);
            return PathAction::Recover;
        }
        PathAction::None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn intermittent_success_does_not_reset_repair_budget() {
        let t = Instant::now();
        let mut health = PathHealth::default();
        assert_eq!(
            health.observe(PathOutcome::DnsFailure, t),
            PathAction::Recheck
        );
        assert_eq!(
            health.observe(PathOutcome::EgressFailure, t),
            PathAction::Recheck
        );
        assert_eq!(
            health.observe(PathOutcome::DnsFailure, t),
            PathAction::Recover
        );
        health.observe(PathOutcome::Healthy, t);
        for i in 1..=3 {
            assert_ne!(
                health.observe(PathOutcome::EgressFailure, t + Duration::from_secs(i)),
                PathAction::Recover
            );
        }
        assert_eq!(
            health.observe(PathOutcome::EgressFailure, t + Duration::from_secs(301)),
            PathAction::Recover
        );
    }
    #[test]
    fn skipped_probe_is_not_success_and_stable_success_restores_budget() {
        let t = Instant::now();
        let mut health = PathHealth::default();
        health.observe(PathOutcome::DnsFailure, t);
        health.observe(PathOutcome::Skipped, t);
        assert_eq!(health.status()["consecutiveFailures"], 1);
        health.observe(PathOutcome::Healthy, t);
        health.observe(PathOutcome::Healthy, t + Duration::from_secs(60));
        assert!(health.repaired_at.is_none());
    }
}
