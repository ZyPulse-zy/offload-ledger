local M=dofile(assert(arg[1]))
local json
if arg[2] then json=assert(package.loadlib(arg[2],'luaopen_cjson'))()
else json=require('cjson') end
local c={epoch='boot-owner',slots=2,records=8,retries=2,backoffs={10,30},max_lease=100}
local l=M.new(c)
local a=l:step(0,true,{{id='a',priority=0,benefit=1,valid_until=90},{id='b',priority=0,benefit=1,valid_until=90}})
for _,v in ipairs(a)do l:receipt(1,{slot=v.slot,epoch=v.epoch,sequence=v.sequence,kind='created'})end
local old=l:end_lifecycle(2,'a')[1]
l:receipt(3,{slot=old.slot,epoch=old.epoch,sequence=old.sequence,kind='absent'})
local snapshot=l:snapshot()
assert(snapshot.slots['1']==nil and snapshot.slots['2'])
local encoded=json.encode(snapshot);local roundtrip=M.restore(c,json.decode(encoded))
assert(roundtrip:status().active==1)
assert(roundtrip:snapshot().slots['2'].id=='b')
snapshot=roundtrip:snapshot();snapshot.sequence=99999999999998
snapshot.slots['2'].sequence=99999999999997
local parsed=json.decode(json.encode(snapshot))
assert(parsed.sequence==99999999999998 and parsed.slots['2'].sequence==99999999999997)
assert(M.restore(c,parsed):status().active==1)
print('JSON sparse-slot and exact counter roundtrips passed')
