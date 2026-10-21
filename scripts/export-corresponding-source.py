#!/usr/bin/env python3
"""Export application source, prepared upstream source and build instructions."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

from third_party_common import LOCAL, ROOT, load_lock, run, sha256


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True,
                        choices=['macos-arm64', 'macos-x64', 'windows-x64', 'android-arm64', 'ios'])
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    destination = args.output.resolve()
    if destination.exists():
        raise SystemExit('Output already exists; preserving it.')
    run([sys.executable, ROOT / 'scripts/check_public_source.py'], cwd=ROOT)
    lock = load_lock()
    if args.platform == 'ios':
        sources = {'sing_box': ROOT / 'apps/iphone/ThirdParty/sing-box-src'}
    elif args.platform == 'android-arm64':
        sources = {key: ROOT / '.local/android-dependencies' / ('source-' + name + '-' + lock['dependencies'][key]['commit'])
                   for key, name in [('mihomo_android', 'mihomo'), ('tun2socks', 'tun2socks')]}
        # Resolve the actual source directories recorded by the Android script.
        for key in sources:
            name = 'mihomo' if key == 'mihomo_android' else 'tun2socks'
            candidates = list((ROOT / '.local/android-dependencies').glob(f'{name}-*'))
            candidates += list((ROOT / '.local/android-dependencies').glob(f'sources/{name}-*'))
            if not (sources[key] / 'go.mod').is_file():
                matches = [path for path in candidates if (path / 'go.mod').is_file()]
                if len(matches) != 1:
                    raise SystemExit('Prepare Android dependencies before exporting source.')
                sources[key] = matches[0]
    else:
        sources = {'mihomo': LOCAL / 'sources' / ('mihomo-' + lock['dependencies']['mihomo']['commit']),
                   'zju_connect': ROOT / 'packages/company-vpn/.local/source'}
    for source in sources.values():
        if not (source / 'go.mod').is_file():
            raise SystemExit('Prepare platform dependencies before exporting source.')
    names = subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='qingzhou-source-', dir=destination.parent) as temporary:
        stage = Path(temporary) / 'qingzhou-source'
        app = stage / 'application'
        for name in sorted(set(filter(None, names))):
            source = ROOT / name
            if source.is_file():
                target = app / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
                target.chmod(source.stat().st_mode & 0o777)
        components = {}
        for key, source in sources.items():
            target = stage / 'upstream' / key
            shutil.copytree(source, target, ignore=shutil.ignore_patterns(
                '.git', '.local', '*.xcframework', '*.framework', '.qingzhou-source.json'))
            components[key] = {field: lock['dependencies'][key][field]
                               for field in ['repository', 'commit', 'license']}
        (stage / 'SOURCE-MANIFEST.json').write_text(json.dumps({
            'platform': args.platform, 'components': components,
            'dependency_lock_sha256': sha256(ROOT / 'third_party/dependencies.lock.json'),
            'go_module_dependencies': 'Resolve using the included go.mod/go.sum; see application/docs/LICENSES.md.',
            'native_dependencies': 'iOS cronet-go includes upstream native archives; preserve its source and notices as documented.'}, indent=2) + '\n')
        with tarfile.open(destination, 'w:gz') as archive:
            archive.add(stage, arcname='qingzhou-source')
    print(json.dumps({'output': destination.name, 'sha256': sha256(destination)}, indent=2))


if __name__ == '__main__':
    main()
