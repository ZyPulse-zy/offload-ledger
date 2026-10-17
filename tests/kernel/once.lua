-- Test-only one-shot policy bridge; the Python worker owns I/O and persistence.
local json
if arg[2] then json=assert(package.loadlib(arg[2],'luaopen_cjson'))() else json=require('cjson') end
local M=dofile(assert(arg[1]))
local r=json.decode(io.read('*a'))
local ledger=r.snapshot and M.restore(r.config,r.snapshot) or M.new(r.config)
local actions
if r.op=='step' then actions=ledger:step(r.now,r.fresh,r.flows)
elseif r.op=='receipt' then actions=ledger:receipt(r.now,r.receipt)
else error('invalid operation') end
io.write(json.encode({snapshot=ledger:snapshot(),actions=actions}),'\n')
