local module=assert(arg[1]); local M
if module=='--installed' then M=require('offload_ledger') else M=dofile(module) end
local checks=0
local function check(v, why) assert(v,why);checks=checks+1 end
local function cfg(slots,records)
 return {epoch='boot-and-owner-instance',slots=slots or 2,records=records or 8,
  retries=2,backoffs={10,30},create_timeout=20,max_lease=100}
end
local function flow(id,at,p,b) return {id=id,priority=p or 0,benefit=b or 1,valid_until=at+90} end
local function reply(l,a,at,kind,delta)
 return l:receipt(at,{slot=a.slot,epoch=a.epoch,sequence=a.sequence+(delta or 0),kind=kind})
end
local function invariant(l)
 local s=l:snapshot(); local seen,reserved={},{}; local count=0
 for id,r in pairs(s.records) do
  count=count+1;check(r.failures<=3)
  check(r.exhausted==(r.failures>2))
  if r.slot then check(s.slots[tostring(r.slot)] and s.slots[tostring(r.slot)].id==id) end
 end
 check(count<=s.config.records)
 for key,slot in pairs(s.slots) do
  local index=tonumber(key)
  check(index>=1 and index<=s.config.slots and not seen[slot.id]);seen[slot.id]=true
  check(s.records[slot.id].slot==index)
 end
 for id,index in pairs(s.pending) do
  check(not reserved[index] and not s.records[id].slot);reserved[index]=id
 end
 -- Restoration must preserve every live token and all lifetime retry counters.
 local restored=M.restore(s.config,s):snapshot()
 for id,r in pairs(s.records) do
  check(restored.records[id].failures==r.failures and restored.records[id].attempts==r.attempts)
 end
end
-- Normal asynchronous lifecycle: no reuse after failed CREATE until absence.
local c=cfg(1);local l=M.new(c);local a=l:step(0,true,{flow('a',0)})
check(#a==1 and a[1].op=='create');local first=a[1]
check(#l:step(1,true,{flow('a',1)})==0)
a=reply(l,first,2,'failed');check(#a==1 and a[1].op=='revoke')
check(#l:step(15,true,{flow('a',15)})==0,'reused before exact absence')
local _,accepted=reply(l,first,15,'absent',1);check(not accepted)
reply(l,first,16,'absent');a=l:step(16,true,{flow('a',16)})
check(#a==1 and a[1].sequence>first.sequence)
_,accepted=reply(l,first,17,'absent');check(not accepted,'old generation removed new slot')
invariant(l)
-- Repeated failures across empty/stale observations must exhaust once per epoch.
l=M.new(c);local at=0
for attempt=1,3 do
 a=l:step(at,true,{flow('same-ct',at)});check(#a==1 and a[1].op=='create')
 first=a[1];a=reply(l,first,at+1,'failed');check(#a==1)
 reply(l,first,at+2,'absent')
 check(#l:step(at+3,false,{})==0)
 l=M.restore(c,l:snapshot())
 at=at+40
end
for i=1,50 do
 check(#l:step(at,true,{flow('same-ct',at)})==0,'source gap reset spent retry budget');at=at+1
end
check(l:snapshot().records['same-ct'].failures==3)
l:end_lifecycle(at,'same-ct');check(not l:snapshot().records['same-ct'])
a=l:step(at,true,{flow('new-ct-birth',at)});check(#a==1)
-- A delayed removal may evict only one lower-priority victim per demand.
l=M.new(cfg());a=l:step(0,true,{flow('bulk1',0,0,2),flow('bulk2',0,0,1)})
for _,v in ipairs(a) do reply(l,v,1,'created') end
local rows={flow('rt',2,10),flow('bulk1',2,0,2),flow('bulk2',2,0,1)}
a=l:step(2,true,rows);check(#a==3 and a[3].op=='revoke');local victim=a[3]
check(victim.id=='bulk2')
for t=3,19 do check(#l:step(t,true,rows)==0,'repeated preemption while ACK delayed') end
invariant(l)
reply(l,victim,19,'absent');a=l:step(19,true,rows)
check(#a==1 and a[1].op=='create' and a[1].id=='rt','promised RT slot lost')
-- Equal-priority work never displaces an active owner.
l=M.new(c);a=l:step(0,true,{flow('a',0,5)});reply(l,a[1],1,'created')
check(#l:step(2,true,{flow('a',0,5),flow('b',2,5,100)})==0)
-- Source loss withdraws once, without issuing CREATE or renew; unknown CREATE
-- consumes lifetime recovery budget even when its later ACK is missing.
l=M.new(c);a=l:step(0,true,{flow('a',0)});first=a[1]
a=l:step(1,false,{});check(#a==1 and a[1].op=='revoke')
check(#l:step(2,false,{})==0);reply(l,first,3,'created')
check(l:snapshot().slots['1'].phase=='retiring');reply(l,first,4,'absent')
check(l:snapshot().records.a.failures==1)
-- Late CREATE cannot turn an expired lease or creation deadline into active.
for _,lease in ipairs({5,90}) do
 l=M.new(c);local f=flow('a',0);f.valid_until=lease;a=l:step(0,true,{f});first=a[1]
 a=reply(l,first,21,'created');check(#a==1 and a[1].op=='revoke')
 check(l:snapshot().slots['1'].phase=='retiring');invariant(l)
end
-- Full lifetime history is conservative, rather than evicting spent budgets.
l=M.new(cfg(1,1));a=l:step(0,true,{flow('old',0)});first=a[1]
reply(l,first,1,'created');a=l:step(2,true,{})
reply(l,a[1],3,'absent')
check(#l:step(4,true,{flow('new',4)})==0)
l:end_lifecycle(5,'old');check(#l:step(6,true,{flow('new',6)})==1)
-- Confirmed lifecycle end waits for exact hardware retirement before deletion.
l=M.new(c);a=l:step(0,true,{flow('a',0)});first=a[1]
a=l:end_lifecycle(1,'a');check(#a==1 and l:snapshot().records.a.closed)
check(#l:step(2,true,{flow('a',2)})==0)
reply(l,first,3,'absent');check(not l:snapshot().records.a)
-- Invalid observations, time regressions, and corrupt checkpoints are rejected.
l=M.new(c);l:step(10,true,{})
check(not pcall(l.step,l,9,true,{}))
check(not pcall(l.step,l,11,true,{flow('a',11),flow('a',11)}))
check(not pcall(l.step,l,11,true,{{id='a',priority=0,benefit=0,valid_until=math.huge}}))
check(l:snapshot().sequence==0)
a=l:step(11,true,{flow('a',11)});local state=l:snapshot();state.records.a.slot=2
check(not pcall(M.restore,c,state))
state=l:snapshot();state.records.a.exhausted=true;check(not pcall(M.restore,c,state))
-- Snapshots and caller inputs cannot modify internal state through aliases.
state=l:snapshot();state.slots['1'].phase='active';check(l:snapshot().slots['1'].phase=='creating')
-- Capacity is configurable and priority reservations do not assume 32 slots.
for _,capacity in ipairs({1,2,32,64,128}) do
 local wide=cfg(capacity,capacity+4);local w=M.new(wide);local candidates={}
 for i=1,capacity do candidates[i]=flow('bulk-'..i,0,0,i) end
 local created=w:step(0,true,candidates);check(#created==capacity)
 for _,op in ipairs(created) do reply(w,op,1,'created') end
 candidates[#candidates+1]=flow('rt',2,10)
 local actions=w:step(2,true,candidates);local retiring
 for _,op in ipairs(actions) do if op.op=='revoke' then check(not retiring);retiring=op end end
 check(retiring and retiring.id=='bulk-1')
 for t=3,8 do check(#w:step(t,true,candidates)==0) end
 invariant(w);reply(w,retiring,9,'absent')
 local admitted=w:step(9,true,candidates);check(#admitted==1 and admitted[1].id=='rt')
end
-- Deterministic fault traces with lost, duplicate, stale and reordered receipts.
-- Park ownership after mutation; generated actions are validated against a tiny
-- asynchronous backend which refuses to replace any still-present generation.
local seed=1234567
local function rand(n) seed=(seed*16807)%2147483647;return seed%n+1 end
for trial=1,12 do
 c=cfg(4,32);l=M.new(c);local backend,queue={},{}
 local function apply(actions)
  for _,op in ipairs(actions) do
   if op.op=='create' then
    check(not backend[op.slot], 'CREATE before prior generation absence')
    backend[op.slot]={epoch=op.epoch,sequence=op.sequence,id=op.id}
    queue[#queue+1]={due=at+rand(8),slot=op.slot,epoch=op.epoch,sequence=op.sequence,kind=rand(3)==1 and 'failed' or 'created'}
   elseif op.op=='revoke' then
    local old=backend[op.slot];check(not old or old.sequence==op.sequence)
    queue[#queue+1]={due=at+rand(8),slot=op.slot,epoch=op.epoch,sequence=op.sequence,kind='absent'}
   elseif op.op=='renew' then
    local old=backend[op.slot];check(old and old.sequence==op.sequence)
   else error('unexpected action') end
  end
 end
 for t=0,180 do
  at=t
  for i=#queue,1,-1 do
   local receipt=queue[i]
   if receipt.due<=t then
    table.remove(queue,i)
    if receipt.kind=='absent' then
     local old=backend[receipt.slot]
     if old and old.sequence==receipt.sequence then backend[receipt.slot]=nil end
    end
    apply(l:receipt(t,receipt))
    if rand(4)==1 then apply(l:receipt(t,receipt)) end
   end
  end
  rows={}
  for i=1,12 do if rand(4)>1 then rows[#rows+1]=flow('flow-'..i,t,i%3,rand(100)) end end
  apply(l:step(t,rand(6)>1,rows));invariant(l)
  if t%11==0 then l=M.restore(c,l:snapshot()) end
 end
end
print(checks..' checks passed (deterministic traces + 2172 fault-injection steps)')
