#!/usr/bin/env python3
"""Smoke the native aTrust page on an explicitly selected disposable emulator.
Never click VPN connect after authentication or use an account/gateway.
"""
import argparse, re, subprocess, time, xml.etree.ElementTree as ET
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--adb',default='adb');p.add_argument('--serial',required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
assert a.serial.startswith('emulator-'),'Use a disposable emulator, never a real device'
a.out.mkdir(parents=True,exist_ok=True)
def adb(*args):return subprocess.check_output([a.adb,'-s',a.serial,*args])
def dump():
    adb('shell','uiautomator','dump','/sdcard/qz-company-ui.xml')
    return ET.fromstring(adb('shell','cat','/sdcard/qz-company-ui.xml'))
def find(text):
    deadline=time.monotonic()+15
    while time.monotonic()<deadline:
        root=dump()
        for node in root.iter('node'):
            if node.get('text')==text:return node
    raise AssertionError('Missing UI: '+text)
def tap(text):
    node=find(text);x1,y1,x2,y2=map(int,re.findall(r'\d+',node.get('bounds')))
    adb('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2))
adb('shell','input','keyevent','KEYCODE_WAKEUP');adb('shell','wm','dismiss-keyguard')
adb('shell','am','force-stop','dev.splitvpn.android');adb('shell','am','start','-n','dev.splitvpn.android/.MainActivity')
tap('诊断');tap('aTrust 私有网络');find('HTTPS 接入地址')
tap('登录并获取授权资源');find('请检测当前入口并核对证书')
tap('连接接入');find('请先完成接入认证')
adb('shell','input','swipe','600','1850','600','650','500');find('通过当前接入隧道验证业务')
adb('shell','screencap','-p','/sdcard/qz-company-ui.png');adb('pull','/sdcard/qz-company-ui.png',str(a.out/'android-company-lower.png'))
adb('shell','input','swipe','600','650','600','1850','500');find('HTTPS 接入地址')
adb('shell','screencap','-p','/sdcard/qz-company-ui.png');adb('pull','/sdcard/qz-company-ui.png',str(a.out/'android-company-final.png'))
tap('关闭')
assert adb('shell','pidof','dev.splitvpn.android').strip(),'App crashed'
(a.out/'android-company-final.xml').write_bytes(adb('shell','cat','/sdcard/qz-company-ui.xml'))
print('PASS: cold launch, aTrust page, certificate gate, unauthenticated connection gate, scroll, business verification controls, dismiss; no account or VPN started')
