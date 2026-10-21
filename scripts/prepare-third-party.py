#!/usr/bin/env python3
"""Prepare pinned sources and resources without starting the VPN."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from third_party_common import (LOCAL, ROOT, build_record, download, go_environment,
                                load_lock, run, sha256, source_for, verify_record)

PLATFORMS = ('macos-arm64', 'macos-x64', 'windows-x64', 'android-arm64', 'ios')


def geodata():
    outputs = []
    for key, item in load_lock()['data'].items():
        cached = download(item['url'], item['sha256'], LOCAL / 'downloads' / key)
        for name in item['destinations']:
            target = ROOT / name
            if ROOT not in target.resolve().parents or target.is_symlink():
                raise RuntimeError('Geo destination must stay inside this checkout.')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(cached, target)
            outputs.append(target)
    if not outputs:
        raise RuntimeError('The dependency lock does not contain Geo inputs.')
    return outputs


def desktop(platform):
    dependency = load_lock()['dependencies']['mihomo']
    source = source_for('mihomo')
    goos, goarch, directory, executable = {
        'macos-arm64': ('darwin', 'arm64', 'darwin-arm64', 'mihomo'),
        'macos-x64': ('darwin', 'amd64', 'darwin-x64', 'mihomo'),
        'windows-x64': ('windows', 'amd64', 'win32-x64', 'mihomo.exe'),
    }[platform]
    destination = ROOT / 'resources/mihomo' / directory / executable
    destination.parent.mkdir(parents=True, exist_ok=True)
    environment = go_environment(dependency['go_version'])
    environment.update(GOOS=goos, GOARCH=goarch, CGO_ENABLED='0')
    run(['go', 'build', '-mod=readonly', '-tags=with_gvisor', '-trimpath', '-buildvcs=false', '-ldflags=-s -w',
         '-o', destination, '.'], cwd=source, env=environment)
    destination.chmod(0o755)
    # The maintained patch script downloads and verifies its own fixed Git commit.
    run([sys.executable, ROOT / 'packages/company-vpn/prepare.py'], cwd=ROOT)
    return [destination, ROOT / 'packages/company-vpn/.local/source/go.mod',
            ROOT / 'packages/company-vpn/.local/bin/company-account-helper']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=PLATFORMS)
    parser.add_argument('--geodata', action='store_true', help='Prepare only shared Geo resources.')
    parser.add_argument('--check', action='store_true', help='Verify prepared files without network or builds.')
    args = parser.parse_args()
    if not args.platform and not args.geodata:
        parser.error('Choose --platform or --geodata.')
    if args.check:
        if args.platform:
            verify_record(args.platform)
        else:
            for item in load_lock()['data'].values():
                for name in item['destinations']:
                    if not (ROOT / name).is_file() or sha256(ROOT / name) != item['sha256']:
                        raise RuntimeError(f'Missing or changed Geo input: {name}')
        print('Prepared inputs match the dependency lock.')
        return
    outputs = geodata()
    if args.platform in PLATFORMS[:3]:
        outputs += desktop(args.platform)
    elif args.platform == 'android-arm64':
        run([sys.executable, ROOT / 'apps/android/scripts/prepare-dependencies.py'], cwd=ROOT)
        run(['bash', ROOT / 'apps/android/scripts/build-core.sh'], cwd=ROOT)
        outputs += [ROOT / 'apps/android/app/src/main/jniLibs/arm64-v8a' / name
                    for name in ['libmihomo.so', 'libtun2socks.so']]
        outputs.append(ROOT / 'apps/android/app/src/main/cpp/prebuilt/arm64-v8a/libsplitvpn_core.a')
    elif args.platform == 'ios':
        run(['bash', ROOT / 'apps/iphone/Scripts/build-core-xcframework.sh'], cwd=ROOT)
        run(['bash', ROOT / 'apps/iphone/Scripts/build-sing-box-libbox.sh'], cwd=ROOT)
        outputs += [path for base in ['CoreFrameworks', 'SingBoxFrameworks']
                    for path in (ROOT / 'apps/iphone/ThirdParty' / base).rglob('*') if path.is_file()]
    if args.platform:
        build_record(args.platform, outputs)
    print(json.dumps({'platform': args.platform, 'prepared_files': len(outputs)}, indent=2))


if __name__ == '__main__':
    main()
