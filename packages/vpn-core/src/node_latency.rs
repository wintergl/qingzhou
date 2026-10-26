//! Choose the newest comparable observation. A failed zero-delay sample is
//! never a measurement, and old evidence remains visible with a stale marker.
use chrono::{DateTime, Utc};
use serde_json::{Value, json};

fn date(value: &Value) -> Option<DateTime<Utc>> {
    value
        .as_str()
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.with_timezone(&Utc))
}
pub fn apply(node: &mut Value, live: Option<&Value>, cache: &[Value], now: DateTime<Utc>) {
    if node["identityAmbiguous"] == true {
        node["delay"] = Value::Null;
        node["available"] = Value::Null;
        node["latencyStatus"] = json!("ambiguous");
        node["latencyCheckedAt"] = Value::Null;
        return;
    }
    let history = live
        .and_then(|p| p["history"].as_array())
        .and_then(|h| h.last());
    let saved = cache
        .iter()
        .filter(|e| {
            e["identityKey"] == node["identityKey"]
                && e["providerRevision"] == node["providerRevision"]
        })
        .max_by_key(|e| date(&e["testedAt"]));
    let use_saved = saved
        .is_some_and(|saved| history.is_none_or(|h| date(&saved["testedAt"]) >= date(&h["time"])));
    let (stamp, delay, status, source, ttl, failure) = if use_saved {
        let saved = saved.unwrap();
        let delay = saved
            .get("medianDelayMs")
            .or_else(|| saved.get("medianMs"))
            .and_then(Value::as_u64)
            .filter(|d| *d > 0);
        let status = if delay.is_some() {
            if saved["status"] == "unstable" {
                "unstable"
            } else {
                "available"
            }
        } else if saved["status"] == "timeout" {
            "timeout"
        } else {
            "failed"
        };
        (
            &saved["testedAt"],
            delay,
            status,
            "manual",
            if saved["targetSetId"] == "default-latency" {
                600
            } else {
                1800
            },
            saved["failureReason"].clone(),
        )
    } else if let Some(history) = history {
        let delay = history["delay"].as_u64().filter(|d| *d > 0);
        (
            &history["time"],
            delay,
            if delay.is_some() {
                "available"
            } else {
                "failed"
            },
            "engine",
            600,
            Value::Null,
        )
    } else {
        node["delay"] = Value::Null;
        node["available"] = Value::Null;
        node["latencyStatus"] = json!(if node["identityAmbiguous"] == true {
            "ambiguous"
        } else {
            "untested"
        });
        node["latencyCheckedAt"] = Value::Null;
        return;
    };
    let stale = date(stamp).is_none_or(|at| now.signed_duration_since(at).num_seconds() > ttl);
    node["delay"] = json!(delay);
    node["available"] = if stale {
        Value::Null
    } else {
        json!(delay.is_some())
    };
    node["latencyStatus"] = json!(if node["identityAmbiguous"] == true {
        "ambiguous"
    } else if stale {
        "stale"
    } else {
        status
    });
    node["latencyCheckedAt"] = stamp.clone();
    node["latencySource"] = json!(source);
    node["latencyFailure"] = failure;
}

#[cfg(test)]
mod tests {
    use super::*;
    fn node() -> Value {
        json!({"identityKey":"fixture","providerRevision":"one"})
    }
    #[test]
    fn failure_zero_is_not_a_latency_and_newer_timeout_wins() {
        let now = Utc::now();
        let mut n = node();
        let live = json!({"history":[{"time":(now-chrono::Duration::seconds(30)).to_rfc3339(),"delay":0}]});
        let saved = json!({"identityKey":"fixture","providerRevision":"one","testedAt":now.to_rfc3339(),"status":"timeout","medianDelayMs":null});
        apply(&mut n, Some(&live), &[saved], now);
        assert!(n["delay"].is_null());
        assert_eq!(n["latencyStatus"], "timeout");
        assert_eq!(n["available"], false);
    }
    #[test]
    fn ambiguous_identity_does_not_borrow_another_nodes_live_measurement() {
        let now = Utc::now();
        let mut n = node();
        n["identityAmbiguous"] = json!(true);
        apply(
            &mut n,
            Some(&json!({"history":[{"time":now.to_rfc3339(),"delay":35}]})),
            &[],
            now,
        );
        assert_eq!(n["latencyStatus"], "ambiguous");
        assert!(n["delay"].is_null());
        assert!(n["available"].is_null());
    }
    #[test]
    fn stale_success_is_retained_but_not_reported_as_currently_available() {
        let now = Utc::now();
        let mut n = node();
        let live = json!({"history":[{"time":(now-chrono::Duration::minutes(12)).to_rfc3339(),"delay":50}]});
        apply(&mut n, Some(&live), &[], now);
        assert_eq!(n["delay"], 50);
        assert_eq!(n["latencyStatus"], "stale");
        assert!(n["available"].is_null());
        let changed_provider = json!({"identityKey":"fixture","providerRevision":"other","testedAt":now.to_rfc3339(),"medianDelayMs":10});
        apply(&mut n, None, &[changed_provider], now);
        assert_eq!(n["latencyStatus"], "untested");
    }
}
