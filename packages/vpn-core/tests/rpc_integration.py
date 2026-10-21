#!/usr/bin/env python3
"""Exercise the actual Rust JSON-lines process using only loopback fixtures."""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import tempfile
import threading
import time
import unittest
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[3]
BINARY = Path(os.environ.get("SPLITVPN_CORE_BINARY", ROOT / "packages/vpn-core/target/debug/splitvpn-core"))


class Controller(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def respond(self, value=None, status=200):
        body = json.dumps(value).encode() if status != 204 else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        state = self.server.state
        path = urlsplit(self.path).path
        state["requests"].append(("GET", path))
        if path == state.get("blocked_path"):
            state["download_entered"].set()
            state["download_release"].wait(10)
        if path == "/version":
            self.respond({"version": "fixture"})
        elif path == "/configs":
            current = state.get("reloads", [])[-1] if state.get("reloads") else ""
            interface = re.search(r"^interface-name: (.+)$", current, re.M)
            tun = None if state.get("unconfirmed_company_tun") and state["company"] else False
            self.respond({"interface-name": interface.group(1) if interface else "", "tun": {"enable": tun}})
        elif path == "/proxies":
            proxies = {n: {"type": "Http", "udp": False, "history": []} for n in ["node-a", "node-b", *state["company"]]}
            proxies["VPN"] = {"type": "Selector", "now": state["selected"], "all": ["DIRECT", "node-a", "node-b"]}
            self.respond({"proxies": proxies})
        elif path.startswith("/proxies/") and path.endswith("/delay"):
            self.respond({"delay": 27})
        elif path.startswith("/proxies/"):
            name = path.split("/")[-1]
            if state["proxy_failure"]:
                self.respond({}, 503)
            elif name in ["VPN", "PROBE", "node-a", "node-b", *state["company"]]:
                self.respond({"name": name})
            else:
                self.respond({}, 404)
        elif path == "/connections":
            self.respond({"uploadTotal": 1, "downloadTotal": 2, "connections": [{"id": "kept-company-connection", "metadata": {"network": "tcp", "host": "fixture.invalid"}, "chains": ["DIRECT"], "upload": 1, "download": 2}]})
        elif path == "/subscription":
            if state.get("subscription_content") is not None:
                body = state["subscription_content"].encode()
                self.send_response(state["subscription_status"])
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.respond({"proxies": [{"name": n, "type": "http", "server": "127.0.0.1", "port": 9, "udp": False} for n in ["node-a", "node-b"]]}, state["subscription_status"])
        elif path == "/health":
            self.respond({"ok": True})
        elif path == "/chatgpt":
            self.respond({"ok": True}, state["chatgpt_status"])
        else:
            if state["risk_error"]:
                self.respond({"error": "fixture"}, 401)
            else:
                self.respond({"ip": "203.0.113.9", "threat": {"is_proxy": False}, "scores": {"trust_score": 99}})

    def do_PUT(self):
        state = self.server.state
        path = urlsplit(self.path).path
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        state["requests"].append(("PUT", path))
        if path == "/configs":
            state["reloads"].append(body["payload"])
            if state["reload_failure"]:
                state["reload_failure"] = False
                self.respond({}, 500)
                return
            state["company"] = re.findall(r"name: (COMPANY-[a-f0-9]+)", body["payload"])
            # No isolated reload may turn either system service on.
            assert "tun:\n  enable: false" in body["payload"]
            assert "dns:\n  enable: false" in body["payload"]
            self.respond(status=204)
        elif path == "/proxies/VPN":
            state["selected"] = body["name"]
            state["selections"].append(body["name"])
            self.respond(status=204)
        elif path == "/proxies/PROBE":
            state["probes"].append(body["name"])
            self.respond(status=204)
        else:
            self.respond({}, 404)

    def do_DELETE(self):
        self.server.state["requests"].append(("DELETE", urlsplit(self.path).path))
        self.respond(status=204)


class RPC:
    def __init__(self, data, resources, port=None, overrides=None):
        env = dict(os.environ, SPLITVPN_ISOLATED="1", SPLITVPN_DATA_DIR=str(data), SPLITVPN_RESOURCES=str(resources))
        for key in ["SPLITVPN_TEST_CONTROLLER_PORT", "SPLITVPN_TEST_MIXED_PORT", "SPLITVPN_TEST_IPDATA_URL", "SPLITVPN_TEST_CONNECTIVITY_URL", "SPLITVPN_TEST_CHATGPT_URL", "SPLITVPN_TEST_SYSTEM_DNS_ADDRESSES", "SPLITVPN_TEST_VPN_DNS_ADDRESSES"]:
            env.pop(key, None)
        if port:
            env.update(SPLITVPN_TEST_CONTROLLER_PORT=str(port), SPLITVPN_TEST_MIXED_PORT=str(port), SPLITVPN_TEST_IPDATA_URL=f"http://127.0.0.1:{port}/")
            env.update(SPLITVPN_TEST_CONNECTIVITY_URL=f"http://127.0.0.1:{port}/health", SPLITVPN_TEST_CHATGPT_URL=f"http://127.0.0.1:{port}/chatgpt",
                       SPLITVPN_TEST_SYSTEM_DNS_ADDRESSES="198.18.0.65", SPLITVPN_TEST_VPN_DNS_ADDRESSES="198.18.0.65")
        env.update(overrides or {})
        self.process = subprocess.Popen([str(BINARY)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.lines = queue.Queue()
        self.events = []
        self.counter = 0
        def read():
            for line in self.process.stdout:
                self.lines.put(json.loads(line))
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def request(self, channel, payload=None, ok=True):
        self.counter += 1
        identity = str(self.counter)
        self.process.stdin.write(json.dumps({"id": identity, "channel": channel, "payload": payload or {}}) + "\n")
        self.process.stdin.flush()
        while True:
            reply = self.lines.get(timeout=15)
            if reply.get("id") == identity:
                assert reply["ok"] == ok, reply
                return reply["data"] if ok else reply["error"]
            self.events.append(reply)

    def event(self, finished):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            for index, reply in enumerate(self.events):
                if reply.get("event") == "nodes:risk-progress" and reply["data"]["finished"] == finished:
                    return self.events.pop(index)["data"]
            self.events.append(self.lines.get(timeout=10))
        raise AssertionError("progress missing")

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=15)
            assert self.process.returncode == 0, self.process.stderr.read()
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.process.stdout.close()
            self.process.stderr.close()


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="splitvpn-rust-rpc-")
        self.data = Path(self.temp.name) / "data"
        self.resources = Path(self.temp.name) / "resources"
        self.resources.mkdir()
        validator = self.resources / "mihomo"
        validator.write_text("#!/usr/bin/env python3\nimport pathlib,sys\np=pathlib.Path(sys.argv[sys.argv.index('-f')+1])\ns=p.read_text()\nr=p.parent/'providers/vpn-domains.yaml'\nif 'force.invalid' in s or (r.exists() and 'force.invalid' in r.read_text()): sys.exit(1)\n")
        validator.chmod(0o755)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Controller)
        self.server.state = {"selected": "node-b", "company": [], "reloads": [], "selections": [], "probes": [], "requests": [], "proxy_failure": False,
                             "reload_failure": False, "risk_error": False, "subscription_status": 200, "chatgpt_status": 200}
        port = self.server.server_port
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        def save(name, value):
            p = self.data / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(json.dumps(value, indent=2))
        save("settings.json", {"settingsVersion": 10, "selectedProxy": "node-a", "tun": True, "vpnDomainRules": ["DOMAIN-SUFFIX,ipdata.co"], "nodeGroups": []})
        save("subscription.json", {"entries": [{"id": "one", "name": "one", "url": f"http://127.0.0.1:{port}/subscription", "nodeCount": 2, "enabled": True, "status": "ready"}]})
        save("mihomo/providers/one.yaml", {"proxies": [{"name": n, "type": "http", "server": "127.0.0.1", "port": 9, "udp": True} for n in ["node-a", "node-b"]]})
        provider = self.data / "mihomo/providers/one.yaml"
        save("mihomo/providers/subscription-manifest.json", {"schemaVersion": 1, "revision": "kept", "entries": [{"subscriptionId": "one", "providerPath": str(provider), "providerRevision": hashlib.sha256(provider.read_bytes()).hexdigest()}]})
        save("mihomo/config.yaml", {"mode": "rule", "tun": {"enable": True, "auto-route": True, "route-exclude-address": ["10.0.0.0/8"]}, "dns": {"enable": True}, "proxies": [], "rules": ["MATCH,DIRECT"]})
        self.rpc = RPC(self.data, self.resources, port)

    def tearDown(self):
        try:
            if self.rpc:
                self.rpc.close()
        finally:
            self.server.shutdown()
            self.server.server_close()
            self.temp.cleanup()

    def test_startup_reuses_existing_connection_without_reload_or_node_change(self):
        journal = self.data / "runtime-state/native-company-routing.json"
        journal.parent.mkdir(parents=True, exist_ok=True)
        journal.write_text(json.dumps({"ownerPid": os.getpid(), "proxyName": "COMPANY-01234567"}))
        before = {p: p.read_bytes() for p in [self.data / "settings.json", self.data / "mihomo/config.yaml", journal]}
        result = self.rpc.request("native:startup-connect")
        self.assertEqual(result["startupOutcome"], "already-running")
        self.assertEqual(self.rpc.request("native:startup-connect")["startupOutcome"], "already-attempted")
        self.assertEqual(self.server.state["selected"], "node-b")
        self.assertEqual(self.server.state["reloads"], [])
        self.assertEqual(self.server.state["selections"], [])
        self.assertFalse(any(method in ["PUT", "DELETE"] for method, _ in self.server.state["requests"]))
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content)

    def test_network_recovery_status_is_additive_and_unowned_events_are_read_only(self):
        before = (self.data / "mihomo/config.yaml").read_bytes()
        status = self.rpc.request("vpn:get-status")["mihomo"]
        self.assertEqual(status["state"], "running")
        self.assertEqual(status["networkRecovery"]["state"], "idle")
        result = self.rpc.request("native:network-changed", {"available": False})
        self.assertEqual(result["networkRecovery"]["state"], "idle")
        self.assertEqual((self.data / "mihomo/config.yaml").read_bytes(), before)
        self.assertFalse(any(method in ["PUT", "DELETE"] for method, _ in self.server.state["requests"]))
        self.assertNotIn("signature", json.dumps(result["networkRecovery"]))

    def test_recovery_visibility_is_additive_and_exported_without_touching_unowned_engine(self):
        before = (self.data / "mihomo/config.yaml").read_bytes()
        recovery = self.rpc.request("vpn:get-status")["mihomo"]["networkRecovery"]
        self.assertEqual(recovery["history"], [])
        self.assertEqual(recovery["maxAttempts"], 3)
        error = self.rpc.request("vpn:retry-recovery", ok=False)
        self.assertIn("请先连接 VPN", error["message"])
        report = self.rpc.request("logs:export-redacted")
        self.assertIn("网络恢复：", report)
        self.assertIn('"history":[]', report)
        self.assertEqual((self.data / "mihomo/config.yaml").read_bytes(), before)
        self.assertFalse(any(method in ["PUT", "DELETE"] for method, _ in self.server.state["requests"]))

    def test_invalid_interval_does_not_reload_running_engine(self):
        before = (self.data / "subscription.json").read_bytes()
        self.rpc.request("subscription:configure-update", {"id": "one", "intervalMinutes": 4}, ok=False)
        self.assertEqual((self.data / "subscription.json").read_bytes(), before)
        self.assertEqual(self.server.state["reloads"], [])

    def test_runtime_environment_is_ephemeral_and_never_mutates_an_unowned_connection(self):
        before = {p: p.read_bytes() for p in [self.data / "settings.json", self.data / "mihomo/config.yaml"]}
        self.rpc.request("native:runtime-environment", {"sleeping": True, "lowPower": True, "networkEvents": True})
        self.rpc.request("native:runtime-environment", {"sleeping": False})
        self.rpc.request("native:runtime-environment", {"sleeping": "true"}, ok=False)
        self.rpc.request("native:runtime-environment", {"selectedProxy": "DIRECT"}, ok=False)
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertEqual(self.server.state["reloads"], [])
        self.assertEqual(self.server.state["selections"], [])

    def test_slow_download_does_not_block_status_or_stop(self):
        entered, release = threading.Event(), threading.Event()
        self.server.state.update(blocked_path="/subscription", download_entered=entered, download_release=release)
        self.rpc.process.stdin.write(json.dumps({"id": "slow-download", "channel": "subscription:update", "payload": {"id": "one"}}) + "\n")
        self.rpc.process.stdin.flush()
        try:
            self.assertTrue(entered.wait(3), "download did not start")
            start = time.monotonic()
            self.rpc.request("vpn:get-status")
            # The fixture controller belongs to another process: the stop must
            # promptly return its ownership refusal, without waiting for IO.
            stopped = self.rpc.request("vpn:stop", ok=False)
            self.assertIn("未停止其他内核", stopped["message"])
            self.assertLess(time.monotonic() - start, 2, "status/stop waited for the subscription server")
            self.assertFalse(release.is_set())
        finally:
            release.set()
        while True:
            reply = self.rpc.lines.get(timeout=5)
            if reply.get("id") == "slow-download":
                self.assertTrue(reply["ok"], reply)
                break
            self.rpc.events.append(reply)

    def test_connectivity_requires_system_dns_and_chatgpt_http(self):
        result = self.rpc.request("connectivity:check")["connectivity"]
        self.assertTrue(result["foreignOk"])
        self.assertTrue(result["proxyOk"])
        self.assertTrue(result["systemDns"]["ok"])
        self.assertEqual(result["chatgpt"]["httpStatus"], 200)
        self.server.state["chatgpt_status"] = 403
        blocked = self.rpc.request("connectivity:check")["connectivity"]
        self.assertFalse(blocked["foreignOk"])
        self.assertTrue(blocked["proxyOk"])
        self.assertTrue(blocked["systemDns"]["ok"])
        self.assertEqual(blocked["chatgpt"]["httpStatus"], 403)
        self.assertIn("403", blocked["error"])

    def test_proxy_success_cannot_mask_real_process_dns_mismatch(self):
        self.rpc.close()
        self.rpc = None
        self.rpc = RPC(self.data, self.resources, self.server.server_port,
                       {"SPLITVPN_TEST_SYSTEM_DNS_ADDRESSES": "203.0.113.1"})
        result = self.rpc.request("connectivity:check")["connectivity"]
        self.assertTrue(result["proxyOk"])
        self.assertTrue(result["chatgpt"]["ok"])
        self.assertFalse(result["systemDns"]["ok"])
        self.assertFalse(result["foreignOk"])
        self.assertIn("DNS", result["error"])

    def test_failed_download_keeps_manifest_and_provider(self):
        before = {name: (self.data / name).read_bytes() for name in ["mihomo/providers/one.yaml", "mihomo/providers/subscription-manifest.json", "mihomo/config.yaml"]}
        self.server.state["subscription_status"] = 503
        result = self.rpc.request("subscription:update", {"id": "one"})
        self.assertEqual(result["nodeCount"], 2)
        self.assertIsNotNone(result["lastError"])
        for name, value in before.items():
            self.assertEqual((self.data / name).read_bytes(), value)
        self.assertEqual(self.server.state["reloads"], [])

    def test_cached_shadowrocket_metadata_bootstraps_without_rewriting_provider(self):
        self.rpc.close()
        self.rpc = None
        raw = "STATUS=fixture status\nREMARKS=fixture: 東京\nhttp://127.0.0.1:9?udp=false#node-a\nhttp://127.0.0.1:9?udp=false#node-b\n"
        provider = self.data / "mihomo/providers/one.yaml"
        content = base64.b64encode(raw.encode())
        provider.write_bytes(content)
        manifest_path = self.data / "mihomo/providers/subscription-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["entries"][0]["providerRevision"] = hashlib.sha256(content).hexdigest()
        manifest_path.write_text(json.dumps(manifest))
        before = {name: (self.data / name).read_bytes() for name in ["settings.json", "subscription.json", "mihomo/providers/one.yaml", "mihomo/providers/subscription-manifest.json"]}
        self.rpc = RPC(self.data, self.resources, self.server.server_port)
        bootstrap = self.rpc.request("native:bootstrap")
        self.assertEqual({n["name"] for n in bootstrap["nodes"]}, {"DIRECT", "node-a", "node-b"})
        for name, value in before.items():
            self.assertEqual((self.data / name).read_bytes(), value)
        self.assertEqual(self.server.state["reloads"], [])

    def test_downloaded_metadata_subscription_retains_protocol_content_and_pid(self):
        raw = "STATUS=fixture status\nREMARKS=fixture: 東京\nanytls://fixture-secret@example.invalid:443?insecure=0&udp=false#node-a\nhttp://127.0.0.1:9?udp=false#node-b\n"
        content = base64.b64encode(raw.encode()).decode()
        self.server.state["subscription_content"] = content
        before = self.rpc.request("vpn:get-status")["mihomo"]["pid"]
        result = self.rpc.request("subscription:update", {"id": "one"})
        self.assertEqual(result["nodeCount"], 2)
        self.assertIsNone(result["lastError"])
        self.assertEqual(self.rpc.request("vpn:get-status")["mihomo"]["pid"], before)
        manifest = json.loads((self.data / "mihomo/providers/subscription-manifest.json").read_text())
        self.assertEqual(Path(manifest["entries"][0]["providerPath"]).read_text(), content)
        self.assertFalse(any(method == "DELETE" for method, _ in self.server.state["requests"]))

    def test_refresh_hotloads_without_killing_existing_connections(self):
        before = self.rpc.request("vpn:get-status")["mihomo"]["pid"]
        self.rpc.request("subscription:update", {"id": "one"})
        self.assertEqual(self.rpc.request("vpn:get-status")["mihomo"]["pid"], before)
        self.assertEqual(self.rpc.request("traffic:get-monitor")["snapshot"]["connections"][0]["id"], "kept-company-connection")
        self.assertTrue(self.server.state["reloads"])
        self.assertFalse(any(method == "DELETE" for method, _ in self.server.state["requests"]))

    def test_config_validation_failure_keeps_previous_files_without_reload(self):
        before = {n: (self.data / n).read_bytes() for n in ["settings.json", "mihomo/config.yaml"]}
        self.rpc.request("routing:update", {"vpnDomainRules": ["DOMAIN,force.invalid"]}, ok=False)
        for n, b in before.items():
            self.assertEqual((self.data / n).read_bytes(), b)
        self.assertEqual(self.server.state["reloads"], [])

    def test_controller_failure_rolls_back_files_and_outlet(self):
        before = (self.data / "settings.json").read_bytes()
        self.server.state["reload_failure"] = True
        self.rpc.request("routing:update", {"unknownTraffic": "vpn"}, ok=False)
        self.assertEqual((self.data / "settings.json").read_bytes(), before)
        self.assertEqual(self.server.state["selected"], "node-b")
        self.assertEqual(len(self.server.state["reloads"]), 2)
        self.assertFalse((self.data / "runtime-state/rust-pending.json").exists())

    def test_geo_fallback_updates_preserve_connection_and_settings(self):
        pid = self.rpc.request("vpn:get-status")["mihomo"]["pid"]
        for fallback, unknown, expected in [
            ("cn-direct-else-vpn", "direct", "VPN"),
            ("follow-default", "direct", "DIRECT"),
            ("follow-default", "vpn", "VPN"),
        ]:
            saved = self.rpc.request("routing:update", {"geoFallback": fallback, "unknownTraffic": unknown})
            self.assertEqual(saved["geoFallback"], fallback)
            self.assertEqual(json.loads((self.data / "settings.json").read_text())["geoFallback"], fallback)
            self.assertIn(f"\n- MATCH,{expected}\n", self.server.state["reloads"][-1])
            self.assertEqual(self.rpc.request("vpn:get-status")["mihomo"]["pid"], pid)
            self.assertEqual(self.server.state["selected"], "node-b")

        before = {name: (self.data / name).read_bytes() for name in ["settings.json", "mihomo/config.yaml"]}
        reloads = len(self.server.state["reloads"])
        error = self.rpc.request("routing:update", {"geoFallback": "block"}, ok=False)
        self.assertIn("Geo 数据不可用", error["message"])
        for name, content in before.items():
            self.assertEqual((self.data / name).read_bytes(), content)
        self.assertEqual(len(self.server.state["reloads"]), reloads)

        geo = self.resources / "geodata"
        geo.mkdir()
        for name in ["GeoSite.dat", "country.mmdb", "geoip.metadb"]:
            (geo / name).write_bytes(b"fixture geo")
        saved = self.rpc.request("routing:update", {"geoFallback": "block"})
        self.assertEqual(saved["geoFallback"], "block")
        self.assertIn("GEOSITE,cn,DIRECT", self.server.state["reloads"][-1])
        self.assertEqual(self.rpc.request("vpn:get-status")["mihomo"]["pid"], pid)
        self.assertEqual(self.server.state["selected"], "node-b")
        self.assertFalse(any(method == "DELETE" for method, _ in self.server.state["requests"]))

    def test_invalid_geo_fallback_does_not_rewrite_settings_or_reload(self):
        before = (self.data / "settings.json").read_bytes()
        for invalid in ["invalid", False, 1, {}]:
            self.rpc.request("routing:update", {"geoFallback": invalid}, ok=False)
        self.assertEqual((self.data / "settings.json").read_bytes(), before)
        self.assertEqual(self.server.state["reloads"], [])

    def test_outlet_edits_hotload_without_changing_default_node_or_pid(self):
        before = self.rpc.request("vpn:get-status")
        pid = before["mihomo"]["pid"]
        saved = self.rpc.request("routing:add-rule", {"rule": "https://api.example.test/path", "target": "direct"})
        self.assertIn("DOMAIN-SUFFIX,api.example.test", saved["directDomainRules"])
        self.assertIn("DOMAIN-SUFFIX,api.example.test,DIRECT", self.server.state["reloads"][-1])
        moved = self.rpc.request("routing:edit-rule", {"originalRule": "DOMAIN-SUFFIX,api.example.test", "originalTarget": "direct", "rule": "api.example.test", "target": "vpn"})
        self.assertNotIn("DOMAIN-SUFFIX,api.example.test", moved["directDomainRules"])
        self.assertIn("DOMAIN-SUFFIX,api.example.test", moved["vpnDomainRules"])
        self.assertEqual(moved["unknownTraffic"], before["settings"]["unknownTraffic"])
        self.assertEqual(self.rpc.request("vpn:get-status")["mihomo"]["pid"], pid)
        self.assertEqual(self.server.state["selected"], "node-b")
        self.assertFalse(any(method == "DELETE" for method, _ in self.server.state["requests"]))

    def test_failed_rule_reload_restores_both_rule_lists(self):
        before = (self.data / "settings.json").read_bytes()
        self.server.state["reload_failure"] = True
        self.rpc.request("routing:add-rule", {"rule": "192.0.2.0/24", "target": "direct"}, ok=False)
        self.assertEqual((self.data / "settings.json").read_bytes(), before)
        self.assertEqual(self.server.state["selected"], "node-b")

    def test_rule_preview_and_diagnosis_are_read_only(self):
        before = (self.data / "settings.json").read_bytes()
        normalized = self.rpc.request("routing:normalize-rule", {"rule": "192.0.2.8/24"})
        self.assertEqual(normalized["rule"], "IP-CIDR,192.0.2.0/24")
        diagnosed = self.rpc.request("routing:diagnose", {"target": "api.example.test"})
        self.assertIn("policy", diagnosed)
        for invalid in ["999.1.1.1", "192.0.2.8/33", "DOMAIN,example.test,DIRECT"]:
            self.rpc.request("routing:add-rule", {"rule": invalid, "target": "direct"}, ok=False)
        self.assertEqual((self.data / "settings.json").read_bytes(), before)
        self.assertEqual(self.server.state["reloads"], [])

    def test_node_switch_failure_restores_actual_outlet(self):
        before = (self.data / "settings.json").read_bytes()
        self.server.state["reload_failure"] = True
        self.rpc.request("nodes:select-v2", {"identityKey": "v1:one:node-a"}, ok=False)
        self.assertEqual((self.data / "settings.json").read_bytes(), before)
        self.assertEqual(self.server.state["selected"], "node-b")

    def test_risk_success_and_failure_restore_actual_outlet(self):
        self.rpc.request("native:risk-key", {"apiKey": "fixture-private-key"})
        selections = len(self.server.state["selections"])
        result = self.rpc.request("nodes:check-risk", {"nodeName": "node-a"})
        self.assertEqual(result["riskLevel"], "low")
        self.assertEqual(self.server.state["selected"], "node-b")
        # The check goes through the PROBE selector; the VPN outlet never moves.
        self.assertEqual(self.server.state["probes"], ["node-a"])
        self.assertEqual(len(self.server.state["selections"]), selections)
        self.server.state["risk_error"] = True
        error = self.rpc.request("nodes:check-risk", {"nodeName": "node-a"}, ok=False)
        self.assertNotIn("fixture-private-key", error["message"])
        self.assertEqual(self.server.state["selected"], "node-b")

    def test_risk_batch_cancel_restores_outlet_and_publishes_final_event(self):
        self.rpc.request("native:risk-key", {"apiKey": "fixture-private-key"})
        self.rpc.request("nodes:start-risk-batch", {"nodeNames": ["node-a", "node-b"]})
        self.rpc.event(False)
        self.rpc.request("nodes:cancel-risk-batch")
        final = self.rpc.event(True)
        self.assertTrue(final["cancelled"])
        self.assertLess(final["checked"], final["total"])
        self.assertEqual(self.server.state["selected"], "node-b")

    def test_udp_runtime_flag_overrides_provider_flag_without_probe(self):
        count = len(self.server.state["selections"])
        result = self.rpc.request("nodes:test-udp", {"nodeName": "node-a"})
        self.assertFalse(result["supported"])
        self.assertEqual(len(self.server.state["selections"]), count)

    def test_company_transport_error_retains_recovery_journal(self):
        state = self.rpc.request("native:company-apply", {"port": 1080, "helperPid": os.getpid(), "rows": [{"address": "10.20.0.0/24", "ports": "443", "network": "tcp"}]})
        self.assertTrue(state["active"])
        self.assertTrue((self.data / "runtime-state/native-company-routing.json").exists())
        self.server.state["proxy_failure"] = True
        self.rpc.request("native:company-remove", ok=False)
        self.assertTrue((self.data / "runtime-state/native-company-routing.json").exists())
        self.server.state["proxy_failure"] = False
        self.rpc.request("native:company-remove")
        self.assertFalse((self.data / "runtime-state/native-company-routing.json").exists())
        self.assertEqual(self.server.state["selected"], "node-b")

    def test_unconfirmed_company_tun_rolls_back_without_reporting_active_or_changing_settings(self):
        before = (self.data / "settings.json").read_bytes()
        self.server.state["unconfirmed_company_tun"] = True
        error = self.rpc.request("native:company-apply", {"port": 1080, "helperPid": os.getpid(), "rows": [{"address": "10.0.0.0/24", "ports": "443", "network": "tcp"}]}, ok=False)
        self.assertIn("TUN", error["message"])
        self.assertEqual(self.server.state["company"], [])
        self.assertFalse((self.data / "runtime-state/native-company-routing.json").exists())
        self.assertEqual((self.data / "settings.json").read_bytes(), before)
        self.assertEqual(self.server.state["selected"], "node-b")
        self.assertEqual(len(self.server.state["reloads"]), 2)
        self.assertFalse(self.rpc.request("native:bootstrap")["companyRouting"]["active"])
        self.assertEqual(self.rpc.request("traffic:get-monitor")["snapshot"]["connections"][0]["id"], "kept-company-connection")

    def test_existing_company_proxy_cannot_hide_a_failed_tun(self):
        state = self.rpc.request("native:company-apply", {"port": 1080, "helperPid": os.getpid(), "rows": [{"address": "10.0.0.0/24", "ports": "443", "network": "tcp"}]})
        self.assertTrue(state["active"])
        self.server.state["unconfirmed_company_tun"] = True
        self.rpc.request("native:runtime-environment", {"sleeping": False})
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            state = self.rpc.request("native:bootstrap")["companyRouting"]
            if not state["active"]:
                break
            time.sleep(0.05)
        self.assertFalse(state["active"])
        self.assertTrue(state["recovering"])
        self.assertIn("TUN", state["lastError"])
        self.assertTrue(self.server.state["company"])
        self.assertEqual(len(self.server.state["reloads"]), 1)
        self.server.state["unconfirmed_company_tun"] = False

    def test_foreign_company_owner_is_preserved_on_mutation_and_exit(self):
        journal = self.data / "runtime-state/native-company-routing.json"
        journal.parent.mkdir(parents=True, exist_ok=True)
        journal.write_text(json.dumps({"ownerPid": os.getpid(), "proxyName": "COMPANY-01234567"}))
        before = journal.read_bytes()
        self.rpc.request("native:favorite", {"name": "node-a"}, ok=False)
        self.rpc.request("native:company-remove", ok=False)
        self.rpc.close()
        self.assertEqual(journal.read_bytes(), before)
        # tearDown can safely close an already-exited process.
        self.rpc = None

    def test_unadopted_company_journal_is_retained_when_controller_fails_on_exit(self):
        journal = self.data / "runtime-state/native-company-routing.json"
        journal.parent.mkdir(parents=True, exist_ok=True)
        journal.write_text(json.dumps({"corePid": self.rpc.process.pid, "proxyName": "COMPANY-01234567"}))
        before = journal.read_bytes()
        self.server.state["company"] = ["COMPANY-01234567"]
        self.server.state["proxy_failure"] = True
        self.rpc.request("native:company-remove", ok=False)
        self.rpc.close()
        self.assertEqual(journal.read_bytes(), before)
        self.assertEqual(self.server.state["company"], ["COMPANY-01234567"])
        self.rpc = None

    def test_unadopted_company_outlet_is_removed_after_controller_confirms_recovery(self):
        journal = self.data / "runtime-state/native-company-routing.json"
        journal.parent.mkdir(parents=True, exist_ok=True)
        journal.write_text(json.dumps({"corePid": self.rpc.process.pid, "proxyName": "COMPANY-01234567"}))
        self.server.state["company"] = ["COMPANY-01234567"]
        self.rpc.request("native:company-remove")
        self.assertFalse(journal.exists())
        self.assertEqual(self.server.state["company"], [])
        self.assertEqual(self.server.state["selected"], "node-b")

    def test_speed_result_keeps_existing_cache_contract(self):
        result = self.rpc.request("nodes:test-recommended", {"identityKey": "v1:one:node-a"})
        self.assertEqual(result["runtimeName"], "node-a")
        self.assertEqual(result["status"], "available")
        self.assertEqual(result["medianDelayMs"], 27)
        self.assertEqual(len(result["samples"]), 3)
        self.assertEqual(result["samples"][0]["targetId"], "gstatic-204")


if __name__ == "__main__":
    unittest.main(verbosity=2)
