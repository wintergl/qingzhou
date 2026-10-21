#!/usr/bin/env python3
"""Build a pinned, isolated aTrust backend; never modify the live application."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
LOCAL = ROOT / '.local'
REVISION = '923672dc927e43e04592595a0005ad90a7a3afb5'
UPSTREAM = 'https://github.com/Mythologyli/zju-connect.git'
DEPENDENCY = json.loads((ROOT.parents[1] / 'third_party/dependencies.lock.json').read_text())['dependencies']['zju_connect']
if DEPENDENCY['commit'] != REVISION or DEPENDENCY['repository'] != UPSTREAM:
    raise RuntimeError('统一锁文件与适配补丁的上游版本不一致。')

def run(*args, cwd=None, env=None):
    subprocess.run(args, cwd=cwd, env=env, check=True)

def replace_once(path, before, after):
    text = path.read_text()
    if text.count(before) != 1:
        raise RuntimeError(f'固定版本的补丁上下文不匹配：{path.name}')
    path.write_text(text.replace(before, after, 1))

def add_import(path, package):
    replace_once(path, 'import (\n', f'import (\n\t"github.com/mythologyli/zju-connect/internal/{package}"\n')

parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, help='已有的固定版本源码，省去重新下载')
args = parser.parse_args()
LOCAL.mkdir(exist_ok=True)
upstream = args.source or LOCAL / 'upstream'
if not upstream.exists():
    run('git', 'init', str(upstream))
    run('git', '-C', str(upstream), 'fetch', '--depth', '1', UPSTREAM, REVISION)
    run('git', '-C', str(upstream), 'checkout', '--detach', 'FETCH_HEAD')
head = subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip()
if head != REVISION:
    raise RuntimeError('源码版本与已审阅版本不一致，停止构建')
source = LOCAL / 'source'
if source.exists():
    if not (source / '.splitvpn-experiment-owned').exists():
        raise RuntimeError('源码目录不属于本实验，停止覆盖')
    shutil.rmtree(source)
shutil.copytree(upstream, source, ignore=shutil.ignore_patterns('.git'))
(source / '.splitvpn-experiment-owned').write_text(REVISION + '\n')
shutil.copytree(ROOT / 'overlay', source, dirs_exist_ok=True)

auth = source / 'client/atrust/auth/auth.go'
add_import(auth, 'companycert')
replace_once(auth, 'InsecureSkipVerify: true,', 'InsecureSkipVerify: true,\n\t\t\tVerifyConnection: companycert.VerifyConnection,\n\t\t\tMinVersion: tls.VersionTLS12,')
# Identify this experimental client and its actual platform.
text = auth.read_text()
text, count = re.subn(r'UserAgent\s*= "[^"]+"', 'UserAgent = "SplitVPN-CompanyExperiment/0.1 (macOS)"', text)
if count != 1:
    raise RuntimeError('User-Agent 补丁上下文不匹配')
auth.write_text(text)
replace_once(auth, '"platform":   {"Linux"}', '"platform":   {"Mac"}')
replace_once(auth, 'type Session struct {', 'type Session struct {\n\tpasswordChangeHandler PasswordChangeHandler\n\tpasswordChangeInfo passwordChangeData')
replace_once(auth, 'type LoginOptions struct {', 'type LoginOptions struct {\n\tPasswordChangeHandler PasswordChangeHandler')
replace_once(auth, '\ts.challengeHandler = opts.ChallengeHandler', '\ts.passwordChangeHandler = opts.PasswordChangeHandler\n\ts.challengeHandler = opts.ChallengeHandler')
replace_once(auth, '\t\tcase "auth/token":', '\t\tcase "auth/modifyPwd":\n\t\t\tstep, err = s.completePasswordChange(step)\n\t\tcase "auth/token":')
replace_once(auth, '\t\tvar err error\n\t\tswitch step.Service', '\t\tif step.AntiReplayRand != "" { s.antiReplayRand = step.AntiReplayRand }\n\t\tvar err error\n\t\tswitch step.Service')

transport = source / 'client/atrust/tls.go'
add_import(transport, 'companycert')
replace_once(transport, '\tif keyLogWriter != nil {', '\tconfig.InsecureSkipVerify = true\n\tconfig.VerifyConnection = companycert.VerifyConnection\n\tconfig.MinVersion = tls.VersionTLS12\n\tif keyLogWriter != nil {')

requests = source / 'client/atrust/auth/request.go'
replace_once(requests, 'type authStepData struct {', 'type authStepData struct {\n\tpasswordChangeData\n\tAntiReplayRand string `json:"antiReplayRand"`')
replace_once(requests, 'type authStep struct {', 'type authStep struct {\n\tPasswordChange passwordChangeData\n\tAntiReplayRand string')
replace_once(requests, 'step := authStep{Service: data.NextService}', 'step := authStep{Service: data.NextService, PasswordChange: data.passwordChangeData, AntiReplayRand: data.AntiReplayRand}')
password = source / 'client/atrust/auth/psw.go'
replace_once(password, '\t\t\tTicket               string', '\t\t\tpasswordChangeData\n\t\t\tTicket               string')
replace_once(password, '\ts.nextService = re.Data.NextService', '\ts.passwordChangeInfo = re.Data.passwordChangeData\n\ts.nextService = re.Data.NextService')
replace_once(requests, 'if len(re.Data.AntiMITM.raw) != 0 {', 'if re.Data.AntiMITM.Enable == 1 && len(re.Data.AntiMITM.raw) != 0 {')
replace_once(requests, 'log.Printf("aTrust anti-MITM check failed: %v", err)', 'return 0, nil, fmt.Errorf("aTrust anti-MITM verification failed: %w", err)')
# Resource failures must never become an apparently successful empty list.
text = requests.read_text()
start = text.index('func (s *Session) ClientResource()')
end = text.index('func (s *Session) checkCode()', start)
segment = text[start:end]
before = 'body, _ := io.ReadAll(resp.Body)'
after = '''if resp.StatusCode != http.StatusOK {
        return nil, fmt.Errorf("clientResource HTTP %d", resp.StatusCode)
    }
    body, err := io.ReadAll(io.LimitReader(resp.Body, 16*1024*1024+1))
    if err != nil { return nil, err }
    if len(body) > 16*1024*1024 { return nil, fmt.Errorf("clientResource response too large") }'''
if segment.count(before) != 1:
    raise RuntimeError('授权资源补丁上下文不匹配')
requests.write_text(text[:start] + segment.replace(before, after, 1) + text[end:])

# The native app needs only the aTrust TCP data plane, sharing the existing
# Mihomo TUN. Avoid allocating an unused second L3 data plane.
client_source = source / 'client/atrust/client.go'
replace_once(client_source, 'type SetupOptions struct {', 'type SetupOptions struct {\n\tSkipL3 bool // Native shared-TUN TCP mode; all other callers keep L3 setup.')
replace_once(client_source, 'type Client struct {', 'type Client struct {\n\tcompanyTCPOnly bool')
replace_once(client_source, '\tc.serverAddress = options.ServerAddress', '\tc.companyTCPOnly = options.SkipL3\n\tc.serverAddress = options.ServerAddress')
text = client_source.read_text()
start = text.index('\terr = c.getIP()')
end = text.index('\tif options.SaveClientData != nil {', start)
text = text[:start] + '\tif !options.SkipL3 {\n' + text[start:end] + '\t}\n' + text[end:]
client_source.write_text(text)

# Replacing all working TCP outlets with an empty map after a short routing
# interruption made company requests fail until the next two-minute refresh.
nodes = source / 'client/atrust/node.go'
replace_once(nodes, '\t\tc.BestNodes = bestNodes', '\t\tif c.companyTCPOnly { bestNodes = companyReachableNodes(c.NodeGroups, c.BestNodes, bestNodes) }\n\t\tc.BestNodes = bestNodes')

tcp = source / 'client/atrust/tcptunnel.go'
add_import(tcp, 'companyprocess')
replace_once(tcp, '\tprocName := "google-chrome-stable"\n\tprocPath := "/usr/bin/google-chrome-stable"\n\tif addr.Port == 22 {\n\t\tprocName = "ssh"\n\t\tprocPath = "/usr/bin/ssh"\n\t}\n\tprocHash := fmt.Sprintf("%X", sha256.Sum256([]byte(procPath)))', '\tproc := companyprocess.Current()\n\tprocName, procPath, procHash := proc.Name, proc.Path, proc.Fingerprint')
replace_once(tcp, 'DigitalSignature: "TrustAppClosed",', 'DigitalSignature: "",')
replace_once(tcp, 'Platform:         "Linux",', 'Platform:         proc.Platform,')
replace_once(tcp, 'Description:      "TrustAppClosed",', 'Description:      "split-vpn company connection experiment",')
replace_once(tcp, 'Version:          "TrustAppClosed",', 'Version:          "0.1",')
replace_once(tcp, 'SecurityEnv:      "normal",', 'SecurityEnv:      "UNKNOWN",')
replace_once(tcp, 'ProcessTrusted = "TRUSTED"', 'ProcessTrusted = "UNKNOWN"')
# An expired session is a returned error, allowing the owner to restore its
# routing transaction. Never kill the process from a connection callback.
replace_once(tcp, 'log.Fatalf("tcp tunnel: aTrust session is invalid (code %d): %s", response.Code, response.Message)',
             'return fmt.Errorf("aTrust session is invalid with code %d", response.Code)')

l3 = source / 'client/atrust/l3tunnelconn.go'
add_import(l3, 'companyprocess')
text = l3.read_text()
replacement = '''func defaultEnv(info clientInfo) *trustEnv {
    proc := companyprocess.Current()
    var env trustEnv
    env.Application.Runtime.Process.Name = proc.Name
    env.Application.Runtime.Process.Path = proc.Path
    env.Application.Runtime.Process.Fingerprint = proc.Fingerprint
    env.Application.Runtime.Process.Platform = proc.Platform
    env.Application.Runtime.Process.Version = "0.1"
    env.Application.Runtime.Process.Description = "split-vpn company connection experiment"
    env.Application.Runtime.Process.SecurityEnv = "UNKNOWN"
    env.Application.Runtime.ProcessTrusted = "UNKNOWN"
    return &env
}'''
text, count = re.subn(r'func defaultEnv\(info clientInfo\) \*trustEnv \{.*?\n\}', replacement, text, flags=re.S)
if count != 1:
    raise RuntimeError('设备环境补丁上下文不匹配')
for package in ('runtime', 'crypto/sha256'):
    if package.rsplit('/', 1)[-1] + '.' not in text:
        text = text.replace(f'\t"{package}"\n', '')
l3.write_text(text)

env = os.environ.copy()
env.pop('GOFLAGS', None)
env.pop('GOROOT', None)
env.update(GOTOOLCHAIN='go' + DEPENDENCY['go_version'], GOWORK='off', GOCACHE=str(LOCAL / 'go-cache'), GOMODCACHE=str(LOCAL / 'go-modules'))
paths = [auth, password, transport, requests, client_source, nodes, tcp, l3, *source.glob('client/atrust/company_*.go'), *source.glob('client/atrust/auth/company_*.go'), *source.glob('internal/company*/*.go'), *source.glob('cmd/company-account-helper/*.go')]
run('gofmt', '-w', *map(str, paths))
print('验证证书拦截，再构建独立连接内核。', flush=True)
run('go', 'test', './internal/companycert', cwd=source, env=env)
run('go', 'test', './cmd/company-account-helper', cwd=source, env=env)
run('go', 'test', './client/atrust', '-run', '^TestCompanyNode', cwd=source, env=env)
binary = LOCAL / 'bin/company-connect'
binary.parent.mkdir(exist_ok=True)
run('go', 'build', '-trimpath', '-buildvcs=false', '-ldflags', f'-X main.zjuConnectVersion=splitvpn-company-experiment -X main.CommitID={REVISION}',
    '-o', str(binary), '.', cwd=source, env=env)
print(f'实验内核已生成：{binary}')
account_binary = LOCAL / 'bin/company-account-helper'
run('go', 'build', '-trimpath', '-buildvcs=false', '-o', str(account_binary), './cmd/company-account-helper', cwd=source, env=env)
print(f'账号测试内核已生成：{account_binary}')
