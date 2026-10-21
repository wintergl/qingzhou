//! Conservative, in-memory detection. Connection identifiers never enter logs.
use serde_json::Value;
use std::{
    collections::HashMap,
    time::{Duration, Instant},
};

#[derive(Default)]
pub struct ConnectionHealth {
    entries: HashMap<String, Entry>,
    actions: Vec<Instant>,
    last_sample: Option<Instant>,
}
struct Entry {
    upload: u64,
    download: u64,
    pending: Option<Instant>,
    quiet_since: Instant,
    observations: u32,
}

pub fn is_wechat(c: &Value) -> bool {
    let chains = c["chains"].as_array();
    if chains.is_some_and(|xs| {
        xs.iter()
            .any(|v| v.as_str().is_some_and(|s| s.starts_with("COMPANY-")))
    }) {
        return false;
    }
    chains.is_some_and(|xs| xs.iter().any(|v| v == "WECHAT"))
        || matches!(
            c["metadata"]["process"].as_str(),
            Some("WeChat" | "WeChatAppEx" | "WeChatAppEx Helper" | "WeChatHelper")
        )
}

impl ConnectionHealth {
    /// New sockets with unanswered data, or new outgoing activity across samples,
    /// arm the detector. The first snapshot is only a baseline.
    /// A response, counter reset, vanished socket or missing sample disarms it.
    /// Two minutes without a response AND 30 seconds without byte movement is
    /// suspicion, not proof. At most one targeted retry per 2 min, three per 10 min.
    pub fn observe(&mut self, snapshot: &Value, now: Instant) -> Option<String> {
        let Some(connections) = snapshot["connections"].as_array() else {
            self.entries.clear();
            self.last_sample = None;
            return None;
        };
        if self
            .last_sample
            .is_some_and(|t| now.duration_since(t) > Duration::from_secs(75))
        {
            self.entries.clear();
            self.last_sample = None;
        }
        let has_baseline = self.last_sample.is_some();
        self.last_sample = Some(now);
        let mut next = HashMap::new();
        let mut candidate = None;
        for c in connections.iter().filter(|c| is_wechat(c)).take(1024) {
            let (Some(id), Some(upload), Some(download)) = (
                c["id"].as_str(),
                c["upload"].as_u64(),
                c["download"].as_u64(),
            ) else {
                continue;
            };
            let mut e = self.entries.remove(id).unwrap_or(Entry {
                upload,
                download,
                pending: (has_baseline && upload > 0 && download == 0).then_some(now),
                quiet_since: now,
                observations: 0,
            });
            if download != e.download || upload < e.upload {
                e.pending = None;
                e.observations = 0;
            } else if upload > e.upload && e.pending.is_none() {
                e.pending = Some(now);
                e.observations = 0;
            }
            if upload != e.upload || download != e.download {
                e.quiet_since = now;
            }
            e.upload = upload;
            e.download = download;
            e.observations = e.observations.saturating_add(1);
            if e.pending
                .is_some_and(|t| now.duration_since(t) >= Duration::from_secs(120))
                && now.duration_since(e.quiet_since) >= Duration::from_secs(30)
                && e.observations >= 3
                && candidate.is_none()
            {
                candidate = Some(id.to_owned());
            }
            next.insert(id.to_owned(), e);
        }
        self.entries = next;
        self.actions
            .retain(|t| now.duration_since(*t) < Duration::from_secs(600));
        if self.actions.len() >= 3
            || self
                .actions
                .last()
                .is_some_and(|t| now.duration_since(*t) < Duration::from_secs(120))
        {
            return None;
        }
        if let Some(id) = &candidate {
            self.actions.push(now); // Failed close attempts are rate limited too.
            self.entries.remove(id);
        }
        candidate
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn sample(upload: u64, download: u64) -> Value {
        json!({"connections":[{"id":"fixture","upload":upload,"download":download,"chains":["WECHAT","VPN"]}]})
    }
    #[test]
    fn idle_and_long_active_uploads_are_not_closed() {
        let t = Instant::now();
        let mut h = ConnectionHealth::default();
        for n in 0..20 {
            assert!(
                h.observe(&sample(100, 0), t + Duration::from_secs(n * 30))
                    .is_none()
            );
        }
        for n in 20..40 {
            assert!(
                h.observe(&sample(n * 100, 0), t + Duration::from_secs(n * 30))
                    .is_none()
            );
        }
    }
    #[test]
    fn stalled_new_upload_retries_once_and_response_clears_suspicion() {
        let t = Instant::now();
        let mut h = ConnectionHealth::default();
        h.observe(&sample(0, 0), t);
        for n in 1..5 {
            assert!(
                h.observe(&sample(100, 0), t + Duration::from_secs(n * 30))
                    .is_none()
            );
        }
        assert_eq!(
            h.observe(&sample(100, 0), t + Duration::from_secs(150)),
            Some("fixture".into())
        );
        assert!(
            h.observe(&sample(100, 0), t + Duration::from_secs(180))
                .is_none()
        );
        h.observe(&sample(200, 0), t + Duration::from_secs(210));
        h.observe(&sample(200, 1), t + Duration::from_secs(240));
        assert!(
            h.observe(&sample(200, 1), t + Duration::from_secs(500))
                .is_none()
        );
    }
    #[test]
    fn newly_seen_stalled_socket_is_detected_and_retries_are_bounded() {
        let t = Instant::now();
        let mut h = ConnectionHealth::default();
        h.observe(&serde_json::json!({"connections":[]}), t);
        let mut retries = 0;
        for n in 1..20 {
            if h.observe(&sample(100, 0), t + Duration::from_secs(n * 30))
                .is_some()
            {
                retries += 1;
            }
        }
        assert_eq!(retries, 3);
    }

    #[test]
    fn gaps_resets_disappearance_and_unknown_processes_disarm_suspicion() {
        let t = Instant::now();
        for replacement in [
            Value::Null,
            serde_json::json!({"connections":[]}),
            sample(0, 0),
        ] {
            let mut h = ConnectionHealth::default();
            h.observe(&sample(0, 0), t);
            h.observe(&sample(100, 0), t + Duration::from_secs(30));
            h.observe(&replacement, t + Duration::from_secs(60));
            assert!(
                h.observe(&sample(0, 0), t + Duration::from_secs(90))
                    .is_none()
            );
        }
        let mut h = ConnectionHealth::default();
        h.observe(&sample(0, 0), t);
        h.observe(&sample(100, 0), t + Duration::from_secs(30));
        assert!(
            h.observe(&sample(100, 0), t + Duration::from_secs(200))
                .is_none()
        );
        assert!(!is_wechat(
            &serde_json::json!({"metadata":{"process":"unknown"},"chains":["VPN"]})
        ));
    }

    #[test]
    fn company_connections_and_missing_samples_are_never_actionable() {
        let mut c = sample(0, 0);
        c["connections"][0]["chains"] = json!(["COMPANY-fixture", "WECHAT"]);
        assert!(!is_wechat(&c["connections"][0]));
        let t = Instant::now();
        let mut h = ConnectionHealth::default();
        h.observe(&sample(0, 0), t);
        h.observe(&sample(100, 0), t + Duration::from_secs(30));
        h.observe(&Value::Null, t + Duration::from_secs(60));
        assert!(
            h.observe(&sample(100, 0), t + Duration::from_secs(200))
                .is_none()
        );
    }
}
