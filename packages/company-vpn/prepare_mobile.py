#!/usr/bin/env python3
"""Stage a gomobile package from the same reviewed helper, never a live app."""
import argparse,json,os,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parent
parser=argparse.ArgumentParser();parser.add_argument('--skip-prepare',action='store_true');args=parser.parse_args()
if not args.skip_prepare:subprocess.run(['python3',str(ROOT/'prepare.py')],check=True)
source=ROOT/'.local/source'
for file in (ROOT/'overlay/client/atrust/auth').glob('company_*.go'):shutil.copy2(file,source/'client/atrust/auth'/file.name)
# The reviewed security overlay propagates anti-MITM failures. Keep the two
# upstream regression expectations aligned with that stricter contract.
security_tests=source/'client/atrust/auth/tls_test.go'
text=security_tests.read_text().replace('TestAuthConfigReportsButDoesNotPropagate','TestAuthConfigRejects')
text=text.replace('if _, _, err := session.authConfig(false, true); err != nil {\n\t\tt.Fatalf("official authentication caller does not propagate the check result: %v", err)\n\t}', 'if _, _, err := session.authConfig(false, true); err == nil {\n\t\tt.Fatal("anti-MITM failure was ignored")\n\t}')
security_tests.write_text(text)
target=source/'mobile/companymobile';target.mkdir(parents=True,exist_ok=True)
for file in (ROOT/'overlay/cmd/company-account-helper').glob('*.go'):
 text=file.read_text().replace('package main','package companymobile',1)
 if file.name=='main.go':
  text=text.replace('"bufio"','"bufio"\n "context"')
  text=text.replace('type bridge struct {','type bridge struct {\n ctx context.Context\n cancel context.CancelFunc\n capture func(*auth.Session,*url.URL,string,string,[]byte)')
  text=text.replace('os.Exit(0) // The native window has closed; retain no session on disk.','if b.cancel != nil { b.cancel() }; return')
  text=text.replace('"github.com/mythologyli/zju-connect/client/atrust/auth"','"github.com/mythologyli/zju-connect/client/atrust/auth"\n "github.com/mythologyli/zju-connect/internal/platformdialer"')
  text=text.replace('s := auth.NewSession(u.Host, nil)','dialer := &platformdialer.Dialer{InterfaceName:c.InterfaceName}; s := auth.NewSession(u.Host, nil, dialer.DialContext)')
  text=text.replace('s.SetCertificatePin(c.Fingerprint)' ,'s.SetCertificatePin(c.Fingerprint)\n s.SetLifecycleContext(b.ctx)')
  text=text.replace('p, err := probe(u)','p, err := probeWithContext(b.ctx, u, c.InterfaceName)')
  text=text.replace('raw, _, _ := b.fetchResources(s)','raw, _, _ := b.fetchResources(s)\n if raw != nil && b.capture != nil { b.capture(s,u,result.Username,hex.EncodeToString(device),raw) }',1)
  text=text.replace('raw, _, _ = b.fetchResources(s)','raw, _, _ = b.fetchResources(s)\n if raw != nil && b.capture != nil { b.capture(s,u,result.Username,hex.EncodeToString(device),raw) }')
 if file.name=='probe.go':
  text=text.replace('func probe(u *url.URL) (probeInfo, error) {','func probe(u *url.URL) (probeInfo, error) { return probeWithContext(context.Background(),u, "") }\nfunc probeWithContext(parent context.Context,u *url.URL,interfaceName string) (probeInfo, error) {\n if parent==nil {parent=context.Background()}')
  text=text.replace('context.WithTimeout(context.Background(), 10*time.Second)','context.WithTimeout(parent, 10*time.Second)')
  text=text.replace('http.NewRequest(http.MethodGet,','http.NewRequestWithContext(ctx,http.MethodGet,')
  text=text.replace('"github.com/mythologyli/zju-connect/internal/companycert"','"github.com/mythologyli/zju-connect/internal/companycert"\n "github.com/mythologyli/zju-connect/internal/platformdialer"')
  text=text.replace('dialer := tls.Dialer{NetDialer: &net.Dialer{Timeout: 8 * time.Second}, Config: &tls.Config{','netDialer := &platformdialer.Dialer{InterfaceName:interfaceName}; dialer := tls.Dialer{Config: &tls.Config{')
  text=text.replace('connection, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(u.Hostname(), port))','raw, err := netDialer.DialContext(ctx,"tcp",net.JoinHostPort(u.Hostname(),port)); if err != nil { return result,err }; tlsConnection := tls.Client(raw,dialer.Config); if err = tlsConnection.HandshakeContext(ctx); err != nil { _ = raw.Close(); return result,err }; var connection net.Conn=tlsConnection')
  text=text.replace('tlsConnection := connection.(*tls.Conn)','tlsConnection = connection.(*tls.Conn)')
  text=text.replace('tr := &http.Transport{TLSClientConfig:', 'tr := &http.Transport{DialContext:netDialer.DialContext,TLSClientConfig:')
 (target/file.name).write_text(text)
for file in (ROOT/'mobile/companymobile').glob('*.go'):shutil.copy2(file,target/file.name)
version=json.loads((ROOT.parents[1]/'third_party/dependencies.lock.json').read_text())['dependencies']['zju_connect']['go_version']
env={**os.environ,'GOTOOLCHAIN':'go'+version,'GOWORK':'off','GOPATH':str(ROOT/'.local/go-path'),'GOCACHE':str(ROOT/'.local/go-cache'),'GOMODCACHE':str(ROOT/'.local/go-modules')}
env.pop('GOROOT',None);env.pop('GOFLAGS',None)
subprocess.run(['gofmt','-w',str(target)],check=True)
subprocess.run(['go','test','./mobile/companymobile','./client/atrust/auth'],cwd=source,env=env,check=True)
print('Embedded mobile package staged and tested.')
