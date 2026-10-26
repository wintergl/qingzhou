#!/usr/bin/env python3
"""Android-generated DNS via SOCKS, with loopback fixtures only (no TUN/VPN).

Build the host bridge first:
  cargo rustc --manifest-path packages/vpn-core/Cargo.toml --locked --lib --crate-type cdylib
"""
import argparse
import ctypes
import ipaddress
import json
import re
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DNS_SERVER = "172.19.0.2"


def receive(sock, length):
    data = b""
    while len(data) < length:
        part = sock.recv(length - len(data))
        assert part, "Unexpected SOCKS/DNS EOF"
        data += part
    return data


def name_at(data, pos):
    labels = []
    while data[pos]:
        if data[pos] & 0xC0 == 0xC0:
            tail, _ = name_at(data, ((data[pos] & 0x3F) << 8) | data[pos + 1])
            return ".".join(labels + [tail]), pos + 2
        length = data[pos]
        pos += 1
        labels.append(data[pos:pos + length].decode("ascii"))
        pos += length
    return ".".join(labels), pos + 1


def dns_packet(name, tx=0x514A):
    return (struct.pack("!6H", tx, 0x100, 1, 0, 0, 0)
            + b"".join(bytes([len(p)]) + p.encode() for p in name.split("."))
            + b"\0" + struct.pack("!HH", 1, 1))


def answer_ip(packet):
    tx, flags, qd, an, _, _ = struct.unpack_from("!6H", packet)
    assert tx == 0x514A and flags & 15 == 0 and an > 0, "DNS request failed"
    pos = 12
    for _ in range(qd):
        _, pos = name_at(packet, pos)
        pos += 4
    for _ in range(an):
        _, pos = name_at(packet, pos)
        kind, _, _, length = struct.unpack_from("!HHIH", packet, pos)
        pos += 10
        if kind == 1 and length == 4:
            return socket.inet_ntoa(packet[pos:pos + 4])
        pos += length
    raise AssertionError("DNS response contains no IPv4 answer")


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def socks(mixed, command, address="0.0.0.0", port=0):
    sock = socket.create_connection(("127.0.0.1", mixed), 2)
    sock.settimeout(3)
    sock.sendall(b"\x05\x01\x00")
    assert receive(sock, 2) == b"\x05\x00", "SOCKS authentication failed"
    sock.sendall(bytes([5, command, 0, 1]) + socket.inet_aton(address) + struct.pack("!H", port))
    version, status, _, address_type = receive(sock, 4)
    assert version == 5 and status == 0, "SOCKS command failed"
    if address_type == 1:
        bound = socket.inet_ntoa(receive(sock, 4))
    elif address_type == 3:
        bound = receive(sock, receive(sock, 1)[0]).decode()
    else:
        bound = socket.inet_ntop(socket.AF_INET6, receive(sock, 16))
    bound_port = struct.unpack("!H", receive(sock, 2))[0]
    return sock, ("127.0.0.1" if bound == "0.0.0.0" else bound, bound_port)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core-library", type=Path, default=ROOT / "packages/vpn-core/target/debug/libsplitvpn_core.dylib")
    parser.add_argument("--mihomo", type=Path, default=ROOT / "resources/mihomo/darwin-arm64/mihomo")
    args = parser.parse_args()
    library = ctypes.CDLL(str(args.core_library.resolve()))
    library.qz_core_call.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    library.qz_core_call.restype = ctypes.c_void_p
    library.qz_core_free.argtypes = [ctypes.c_void_p]
    observed = []
    upstream = []

    class Proxy(socketserver.StreamRequestHandler):
        def handle(self):
            self.request.settimeout(3)
            line = self.rfile.readline().decode().strip()
            observed.append(line)
            while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                pass
            self.wfile.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
            self.wfile.flush()
            assert self.rfile.read(len(b"fixture-request")) == b"fixture-request"
            self.wfile.write(b"fixture-ok")
            self.wfile.flush()

    class Dns(socketserver.BaseRequestHandler):
        def handle(self):
            query, sock = self.request
            name, _ = name_at(query, 12)
            upstream.append(name)
            assert name == "printer.lan", "Fixture must never resolve public names"
            response = query[:2] + struct.pack("!5H", 0x8180, 1, 1, 0, 0) + query[12:]
            response += b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + socket.inet_aton("10.0.0.8")
            sock.sendto(response, self.client_address)

    proxy = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Proxy)
    proxy.daemon_threads = True
    dns = socketserver.ThreadingUDPServer(("127.0.0.1", 0), Dns)
    dns.daemon_threads = True
    servers = [proxy, dns]
    threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in servers]
    for thread in threads:
        thread.start()
    process = None
    debug_log = None
    try:
        with tempfile.TemporaryDirectory(prefix="qingzhou-dns-bridge-") as temporary:
            root = Path(temporary)

            def call(channel, payload):
                pointer = library.qz_core_call(str(root).encode(), json.dumps({"channel": channel, "payload": payload}).encode())
                try:
                    reply = json.loads(ctypes.string_at(pointer))
                finally:
                    library.qz_core_free(pointer)
                assert reply["ok"], reply
                return reply["data"]

            identifier = call("subscription:save", {"name": "fixture", "url": "https://example.test/sub"})["entries"][0]["id"]
            plan = call("subscription:plan", {"id": identifier})
            call("subscription:accept", {"id": identifier, "token": plan["token"], "index": 0, "status": 200,
                                        "content": f"proxies:\n  - {{name: fixture, type: http, server: 127.0.0.1, port: {proxy.server_address[1]}}}\n"})
            call("settings:patch", {"selectedProxy": "fixture", "unknownTraffic": "vpn", "lanDirect": True,
                                    "directDomainRules": ["IP-CIDR,172.19.0.0/16"], "vpnDomainRules": ["DOMAIN-SUFFIX,example.test"]})
            saved = call("settings:get", {})
            mixed = free_port()
            generated = call("mihomo:generate", {"mixedPort": mixed, "controllerPort": free_port()})
            assert generated["udp"] is False, "Fixture must use an HTTP node without UDP"
            path = Path(generated["config"])
            text = path.read_text()
            text = text.replace("https://www.gstatic.com/generate_204", f"http://127.0.0.1:{proxy.server_address[1]}/unused-health")
            assert re.search(r"tun:\n  enable: false", text), "Never establish TUN"
            assert "(IP-CIDR,172.19.0.2/32,no-resolve),(DST-PORT,53)" in text
            # Replace only upstreams and sniffing. Keep the generated virtual-DNS
            # outbound, first rule, provider and user/LAN rule order intact.
            local_dns = {"enable": True, "ipv6": False, "enhanced-mode": "fake-ip", "fake-ip-range": "198.18.0.1/16",
                         "fake-ip-filter": ["+.lan"], "respect-rules": True,
                         "nameserver": [f"udp://127.0.0.1:{dns.server_address[1]}"],
                         "default-nameserver": ["127.0.0.1"], "proxy-server-nameserver": ["127.0.0.1"]}
            section = r"(?ms)^%s:\n.*?(?=^[^\s-][^\n]*:|\Z)"
            text = re.sub(section % "dns", "dns: " + json.dumps(local_dns) + "\n", text)
            text = re.sub(section % "sniffer", 'sniffer: {"enable": false}\n', text)
            assert "https://dns.google" not in text and "https://cloudflare-dns" not in text
            path.write_text(text)
            debug_log = root / "mihomo.log"
            text = path.read_text().replace("log-level: error", "log-level: debug")
            path.write_text(text)
            with debug_log.open("w") as log:
                process = subprocess.Popen([str(args.mihomo.resolve()), "-d", generated["home"], "-f", str(path)], stdout=log, stderr=subprocess.STDOUT)
                for _ in range(80):
                    try:
                        control, relay = socks(mixed, 3)
                        break
                    except OSError:
                        assert process.poll() is None, (root / "mihomo.log").read_text()
                        time.sleep(.05)
                else:
                    raise AssertionError("Isolated SOCKS did not start")
                with control, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                    udp.settimeout(3)
                    udp.sendto(b"\0\0\0\x01" + socket.inet_aton(DNS_SERVER) + struct.pack("!H", 53) + dns_packet("service.example.test"), relay)
                    response, _ = udp.recvfrom(4096)
                    assert response[:4] == b"\0\0\0\x01"
                    assert socket.inet_ntoa(response[4:8]) == DNS_SERVER and struct.unpack("!H", response[8:10])[0] == 53
                    fake_ip = answer_ip(response[10:])
                    assert ipaddress.ip_address(fake_ip) in ipaddress.ip_network("198.18.0.0/16"), fake_ip
                tcp, _ = socks(mixed, 1, DNS_SERVER, 53)
                with tcp:
                    packet = dns_packet("service.example.test")
                    tcp.sendall(struct.pack("!H", len(packet)) + packet)
                    assert answer_ip(receive(tcp, struct.unpack("!H", receive(tcp, 2))[0])) == fake_ip
                    packet = dns_packet("printer.lan")
                    tcp.sendall(struct.pack("!H", len(packet)) + packet)
                    assert answer_ip(receive(tcp, struct.unpack("!H", receive(tcp, 2))[0])) == "10.0.0.8"
                traffic, _ = socks(mixed, 1, fake_ip, 443)
                with traffic:
                    traffic.sendall(b"fixture-request")
                    assert receive(traffic, len(b"fixture-ok")) == b"fixture-ok"
                assert observed == ["CONNECT service.example.test:443 HTTP/1.1"], observed
                assert upstream == ["printer.lan"], upstream
                assert call("settings:get", {}) == saved, "DNS generation must not change user settings"
                process.terminate()
                process.wait(timeout=5)
                with socket.socket() as check:
                    assert check.connect_ex(("127.0.0.1", mixed)) != 0, "Isolated listener must close"
                print(json.dumps({"udp_dns": "passed", "tcp_dns": "passed", "fake_ip_to_domain_forwarding": "passed",
                                  "lan_fake_ip_filter": "passed", "lan_rule_priority": "passed", "settings_unchanged": True,
                                  "process_reaped": True, "listener_closed": True}))
    except Exception:
        if debug_log is not None and debug_log.exists():
            print(debug_log.read_text())
        print({"observed": observed, "upstream": upstream})
        raise
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        for server in servers:
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join(timeout=2)


if __name__ == "__main__":
    main()
