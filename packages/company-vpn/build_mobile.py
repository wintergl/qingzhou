#!/usr/bin/env python3
"""Build mobile bindings without fetching or replacing the user's Libbox source."""
import argparse,hashlib,json,os,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[1];LOCAL=ROOT/'.local/mobile'
p=argparse.ArgumentParser();p.add_argument('platform',choices=['host','android','ios']);p.add_argument('--skip-prepare',action='store_true');p.add_argument('--reuse-stage',action='store_true');args=p.parse_args()
if not args.skip_prepare:subprocess.run(['python3',str(ROOT/'prepare_mobile.py')],check=True)
reviewed=ROOT/'.local/source';LOCAL.mkdir(parents=True,exist_ok=True)
company=LOCAL/'company-source'
if company.exists() and not (company/'.splitvpn-experiment-owned').exists():raise SystemExit('Refusing to replace an unowned company staging directory')
if not args.reuse_stage:shutil.copytree(reviewed,company,dirs_exist_ok=True)
if not company.exists():raise SystemExit('Prepare the reviewed company source first')
# The native owner supplies the physical interface on iOS. Android excludes
# its own UID from its VPN. Do not embed a second, older TUN implementation.
underlay=company/'underlay/dialer.go';text=underlay.read_text()
start=text.index('func detectDefaultInterface() string {');end=text.index('\nfunc usableInterface(',start)
text=text[:start]+'func detectDefaultInterface() string { return "" }\n'+text[end:]
for line in ['\t"net/netip"\n','\ttun "github.com/mythologyli/sing-tun"\n','\t"github.com/sagernet/sing/common/logger"\n']:text=text.replace(line,'')
underlay.write_text(text)
version=json.loads((REPO/'third_party/dependencies.lock.json').read_text())['dependencies']['zju_connect']['go_version']
env={**os.environ,'GOTOOLCHAIN':'go'+version,'GOWORK':'off','GOPATH':str(ROOT/'.local/go-path'),'GOCACHE':str(ROOT/'.local/go-cache'),'GOMODCACHE':str(ROOT/'.local/go-modules')}
env.pop('GOROOT',None);env.pop('GOFLAGS',None)
gomobile=Path(subprocess.check_output(['go','env','GOPATH'],text=True).strip())/'bin/gomobile'
# Keep the user's globally installed tools intact. This pinned fork overwrites
# GOFLAGS for Apple builds; retain -mod=mod for its generated work module.
tools=LOCAL/'gomobile-tools';tool_source=ROOT/'.local/go-modules/github.com/sagernet/gomobile@v0.1.12'
if not tool_source.exists():subprocess.run(['go','mod','download','github.com/sagernet/gomobile@v0.1.12'],env=env,check=True)
if not tools.exists():shutil.copytree(tool_source,tools)
patched=tools/'cmd/gomobile/env.go';text=patched.read_text();old='"GOFLAGS="+"-tags="+strings.Join(platformTags(platform), ","),';new='"GOFLAGS="+os.Getenv("GOFLAGS")+" -tags="+strings.Join(platformTags(platform), ","),'
if old in text:patched.chmod(0o644);patched.write_text(text.replace(old,new))
tool_bin=LOCAL/'bin';tool_bin.mkdir(exist_ok=True)
for command in ['gomobile','gobind']:
 target=tool_bin/command
 if not target.exists() or target.stat().st_mtime<patched.stat().st_mtime:subprocess.run(['go','build','-o',str(target),'./cmd/'+command],cwd=tools,env=env,check=True)
gomobile=tool_bin/'gomobile';env['PATH']=str(tool_bin)+os.pathsep+env.get('PATH','');env['GOFLAGS']='-mod=mod'

if args.platform=='android':
 env['JAVA_HOME']=env.get('JAVA_HOME','/Applications/Android Studio.app/Contents/jbr/Contents/Home');env['ANDROID_HOME']=env.get('ANDROID_HOME',env.get('ANDROID_SDK_ROOT',str(Path.home()/'Library/Android/sdk')))
 subprocess.run(['go','mod','edit','-require=github.com/sagernet/gomobile@v0.1.12'],cwd=company,env=env,check=True)
 output=LOCAL/'CompanyCore.aar'
 subprocess.run([str(gomobile),'bind','-target=android/arm64','-androidapi=26','-javapkg=dev.splitvpn.company','-trimpath','-ldflags=-s -w -buildid= -extldflags=-Wl,-z,max-page-size=16384','-o',str(output),'./mobile/companymobile'],cwd=company,env=env,check=True)
 print('Android mobile binding:',output)
else:
 original=REPO/'apps/iphone/ThirdParty/sing-box-src';stage=LOCAL/'libbox-source';marker=stage/'.splitvpn-mobile-owned'
 if stage.exists() and not marker.exists():raise SystemExit('Refusing to replace an unowned staging directory')
 # Copy only reviewed local source; no git fetch/checkout or upstream mutation.
 shutil.copytree(original,stage,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.git','*.xcframework','*.aar','libbox.aar'))
 marker.write_text('company-mobile-libbox\n')
 overlay=REPO/'apps/iphone/GoOverlay';shutil.copytree(overlay,stage,dirs_exist_ok=True)
 registry=stage/'include/registry.go';text=registry.read_text();marker='\tgroup.RegisterURLTest(registry)';assert text.count(marker)==1;registry.write_text(text.replace(marker,marker+'\n\tgroup.RegisterQZBalance(registry)'))

 with (stage/'go.mod').open('a') as f:f.write('\nrequire github.com/mythologyli/zju-connect v0.0.0\nreplace github.com/mythologyli/zju-connect => ../company-source\nreplace inet.af/netaddr => github.com/inetaf/netaddr v0.0.0-20230525184311-b8eac61e914a\n')
 # Both locked dependency sets are already reviewed in the local build trees.
 (stage/'go.sum').write_text(''.join(sorted(set((original/'go.sum').read_text().splitlines(keepends=True)+(company/'go.sum').read_text().splitlines(keepends=True)))))
 cached=Path(subprocess.check_output(['go','env','GOMODCACHE'],text=True).strip())
 env['GOPROXY']=f'file://{ROOT}/.local/go-modules/cache/download,file://{cached}/cache/download,https://proxy.golang.org'
 tags='with_quic,with_utls,with_gvisor,with_wireguard,with_dhcp,with_clash_api,with_low_memory'
 if args.platform=='host':
  subprocess.run(['go','test','-mod=mod','-tags',tags,'github.com/mythologyli/zju-connect/mobile/companymobile','./experimental/libbox','./protocol/group'],cwd=stage,env=env,check=True)
 else:
  output=LOCAL/'Libbox.xcframework'
  env['GOFLAGS']='-mod=mod'
  subprocess.run([str(gomobile),'bind','-target=ios/arm64,iossimulator/arm64,iossimulator/amd64','-iosversion=17.0','-libname=box','-trimpath','-tags',tags,'-ldflags=-s -w -buildid= -checklinkname=0','-o',str(output),'./experimental/libbox','github.com/mythologyli/zju-connect/mobile/companymobile'],cwd=stage,env=env,check=True)
  print('Combined Apple binding:',output)

# Record the exact staged inputs and dependency locks, without host paths.
manifest={"companyUpstream":"923672dc927e43e04592595a0005ad90a7a3afb5","gomobile":"v0.1.12","platform":args.platform,"files":{}}
for label,tree in [("company",company)]+([] if args.platform=="android" else [("libbox",stage)]):
 for file in sorted(tree.rglob("*")):
  if file.is_file() and (file.suffix==".go" or file.name in ["go.mod","go.sum"]):
   data=file.read_bytes().replace(str(company).encode(),b"../company-source")
   manifest["files"][label+"/"+file.relative_to(tree).as_posix()]=hashlib.sha256(data).hexdigest()
(LOCAL/(args.platform+"-source-manifest.json")).write_text(json.dumps(manifest,indent=2)+"\n")
