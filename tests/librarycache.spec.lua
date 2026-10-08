local support=require("tests/support")
local Cache=require("librarycache")
describe("Streaming library cache regressions",function()
    before_each(support.setup)
    after_each(support.teardown)

    it("reads nested records and escaped quotes across a buffer boundary",function()
        local header='{"format":1,"items":{"NOTE0001":'
        local prefix='{"key":"NOTE0001","data":{"itemType":"note","note":"'
        -- A JSON escape starts at the last byte of the first 64 KiB buffer.
        local record=prefix..string.rep("x",65535-#header-#prefix)..[[\" [nested] {braces} \\ tail]]..'"}}'
        local collection='{"key":"ROOT0001","data":{"name":"Root","parentCollection":false}}'
        local content=header..record..'},"collections":{"ROOT0001":'..collection..'},"version":22}'
        local JSON={decode=function(raw)
            if raw==record then return {key="NOTE0001",data={itemType="note",note="discarded"}} end
            if raw==collection then return {key="ROOT0001",data={name="Root",parentCollection=false}} end
            local key=raw:match('^"([^"\\]*)"$')
            return key or assert(tonumber(raw),"Incorrect captured value boundary")
        end}
        local path=support.directory.."/large.json"
        support.write(path,content)
        local state,err=Cache.read(path,JSON,function(item) item.data.note=nil;return item end,function(item) return item end)
        assert(not err and state.format==1 and state.version==22)
        assert(state.items.NOTE0001.data.note==nil and state.collections.ROOT0001.data.parentCollection==false)
    end)

    it("rejects truncated JSON and trailing input rather than accepting a partial snapshot",function()
        local JSON={decode=function(raw) return raw:match('^"(.-)"$') or tonumber(raw) end}
        local path=support.directory.."/invalid.json"
        for _,content in ipairs({'{"items":{},"collections":{','{"items":{},"collections":{}} trailing'}) do
            support.write(path,content)
            local state,err=Cache.read(path,JSON,function(item) return item end,function(item) return item end)
            assert(not state and err:find("cache JSON",1,true))
        end
    end)

    it("rejects non-record values inside item and collection maps",function()
        local JSON={decode=function(raw)
            if raw=="false" then return false end
            return raw:match('^"(.-)"$')
        end}
        local path=support.directory.."/invalid.json"
        support.write(path,'{"items":{"NOTE0001":false},"collections":{}}')
        local state,err=Cache.read(path,JSON,function(item) return item end,function(item) return item end)
        assert(not state and err:find("Invalid cache record",1,true))
    end)
end)
