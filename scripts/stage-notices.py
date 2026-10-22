#!/usr/bin/env python3
"""Stage verified licenses and a dependency inventory in a build output."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from third_party_common import LOCAL, ROOT, go_environment, load_lock, sha256

SELECTION = {
    'macos-arm64': ['mihomo', 'zju_connect', 'meta_rules'],
    'macos-x64': ['mihomo', 'zju_connect', 'meta_rules'],
    'windows-x64': ['mihomo', 'zju_connect', 'meta_rules'],
    'android-arm64': ['mihomo_android', 'tun2socks', 'meta_rules'],
    'ios': ['sing_box', 'sing_geosite', 'sing_geoip'],
}


def read_prebuilt_inventory(directory, platform):
    """Validate a complete notice tree before it is copied into an app."""
    directory = Path(directory)
    if not directory.is_absolute():
        raise ValueError('Prebuilt notices must use an absolute path.')
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('Prebuilt notices must be a real directory.')
    for path in directory.rglob('*'):
        if path.is_symlink():
            raise ValueError('Prebuilt notices must not contain symbolic links.')
    marker = directory / 'dependency-inventory.json'
    if not marker.is_file():
        raise ValueError('Prebuilt notices are missing dependency-inventory.json.')
    try:
        inventory = json.loads(marker.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError('Prebuilt notice inventory is not valid JSON.') from error
    if inventory.get('platform') != platform:
        raise ValueError('Prebuilt notices are for a different platform.')
    if inventory.get('status') == 'preparing':
        raise ValueError('Prebuilt notices are incomplete.')
    components = inventory.get('components')
    if not isinstance(components, dict) or set(components) != set(SELECTION[platform]):
        raise ValueError('Prebuilt notices do not contain the expected components.')
    if not isinstance(inventory.get('rust_packages'), list) or not inventory['rust_packages']:
        raise ValueError('Prebuilt notices do not contain a Rust dependency inventory.')
    if not isinstance(inventory.get('go_modules'), dict):
        raise ValueError('Prebuilt notices do not contain a Go dependency inventory.')
    if platform == 'ios' and not isinstance(inventory['go_modules'].get('sing_box'), list):
        raise ValueError('Prebuilt iOS notices do not contain the sing-box dependency inventory.')
    if not isinstance(inventory.get('geo_data'), dict):
        raise ValueError('Prebuilt notices do not contain a Geo data inventory.')
    required = [directory / f'{key}.LICENSE' for key in SELECTION[platform]]
    required += [directory / 'Qingzhou-Original-Code.LICENSE', directory / 'LICENSES.md']
    if any(not path.is_file() for path in required):
        raise ValueError('Prebuilt notices are missing required license documents.')
    return inventory


def copy_prebuilt_notices(source, output, platform):
    """Replace an owned output with a verified, already generated notice tree."""
    source = Path(source)
    output = Path(output)
    if output.is_symlink():
        raise ValueError('Notice output must not be a symbolic link.')
    read_prebuilt_inventory(source, platform)
    source = source.resolve()
    output = output.resolve()
    if source == output or source in output.parents or output in source.parents:
        raise ValueError('Prebuilt notice source and output must not overlap.')
    if output.exists():
        if not output.is_dir():
            raise ValueError('Notice output must be a directory.')
        if any(output.iterdir()):
            marker = output / 'dependency-inventory.json'
            if marker.is_symlink() or not marker.is_file():
                raise ValueError('Refusing to replace an unowned notice directory.')
            try:
                current = json.loads(marker.read_text(encoding='utf-8'))
            except (OSError, json.JSONDecodeError) as error:
                raise ValueError('Refusing to replace an unowned notice directory.') from error
            if current.get('platform') != platform:
                raise ValueError('Refusing to replace notices for a different platform.')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f'.{output.name}.copy-', dir=output.parent) as temporary:
        staged = Path(temporary) / output.name
        shutil.copytree(source, staged)
        read_prebuilt_inventory(staged.resolve(), platform)
        previous = None
        if output.exists():
            previous = Path(tempfile.mkdtemp(prefix=f'.{output.name}.previous-', dir=output.parent))
            output.rename(previous / output.name)
        try:
            staged.rename(output)
        except Exception:
            if previous is not None and not output.exists():
                (previous / output.name).rename(output)
                previous.rmdir()
            raise
        if previous is not None:
            shutil.rmtree(previous)
    print(f'Copied verified {platform} notices from {source}.')


def copy_licenses(directory, output):
    """Copy license texts only; do not copy local manifests or build paths."""
    output.mkdir(parents=True, exist_ok=True)
    copied = []
    for path in sorted(Path(directory).iterdir()):
        if path.is_file() and re.match(r'(?i)^(license|licence|copying|notice|copyright|patents)([._-].*)?$', path.name):
            shutil.copyfile(path, output / path.name)
            copied.append(path.name)
    return copied


def rust_notices(output, platform):
    target = {'macos-arm64': 'aarch64-apple-darwin', 'macos-x64': 'x86_64-apple-darwin',
              'windows-x64': 'x86_64-pc-windows-gnu', 'android-arm64': 'aarch64-linux-android',
              'ios': 'aarch64-apple-ios'}[platform]
    raw = subprocess.check_output([
        # A clean builder may not have downloaded manifests for test-only crates.
        # --locked keeps the resolved versions/checksums fixed while allowing
        # Cargo to fill that local metadata cache before notices are collected.
        'cargo', 'metadata', '--locked', '--format-version=1',
        '--filter-platform', target,
        '--manifest-path', str(ROOT / 'packages/vpn-core/Cargo.toml')], cwd=ROOT)
    metadata = json.loads(raw)
    nodes = {node['id']: node for node in metadata['resolve']['nodes']}
    reachable = set()
    pending = [metadata['resolve']['root']]
    while pending:
        identifier = pending.pop()
        if identifier in reachable:
            continue
        reachable.add(identifier)
        pending.extend(dependency['pkg'] for dependency in nodes[identifier]['deps'])
    packages = [package for package in metadata['packages'] if package['id'] in reachable]
    result = []
    for package in packages:
        if package['source'] is None:
            continue
        identifier = package['name'] + '-' + package['version']
        directory = Path(package['manifest_path']).parent
        files = copy_licenses(directory, output / identifier)
        if package.get('license_file'):
            path = directory / package['license_file']
            if path.is_file() and path.name not in files:
                shutil.copyfile(path, output / identifier / path.name)
                files.append(path.name)
        result.append({'name': package['name'], 'version': package['version'],
                       'license': package['license'], 'repository': package.get('repository'),
                       'license_files': files})
    return result


def go_notices(output, platform):
    if platform == 'android-arm64':
        # These two different Go toolchains are handled by the Android preparer.
        return {'prepared_by': 'apps/android/scripts/prepare-dependencies.py'}
    lock = load_lock()
    if platform == 'ios':
        sources = [('sing_box', ROOT / 'apps/iphone/ThirdParty/sing-box-src',
                    dict(os.environ, GOPATH=str(ROOT / '.local/ios-go'),
                         GOMODCACHE=str(ROOT / '.local/ios-go/pkg/mod'),
                         GOTOOLCHAIN='go' + lock['dependencies']['sing_box']['go_version'], GOWORK='off'))]
    else:
        sources = [(key, source, environment) for key, source, environment in [
            ('mihomo', LOCAL / 'sources' / ('mihomo-' + lock['dependencies']['mihomo']['commit']),
             go_environment(lock['dependencies']['mihomo']['go_version'])),
            ('zju_connect', ROOT / 'packages/company-vpn/.local/source',
             dict(os.environ, GOTOOLCHAIN='go' + lock['dependencies']['zju_connect']['go_version'], GOWORK='off',
                  GOMODCACHE=str(ROOT / 'packages/company-vpn/.local/go-modules'))),
        ]]
    result = {}
    pattern = re.compile(r'(?i)^(license|licence|copying|notice|copyright|patents)([._-].*)?$')
    for key, source, environment in sources:
        environment.pop('GOFLAGS', None)
        environment.pop('GOROOT', None)
        environment['GOWORK'] = 'off'
        if not (source / 'go.mod').is_file():
            raise SystemExit(f'Prepare {key} source before staging its notices.')
        raw = subprocess.check_output(['go', 'list', '-mod=readonly', '-m', '-json', 'all'],
                                      cwd=source, env=environment).decode()
        decoder = json.JSONDecoder()
        modules = []
        included_modules = None
        if platform != 'ios':
            architecture = 'arm64' if platform == 'macos-arm64' else 'amd64'
            binary = (ROOT / 'resources/mihomo' / {
                'macos-arm64': 'darwin-arm64/mihomo', 'macos-x64': 'darwin-x64/mihomo',
                'windows-x64': 'win32-x64/mihomo.exe'}[platform]) if key == 'mihomo' else (
                    ROOT / 'packages/company-vpn/.local/bin' / (
                        'company-account-helper-windows-amd64.exe' if platform == 'windows-x64'
                        else 'company-account-helper-' + architecture))
            information = subprocess.check_output(['go', 'version', '-m', str(binary)], env=environment).decode()
            included_modules = {line.split()[1] for line in information.splitlines()
                                if line.strip().startswith('dep\t') or line.strip().startswith('dep ')}
        while raw.strip():
            item, consumed = decoder.raw_decode(raw.lstrip())
            raw = raw.lstrip()[consumed:]
            if item.get('Main'):
                continue
            if included_modules is not None and item['Path'] not in included_modules:
                continue
            effective = item.get('Replace', item)
            identifier = re.sub(r'[^A-Za-z0-9_.-]', '_', effective['Path'] + '@' + effective.get('Version', ''))
            files = []
            directory = Path(effective['Dir']) if effective.get('Dir') else None
            if directory and directory.is_dir():
                for path in sorted(directory.rglob('*')):
                    relative = path.relative_to(directory)
                    if path.is_file() and (pattern.match(path.name)
                            or any(part.lower() in {'licenses', 'licences'} for part in relative.parts[:-1])):
                        destination = output / key / identifier / relative
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(path, destination)
                        files.append(relative.as_posix())
            modules.append({'name': item['Path'], 'version': item.get('Version'),
                            'replacement': ({'name': effective['Path'], 'version': effective.get('Version')}
                                            if 'Replace' in item else None), 'license_files': files})
            if included_modules is not None and not files:
                raise SystemExit(f'No license text found for linked Go module {item["Path"]}.')
        result[key] = modules
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True, choices=SELECTION)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--copy-from', type=Path,
                        help='Copy a complete prebuilt notice tree instead of regenerating it.')
    args = parser.parse_args(argv)
    if args.copy_from:
        copy_prebuilt_notices(args.copy_from, args.output, args.platform)
        return
    output = args.output.resolve()
    marker = output / 'dependency-inventory.json'
    if output.exists() and any(output.iterdir()) and not marker.is_file():
        raise SystemExit('Refusing to overwrite an unowned notice directory.')
    output.mkdir(parents=True, exist_ok=True)
    if not marker.exists():
        marker.write_text(json.dumps({'status': 'preparing', 'platform': args.platform}) + '\n')
    lock = load_lock()
    components = {}
    for key in SELECTION[args.platform]:
        item = lock['dependencies'][key]
        source = ROOT / item['license_file']
        if sha256(source) != item['license_sha256']:
            raise SystemExit('A checked-in upstream license differs from the lock.')
        shutil.copyfile(source, output / f'{key}.LICENSE')
        components[key] = {field: item[field] for field in ['repository', 'commit', 'license']}
    for item in lock.get('license_documents', []):
        source = ROOT / item['path']
        if sha256(source) != item['sha256']:
            raise SystemExit('A checked-in license document differs from the lock.')
        shutil.copyfile(source, output / source.name)
    shutil.copyfile(ROOT / 'LICENSE', output / 'Qingzhou-Original-Code.LICENSE')
    shutil.copyfile(ROOT / 'docs/LICENSES.md', output / 'LICENSES.md')
    rust = rust_notices(output / 'rust', args.platform)
    go = go_notices(output / 'go', args.platform)
    marker.write_text(json.dumps({'platform': args.platform, 'components': components,
                                 'rust_packages': rust,
                                 'go_modules': go,
                                 'geo_data': {key: {k: v for k, v in value.items() if k != 'destinations'}
                                              for key, value in lock['data'].items()
                                              if (key.endswith('.srs')) == (args.platform == 'ios')}},
                                ensure_ascii=False, indent=2) + '\n')
    print(f'Staged {len(components)} direct components and {len(rust)} Rust package declarations.')


if __name__ == '__main__':
    main()
