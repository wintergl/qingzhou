#!/usr/bin/env python3
"""Check the exported macOS boat renderer and every Windows ICO frame."""
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[3]
ASSETS = ROOT / "apps/windows/Qingzhou/Assets/Tray"
manifest = json.loads((ASSETS / "manifest.json").read_text())
renderer = ROOT / "apps/macos-native/Sources/SplitVPNNative/Services/StatusBarController.swift"
assert hashlib.sha256(renderer.read_bytes()).hexdigest() == manifest["rendererSha256"], "Regenerate Windows tray icons after macOS renderer changes"
expected = {f"{theme}-{personal}-{company}-{badge}.ico" for theme in ("light", "dark")
            for personal in ("on", "off") for company in ("on", "off") for badge in ("none", "progress", "error", "unknown")}
assert {entry["file"] for entry in manifest["files"]} == expected
assert {p.name for p in ASSETS.glob("*.ico")} == expected
for entry in manifest["files"]:
    data = (ASSETS / entry["file"]).read_bytes()
    assert hashlib.sha256(data).hexdigest() == entry["sha256"], entry["file"]
    reserved, kind, count = struct.unpack_from("<HHH", data)
    assert (reserved, kind, count) == (0, 1, len(manifest["sizes"]))
    for index, size in enumerate(manifest["sizes"]):
        w, h, _, _, planes, bits, length, offset = struct.unpack_from("<BBBBHHII", data, 6 + index * 16)
        assert (w, h, planes, bits) == (size, size, 1, 32)
        image = data[offset:offset + length]
        assert len(image) == length and image.startswith(b"\x89PNG\r\n\x1a\n")
        assert struct.unpack_from(">II", image, 16) == (size, size)
print("32 tray assets / 256 PNG frames match the macOS renderer export.")
