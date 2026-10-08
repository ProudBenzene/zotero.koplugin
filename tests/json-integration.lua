-- Optional real JSON smoke check. HTTP, crypto and PDF geometry remain doubles.
-- Usage: pandoc lua tests/json-integration.lua
assert(pandoc and pandoc.json, "Run this check with Pandoc's embedded Lua")
package.path = "./?.lua;./tests/?.lua;" .. package.path
local support = require("tests/support")
local API = support.setup()
local checks = 0
local function check(value, label)
    assert(value, label)
    checks = checks + 1
end
local ok, err = xpcall(function()
    -- Both modules use this table; replace the token codec with a real parser.
    support.JSON.encode, support.JSON.decode = pandoc.json.encode, pandoc.json.decode
    local Annotations = require("annotations")
    local parent = support.attachment("ATTACH01", "paper.pdf", false)
    parent.data.md5 = string.rep("0", 32)
    support.seed({ATTACH01=parent})
    local directory, path = API.getDirAndPath("ATTACH01")
    assert(support.makePath(directory))
    support.write(path, "immutable stand-in")
    support.write(directory.."/.zotero-cache.json", support.JSON.encode({md5=parent.data.md5,version=10}))
    local item = {key="ANNOT001",version=10,data={itemType="annotation",parentItem="ATTACH01",
        annotationType="highlight",annotationText='中文 "quote"\nsecond line',annotationComment="",
        annotationColor="#ffd400",dateAdded="2026-10-08T04:00:00Z",
        annotationPosition='{"pageIndex":0,"rects":[[10.5,100,110.5,120]]}'}}
    local children = support.JSON.encode({item})
    support.response = function(req)
        check(req.method=="GET", "Read-only JSON requests")
        if req.url:find("/keys/current", 1, true) then return support.key(req) end
        if req.url:find("/children?", 1, true) then return support.respond(req,children,10) end
        return support.respond(req,parent)
    end
    assert(Annotations.ensureCached(API,"ATTACH01"))
    local raw = pandoc.json.decode(support.read(directory.."/.zotero-annotations.json"))
    check(raw.items[1].data.annotationText==item.data.annotationText, "Unicode, quotes and newline round trip")
    local cache = assert(Annotations.readCache(API,"ATTACH01"))
    local converted = assert(Annotations.convert(cache,{info={number_of_pages=1},
        getNativePageDimensions=function() return {w=600,h=800} end}))
    check(converted[1].pboxes[1].x==10.5 and converted[1].pboxes[1].y==680 and converted[1].note==nil,
        "Decode nested position JSON and empty comment")
    children = "[]"
    assert(Annotations.ensureCached(API,"ATTACH01",nil,true))
    check(#assert(Annotations.readCache(API,"ATTACH01")).items==0, "Real empty array snapshot")
    local saved = support.read(directory.."/.zotero-annotations.json")
    children = "{}"
    local result,fetch_err = Annotations.ensureCached(API,"ATTACH01",nil,true)
    check(not result and fetch_err and support.read(directory.."/.zotero-annotations.json")==saved,
        "Object response does not clear the cache")
    check(support.read(path)=="immutable stand-in", "PDF stand-in is unchanged")
end,debug.traceback)
support.teardown()
if not ok then error(err) end
io.write(string.format("%d real JSON integration checks passed\n",checks))
