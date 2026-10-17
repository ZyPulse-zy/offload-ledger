-- SPDX-License-Identifier: GPL-2.0-only
-- Pure asynchronous admission state machine. No kernel, firmware or network I/O.
local M = {}
local MAXINT = 99999999999999
local function integer(v, low, high)
    return type(v) == 'number' and v == v and v >= low and v <= high and v % 1 == 0
end
local function id_ok(v)
    return type(v) == 'string' and #v > 0 and #v <= 128 and not v:find('[^ -~]')
end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}; for k, v in pairs(value) do result[k] = copy(v) end; return result
end
local Ledger = {}; Ledger.__index = Ledger
local function config(c)
    assert(type(c) == 'table' and id_ok(c.epoch), 'unique controller epoch required')
    local r = {epoch=c.epoch, slots=c.slots or 32, records=c.records or 256,
        retries=c.retries or 2, backoffs=copy(c.backoffs or {1000,3000}),
        create_timeout=c.create_timeout or 6000, max_lease=c.max_lease or 6000}
    assert(integer(r.slots,1,4096) and integer(r.records,r.slots,65536), 'invalid capacity')
    assert(integer(r.retries,0,16) and #r.backoffs == r.retries, 'invalid retries/backoffs')
    for i=1,r.retries do assert(integer(r.backoffs[i],1,3600000), 'invalid backoff') end
    assert(integer(r.create_timeout,1,600000) and integer(r.max_lease,1,600000), 'invalid deadlines')
    return r
end
function M.new(c)
    return setmetatable({config=config(c), at=0, sequence=0, records={}, slots={}, pending={}, count=0}, Ledger)
end
function Ledger:_clock(now)
    assert(integer(now,self.at,MAXINT-7200000), 'non-monotonic or invalid time')
end
function Ledger:_record(id)
    local r=self.records[id]; if r then return r end
    if self.count >= self.config.records then return nil end
    r={failures=0, attempts=0, next_at=0, exhausted=false, closed=false}
    self.records[id]=r; self.count=self.count+1; return r
end
function Ledger:_failed(s, now)
    if s.failure_counted then return end
    s.failure_counted=true
    local r=assert(self.records[s.id]); r.failures=r.failures+1
    r.exhausted=r.failures>self.config.retries
    r.next_at=now+(self.config.backoffs[r.failures] or 0)
end
local function action(op, index, s, why)
    return {op=op,slot=index,id=s.id,epoch=s.epoch,sequence=s.sequence,
        valid_until=s.valid_until,priority=s.priority,reason=why}
end
function Ledger:_retire(index, now, failed, why, actions)
    local s=assert(self.slots[index])
    if failed then self:_failed(s,now) end
    if s.phase == 'retiring' then return end
    s.phase='retiring'; actions[#actions+1]=action('revoke',index,s,why)
end
function Ledger:_claim(index, flow, now, actions)
    assert(not self.slots[index] and self.sequence<MAXINT, 'generation space exhausted')
    local r=assert(self:_record(flow.id)); assert(not r.slot and not r.closed and not r.exhausted)
    self.sequence=self.sequence+1; r.attempts=r.attempts+1; r.slot=index
    local s={id=flow.id,epoch=self.config.epoch,sequence=self.sequence,phase='creating',
        valid_until=flow.valid_until,create_until=now+self.config.create_timeout,
        priority=flow.priority,benefit=flow.benefit,failure_counted=false}
    self.slots[index]=s; self.pending[flow.id]=nil
    actions[#actions+1]=action('create',index,s,'admit')
end
local function eligible(r, now)
    return not r or not r.slot and not r.closed and not r.exhausted and now>=r.next_at
end
function Ledger:step(now, fresh, flows)
    self:_clock(now); assert(self.sequence<=MAXINT-self.config.slots, 'generation space exhausted')
    assert(type(fresh)=='boolean' and type(flows)=='table','invalid observation')
    assert(#flows<=self.config.records, 'observation capacity exceeded')
    local length=#flows; local entries=0
    for k in pairs(flows) do assert(integer(k,1,length),'non-array observation');entries=entries+1 end
    assert(entries==length,'sparse observation')
    local desired, choices={},{}
    for i=1,#flows do
        local f=flows[i]; assert(type(f)=='table' and id_ok(f.id) and not desired[f.id], 'invalid/duplicate lifecycle')
        assert(integer(f.priority,0,255) and integer(f.benefit,0,MAXINT), 'invalid priority/benefit')
        assert(integer(f.valid_until,0,now+self.config.max_lease), 'invalid lease')
        desired[f.id]=f
        if f.valid_until>now then choices[#choices+1]=f end
    end
    -- Validate before changing state. Inputs are copied into bounded internal rows.
    self.at=now; local actions={}
    for index=1,self.config.slots do
        local s=self.slots[index]
        if s and s.phase~='retiring' then
            local f=desired[s.id]
            if s.phase=='creating' and now>=s.create_until then
                self:_retire(index,now,true,'create-deadline',actions)
            elseif now>=s.valid_until or not fresh or not f or f.valid_until<=now or f.priority~=s.priority then
                self:_retire(index,now,s.phase=='creating','lease-or-source-withdrawal',actions)
            elseif s.phase=='active' and f.valid_until>s.valid_until then
                s.valid_until=f.valid_until; s.benefit=f.benefit
                actions[#actions+1]=action('renew',index,s,'fresh-observation')
            end
        end
    end
    local reserved={}
    for id,index in pairs(self.pending) do
        local f=desired[id]
        if not fresh or not f or f.valid_until<=now or not eligible(self.records[id],now) then
            self.pending[id]=nil
            local r=self.records[id]
            if r and r.attempts==0 and not r.slot then self.records[id]=nil;self.count=self.count-1 end
        else reserved[index]=id end
    end
    if not fresh then return actions end
    table.sort(choices,function(a,b)
        if a.priority~=b.priority then return a.priority>b.priority end
        if a.benefit~=b.benefit then return a.benefit>b.benefit end
        return a.id<b.id
    end)
    for _,f in ipairs(choices) do
        local r=self.records[f.id]
        if eligible(r,now) then
            local index=self.pending[f.id]
            if not index then
                for i=1,self.config.slots do if not reserved[i] and not self.slots[i] then index=i;break end end
                if not index then
                    for i=1,self.config.slots do if not reserved[i] and self.slots[i].phase=='retiring' then index=i;break end end
                end
                if not index then
                    for i=1,self.config.slots do
                        local s=self.slots[i]
                        if not reserved[i] and s.phase=='active' and s.priority<f.priority then
                            local old=index and self.slots[index]
                            if not old or s.priority<old.priority or s.priority==old.priority and s.benefit<old.benefit then index=i end
                        end
                    end
                end
                if index and self:_record(f.id) then
                    self.pending[f.id]=index; reserved[index]=f.id
                    if self.slots[index] then self:_retire(index,now,false,'higher-priority-reservation',actions) end
                else index=nil end
            end
            if index and not self.slots[index] then self:_claim(index,f,now,actions) end
        end
    end
    return actions
end
function Ledger:receipt(now, receipt)
    self:_clock(now)
    assert(type(receipt)=='table' and integer(receipt.slot,1,self.config.slots) and id_ok(receipt.epoch)
        and integer(receipt.sequence,1,MAXINT), 'invalid receipt identity')
    assert(receipt.kind=='created' or receipt.kind=='failed' or receipt.kind=='absent', 'invalid receipt kind')
    self.at=now; local s=self.slots[receipt.slot]; local actions={}
    if not s or s.epoch~=receipt.epoch or s.sequence~=receipt.sequence then return actions,false end
    if receipt.kind=='absent' then
        if s.phase~='retiring' then self:_failed(s,now) end
        local r=assert(self.records[s.id]); r.slot=nil; self.slots[receipt.slot]=nil
        if r.closed then self.records[s.id]=nil; self.count=self.count-1 end
    elseif s.phase=='creating' then
        if now>=s.create_until or now>=s.valid_until or receipt.kind=='failed' then
            self:_retire(receipt.slot,now,true,(now>=s.create_until or now>=s.valid_until) and 'late-create-receipt' or 'create-failed',actions)
        else s.phase='active' end
    end
    return actions,true
end
function Ledger:end_lifecycle(now, id)
    self:_clock(now); assert(id_ok(id),'invalid lifecycle')
    self.at=now; local r=self.records[id]; local actions={}; self.pending[id]=nil
    if r then
        r.closed=true
        if r.slot then self:_retire(r.slot,now,false,'confirmed-lifecycle-end',actions)
        else self.records[id]=nil; self.count=self.count-1 end
    end
    return actions
end
function Ledger:status()
    local result={records=self.count,capacity=self.config.records,slots=self.config.slots,
        creating=0,active=0,retiring=0,reservations=0,exhausted=0}
    for _,s in pairs(self.slots) do result[s.phase]=result[s.phase]+1 end
    for _ in pairs(self.pending) do result.reservations=result.reservations+1 end
    for _,r in pairs(self.records) do if r.exhausted then result.exhausted=result.exhausted+1 end end
    return result
end
function Ledger:snapshot()
    -- Canonical string slot keys survive JSON object encoding, including holes.
    local slots={}; for index,s in pairs(self.slots) do slots[tostring(index)]=s end
    return copy({version=1,config=self.config,at=self.at,sequence=self.sequence,
        records=self.records,slots=slots,pending=self.pending})
end
-- Restore only validated plain state from this module's snapshot schema.
function M.restore(c, state)
    local result=M.new(c); local cfg=result.config
    assert(type(state)=='table' and state.version==1 and type(state.config)=='table','invalid snapshot')
    for k,v in pairs(cfg) do
        if k=='backoffs' then
            assert(type(state.config[k])=='table' and #state.config[k]==#v,'changed config')
            for i=1,#v do assert(state.config[k][i]==v[i],'changed config') end
        else assert(state.config[k]==v,'changed config') end
    end
    assert(integer(state.at,0,MAXINT-7200000) and integer(state.sequence,0,MAXINT),'invalid snapshot clock')
    assert(type(state.records)=='table' and type(state.slots)=='table' and type(state.pending)=='table','missing state')
    local count=0
    for id,r in pairs(state.records) do
        count=count+1; assert(count<=cfg.records and id_ok(id) and type(r)=='table','invalid records')
        assert(integer(r.failures,0,cfg.retries+1) and integer(r.attempts,0,state.sequence)
            and integer(r.next_at,0,state.at+3600000) and type(r.exhausted)=='boolean' and type(r.closed)=='boolean','invalid record')
        assert(r.exhausted==(r.failures>cfg.retries) and r.failures<=r.attempts
            and (not r.closed or r.slot) and (r.slot==nil or integer(r.slot,1,cfg.slots)),'inconsistent record')
        result.records[id]={failures=r.failures,attempts=r.attempts,next_at=r.next_at,
            exhausted=r.exhausted,closed=r.closed,slot=r.slot}
    end
    local sequences={}
    for key,s in pairs(state.slots) do
        local index=tonumber(key)
        assert(type(key)=='string' and tostring(index)==key and integer(index,1,cfg.slots) and type(s)=='table' and id_ok(s.id) and s.epoch==cfg.epoch
            and integer(s.sequence,1,state.sequence) and not sequences[s.sequence],'invalid slot token')
        sequences[s.sequence]=true
        local r=result.records[s.id]; assert(r and r.slot==index,'slot ownership mismatch')
        assert(s.phase=='creating' or s.phase=='active' or s.phase=='retiring','invalid phase')
        assert(integer(s.valid_until,0,state.at+cfg.max_lease) and integer(s.create_until,0,state.at+cfg.create_timeout)
            and integer(s.priority,0,255) and integer(s.benefit,0,MAXINT) and type(s.failure_counted)=='boolean','invalid slot')
        assert((not s.failure_counted or s.phase=='retiring' and r.failures>0)
            and (not r.closed and not r.exhausted or s.phase=='retiring'), 'inconsistent live phase')
        result.slots[index]={id=s.id,epoch=s.epoch,sequence=s.sequence,phase=s.phase,valid_until=s.valid_until,
            create_until=s.create_until,priority=s.priority,benefit=s.benefit,failure_counted=s.failure_counted}
    end
    for id,r in pairs(result.records) do assert(not r.slot or result.slots[r.slot] and result.slots[r.slot].id==id,'dangling ownership') end
    local reserved={}
    for id,index in pairs(state.pending) do
        local r=result.records[id]
        assert(r and not r.slot and not r.closed and not r.exhausted and integer(index,1,cfg.slots)
            and not reserved[index],'invalid reservation')
        result.pending[id]=index; reserved[index]=true
    end
    result.at=state.at; result.sequence=state.sequence; result.count=count; return result
end
return M
