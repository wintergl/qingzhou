//! Portable management uses the desktop rule/identity model. Platform shells
//! only collect input and own system credentials; no subscription parsing here.
use crate::{routing, static_exit, storage::Storage};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};

pub(super) fn handle(store: &Storage, channel: &str, p: &Value) -> Option<Result<Value>> {
    if !matches!(
        channel,
        "routing:normalize-rule"
            | "routing:diagnose"
            | "routing:add-rule"
            | "routing:edit-rule"
            | "routing:delete-rule"
            | "nodes:select"
            | "nodes:select-v2"
            | "native:favorite"
            | "node-groups:list"
            | "node-groups:save"
            | "static-exit:parse"
            | "static-exit:configure"
            | "static-exit:set-enabled"
    ) {
        return None;
    }
    Some((|| {
        match channel {
            "routing:normalize-rule" => routing::normalize_input(p),
            "routing:diagnose" => {
                routing::diagnose(&store.settings()?, super::string(p, "target")?)
            }
            "routing:add-rule" | "routing:edit-rule" | "routing:delete-rule" => {
                let patch = routing::edit_patch(&store.settings()?, p, channel)?;
                super::handle(store, "settings:patch", &patch)
            }
            "nodes:select" | "nodes:select-v2" => {
                let settings = store.settings()?;
                let node = if channel == "nodes:select-v2" {
                    let key = super::string(p, "identityKey")?;
                    let nodes = super::nodes(store)?;
                    let found = nodes
                        .iter()
                        .filter(|n| n["identityKey"] == key)
                        .collect::<Vec<_>>();
                    ensure!(
                        found.len() == 1 && found[0]["identityAmbiguous"] != true,
                        "节点已失效或存在同名冲突，请刷新后重试。"
                    );
                    found[0].clone()
                } else {
                    let name = super::string(p, "nodeName")?;
                    ensure!(
                        ["AUTO", "BALANCE", "DIRECT"].contains(&name),
                        "请选择带身份标识的具体节点。"
                    );
                    json!({"name":name})
                };
                ensure!(
                    node["name"] != "DIRECT" || settings["staticExit"]["enabled"] != true,
                    "请先关闭静态 ISP，再切换为直连。"
                );
                let outlet = if node["identityKey"].is_string() {
                    json!({"kind":"node","name":node["name"],"identityKey":node["identityKey"],"subscriptionId":node["subscriptionId"]})
                } else {
                    json!({"kind":"builtin","name":node["name"]})
                };
                super::handle(
                    store,
                    "settings:patch",
                    &json!({"selectedProxy":node["name"],"defaultOutlet":outlet}),
                )
            }
            "native:favorite" => {
                let settings = store.settings()?;
                let name = super::string(p, "name")?;
                let mut favorites = settings["favoriteNodeNames"].as_array().unwrap().clone();
                if favorites.contains(&json!(name)) {
                    favorites.retain(|v| v != name);
                } else {
                    favorites.push(json!(name));
                }
                super::handle(
                    store,
                    "settings:patch",
                    &json!({"favoriteNodeNames":favorites}),
                )
            }
            "node-groups:list" => Ok(store.settings()?["nodeGroups"].clone()),
            "node-groups:save" => {
                let groups = p["nodeGroups"].as_array().context("节点组格式无效。")?;
                let mut ids = std::collections::HashSet::new();
                for group in groups {
                    ensure!(
                        ids.insert(super::string(group, "id")?)
                            && !super::string(group, "name")?.trim().is_empty(),
                        "节点组标识或名称无效。"
                    );
                    ensure!(
                        group["nodeNames"]
                            .as_array()
                            .is_some_and(|a| a.iter().all(Value::is_string)),
                        "节点组成员格式无效。"
                    );
                }
                super::handle(store, "settings:patch", &json!({"nodeGroups":groups}))
            }
            "static-exit:parse" => static_exit::parse_line(super::string(p, "line")?),
            "static-exit:configure" => {
                static_exit::validate(&p["configuration"])?;
                // Passwords are supplied again from the OS vault at generation.
                // Only non-secret configuration belongs in shared settings.
                super::handle(
                    store,
                    "settings:patch",
                    &json!({"staticExit":p["configuration"]}),
                )
            }
            "static-exit:set-enabled" => {
                let enabled = p["enabled"].as_bool().context("请选择是否启用 ISP。")?;
                let mut exit = store.settings()?["staticExit"].clone();
                exit["enabled"] = json!(enabled);
                static_exit::validate(&exit)?;
                super::handle(store, "settings:patch", &json!({"staticExit":exit}))
            }
            _ => unreachable!(),
        }
    })())
}
