#!/usr/bin/env python3
"""Check source intended for publication without printing matched values."""
import json
import hashlib
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_PARTS = {
    '.local', '.build', '.codex', '.claude', '.agents', 'xcuserdata',
    'node_modules', 'release', 'dist', 'target', 'bin', 'obj',
}
FORBIDDEN_SUFFIXES = {
    '.pem', '.key', '.p12', '.pfx', '.jks', '.keystore', '.mobileprovision',
    '.provisionprofile', '.ipa', '.apk', '.aab', '.dmg', '.log',
}
PATTERNS = {
    'private-key': re.compile(r'-----BEGIN (?:[A-Z ]*PRIVATE KEY)-----'),
    'service-token': re.compile(
        r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'
        r'|AKIA[0-9A-Z]{16}|sk-(?:proj-)?[A-Za-z0-9_-]{20,})\b'
    ),
    'user-home-path': re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+/'),
    'windows-user-path': re.compile(r'[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+\\'),
}
EMAIL = re.compile(r'[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})')


def main():
    top = subprocess.check_output(
        ['git', 'rev-parse', '--show-toplevel'], cwd=ROOT, text=True
    ).strip()
    if Path(top).resolve() != ROOT:
        raise SystemExit('Run this check inside its independent source repository.')
    names = subprocess.check_output(
        ['git', 'ls-files', '-co', '--exclude-standard', '-z'], cwd=ROOT
    ).decode().split('\0')
    findings = []
    lock_path = ROOT / 'third_party/dependencies.lock.json'
    upstream_licenses = {}
    if lock_path.is_file():
        lock = json.loads(lock_path.read_text())
        upstream_licenses.update({item['license_file']: item['license_sha256']
                                  for item in lock['dependencies'].values() if 'license_file' in item})
        upstream_licenses.update({item['path']: item['sha256'] for item in lock.get('license_documents', [])})
    checked = 0
    for name in sorted(set(filter(None, names))):
        path = ROOT / name
        relative = Path(name)
        if path.is_symlink():
            findings.append({'file': name, 'kind': 'symlink'})
            continue
        if not path.is_file():
            continue
        checked += 1
        if (FORBIDDEN_PARTS.intersection(relative.parts)
                or relative.suffix.lower() in FORBIDDEN_SUFFIXES
                or relative.name in {'Signing.local.xcconfig', 'local.properties'}
                or (relative.name.startswith('.env') and relative.name != '.env.example')
                or name.startswith('docs/archive/')):
            findings.append({'file': name, 'kind': 'local-or-distribution-artifact'})
        raw = path.read_bytes()
        verified_license = name in upstream_licenses and hashlib.sha256(raw).hexdigest() == upstream_licenses[name]
        if name in upstream_licenses and not verified_license:
            findings.append({'file': name, 'kind': 'changed-upstream-license'})
        if b'\0' in raw[:8192]:
            continue
        try:
            content = raw.decode('utf-8')
        except UnicodeDecodeError:
            continue
        for line_no, line in enumerate(content.splitlines(), 1):
            for kind, pattern in PATTERNS.items():
                if pattern.search(line):
                    findings.append({'file': name, 'line': line_no, 'kind': kind})
            for match in EMAIL.finditer(line):
                if (path.suffix == ".kt" and match[0].startswith("this@")
                        and match.start() > 0 and line[match.start()-1] in "( "):
                    continue
                # Retain verified third-party copyright attributions verbatim.
                if verified_license:
                    continue
                domain = match[1].lower()
                if not (domain.endswith(('.test', '.invalid'))
                        or any(domain == example or domain.endswith('.' + example)
                               for example in ('example.com', 'example.net', 'example.org'))):
                    findings.append({'file': name, 'line': line_no, 'kind': 'non-example-email'})
    print(json.dumps({'checked_files': checked, 'findings': findings}, ensure_ascii=False, indent=2))
    return bool(findings)


if __name__ == '__main__':
    sys.exit(main())
