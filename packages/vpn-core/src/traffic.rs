//! Route ownership is interpreted once in the shared core.
use serde_json::Value;

pub fn route_kind(chains: &Value) -> &'static str {
    let names: Vec<_> = chains
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    if names.iter().any(|name| name.starts_with("COMPANY-")) {
        "company"
    } else if names
        .iter()
        .any(|name| matches!(*name, "VPN" | crate::static_exit::EXIT))
    {
        "proxy"
    } else if names.contains(&"DIRECT") {
        "direct"
    } else {
        "unknown"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn private_route_takes_precedence_and_missing_chains_remain_unknown() {
        assert_eq!(
            route_kind(&json!(["COMPANY-0123456789abcdef", "VPN"])),
            "company"
        );
        assert_eq!(route_kind(&json!(["fixture-node", "VPN"])), "proxy");
        assert_eq!(route_kind(&json!(["DIRECT"])), "direct");
        assert_eq!(route_kind(&Value::Null), "unknown");
        assert_eq!(route_kind(&json!(["UNKNOWN"])), "unknown");
    }
}
