-- Test protocol bridge, not a production controller. No direct I/O to the kernel.
local M=dofile(assert(arg[1]));local json
if arg[2] then json=assert(package.loadlib(arg[2],'luaopen_cjson'))() else json=require('cjson') end
local ledger=M.new({epoch='kernel-lab-owner',slots=2,records=16,retries=2,backoffs={10,30},create_timeout=1000,max_lease=6000})
for line in io.lines() do
 local request=json.decode(line);local actions
 if request.op=='step' then actions=ledger:step(request.now,request.fresh,request.flows)
 elseif request.op=='receipt' then actions=ledger:receipt(request.now,request.receipt)
 elseif request.op=='restart' then ledger=M.restore(ledger:snapshot().config,request.snapshot or ledger:snapshot());actions={}
 else error('invalid test operation') end
 io.write(json.encode({actions=actions,status=ledger:status(),snapshot=ledger:snapshot()}),'\n');io.flush()
end
