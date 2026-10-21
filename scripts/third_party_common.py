"""Pinned public-source downloads and local build records."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / 'third_party/dependencies.lock.json'
LOCAL = ROOT / '.local/third-party'


def load_lock():
    return json.loads(LOCK_PATH.read_text())


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def run(args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def download(url, expected, destination):
    if not url.startswith('https://') or not re.fullmatch(r'[a-f0-9]{64}', expected):
        raise ValueError('Downloads require HTTPS and a pinned SHA-256.')
    destination = Path(destination)
    if destination.is_symlink():
        raise RuntimeError('Refusing a symbolic-link download cache.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if sha256(destination) != expected:
            raise RuntimeError(f'Cached file differs from the lock: {destination.name}')
        return destination
    fd, temporary = tempfile.mkstemp(prefix=destination.name + '.', dir=destination.parent)
    os.close(fd)
    temporary = Path(temporary)
    try:
        run(['curl', '--disable', '--fail', '--location', '--retry', '3',
             '--proto', '=https', '--proto-redir', '=https', '--output', temporary, url])
        if sha256(temporary) != expected:
            raise RuntimeError(f'Download checksum mismatch: {destination.name}')
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def tree_hash(directory):
    digest = hashlib.sha256()
    for path in sorted(Path(directory).rglob('*')):
        if path.name == '.qingzhou-source.json':
            continue
        if path.is_symlink():
            raise RuntimeError('Source tree contains a symbolic link.')
        if path.is_file():
            digest.update(path.relative_to(directory).as_posix().encode() + b'\0')
            digest.update(bytes.fromhex(sha256(path)))
    return digest.hexdigest()


def extract_source(archive, destination):
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        temporary = Path(temporary)
        with tarfile.open(archive) as source:
            for member in source.getmembers():
                target = temporary / member.name
                if (target.is_absolute() and temporary not in target.resolve().parents
                        or not (member.isfile() or member.isdir())):
                    raise ValueError('Unsafe source archive member.')
            source.extractall(temporary, filter='data')
        roots = list(temporary.iterdir())
        if len(roots) != 1 or not roots[0].is_dir():
            raise ValueError('Expected one source archive root.')
        roots[0].replace(destination)


def source_for(key):
    dependency = load_lock()['dependencies'][key]
    revision = dependency['commit']
    if not re.fullmatch(r'[a-f0-9]{40}', revision):
        raise ValueError('Source revision must be an immutable Git commit.')
    repository = dependency['repository'].removesuffix('.git')
    if not re.fullmatch(r'https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Expected a public GitHub source repository.')
    suffix = repository.removeprefix('https://github.com/')
    archive = download(f'https://codeload.github.com/{suffix}/tar.gz/{revision}',
                       dependency['archive_sha256'], LOCAL / 'downloads' / f'{key}-{revision}.tar.gz')
    destination = LOCAL / 'sources' / f'{key}-{revision}'
    if destination.is_symlink():
        raise RuntimeError('Refusing a symbolic-link source cache.')
    marker = destination / '.qingzhou-source.json'
    if destination.exists():
        if not marker.exists() or json.loads(marker.read_text())['tree_sha256'] != tree_hash(destination):
            raise RuntimeError(f'Locally modified source retained; choose a clean cache for {key}.')
    else:
        extract_source(archive, destination)
        marker.write_text(json.dumps({'commit': revision, 'tree_sha256': tree_hash(destination)}, indent=2) + '\n')
    return destination


def go_environment(version):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Expected a fixed Go patch version.')
    environment = dict(os.environ)
    environment.pop('GOFLAGS', None)
    environment.pop('GOROOT', None)
    environment.update(GOTOOLCHAIN='go' + version,
                       GOWORK='off', GOCACHE=str(LOCAL / 'go-cache'), GOMODCACHE=str(LOCAL / 'go-modules'))
    return environment


def build_record(platform, files):
    record = {'platform': platform, 'lock_sha256': sha256(LOCK_PATH),
              'outputs': {Path(path).relative_to(ROOT).as_posix(): sha256(path) for path in files}}
    if platform.startswith(('macos-', 'windows-')):
        record['adapter_inputs_sha256'] = sha256(ROOT / 'packages/company-vpn/prepare.py')
        record['adapter_overlay_sha256'] = tree_hash(ROOT / 'packages/company-vpn/overlay')
        record['adapter_source_sha256'] = tree_hash(ROOT / 'packages/company-vpn/.local/source')
    output = LOCAL / 'records' / f'{platform}.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(record, indent=2) + '\n')


def verify_record(platform):
    path = LOCAL / 'records' / f'{platform}.json'
    if not path.is_file():
        raise RuntimeError(f'No prepared dependency record for {platform}.')
    record = json.loads(path.read_text())
    if record['lock_sha256'] != sha256(LOCK_PATH):
        raise RuntimeError('Dependency lock changed; prepare dependencies again.')
    if platform.startswith(('macos-', 'windows-')):
        if (record['adapter_inputs_sha256'] != sha256(ROOT / 'packages/company-vpn/prepare.py')
                or record['adapter_overlay_sha256'] != tree_hash(ROOT / 'packages/company-vpn/overlay')
                or record['adapter_source_sha256'] != tree_hash(ROOT / 'packages/company-vpn/.local/source')):
            raise RuntimeError('Adapter source or patches changed; prepare dependencies again.')
    for name, expected in record['outputs'].items():
        path = ROOT / name
        if not path.is_file() or sha256(path) != expected:
            raise RuntimeError(f'Missing or changed prepared input: {name}')
    return record
