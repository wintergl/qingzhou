#!/usr/bin/env python3
"""Exercise the actual Rust JSON-lines process using only loopback fixtures."""
import base64
from datetime import datetime, timedelta, timezone
import shutil
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
import uuid
from urllib.parse import urlsplit, parse_qs

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
        if path == state.get("blocked_path") and len(state.get("selections", [])) >= state.get("blocked_after_select",0) and len(state.get("reloads", [])) >= state.get("blocked_after_reload", 0) and (state.get("blocked_node") is None or state.get("chain_selected") == state["blocked_node"]):
            state["download_entered"].set()
            state["download_release"].wait(10)
        if path.startswith("/chain-"):
            state.setdefault("chain_requests", []).append((path, state.get("chain_selected")))
            if path == "/chain-latency":
                if state.get("chain_latency_failure") or state.get("chain_selected") in state.get("chain_latency_failure_nodes", []):
                    self.respond({}, 503)
                    return
                time.sleep(state.get("chain_latency_delay", 0.01 if state.get("chain_selected") == "node-a" else 0.05))
                self.respond({})
            elif path == "/chain-download":
                time.sleep(state.get("chain_download_delay", 0.06 if state.get("chain_selected") == "node-a" else 0.005))
                body = b"x" * (32 if state.get("chain_bad_size") else 512 * 1024)
                self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
            else:
                self.respond({"ip": "203.0.113.9" if state.get("chain_wrong_ip") or len(state.get("selections", [])) >= state.get("chain_wrong_ip_after_select", float("inf")) or len(state.get("reloads", [])) >= state.get("chain_wrong_ip_after_reload", float("inf")) else "203.0.113.8"})
        elif path == "/version":
            self.respond({"version": "fixture"})
        elif path == "/configs":
            current = state.get("reloads", [])[-1] if state.get("reloads") else ""
            interface = re.search(r"^interface-name: (.+)$", current, re.M)
            tun = None if state.get("unconfirmed_company_tun") and state["company"] else False
            self.respond({"interface-name": interface.group(1) if interface else "", "tun": {"enable": tun}})
        elif path == "/proxies":
            if state.get("selections_failure"):
                self.respond({},503)
                return
            proxies = {n: {"type": "Http", "udp": False, "history": []} for n in ["node-a", "node-b", *state["company"]]}
            for name, history in state.get("node_histories", {}).items():
                if name in proxies: proxies[name]["history"] = history
            proxies["VPN"] = {"type": "Selector", "now": state["selected"], "all": ["DIRECT", "node-a", "node-b"]}
            self.respond({"proxies": proxies})
        elif path.startswith("/proxies/") and path.endswith("/delay"):
            state.setdefault("delay_urls", []).append(parse_qs(urlsplit(self.path).query).get("url", [""])[0])
            if state.get("delay_timeout"):
                self.respond({"message": "Timeout"}, 504)
            else:
                self.respond({"delay": 27})
        elif path.startswith("/proxies/"):
            name = path.split("/")[-1]
            if state["proxy_failure"]:
                self.respond({}, 503)
            elif name in ["VPN", "PROBE", "node-a", "node-b", *state["company"]]:
                self.respond({"name": name, "all": ["DIRECT", "node-a", "node-b"], "now":state["selected"]} if name == "VPN" else {"name":name})
            else:
                self.respond({}, 404)
        elif path == "/connections":
            self.respond({"uploadTotal": 1, "downloadTotal": 2, "connections": state.get("traffic_connections", [{"id": "kept-company-connection", "metadata": {"network": "tcp", "host": "fixture.invalid"}, "chains": ["DIRECT"], "upload": 1, "download": 2}])})
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
            if barrier := state.get("health_barrier"):
                try:
                    barrier.wait(timeout=3)
                except threading.BrokenBarrierError:
                    self.respond({"error": "website probes did not start together"}, 503)
                    return
                self.close_connection = True
            self.respond({"ok": True}, state.get("health_status", 200))
        elif path == "/chatgpt":
            self.respond({"ok": True}, state["chatgpt_status"])
        else:
            if state["risk_error"]:
                self.respond({"error": "fixture"}, 401)
            else:
                self.respond({"ip": state.get("risk_ip", "203.0.113.9"), "threat": {"is_proxy": False}, "scores": {"trust_score": 99}})

    def do_PUT(self):
        state = self.server.state
        path = urlsplit(self.path).path
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        state["requests"].append(("PUT", path))
        if path == "/configs":
            state["reloads"].append(body["payload"])
            if state["reload_failure"] or state.get("reload_always_failure"):
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
        elif path == "/proxies/__QZ_CHAIN_SCAN_FRONT__":
            if state.get("chain_selector_failure"):
                self.respond({}, 503)
                return
            state["chain_selected"] = body["name"]
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
        if port:
            env.update(SPLITVPN_TEST_CHAIN_PROXY_URL=f"http://127.0.0.1:{port}/", SPLITVPN_TEST_CHAIN_LATENCY_URL=f"http://127.0.0.1:{port}/chain-latency", SPLITVPN_TEST_CHAIN_DOWNLOAD_URL=f"http://127.0.0.1:{port}/chain-download", SPLITVPN_TEST_CHAIN_IP_URL=f"http://127.0.0.1:{port}/chain-ip")
        env.setdefault("SPLITVPN_TEST_CHAIN_INTERVAL_MS", "200")
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

    def send(self, channel, payload=None):
        self.counter += 1
        identity = str(self.counter)
        self.process.stdin.write(json.dumps({"id": identity, "channel": channel, "payload": payload or {}}) + "\n")
        self.process.stdin.flush()
        return identity

    def wait_reply(self, identity, ok=True):
        for index, reply in enumerate(self.events):
            if reply.get("id") == identity:
                self.events.pop(index)
                if ok is None: return reply
                assert reply["ok"] == ok, reply
                return reply["data"] if ok else reply["error"]
        while True:
            reply = self.lines.get(timeout=15)
            if reply.get("id") == identity:
                if ok is None: return reply
                assert reply["ok"] == ok, reply
                return reply["data"] if ok else reply["error"]
            self.events.append(reply)

    def request(self, channel, payload=None, ok=True):
        return self.wait_reply(self.send(channel, payload), ok=ok)

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

    def setup_chain_scan(self):
        config = {"enabled": True, "protocol": "socks5", "server": "proxy.example.test", "port": 1080, "username": "fixture", "expectedIp": "203.0.113.8"}
        self.rpc.request("static-exit:configure", {"configuration": config, "password": "fixture-only"})
        self.server.state["selections"].clear()

    def finish_chain_scan(self, strategy="download"):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            state = self.rpc.request("chain-scan:get", {"strategy": strategy})
            if not state["running"]:
                time.sleep(0.02)
                return state
            time.sleep(0.03)
        self.fail("chain scan did not finish")

    def chain_use_payload(self, state):
        row = next(r for r in state["results"] if r["nodeName"] == "node-a")
        return {"scanId": state["id"], "identityKey": row["identityKey"], "operationId": str(uuid.uuid4())}

    def chain_use_ready(self, disabled=False):
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "full"})
        state = self.finish_chain_scan()
        if disabled:
            self.rpc.request("static-exit:set-enabled", {"enabled": False})
        return state

    def restart_chain_use_disconnected(self, overrides=None):
        self.rpc.close(); self.rpc = None
        port = self.server.server_port
        # An owned child fixture exposes only a loopback controller and forwards
        # to the synthetic server. It never creates a VPN, DNS listener or route.
        script = r"""#!/usr/bin/env python3
import http.server,pathlib,re,sys,urllib.request,urllib.error
if '-t' in sys.argv: sys.exit(0)
text=pathlib.Path(sys.argv[sys.argv.index('-f')+1]).read_text()
assert 'tun:\n  enable: false' in text and 'dns:\n  enable: false' in text
port=int(re.search(r'127\.0\.0\.1:(\d+)',re.search(r'^external-controller: (.+)$',text,re.M).group(1)).group(1))
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def forward(self):
  body=self.rfile.read(int(self.headers.get('Content-Length',0))) if self.command=='PUT' else None
  req=urllib.request.Request('http://127.0.0.1:UPSTREAM'+self.path,data=body,method=self.command,headers={'Content-Type':'application/json'})
  try: response=urllib.request.urlopen(req,timeout=10)
  except urllib.error.HTTPError as error: response=error
  value=response.read();self.send_response(response.status);self.send_header('Content-Length',str(len(value)));self.end_headers();self.wfile.write(value)
 do_GET=do_PUT=do_DELETE=forward
http.server.ThreadingHTTPServer(('127.0.0.1',port),Handler).serve_forever()
""".replace('UPSTREAM',str(port))
        (self.resources / "mihomo").write_text(script)
        self.rpc = RPC(self.data,self.resources,overrides={
            "SPLITVPN_TEST_CHAIN_PROXY_URL":f"http://127.0.0.1:{port}/",
            "SPLITVPN_TEST_CHAIN_LATENCY_URL":f"http://127.0.0.1:{port}/chain-latency",
            "SPLITVPN_TEST_CHAIN_DOWNLOAD_URL":f"http://127.0.0.1:{port}/chain-download",
            "SPLITVPN_TEST_CHAIN_IP_URL":f"http://127.0.0.1:{port}/chain-ip", **(overrides or {})})
        self.rpc.request("static-exit:credential", {"configuration":json.loads((self.data / 'settings.json').read_text())["staticExit"],"password":"fixture-only"})

    def test_one_click_enables_isp_and_applies_only_the_selected_route_without_speed_download(self):
        state = self.chain_use_ready(disabled=True)
        before = {r["identityKey"]:r["testedAt"] for r in state["results"]}
        calls = len(self.server.state["chain_requests"])
        result = self.rpc.request("chain-scan:use", self.chain_use_payload(state))
        self.assertTrue(result["connected"])
        self.assertEqual(result["nodeName"],"node-a")
        settings = self.rpc.request("native:bootstrap")["status"]["settings"]
        self.assertTrue(settings["staticExit"]["enabled"])
        self.assertEqual(settings["selectedProxy"],"node-a")
        after = self.rpc.request("chain-scan:get")
        self.assertEqual(before,{r["identityKey"]:r["testedAt"] for r in after["results"]})
        self.assertEqual(after["routine"]["verification"]["status"],"passed")
        self.assertFalse(any(path=="/chain-download" for path,_ in self.server.state["chain_requests"][calls:]))
        self.assertEqual(self.rpc.request("chain-scan:use-state")["phase"],"connected")

    def prepare_automatic_failover(self, both_subscriptions=False):
        state = self.scan_two_subscriptions() if both_subscriptions else self.chain_use_ready(disabled=True)
        port = self.server.server_port
        self.restart_chain_use_disconnected({
            "SPLITVPN_TEST_CONNECTIVITY_URL": f"http://127.0.0.1:{port}/health",
            "SPLITVPN_TEST_CHATGPT_URL": f"http://127.0.0.1:{port}/chatgpt",
            "SPLITVPN_TEST_IPDATA_URL": f"http://127.0.0.1:{port}/",
            "SPLITVPN_TEST_SYSTEM_DNS_ADDRESSES": "198.18.0.65",
            "SPLITVPN_TEST_VPN_DNS_ADDRESSES": "198.18.0.65"})
        result = self.rpc.request("chain-scan:use", self.chain_use_payload(state))
        self.server.state["risk_ip"] = "203.0.113.8"
        self.server.state["health_status"] = 503
        return state, result["operationId"]

    def wait_failover(self, previous):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            result = self.rpc.request("chain-scan:use-state")
            if result.get("operationId") != previous and result.get("finished"):
                return result
            time.sleep(0.03)
        self.fail("automatic ISP failover did not complete")

    def test_isp_failover_requires_repeated_failure_and_preserves_measurements_and_cooldown(self):
        state, operation = self.prepare_automatic_failover()
        stamps = {r["identityKey"]: r["testedAt"] for r in state["results"]}
        calls = len(self.server.state["chain_requests"])
        for _ in range(2):
            self.rpc.request("connectivity:check")
            self.assertEqual(self.server.state["selected"], "node-a")
            self.assertEqual(self.rpc.request("chain-scan:use-state")["operationId"], operation)
        self.rpc.request("connectivity:check")
        result = self.wait_failover(operation)
        self.assertEqual(result["phase"], "connected", result)
        self.assertTrue(result["automatic"])
        self.assertEqual(result["previousNodeName"], "node-a")
        self.assertEqual(self.server.state["selected"], "node-b")
        after = self.rpc.request("chain-scan:get")
        self.assertEqual(stamps, {r["identityKey"]: r["testedAt"] for r in after["results"]})
        self.assertEqual(after["routine"]["verification"]["status"], "passed")
        self.assertFalse(any(path == "/chain-download" for path, _ in self.server.state["chain_requests"][calls:]))
        self.rpc.request("chain-scan:start", {"mode": "accumulate"})
        self.finish_chain_scan()
        saved = json.loads((self.data / "runtime-state/chain-scan-cache.json").read_text())
        self.assertIsInstance(saved["state"]["lastFailoverAttemptAt"], str)
        for _ in range(3): self.rpc.request("connectivity:check")
        time.sleep(0.15)
        self.assertEqual(self.rpc.request("chain-scan:use-state")["operationId"], result["operationId"])
        self.assertEqual(self.server.state["selected"], "node-b")

    def test_isp_failover_with_failed_preflight_keeps_the_original_route(self):
        _, operation = self.prepare_automatic_failover()
        settings = (self.data / "settings.json").read_bytes()
        reloads = len(self.server.state["reloads"])
        self.server.state["chain_wrong_ip"] = True
        for _ in range(3): self.rpc.request("connectivity:check")
        result = self.wait_failover(operation)
        self.assertEqual(result["phase"], "failed")
        self.assertIn("实际出口与预期 ISP 不一致", result["error"])
        self.assertEqual((self.data / "settings.json").read_bytes(), settings)
        self.assertEqual(len(self.server.state["reloads"]), reloads)
        self.assertEqual(self.server.state["selected"], "node-a")

    def test_manual_switch_failure_explains_response_and_exit_checks_without_urls(self):
        state = self.chain_use_ready()
        for failure, message in [("chain_latency_failure", "目标线路响应复核"), ("chain_wrong_ip", "实际出口与预期 ISP 不一致")]:
            self.server.state[failure] = True
            try:
                self.rpc.request("chain-scan:use", self.chain_use_payload(state), ok=False)
                status = self.rpc.request("chain-scan:use-state")
                self.assertEqual(status["phase"], "failed")
                self.assertFalse(status["automatic"])
                self.assertIn(message, status["error"])
                self.assertIn("原配置与连接未改动", status["error"])
                self.assertNotIn("http://", status["error"])
                self.assertNotIn("https://", status["error"])
                self.assertEqual(self.server.state["selected"], "node-b")
            finally:
                self.server.state[failure] = False

    def scan_two_subscriptions(self):
        self.install_chain_inventory(7)
        self.rpc.close(); self.rpc = None
        provider = self.data / "mihomo/providers/one.yaml"
        nodes = json.loads(provider.read_text())["proxies"]
        provider.write_text(json.dumps({"proxies": nodes[:4]}))
        other = provider.with_name("two.yaml")
        other.write_text(json.dumps({"proxies": nodes[4:]}))
        (self.data / "subscription.json").write_text(json.dumps({"entries": [
            {"id": key, "name": key, "url": "https://example.test/subscription", "nodeCount": count, "enabled": True, "status": "ready"}
            for key, count in [("one", 4), ("two", 3)]]}))
        (self.data / "mihomo/providers/subscription-manifest.json").write_text(json.dumps({"schemaVersion": 1, "revision": "both", "entries": [
            {"subscriptionId": key, "providerPath": str(path), "providerRevision": hashlib.sha256(path.read_bytes()).hexdigest()}
            for key, path in [("one", provider), ("two", other)]]}))
        self.rpc = RPC(self.data, self.resources, self.server.server_port)
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "full"})
        return self.finish_chain_scan()

    def test_isp_backups_keep_two_verified_routes_from_each_subscription_after_restart(self):
        state = self.scan_two_subscriptions()
        backups = state["routine"]["backupIdentityKeys"]
        self.assertEqual(len(backups), 4)
        for subscription in ["one", "two"]:
            self.assertEqual(sum(r["identityKey"] in backups and r["subscriptionId"] == subscription for r in state["results"]), 2)
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port)
        self.setup_chain_scan()
        self.assertEqual(self.rpc.request("chain-scan:get")["routine"]["backupIdentityKeys"], backups)

    def test_isp_failover_tries_the_other_subscription_and_skips_a_failed_backup(self):
        state, operation = self.prepare_automatic_failover(both_subscriptions=True)
        backups = state["routine"]["backupIdentityKeys"]
        others = [r["nodeName"] for key in backups for r in state["results"] if r["identityKey"] == key and r["subscriptionId"] == "two"]
        self.assertEqual(len(others), 2)
        self.server.state["chain_latency_failure_nodes"] = [others[0]]
        calls = len(self.server.state["chain_requests"])
        for _ in range(3): self.rpc.request("connectivity:check")
        result = self.wait_failover(operation)
        self.assertEqual(result["phase"], "connected", result)
        self.assertEqual(self.server.state["selected"], others[1])
        probed = {node for _, node in self.server.state["chain_requests"][calls:]}
        self.assertEqual(probed, set(others))

    def test_isp_failover_restores_original_route_when_actual_exit_is_wrong(self):
        _, operation = self.prepare_automatic_failover()
        settings = (self.data / "settings.json").read_bytes()
        self.server.state["chain_wrong_ip_after_reload"] = len(self.server.state["reloads"]) + 1
        for _ in range(3): self.rpc.request("connectivity:check")
        result = self.wait_failover(operation)
        self.assertEqual(result["phase"], "failed")
        self.assertEqual((self.data / "settings.json").read_bytes(), settings)
        self.assertEqual(self.server.state["selected"], "node-a")
        self.assertFalse((self.data / "runtime-state/rust-pending.json").exists())

    def test_disconnect_during_automatic_backup_check_cannot_reconnect_later(self):
        _, operation = self.prepare_automatic_failover()
        self.server.state.update(blocked_path="/chain-latency", blocked_node="node-b", download_entered=threading.Event(), download_release=threading.Event())
        try:
            for _ in range(3): self.rpc.request("connectivity:check")
            self.assertTrue(self.server.state["download_entered"].wait(8))
            selections = list(self.server.state["selections"])
            self.rpc.request("vpn:stop")
            self.server.state["download_release"].set()
            result = self.wait_failover(operation)
            self.assertIn(result["phase"], ["failed", "cancelled"])
            self.assertEqual(self.server.state["selections"], selections)
            self.assertEqual(self.rpc.request("vpn:get-status")["mihomo"]["state"], "stopped")
        finally:
            self.server.state["download_release"].set()

    def test_one_click_recheck_of_current_route_does_not_reload_or_rebuild_connections(self):
        state = self.chain_use_ready()
        payload = self.chain_use_payload(state)
        self.rpc.request("chain-scan:use",payload)
        reloads = len(self.server.state["reloads"])
        selections = list(self.server.state["selections"])
        requests = len(self.server.state["requests"])
        payload["operationId"] = str(uuid.uuid4())
        self.rpc.request("chain-scan:use",payload)
        self.assertEqual(len(self.server.state["reloads"]),reloads)
        self.assertEqual(self.server.state["selections"],selections)
        self.assertFalse(any(method=="DELETE" for method,_ in self.server.state["requests"][requests:]))

    def test_one_click_preflight_failure_leaves_original_settings_and_connection_untouched(self):
        state = self.chain_use_ready(disabled=True)
        before = (self.data / "settings.json").read_bytes()
        selected = self.server.state["selected"]
        reloads = len(self.server.state["reloads"])
        self.server.state["chain_wrong_ip"] = True
        error = self.rpc.request("chain-scan:use",self.chain_use_payload(state),ok=False)
        self.assertIn("原配置与连接未改动",error["message"])
        self.assertEqual((self.data / "settings.json").read_bytes(),before)
        self.assertEqual(self.server.state["selected"],selected)
        self.assertEqual(len(self.server.state["reloads"]),reloads)

    def test_one_click_failed_apply_or_wrong_final_exit_restores_prior_route_and_settings(self):
        for failure in ["reload_failure","final_exit"]:
            with self.subTest(failure=failure):
                state = self.chain_use_ready(disabled=True)
                before = (self.data / "settings.json").read_bytes()
                selected = self.server.state["selected"]
                if failure=="reload_failure": self.server.state["reload_failure"] = True
                else: self.server.state["chain_wrong_ip_after_reload"] = len(self.server.state["reloads"])+1
                error = self.rpc.request("chain-scan:use",self.chain_use_payload(state),ok=False)
                self.assertIn("原配置与线路已恢复",error["message"])
                self.assertEqual((self.data / "settings.json").read_bytes(),before)
                self.assertEqual(self.server.state["selected"],selected)
                self.assertFalse((self.data / "runtime-state/rust-pending.json").exists())
                self.server.state.pop("chain_wrong_ip_after_reload",None)

    def test_one_click_cancel_during_preflight_and_duplicate_click_do_not_change_connection(self):
        state = self.chain_use_ready(disabled=True)
        before = (self.data / "settings.json").read_bytes()
        payload = self.chain_use_payload(state)
        self.server.state.update(blocked_path="/chain-latency",download_entered=threading.Event(),download_release=threading.Event())
        pending = self.rpc.send("chain-scan:use",payload)
        self.assertTrue(self.server.state["download_entered"].wait(5))
        self.rpc.request("chain-scan:use",self.chain_use_payload(state),ok=False)
        active = self.rpc.request("chain-scan:use-state")
        self.assertFalse(active["finished"])
        reply = self.rpc.request("chain-scan:cancel-use",{"operationId":payload["operationId"]})
        self.assertTrue(reply["cancelRequested"])
        self.server.state["download_release"].set()
        self.assertIn("取消",self.rpc.wait_reply(pending,ok=False)["message"])
        self.assertEqual((self.data / "settings.json").read_bytes(),before)
        self.assertEqual(self.rpc.request("chain-scan:use-state")["phase"],"cancelled")

    def test_one_click_cancel_after_apply_restores_original_connection(self):
        state = self.chain_use_ready(disabled=True)
        before = (self.data / "settings.json").read_bytes()
        selected = self.server.state["selected"]
        payload = self.chain_use_payload(state)
        self.server.state.update(blocked_path="/chain-latency",blocked_after_reload=len(self.server.state["reloads"])+1,download_entered=threading.Event(),download_release=threading.Event())
        pending = self.rpc.send("chain-scan:use",payload)
        self.assertTrue(self.server.state["download_entered"].wait(5))
        self.assertEqual(self.rpc.request("chain-scan:use-state")["phase"],"confirming")
        self.rpc.request("chain-scan:cancel-use",{"operationId":payload["operationId"]})
        self.server.state["download_release"].set()
        self.assertIn("原配置与线路已恢复",self.rpc.wait_reply(pending,ok=False)["message"])
        self.assertEqual((self.data / "settings.json").read_bytes(),before)
        self.assertEqual(self.server.state["selected"],selected)

    def test_one_click_cancel_before_request_is_not_lost_and_old_cancel_does_not_cancel_new_use(self):
        state = self.chain_use_ready()
        payload = self.chain_use_payload(state)
        self.rpc.request("chain-scan:cancel-use",{"operationId":payload["operationId"]})
        self.assertIn("取消",self.rpc.request("chain-scan:use",payload,ok=False)["message"])
        self.rpc.request("chain-scan:use",self.chain_use_payload(state))

    def test_one_click_can_start_an_owned_loopback_fixture_and_restores_stopped_state_on_failure(self):
        for fail in [False,True]:
            with self.subTest(final_exit_failure=fail):
                state = self.chain_use_ready(disabled=True)
                self.restart_chain_use_disconnected()
                before = (self.data / "settings.json").read_bytes()
                if fail: self.server.state["chain_wrong_ip_after_reload"] = len(self.server.state["reloads"])
                if fail:
                    # Preflight must still pass; fail only after the owned
                    # fixture's first business selector change.
                    self.server.state.pop("chain_wrong_ip_after_reload",None)
                    self.server.state["chain_wrong_ip_after_select"] = len(self.server.state["selections"])+1
                result = self.rpc.request("chain-scan:use",self.chain_use_payload(state),ok=not fail)
                if fail:
                    self.assertIn("VPN 未连接",result["message"])
                    self.assertEqual((self.data / "settings.json").read_bytes(),before)
                    self.assertEqual(self.rpc.request("vpn:get-status")["mihomo"]["state"],"stopped")
                else: self.assertTrue(result["connected"])
                self.server.state.pop("chain_wrong_ip_after_select",None)
                self.rpc.close(); self.rpc = RPC(self.data,self.resources,self.server.server_port)

    def test_one_click_network_change_during_preflight_or_confirmation_does_not_keep_new_route(self):
        self.setup_chain_network_fixture()
        for after_apply, sleeping in [(False,False),(True,False),(True,True)]:
            with self.subTest(after_apply=after_apply,sleeping=sleeping):
                state = self.chain_use_ready(disabled=True)
                before = (self.data / "settings.json").read_bytes()
                selected = self.server.state["selected"]
                self.server.state.update(blocked_path="/chain-latency",blocked_after_reload=len(self.server.state["reloads"])+(1 if after_apply else 0),download_entered=threading.Event(),download_release=threading.Event())
                pending = self.rpc.send("chain-scan:use",self.chain_use_payload(state))
                self.assertTrue(self.server.state["download_entered"].wait(5))
                if sleeping:
                    environment = self.rpc.send("native:runtime-environment",{"sleeping":True})
                else:
                    self.network_fixture.write_text(json.dumps({"available":True,"signature":"after-apply" if after_apply else "after-preflight"}))
                self.server.state["download_release"].set()
                self.assertIn("环境已变化",self.rpc.wait_reply(pending,ok=False)["message"])
                if sleeping:
                    self.rpc.wait_reply(environment)
                    self.rpc.request("native:runtime-environment",{"sleeping":False})
                self.assertEqual((self.data / "settings.json").read_bytes(),before)
                self.assertEqual(self.server.state["selected"],selected)
                self.server.state.pop("blocked_path",None)

    def test_one_click_stop_overtakes_an_owned_new_connection_without_reconnecting(self):
        state = self.chain_use_ready(disabled=True)
        self.restart_chain_use_disconnected()
        before = (self.data / "settings.json").read_bytes()
        self.server.state.update(blocked_path="/chain-latency",blocked_after_select=len(self.server.state["selections"])+1,download_entered=threading.Event(),download_release=threading.Event())
        pending = self.rpc.send("chain-scan:use",self.chain_use_payload(state))
        self.assertTrue(self.server.state["download_entered"].wait(5))
        stop = self.rpc.send("vpn:stop")
        self.server.state["download_release"].set()
        self.assertIn("VPN 未连接",self.rpc.wait_reply(pending,ok=False)["message"])
        self.rpc.wait_reply(stop)
        self.assertEqual((self.data / "settings.json").read_bytes(),before)
        self.assertEqual(self.rpc.request("vpn:get-status")["mihomo"]["state"],"stopped")
        time.sleep(0.1)
        self.assertEqual(self.rpc.request("vpn:get-status")["mihomo"]["state"],"stopped")

    def test_one_click_interrupted_journal_does_not_reload_a_different_running_process(self):
        self.chain_use_ready(disabled=True)
        self.rpc.close(); self.rpc = None
        settings = (self.data / "settings.json").read_text()
        self.data.joinpath("runtime-state/rust-pending.json").write_text(json.dumps({
            "schemaVersion":1,"ownerPid":99999999,"chainUseWasRunning":True,"chainUseOriginalPid":99999998,
            "files":{"settings.json":settings},"selections":{"VPN":"node-a"}}))
        reloads = len(self.server.state["reloads"])
        self.rpc = RPC(self.data,self.resources,self.server.server_port)
        status = self.rpc.request("native:bootstrap")["status"]
        self.assertEqual(status["recovery"]["state"],"required")
        self.assertEqual(status["mihomo"]["state"],"error")
        self.assertEqual(len(self.server.state["reloads"]),reloads)
        self.assertEqual((self.data / "settings.json").read_text(),settings)
        self.assertTrue((self.data / "runtime-state/rust-pending.json").exists())

    def test_one_click_does_not_apply_when_original_selection_cannot_be_confirmed(self):
        state = self.chain_use_ready(disabled=True)
        before = (self.data / "settings.json").read_bytes()
        reloads = len(self.server.state["reloads"])
        selected = self.server.state["selected"]
        self.server.state["selections_failure"] = True
        error = self.rpc.request("chain-scan:use",self.chain_use_payload(state),ok=False)
        self.assertIn("当前线路无法核对",error["message"])
        self.assertEqual((self.data / "settings.json").read_bytes(),before)
        self.assertEqual(len(self.server.state["reloads"]),reloads)
        self.assertEqual(self.server.state["selected"],selected)
        self.server.state["selections_failure"] = False

    def test_one_click_rollback_failure_preserves_recovery_evidence_and_does_not_claim_restoration(self):
        state = self.chain_use_ready(disabled=True)
        self.server.state["reload_always_failure"] = True
        error = self.rpc.request("chain-scan:use",self.chain_use_payload(state),ok=False)
        self.assertIn("恢复尚未确认",error["message"])
        self.assertNotIn("已恢复",error["message"])
        self.assertTrue((self.data / "runtime-state/rust-pending.json").exists())
        self.assertEqual(self.rpc.request("runtime:get-recovery-state")["state"],"required")
        self.assertEqual(self.rpc.request("vpn:get-status")["mihomo"]["state"],"error")
        self.assertIn("RECOVERY_REQUIRED",self.rpc.request("chain-scan:use",self.chain_use_payload(state),ok=False)["message"])
        self.server.state["reload_always_failure"] = False

    def age_chain_results(self, identity_keys=None, interval_ms=200):
        """Age only isolated cache fixtures; keep immutable history untouched."""
        self.rpc.close(); self.rpc = None
        path = self.data / "runtime-state/chain-scan-cache.json"
        saved = json.loads(path.read_text())
        expired = (datetime.now(timezone.utc) - timedelta(hours=25)).isoformat()
        for row in saved["state"]["results"]:
            if identity_keys is None or row["identityKey"] in identity_keys:
                row["testedAt"] = expired
        path.write_text(json.dumps(saved))
        self.rpc = RPC(self.data, self.resources, self.server.server_port,
                       overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1", "SPLITVPN_TEST_CHAIN_INTERVAL_MS": str(interval_ms)})
        self.rpc.request("native:runtime-environment", {"onBattery": True})
        self.setup_chain_scan()
        return self.rpc.request("chain-scan:get")

    def install_chain_inventory(self, count):
        self.rpc.close(); self.rpc = None
        self.server.state["selected"] = "node-a"
        provider = self.data / "mihomo/providers/one.yaml"
        names = ["node-a", "node-b"] + [f"node-{i}" for i in range(2, count)]
        provider.write_text(json.dumps({"proxies": [{"name": n, "type": "http", "server": "127.0.0.1", "port": 9} for n in names[:count]]}))
        path = self.data / "mihomo/providers/subscription-manifest.json"
        manifest = json.loads(path.read_text())
        manifest["entries"][0]["providerRevision"] = hashlib.sha256(provider.read_bytes()).hexdigest()
        path.write_text(json.dumps(manifest))
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1"})
        self.rpc.request("native:runtime-environment", {"onBattery": True})
        self.setup_chain_scan()
        return [n for n in self.rpc.request("nodes:list") if n.get("identityKey")]

    def test_quick_search_allows_one_verified_route_to_be_used_and_maintained(self):
        self.install_chain_inventory(200)
        selected = self.server.state["selected"]
        reply = self.rpc.request("chain-scan:start", {"mode": "quick"})
        self.assertLessEqual(reply["total"], 3)
        state = self.finish_chain_scan()
        self.assertEqual(state["completed"], 1)
        self.assertEqual(len(state["results"]), 1)
        self.assertTrue(state["results"][0]["connectionEligible"])
        self.assertEqual(len(state["routine"]["maintenanceIdentityKeys"]), 1)
        self.assertEqual(self.server.state["selected"], selected)
        self.assertEqual(sum(p == "/chain-download" for p, _ in self.server.state["chain_requests"]), 2)
        self.rpc.request("chain-scan:auto-configure", {"enabled": True, "intervalMinutes": 30})
        self.age_chain_results()
        calls = len(self.server.state["chain_requests"])
        self.rpc.request("native:runtime-environment", {"onBattery": False})
        done = self.wait_for_chain(lambda s: s.get("automatic") and not s["running"] and not s["workerActive"])
        self.assertEqual(done["completed"], 1)
        self.assertEqual(done["candidateCount"], 1)
        self.assertEqual(len(done["routine"]["maintenanceIdentityKeys"]), 1)
        self.assertEqual({node for _, node in self.server.state["chain_requests"][calls:]}, {state["results"][0]["nodeName"]})

    def test_two_hundred_saved_routes_keep_a_stable_pool_and_do_not_rotate_into_full_scan(self):
        nodes = self.install_chain_inventory(200)
        self.rpc.request("chain-scan:start", {"mode": "quick"})
        self.finish_chain_scan()
        self.rpc.close(); self.rpc = None
        path = self.data / "runtime-state/chain-scan-cache.json"
        saved = json.loads(path.read_text())
        template = saved["state"]["results"][0]
        aged = (datetime.now(timezone.utc) - timedelta(hours=25)).isoformat()
        saved["state"]["results"] = []
        for index, node in enumerate(nodes):
            row = dict(template, identityKey=node["identityKey"], nodeName=node["name"], testedAt=aged, downloadMbps=10 + index)
            saved["state"]["results"].append(row)
        path.write_text(json.dumps(saved))
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1"})
        self.rpc.request("native:runtime-environment", {"onBattery": True})
        self.setup_chain_scan()
        pool = self.rpc.request("chain-scan:get")["routine"]["maintenanceIdentityKeys"]
        self.assertEqual(len(pool), 3)
        self.rpc.request("chain-scan:auto-configure", {"enabled": True, "intervalMinutes": 30})
        self.rpc.request("native:runtime-environment", {"onBattery": False})
        done = self.wait_for_chain(lambda s: s.get("automatic") and not s["running"] and not s["workerActive"])
        self.assertEqual(done["completed"], 3)
        self.assertEqual(set(done["candidateIdentityKeys"]), set(pool))
        self.assertEqual(done["routine"]["maintenanceIdentityKeys"], pool)
        self.assertEqual(len(done["results"]), 200)
        self.assertTrue(all(r["testedAt"] == aged for r in done["results"] if r["identityKey"] not in pool))
        calls = len(self.server.state["chain_requests"])
        self.rpc.close(); self.rpc = None
        saved = json.loads(path.read_text())
        saved["state"]["lastAutomaticBatchAt"] = (datetime.now(timezone.utc) - timedelta(hours=3)).isoformat()
        path.write_text(json.dumps(saved))
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1"})
        self.setup_chain_scan()
        self.rpc.request("native:runtime-environment", {"onBattery": False})
        time.sleep(0.4)
        state = self.rpc.request("chain-scan:get")
        self.assertEqual(state["id"], done["id"])
        self.assertEqual(state["routine"]["maintenanceIdentityKeys"], pool)
        self.assertFalse(state["workerActive"])
        self.assertEqual(len(self.server.state["chain_requests"]), calls)

    def test_performance_age_keeps_ranking_and_rechecking_current_route_does_not_rebuild_it(self):
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "full"})
        self.finish_chain_scan()
        state = self.rpc.request("chain-scan:get")
        winner = state["recommendedIdentityKey"]
        aged = self.age_chain_results([winner])
        self.assertEqual(aged["recommendedIdentityKey"], winner)
        row = next(r for r in aged["results"] if r["identityKey"] == winner)
        stamp = row["testedAt"]
        self.assertTrue(row["requiresRefresh"] and row["connectionEligible"])
        self.rpc.request("chain-scan:connect", {"scanId": aged["id"], "identityKey": winner})
        after = self.rpc.request("chain-scan:get")
        self.assertEqual(after["routine"]["verification"]["status"], "passed")
        self.assertEqual(after["routine"]["performanceTestedAt"], stamp)
        selections = len(self.server.state["selections"])
        reloads = len(self.server.state["reloads"])
        calls = len(self.server.state["chain_requests"])
        self.rpc.request("chain-scan:connect", {"scanId": after["id"], "identityKey": winner})
        self.assertEqual(len(self.server.state["selections"]), selections)
        self.assertEqual(len(self.server.state["reloads"]), reloads)
        self.assertFalse(any(p == "/chain-download" for p, _ in self.server.state["chain_requests"][calls:]))
        self.server.state["chain_wrong_ip"] = True
        self.rpc.request("chain-scan:connect", {"scanId": after["id"], "identityKey": winner}, ok=False)
        failed = self.rpc.request("chain-scan:get")
        self.assertEqual(failed["routine"]["verification"]["status"], "failed")
        self.assertEqual(failed["routine"]["performanceTestedAt"], stamp)

    def test_network_change_can_recheck_compatible_route_without_refreshing_performance(self):
        self.setup_chain_network_fixture()
        self.rpc.request("chain-scan:start", {"mode": "quick"})
        before = self.finish_chain_scan()
        row = before["results"][0]
        self.network_fixture.write_text(json.dumps({"available": True, "signature": "network-b"}))
        changed = self.rpc.request("chain-scan:get")
        self.assertTrue(changed["stale"])
        self.assertTrue(changed["results"][0]["otherEnvironment"])
        self.assertTrue(changed["results"][0]["connectionEligible"])
        calls = len(self.server.state["chain_requests"])
        self.rpc.request("chain-scan:connect", {"scanId": changed["id"], "identityKey": row["identityKey"]})
        after = self.rpc.request("chain-scan:get")
        self.assertEqual(after["routine"]["verification"]["status"], "passed")
        self.assertEqual(after["results"][0]["testedAt"], row["testedAt"])
        self.assertTrue(after["results"][0]["otherEnvironment"])
        self.assertTrue(after["routine"]["performanceOtherEnvironment"])
        self.assertFalse(any(p == "/chain-download" for p, _ in self.server.state["chain_requests"][calls:]))

    def test_manual_quick_search_does_not_silently_resume_paused_maintenance(self):
        self.setup_chain_scan()
        self.rpc.request("chain-scan:auto-configure", {"enabled": True, "intervalMinutes": 30})
        self.rpc.request("chain-scan:cancel")
        self.assertTrue(self.rpc.request("chain-scan:get")["autoRefresh"]["paused"])
        self.rpc.request("chain-scan:start", {"mode": "quick"})
        done = self.finish_chain_scan()
        self.assertTrue(done["autoRefresh"]["paused"])

    def test_route_recheck_rejects_network_change_during_the_check(self):
        self.setup_chain_network_fixture()
        self.rpc.request("chain-scan:start", {"mode": "quick"})
        before = self.finish_chain_scan()
        selected = self.server.state["selected"]
        self.server.state.update(blocked_path="/chain-latency", download_entered=threading.Event(), download_release=threading.Event())
        replies = queue.Queue()
        def connect():
            try:
                replies.put(self.rpc.request("chain-scan:connect", {"scanId": before["id"], "identityKey": before["results"][0]["identityKey"]}, ok=False))
            except Exception as error:
                replies.put(error)
        worker = threading.Thread(target=connect)
        worker.start()
        self.assertTrue(self.server.state["download_entered"].wait(5))
        self.network_fixture.write_text(json.dumps({"available": True, "signature": "network-b"}))
        self.server.state["download_release"].set()
        worker.join(10)
        self.assertFalse(worker.is_alive())
        result = replies.get_nowait()
        self.assertIsInstance(result, dict)
        self.assertIn("环境已变化", result["message"])
        self.assertEqual(self.server.state["selected"], selected)
        self.assertEqual(self.rpc.request("chain-scan:get")["routine"]["verification"]["status"], "pending")

    def test_first_complete_route_remains_usable_when_a_wider_comparison_is_paused(self):
        self.setup_chain_scan()
        self.server.state.update(blocked_path="/chain-latency", blocked_node="node-b", download_entered=threading.Event(), download_release=threading.Event())
        self.rpc.request("chain-scan:start", {"mode": "full"})
        self.assertTrue(self.server.state["download_entered"].wait(5))
        partial = self.rpc.request("chain-scan:get")
        self.assertTrue(partial["running"])
        self.assertEqual(partial["completed"], 1)
        self.assertTrue(partial["canUseCachedResults"])
        self.assertTrue(partial["results"][0]["connectionEligible"])
        self.rpc.request("chain-scan:cancel")
        self.server.state["download_release"].set()
        paused = self.finish_chain_scan()
        self.assertTrue(paused["cancelled"])
        self.assertTrue(paused["canUseCachedResults"])
        self.assertEqual(len(paused["routine"]["maintenanceIdentityKeys"]), 1)
        self.rpc.request("chain-scan:connect", {"scanId": paused["id"], "identityKey": paused["results"][0]["identityKey"]})
        self.assertEqual(self.rpc.request("chain-scan:get")["routine"]["verification"]["status"], "passed")

    def test_disconnected_state_keeps_a_verified_preferred_route_without_requiring_another_test(self):
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "quick"})
        before = self.finish_chain_scan()
        known = before["results"][0]
        calls = len(self.server.state["chain_requests"])
        # Reopen without an attached business controller; the scan fixture's
        # controller is deliberately unowned and must never be stopped.
        self.rpc.close()
        port = self.server.server_port
        overrides = {"SPLITVPN_TEST_CHAIN_PROXY_URL": f"http://127.0.0.1:{port}/"}
        for kind in ["LATENCY", "DOWNLOAD", "IP"]:
            overrides[f"SPLITVPN_TEST_CHAIN_{kind}_URL"] = f"http://127.0.0.1:{port}/chain-{kind.lower()}"
        self.rpc = RPC(self.data, self.resources, overrides=overrides)
        state = self.rpc.request("chain-scan:get")
        self.assertEqual(state["routine"]["connectionState"], "disconnected")
        self.assertIsNone(state["routine"]["currentIdentityKey"])
        self.assertEqual(state["routine"]["preferredIdentityKey"], known["identityKey"])
        self.assertEqual(state["routine"]["performanceTestedAt"], known["testedAt"])
        self.assertEqual(state["routine"]["backupIdentityKeys"], [])
        self.assertEqual(len(self.server.state["chain_requests"]), calls)

    def test_network_interruption_does_not_erase_or_rotate_the_remembered_maintenance_pool(self):
        self.install_chain_inventory(4)
        self.rpc.close()
        self.network_fixture = self.data / "test-network.json"
        self.network_fixture.write_text(json.dumps({"available": True, "signature": "network-a"}))
        overrides = {"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1", "SPLITVPN_TEST_CHAIN_NETWORK_FILE": str(self.network_fixture)}
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides=overrides)
        self.rpc.request("native:runtime-environment", {"onBattery": True})
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "full"})
        baseline = self.finish_chain_scan()
        pool = baseline["routine"]["maintenanceIdentityKeys"]
        self.assertEqual(len(pool), 3)
        self.rpc.close()
        path = self.data / "runtime-state/chain-scan-cache.json"
        saved = json.loads(path.read_text())
        for row in saved["state"]["results"]:
            row["testedAt"] = (datetime.now(timezone.utc) - timedelta(hours=25)).isoformat()
        path.write_text(json.dumps(saved))
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides=overrides)
        self.rpc.request("native:runtime-environment", {"onBattery": True})
        self.setup_chain_scan()
        self.server.state.update(blocked_path="/chain-latency", download_entered=threading.Event(), download_release=threading.Event())
        self.rpc.request("chain-scan:auto-configure", {"enabled": True, "intervalMinutes": 30})
        self.rpc.request("native:runtime-environment", {"onBattery": False})
        self.assertTrue(self.server.state["download_entered"].wait(5))
        self.network_fixture.write_text(json.dumps({"available": False}))
        self.server.state["download_release"].set()
        stopped = self.wait_for_chain(lambda s: not s["running"] and not s["workerActive"])
        self.assertEqual(stopped["autoRefresh"]["status"], "waiting-network")
        self.assertEqual(json.loads(path.read_text())["state"]["maintenanceIdentityKeys"], pool)
        self.network_fixture.write_text(json.dumps({"available": True, "signature": "network-a"}))
        self.assertEqual(self.rpc.request("chain-scan:get")["routine"]["maintenanceIdentityKeys"], pool)

    def test_chain_scan_with_isp_disabled_preserves_business_state_and_cache(self):
        self.setup_chain_scan()
        self.rpc.request("static-exit:set-enabled", {"enabled": False})
        settings = (self.data / "settings.json").read_bytes()
        config = (self.data / "mihomo/config.yaml").read_bytes()
        selected = self.server.state["selected"]
        self.server.state["reloads"].clear()
        self.rpc.request("chain-scan:start", {"mode": "full"})
        state = self.finish_chain_scan()
        self.assertEqual(state["completed"], 2)
        self.assertTrue(state["canUseCachedResults"])
        self.assertEqual((self.data / "settings.json").read_bytes(), settings)
        self.assertEqual((self.data / "mihomo/config.yaml").read_bytes(), config)
        self.assertEqual(self.server.state["selected"], selected)
        self.assertEqual(self.server.state["reloads"], [])
        self.rpc.request("chain-scan:connect", {"scanId": state["id"]}, ok=False)
        cache = self.data / "runtime-state/chain-scan-cache.json"
        self.assertTrue(cache.exists())
        self.assertNotIn("fixture-only", cache.read_text())
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port)
        restored = self.rpc.request("chain-scan:get")
        self.assertEqual(restored["id"], state["id"])
        self.assertTrue(restored["canUseCachedResults"])

    def test_chain_scan_without_vpn_connection_uses_only_loopback_fixture(self):
        self.setup_chain_scan()
        self.rpc.request("static-exit:set-enabled", {"enabled": False})
        self.rpc.close()
        port = self.server.server_port
        overrides = {"SPLITVPN_TEST_CHAIN_PROXY_URL": f"http://127.0.0.1:{port}/"}
        for kind in ["LATENCY", "DOWNLOAD", "IP"]:
            overrides[f"SPLITVPN_TEST_CHAIN_{kind}_URL"] = f"http://127.0.0.1:{port}/chain-{kind.lower()}"
        self.rpc = RPC(self.data, self.resources, overrides=overrides)
        self.rpc.request("static-exit:credential", {"configuration": json.loads((self.data / "settings.json").read_text())["staticExit"], "password": "fixture-only"})
        before = self.rpc.request("native:bootstrap")["status"]["mihomo"]
        self.rpc.request("chain-scan:start", {"mode": "full"})
        state = self.finish_chain_scan()
        self.assertEqual(state["completed"], 2)
        self.assertTrue(state["canUseCachedResults"])
        after = self.rpc.request("native:bootstrap")["status"]["mihomo"]
        self.assertGreater(after.pop("viewRevision"), before.pop("viewRevision"))
        self.assertEqual(after, before)
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, overrides=overrides)
        self.assertTrue(self.rpc.request("chain-scan:get")["canUseCachedResults"])

    def test_chain_scan_ranks_download_and_latency_without_switching_current_airport(self):
        self.setup_chain_scan()
        before = self.server.state["selected"]
        self.rpc.request("chain-scan:start", {"mode": "full"})
        state = self.finish_chain_scan()
        self.assertEqual(state["completed"], 2)
        self.assertFalse(state["stale"])
        self.assertEqual(self.server.state["selected"], before)
        self.assertEqual(self.server.state["selections"], [])
        fastest = state["results"][0]
        self.assertEqual(fastest["nodeName"], "node-b")
        latency = self.rpc.request("chain-scan:get", {"strategy": "latency"})
        self.assertEqual(latency["results"][0]["nodeName"], "node-a")
        chosen = self.rpc.request("chain-scan:connect", {"scanId": state["id"], "strategy": "download"})
        self.assertTrue(chosen["connected"])
        self.assertEqual(chosen["nodeName"], "node-b")
        self.assertEqual(chosen["exitIp"], "203.0.113.8")
        self.assertTrue(self.server.state["selections"])
        self.assertTrue(all(n == "node-b" for n in self.server.state["selections"]))
        self.server.state["selections"].clear()
        chosen = self.rpc.request("chain-scan:connect", {"scanId": state["id"], "strategy": "latency"})
        self.assertEqual(chosen["nodeName"], "node-a")
        self.assertEqual(self.server.state["selected"], "node-a")
        self.assertTrue(all(n == "node-a" for n in self.server.state["selections"]))

    def test_chain_balanced_is_default_and_connects_the_displayed_recommendation(self):
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "full"})
        self.finish_chain_scan()
        state = self.rpc.request("chain-scan:get")
        self.assertEqual(state["strategy"], "balanced")
        self.assertEqual(state["scorePolicy"]["downloadWeight"], 0.45)
        self.assertTrue(all(isinstance(r["balancedScore"], (int, float)) for r in state["results"]))
        self.assertGreaterEqual(state["results"][0]["balancedScore"], state["results"][1]["balancedScore"])
        recommended = next(r for r in state["results"] if r["identityKey"] == state["recommendedIdentityKey"])
        chosen = self.rpc.request("chain-scan:connect", {"scanId": state["id"]})
        self.assertEqual(chosen["nodeName"], recommended["nodeName"])
        self.assertEqual(chosen["exitIp"], "203.0.113.8")

    def test_comparison_exposes_distinct_leaders_ranks_and_connects_explicit_selection(self):
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "full"})
        state = self.finish_chain_scan("balanced")
        by_name = {r["nodeName"]: r for r in state["results"]}
        self.assertEqual(state["leaders"]["download"], by_name["node-b"]["identityKey"])
        self.assertEqual(state["leaders"]["latency"], by_name["node-a"]["identityKey"])
        self.assertEqual(state["leaders"]["balanced"], state["recommendedIdentityKey"])
        self.assertEqual([r["rank"] for r in state["results"]], [1, 2])
        download = self.rpc.request("chain-scan:get", {"strategy": "download"})
        self.assertEqual(download["results"][0]["nodeName"], "node-b")
        self.assertEqual(download["leaders"], state["leaders"])
        other = next(r for r in state["results"] if r["identityKey"] != state["recommendedIdentityKey"])
        result = self.rpc.request("chain-scan:connect", {"scanId": state["id"], "strategy": "balanced", "identityKey": other["identityKey"]})
        self.assertEqual(result["nodeName"], other["nodeName"])

    def test_targeted_retest_refreshes_one_route_without_losing_other_results(self):
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "full"})
        state = self.finish_chain_scan()
        rows = {r["nodeName"]: r for r in state["results"]}
        key = rows["node-a"]["identityKey"]
        payload = {"mode": "accumulate", "identityKeys": [key], "forceRetest": True}
        self.rpc.request("chain-scan:start", payload)
        state = self.finish_chain_scan()
        self.assertEqual(state["completed"], 1)
        rows2 = {r["nodeName"]: r for r in state["results"]}
        self.assertEqual(rows2["node-b"]["testedAt"], rows["node-b"]["testedAt"])
        self.assertEqual(rows2["node-a"]["observationCount"], 2)
        self.server.state["chain_wrong_ip"] = True
        self.rpc.request("chain-scan:start", payload)
        failed = self.finish_chain_scan()
        self.assertTrue(any(r["status"] != "available" for r in failed["results"]))
        self.server.state["chain_wrong_ip"] = False
        self.rpc.request("chain-scan:start", payload)
        recovered = self.finish_chain_scan()
        self.assertEqual(len(recovered["results"]), 2)
        self.assertTrue(all(r["status"] == "available" for r in recovered["results"]))
        self.assertEqual(len(self.rpc.request("chain-scan:history")["records"]), 5)
        for invalid in [{"forceRetest": True}, {"mode": "continuous", "identityKeys": [key], "forceRetest": True}, {"forceRetest": "yes"}]:
            self.rpc.request("chain-scan:start", invalid, ok=False)
        self.assertFalse(self.rpc.request("chain-scan:get")["running"])

    def test_subscription_full_retest_bypasses_cooldown_and_preserves_other_subscriptions(self):
        self.rpc.close()
        subscriptions = json.loads((self.data / "subscription.json").read_text())
        subscriptions["entries"].append({"id": "two", "name": "two", "url": "https://example.test/two", "enabled": True, "nodeCount": 1, "status": "ready"})
        (self.data / "subscription.json").write_text(json.dumps(subscriptions))
        provider = self.data / "mihomo/providers/two.yaml"
        provider.write_text(json.dumps({"proxies": [{"name": "node-c", "type": "http", "server": "127.0.0.1", "port": 9}]}))
        path = self.data / "mihomo/providers/subscription-manifest.json"
        manifest = json.loads(path.read_text())
        manifest["entries"].append({"subscriptionId": "two", "providerPath": str(provider), "providerRevision": hashlib.sha256(provider.read_bytes()).hexdigest()})
        path.write_text(json.dumps(manifest))
        self.rpc = RPC(self.data, self.resources, self.server.server_port)
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "full"})
        first = self.finish_chain_scan()
        self.assertEqual(len(first["results"]), 3)
        other = next(r for r in first["results"] if r["nodeName"] == "node-c")
        cache = self.data / "runtime-state/chain-scan-cache.json"
        before = cache.read_bytes()
        scoped = self.rpc.request("chain-scan:get", {"subscriptionId": "two"})["view"]
        self.assertEqual(scoped["subscriptionId"], "two")
        self.assertEqual([r["nodeName"] for r in scoped["results"]], ["node-c"])
        self.assertEqual(scoped["results"][0]["rank"], 1)
        self.assertTrue(all(key == other["identityKey"] for key in scoped["leaders"].values()))
        self.assertEqual(scoped["progress"]["total"], 1)
        self.assertEqual(scoped["progress"]["completed"], 1)
        self.assertEqual(cache.read_bytes(), before)
        self.assertEqual(self.rpc.request("chain-scan:get", {"subscriptionId": "unknown"})["view"]["results"], [])
        all_rows = self.rpc.request("chain-scan:get")["view"]["results"]
        self.assertEqual(len(all_rows), 3)
        self.assertTrue(all("comparisonReason" in r for r in all_rows))
        payload = {"mode": "accumulate", "subscriptionId": "one", "forceRetest": True}
        self.server.state["chain_wrong_ip"] = True
        self.rpc.request("chain-scan:start", payload)
        failed = self.finish_chain_scan()
        self.assertEqual(failed["completed"], 2)
        self.assertEqual(len(failed["candidateIdentityKeys"]), 2)
        self.server.state["chain_wrong_ip"] = False
        self.rpc.request("chain-scan:start", payload)
        done = self.finish_chain_scan()
        self.assertEqual(done["completed"], 2)
        self.assertTrue(all(r["status"] == "available" for r in done["results"]))
        kept = next(r for r in done["results"] if r["nodeName"] == "node-c")
        self.assertEqual(kept["testedAt"], other["testedAt"])
        self.assertEqual(kept["observationCount"], 1)
        self.assertEqual(len(self.rpc.request("chain-scan:history")["records"]), 7)
        for invalid in [{"subscriptionId": "unknown"}, {"subscriptionId": 1}, {"subscriptionId": ""},
                        {"subscriptionId": "one", "identityKeys": []}, {"subscriptionId": "one", "mode": "full"}]:
            self.rpc.request("chain-scan:start", invalid, ok=False)
        self.assertFalse(self.rpc.request("chain-scan:get")["running"])

    def test_routine_refresh_leaves_day_recent_results_idle_even_after_restart(self):
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1"})
        self.setup_chain_scan()
        self.rpc.request("native:runtime-environment", {"onBattery": True})
        self.rpc.request("chain-scan:start", {"mode": "full"})
        baseline = self.finish_chain_scan()
        calls = len(self.server.state["chain_requests"])
        self.rpc.request("chain-scan:auto-configure", {"enabled": True, "intervalMinutes": 30})
        self.rpc.request("native:runtime-environment", {"onBattery": False})
        time.sleep(0.4)
        state = self.rpc.request("chain-scan:get")
        self.assertEqual(state["id"], baseline["id"])
        self.assertFalse(state["running"])
        self.assertFalse(state["workerActive"])
        self.assertEqual(len(self.server.state["chain_requests"]), calls)
        error = self.rpc.request("chain-scan:start", {"mode": "continuous", "automatic": True}, ok=False)
        self.assertIn("无需自动重测", error["message"])
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1"})
        self.setup_chain_scan()
        self.rpc.request("native:runtime-environment", {"onBattery": False})
        time.sleep(0.4)
        state = self.rpc.request("chain-scan:get")
        self.assertEqual(state["id"], baseline["id"])
        self.assertFalse(state["running"])
        self.assertFalse(state["workerActive"])
        self.assertEqual({r["identityKey"]: r["testedAt"] for r in state["results"]},
                         {r["identityKey"]: r["testedAt"] for r in baseline["results"]})
        self.assertEqual(len(self.server.state["chain_requests"]), calls)
        self.assertEqual(len(self.rpc.request("chain-scan:history")["records"]), 2)

    def test_routine_refresh_measures_only_expired_routes_and_releases_worker(self):
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1"})
        self.setup_chain_scan()
        self.rpc.request("native:runtime-environment", {"onBattery": True})
        self.rpc.request("chain-scan:start", {"mode": "full"})
        baseline = self.finish_chain_scan()
        old = next(r for r in baseline["results"] if r["nodeName"] == "node-a")
        fresh = next(r for r in baseline["results"] if r["nodeName"] == "node-b")
        self.age_chain_results([old["identityKey"]], interval_ms=60000)
        calls = len(self.server.state["chain_requests"])
        self.rpc.request("chain-scan:auto-configure", {"enabled": True, "intervalMinutes": 30})
        self.rpc.request("native:runtime-environment", {"onBattery": False})
        state = self.wait_for_chain(lambda s: s.get("automatic") and not s["running"] and not s["workerActive"])
        self.assertEqual(state["completed"], 1)
        requests = self.server.state["chain_requests"][calls:]
        self.assertTrue(requests)
        self.assertEqual({node for _, node in requests}, {"node-a"})
        kept = next(r for r in state["results"] if r["identityKey"] == fresh["identityKey"])
        self.assertEqual(kept["testedAt"], fresh["testedAt"])
        self.assertEqual(kept["observationCount"], 1)
        self.assertTrue(all(not r["requiresRefresh"] for r in state["results"]))
        self.assertEqual(len(self.rpc.request("chain-scan:history")["records"]), 3)

    def test_routine_refresh_requires_baseline_and_respects_battery_and_batch_budget(self):
        self.rpc.close()
        provider = self.data / "mihomo/providers/one.yaml"
        provider.write_text(json.dumps({"proxies": [{"name": n, "type": "http", "server": "127.0.0.1", "port": 9} for n in ["node-a", "node-b", "node-c", "node-d"]]}))
        manifest_path = self.data / "mihomo/providers/subscription-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["entries"][0]["providerRevision"] = hashlib.sha256(provider.read_bytes()).hexdigest()
        manifest_path.write_text(json.dumps(manifest))
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1"})
        self.setup_chain_scan()
        self.rpc.request("static-exit:set-enabled", {"enabled": False})
        self.rpc.request("chain-scan:auto-configure", {"enabled": True, "intervalMinutes": 30})
        time.sleep(0.3)
        self.assertEqual(self.rpc.request("chain-scan:get")["autoRefresh"]["status"], "needs-baseline")
        self.assertFalse(self.rpc.request("chain-scan:get")["running"])
        self.rpc.request("native:runtime-environment", {"onBattery": True})
        self.rpc.request("chain-scan:start", {"mode": "full"})
        baseline = self.finish_chain_scan()
        self.assertEqual(baseline["completed"], 4)
        # A minute between manual samples must not keep the automatic engine idle.
        self.age_chain_results(interval_ms=60000)
        self.assertEqual(self.rpc.request("chain-scan:get")["autoRefresh"]["status"], "on-battery")
        calls = len(self.server.state["chain_requests"])
        time.sleep(0.4)
        self.assertEqual(len(self.server.state["chain_requests"]), calls)
        self.rpc.request("native:runtime-environment", {"onBattery": False})
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = self.rpc.request("chain-scan:get")
            if state.get("automatic") and not state["running"] and state.get("completed") == 3:
                break
            time.sleep(0.05)
        self.assertTrue(state.get("automatic"), state)
        self.assertFalse(state["running"])
        self.assertEqual(state["completed"], 3)
        calls = len(self.server.state["chain_requests"])
        time.sleep(0.4)
        self.assertEqual(len(self.server.state["chain_requests"]), calls)
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1"})
        self.setup_chain_scan()
        time.sleep(0.4)
        self.assertFalse(self.rpc.request("chain-scan:get")["running"])
        self.assertEqual(len(self.server.state["chain_requests"]), calls)
        self.rpc.request("chain-scan:auto-configure", {"enabled": False, "intervalMinutes": 30})

    def test_automatic_batch_preserves_previous_results_after_two_failures(self):
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1"})
        self.setup_chain_scan()
        self.rpc.request("native:runtime-environment", {"onBattery": True})
        self.rpc.request("chain-scan:start", {"mode": "full"})
        self.finish_chain_scan()
        baseline = self.age_chain_results()
        timestamps = {r["identityKey"]: r["testedAt"] for r in baseline["results"]}
        self.server.state["chain_wrong_ip"] = True
        self.rpc.request("chain-scan:auto-configure", {"enabled": True, "intervalMinutes": 30})
        self.rpc.request("native:runtime-environment", {"onBattery": False})
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = self.rpc.request("chain-scan:get")
            if state.get("automatic") and not state["running"] and state.get("completed") == 2 and state.get("autoRefresh", {}).get("status") == "network-uncertain":
                break
            time.sleep(0.05)
        self.assertEqual(state["completed"], 2, state)
        self.assertEqual(state["autoRefresh"]["status"], "network-uncertain")
        self.assertTrue(all(r["status"] == "available" and r["requiresRefresh"] for r in state["results"]))
        self.assertEqual({r["identityKey"]: r["testedAt"] for r in state["results"]}, timestamps)
        history = self.rpc.request("chain-scan:history")["records"]
        self.assertEqual(sum(r["observation"].get("environmentUncertain") is True for r in history), 2)

    def test_automatic_worker_stops_when_power_switches_to_battery(self):
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1"})
        self.setup_chain_scan()
        self.rpc.request("native:runtime-environment", {"onBattery": True})
        self.rpc.request("chain-scan:start", {"mode": "full"})
        self.finish_chain_scan()
        self.age_chain_results()
        self.server.state.update(blocked_path="/chain-latency", download_entered=threading.Event(), download_release=threading.Event())
        self.rpc.request("chain-scan:auto-configure", {"enabled": True, "intervalMinutes": 30})
        self.rpc.request("native:runtime-environment", {"onBattery": False})
        self.assertTrue(self.server.state["download_entered"].wait(10))
        self.rpc.request("native:runtime-environment", {"onBattery": True})
        self.server.state["download_release"].set()
        state = self.finish_chain_scan()
        self.assertEqual(state["completed"], 0)
        self.assertFalse(state["running"])
        self.assertEqual(state["autoRefresh"]["status"], "on-battery")
        self.assertEqual(len(self.rpc.request("chain-scan:history")["records"]), 2)

    def test_automatic_local_selector_failure_preserves_good_results(self):
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1"})
        self.setup_chain_scan()
        self.rpc.request("native:runtime-environment", {"onBattery": True})
        self.rpc.request("chain-scan:start", {"mode": "full"})
        self.finish_chain_scan()
        self.age_chain_results()
        self.server.state["chain_selector_failure"] = True
        self.rpc.request("chain-scan:auto-configure", {"enabled": True, "intervalMinutes": 30})
        self.rpc.request("native:runtime-environment", {"onBattery": False})
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = self.rpc.request("chain-scan:get")
            if state.get("automatic") and not state["running"] and state.get("completed") == 2:
                break
            time.sleep(0.05)
        self.assertEqual(state["completed"], 2, state)
        self.assertEqual(state["autoRefresh"]["status"], "network-uncertain")
        self.assertTrue(all(r["status"] == "available" and r["requiresRefresh"] for r in state["results"]))

    def test_new_subscription_does_not_trigger_automatic_first_measurement(self):
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1"})
        self.setup_chain_scan()
        self.rpc.request("native:runtime-environment", {"onBattery": True})
        self.rpc.request("chain-scan:start", {"mode": "full"})
        self.finish_chain_scan()
        self.age_chain_results()
        self.rpc.request("chain-scan:auto-configure", {"enabled": True, "intervalMinutes": 30})
        self.rpc.close()
        subscriptions_path = self.data / "subscription.json"
        subscriptions = json.loads(subscriptions_path.read_text())
        subscriptions["entries"].append({"id": "two", "name": "two", "url": "https://example.test/two", "enabled": True, "nodeCount": 1, "status": "ready"})
        subscriptions_path.write_text(json.dumps(subscriptions))
        provider = self.data / "mihomo/providers/two.yaml"
        provider.write_text(json.dumps({"proxies": [{"name": "node-c", "type": "http", "server": "127.0.0.1", "port": 9}]}))
        path = self.data / "mihomo/providers/subscription-manifest.json"
        manifest = json.loads(path.read_text())
        manifest["entries"].append({"subscriptionId": "two", "providerPath": str(provider), "providerRevision": hashlib.sha256(provider.read_bytes()).hexdigest()})
        path.write_text(json.dumps(manifest))
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1"})
        self.setup_chain_scan()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = self.rpc.request("chain-scan:get")
            if state.get("automatic") and not state["running"] and state.get("completed") == 2:
                break
            time.sleep(0.05)
        self.assertEqual(state["completed"], 2, state)
        self.assertEqual({r["nodeName"] for r in state["results"]}, {"node-a", "node-b"})
        self.assertNotIn("node-c", [node for _, node in self.server.state["chain_requests"]])

    def test_routine_refresh_waits_for_credentials_and_does_not_cancel_manual_test(self):
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1"})
        config = {"enabled": False, "protocol": "socks5", "server": "proxy.example.test", "port": 1080, "username": "fixture", "expectedIp": "203.0.113.8"}
        self.rpc.request("static-exit:configure", {"configuration": config, "password": "fixture-only"})
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_AUTO_REFRESH": "1"})
        self.rpc.request("chain-scan:auto-configure", {"enabled": True, "intervalMinutes": 10})
        time.sleep(0.3)
        self.assertEqual(self.rpc.request("chain-scan:get")["autoRefresh"]["status"], "needs-credential")
        self.assertFalse(self.rpc.request("chain-scan:get")["running"])
        self.rpc.request("chain-scan:auto-configure", {"enabled": False, "intervalMinutes": 10})
        self.setup_chain_scan()
        self.server.state.update(blocked_path="/chain-latency", download_entered=threading.Event(), download_release=threading.Event())
        started = self.rpc.request("chain-scan:start", {"mode": "full"})
        self.assertTrue(self.server.state["download_entered"].wait(5))
        self.rpc.request("chain-scan:auto-configure", {"enabled": False, "intervalMinutes": 60})
        self.assertEqual(self.rpc.request("chain-scan:get")["id"], started["id"])
        self.assertTrue(self.rpc.request("chain-scan:get")["running"])
        self.server.state["download_release"].set(); self.finish_chain_scan()
        for invalid in [{"enabled": True, "intervalMinutes": 7}, {"enabled": "yes", "intervalMinutes": 10}]:
            self.rpc.request("chain-scan:auto-configure", invalid, ok=False)

    def test_scan_progress_reports_real_stages_and_scope_without_mutating_task(self):
        self.setup_chain_scan()
        self.server.state.update(blocked_path="/chain-latency", download_entered=threading.Event(), download_release=threading.Event())
        started = self.rpc.request("chain-scan:start", {"mode": "full"})
        self.assertTrue(self.server.state["download_entered"].wait(5))
        snapshot = self.rpc.request("chain-scan:get", {"subscriptionId": "one"})
        progress = snapshot["view"]["progress"]
        self.assertEqual(progress["stage"], "latency")
        self.assertEqual(progress["stageAttempt"], 1)
        self.assertEqual(progress["total"], 2)
        self.assertEqual(progress["remaining"], 2)
        self.assertIsNone(progress["estimatedSeconds"])
        other = self.rpc.request("chain-scan:get", {"subscriptionId": "unknown"})
        self.assertEqual(other["view"]["progress"]["total"], 0)
        self.assertTrue(other["view"]["progress"]["testingOtherScope"])
        self.assertEqual(other["id"], started["id"])
        self.server.state["download_release"].set()
        done = self.finish_chain_scan()
        self.assertEqual(done["view"]["progress"]["completed"], 2)
        self.assertEqual(done["view"]["progress"]["remaining"], 0)
        self.assertIsNone(done["view"]["progress"]["stage"])
        self.assertIsNone(done["view"]["progress"]["estimatedSeconds"])

    def test_unreachable_nodes_stop_after_two_failed_latency_attempts(self):
        self.setup_chain_scan()
        self.server.state["chain_latency_failure"] = True
        self.rpc.request("chain-scan:start", {"mode": "full"})
        done = self.finish_chain_scan()
        self.assertEqual(len(self.server.state["chain_requests"]), 4)
        self.assertTrue(all(r["status"] == "unreachable" and r["latencyAttempts"] == 2 and r["downloadAttempts"] == 0 for r in done["results"]))
        self.assertIsNone(done["recommendedIdentityKey"])

    def test_failed_download_skips_redundant_second_download_and_keeps_partial_status(self):
        self.setup_chain_scan()
        self.server.state["chain_bad_size"] = True
        self.rpc.request("chain-scan:start", {"mode": "full"})
        done = self.finish_chain_scan()
        self.assertEqual(sum(path == "/chain-download" for path, _ in self.server.state["chain_requests"]), 2)
        self.assertTrue(all(r["status"] == "unstable" and r["downloadAttempts"] == 1 and r["latencySuccesses"] == 3 for r in done["results"]))
        self.assertIsNone(done["recommendedIdentityKey"])

    def test_chain_scan_rejects_wrong_exit_and_short_downloads(self):
        self.setup_chain_scan()
        self.server.state["chain_wrong_ip"] = True
        self.rpc.request("chain-scan:start", {"mode": "full"})
        state = self.finish_chain_scan()
        self.assertIsNone(state["recommendedIdentityKey"])
        self.rpc.request("chain-scan:connect", {"scanId": state["id"]}, ok=False)
        self.server.state["chain_wrong_ip"] = False
        self.server.state["chain_bad_size"] = True
        self.rpc.request("chain-scan:start", {"mode": "full"})
        state = self.finish_chain_scan()
        self.assertIsNone(state["recommendedIdentityKey"])
        self.assertTrue(all("download-failed" in r["errors"] for r in state["results"]))
        self.assertEqual(self.server.state["selections"], [])

    def test_chain_connect_revalidates_exit_and_rejects_stale_scan(self):
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "full"})
        state = self.finish_chain_scan()
        self.server.state["chain_wrong_ip"] = True
        self.rpc.request("chain-scan:connect", {"scanId": state["id"]}, ok=False)
        self.assertEqual(self.server.state["selections"], [])
        self.server.state["chain_wrong_ip"] = False
        self.rpc.request("routing:update", {"unknownTraffic": "vpn"})
        self.assertTrue(self.rpc.request("chain-scan:get")["stale"])
        self.rpc.request("chain-scan:connect", {"scanId": state["id"]}, ok=False)

    def test_chain_cancel_keeps_current_connection_and_disallows_partial_recommendation(self):
        self.setup_chain_scan()
        self.server.state.update(blocked_path="/chain-latency", download_entered=threading.Event(), download_release=threading.Event())
        before = self.server.state["selected"]
        self.rpc.request("chain-scan:start", {"mode": "full"})
        self.assertTrue(self.server.state["download_entered"].wait(5))
        self.assertTrue(self.rpc.request("chain-scan:get")["running"])
        self.rpc.request("chain-scan:cancel")
        self.server.state["download_release"].set()
        state = self.finish_chain_scan()
        self.assertTrue(state["cancelled"])
        self.assertEqual(self.server.state["selected"], before)
        self.rpc.request("chain-scan:connect", {"scanId": state["id"]}, ok=False)

    def wait_for_chain(self, predicate):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            state = self.rpc.request("chain-scan:get")
            if predicate(state):
                return state
            time.sleep(0.03)
        self.fail("background chain condition did not become true")

    def test_chain_accumulates_subsets_reuses_fresh_results_and_full_retest_replaces_them(self):
        self.setup_chain_scan()
        nodes = self.rpc.request("nodes:list")
        a = next(n["identityKey"] for n in nodes if n["name"] == "node-a")
        b = next(n["identityKey"] for n in nodes if n["name"] == "node-b")
        self.rpc.request("chain-scan:start", {"mode": "accumulate", "identityKeys": [a]})
        self.finish_chain_scan()
        first_count = len(self.server.state["chain_requests"])
        reply = self.rpc.request("chain-scan:start", {"mode": "accumulate", "identityKeys": [a]})
        self.assertEqual(reply["total"], 0)
        self.assertEqual(len(self.server.state["chain_requests"]), first_count)
        self.rpc.request("chain-scan:start", {"mode": "accumulate", "identityKeys": [b]})
        state = self.finish_chain_scan()
        self.assertEqual({r["nodeName"] for r in state["results"]}, {"node-a", "node-b"})
        self.assertTrue(state["canUseCachedResults"])
        self.rpc.request("chain-scan:start", {"mode": "full", "identityKeys": [b]})
        state = self.finish_chain_scan()
        self.assertEqual([r["nodeName"] for r in state["results"]], ["node-b"])
        self.assertEqual(state["results"][0]["observationCount"], 1)

    def test_failed_chain_is_cached_until_address_changes_or_full_retest(self):
        self.setup_chain_scan()
        self.server.state["chain_wrong_ip"] = True
        self.rpc.request("chain-scan:start", {"mode": "full"})
        self.finish_chain_scan()
        before = len(self.server.state["chain_requests"])
        self.server.state["chain_wrong_ip"] = False
        # Default mode reuses failures, including across a process restart.
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port)
        self.rpc.request("chain-scan:start")
        state = self.finish_chain_scan()
        self.assertEqual(state["completed"], 0)
        self.assertEqual(len(self.server.state["chain_requests"]), before)
        self.assertTrue(all(r["cachedSkip"] for r in state["results"]))
        # Continuous mode stays alive while all candidates are suppressed.
        self.rpc.request("chain-scan:start", {"mode": "continuous"})
        time.sleep(0.5)
        self.assertTrue(self.rpc.request("chain-scan:get")["running"])
        self.assertEqual(len(self.server.state["chain_requests"]), before)
        self.rpc.request("chain-scan:cancel")
        self.finish_chain_scan()
        # Explicit full retest bypasses failures and clears recovered entries.
        self.rpc.request("chain-scan:start", {"mode": "full"})
        state = self.finish_chain_scan()
        self.assertEqual(state["completed"], 2)
        self.assertTrue(all(r["status"] == "available" for r in state["results"]))

    def test_failed_nodes_automatically_return_after_cooldown_without_ip_change(self):
        self.setup_chain_scan()
        self.server.state["chain_wrong_ip"] = True
        self.rpc.request("chain-scan:start", {"mode": "full"})
        self.finish_chain_scan()
        self.rpc.close(); self.rpc = None
        path = self.data / "runtime-state/chain-scan-cache.json"
        cache = json.loads(path.read_text())
        retry = (datetime.now(timezone.utc) + timedelta(seconds=1)).isoformat()
        for row in cache["state"]["rejectedResults"]:
            row["nextRetryAt"] = retry
        path.write_text(json.dumps(cache))
        self.server.state["chain_wrong_ip"] = False
        self.rpc = RPC(self.data, self.resources, self.server.server_port)
        self.rpc.request("chain-scan:start", {"mode": "continuous"})
        state = self.wait_for_chain(lambda s: len(s["results"]) == 2 and all(r["status"] == "available" for r in s["results"]))
        self.assertTrue(all(r["failureStreak"] == 0 for r in state["results"]))
        self.rpc.request("chain-scan:cancel")
        self.finish_chain_scan()

    def test_history_survives_retests_environment_changes_restart_and_paginates(self):
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "full"})
        self.finish_chain_scan()
        first = self.rpc.request("chain-scan:history")
        self.assertEqual(len(first["records"]), 2)
        first_ids = {r["recordId"] for r in first["records"]}
        self.server.state["chain_wrong_ip"] = True
        self.rpc.request("chain-scan:start", {"mode": "full"})
        self.finish_chain_scan()
        self.rpc.request("routing:update", {"unknownTraffic": "vpn"})
        records = self.rpc.request("chain-scan:history")["records"]
        self.assertEqual(len(records), 4)
        self.assertTrue(first_ids.issubset({r["recordId"] for r in records}))
        self.assertFalse(any(r["sameEnvironment"] for r in records))
        self.assertEqual(sum(r["observation"]["status"] == "available" for r in records), 2)
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port)
        first_page = self.rpc.request("chain-scan:history", {"limit": 2})
        self.assertTrue(first_page["hasMore"])
        second_page = self.rpc.request("chain-scan:history", {"limit": 2, "before": first_page["nextBefore"]})
        self.assertFalse(second_page["hasMore"])
        self.assertEqual(len({r["recordId"] for r in first_page["records"] + second_page["records"]}), 4)
        for path in (self.data / "isp-tests/history").glob("*.json"):
            self.assertNotIn("fixture-only", path.read_text())
            self.assertNotIn("proxy.example.test", path.read_text())

    def test_existing_cache_migrates_once_into_long_term_history(self):
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "full"})
        self.finish_chain_scan()
        self.rpc.close(); self.rpc = None
        shutil.rmtree(self.data / "isp-tests")
        self.rpc = RPC(self.data, self.resources, self.server.server_port)
        self.assertEqual(len(self.rpc.request("chain-scan:history")["records"]), 2)
        self.rpc.close()
        # Simulate interruption after writing legacy rows but before migration marker.
        (self.data / "isp-tests/legacy-migrated.json").unlink()
        self.rpc = RPC(self.data, self.resources, self.server.server_port)
        self.assertEqual(len(self.rpc.request("chain-scan:history")["records"]), 2)

    def test_low_score_success_is_retested_after_expiration_even_with_legacy_cache(self):
        self.setup_chain_scan()
        self.server.state.update(chain_latency_delay=1.2, chain_download_delay=0.8)
        key = next(n["identityKey"] for n in self.rpc.request("nodes:list") if n["name"] == "node-a")
        self.rpc.request("chain-scan:start", {"mode": "full", "identityKeys": [key]})
        state = self.finish_chain_scan()
        self.assertEqual(state["results"][0]["status"], "available")
        self.assertLess(state["results"][0]["balancedScore"], 30)
        before = len(self.server.state["chain_requests"])
        self.rpc.close()
        self.rpc = None
        path = self.data / "runtime-state/chain-scan-cache.json"
        cache = json.loads(path.read_text())
        self.assertEqual(cache["state"]["rejectedResults"], [])
        # Simulate an older version that suppressed a successful low score.
        cache["state"]["rejectedResults"] = [dict(cache["state"]["results"][0])]
        for field in ["results", "rejectedResults"]:
            for row in cache["state"][field]:
                row["testedAt"] = "2000-01-01T00:00:00Z"
        path.write_text(json.dumps(cache))
        self.rpc = RPC(self.data, self.resources, self.server.server_port)
        self.rpc.request("chain-scan:start", {"identityKeys": [key]})
        state = self.finish_chain_scan()
        self.assertEqual(state["completed"], 1)
        self.assertEqual(state["results"][0]["status"], "available")
        self.assertNotEqual(state["results"][0]["testedAt"], "2000-01-01T00:00:00Z")
        self.assertEqual(state["results"][0]["observationCount"], 2)
        self.assertGreater(len(self.server.state["chain_requests"]), before)
        cache = json.loads(path.read_text())
        self.assertEqual(cache["state"]["rejectedResults"], [])

    def test_changed_proxy_address_unlocks_only_that_failed_node(self):
        self.setup_chain_scan()
        self.server.state["chain_wrong_ip"] = True
        self.rpc.request("chain-scan:start", {"mode": "full"})
        self.finish_chain_scan()
        self.server.state["chain_wrong_ip"] = False
        self.rpc.close()
        self.rpc = None
        path = self.data / "mihomo/providers/one.yaml"
        provider = json.loads(path.read_text())
        provider["proxies"][0]["server"] = "127.0.0.2"
        path.write_text(json.dumps(provider))
        manifest_path = self.data / "mihomo/providers/subscription-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["entries"][0]["providerRevision"] = hashlib.sha256(path.read_bytes()).hexdigest()
        manifest_path.write_text(json.dumps(manifest))
        self.rpc = RPC(self.data, self.resources, self.server.server_port)
        self.rpc.request("chain-scan:start")
        state = self.finish_chain_scan()
        self.assertEqual(state["completed"], 1)
        rows = {r["nodeName"]: r for r in state["results"]}
        self.assertEqual(rows["node-a"]["status"], "available")
        self.assertTrue(rows["node-b"]["cachedSkip"])

    def test_priority_retest_does_not_pause_and_bypasses_failed_cooldown(self):
        self.setup_chain_scan()
        self.server.state["chain_wrong_ip"] = True
        self.rpc.request("chain-scan:start", {"mode": "full"})
        first = self.finish_chain_scan()
        key = first["results"][0]["identityKey"]
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port, overrides={"SPLITVPN_TEST_CHAIN_INTERVAL_MS": "60000"})
        self.setup_chain_scan()
        self.server.state["chain_wrong_ip"] = False
        self.rpc.request("chain-scan:start", {"mode": "continuous"})
        state = self.wait_for_chain(lambda s: s["running"] and any(r.get("cachedSkip") for r in s["results"]))
        scan_id = state["id"]
        reply = self.rpc.request("chain-scan:prioritize", {"identityKey": key})
        self.assertTrue(reply["queued"])
        recovered = self.wait_for_chain(lambda s: any(r["identityKey"] == key and r["status"] == "available" for r in s["results"]))
        self.assertEqual(recovered["id"], scan_id)
        self.assertEqual(recovered["mode"], "continuous")
        self.assertTrue(recovered["running"])
        self.assertFalse(recovered["cancelled"])
        self.rpc.request("chain-scan:cancel")
        self.finish_chain_scan()
        self.assertEqual(self.rpc.request("chain-scan:get")["queuedIdentityKeys"], [])
        self.rpc.request("chain-scan:prioritize", {"identityKey": key}, ok=False)

    def test_full_scan_prioritizes_untested_node_without_duplicate_samples(self):
        self.assert_finite_priority("full")

    def test_accumulating_scan_prioritizes_untested_node_without_duplicate_samples(self):
        self.assert_finite_priority("accumulate")

    def assert_finite_priority(self, mode):
        self.setup_chain_scan()
        nodes = self.rpc.request("nodes:list")
        a = next(n["identityKey"] for n in nodes if n["name"] == "node-a")
        b = next(n["identityKey"] for n in nodes if n["name"] == "node-b")
        self.server.state.update(blocked_path="/chain-latency", download_entered=threading.Event(), download_release=threading.Event())
        self.rpc.request("chain-scan:start", {"mode": mode})
        self.assertTrue(self.server.state["download_entered"].wait(5))
        self.assertTrue(self.rpc.request("chain-scan:prioritize", {"identityKey": a})["alreadyTesting"])
        for _ in range(2): self.assertTrue(self.rpc.request("chain-scan:prioritize", {"identityKey": b})["queued"])
        self.assertEqual(self.rpc.request("chain-scan:get")["queuedIdentityKeys"], [b])
        self.server.state["download_release"].set()
        done = self.finish_chain_scan()
        self.assertEqual(done["completed"], 2)
        self.assertEqual(done["total"], 2)
        self.assertEqual({r["identityKey"] for r in done["results"]}, {a, b})
        self.assertEqual(done["stopReason"], "completed")
        self.assertEqual(done["queuedIdentityKeys"], [])

    def test_continue_unmeasured_subset_preserves_measured_result_and_history(self):
        self.setup_chain_scan()
        nodes = self.rpc.request("nodes:list")
        a = next(n["identityKey"] for n in nodes if n["name"] == "node-a")
        b = next(n["identityKey"] for n in nodes if n["name"] == "node-b")
        self.rpc.request("chain-scan:start", {"mode": "accumulate", "identityKeys": [a]})
        first = self.finish_chain_scan()
        self.assertEqual(len(first["results"]), 1)
        measured = first["results"][0]
        self.rpc.request("chain-scan:start", {"mode": "accumulate", "identityKeys": [b]})
        done = self.finish_chain_scan()
        self.assertEqual(done["completed"], 1)
        self.assertEqual(done["total"], 1)
        self.assertEqual({r["identityKey"] for r in done["results"]}, {a, b})
        kept = next(r for r in done["results"] if r["identityKey"] == a)
        self.assertEqual(kept["testedAt"], measured["testedAt"])
        self.assertEqual(kept["downloadMbps"], measured["downloadMbps"])
        records = self.rpc.request("chain-scan:history")["records"]
        self.assertEqual(len(records), 2)
        self.assertEqual({r["observation"]["identityKey"] for r in records}, {a, b})

    def test_priority_retest_deduplicates_and_honors_current_scope(self):
        self.setup_chain_scan()
        nodes = self.rpc.request("nodes:list")
        a = next(n["identityKey"] for n in nodes if n["name"] == "node-a")
        b = next(n["identityKey"] for n in nodes if n["name"] == "node-b")
        self.server.state.update(blocked_path="/chain-latency", download_entered=threading.Event(), download_release=threading.Event())
        self.rpc.request("chain-scan:start", {"mode": "continuous"})
        self.assertTrue(self.server.state["download_entered"].wait(5))
        self.assertTrue(self.rpc.request("chain-scan:prioritize", {"identityKey": a})["alreadyTesting"])
        for _ in range(2): self.rpc.request("chain-scan:prioritize", {"identityKey": b})
        self.assertEqual(self.rpc.request("chain-scan:get")["queuedIdentityKeys"], [b])
        self.rpc.request("chain-scan:prioritize", {"identityKey": "unknown"}, ok=False)
        self.server.state["download_release"].set()
        self.wait_for_chain(lambda s: s["completed"] >= 2)
        self.rpc.request("chain-scan:cancel"); self.finish_chain_scan()
        self.server.state["download_entered"].clear(); self.server.state["download_release"].clear()
        self.rpc.request("chain-scan:start", {"mode": "continuous", "identityKeys": [a]})
        self.assertTrue(self.server.state["download_entered"].wait(5))
        self.rpc.request("chain-scan:prioritize", {"identityKey": b}, ok=False)
        self.rpc.request("chain-scan:cancel"); self.server.state["download_release"].set(); self.finish_chain_scan()

    def test_chain_survives_duplicate_network_events_business_switches_and_sleep(self):
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "continuous"})
        first = self.wait_for_chain(lambda s: s["completed"] >= 1)
        for _ in range(4):
            self.rpc.request("native:network-changed", {"available": True})
        node = next(n for n in self.rpc.request("nodes:list") if n["name"] == "node-a")
        self.rpc.request("nodes:select-v2", {"identityKey": node["identityKey"]})
        self.rpc.request("static-exit:set-enabled", {"enabled": False})
        # Subscription refresh metadata can change even if all nodes are identical.
        manifest_path = self.data / "mihomo/providers/subscription-manifest.json"
        manifest = json.loads(manifest_path.read_text()); manifest["revision"] = "metadata-only-refresh"
        manifest_path.write_text(json.dumps(manifest))
        self.wait_for_chain(lambda s: s["completed"] > first["completed"] and s["running"])
        self.rpc.request("native:runtime-environment", {"sleeping": True})
        waiting = self.wait_for_chain(lambda s: s.get("waitingReason") == "sleeping")
        self.assertTrue(waiting["running"])
        count = len(self.server.state["chain_requests"])
        time.sleep(0.3)
        self.assertEqual(len(self.server.state["chain_requests"]), count)
        self.rpc.request("native:runtime-environment", {"sleeping": False})
        resumed = self.wait_for_chain(lambda s: s["completed"] > waiting["completed"])
        self.assertEqual(resumed.get("networkRestarts"), 0)
        self.rpc.request("chain-scan:cancel")
        self.assertEqual(self.finish_chain_scan()["stopReason"], "user-paused")

    def test_business_disconnect_request_does_not_cancel_independent_scanner(self):
        self.rpc.close()
        port = self.server.server_port
        overrides = {"SPLITVPN_TEST_CHAIN_PROXY_URL": f"http://127.0.0.1:{port}/"}
        for kind in ["LATENCY", "DOWNLOAD", "IP"]:
            overrides[f"SPLITVPN_TEST_CHAIN_{kind}_URL"] = f"http://127.0.0.1:{port}/chain-{kind.lower()}"
        self.rpc = RPC(self.data, self.resources, overrides=overrides)
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "continuous"})
        first = self.wait_for_chain(lambda s: s["completed"] >= 1)
        self.rpc.request("vpn:stop")
        self.assertEqual(self.rpc.request("native:bootstrap")["status"]["mihomo"]["state"], "stopped")
        self.wait_for_chain(lambda s: s["completed"] > first["completed"] and s["running"])
        self.rpc.request("chain-scan:cancel")
        self.assertEqual(self.finish_chain_scan()["stopReason"], "user-paused")

    def setup_chain_network_fixture(self):
        self.rpc.close()
        self.network_fixture = self.data / "test-network.json"
        self.network_fixture.write_text(json.dumps({"available": True, "signature": "network-a"}))
        self.rpc = RPC(self.data, self.resources, self.server.server_port,
                       overrides={"SPLITVPN_TEST_CHAIN_NETWORK_FILE": str(self.network_fixture)})
        self.setup_chain_scan()

    def test_chain_waits_for_network_and_rebases_results_without_losing_history(self):
        self.setup_chain_network_fixture()
        self.rpc.request("chain-scan:start", {"mode": "continuous"})
        self.wait_for_chain(lambda s: s["completed"] >= 1)
        self.network_fixture.write_text(json.dumps({"available": False}))
        waiting = self.wait_for_chain(lambda s: s.get("waitingReason") == "network-unavailable")
        self.assertTrue(waiting["running"])
        offline_history = self.rpc.request("chain-scan:history")["records"]
        self.assertTrue(offline_history)
        self.assertTrue(all(r["environmentKnown"] == False for r in offline_history))
        count = len(self.server.state["chain_requests"])
        time.sleep(0.3)
        self.assertEqual(len(self.server.state["chain_requests"]), count)
        self.network_fixture.write_text(json.dumps({"available": True, "signature": "network-b"}))
        resumed = self.wait_for_chain(lambda s: s.get("networkRestarts") == 1 and s["completed"] >= 1)
        self.assertTrue(resumed["running"])
        self.assertTrue(all(r["observationCount"] == 1 for r in resumed["results"]))
        history = self.rpc.request("chain-scan:history")["records"]
        self.assertTrue(any(r["sameEnvironment"] for r in history))
        self.assertTrue(any(not r["sameEnvironment"] for r in history))
        self.rpc.request("chain-scan:cancel")
        self.finish_chain_scan()

    def test_network_loss_mid_sample_requeues_full_scan_instead_of_finishing_it(self):
        self.setup_chain_network_fixture()
        self.server.state.update(blocked_path="/chain-latency", download_entered=threading.Event(), download_release=threading.Event())
        self.rpc.request("chain-scan:start", {"mode": "full"})
        self.assertTrue(self.server.state["download_entered"].wait(5))
        self.network_fixture.write_text(json.dumps({"available": False}))
        self.server.state["download_release"].set()
        waiting = self.wait_for_chain(lambda s: s.get("waitingReason") == "network-unavailable")
        self.assertEqual(waiting["completed"], 0)
        self.assertEqual(self.rpc.request("chain-scan:history")["records"], [])
        self.network_fixture.write_text(json.dumps({"available": True, "signature": "network-b"}))
        state = self.finish_chain_scan()
        self.assertEqual(state["stopReason"], "completed")
        self.assertFalse(state["cancelled"])
        self.assertEqual(state["completed"], 2)
        self.assertEqual(state["networkRestarts"], 1)
        self.assertEqual(len(self.rpc.request("chain-scan:history")["records"]), 2)

    def test_scanner_explains_configuration_stop_and_keeps_its_history(self):
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "continuous"})
        self.wait_for_chain(lambda s: s["completed"] >= 1)
        self.rpc.request("routing:update", {"unknownTraffic": "vpn"})
        state = self.finish_chain_scan()
        self.assertEqual(state["stopReason"], "configuration-changed")
        self.assertTrue(self.rpc.request("chain-scan:history")["records"])

    def test_continuous_chain_runs_without_view_polling_and_can_pause_then_connect(self):
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "continuous"})
        # No view or polling request drives this interval: the Rust job owns it.
        time.sleep(1.8)
        state = self.wait_for_chain(lambda s: s["completed"] >= 2 and s["canUseCachedResults"])
        self.assertTrue(state["running"])
        self.assertEqual(state["mode"], "continuous")
        first = state["completed"]
        state = self.wait_for_chain(lambda s: s["completed"] > first)
        self.assertTrue(any(r["observationCount"] > 1 for r in state["results"]))
        chosen = self.rpc.request("chain-scan:connect", {"scanId": state["id"]})
        self.assertTrue(chosen["connected"])
        self.assertTrue(self.rpc.request("chain-scan:get")["running"])
        self.rpc.request("chain-scan:cancel")
        state = self.finish_chain_scan()
        self.assertTrue(state["cancelled"])
        self.assertTrue(state["canUseCachedResults"])
        chosen = self.rpc.request("chain-scan:connect", {"scanId": state["id"]})
        self.assertTrue(chosen["connected"])
        paused_count = len(self.server.state["chain_requests"])
        time.sleep(0.4)
        self.assertEqual(len(self.server.state["chain_requests"]), paused_count)

    def test_chain_cache_restores_valid_results_and_contains_no_proxy_secret(self):
        self.setup_chain_scan()
        self.rpc.request("chain-scan:start", {"mode": "full"})
        before = self.finish_chain_scan()
        cache = (self.data / "runtime-state/chain-scan-cache.json").read_text()
        self.assertNotIn("fixture-only", cache)
        self.assertNotIn("proxy.example.test", cache)
        self.rpc.close()
        self.rpc = RPC(self.data, self.resources, self.server.server_port)
        state = self.rpc.request("chain-scan:get")
        self.assertFalse(state["running"])
        self.assertEqual(state["id"], before["id"])
        self.assertTrue(state["canUseCachedResults"])
        self.assertEqual(len(state["results"]), 2)
        # A result from earlier in the day remains current after restarting.
        self.rpc.close(); self.rpc = None
        path = self.data / "runtime-state/chain-scan-cache.json"
        saved = json.loads(path.read_text())
        earlier_today = (datetime.now(timezone.utc) - timedelta(hours=23)).isoformat()
        for row in saved["state"]["results"]:
            row["testedAt"] = earlier_today
        path.write_text(json.dumps(saved))
        self.rpc = RPC(self.data, self.resources, self.server.server_port)
        state = self.rpc.request("chain-scan:get", {"strategy": "download"})
        self.assertFalse(state["stale"])
        self.assertTrue(state["canUseCachedResults"])
        self.assertEqual(state["recommendedIdentityKey"], before["recommendedIdentityKey"])
        self.assertTrue(all(not r["requiresRefresh"] and r["testedAt"] == earlier_today for r in state["results"]))
        self.assertIn("最近 24 小时", state["recommendationSummary"])
        # Expiration is assessed per observation, not refreshed by restarting.
        self.rpc.close(); self.rpc = None
        path = self.data / "runtime-state/chain-scan-cache.json"
        saved = json.loads(path.read_text())
        for row in saved["state"]["results"]:
            row["testedAt"] = "2000-01-01T00:00:00Z"
        path.write_text(json.dumps(saved))
        self.rpc = RPC(self.data, self.resources, self.server.server_port)
        state = self.rpc.request("chain-scan:get")
        self.assertFalse(state["stale"])
        self.assertIsNotNone(state["recommendedIdentityKey"])
        self.assertTrue(all(r["requiresRefresh"] and r["balancedScore"] is not None for r in state["results"]))
        self.assertEqual(state["suggestedRefreshSeconds"], 86400)
        self.rpc.request("static-exit:credential", {"configuration": json.loads((self.data / "settings.json").read_text())["staticExit"], "password": "fixture-only"})
        before = self.server.state["selected"]
        self.server.state["chain_latency_failure"] = True
        self.rpc.request("chain-scan:connect", {"scanId": state["id"]}, ok=False)
        self.assertEqual(self.server.state["selected"], before)
        self.server.state["chain_latency_failure"] = False
        count = len(self.server.state["chain_requests"])
        self.rpc.request("chain-scan:connect", {"scanId": state["id"]})
        requests = self.server.state["chain_requests"][count:]
        self.assertTrue(any("chain-latency" in str(r) for r in requests))
        self.assertFalse(any("chain-download" in str(r) for r in requests))
        after = self.rpc.request("chain-scan:get")
        self.assertTrue(all(r["testedAt"] == "2000-01-01T00:00:00Z" for r in after["results"]))
        self.assertTrue(any(r.get("lastVerifiedAt") for r in after["results"]))
        self.rpc.request("chain-scan:start", {"mode": "accumulate"})
        self.assertEqual(self.finish_chain_scan()["completed"], 2)

    def test_static_exit_is_optional_and_credentials_are_not_in_settings(self):
        config = {"enabled": True, "protocol": "socks5", "server": "proxy.example.test", "port": 1080,
                  "username": "fixture", "expectedIp": "203.0.113.8"}
        self.assertFalse(self.rpc.request("static-exit:needs-credential"))
        parsed = self.rpc.request("static-exit:parse", {"line": "proxy.example.test:1080:fixture:fixture-only:colon"})
        self.assertEqual(parsed["password"], "fixture-only:colon")
        settings = self.rpc.request("static-exit:configure", {"configuration": config, "password": "fixture-only"})
        self.assertTrue(settings["staticExit"]["enabled"])
        persisted = (self.data / "settings.json").read_text()
        self.assertNotIn("fixture-only", persisted)
        self.assertNotIn("password", persisted)
        self.assertFalse(self.rpc.request("static-exit:needs-credential"))
        compiled = (self.data / "mihomo/config.yaml").read_text()
        self.assertIn("dialer-proxy: VPN", compiled)
        self.assertIn("__QZ_STATIC_EXIT__", compiled)
        before = (self.data / "settings.json").read_bytes()
        error = self.rpc.request("nodes:select", {"nodeName": "DIRECT"}, ok=False)
        self.assertIn("关闭静态出口", error["message"])
        self.assertEqual(before, (self.data / "settings.json").read_bytes())
        self.rpc.request("static-exit:test", ok=False)  # isolated: never contacts a real endpoint
        config["enabled"] = False
        self.rpc.request("static-exit:configure", {"configuration": config, "password": "fixture-only"})
        self.assertNotIn("__QZ_STATIC_EXIT__", (self.data / "mihomo/config.yaml").read_text())
        self.rpc.request("nodes:select", {"nodeName": "DIRECT"})

    def test_home_isp_toggle_preserves_configuration_and_reenables_with_credentials(self):
        config = {"enabled": True, "protocol": "socks5", "server": "proxy.example.test", "port": 1080, "username": "fixture", "expectedIp": "203.0.113.8"}
        self.rpc.request("static-exit:configure", {"configuration": config, "password": "fixture-only"})
        disabled = self.rpc.request("static-exit:set-enabled", {"enabled": False})
        self.assertEqual(disabled["staticExit"], dict(config, enabled=False))
        self.assertNotIn("__QZ_STATIC_EXIT__", (self.data / "mihomo/config.yaml").read_text())
        # Closing the ISP path must work without a credential in memory.
        self.rpc.request("static-exit:credential", {"configuration": config, "password": ""})
        self.rpc.request("static-exit:set-enabled", {"enabled": False})
        before = (self.data / "settings.json").read_bytes()
        self.rpc.request("static-exit:set-enabled", {"enabled": True}, ok=False)
        self.assertEqual(before, (self.data / "settings.json").read_bytes())
        self.rpc.request("static-exit:credential", {"configuration": config, "password": "fixture-only"})
        enabled = self.rpc.request("static-exit:set-enabled", {"enabled": True})
        self.assertEqual(enabled["staticExit"], config)
        self.assertNotIn("fixture-only", (self.data / "settings.json").read_text())
        self.assertIn("__QZ_STATIC_EXIT__", (self.data / "mihomo/config.yaml").read_text())

    def test_home_isp_toggle_rejects_missing_config_invalid_input_and_direct_front(self):
        before = (self.data / "settings.json").read_bytes()
        self.rpc.request("static-exit:set-enabled", {"enabled": True}, ok=False)
        self.rpc.request("static-exit:set-enabled", {"enabled": "true"}, ok=False)
        self.rpc.request("static-exit:set-enabled", {"enabled": False, "password": "forbidden"}, ok=False)
        self.assertEqual(before, (self.data / "settings.json").read_bytes())
        config = {"enabled": False, "protocol": "socks5", "server": "proxy.example.test", "port": 1080, "username": "fixture", "expectedIp": ""}
        self.rpc.request("static-exit:configure", {"configuration": config, "password": "fixture-only"})
        self.rpc.request("nodes:select", {"nodeName": "DIRECT"})
        error = self.rpc.request("static-exit:set-enabled", {"enabled": True}, ok=False)
        self.assertIn("机场节点", error["message"])
        self.assertFalse(self.rpc.request("routing:get-state")["settings"]["staticExit"]["enabled"])

    def test_static_exit_failed_reload_restores_previous_configuration(self):
        config = {"enabled": True, "protocol": "http", "server": "proxy.example.test", "port": 1080,
                  "username": "fixture", "expectedIp": ""}
        self.rpc.request("static-exit:configure", {"configuration": config, "password": "fixture-only"})
        before = {name: (self.data / name).read_bytes() for name in ["settings.json", "mihomo/config.yaml"]}
        self.server.state["reload_failure"] = True
        config["server"] = "other.example.test"
        self.rpc.request("static-exit:configure", {"configuration": config, "password": "other-fixture"}, ok=False)
        for name, contents in before.items():
            self.assertEqual(contents, (self.data / name).read_bytes())
        self.assertFalse(self.rpc.request("static-exit:needs-credential"))

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

    def wait_traffic_sample(self):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            traffic = self.rpc.request("traffic:get-monitor")
            if traffic["snapshot"] is not None:
                return traffic
            time.sleep(0.05)
        self.fail("background traffic sample missing")

    def test_slow_latency_does_not_block_bootstrap_or_stop_and_cannot_commit(self):
        entered, release = threading.Event(), threading.Event()
        self.server.state.update(blocked_path="/proxies/node-a/delay", download_entered=entered, download_release=release)
        self.rpc.process.stdin.write(json.dumps({"id": "slow-latency", "channel": "nodes:test", "payload": {"nodeName": "node-a"}}) + "\n")
        self.rpc.process.stdin.flush()
        self.assertTrue(entered.wait(5), "latency fixture was not reached")
        try:
            started = time.monotonic()
            self.assertEqual(self.rpc.request("native:bootstrap")["status"]["mihomo"]["state"], "running")
            stopped = self.rpc.request("vpn:stop", ok=False)
            self.assertIn("未停止其他内核", stopped["message"])
            self.assertLess(time.monotonic() - started, 1.5)
            self.assertFalse(release.is_set())
        finally:
            release.set()
        while True:
            reply = self.rpc.lines.get(timeout=5)
            if reply.get("id") == "slow-latency":
                self.assertTrue(reply["ok"], reply)
                self.assertEqual(reply["data"]["status"], "runtime-changed")
                break
            self.rpc.events.append(reply)
        self.assertFalse((self.data / "runtime-state/speed-cache.json").exists())

    def test_slow_controller_sample_does_not_block_cached_reads_or_stop(self):
        entered, release = threading.Event(), threading.Event()
        self.server.state.update(blocked_path="/connections", download_entered=entered, download_release=release)
        self.assertTrue(entered.wait(5), "background sampler did not reach controller")
        try:
            started = time.monotonic()
            self.rpc.request("native:bootstrap")
            self.rpc.request("vpn:get-status")
            self.rpc.request("traffic:get-monitor")
            self.rpc.request("vpn:stop", ok=False)
            self.assertLess(time.monotonic() - started, 1.5)
            self.assertFalse(release.is_set())
        finally:
            release.set()

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
        self.assertEqual(blocked["chatgpt"]["failureReason"], "restricted")
        self.assertIn("403", blocked["error"])

    def test_cached_read_failures_do_not_return_successful_historical_snapshots(self):
        original = (self.data / "settings.json").read_bytes()
        before = self.rpc.request("native:bootstrap")
        try:
            (self.data / "settings.json").write_text("{broken-fixture")
            self.rpc.request("native:runtime-environment", {"visible": False})
            error = self.rpc.request("native:bootstrap", ok=False)
            self.assertIn("settings.json", error["message"])
            self.rpc.request("vpn:get-status", ok=False)
            self.rpc.request("traffic:get-monitor")
            self.rpc.request("diagnostics:get-state")
        finally:
            (self.data / "settings.json").write_bytes(original)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            reply = self.rpc.request("native:bootstrap", ok=None)
            if reply["ok"]:
                after = reply["data"]
                break
            time.sleep(0.05)
        else:
            self.fail("normal refresh did not notice the repaired configuration")
        self.assertGreater(after["viewRevision"], before["viewRevision"])
        risk_cache = self.data / "ipdata-risk-cache.json"
        risk_cache.write_text("{broken-fixture")
        try:
            self.rpc.request("native:runtime-environment", {"visible": True})
            self.rpc.request("native:bootstrap", ok=False)
            self.rpc.request("vpn:get-status")
            self.rpc.request("nodes:list")
            self.rpc.request("traffic:get-monitor")
        finally:
            risk_cache.unlink()

    def test_node_changes_are_pushed_without_bootstrap_polling_and_unchanged_nodes_stay_quiet(self):
        self.rpc.request("native:runtime-environment", {"visible": False})
        self.server.state["node_histories"] = {"node-a":[{"time":datetime.now(timezone.utc).isoformat(),"delay":33}]}
        self.rpc.request("native:runtime-environment", {"visible": True})
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            nodes = self.rpc.request("nodes:list")
            if next(node for node in nodes if node["name"] == "node-a").get("delay") == 33:
                break
            time.sleep(0.05)
        else:
            self.fail("updated engine measurements were not published")
        self.rpc.request("core:capabilities")
        updates = [event for event in self.rpc.events if event.get("event") == "nodes:updated"]
        self.assertTrue(any(any(node.get("delay") == 33 for node in event["data"].get("nodes",[]) or []) for event in updates))
        count = len(updates)
        for _ in range(5): self.rpc.request("native:runtime-environment", {"visible": True})
        self.assertEqual(len([event for event in self.rpc.events if event.get("event") == "nodes:updated"]), count)

    def test_provider_catalog_invalidates_after_content_or_subscription_metadata_change(self):
        self.rpc.request("nodes:list")
        provider = self.data / "mihomo/providers/one.yaml"
        document = json.loads(provider.read_text())
        document["proxies"][0]["name"] = "node-z"
        provider.write_text(json.dumps(document))
        self.rpc.request("native:runtime-environment", {"visible": False})
        nodes = self.rpc.request("nodes:list")
        self.assertIn("node-z", [node["name"] for node in nodes])
        self.assertNotIn("node-a", [node["name"] for node in nodes])
        subscription = self.data / "subscription.json"
        document = json.loads(subscription.read_text())
        document["entries"][0]["name"] = "Renamed Fixture"
        subscription.write_text(json.dumps(document))
        self.rpc.request("native:runtime-environment", {"visible": True})
        self.assertTrue(all(node["subscriptionName"] == "Renamed Fixture" for node in self.rpc.request("nodes:list") if node["name"] != "DIRECT"))

    def test_current_exit_risk_uses_the_isp_listener_and_does_not_overwrite_airport_risks(self):
        self.setup_chain_scan()
        configuration = (self.data / "mihomo/config.yaml").read_text()
        port = int(re.search(r"name: static-exit-check[\s\S]*?\bport: (\d+)", configuration).group(1))
        isp = http.server.ThreadingHTTPServer(("127.0.0.1", port), Controller)
        isp.state = dict(self.server.state, requests=[], probes=[], risk_ip="203.0.113.8")
        thread = threading.Thread(target=isp.serve_forever, daemon=True); thread.start()
        try:
            self.rpc.request("native:risk-key", {"apiKey":"fixture-only"})
            exit_risk = self.rpc.request("nodes:check-current-risk")
            self.assertEqual(exit_risk["ip"], "203.0.113.8")
            self.assertTrue(exit_risk["viaStaticExit"])
            self.assertEqual(exit_risk["scope"], "current-exit")
            self.assertEqual(self.server.state["probes"], [])
            self.assertTrue(isp.state["requests"])
            node_risk = self.rpc.request("nodes:check-risk", {"nodeName":"node-a"})
            self.assertEqual(node_risk["ip"], "203.0.113.9")
            snapshot = self.rpc.request("native:bootstrap")
            self.assertEqual(snapshot["currentExitRisk"]["ip"], "203.0.113.8")
            self.assertEqual(snapshot["risks"][0]["ip"], "203.0.113.9")
            self.assertTrue((self.data / "current-exit-risk-cache.json").is_file())
            self.rpc.request("native:network-changed", {"available":True})
            self.assertIsNone(self.rpc.request("native:bootstrap")["currentExitRisk"])
            self.assertTrue((self.data / "current-exit-risk-cache.json").is_file())
        finally:
            isp.shutdown(); isp.server_close(); thread.join(timeout=2)

    def test_manual_check_updates_shared_schedule_and_time_without_shape_breakage(self):
        result = self.rpc.request("connectivity:check")
        self.assertIn("connectivity", result)
        state = self.rpc.request("diagnostics:get-state")
        record = state["connectivity"]
        self.assertEqual(record["state"], "ready")
        self.assertEqual(record["source"], "manual")
        self.assertTrue(record["checkedAt"])
        self.assertEqual(record["result"]["connectivity"], result["connectivity"])
        self.assertEqual(record["intervalSeconds"], 300)

    def test_recommended_latency_uses_three_distinct_targets(self):
        result = self.rpc.request("nodes:test-recommended", {"identityKey": "v1:one:node-a"})
        self.assertEqual(len(set(self.server.state["delay_urls"])), 3)
        self.assertEqual(len(result["samples"]), 3)
        self.assertEqual(result["status"], "available")

    def test_website_restriction_is_not_reported_as_a_connection_timeout(self):
        self.server.state["health_status"] = 403
        result = self.rpc.request("connectivity:test-website-speeds")
        self.assertTrue(result["checkedAt"])
        self.assertEqual(len(result["results"]), 3)
        for site in result["results"]:
            self.assertEqual(site["httpStatus"], 403)
            self.assertEqual(site["failureReason"], "restricted")
        state = self.rpc.request("diagnostics:get-state")
        self.assertEqual(state["websites"]["state"], "ready")
        self.assertTrue(state["websites"]["checkedAt"])

    def test_website_probes_start_together_and_preserve_site_order(self):
        self.server.state["health_barrier"] = threading.Barrier(3)
        try:
            result = self.rpc.request("connectivity:test-website-speeds")
        finally:
            self.server.state.pop("health_barrier", None)
        self.assertEqual([site["id"] for site in result["results"]], ["google", "chatgpt", "claude"])
        self.assertTrue(all(site["ok"] for site in result["results"]))

    def test_timeout_is_not_zero_latency_and_includes_a_timestamp(self):
        self.server.state["delay_timeout"] = True
        result = self.rpc.request("nodes:test", {"nodeName": "node-a"})
        self.assertEqual(result["status"], "timeout")
        node = next(n for n in self.rpc.request("nodes:list") if n["name"] == "node-a")
        self.assertIsNone(node["delay"])
        self.assertEqual(node["latencyStatus"], "timeout")
        self.assertTrue(node["latencyCheckedAt"])

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
        self.assertEqual(self.wait_traffic_sample()["snapshot"]["connections"][0]["id"], "kept-company-connection")
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

    def test_mailmaster_direct_toggle_preserves_other_compatibility_choices(self):
        before = self.rpc.request("vpn:get-status")
        prior = before["settings"]["specialCompatibilityRules"]
        pid = before["mihomo"]["pid"]
        for enabled in [True, False, True]:
            result = self.rpc.request("routing:update", {"specialCompatibilityRules": {"mailMasterDirect": enabled}})
            choices = result["specialCompatibilityRules"]
            self.assertEqual(choices["mailMasterDirect"], enabled)
            for key in ["mailMasterProxy8081", "wechatImageSendFallback"]:
                self.assertEqual(choices[key], prior[key])
            generated = self.server.state["reloads"][-1]
            self.assertEqual("PROCESS-NAME,MailMaster,DIRECT" in generated, enabled)
            self.assertEqual(self.rpc.request("vpn:get-status")["mihomo"]["pid"], pid)
        saved = json.loads((self.data / "settings.json").read_text())
        self.assertTrue(saved["specialCompatibilityRules"]["mailMasterDirect"])

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
        probes = len(self.server.state["probes"])
        result = self.rpc.request("nodes:test-udp", {"nodeName": "node-a"})
        self.assertFalse(result["supported"])
        self.assertEqual(len(self.server.state["selections"]), count)
        self.assertEqual(len(self.server.state["probes"]), probes)

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
        self.assertEqual(self.wait_traffic_sample()["snapshot"]["connections"][0]["id"], "kept-company-connection")

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
