//! Immutable observations, separate from the replaceable recommendation cache.
use super::*;

const DIRECTORY: &str = "isp-tests/history";
pub(super) fn append(
    store: &Storage,
    scan: &str,
    key: &Value,
    row: &Value,
    legacy: bool,
) -> Result<()> {
    let time = row["testedAt"]
        .as_str()
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|t| t.timestamp_micros())
        .unwrap_or(0)
        .max(0);
    // Deterministic legacy IDs make interrupted migrations safe to repeat.
    let suffix = if legacy {
        crate::storage::sha256(&serde_json::to_vec(&json!([scan, key, row]))?)
    } else {
        uuid::Uuid::new_v4().simple().to_string()
    };
    let id = format!("{time:020}-{suffix}");
    let path = format!("{DIRECTORY}/{id}.json");
    if legacy && store.path(&path).exists() {
        return Ok(());
    }
    let ranked = crate::chain_scan::ranked(&json!({"results":[row]}), "balanced")?;
    store.write(
        &path,
        &json!({"recordId":id,"scanId":scan,"environmentKey":key,"observation":ranked["results"][0],"scorePolicy":ranked["scorePolicy"]}),
    )
}
pub(super) fn migrate(store: &Storage, state: &Value, key: &Value) -> Result<()> {
    if store.path("isp-tests/legacy-migrated.json").exists() {
        return Ok(());
    }
    if let Some(rows) = state["results"].as_array() {
        for row in rows {
            append(store, state["id"].as_str().unwrap_or(""), key, row, true)?;
        }
    }
    store.write("isp-tests/legacy-migrated.json", &json!({"completed":true}))
}
pub(super) fn page(store: &Storage, payload: &Value, key: &Value) -> Result<Value> {
    allowed_keys(payload, &["before", "limit"])?;
    let before = payload
        .get("before")
        .map(|v| v.as_str().context("历史记录游标无效。"))
        .transpose()?;
    if let Some(before) = before {
        ensure!(
            before.len() <= 100
                && !before.is_empty()
                && before
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-'),
            "历史记录游标无效。"
        );
    }
    let limit = payload
        .get("limit")
        .map(|v| v.as_u64().context("历史记录数量无效。"))
        .transpose()?
        .unwrap_or(50);
    ensure!((1..=200).contains(&limit), "每次可读取 1～200 条历史记录。");
    let mut ids = Vec::new();
    match fs::read_dir(store.path(DIRECTORY)) {
        Ok(entries) => {
            for entry in entries {
                let entry = entry?;
                let name = entry.file_name().to_string_lossy().into_owned();
                if let Some(id) = name.strip_suffix(".json") {
                    if before.is_none_or(|before| id < before) {
                        ids.push(id.to_owned());
                    }
                }
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.into()),
    }
    ids.sort_unstable_by(|a, b| b.cmp(a));
    let has_more = ids.len() > limit as usize;
    ids.truncate(limit as usize);
    let mut records = Vec::new();
    for id in &ids {
        let mut record = store.read(&format!("{DIRECTORY}/{id}.json"), Value::Null)?;
        record["environmentKnown"] = json!(!key.is_null());
        record["sameEnvironment"] = json!(!key.is_null() && record["environmentKey"] == *key);
        // Preserve the recorded score and policy, only annotate its present age.
        record["observation"]["requiresRefresh"] = json!(!crate::chain_scan::fresh(
            &record["observation"],
            chrono::Utc::now()
        ));
        records.push(record);
    }
    Ok(
        json!({"records":records,"nextBefore":if has_more { ids.last().cloned() } else { None },"hasMore":has_more}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reading_history_preserves_recorded_scores_and_never_rewrites_evidence() {
        let root = tempfile::tempdir().unwrap();
        let store = Storage::new(root.path().to_owned());
        let key = json!({"environment":"test"});
        let row = json!({"identityKey":"one","status":"available","latencyMs":100,"jitterMs":10,"downloadMbps":20,"testedAt":"2000-01-01T00:00:00Z"});
        append(&store, "scan", &key, &row, false).unwrap();
        let record = page(&store, &json!({}), &key).unwrap()["records"][0].clone();
        assert!(record["scorePolicy"]["version"].is_number());
        let id = record["recordId"].as_str().unwrap();
        let relative = format!("{DIRECTORY}/{id}.json");
        let mut recorded = store.read(&relative, Value::Null).unwrap();
        recorded["observation"]["balancedScore"] = json!(12.34);
        recorded["scorePolicy"]["version"] = json!(0);
        store.write(&relative, &recorded).unwrap();
        let bytes = fs::read(store.path(&relative)).unwrap();
        let history = page(&store, &json!({}), &json!({"environment":"other"})).unwrap();
        assert_eq!(history["records"][0]["observation"]["balancedScore"], 12.34);
        assert_eq!(
            history["records"][0]["observation"]["requiresRefresh"],
            true
        );
        assert_eq!(history["records"][0]["sameEnvironment"], false);
        assert_eq!(fs::read(store.path(&relative)).unwrap(), bytes);
        assert!(page(&store, &json!({"before":"../other"}), &key).is_err());
        assert!(page(&store, &json!({"limit":201}), &key).is_err());
    }
}
