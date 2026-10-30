#!/usr/bin/env python3
"""Actual mobile rules, loopback listeners only; never TUN, DNS or real VPN."""
import argparse, ctypes, http.client, json, os, socket, struct, subprocess, tempfile, threading, time
from pathlib import Path
import yaml

def port():
    with socket.socket() as s: s.bind(('127.0.0.1',0)); return s.getsockname()[1]
def exact(stream,n):
    data=b''
    while len(data)<n:
        chunk=stream.recv(n-len(data))
        if not chunk: raise EOFError()
        data+=chunk
    return data
class Backend:
    def __init__(self):
        self.records=[]; self.socket=socket.socket();self.socket.bind(('127.0.0.1',0));self.socket.listen();self.port=self.socket.getsockname()[1]
        threading.Thread(target=self.run,daemon=True).start()
    def run(self):
        while True:
            try: stream,_=self.socket.accept()
            except OSError:return
            with stream:
                stream.settimeout(3)
                try:
                    header=exact(stream,2);exact(stream,header[1]);stream.sendall(b'\x05\x00')
                    header=exact(stream,4);kind=header[3]
                    host=socket.inet_ntoa(exact(stream,4)) if kind==1 else exact(stream,exact(stream,1)[0]).decode()
                    target=(host,struct.unpack('!H',exact(stream,2))[0]);self.records.append(target)
                    stream.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00')
                    data=b''
                    while b'\r\n\r\n' not in data:data+=exact(stream,1)
                    stream.sendall(b'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                except (OSError,EOFError):pass
    def close(self):
        try:self.socket.shutdown(socket.SHUT_RDWR)
        except OSError:pass
        self.socket.close()
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--core',required=True);parser.add_argument('--mihomo',required=True);parser.add_argument('--singbox',required=True);args=parser.parse_args()
    os.environ['SPLITVPN_ISOLATED']='1'
    core=ctypes.CDLL(str(Path(args.core).resolve()));core.qz_core_call.argtypes=[ctypes.c_char_p,ctypes.c_char_p];core.qz_core_call.restype=ctypes.c_void_p;core.qz_core_free.argtypes=[ctypes.c_void_p]
    with tempfile.TemporaryDirectory(prefix='qz-company-engine-') as tmp:
        root=Path(tmp);backend=Backend()
        def call(channel,payload={}):
            ptr=core.qz_core_call(str(root).encode(),json.dumps({'channel':channel,'payload':payload}).encode())
            try: reply=json.loads(ctypes.string_at(ptr))
            finally:core.qz_core_free(ptr)
            assert reply['ok'],reply
            return reply['data']
        record={'enabled':True,'origin':'https://vpn.example.test','username':'fixture','fingerprint':'ab'*32,'resources':[{'name':'fixture','address':'10.0.0.8/32','ports':'443','network':'tcp'}]}
        call('company:mobile:configure',record);call('settings:patch',{'selectedProxy':'DIRECT'});transport={**record,'port':backend.port}
        for name in ['mihomo','singbox']:
            listen=port()
            if name=='mihomo':
                generated=call('mihomo:generate',{'companyTunnel':transport});original=yaml.safe_load(Path(generated['config']).read_text())
                config={'mixed-port':listen,'bind-address':'127.0.0.1','allow-lan':False,'log-level':'silent','tun':{'enable':False},'dns':{'enable':False},'proxies':[p for p in original['proxies'] if p['name'].startswith('COMPANY-')],'proxy-groups':[],'rules':[r for r in original['rules'] if 'COMPANY-' in r or '10.0.0.8/32' in r]+['MATCH,REJECT']}
                command=[str(Path(args.mihomo).resolve()),'-d',tmp,'-f',str(root/'engine.json')]
            else:
                generated=call('singbox:generate',{'companyTunnel':transport});config=json.loads(generated['config'])
                config['inbounds']=[{'type':'mixed','tag':'fixture-in','listen':'127.0.0.1','listen_port':listen}]
                config['outbounds']=[o for o in config['outbounds'] if o['tag'].startswith('COMPANY-')]+[{'type':'block','tag':'block'}]
                config['route']={'rules':[r for r in config['route']['rules'] if r.get('outbound','').startswith('COMPANY-') or r.get('ip_cidr')==['10.0.0.8/32']],'final':'block'}
                config.pop('dns',None);config.pop('experimental',None)
                command=[str(Path(args.singbox).resolve()),'run','-c',str(root/'engine.json')]
            (root/'engine.json').write_text(json.dumps(config))
            log=(root/(name+'.log')).open('w+');process=subprocess.Popen(command,cwd=tmp,stdout=log,stderr=log)
            try:
                deadline=time.monotonic()+10
                while True:
                    try:
                        with socket.create_connection(('127.0.0.1',listen),timeout=.1):break
                    except OSError:
                        if process.poll() is not None or time.monotonic()>deadline:log.seek(0);raise AssertionError(log.read())
                        time.sleep(.05)
                def request(target):
                    connection=http.client.HTTPConnection('127.0.0.1',listen,timeout=3)
                    try:connection.request('GET',target);return connection.getresponse().status
                    except (OSError,http.client.HTTPException):return None
                    finally:connection.close()
                before=len(backend.records);assert request('http://10.0.0.8:443/')==204,name
                assert backend.records[before:]==[('10.0.0.8',443)],backend.records
                before=len(backend.records);assert request('http://10.0.0.8:444/')!=204,name;assert len(backend.records)==before,'unauthorized port reached backend'
                backend.close();assert request('http://10.0.0.8:443/')!=204,'closed backend fell through'
                print(name+': authorized TCP traversed backend; unauthorized port and unavailable backend rejected; no external sockets')
                backend=Backend();transport['port']=backend.port
            finally:process.terminate();process.wait(timeout=5);log.close()
        backend.close()
if __name__=='__main__':main()
