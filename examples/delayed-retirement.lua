-- Synthetic backend only. No hardware or network operations.
local M=dofile(arg[1] or 'lua/offload_ledger.lua')
local l=M.new({epoch='example-owner-instance',slots=1,records=8})
local function f(id,priority,now) return {id=id,priority=priority,benefit=1,valid_until=now+5000} end
local function show(actions)
 for _,a in ipairs(actions) do print(a.op,a.id,'slot='..a.slot,'generation='..a.sequence)end
end
local a=l:step(0,true,{f('bulk-ct-birth',0,0)});show(a)
local bulk=a[1]
l:receipt(1,{slot=bulk.slot,epoch=bulk.epoch,sequence=bulk.sequence,kind='created'})
a=l:step(2,true,{f('bulk-ct-birth',0,2),f('interactive-ct-birth',10,2)});show(a)
-- CREATE ACK and a successful revoke command are not absence proof.
for t=3,5 do
 local pending=l:step(t,true,{f('bulk-ct-birth',0,2),f('interactive-ct-birth',10,2)})
 assert(#pending==0 and l:status().reservations==1)
end
print('delayed absence: one reservation, no repeated eviction or premature CREATE')
l=M.restore(l:snapshot().config,l:snapshot())
l:receipt(6,{slot=bulk.slot,epoch=bulk.epoch,sequence=bulk.sequence,kind='absent'})
show(l:step(7,true,{f('bulk-ct-birth',0,7),f('interactive-ct-birth',10,7)}))
