#!/usr/bin/env python3
"""Generated Android config against host mihomo; loopback HTTP only, no TUN/VPN.

Build the host bridge first:
  cargo rustc --manifest-path packages/vpn-core/Cargo.toml --locked --lib --crate-type cdylib
"""
import argparse
import ctypes
import http.client
import json
import re
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, urlsplit


ROOT = Path(__file__).resolve().parents[3]


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core-library", type=Path, default=ROOT / "packages/vpn-core/target/debug/libsplitvpn_core.dylib")
    parser.add_argument("--mihomo", type=Path, default=ROOT / "resources/mihomo/darwin-arm64/mihomo")
    args = parser.parse_args()
    library = ctypes.CDLL(str(args.core_library.resolve()))
    library.qz_core_call.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    library.qz_core_call.restype = ctypes.c_void_p
    library.qz_core_free.argtypes = [ctypes.c_void_p]
    counts = {"health": 0, "forward": 0}
    lock = threading.Lock()

    class Proxy(BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlsplit(self.path).path
            health = path == "/health"
            with lock:
                counts["health" if health else "forward"] += 1
            if path == "/probe":
                time.sleep(0.02)  # Keep Mihomo's millisecond delay strictly positive.
            body = b"" if health else b"forwarded"
            self.send_response(204 if health else 200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_CONNECT(self):
            # Mihomo's HTTP outbound uses CONNECT even for plaintext traffic.
            # Terminate the tunnel here instead of opening its destination.
            self.send_response(200)
            self.end_headers()
            request_line = self.rfile.readline().decode().split()
            if len(request_line) < 2:
                return
            while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                pass
            path = urlsplit(request_line[1]).path
            health = path == "/health"
            with lock:
                counts["health" if health else "forward"] += 1
            if path == "/probe":
                time.sleep(0.02)
            body = b"" if health else b"forwarded"
            status = b"204 No Content" if health else b"200 OK"
            self.wfile.write(b"HTTP/1.1 " + status + b"\r\nContent-Length: " + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
            self.close_connection = True

        def log_message(self, *_):
            pass

    proxy = ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    proxy.daemon_threads = True
    threading.Thread(target=proxy.serve_forever, daemon=True).start()
    process = None
    try:
        with tempfile.TemporaryDirectory(prefix="qingzhou-probe-policy-") as temporary:
            root = Path(temporary)

            def call(channel, payload):
                pointer = library.qz_core_call(str(root).encode(), json.dumps({"channel": channel, "payload": payload}).encode())
                try:
                    reply = json.loads(ctypes.string_at(pointer))
                finally:
                    library.qz_core_free(pointer)
                assert reply["ok"], reply
                return reply["data"]

            subscription = call("subscription:save", {"name": "fixture", "url": "https://example.test/sub"})["entries"][0]["id"]
            plan = call("subscription:plan", {"id": subscription})
            provider = "proxies:\n" + "".join(
                f"  - {{name: fixture-{name}, type: http, server: 127.0.0.1, port: {proxy.server_port}}}\n"
                for name in ("a", "b")
            )
            call("subscription:accept", {"id": subscription, "token": plan["token"], "index": 0, "status": 200, "content": provider})
            mixed, controller = free_port(), free_port()

            def generate(selected, baseline=False):
                call("settings:patch", {"selectedProxy": selected, "unknownTraffic": "vpn"})
                result = call("mihomo:generate", {"mixedPort": mixed, "controllerPort": controller})
                path = Path(result["config"])
                config = path.read_text()
                assert re.search(r"tun:\n  enable: false", config), "Fixture must never establish TUN"
                # All traffic is handled by our loopback proxy. Replace only the
                # test URL and fixture routing; no real DNS, geodata or websites.
                config = config.replace("https://www.gstatic.com/generate_204", "http://198.18.0.10/health")
                config = config.replace("dns:\n  enable: true", "dns:\n  enable: false")
                config = config.replace("sniffer:\n  enable: true", "sniffer:\n  enable: false")
                config = re.sub(r"(?m)^rules:\n[\s\S]*", "rules:\n- MATCH,VPN\n", config)
                # Compress the automatic/baseline interval for this test only.
                config = re.sub(r"interval: (300|900)\b", "interval: 1", config)
                if baseline:
                    config = config.replace("health-check:\n      enable: false", "health-check:\n      enable: true")
                    config = config.replace("interval: 0", "interval: 1")
                path.write_text(config)
                return result

            def request(path, method="GET", body=None):
                connection = http.client.HTTPConnection("127.0.0.1", controller, timeout=3)
                try:
                    headers = {"Authorization": "Bearer " + result["secret"], "Content-Type": "application/json"}
                    connection.request(method, path, json.dumps(body) if body is not None else None, headers)
                    response = connection.getresponse()
                    content = response.read()
                    assert 200 <= response.status < 300, (response.status, content)
                    return json.loads(content) if content else None
                finally:
                    connection.close()

            def forward():
                connection = http.client.HTTPConnection("127.0.0.1", mixed, timeout=3)
                try:
                    connection.request("GET", "http://198.18.0.10/normal")
                    response = connection.getresponse()
                    content = response.read()
                    assert response.status == 200 and content == b"forwarded", (response.status, content)
                finally:
                    connection.close()

            def health_count():
                with lock:
                    return counts["health"]

            def forward_count():
                with lock:
                    return counts["forward"]

            def assert_selected_group_delay(expected_selection):
                before_selection = request("/proxies/VPN")["now"]
                assert before_selection == expected_selection, before_selection
                before = forward_count()
                target = quote("http://198.18.0.10/probe", safe="")
                delay = request(f"/proxies/VPN/delay?url={target}&timeout=2000&expected=200-599")
                assert delay["delay"] > 0, delay
                assert forward_count() == before + 1, "Selected-group delay must make one target request"
                assert request("/proxies/VPN")["now"] == before_selection, "Delay probe must not change VPN.now"

            def reload(selected):
                nonlocal result
                result = generate(selected)
                request("/configs?force=true", "PUT", {"path": result["config"]})
                request("/proxies/VPN", "PUT", {"name": selected})

            result = generate("fixture-a", baseline=True)
            with (root / "mihomo.log").open("w") as log:
                process = subprocess.Popen([str(args.mihomo.resolve()), "-d", result["home"], "-f", result["config"]], stdout=log, stderr=subprocess.STDOUT)
                for _ in range(100):
                    try:
                        request("/version")
                        break
                    except (OSError, AssertionError):
                        assert process.poll() is None, (root / "mihomo.log").read_text()
                        time.sleep(0.05)
                else:
                    raise AssertionError("Isolated controller did not start")
                request("/proxies/VPN", "PUT", {"name": "fixture-a"})
                for _ in range(4):
                    forward()
                    time.sleep(0.55)
                baseline = health_count()
                assert baseline >= 4, ("Lazy fixed-node baseline must test both nodes repeatedly", counts)
                reload("fixture-a")
                time.sleep(0.5)  # Drain requests from the old profile.
                before = health_count()
                for _ in range(4):
                    forward()
                    time.sleep(0.55)
                assert health_count() == before, "Fixed-node forwarding must not trigger periodic group tests"
                assert_selected_group_delay("fixture-a")
                after_fixed_probe = health_count()
                time.sleep(1.2)
                assert health_count() == after_fixed_probe, "Fixed-node delay probe must not trigger provider tests"
                request("/providers/proxies/" + quote(subscription) + "/healthcheck")
                for _ in range(60):
                    if health_count() >= before + 2:
                        break
                    time.sleep(0.05)
                assert health_count() >= before + 2, "Manual provider tests must remain available"
                reload("AUTO")
                auto_before = health_count()
                for _ in range(4):
                    forward()
                    time.sleep(0.55)
                assert health_count() >= auto_before + 2, "Automatic selection must restore health checks"
                assert_selected_group_delay("AUTO")
                reload("BALANCE")
                assert_selected_group_delay("BALANCE")
                reload("fixture-b")
                time.sleep(0.5)
                before = health_count()
                forward()
                time.sleep(2.2)
                assert health_count() == before, "Returning to a fixed node must stop group tests again"
                print(json.dumps({"baseline_health_requests": baseline, "fixed_periodic_requests": 0, "manual_tests": "passed", "automatic_tests": "passed", "selected_group_delay": ["fixed", "AUTO", "BALANCE"], "fixed_node_switch_and_forwarding": "passed"}))
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        proxy.shutdown()
        proxy.server_close()


if __name__ == "__main__":
    main()
