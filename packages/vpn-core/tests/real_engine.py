#!/usr/bin/env python3
"""Run a real Mihomo through the Rust process, with TUN/DNS and probes disabled."""
import base64
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import platform
import re
import tempfile
import threading
import time
import unittest

from rpc_integration import ROOT, RPC


class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/subscription":
            self.server.download_entered.set()
            self.server.download_release.wait(10)
            if self.server.metadata_subscription:
                text = "STATUS=fixture status\nREMARKS=fixture: 東京\n" + "\n".join(f"http://127.0.0.1:{self.server.server_port}?udp=false#{n}" for n in ["fixture-a", "fixture-b"]) + "\n"
                body = base64.b64encode(text.encode())
            else:
                body = json.dumps({"proxies": [{"name": n, "type": "http", "server": "127.0.0.1", "port": self.server.server_port, "udp": False} for n in ["fixture-a", "fixture-b"]]}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/stream":
            self.send_response(200)
            self.send_header("Content-Length", "12")
            self.end_headers()
            self.wfile.write(b"f")
            self.wfile.flush()
            self.server.release.wait(20)
            self.wfile.write(b"ixture-body")
        else:
            self.send_response(404)
            self.end_headers()


class RealEngineTests(unittest.TestCase):
    def test_start_reload_keeps_open_stream_and_stop_reaps_owned_process(self):
        self.run_stream_fixture(False)

    def test_metadata_subscription_reloads_through_real_mihomo_without_stream_loss(self):
        self.run_stream_fixture(True)

    def test_startup_connects_saved_node_and_manual_stop_is_not_undone(self):
        self.run_stream_fixture(False, startup=True)

    def test_slow_download_allows_stop_and_cannot_restart_engine(self):
        self.run_stream_fixture(False, slow_stop=True)

    def run_stream_fixture(self, metadata_subscription, startup=False, slow_stop=False):
        arch = "darwin-arm64" if platform.machine() == "arm64" else "darwin-x64"
        mihomo = Path(os.environ.get("SPLITVPN_TEST_MIHOMO", ROOT / f"resources/mihomo/{arch}/mihomo"))
        self.assertTrue(mihomo.is_file(), "bundled Mihomo missing")
        with tempfile.TemporaryDirectory(prefix="splitvpn-rust-real-") as temp:
            root = Path(temp)
            data = root / "data"
            resources = root / "resources"
            resources.mkdir()
            (resources / "mihomo").symlink_to(mihomo)
            (resources / "geodata").symlink_to(ROOT / "resources/mihomo/geodata", target_is_directory=True)
            def save(name, value):
                p = data / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(json.dumps(value))
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
            server.metadata_subscription = metadata_subscription
            server.release = threading.Event()
            server.download_entered = threading.Event()
            server.download_release = threading.Event()
            server.download_release.set()
            threading.Thread(target=server.serve_forever, daemon=True).start()
            port = server.server_port
            save("settings.json", {"settingsVersion": 10, "selectedProxy": "fixture-a" if startup else "DIRECT", "tun": True, "vpnDomainRules": ["DOMAIN-SUFFIX,fixture.invalid"], "nodeGroups": []})
            save("subscription.json", {"entries": [{"id": "one", "name": "one", "url": f"http://127.0.0.1:{port}/subscription", "nodeCount": 1, "enabled": True, "status": "ready", "updateIntervalMinutes": None}]})
            save("mihomo/providers/one.yaml", {"proxies": [{"name": "fixture-a", "type": "http", "server": "127.0.0.1", "port": port, "udp": False}]})
            provider = data / "mihomo/providers/one.yaml"
            save("mihomo/providers/subscription-manifest.json", {"schemaVersion": 1, "revision": "fixture", "entries": [{"subscriptionId": "one", "providerPath": str(provider), "providerRevision": hashlib.sha256(provider.read_bytes()).hexdigest()}]})
            rpc = RPC(data, resources)
            connection = None
            try:
                settings_before = (data / "settings.json").read_bytes()
                if startup:
                    bootstrap = rpc.request("native:bootstrap")
                    self.assertEqual(bootstrap["status"]["mihomo"]["state"], "stopped")
                    self.assertFalse((data / "mihomo/config.yaml").exists())
                started = rpc.request("native:startup-connect" if startup else "vpn:start")
                self.assertTrue(started["controllerOk"])
                pid = started["mihomo"]["pid"]
                if startup:
                    self.assertEqual(started["startupOutcome"], "connected")
                    self.assertEqual((data / "settings.json").read_bytes(), settings_before)
                    reused = rpc.request("native:startup-connect")
                    self.assertEqual(reused["startupOutcome"], "already-attempted")
                    self.assertEqual(reused["mihomo"]["pid"], pid)
                    controller = http.client.HTTPConnection("127.0.0.1", started["runtimePorts"]["externalControllerPort"], timeout=5)
                    try:
                        controller.request("GET", "/proxies/VPN")
                        result = controller.getresponse()
                        self.assertEqual(result.status, 200)
                        self.assertEqual(json.loads(result.read())["now"], "fixture-a")
                        # Node checks use the PROBE selector and its own inbound.
                        for name in ["fixture-a", "DIRECT"]:
                            controller.request("PUT", "/proxies/PROBE", json.dumps({"name": name}), {"Content-Type": "application/json"})
                            reply = controller.getresponse()
                            body = reply.read()
                            self.assertEqual(reply.status, 204, (name, body))
                        controller.request("GET", "/proxies/VPN")
                        self.assertEqual(json.loads(controller.getresponse().read())["now"], "fixture-a")
                    finally:
                        controller.close()
                    text = (data / "mihomo/config.yaml").read_text()
                    probe_port = int(re.search(r"- name: probe-in\n(?:  .*\n)*?  port: (\d+)", text).group(1))
                    probe = http.client.HTTPConnection("127.0.0.1", probe_port, timeout=5)
                    try:
                        probe.request("GET", f"http://127.0.0.1:{port}/subscription")
                        self.assertEqual(probe.getresponse().status, 200)
                    finally:
                        probe.close()
                self.assertNotIn(started["runtimePorts"]["externalControllerPort"], [9090, 9091])
                config = (data / "mihomo/config.yaml").read_text()
                self.assertIn("tun:\n  enable: false", config)
                self.assertIn("dns:\n  enable: false", config)
                connection = http.client.HTTPConnection("127.0.0.1", started["runtimePorts"]["mixedPort"], timeout=15)
                connection.request("GET", f"http://127.0.0.1:{port}/stream")
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                before = rpc.request("traffic:get-monitor")["snapshot"]["connections"]
                self.assertTrue(before, "loopback connection missing")
                if slow_stop:
                    server.download_release.clear()
                    server.download_entered.clear()
                    rpc.process.stdin.write(json.dumps({"id":"slow-download", "channel":"subscription:update", "payload":{"id":"one"}}) + "\n")
                    rpc.process.stdin.flush()
                    self.assertTrue(server.download_entered.wait(3))
                    start = time.monotonic()
                    self.assertEqual(rpc.request("vpn:get-status")["mihomo"]["pid"], pid)
                    self.assertEqual(rpc.request("vpn:stop")["state"], "stopped")
                    self.assertLess(time.monotonic() - start, 2)
                    self.assertFalse(server.download_release.is_set())
                    server.download_release.set()
                    pending = next((e for e in rpc.events if e.get("id") == "slow-download"), None)
                    while pending is None:
                        value = rpc.lines.get(timeout=5)
                        if value.get("id") == "slow-download":
                            pending = value
                        else:
                            rpc.events.append(value)
                    self.assertTrue(pending["ok"], pending)
                    self.assertEqual(rpc.request("vpn:get-status")["mihomo"]["state"], "stopped")
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
                    return
                rpc.request("subscription:update", {"id": "one"})
                self.assertEqual(rpc.request("vpn:get-status")["mihomo"]["pid"], pid)
                after = rpc.request("traffic:get-monitor")["snapshot"]["connections"]
                self.assertTrue(set(c["id"] for c in before) & set(c["id"] for c in after), "reload discarded the open stream")
                server.release.set()
                self.assertEqual(response.read(), b"fixture-body")
                names = [n["name"] for n in rpc.request("nodes:list")]
                self.assertIn("fixture-b", names)
                stopped = rpc.request("vpn:stop")
                self.assertEqual(stopped["state"], "stopped")
                if startup:
                    repeated = rpc.request("native:startup-connect")
                    self.assertEqual(repeated["startupOutcome"], "already-attempted")
                    self.assertEqual(repeated["mihomo"]["state"], "stopped")
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
            finally:
                server.release.set()
                server.download_release.set()
                if connection:
                    connection.close()
                rpc.close()
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
