#!/usr/bin/env python3
"""SIGKILL the complete test adapter at durable-state/kernel-write boundaries."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

if os.geteuid() != 0 or os.readlink('/proc/self/ns/net') == os.environ.get('OFFLOAD_LAB_PARENT_NETNS', os.readlink('/proc/self/ns/net')):
    raise SystemExit('Refusing kernel writes outside a distinct network namespace')
root=Path(__file__).resolve().parents[2]
helper=str(Path(sys.argv[1]).resolve());lua=sys.argv[2]
module=sys.argv[3] if len(sys.argv)>3 else ''
checks=0;kills=0


def check(value,why=''):
    global checks
    assert value,why
    checks+=1


with tempfile.TemporaryDirectory(prefix='ledger-crash-') as name:
    directory=Path(name);lock=directory/'writer.lock'

    def fenced(*args):
        return [helper,'run','5000',str(lock),'--',shutil.which(args[0]),*args[1:]]

    def control(*args):
        return subprocess.run(fenced(*args),capture_output=True,text=True,check=True,timeout=8).stdout

    def worker(case,op,now,cut='',expected=0):
        global kills
        barrier=case/'barrier.json'
        barrier.unlink(missing_ok=True)
        args=fenced(sys.executable,str(root/'tests/kernel/crash_worker.py'),str(case),lua,module,op,str(now),cut)
        process=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            if cut:
                deadline=time.monotonic()+4
                while not barrier.exists() and time.monotonic()<deadline and process.poll() is None:
                    time.sleep(.005)
                if not barrier.exists():
                    stdout,stderr=process.communicate(timeout=8)
                    raise AssertionError(('crash barrier not reached',process.returncode,stdout,stderr))
                check(True,'crash barrier reached')
                marker=json.loads(barrier.read_text());check(marker['phase']==cut)
                fd=os.pidfd_open(marker['pid'])
                try:signal.pidfd_send_signal(fd,signal.SIGKILL)
                finally:os.close(fd)
                kills+=1
                expected=128+signal.SIGKILL
            stdout,stderr=process.communicate(timeout=8)
            check(process.returncode==expected,(process.returncode,stdout,stderr))
            control('true') # Previous command and descendants have released the same lock.
            return json.loads(stdout) if expected==0 else stderr
        finally:
            if process.poll() is None:
                # Kill the worker via the fence deadline; never abandon the fence.
                process.communicate(timeout=8)
            process.stdout.close();process.stderr.close()

    def journal(case):return json.loads((case/'journal.json').read_text())
    def writes(case):
        p=case/'writes.jsonl'
        return [json.loads(s) for s in p.read_text().splitlines()] if p.exists() else []
    def filters(dev):
        return [r for r in json.loads(control('tc','-j','-d','filter','show','dev',dev,'ingress')) if r.get('pref')==1001 and 'options' in r]
    def clear():
        for dev in ('crashwan0','crashwan1'):
            control('tc','qdisc','del','dev',dev,'clsact')
            control('tc','qdisc','add','dev',dev,'clsact')

    for dev in ('crashwan0','crashwan1'):
        control('ip','link','add',dev,'type','dummy')
        control('tc','qdisc','add','dev',dev,'clsact')
    try:
        # Same persisted intent, three distinct lost-progress windows.
        for cut in ('before_write','after_write','after_receipt'):
            clear();case=directory/cut;case.mkdir()
            worker(case,'step',0,cut=cut)
            saved=journal(case);a=saved['outbox'][0]
            check(len(saved['outbox'])==1 and saved['snapshot']['slots']['1']['phase']=='creating')
            check(bool(filters('crashwan0'))==(cut!='before_write'))
            check(len(writes(case))==(0 if cut=='before_write' else 1))
            result=worker(case,'reconcile',1)
            check(not result['outbox'] and result['snapshot']['slots']['1']['phase']=='active')
            check(result['snapshot']['slots']['1']['sequence']==a['sequence'])
            check(len(writes(case))==1,'recovery blindly repeated CREATE')
            row=filters('crashwan0')[0]
            check(row['options']['handle']==a['sequence'])

        # Real deletion completed, but no absence receipt or checkpoint survived.
        case=directory/'after_receipt'
        worker(case,'step',2,cut='after_write')
        pending=journal(case)['outbox'][0]
        check(pending['op']=='revoke' and not filters('crashwan0'))
        result=worker(case,'reconcile',3)
        check(not result['outbox'] and not result['snapshot']['slots'])
        check(len(writes(case))==2,'recovery blindly repeated DELETE')
        result=worker(case,'step',4)
        check(result['snapshot']['slots']['1']['id']=='rt')
        check(result['snapshot']['slots']['1']['sequence']>pending['sequence'])
        check(len(filters('crashwan1'))==1 and len(writes(case))==3)

        # A rule with an unexpected generation, including another device, is not
        # proof of absence. Retain both the journal and the foreign kernel rule.
        for dev in ('crashwan0','crashwan1'):
            clear();case=directory/('conflict-'+dev);case.mkdir()
            worker(case,'step',0,cut='before_write')
            old=(case/'journal.json').read_bytes()
            control('tc','filter','add','dev',dev,'ingress','protocol','ip','pref','1001','handle','0x777','flower','skip_hw','ip_proto','udp','dst_port','41999','action','gact','pass')
            foreign=filters(dev)
            check('Conflicting generation' in worker(case,'reconcile',1,expected=4))
            check((case/'journal.json').read_bytes()==old,'conflict discarded pending state')
            check(filters(dev)==foreign and not writes(case),'conflict was changed or admitted')
        clear();case=directory/'conflict-action';case.mkdir()
        worker(case,'step',0,cut='before_write')
        old=(case/'journal.json').read_bytes()
        a=journal(case)['outbox'][0]
        control('tc','filter','add','dev','crashwan0','ingress','protocol','ip','pref','1001','handle',hex(a['sequence']),'flower','skip_hw','ip_proto','udp','dst_port','41001','action','gact','drop')
        foreign=filters('crashwan0')
        check('Conflicting generation' in worker(case,'reconcile',1,expected=4))
        check((case/'journal.json').read_bytes()==old and filters('crashwan0')==foreign)
        check(not writes(case),'matching token hid a different rule action')
        print(json.dumps({'passed':True,'checks':checks,'sigkillCuts':kills,
                          'recoveryReadbackUnderFence':True,'blindReplay':False,
                          'foreignGenerationRetained':True,'hardwareOffload':False}))
    finally:
        for dev in ('crashwan0','crashwan1'):
            control('ip','link','del',dev)
