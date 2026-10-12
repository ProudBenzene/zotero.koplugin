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
    local Cleanup=require("downloadcleanup")
    local state=pandoc.json.decode(support.read(API.cache_path))
    state.compact=nil
    state.items.ATTACH01.data.parentItem="PARENT01"
    state.items.ATTACH01.data.title="Full Text PDF"
    state.items.PARENT01={data={itemType="journalArticle",title='中文 "title"\nOriginal title',unused=string.rep("x",1048576)}}
    support.write(API.cache_path,pandoc.json.encode(state))
    local library=support.read(API.cache_path)
    API.state=nil
    local scan=Cleanup.scanDownloads(API)
    check(#scan.targets==1 and scan.pdf==1,"Real JSON receipts identify a downloaded PDF")
    check(scan.targets[1].title==state.items.PARENT01.data.title and scan.targets[1].attachment_title=="Full Text PDF",
        "Streaming cold metadata retains Unicode document and attachment titles for preview")
    check(API.state==nil and support.read(API.cache_path)==library,"Preview scan leaves large legacy metadata unchanged")
    local requests=#support.requests
    local original=os.remove
    os.remove=function(file)
        if file==directory.."/.zotero-annotations.json" then return nil,"denied" end
        return original(file)
    end
    local stats=Cleanup.newStats(scan)
    Cleanup.processTarget(scan.targets[1],stats)
    check(stats.deleted==1 and stats.pending==1,"Cleanup failure preserves a retry record after unlink")
    os.remove=original
    local task=pandoc.json.decode(support.read(directory.."/.zotero-cleanup.json"))
    check(task.source=="zotero.koplugin" and task.tasks["paper.pdf"].identity.size==#"immutable stand-in",
        "Cleanup task round trips with real JSON")
    scan=Cleanup.scanDownloads(API);stats=Cleanup.newStats(scan)
    Cleanup.processTarget(scan.targets[1],stats)
    check(stats.cleaned==1 and stats.failed==0 and stats.pending==0,"Real JSON cleanup task retries successfully")
    check(#support.requests==requests and support.read(API.cache_path)==library,"Cleanup keeps library bytes and performs no HTTP")

    support.seed({OLDITEM1=support.attachment("OLDITEM1","old.pdf")},{},10)
    local old_library=support.read(API.cache_path)
    local deleted='{"items":{"OLDITEM1":true},"collections":[]}'
    support.response=function(req)
        if req.url:find("/keys/current",1,true) then return support.key(req) end
        if req.url:find("/deleted?",1,true) then return support.respond(req,deleted,11) end
        check(req.url:find("since=10",1,true),"Rejected deletion response keeps the retry cursor")
        return support.respond(req,"[]",11)
    end
    for _,body in ipairs({deleted,'{"items":[null],"collections":[]}',
        '{"items":[],"collections":{"GONE0001":true}}','{"items":[123],"collections":[]}'}) do
        deleted=body
        local sync_err=API.syncAllItems()
        check(sync_err and API.getLibraryVersion()==10 and API.getItems().OLDITEM1
            and support.read(API.cache_path)==old_library,"Malformed real JSON deletion log cannot publish a new version")
    end
    deleted='{"items":["OLDITEM1"],"collections":[]}'
    check(API.syncAllItems()==nil and API.getLibraryVersion()==11 and not API.getItems().OLDITEM1,
        "Corrected deletion arrays retry and remove the old item")

    parent.version=11;parent.data.md5=string.rep("b",32)
    support.seed({ATTACH01=parent},{},11)
    directory,path=API.getDirAndPath("ATTACH01")
    assert(support.makePath(directory))
    support.write(path,"old PDF bytes")
    local receipt_path=directory.."/.zotero-cache.json"
    support.write(receipt_path,pandoc.json.encode({version=10,md5=string.rep("0",32)}))
    support.write(directory.."/.zotero-annotations.json",pandoc.json.encode({format=1,user_id="123",
        attachment_key="ATTACH01",library_version=10,file_identity={md5=string.rep("0",32)},items={item}}))
    support.digests["new PDF bytes"]=parent.data.md5
    support.response=function(req) return support.respond(req,"new PDF bytes",nil,{etag='"'..parent.data.md5..'"'}) end
    local rename=os.rename
    local receipt_writes=0
    os.rename=function(from,to)
        if to==receipt_path then
            receipt_writes=receipt_writes+1
            if receipt_writes==2 then return nil,"receipt publication failure" end
        end
        return rename(from,to)
    end
    local result,download_err=API.downloadAndGetPath("ATTACH01")
    os.rename=rename
    check(not result and download_err and support.read(path)=="new PDF bytes"
        and pandoc.json.decode(support.read(receipt_path)).download_pending==true,
        "Failed final receipt publication leaves a real JSON pending identity")
    API.init(API.zotero_dir)
    check(API.getAttachmentStatus("ATTACH01")=="outdated","Reload rejects an incomplete download as a reusable cache")
    local config={data={annotations={}},readSetting=function(self,key) return self.data[key] end,
        saveSetting=function(self,key,value) self.data[key]=value end}
    local ui={document={is_pdf=true,file=path,info={number_of_pages=1},configurable={text_wrap=0},
        getNativePageDimensions=function() return {w=600,h=800} end,
        getPageBoxesFromPositions=function() return {} end,comparePositions=function() return 1 end},
        annotation={annotations={}},registerPostReaderReadyCallback=function() end}
    local apply_err
    result,apply_err=Annotations.applyToReader(API,ui,config,"ATTACH01")
    check(not result and apply_err and #ui.annotation.annotations==0 and config.data.zotero_annotations_applied==nil,
        "Offline reader refuses the old annotation snapshot after interrupted publication")
    local pending_scan=Cleanup.scanDownloads(API)
    check(#pending_scan.targets==1 and #pending_scan.unknown==0,"Pending receipt still identifies files for local cleanup")
    check(API.downloadAndGetPath("ATTACH01")==path and API.getAttachmentStatus("ATTACH01")=="downloaded"
        and not pandoc.json.decode(support.read(receipt_path)).download_pending,"Successful retry publishes a valid identity")
    local request_count=#support.requests
    check(API.downloadAndGetPath("ATTACH01")==path and #support.requests==request_count,"Recovered download is reusable offline")

    -- A legacy receipt must retain the old filename before a renamed file is
    -- published, including version-only receipts whose slot later has two files.
    for _,checksum in ipairs({false,true}) do
        local key=checksum and "LEGACY02" or "LEGACY01"
        local renamed=support.attachment(key,"new.pdf",false,12)
        if checksum then renamed.data.md5=string.rep("c",32) end
        support.seed({[key]=renamed},{},12)
        local slot,new_path=API.getDirAndPath(key)
        assert(support.makePath(slot))
        local old_path=slot.."/old.pdf"
        support.write(old_path,"legacy PDF bytes")
        local receipt_file=slot.."/.zotero-cache.json"
        support.write(receipt_file,pandoc.json.encode({version=11,md5=checksum and string.rep("a",32) or nil}))
        support.digests["renamed PDF bytes"]=string.rep("c",32)
        support.response=function(req) return support.respond(req,"renamed PDF bytes") end
        os.rename=function(from,to)
            if to==new_path then return nil,"renamed file publication failure" end
            return rename(from,to)
        end
        local renamed_result,rename_err=API.downloadAndGetPath(key)
        os.rename=rename
        local pending=pandoc.json.decode(support.read(receipt_file))
        check(not renamed_result and rename_err and pending.download_pending and #pending.previous_files==1
            and pending.previous_files[1].filename=="old.pdf" and support.read(old_path)=="legacy PDF bytes",
            "Real JSON pending receipt retains the legacy old filename on failed publication")
        API.init(API.zotero_dir)
        local interrupted=Cleanup.scanDownloads(API)
        local identified=false
        for _,target in ipairs(interrupted.targets) do if target.path==old_path then identified=true end end
        check(identified and #interrupted.unknown==0,"Restart still identifies the renamed legacy old PDF")
        check(API.downloadAndGetPath(key)==new_path and not pandoc.json.decode(support.read(receipt_file)).download_pending,
            "Renamed legacy retry publishes a valid receipt")
        local count=#support.requests
        check(require("localfiles").removeAttachment(API,key,new_path),"Single deletion removes the newly named PDF")
        check(pandoc.json.decode(support.read(receipt_file)).previous_files[1].filename=="old.pdf",
            "Single deletion preserves the receipt of the old legacy copy")
        local remaining=Cleanup.scanDownloads(API)
        local target
        for _,candidate in ipairs(remaining.targets) do if candidate.path==old_path then target=candidate end end
        check(target and #remaining.unknown==0,"Batch cleanup can still find the old legacy copy")
        local cleanup_stats=Cleanup.newStats(remaining)
        Cleanup.processTarget(target,cleanup_stats)
        check(cleanup_stats.deleted==1 and cleanup_stats.failed==0 and cleanup_stats.pending==0
            and not require("libs/libkoreader-lfs").attributes(old_path),"Batch cleanup removes the old legacy copy")
        check(#support.requests==count,"Cleaning renamed legacy copies stays offline")
    end
end,debug.traceback)
support.teardown()
if not ok then error(err) end
io.write(string.format("%d real JSON integration checks passed\n",checks))
