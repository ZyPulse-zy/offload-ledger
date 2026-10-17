#!/usr/bin/env python3
"""Real tc backend for integration tests. No traffic generation or NSS claims."""
import json
import os
import select
import shlex
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

if os.geteuid() != 0 or os.readlink('/proc/self/ns/net') == os.environ.get('OFFLOAD_LAB_PARENT_NETNS', os.readlink('/proc/self/ns/net')):
    raise SystemExit('Refusing kernel writes outside a distinct network namespace')
root=Path(__file__).resolve().parents[2]
helper=str(Path(sys.argv[1]).resolve())
snapshot=str(Path(sys.argv[2]).resolve())
lua=sys.argv[3]
json_module=sys.argv[4:5]
checks=0

def check(value, why=''):
    global checks
    assert value, why
    checks+=1

def command(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True, timeout=5).stdout

with tempfile.TemporaryDirectory() as directory:
    tmp=Path(directory)
    lock=tmp/'writer.lock'
    def controlled(*args, expected=0, timeout=1500):
        result=subprocess.run([helper,'run',str(timeout),str(lock),'--',shutil.which(args[0]),*args[1:]],capture_output=True,text=True,timeout=5)
        check(result.returncode==expected,(args,result.returncode,result.stderr))
        return result.stdout

    for dev,rate in [('labwan0','12mbit'),('labwan1','7mbit')]:
        controlled('ip','link','add',dev,'type','dummy')
        controlled('ip','link','set',dev,'up')
        controlled('tc','qdisc','add','dev',dev,'root','cake','bandwidth',rate)
        controlled('tc','qdisc','add','dev',dev,'clsact')
    before=command('tc','-j','qdisc','show')
    rates=json.loads(command(snapshot,'labwan0','labwan1'))['rates']
    check([int(r['bits_per_second']) for r in rates]==[12000000,7000000])
    budgets={r['dev']:int(r['bits_per_second']) for r in rates}
    check(command('tc','-j','qdisc','show')==before,'budget reader changed qdisc state')
    process=None
    outbox=[]
    state=None
    mapping={}
    def start():
        return subprocess.Popen([lua,str(root/'tests/kernel/controller.lua'),str(root/'lua/offload_ledger.lua'),*json_module],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    def persist():
        data=json.dumps({'snapshot':state,'outbox':outbox})
        new=tmp/'journal.new'
        with new.open('w') as stream:
            stream.write(data);stream.flush();os.fsync(stream.fileno())
        os.replace(new,tmp/'journal.json')
        fd=os.open(tmp,os.O_DIRECTORY)
        try:os.fsync(fd)
        finally:os.close(fd)
    def rpc(op,now,**values):
        global state
        if op=='step':values['flows']=qualify(values['flows'])
        request={'op':op,'now':now,**values}
        process.stdin.write(json.dumps(request)+'\n');process.stdin.flush()
        check(bool(select.select([process.stdout],[],[],3)[0]),'controller response deadline')
        line=process.stdout.readline()
        check(bool(line),'controller died: '+str(process.poll()))
        result=json.loads(line);state=result['snapshot']
        actions=result['actions'] or []
        check(isinstance(actions,list))
        outbox.extend(actions)
        persist() # State and unexecuted writes are durable before any kernel write.
        return actions
    def device(id):
        return 'labwan1' if id in ('bulk1','overbudget') else 'labwan0'
    def qualify(flows):
        # Test-only budget policy; use exact rates from the actual CAKE reader.
        demands={'bulk0':1000000,'bulk1':6000000,'rt':2000000,'partial':1000000,'overbudget':8000000}
        used={};qualified=[]
        for f in sorted(flows,key=lambda f:(-f['priority'],f['id'])):
            dev=device(f['id']);cost=demands[f['id']]
            if used.get(dev,0)+cost<=budgets[dev]:
                used[dev]=used.get(dev,0)+cost;qualified.append(f)
        return qualified
    def port(id):
        return {'bulk0':40001,'bulk1':40002,'rt':40003,'partial':40004}[id]
    def filters(dev,pref):
        rows=json.loads(command('tc','-j','-d','filter','show','dev',dev,'ingress'))
        return [r for r in rows if r.get('pref')==pref and 'options' in r]
    def present(a):
        rows=filters(device(a['id']),1000+a['slot'])
        return len(rows)==1 and rows[0]['kind']=='flower' and rows[0]['options']['handle']==a['sequence'] and rows[0]['options']['keys']['dst_port']==port(a['id']) and rows[0]['options'].get('skip_hw') is True
    def create_args(a):
        return ['tc','filter','add','dev',device(a['id']),'ingress','protocol','ip','pref',str(1000+a['slot']),'handle',hex(a['sequence']),'flower','skip_hw','ip_proto','udp','dst_port',str(port(a['id'])),'action','gact','pass']
    def write(a,partial=False):
        token=(a['slot'],a['sequence'])
        if a['op']=='create':
            for dev in ('labwan0','labwan1'):
                check(not filters(dev,1000+a['slot']),'CREATE before old rule absence')
            if partial:
                script=tmp/'partial.sh'
                script.write_text('#!/bin/sh\n'+shlex.join([shutil.which('tc'),*create_args(a)[1:]])+'\nprintf applied > '+shlex.quote(str(tmp/'partial'))+'\nexec sleep 30\n')
                script.chmod(0o700)
                controlled(str(script),expected=124,timeout=200)
                check((tmp/'partial').read_text()=='applied')
            else:controlled(*create_args(a))
            check(present(a),'CREATE readback mismatch')
            mapping[token]=a.copy()
        elif a['op']=='revoke':
            check(token in mapping and present(mapping[token]),'revoke identity mismatch')
            controlled('tc','filter','del','dev',device(a['id']),'ingress','protocol','ip','pref',str(1000+a['slot']),'handle',hex(a['sequence']),'flower')
            check(not filters(device(a['id']),1000+a['slot']),'absence readback failed')
            del mapping[token]
        elif a['op']=='renew':
            check(token in mapping and present(a),'renew generation mismatch')
        else:raise AssertionError('unexpected operation')
        outbox.remove(a);persist()
    def receipt(a,now,kind):
        return rpc('receipt',now,receipt={k:a[k] for k in ('slot','epoch','sequence')}|{'kind':kind})
    def restart(now):
        global process
        process.stdin.close();process.wait(timeout=3)
        check(process.returncode==0)
        process.stdout.close();process.stderr.close()
        saved=json.loads((tmp/'journal.json').read_text())
        check(saved['outbox']==outbox)
        process=start();rpc('restart',now,snapshot=saved['snapshot'])
    def flow(id,priority=0,benefit=1):
        return {'id':id,'priority':priority,'benefit':benefit,'valid_until':5000}
    process=start()
    try:
        controlled('tc','filter','add','dev','labwan0','ingress','protocol','ip','pref','1999','handle','0x99','flower','skip_hw','ip_proto','udp','dst_port','49999','action','gact','pass')
        decoy=filters('labwan0',1999)
        rows=[flow('bulk0',benefit=2),flow('bulk1'),flow('overbudget',100)]
        created=rpc('step',0,fresh=True,flows=rows)
        check(len(created)==2 and 'overbudget' not in state['records'])
        for a in created:
            write(a);check(not receipt(a,1,'created'))
        rows.append(flow('rt',10))
        actions=rpc('step',2,fresh=True,flows=rows)
        check(len(actions)==1 and actions[0]['op']=='revoke' and actions[0]['id']=='bulk1')
        victim=actions[0]
        check(present(victim),'victim already vanished')
        for now in range(3,10):
            check(not rpc('step',now,fresh=True,flows=rows),'repeated preemption before absence')
        restart(10)
        check(present(victim) and len(outbox)==1,'lost durable retirement outbox')
        write(victim);check(not receipt(victim,11,'absent'))
        admitted=rpc('step',12,fresh=True,flows=rows)
        check(len(admitted)==1 and admitted[0]['id']=='rt')
        write(admitted[0]);receipt(admitted[0],13,'created')
        check(not receipt(victim,14,'absent'),'stale receipt emitted actions')
        check(present(admitted[0]) and state['slots'][str(admitted[0]['slot'])]['phase']=='active','stale receipt released current rule')
        for a in rpc('step',20,fresh=False,flows=[]):
            write(a);receipt(a,20,'absent')
        check(not mapping)
        a=rpc('step',30,fresh=True,flows=[flow('partial')])[0]
        write(a,partial=True) # Verified effect survives command timeout.
        check(present(a))
        revoked=rpc('step',1040,fresh=True,flows=[flow('partial')])
        check(len(revoked)==1 and revoked[0]['op']=='revoke')
        write(revoked[0]);receipt(revoked[0],1041,'absent')
        rpc('step',1042,fresh=False,flows=[]);restart(1043)
        check(state['records']['partial']['failures']==1,'gap/restart reset recovery history')
        new=rpc('step',1080,fresh=True,flows=[flow('partial')])[0]
        check(new['sequence']>a['sequence'])
        write(new);receipt(a,1081,'absent')
        check(present(new) and state['records']['partial']['slot']==new['slot'])
        receipt(new,1082,'created')
        for a in rpc('step',1090,fresh=False,flows=[]):
            write(a);receipt(a,1090,'absent')
        check(not mapping and not outbox)
        crash=subprocess.run([sys.executable,str(root/'tests/kernel/test_crash.py'),helper,lua,*json_module],capture_output=True,text=True,check=True,timeout=30)
        print(crash.stdout,end='')
        check(filters('labwan0',1999)==decoy,'unrelated rule changed')
        check(command('tc','-j','qdisc','show')==before,'static CAKE root changed')
        print(json.dumps({'passed':True,'checks':checks,'realKernel':True,'wanDevices':2,'exactBudgetRates':True,'durablePendingRetirement':True,'partialWriteTimeout':True,'generationSafeReceipts':True,'hardwareOffload':False}))
    finally:
        if process.poll() is None:
            process.stdin.close()
            try:process.wait(timeout=3)
            except subprocess.TimeoutExpired:process.kill();process.wait()
        process.stdout.close();process.stderr.close()
