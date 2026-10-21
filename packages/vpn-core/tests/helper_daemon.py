#!/usr/bin/env python3
"""Run the real macOS helper loop with mocked networking and a private child.

Only this test's /bin/sleep process may receive a signal. Every network command,
DNS cache flush, data path and identity file is replaced before execution.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
MOCK = '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
p=Path(__file__).parent/'network.json'
s=json.loads(p.read_text())
if sys.argv[0].endswith('/route'):
    print('interface: '+s['device'])
elif sys.argv[1]=='-listnetworkserviceorder':
    print('An asterisk (*) denotes that a network service is disabled.\\n(1) Wi-Fi\\n(Hardware Port: Wi-Fi, Device: en0)\\n(2) ORICO-2.5G\\n(Hardware Port: USB LAN, Device: en16)')
elif sys.argv[1]=='-listallnetworkservices':
    print('An asterisk (*) denotes that a network service is disabled.\\nWi-Fi\\nORICO-2.5G')
elif sys.argv[1]=='-getdnsservers':
    print('\\n'.join(s['dns'][sys.argv[2]]) or "There aren't any DNS Servers set on "+sys.argv[2]+'.')
elif sys.argv[1]=='-setdnsservers':
    s['dns'][sys.argv[2]]=[] if sys.argv[3]=='Empty' else sys.argv[3:]
    s['changes'].append(sys.argv[2:])
    t=p.with_suffix('.tmp');t.write_text(json.dumps(s));os.replace(t,p)
else:
    sys.exit(64)
'''


@unittest.skipUnless(sys.platform == 'darwin', 'macOS shell and process identity contract')
class HelperDaemonTests(unittest.TestCase):
    def test_canonical_identity_survives_timezone_and_locale_changes(self):
        self.check_identity('canonical')

    def test_legacy_identity_migrates_after_timezone_change(self):
        self.check_identity('legacy')

    def test_timezone_migration_rejects_stale_record_and_wrong_start(self):
        self.check_identity('stale')

    def check_identity(self, scenario):
        script = (ROOT / 'packages/vpn-core/assets/macos-helper.sh').read_text()
        functions = []
        for name in ['process_start_token', 'legacy_start_matches', 'write_process_identity', 'verify_process_identity']:
            match = re.search(rf'^{name}\(\) \{{\n.*?^\}}$', script, re.M | re.S)
            self.assertIsNotNone(match, name)
            functions.append(match.group())
        with tempfile.TemporaryDirectory(prefix='splitvpn-helper-identity-') as directory:
            identity = Path(directory) / 'identity'
            child = subprocess.Popen(['/bin/sleep', '30'])
            try:
                env = dict(os.environ, TZ='Asia/Shanghai', LC_ALL='C')
                start = subprocess.check_output(['/bin/ps', '-p', str(child.pid), '-o', 'lstart='], env=env, text=True).strip()
                self.assertTrue(start)
                identity.write_text(f'{child.pid}\n/bin/sleep\n{start}\nfixture\n')
                if scenario == 'stale':
                    os.utime(identity, (time.time() - 30, time.time() - 30))
                setup = '\n'.join(functions) + '\nIDENTITY_FILE="$1"\nMIHOMO=/bin/sleep\n'
                if scenario == 'canonical':
                    result = subprocess.run(['/bin/sh', '-c', setup + 'write_process_identity "$2"', 'identity-test', str(identity), str(child.pid)], env=env)
                    self.assertEqual(result.returncode, 0)
                for timezone, locale in [('America/Los_Angeles', 'C'), ('Pacific/Chatham', 'en_US.UTF-8'), ('UTC', 'C')]:
                    changed = dict(env, TZ=timezone, LC_ALL=locale)
                    result = subprocess.run(['/bin/sh', '-c', setup + 'verify_process_identity "$2"', 'identity-test', str(identity), str(child.pid)], env=changed)
                    self.assertEqual(result.returncode, 1 if scenario == 'stale' else 0, (scenario, timezone))
                if scenario != 'stale':
                    self.assertTrue(identity.read_text().splitlines()[2].startswith('utc:'))
                    # A canonical record cannot be rewritten to adopt a mismatched start.
                    lines = identity.read_text().splitlines()
                    lines[2] = 'utc:Mon Oct 12 00:00:00 2000'
                    identity.write_text('\n'.join(lines) + '\n')
                    result = subprocess.run(['/bin/sh', '-c', setup + 'verify_process_identity "$2"', 'identity-test', str(identity), str(child.pid)], env=env)
                    self.assertEqual(result.returncode, 1)
                self.assertIsNone(child.poll())
            finally:
                child.terminate()
                child.wait(timeout=5)

    def test_idle_fifo_handoff_preserves_pid_and_restores_each_service(self):
        with tempfile.TemporaryDirectory(prefix='splitvpn-helper-loop-') as directory:
            root = Path(directory)
            data = root / 'data'
            (data / 'mihomo').mkdir(parents=True)
            identities = root / 'identity'
            identities.mkdir()
            network = root / 'network.json'
            original = {'Wi-Fi': [], 'ORICO-2.5G': ['119.29.29.29', '223.5.5.5']}
            network.write_text(json.dumps({'device': 'en0', 'dns': original, 'changes': []}))
            for name in ['networksetup', 'route']:
                path = root / name
                path.write_text(MOCK)
                path.chmod(0o755)
            script = (ROOT / 'packages/vpn-core/assets/macos-helper.sh').read_text()
            for before, after in {
                'MIHOMO="/Library/PrivilegedHelperTools/com.split-vpn.mihomo"': 'MIHOMO="/bin/sleep"',
                'IDENTITY_DIR="/var/db/com.split-vpn.helper"': f'IDENTITY_DIR="{identities}"',
                '/usr/sbin/networksetup': str(root / 'networksetup'),
                '/sbin/route': str(root / 'route'),
                '/usr/bin/dscacheutil': '/usr/bin/true',
                '/usr/bin/killall': '/usr/bin/true',
            }.items():
                assert before in script
                script = script.replace(before, after)
            helper = root / 'helper.sh'
            helper.write_text(script)
            child = subprocess.Popen(['/bin/sleep', '120'])
            # Reap promptly so the helper can confirm process exit after TERM.
            threading.Thread(target=child.wait, daemon=True).start()
            (data / 'mihomo/mihomo.pid').write_text(str(child.pid))
            start = subprocess.check_output(['/bin/ps', '-p', str(child.pid), '-o', 'lstart='], text=True).strip()
            self.assertTrue(start)
            identity = identities / 'mihomo.identity'
            identity.write_text(f'{child.pid}\n/bin/sleep\n{start}\nfixture\n')
            stdout, stderr = root / 'stdout', root / 'stderr'
            with stdout.open('w') as out, stderr.open('w') as err:
                daemon = subprocess.Popen(['/bin/sh', str(helper), 'daemon', str(data)], stdout=out, stderr=err)
            fifo = data / 'helper/control.pipe'
            def wait_for(condition, timeout=18):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if condition():
                        return
                    self.assertIsNone(daemon.poll(), stderr.read_text())
                    time.sleep(0.15)
                self.fail('helper condition timed out: '+stderr.read_text())
            def state():
                return json.loads(network.read_text())
            def rpc(command, name):
                reply = data / f'helper/responses/{name}.json'
                with fifo.open('w') as pipe:
                    pipe.write(f'{name} {command}\n')
                wait_for(reply.exists, 8)
                return json.loads(reply.read_text())
            try:
                wait_for(fifo.exists, 5)
                # No request is sent: timed FIFO read must permit periodic DNS work.
                wait_for(lambda: state()['dns']['Wi-Fi'] == ['127.0.0.1'])
                self.assertEqual(state()['dns']['ORICO-2.5G'], original['ORICO-2.5G'])
                self.assertIsNone(child.poll())
                switched = state()
                switched['device'] = 'en16'
                temporary = network.with_suffix('.switch')
                temporary.write_text(json.dumps(switched))
                os.replace(temporary, network)
                time.sleep(0.8)
                self.assertEqual(state()['dns']['ORICO-2.5G'], original['ORICO-2.5G'])
                wait_for(lambda: state()['dns']['ORICO-2.5G'] == ['127.0.0.1'])
                self.assertIsNone(child.poll())
                for name in ['refresh1', 'refresh2']:
                    result = rpc('refresh-dns', name)
                    self.assertTrue(result['ok'])
                    self.assertTrue(result['identityVerified'])
                    self.assertTrue(result['dnsRefreshOk'])
                    self.assertEqual(result['pid'], child.pid)
                    self.assertEqual(result['targetPid'], child.pid)
                snapshots = sorted(p.read_text() for p in (data / 'helper/dns-state.d').glob('*.state'))
                self.assertEqual(snapshots, ['ORICO-2.5G\nSERVERS\n119.29.29.29\n223.5.5.5\n', 'Wi-Fi\nEMPTY\n'])
                # Reject an identity mismatch without touching either DNS service.
                identity.write_text(f'{child.pid}\n/bin/sleep\nwrong-start-time\n')
                changes = state()['changes']
                rejected = rpc('refresh-dns', 'mismatch')
                self.assertFalse(rejected['ok'])
                self.assertEqual(rejected['error'], 'identity_mismatch')
                self.assertEqual(state()['changes'], changes)
                identity.write_text(f'{child.pid}\n/bin/sleep\n{start}\nfixture\n')
                stopped = rpc('stop', 'stop')
                self.assertTrue(stopped['ok'])
                self.assertTrue(stopped['processExitConfirmed'])
                self.assertTrue(stopped['dnsRestoreOk'])
                self.assertEqual(state()['dns'], original)
                self.assertEqual(list((data / 'helper/dns-state.d').glob('*.state')), [])
                self.assertIsNotNone(child.poll())
                self.assertFalse(stderr.read_text(), stderr.read_text())
            finally:
                daemon.terminate()
                daemon.wait(timeout=5)
                if child.poll() is None:
                    child.terminate()
                    child.wait(timeout=5)


    def test_planted_links_are_not_followed_and_orphan_dns_is_restored(self):
        with tempfile.TemporaryDirectory(prefix='splitvpn-helper-links-') as directory:
            root = Path(directory)
            data = root / 'data'
            for sub in ['mihomo', 'logs', 'helper/responses', 'helper/dns-state.d']:
                (data / sub).mkdir(parents=True)
            identities = root / 'identity'
            identities.mkdir()
            network = root / 'network.json'
            # A crashed engine left Wi-Fi on 127.0.0.1 with its snapshot behind.
            network.write_text(json.dumps({'device': 'en0', 'dns': {'Wi-Fi': ['127.0.0.1'], 'ORICO-2.5G': []}, 'changes': []}))
            (data / 'helper/dns-state.d/Wi-Fi-1.state').write_text('Wi-Fi\nSERVERS\n223.5.5.5\n$(touch /tmp/x)\n')
            for name in ['networksetup', 'route']:
                path = root / name
                path.write_text(MOCK)
                path.chmod(0o755)
            victim = root / 'victim'
            victim.write_text('untouched\n')
            victim.chmod(0o600)
            (data / 'logs/mihomo.log').symlink_to(victim)
            (data / 'helper/responses/planted.tmp').symlink_to(victim)
            script = (ROOT / 'packages/vpn-core/assets/macos-helper.sh').read_text()
            for before, after in {
                'MIHOMO="/Library/PrivilegedHelperTools/com.split-vpn.mihomo"': 'MIHOMO="/bin/sleep"',
                'IDENTITY_DIR="/var/db/com.split-vpn.helper"': f'IDENTITY_DIR="{identities}"',
                '/usr/sbin/networksetup': str(root / 'networksetup'),
                '/sbin/route': str(root / 'route'),
                '/usr/bin/dscacheutil': '/usr/bin/true',
                '/usr/bin/killall': '/usr/bin/true',
            }.items():
                script = script.replace(before, after)
            helper = root / 'helper.sh'
            helper.write_text(script)
            stderr = root / 'stderr'
            with stderr.open('w') as err:
                daemon = subprocess.Popen(['/bin/sh', str(helper), 'daemon', str(data)], stdout=subprocess.DEVNULL, stderr=err)
            fifo = data / 'helper/control.pipe'
            def wait_for(condition, timeout=25):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if condition():
                        return
                    self.assertIsNone(daemon.poll(), stderr.read_text())
                    time.sleep(0.2)
                self.fail('helper condition timed out: '+stderr.read_text())
            try:
                wait_for(fifo.exists, 5)
                self.assertEqual(fifo.stat().st_mode & 0o777, 0o600)
                with fifo.open('w') as pipe:
                    pipe.write('planted status\n')
                wait_for((data / 'helper/responses/planted.json').exists, 8)
                self.assertTrue(json.loads((data / 'helper/responses/planted.json').read_text())['ok'])
                # The engine stays absent, so the original DNS comes back by itself.
                wait_for(lambda: json.loads(network.read_text())['dns']['Wi-Fi'] == ['223.5.5.5'])
                self.assertEqual(list((data / 'helper/dns-state.d').glob('*.state')), [])
                self.assertFalse(Path('/tmp/x').exists() and Path('/tmp/x').stat().st_mtime > victim.stat().st_mtime)
                self.assertEqual(victim.read_text(), 'untouched\n')
                self.assertEqual(victim.stat().st_mode & 0o777, 0o600)
                self.assertFalse((data / 'logs/mihomo.log').is_symlink())
            finally:
                daemon.terminate()
                daemon.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
