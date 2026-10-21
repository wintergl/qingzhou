#!/usr/bin/env python3
"""Inspect a test APK without installing it or starting a VPN."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import zipfile


def run(*command):
    return subprocess.check_output([str(x) for x in command], text=True, stderr=subprocess.STDOUT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--previous', type=Path, help='Check compatibility with the previous signing certificate')
    parser.add_argument('--built-libs', type=Path, help='Compare packaged libraries with the current stripped build output')
    args = parser.parse_args()
    sdk = Path(os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT') or Path.home() / 'Library/Android/sdk')
    build_tools = sdk / 'build-tools/35.0.0'
    badging = run(build_tools / 'aapt', 'dump', 'badging', args.apk)
    package, code, version = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging).groups()
    assert package == 'dev.splitvpn.android'
    assert "sdkVersion:'26'" in badging and "targetSdkVersion:'35'" in badging
    assert "native-code: 'arm64-v8a'" in badging
    for permission in ('ACCESS_NETWORK_STATE', 'WAKE_LOCK', 'FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_SPECIAL_USE'):
        assert f"android.permission.{permission}" in badging
    cert_output = run(build_tools / 'apksigner', 'verify', '--verbose', '--print-certs', args.apk)
    assert 'Verified using v2 scheme (APK Signature Scheme v2): true' in cert_output
    cert = re.search(r'certificate SHA-256 digest: ([a-f0-9]+)', cert_output).group(1)
    if args.previous:
        previous = run(build_tools / 'apksigner', 'verify', '--print-certs', args.previous)
        assert cert == re.search(r'certificate SHA-256 digest: ([a-f0-9]+)', previous).group(1), 'Signing certificate changed'
        old = run(build_tools / 'aapt', 'dump', 'badging', args.previous)
        assert f"package: name='{package}'" in old
        assert int(code) > int(re.search(r"versionCode='(\d+)'", old).group(1))
    run(build_tools / 'zipalign', '-c', '-P', '16', '4', args.apk)

    libraries = {}
    with zipfile.ZipFile(args.apk) as archive:
        assert archive.testzip() is None, 'Corrupt ZIP entry'
        names = archive.namelist()
        expected = {'libmihomo.so', 'libtun2socks.so', 'libtunfdexec.so', 'libsplitvpncore.so'}
        assert {Path(x).name for x in names if x.startswith('lib/')} == expected
        for name in names:
            if name.startswith('lib/'):
                assert name.startswith('lib/arm64-v8a/')
                blob = archive.read(name)
                assert blob[:6] == b'\x7fELF\x02\x01', 'Expected a 64-bit little-endian ELF'
                assert struct.unpack_from('<H', blob, 18)[0] == 183, 'Expected AArch64'
                offset = struct.unpack_from('<Q', blob, 32)[0]
                size, count = struct.unpack_from('<HH', blob, 54)
                alignments = [struct.unpack_from('<Q', blob, offset + i * size + 48)[0]
                              for i in range(count) if struct.unpack_from('<I', blob, offset + i * size)[0] == 1]
                assert alignments and min(alignments) >= 16384, f'{name}: incompatible page alignment'
                digest = hashlib.sha256(blob).hexdigest()
                if args.built_libs:
                    assert digest == hashlib.sha256((args.built_libs / Path(name).name).read_bytes()).hexdigest(), f'{name}: stale library'
                libraries[Path(name).name] = {'sha256': digest, 'loadAlignments': alignments}
            if name.endswith(('.so', '.dex', '.json', '.yaml', '.yml', '.txt')):
                blob = archive.read(name)
                assert str(Path.home()).encode() not in blob, f'{name}: personal build path'
                assert b'BEGIN PRIVATE KEY' not in blob and b'BEGIN RSA PRIVATE KEY' not in blob, f'{name}: private-key marker'
        assert b'Java_dev_splitvpn_android_SplitVpnService_waitForNativeProcessExit' in archive.read('lib/arm64-v8a/libtunfdexec.so')
        for filename in ('GeoSite.dat', 'geoip.metadb', 'country.mmdb'):
            assert len(archive.read('assets/geodata/' + filename)) > 0, f'Missing geodata: {filename}'
        assert not any(Path(x).name in ('settings.json', 'subscription.json', 'config.yaml', 'debug.keystore') for x in names)
    print(json.dumps({'package': package, 'version': version, 'versionCode': int(code),
                      'debuggable': 'application-debuggable' in badging, 'minSdk': 26, 'targetSdk': 35,
                      'bytes': args.apk.stat().st_size, 'sha256': hashlib.sha256(args.apk.read_bytes()).hexdigest(),
                      'certificateSha256': cert, 'previousCertificateMatches': bool(args.previous),
                      'nativeLibraries': libraries, 'zipAlignment': 'passed', 'sensitiveMarkers': 'none',
                      'installedOrStarted': False}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
