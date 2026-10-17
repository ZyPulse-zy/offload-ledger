#!/usr/bin/env python3
"""Private crash-test adapter, always executed inside fenced-run and a netns.

No production ABI or discovery: this owns one private software rule slot.
Reconciliation reads and writes under the same inherited writer exclusion.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

if os.geteuid() != 0 or os.readlink('/proc/self/ns/net') == os.environ.get('OFFLOAD_LAB_PARENT_NETNS', os.readlink('/proc/self/ns/net')):
    raise SystemExit('Refusing writes outside a distinct network namespace')
if 'FENCED_RUN_LOCK_FD' not in os.environ:
    raise SystemExit('Worker requires inherited writer exclusion')
lock_fd=int(os.environ['FENCED_RUN_LOCK_FD'])
os.fstat(lock_fd)
root=Path(__file__).resolve().parents[2]
directory=Path(sys.argv[1]);lua=sys.argv[2];module=sys.argv[3]
operation=sys.argv[4];now=int(sys.argv[5]);cut=sys.argv[6]
journal=directory/'journal.json'
config={'epoch':'crash-lab-owner','slots':1,'records':4,'retries':2,
        'backoffs':[10,30],'create_timeout':1000,'max_lease':6000}
saved=json.loads(journal.read_text()) if journal.exists() else {'snapshot':None,'outbox':[]}
state=saved['snapshot'];outbox=saved['outbox']


def durable(path,data):
    new=path.with_suffix('.new')
    with new.open('w') as f:
        json.dump(data,f);f.flush();os.fsync(f.fileno())
    os.replace(new,path)
    fd=os.open(directory,os.O_DIRECTORY)
    try:os.fsync(fd)
    finally:os.close(fd)


def persist():
    durable(journal,{'snapshot':state,'outbox':outbox})


def checkpoint(phase):
    if cut==phase:
        durable(directory/'barrier.json',{'pid':os.getpid(),'phase':phase})
        while True:signal.pause() # Parent injects SIGKILL, no graceful shutdown.


def rpc(op,**values):
    global state
    request={'config':config,'op':op,'now':now,**values}
    if state is not None:request['snapshot']=state
    result=subprocess.run([lua,str(root/'tests/kernel/once.lua'),str(root/'lua/offload_ledger.lua'),*([module] if module else [])],input=json.dumps(request),text=True,capture_output=True,timeout=3,pass_fds=(lock_fd,))
    if result.returncode:raise RuntimeError(result.stderr)
    reply=json.loads(result.stdout);state=reply['snapshot']
    return reply['actions'] or []


def tc(*args):
    return subprocess.run(['tc',*args],text=True,capture_output=True,check=True,timeout=3,pass_fds=(lock_fd,)).stdout


def rows(dev):
    return [r for r in json.loads(tc('-j','-d','filter','show','dev',dev,'ingress'))
            if r.get('pref')==1001 and 'options' in r]


def device(a):return 'crashwan1' if a['id']=='rt' else 'crashwan0'
def port(a):return 41002 if a['id']=='rt' else 41001


def occupancy(a):
    found=[(dev,r) for dev in ('crashwan0','crashwan1') for r in rows(dev)]
    if not found:return 'absent'
    if len(found)!=1:return 'conflict'
    dev,r=found[0];o=r['options'];actions=o.get('actions',[])
    return 'exact' if (dev==device(a) and r.get('protocol')=='ip' and
        r.get('kind')=='flower' and r.get('chain')==0 and o.get('handle')==a['sequence'] and
        o.get('keys')=={'eth_type':'ipv4','ip_proto':'udp','dst_port':port(a)} and
        len(actions)==1 and actions[0].get('kind')=='gact' and
        actions[0].get('control_action')=={'type':'pass'} and
        o.get('skip_hw') is True) else 'conflict'


def write(a):
    # Trace intended writes durably; recovery must not blindly replay an add/del.
    with (directory/'writes.jsonl').open('a') as f:
        f.write(json.dumps(a)+'\n');f.flush();os.fsync(f.fileno())
    common=['dev',device(a),'ingress','protocol','ip','pref','1001','handle',hex(a['sequence']),'flower']
    if a['op']=='create':
        tc('filter','add',*common,'skip_hw','ip_proto','udp','dst_port',str(port(a)),'action','gact','pass')
    else:tc('filter','del',*common)


def refuse():
    print('Conflicting generation: pending journal and kernel rule retained',file=sys.stderr)
    raise SystemExit(4)


if operation=='step':
    flows=[{'id':'bulk','priority':0,'benefit':1,'valid_until':5000}]
    if now>=2:flows.append({'id':'rt','priority':10,'benefit':1,'valid_until':5000})
    outbox.extend(rpc('step',fresh=True,flows=flows));persist()
elif operation!='reconcile':raise SystemExit('invalid operation')
checkpoint('before_write')
for a in list(outbox):
    found=occupancy(a)
    if found=='conflict':refuse()
    if a['op']=='create':
        if found=='absent':write(a)
        assert occupancy(a)=='exact'
        receipt='created'
    elif a['op']=='revoke':
        if found=='exact':write(a)
        assert occupancy(a)=='absent'
        receipt='absent'
    else:raise AssertionError('unsupported test operation')
    checkpoint('after_write')
    emitted=rpc('receipt',receipt={k:a[k] for k in ('slot','epoch','sequence')}|{'kind':receipt})
    checkpoint('after_receipt')
    outbox.remove(a);outbox.extend(emitted);persist()
print(json.dumps({'snapshot':state,'outbox':outbox}))
