#!/usr/bin/env python3
"""Verify operational RPC and data preservation against isolated fixture data."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

project = Path(__file__).resolve().parents[1]
resources = Path(os.environ.get("SPLITVPN_APP_BUNDLE", str(project / "dist/轻舟.app"))) / "Contents/Resources"
fixture = Path(tempfile.mkdtemp(prefix="splitvpn-preview-rpc-", dir=project / ".local"))
try:
    # Large enough to exceed a stdout pipe buffer and catch truncated replies
    # when stdin reaches EOF while bootstrap is still being assembled.
    settings = {
        "settingsVersion": 10, "launchAtLogin": False, "unknownTraffic": "direct",
        "tun": False, "ipv6": True, "lanDirect": False, "tailscaleDirect": False,
        "selectedProxy": "DIRECT", "favoriteNodeNames": ["kept"], "nodeGroups": [],
        "vpnDomainRules": [f"DOMAIN-SUFFIX,fixture-{index}.example.com" for index in range(5000)],
    }
    source = json.dumps(settings)
    (fixture / "settings.json").write_text(source)
    env = os.environ.copy()
    env.update(SPLITVPN_DATA_DIR=str(fixture), SPLITVPN_RESOURCES=str(resources), SPLITVPN_ISOLATED="1")
    requests = [
        {"id": "read", "channel": "native:bootstrap"},
        {"id": "favorite", "channel": "native:favorite", "payload": {"name": "new"}},
        {"id": "subscription", "channel": "subscription:configure-update", "payload": {"id": "fixture", "intervalMinutes": 60}},
        {"id": "group-connect", "channel": "native:group-connect", "payload": {"groupId": "fixture"}},
        {"id": "legacy-group", "channel": "node-groups:select", "payload": {"groupId": "fixture"}},
        {"id": "automatic-outlet", "channel": "nodes:select", "payload": {"nodeName": "AUTO"}},
    ]
    process = subprocess.run(
        [os.environ.get("SPLITVPN_CORE_BINARY", str(resources / "splitvpn-core"))],
        input="".join(json.dumps(request) + "\n" for request in requests),
        text=True, capture_output=True, env=env, timeout=20,
    )
    replies = {}
    for line in process.stdout.splitlines():
        reply = json.loads(line)
        if "id" in reply:
            replies[reply["id"]] = reply
    assert process.returncode == 0, "native service failed"
    assert replies["read"]["ok"] and not replies["read"]["data"]["previewOnly"], "operational backend missing"
    assert len(replies["read"]["data"]["status"]["settings"]["vpnDomainRules"]) == 5000, "large reply truncated"
    assert replies["favorite"]["ok"] and not replies["subscription"]["ok"], "valid favorite or invalid subscription result wrong"
    assert not replies["group-connect"]["ok"] and not replies["legacy-group"]["ok"] and not replies["automatic-outlet"]["ok"], "group connections are still exposed"
    retained = json.loads((fixture / "settings.json").read_text())
    assert retained["favoriteNodeNames"] == ["kept", "new"], "favorite was not saved"
    for key in ("tun", "ipv6", "lanDirect", "tailscaleDirect", "vpnDomainRules"):
        assert retained[key] == settings[key], f"retained {key} changed"
    assert not (fixture / "mihomo/config.yaml").exists(), "network config generated"
    print("原生管道验证通过：完整的大数据回复、收藏保存、偏好和规则保留、拒绝无效订阅及分组连接。")
finally:
    shutil.rmtree(fixture)
