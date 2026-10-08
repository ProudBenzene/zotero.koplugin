local support = require("tests/support")
local fixtures = require("tests/fixtures")
local API
local HELLO_MD5 = "5d41402abc4b2a76b9719d911017c592"
support.digests.hello = HELLO_MD5
for _, fixture in pairs(fixtures) do support.digests[fixture.bytes] = fixture.md5 end

local function default_sync(req, items, collections, deleted, version)
    if req.url:find("/keys/current", 1, true) then return support.key(req) end
    if req.url:find("/items?", 1, true) then return support.respond(req, items or {}, version or 11) end
    if req.url:find("/collections?", 1, true) then return support.respond(req, collections or {}, version or 11) end
    if req.url:find("/deleted?", 1, true) then return support.respond(req, deleted or {items={},collections={}}, version or 11) end
    error("Unexpected request " .. req.url)
end

local function cached_attachment(mode, md5)
    local item=support.attachment("ATTACH01", "paper.pdf", "PARENT01", 20, mode)
    item.data.md5=md5
    support.seed({ATTACH01=item})
    local directory, path=API.getDirAndPath("ATTACH01")
    assert(support.makePath(directory))
    support.write(path,"old PDF")
    support.write(directory.."/.zotero-cache.json",support.JSON.encode({version=10,md5=string.rep("1",32)}))
    return directory,path,item
end

describe("Zotero API offline regressions", function()
    before_each(function() API=support.setup() end)
    after_each(support.teardown)

    it("accepts only numeric IDs and nonempty keys", function()
        support.settings_data.user_id="user123"
        assert(API.ensureKeyAndID())
        assert(not API.setUserID("user123"))
        assert(API.setUserID(" 456 "))
        assert(API.getUserID()=="456")
        API.setAPIKey("   ")
        assert(API.ensureKeyAndID())
    end)

    it("checks key ownership and library access before synchronizing", function()
        support.response=function(req) return support.respond(req,{userID=456,access={user={library=true}}}) end
        assert(API.syncAllItems():find("does not belong",1,true))
        assert(#support.requests==1)
        support.response=function(req) return support.respond(req,{userID=123,access={user={library=false}}}) end
        assert(API.syncAllItems():find("does not permit",1,true))
        support.response=function(req) return support.respond(req,{userID=123,access={user=true}}) end
        assert(API.syncAllItems():find("does not permit",1,true))
    end)

    it("identifies the failing sync stage without replacing the last good snapshot", function()
        support.seed({ATTACH01=support.attachment("ATTACH01","paper.pdf",false)},{},10)
        local disk=support.read(API.cache_path)
        support.response=function() return nil,"timeout" end
        assert(API.syncAllItems():find("Checking Zotero account: Error: timeout",1,true))
        support.response=function(req)
            if req.url:find("/keys/current",1,true) then return support.key(req) end
            if req.url:find("/items?",1,true) then return nil,"timeout" end
            return default_sync(req)
        end
        assert(API.syncAllItems():find("Fetching items (page 1): Error: timeout",1,true))
        support.response=function(req)
            if req.url:find("/collections?",1,true) then return nil,"timeout" end
            return default_sync(req)
        end
        assert(API.syncAllItems():find("Fetching collections (page 1): Error: timeout",1,true))
        support.response=function(req)
            if req.url:find("/deleted?",1,true) then return nil,"timeout" end
            return default_sync(req)
        end
        assert(API.syncAllItems():find("Fetching deletions: Error: timeout",1,true))
        assert(support.read(API.cache_path)==disk and API.getLibraryVersion()==10 and not API.sync_in_progress)
    end)

    it("catches failures before account verification can complete", function()
        local socketutil=require("socketutil")
        local set_timeout=socketutil.set_timeout
        socketutil.set_timeout=function() error("timeout setup failed") end
        local ok,err=pcall(API.syncAllItems)
        socketutil.set_timeout=set_timeout
        assert(ok and err:find("Checking Zotero account:",1,true) and err:find("timeout setup failed",1,true))
        assert(not API.sync_in_progress)
    end)

    it("distinguishes synced metadata from attachments visible in Browse", function()
        local parent={key="PARENT01",data={itemType="journalArticle",title="Article"}}
        local pdf=support.attachment("ATTACH01","paper.pdf","PARENT01")
        local other=support.attachment("ATTACH02","image.png",false);other.data.contentType="image/png"
        local orphan=support.attachment("ATTACH03","orphan.pdf","MISSING1")
        support.seed({PARENT01=parent,ATTACH01=pdf,ATTACH02=other,ATTACH03=orphan},
            {COLLECT1={key="COLLECT1",data={name="Collection",parentCollection=false}}})
        local summary=API.getLibrarySummary()
        assert(summary.items==4 and summary.collections==1 and summary.attachments==1)
        assert(summary.attachments==#API.displaySearchResults(""))
    end)

    it("follows pagination links without a HEAD or an extra empty page", function()
        local a=support.attachment("ATTACH01","a.pdf")
        local b=support.attachment("ATTACH02","b.pdf")
        support.response=function(req,index)
            assert(req.method=="GET")
            if index==1 then
                assert(req.url=="https://api.zotero.org/users/123/items?limit=100")
                return support.respond(req,{a},12,{link='<https://api.zotero.org/users/123/items?limit=100&start=100>; rel="next"'})
            end
            assert(req.url:find("start=100",1,true))
            return support.respond(req,{b},12)
        end
        local items,err,version=API.fetchCollectionPaginated("https://api.zotero.org/users/123/items",API.getHeaders("FAKE-KEY"))
        assert(not err and #items==2 and version==12 and #support.requests==2)
    end)

    it("rejects cross-origin pagination links and cycles", function()
        support.response=function(req) return support.respond(req,{},12,{link='<https://evil.invalid/items>; rel="next"'}) end
        local result,err=API.fetchCollectionPaginated("https://api.zotero.org/users/123/items",{})
        assert(not result and err:find("invalid pagination",1,true) and #support.requests==1)
        support.response=function(req) return support.respond(req,{},12,{link='<https://api.zotero.org/users/123/items?limit=100>; rel="next"'}) end
        result,err=API.fetchCollectionPaginated("https://api.zotero.org/users/123/items",{})
        assert(not result and err:find("invalid pagination",1,true))
    end)

    it("returns errors for network failures, invalid JSON, missing versions and wrong shapes", function()
        support.response=function() return nil,"timeout",nil end
        local items,err=API.fetchCollectionPaginated("https://api.zotero.org/users/123/items",{})
        assert(not items and err:find("timeout",1,true))
        support.response=function(req) return support.respond(req,"invalid JSON",10) end
        items,err=API.fetchCollectionPaginated("https://api.zotero.org/users/123/items",{})
        assert(not items and err:find("parse JSON",1,true))
        support.response=function(req) return support.respond(req,{}) end
        items,err=API.fetchCollectionPaginated("https://api.zotero.org/users/123/items",{})
        assert(not items and err:find("Last-Modified-Version",1,true))
        support.response=function(req) return support.respond(req,{error="bad"},10) end
        items,err=API.fetchCollectionPaginated("https://api.zotero.org/users/123/items",{})
        assert(not items and err:find("JSON array",1,true))
    end)

    it("syncs updates, trash and permanent item/collection deletions together", function()
        support.seed({OLDITEM1=support.attachment("OLDITEM1","old.pdf"),TRASHED1=support.attachment("TRASHED1","trash.pdf")},
            {COLLECT1={key="COLLECT1",data={name="Old",parentCollection=false}}},10)
        local fresh=support.attachment("NEWITEM1","new.pdf")
        local trash=support.attachment("TRASHED1","trash.pdf");trash.data.deleted=1
        support.response=function(req)
            if req.url:find("/items?",1,true) then
                assert(req.url:find("includeTrashed=1",1,true))
                assert(req.headers["If-Modified-Since-Version"]=="10")
            elseif req.url:find("/collections?",1,true) then
                assert(not req.url:find("includeTrashed",1,true))
            end
            return default_sync(req,{fresh,trash},{},{items={"OLDITEM1"},collections={"COLLECT1"}})
        end
        assert(API.syncAllItems()==nil)
        assert(API.getItems().NEWITEM1 and not API.getItems().OLDITEM1 and not API.getItems().TRASHED1)
        assert(not API.getCollections().COLLECT1 and API.getLibraryVersion()==11)
        API.init(support.directory)
        assert(API.getItems().NEWITEM1 and API.getLibraryVersion()==11)
        assert(#support.logs==0)
    end)

    it("keeps the cache on a conditional 304 and stops requesting the library", function()
        support.seed({OLDITEM1=support.attachment("OLDITEM1","old.pdf")}, {},10)
        local disk=support.read(API.cache_path)
        support.response=function(req)
            if req.url:find("/keys/current",1,true) then return support.key(req) end
            return support.respond(req,nil,10,{},304)
        end
        assert(API.syncAllItems()==nil and #support.requests==2)
        assert(API.getItems().OLDITEM1 and support.read(API.cache_path)==disk)
    end)

    it("restarts a changed library and commits only the consistent attempt", function()
        support.seed({}, {},10)
        local round=0
        support.response=function(req)
            if req.url:find("/keys/current",1,true) then return support.key(req) end
            if req.url:find("/items?",1,true) then
                round=round+1
                return support.respond(req,{support.attachment(round==1 and "STALE001" or "LATEST01","paper.pdf")},round==1 and 11 or 12)
            end
            return default_sync(req,{},{},{items={},collections={}},12)
        end
        assert(API.syncAllItems()==nil and round==2)
        assert(API.getLibraryVersion()==12 and API.getItems().LATEST01 and not API.getItems().STALE001)
    end)

    it("leaves the snapshot untouched when versions keep changing between pages", function()
        support.seed({OLDITEM1=support.attachment("OLDITEM1","old.pdf")},{},10)
        local disk=support.read(API.cache_path)
        local rounds=0
        support.response=function(req)
            if req.url:find("/keys/current",1,true) then return support.key(req) end
            if not req.url:find("start=100",1,true) then
                rounds=rounds+1
                return support.respond(req,{support.attachment("NEWITEM1","new.pdf")},11,
                    {link='<https://api.zotero.org/users/123/items?since=10&start=100>; rel="next"'})
            end
            return support.respond(req,{},12)
        end
        assert(API.syncAllItems():find("changed",1,true) and rounds==3)
        assert(API.getLibraryVersion()==10 and API.getItems().OLDITEM1 and not API.getItems().NEWITEM1)
        assert(support.read(API.cache_path)==disk)
    end)

    it("does not apply staged items if fetching collections or deletion logs fails", function()
        support.seed({OLDITEM1=support.attachment("OLDITEM1","old.pdf")},{},10)
        local disk=support.read(API.cache_path)
        support.response=function(req)
            if req.url:find("/collections?",1,true) then return nil,"timeout",nil end
            return default_sync(req,{support.attachment("NEWITEM1","new.pdf")})
        end
        assert(API.syncAllItems():find("timeout",1,true))
        assert(support.read(API.cache_path)==disk and not API.getItems().NEWITEM1)
        support.response=function(req)
            if req.url:find("/deleted?",1,true) then return support.respond(req,{items=false,collections={}},11) end
            return default_sync(req,{support.attachment("NEWITEM1","new.pdf")})
        end
        assert(API.syncAllItems():find("deletion log",1,true))
        assert(support.read(API.cache_path)==disk)
    end)

    it("preserves the last snapshot if atomic publication fails", function()
        support.seed({OLDITEM1=support.attachment("OLDITEM1","old.pdf")},{},10)
        local disk=support.read(API.cache_path)
        local rename=os.rename
        os.rename=function(from,to) if to==API.cache_path then return nil,"disk failure" end; return rename(from,to) end
        support.response=function(req) return default_sync(req,{support.attachment("NEWITEM1","new.pdf")}) end
        assert(API.syncAllItems():find("disk failure",1,true))
        assert(support.read(API.cache_path)==disk and API.getLibraryVersion()==10 and API.getItems().OLDITEM1)
        assert(not require("libs/libkoreader-lfs").attributes(API.cache_path..".tmp"))
    end)

    it("keeps the last good metadata until an explicitly requested full resync succeeds", function()
        support.seed({OLDITEM1=support.attachment("OLDITEM1","old.pdf")},{},10)
        API.resetSyncState()
        assert(API.getItems().OLDITEM1 and API.getLibraryVersion()==0)
        support.response=function(req)
            if req.url:find("/items?",1,true) then assert(req.url:find("since=0",1,true)) end
            return default_sync(req,{support.attachment("NEWITEM1","new.pdf")})
        end
        assert(API.syncAllItems()==nil)
        assert(not API.getItems().OLDITEM1 and API.getItems().NEWITEM1 and API.getLibraryVersion()==11)
    end)

    it("recovers a corrupt snapshot by full resync", function()
        support.write(API.cache_path,"broken cache")
        API.init(support.directory)
        assert(not pcall(API.getItems))
        API.resetSyncState()
        support.response=function(req) return default_sync(req) end
        assert(API.syncAllItems()==nil and API.getLibraryVersion()==11)
    end)

    it("ignores legacy metadata checkpoints and keeps old files on disk", function()
        support.settings_data.library_version_nr=100
        support.write(support.directory.."/items.json","legacy")
        API.init(support.directory)
        assert(API.getLibraryVersion()==0 and not next(API.getItems()))
        assert(support.read(support.directory.."/items.json")=="legacy")
    end)

    it("isolates accounts and invalidates the snapshot when the API key changes", function()
        support.seed({OLDITEM1=support.attachment("OLDITEM1","old.pdf")},{},100)
        local old_storage=API.storage_dir
        assert(API.setUserID("456"))
        assert(API.getLibraryVersion()==0 and not next(API.getItems()) and API.storage_dir~=old_storage)
        support.response=function(req)
            if req.url:find("/items?",1,true) then assert(req.url:find("/users/456/items?since=0",1,true)) end
            return default_sync(req,{support.attachment("NEWITEM1","new.pdf")},{},nil,2)
        end
        assert(API.syncAllItems()==nil and API.getItems().NEWITEM1 and not API.getItems().OLDITEM1)
        API.setAPIKey("REPLACEMENT-KEY")
        assert(API.getLibraryVersion()==0 and not next(API.getItems()))
    end)

    it("honors Retry-After without making more requests", function()
        support.response=function(req) return support.respond(req,"rate limited",nil,{["retry-after"]="30"},429) end
        assert(API.syncAllItems():find("retry in",1,true))
        local count=#support.requests
        assert(API.syncAllItems():find("retry in",1,true) and #support.requests==count)
    end)

    it("uses increasing fallback delays for repeated 429 responses", function()
        support.response=function(req) return support.respond(req,"rate limited",nil,{},429) end
        assert(API.syncAllItems() and API.backoff_until-os.time()>=59)
        API.backoff_until=0
        assert(API.syncAllItems() and API.backoff_until-os.time()>=119)
    end)

    it("finishes a sync receiving Backoff and delays the next sync", function()
        support.response=function(req)
            if req.url:find("/items?",1,true) then return support.respond(req,{},11,{backoff="30"}) end
            return default_sync(req)
        end
        assert(API.syncAllItems()==nil and API.getLibraryVersion()==11)
        local count=#support.requests
        assert(API.syncAllItems():find("retry in",1,true) and #support.requests==count)
    end)

    it("delays new requests after a 503 Retry-After", function()
        support.response=function(req) return support.respond(req,"maintenance",nil,{["retry-after"]="30"},503) end
        assert(API.syncAllItems():find("503",1,true))
        local count=#support.requests
        assert(API.syncAllItems():find("retry in",1,true) and #support.requests==count)
    end)

    it("reports WebDAV failures and checks only the configured directory", function()
        API.setWebDAVUrl("https://dav.invalid/zotero/")
        support.response=function(req)
            assert(req.headers.Depth=="0" and req.url=="https://dav.invalid/zotero")
            local body=req.source()
            assert(body:find('<propfind xmlns="DAV:">',1,true) and tonumber(req.headers["Content-Length"])==#body)
            return nil,"timeout",nil
        end
        assert(API.checkWebDAV():find("timeout",1,true))
        support.response=function(req) return support.respond(req,"denied",nil,{},403) end
        assert(API.checkWebDAV():find("Access forbidden",1,true))
        support.response=function(req) return support.respond(req,"missing",nil,{},404) end
        assert(API.checkWebDAV():find("404",1,true))
        support.response=function(req) return support.respond(req,"OK",nil,{},207) end
        assert(API.checkWebDAV()==nil)
    end)

    it("allocates separate paths for sibling attachments with the same filename", function()
        support.seed({ATTACH01=support.attachment("ATTACH01","paper.pdf","PARENT01"),ATTACH02=support.attachment("ATTACH02","paper.pdf","PARENT01")})
        local a,pa=API.getDirAndPath("ATTACH01")
        local b,pb=API.getDirAndPath("ATTACH02")
        assert(a~=b and pa~=pb)
    end)

    it("handles parentItem=false for top-level attachment paths and collection views", function()
        local item=support.attachment("ATTACH01","paper.pdf",false)
        item.data.collections={"COLLECT1"}
        support.seed({ATTACH01=item})
        local directory,path=API.getDirAndPath("ATTACH01")
        assert(directory and path)
        assert(#API.displayCollection("COLLECT1")==1 and #API.displaySearchResults("")==1)
    end)

    it("reports only reusable local files as downloaded without accessing the network", function()
        local directory,path,item=cached_attachment("imported_file",HELLO_MD5)
        assert(API.getAttachmentStatus(item.key)=="outdated")
        support.write(directory.."/.zotero-cache.json",support.JSON.encode({version=1,md5=HELLO_MD5}))
        local status,cached_path,size=API.getAttachmentStatus(item.key)
        assert(status=="downloaded" and cached_path==path and size==#"old PDF")
        assert(API.downloadAndGetPath(item.key)==path and #support.requests==0)
        item.data.md5=string.rep("2",32)
        assert(API.getAttachmentStatus(item.key)=="outdated")
        support.write(directory.."/.zotero-cache.json","invalid JSON")
        assert(API.getAttachmentStatus(item.key)=="outdated")
        support.write(path,"")
        assert(API.getAttachmentStatus(item.key)=="not_downloaded")
        os.remove(path)
        support.write(directory.."/.zotero-download.part","partial PDF")
        assert(API.getAttachmentStatus(item.key)=="not_downloaded" and #support.requests==0)
    end)

    it("uses attachment versions for download status when no checksum is available", function()
        local directory,path,item=cached_attachment()
        assert(API.getAttachmentStatus(item.key)=="outdated")
        support.write(directory.."/.zotero-cache.json",support.JSON.encode({version=item.version}))
        assert(API.getAttachmentStatus(item.key)=="downloaded")
        item.version=item.version+1
        assert(API.getAttachmentStatus(item.key)=="outdated")
        item.version=nil
        assert(API.getAttachmentStatus(item.key)=="outdated")
        os.remove(path)
        assert(API.getAttachmentStatus(item.key)=="not_downloaded")
        assert(API.getAttachmentStatus("MISSING1")=="not_downloaded")
    end)

    it("does not use a sibling's cached version to skip a changed file", function()
        local directory,path=cached_attachment()
        local item=support.attachment("ATTACH02","other.pdf","PARENT01",30)
        local items=API.getItems();items.ATTACH02=item;assert(API.setItems(items))
        local sibling=API.getDirAndPath("ATTACH02")
        assert(support.makePath(sibling))
        support.write(sibling.."/.zotero-cache.json",support.JSON.encode({version=30}))
        support.response=function(req) return support.respond(req,"hello") end
        assert(API.downloadAndGetPath("ATTACH01")==path and #support.requests==1)
        assert(support.read(path)=="hello")
    end)

    it("downloads imported_url PDFs and reuses the verified local cache offline", function()
        local _,path=cached_attachment("imported_url",HELLO_MD5)
        support.response=function(req) return support.respond(req,"hello",nil,{etag='"'..HELLO_MD5..'"'}) end
        local result,err=API.downloadAndGetPath("ATTACH01")
        assert(result==path and not err and support.read(path)=="hello")
        local count=#support.requests
        support.response=function() error("Cache should be used") end
        assert(API.downloadAndGetPath("ATTACH01")==path and #support.requests==count)
    end)

    it("reports accepted download chunks before the request finishes and keeps the legacy start callback", function()
        local _,path=cached_attachment()
        local events,started,finished={},0,false
        support.response=function(req)
            for _,chunk in ipairs({"he","l","lo"}) do assert(req.sink(chunk)) end
            assert(req.sink(nil))
            finished=true
            return 1,200,{}
        end
        local result,err=API.downloadAndGetPath("ATTACH01",function() started=started+1 end,function(event)
            if event.stage=="downloading" then assert(not finished) end
            events[#events+1]=event
        end)
        assert(result==path and not err and support.read(path)=="hello" and started==1)
        local bytes={}
        for _,event in ipairs(events) do
            if event.stage=="downloading" then bytes[#bytes+1]=event.bytes;assert(event.total==nil) end
        end
        assert(#bytes==4 and bytes[1]==0 and bytes[2]==2 and bytes[3]==3 and bytes[4]==5)
        assert(events[1].stage=="checking_cache" and events[#events].stage=="complete")
        events={}
        support.response=function() error("Verified cache should remain offline") end
        assert(API.downloadAndGetPath("ATTACH01",function() started=started+1 end,function(event)
            events[#events+1]=event
        end)==path)
        assert(started==1 and #events==2 and events[2].stage=="cached")
    end)

    it("resets transfer bytes across redirects and never reports a failed download as complete", function()
        local _,path=cached_attachment()
        local events={}
        support.response=function(req,index)
            if index==1 then return support.respond(req,"redirect",nil,{location="https://storage.invalid/file"},302) end
            assert(req.sink("partial"))
            return nil,"timeout",{}
        end
        local result,err=API.downloadAndGetPath("ATTACH01",nil,function(event) events[#events+1]=event end)
        assert(not result and err:find("timeout",1,true) and support.read(path)=="old PDF")
        local bytes={}
        for _,event in ipairs(events) do
            assert(event.stage~="complete")
            if event.stage=="downloading" then bytes[#bytes+1]=event.bytes end
        end
        assert(#bytes==4 and bytes[1]==0 and bytes[2]==8 and bytes[3]==0 and bytes[4]==7)
    end)

    it("does not count chunks rejected by the file sink", function()
        local _,path=cached_attachment()
        local events,closed={},false
        local open=io.open
        io.open=function(name,mode)
            if name:find(".zotero-download.part",1,true) and mode=="wb" then
                return {write=function() return nil,"disk full" end,close=function() closed=true;return true end}
            end
            return open(name,mode)
        end
        support.response=function(req)
            local accepted,err=req.sink("unsaved")
            assert(not accepted and err=="disk full")
            return nil,err,{}
        end
        local result,err=API.downloadAndGetPath("ATTACH01",nil,function(event) events[#events+1]=event end)
        assert(not result and err:find("disk full",1,true) and closed and support.read(path)=="old PDF")
        for _,event in ipairs(events) do assert(not event.bytes or event.bytes==0) end
    end)

    it("reports WebDAV ZIP reception, extraction and verification in order", function()
        local _,path=cached_attachment("imported_file",HELLO_MD5)
        API.setWebDAVUrl("https://dav.invalid/zotero")
        support.settings_data.webdav_enabled=true
        local events={}
        support.response=function(req) return support.respond(req,fixtures.plain.bytes) end
        assert(API.downloadAndGetPath("ATTACH01",nil,function(event) events[#events+1]=event end)==path)
        local received,extracted,verified
        for index,event in ipairs(events) do
            if event.stage=="downloading" and event.bytes>0 then received=index;assert(event.bytes==#fixtures.plain.bytes) end
            if event.stage=="extracting" then extracted=index end
            if event.stage=="verifying" then verified=verified or index end
        end
        assert(received<extracted and extracted<verified and events[#events].stage=="complete")
    end)

    it("keeps downloads and synchronization intact if a progress observer throws", function()
        local _,path=cached_attachment()
        support.response=function(req) return support.respond(req,"hello") end
        local function broken_observer() error("progress UI failed") end
        assert(API.downloadAndGetPath("ATTACH01",nil,broken_observer)==path)
        support.response=function(req) return default_sync(req) end
        assert(API.syncAllItems(broken_observer)==nil and not API.sync_in_progress and API.getLibraryVersion()==11)
    end)

    it("reports page counts and totals while synchronizing without extra requests", function()
        support.seed({}, {},10)
        local a,b=support.attachment("ATTACH01","a.pdf"),support.attachment("ATTACH02","b.pdf")
        local events={}
        support.response=function(req)
            if req.url:find("/items?",1,true) then
                if req.url:find("start=100",1,true) then return support.respond(req,{b},11,{["Total-Results"]="2"}) end
                return support.respond(req,{a},11,{["Total-Results"]="2",
                    link='<https://api.zotero.org/users/123/items?since=10&includeTrashed=1&limit=100&start=100>; rel="next"'})
            end
            return default_sync(req)
        end
        assert(API.syncAllItems(function(event) events[#events+1]=event end)==nil and #support.requests==5)
        local counts={}
        local second_page,collections,deletions,saving
        for _,event in ipairs(events) do
            if event.stage=="items" and event.bytes==nil then counts[#counts+1]=event end
            if event.stage=="items" and event.page==2 and event.bytes==0 then second_page=event end
            if event.stage=="collections" then collections=true end
            if event.stage=="deletions" then deletions=true end
            if event.stage=="saving_library" then saving=true end
        end
        assert(#counts==2 and counts[1].completed==1 and counts[1].total==2 and counts[2].completed==2)
        assert(second_page.completed==1 and second_page.total==2 and collections and deletions and saving)
        assert(events[1].stage=="checking_account" and events[#events].stage=="complete")
    end)

    it("resets page progress when a changing library requires a retry", function()
        support.seed({}, {},10)
        local events,round={},0
        support.response=function(req)
            if req.url:find("/items?",1,true) then
                round=round+1
                return support.respond(req,{support.attachment("ATTACH01","a.pdf")},round==1 and 11 or 12,{["total-results"]="1"})
            end
            return default_sync(req,nil,nil,nil,12)
        end
        assert(API.syncAllItems(function(event) events[#events+1]=event end)==nil and round==2)
        local retry_index
        for index,event in ipairs(events) do if event.stage=="retrying" then retry_index=index;assert(event.attempt==2) end end
        assert(retry_index and events[retry_index+1].stage=="items" and events[retry_index+1].completed==0)
        assert(events[retry_index+1].total==nil and events[#events].stage=="complete")
    end)

    it("keeps unknown totals unknown and reports unchanged libraries without a false completion", function()
        local events={}
        support.response=function(req) return support.respond(req,{support.attachment("ATTACH01","a.pdf")},11) end
        assert(API.fetchCollectionPaginated("https://api.zotero.org/users/123/items",{},nil,nil,
            function(event) events[#events+1]=event end))
        assert(events[#events].completed==1 and events[#events].total==nil)
        support.seed({}, {},11)
        events={}
        support.response=function(req)
            if req.url:find("/keys/current",1,true) then return support.key(req) end
            return support.respond(req,nil,11,{},304)
        end
        assert(API.syncAllItems(function(event) events[#events+1]=event end)==nil)
        assert(events[#events].stage=="up_to_date")
    end)

    it("redownloads empty caches and caches with no identifiable attachment version", function()
        local directory,path,item=cached_attachment("imported_file",HELLO_MD5)
        support.write(path,"")
        support.write(directory.."/.zotero-cache.json",support.JSON.encode({md5=HELLO_MD5}))
        support.response=function(req) return support.respond(req,"hello") end
        assert(API.downloadAndGetPath("ATTACH01")==path and #support.requests==1)
        item.data.md5=nil
        item.version=nil
        support.write(path,"old PDF")
        support.write(directory.."/.zotero-cache.json",support.JSON.encode({}))
        assert(API.downloadAndGetPath("ATTACH01")==path and #support.requests==2)
        assert(support.read(path)=="hello")
    end)

    it("preserves the old file and metadata when a download fails after receiving data", function()
        local directory,path=cached_attachment()
        local metadata=support.read(directory.."/.zotero-cache.json")
        support.response=function(req) return support.respond(req,"server error",nil,{},500) end
        local result,err=API.downloadAndGetPath("ATTACH01")
        assert(not result and err:find("500",1,true) and support.read(path)=="old PDF")
        assert(support.read(directory.."/.zotero-cache.json")==metadata)
        support.response=function(req) assert(req.sink("partial"));return nil,"timeout",nil end
        result,err=API.downloadAndGetPath("ATTACH01")
        assert(not result and err:find("timeout",1,true) and support.read(path)=="old PDF")
        assert(not require("libs/libkoreader-lfs").attributes(directory.."/.zotero-download.part"))
    end)

    it("preserves cached files on checksum mismatches, empty files and disk errors", function()
        local directory,path=cached_attachment("imported_file",HELLO_MD5)
        support.response=function(req) return support.respond(req,"wrong",nil,{etag='"'..HELLO_MD5..'"'}) end
        assert(not API.downloadAndGetPath("ATTACH01") and support.read(path)=="old PDF")
        support.response=function(req) return support.respond(req,"hello",nil,{etag='"'..string.rep("1",32)..'"'}) end
        assert(not API.downloadAndGetPath("ATTACH01") and support.read(path)=="old PDF")
        API.getItems().ATTACH01.data.md5=nil
        support.response=function(req) return support.respond(req,"") end
        assert(not API.downloadAndGetPath("ATTACH01") and support.read(path)=="old PDF")
        support.response=function(req) return support.respond(req,"hello") end
        local rename=os.rename
        os.rename=function(from,to) if to==path then return nil,"disk failure" end;return rename(from,to) end
        assert(not API.downloadAndGetPath("ATTACH01") and support.read(path)=="old PDF")
    end)

    it("removes API keys on cross-origin redirects and preserves first-response file headers", function()
        local _,path=cached_attachment("imported_file",HELLO_MD5)
        support.response=function(req,index)
            assert(req.redirect==false)
            if index==1 then
                assert(req.headers["Zotero-API-Key"]=="FAKE-KEY")
                return support.respond(req,"redirect",nil,{location="https://attachment-proxy.invalid/file",["zotero-file-md5"]=string.rep("1",32)},302)
            end
            assert(not req.headers["Zotero-API-Key"] and not req.headers.Authorization)
            return support.respond(req,"hello",nil,{etag='"'..HELLO_MD5..'"'})
        end
        local result,err=API.downloadAndGetPath("ATTACH01")
        assert(not result and err:find("does not match",1,true) and support.read(path)=="old PDF")
        assert(#support.requests==2)
    end)

    it("rejects HTTPS downgrade redirects and closes thrown network errors", function()
        local directory,path=cached_attachment()
        support.response=function(req) return support.respond(req,"redirect",nil,{location="http://storage.invalid/file"},302) end
        assert(not API.downloadAndGetPath("ATTACH01") and #support.requests==1 and support.read(path)=="old PDF")
        support.response=function() error("network exception") end
        local result,err=API.downloadAndGetPath("ATTACH01")
        assert(not result and err:find("network exception",1,true) and support.read(path)=="old PDF")
        assert(not require("libs/libkoreader-lfs").attributes(directory.."/.zotero-download.part"))
    end)

    it("caps redirect loops", function()
        cached_attachment()
        support.response=function(req) return support.respond(req,"redirect",nil,{location=req.url},302) end
        local result,err=API.downloadAndGetPath("ATTACH01")
        assert(not result and err:find("Too many",1,true) and #support.requests==6)
    end)

    it("finishes a slow file transfer beyond sixty seconds and restores socket timeouts", function()
        local _,path=cached_attachment("imported_file",HELLO_MD5)
        local time=os.time
        local clock=time()
        os.time=function() return clock end
        local socketutil=require("socketutil")
        local block,total=socketutil.block_timeout,socketutil.total_timeout
        support.response=function(req)
            assert(socketutil.block_timeout==socketutil.FILE_BLOCK_TIMEOUT and socketutil.total_timeout==-1)
            for _,chunk in ipairs({"h","e","l","l","o"}) do
                clock=clock+20
                assert(req.sink(chunk))
            end
            assert(req.sink(nil))
            return 1,200,{}
        end
        local result,err=API.downloadAndGetPath("ATTACH01")
        os.time=time
        assert(result==path and not err and support.read(path)=="hello")
        assert(socketutil.block_timeout==block and socketutil.total_timeout==total)
    end)

    it("finishes a metadata page receiving data for longer than thirty seconds", function()
        support.seed({ATTACH01=support.attachment("ATTACH01","paper.pdf",false)},{},10)
        local clock=os.time()
        os.time=function() return clock end
        support.response=function(req)
            if req.url:find("/keys/current",1,true) then return support.key(req) end
            assert(require("socketutil").total_timeout==-1)
            local value=req.url:find("/deleted?",1,true) and {items={},collections={}} or {}
            local body=support.JSON.encode(value)
            for start=1,#body,4 do clock=clock+20;assert(req.sink(body:sub(start,start+3))) end
            assert(req.sink(nil))
            return 1,200,{["last-modified-version"]="11"}
        end
        assert(API.syncAllItems()==nil and API.getLibraryVersion()==11 and not API.sync_in_progress)
        assert(API.getItems().ATTACH01)
    end)

    it("retries a failed page without restarting earlier pages or merging partial records", function()
        local calls,merged,events=0,{},{}
        support.response=function(req)
            calls=calls+1
            if calls==1 then return support.respond(req,{support.attachment("ATTACH01","a.pdf")},11,
                {link='<https://api.zotero.org/users/123/items?start=100>; rel="next"'}) end
            assert(req.url:find("start=100",1,true))
            if calls==2 then assert(req.sink("partial"));return nil,"timeout" end
            if calls==3 then return support.respond(req,"short",11,{["content-length"]="100"}) end
            return support.respond(req,{support.attachment("ATTACH02","b.pdf")},11)
        end
        local version,err=API.fetchCollectionPaginated("https://api.zotero.org/users/123/items",{},
            function(entries) for _,item in ipairs(entries) do merged[#merged+1]=item.key end end,nil,
            function(event) events[#events+1]=event end)
        assert(not err and version==11 and calls==4 and #merged==2 and merged[2]=="ATTACH02")
        local retries=0
        for _,event in ipairs(events) do
            if event.stage=="retrying_request" then
                retries=retries+1;assert(event.page==2 and event.completed==1 and event.attempt==retries+1)
            end
        end
        assert(retries==2)
    end)

    it("bounds metadata retries and retains the last good snapshot after repeated stalls", function()
        support.seed({ATTACH01=support.attachment("ATTACH01","paper.pdf",false)},{},10)
        local disk,calls=support.read(API.cache_path),0
        support.response=function(req)
            if req.url:find("/keys/current",1,true) then return support.key(req) end
            calls=calls+1;assert(req.sink("partial"));return nil,"closed"
        end
        assert(API.syncAllItems():find("page 1",1,true) and calls==3)
        assert(support.read(API.cache_path)==disk and API.getLibraryVersion()==10)
    end)

    it("compacts old caches without losing keys, versions, collection levels or attachment hashes", function()
        local item=support.attachment("ATTACH01","paper.pdf","PARENT01",21)
        item.data.md5=HELLO_MD5
        local state={format=1,user_id="123",key_fingerprint="test-fingerprint:FAKE-KEY",version=22,
            items={ATTACH01=item,
                PARENT01={key="PARENT01",version=20,links={self="unused"},meta={creatorSummary="Author",parsedDate="2001"},
                    data={itemType="journalArticle",title="Paper",DOI="10.1234/test",collections={"CHILD001"},abstractNote=string.rep("a",10000)}},
                NOTE0001={key="NOTE0001",version=19,data={itemType="note",parentItem="PARENT01",note=string.rep("html",10000)}},
                ANNOT001={key="ANNOT001",version=18,data={itemType="annotation",annotationText=string.rep("text",10000)}}},
            collections={ROOT0001={key="ROOT0001",data={name="Root",parentCollection=false}},
                CHILD001={key="CHILD001",data={name="Child",parentCollection="ROOT0001"}}}}
        support.write(API.cache_path,support.JSON.encode(state))
        API.init(support.directory)
        assert(not API.isLibraryLoaded())
        local items=API.getItems()
        assert(items.NOTE0001.data.note==nil and items.ANNOT001.data.annotationText==nil)
        assert(items.PARENT01.data.abstractNote==nil and items.PARENT01.links==nil)
        assert(items.PARENT01.meta.creatorSummary=="Author" and items.PARENT01.meta.parsedDate==nil)
        assert(items.ATTACH01.version==21 and items.ATTACH01.data.md5==HELLO_MD5 and API.getLibraryVersion()==22)
        assert(API.getLibrarySummary().items==4 and API.getLibrarySummary().attachments==1)
        assert(API.displayCollection("ROOT0001")[1].key=="CHILD001" and API.displayCollection("CHILD001")[1].key=="ATTACH01")
        local disk=support.JSON.decode(support.read(API.cache_path))
        assert(disk.compact and disk.items.NOTE0001.data.note==nil and disk.version==22)
    end)

    it("stores compact records during full sync and still counts every object", function()
        local note={key="NOTE0001",version=11,data={itemType="note",note=string.rep("html",10000)}}
        API.resetSyncState()
        support.response=function(req) return default_sync(req,{note,support.attachment("ATTACH01","paper.pdf",false)}) end
        assert(API.syncAllItems()==nil)
        assert(API.getItems().NOTE0001.data.note==nil and API.getLibrarySummary().items==2)
        assert(API.getLibrarySummary().attachments==1 and support.JSON.decode(support.read(API.cache_path)).compact)
    end)

    it("reuses loaded metadata across reader initialization but invalidates it for other accounts", function()
        support.seed({ATTACH01=support.attachment("ATTACH01","paper.pdf",false)},{},10)
        local items=API.getItems()
        API.backoff_until=os.time()+10
        API.init(support.directory,true)
        assert(API.getItems()==items and API.backoff_until>os.time())
        support.settings_data.api_key="DIFFERENT-KEY"
        API.init(support.directory,true)
        assert(not API.isLibraryLoaded() and not next(API.getItems()) and API.backoff_until==0)
    end)

    it("retries a corrupt WebDAV ZIP once and retains failure evidence after success", function()
        local _,path=cached_attachment("imported_file",HELLO_MD5)
        API.setWebDAVUrl("https://dav.invalid/zotero")
        support.settings_data.webdav_enabled=true
        support.response=function(req,index) return support.respond(req,index==1 and "not a zip" or fixtures.plain.bytes) end
        assert(API.downloadAndGetPath("ATTACH01")==path and support.read(path)=="hello" and #support.requests==2)
        assert(support.read(API.zotero_dir.."/.zotero-failed-download.zip")=="not a zip")
        assert(support.read(API.zotero_dir.."/download-error.log"):find("End-of-central-directory",1,true))
    end)

    it("keeps the main file CRC diagnostic instead of a missing legacy fallback name", function()
        local _,path=cached_attachment("imported_file",HELLO_MD5)
        API.setWebDAVUrl("https://dav.invalid/zotero")
        support.settings_data.webdav_enabled=true
        local corrupt=fixtures.plain.bytes:gsub("hello","jello",1)
        support.response=function(req) return support.respond(req,corrupt) end
        local result,err=API.downloadAndGetPath("ATTACH01")
        assert(not result and err:lower():find("bad crc",1,true) and #support.requests==2)
        assert(support.read(path)=="old PDF")
        assert(support.read(API.zotero_dir.."/download-error.log"):lower():find("bad crc",1,true))
    end)

    it("reports stalled file transfers and removes partial downloads without touching cached files", function()
        local directory,path=cached_attachment()
        local metadata=support.read(directory.."/.zotero-cache.json")
        local socketutil=require("socketutil")
        local block,total=socketutil.block_timeout,socketutil.total_timeout
        support.response=function(req)
            assert(socketutil.block_timeout==socketutil.FILE_BLOCK_TIMEOUT and socketutil.total_timeout==-1)
            assert(req.sink("partial"))
            return nil,"timeout"
        end
        local result,err=API.downloadAndGetPath("ATTACH01")
        assert(not result and err:find("waiting for data",1,true) and err:find("received 7 bytes",1,true))
        assert(support.read(path)=="old PDF" and support.read(directory.."/.zotero-cache.json")==metadata)
        assert(not require("libs/libkoreader-lfs").attributes(directory.."/.zotero-download.part"))
        assert(socketutil.block_timeout==block and socketutil.total_timeout==total)
    end)

    it("downloads and extracts a WebDAV ZIP taking longer than sixty seconds", function()
        local directory,path=cached_attachment("imported_file",HELLO_MD5)
        API.setWebDAVUrl("https://dav.invalid/zotero")
        support.settings_data.webdav_enabled=true
        local clock=os.time()
        os.time=function() return clock end
        support.response=function(req)
            assert(req.url:find("ATTACH01.zip",1,true))
            local bytes=fixtures.plain.bytes
            for start=1,#bytes,40 do
                clock=clock+20
                assert(req.sink(bytes:sub(start,start+39)))
            end
            assert(req.sink(nil))
            return 1,200,{}
        end
        assert(API.downloadAndGetPath("ATTACH01")==path and support.read(path)=="hello")
        assert(not require("libs/libkoreader-lfs").attributes(directory.."/.zotero-download.zip"))
    end)

    it("extracts current and legacy WebDAV ZIPs without overwrite prompts", function()
        local directory,path=cached_attachment("imported_file",HELLO_MD5)
        API.setWebDAVUrl("https://dav.invalid/zotero")
        support.settings_data.webdav_enabled=true
        for _,fixture in ipairs({fixtures.plain,fixtures.encoded}) do
            support.write(path,"old PDF")
            support.write(directory.."/.zotero-cache.json",support.JSON.encode({version=10}))
            support.response=function(req) return support.respond(req,fixture.bytes) end
            assert(API.downloadAndGetPath("ATTACH01")==path and support.read(path)=="hello")
            assert(not require("libs/libkoreader-lfs").attributes(directory.."/.zotero-download.zip"))
        end
    end)

    it("resumes a truncated WebDAV ZIP before extracting it and counts cumulative bytes", function()
        local directory,path=cached_attachment("imported_file",HELLO_MD5)
        API.setWebDAVUrl("https://dav.invalid/zotero")
        support.settings_data.webdav_enabled=true
        local bytes,events=fixtures.plain.bytes,{}
        local cut=#bytes-22 -- No central-directory footer in the first response.
        support.response=function(req,index)
            assert(req.headers["Accept-Encoding"]=="identity")
            if index==1 then
                assert(not req.headers.Range)
                return support.respond(req,bytes:sub(1,cut),nil,{["Content-Length"]=tostring(#bytes),ETag='"archive-v1"'})
            end
            assert(req.headers.Range=="bytes="..cut.."-" and req.headers["If-Range"]=='"archive-v1"')
            return support.respond(req,bytes:sub(cut+1),nil,{["content-length"]=tostring(#bytes-cut),etag='"archive-v1"',
                ["content-range"]=("bytes %d-%d/%d"):format(cut,#bytes-1,#bytes)},206)
        end
        assert(API.downloadAndGetPath("ATTACH01",nil,function(event) events[#events+1]=event end)==path)
        assert(support.read(path)=="hello" and #support.requests==2)
        local resumed,complete
        for _,event in ipairs(events) do
            if event.stage=="resuming" then resumed=event.bytes==cut and event.attempt==1 end
            if event.stage=="downloading" and event.bytes==#bytes then complete=true end
        end
        assert(resumed and complete)
        assert(not require("libs/libkoreader-lfs").attributes(directory.."/.zotero-download.zip.response"))
    end)

    it("rejects short responses without a strong validator before ZIP extraction", function()
        local directory,path=cached_attachment("imported_file",HELLO_MD5)
        local metadata=support.read(directory.."/.zotero-cache.json")
        API.setWebDAVUrl("https://dav.invalid/zotero")
        support.settings_data.webdav_enabled=true
        for _,etag in ipairs({false,'W/"weak"'}) do
            local calls=0
            support.response=function(req)
                calls=calls+1
                return support.respond(req,"short",nil,{["content-length"]="100",etag=etag or nil})
            end
            local result,err=API.downloadAndGetPath("ATTACH01")
            assert(not result and err:find("received 5 of 100 bytes",1,true) and calls==1)
            assert(support.read(path)=="old PDF" and support.read(directory.."/.zotero-cache.json")==metadata)
            assert(not require("libs/libkoreader-lfs").attributes(directory.."/.zotero-download.zip.response"))
        end
    end)

    it("rejects mismatched ranges and changed validators without appending their data", function()
        local directory,path=cached_attachment("imported_file",HELLO_MD5)
        for _,invalid in ipairs({{range="bytes 1-4/5",etag='"original"'},
            {range="bytes 2-4/6",etag='"original"'}, {range="bytes 2-4/5",etag='"changed"'}}) do
            local calls=0
            support.response=function(req)
                calls=calls+1
                if calls==1 then return support.respond(req,"he",nil,{["content-length"]="5",etag='"original"'}) end
                return support.respond(req,"llo",nil,{["content-length"]="3",etag=invalid.etag,["content-range"]=invalid.range},206)
            end
            local result,err=API.downloadAndGetPath("ATTACH01")
            assert(not result and err:find("byte range",1,true) and support.read(path)=="old PDF")
            assert(not require("libs/libkoreader-lfs").attributes(directory.."/.zotero-download.part.response"))
        end
    end)

    it("replaces rather than appends a full response when the server ignores If-Range", function()
        local _,path=cached_attachment("imported_file",HELLO_MD5)
        support.response=function(req,index)
            if index==1 then return support.respond(req,"he",nil,{["content-length"]="5",etag='"old"'}) end
            assert(req.headers.Range=="bytes=2-" and req.headers["If-Range"]=='"old"')
            return support.respond(req,"hello",nil,{["content-length"]="5",etag='"'..HELLO_MD5..'"'})
        end
        assert(API.downloadAndGetPath("ATTACH01")==path and support.read(path)=="hello" and #support.requests==2)
    end)

    it("limits repeated short responses and removes all partial files", function()
        local directory,path=cached_attachment()
        support.response=function(req,index)
            if index==1 then return support.respond(req,"h",nil,{["content-length"]="10",etag='"stable"'}) end
            assert(req.headers.Range=="bytes="..(index-1).."-")
            return support.respond(req,"x",nil,{["content-length"]=tostring(11-index),etag='"stable"',
                ["content-range"]=("bytes %d-9/10"):format(index-1)},206)
        end
        local result,err=API.downloadAndGetPath("ATTACH01")
        assert(not result and #support.requests==4 and err:find("received 4 of 10 bytes",1,true))
        assert(support.read(path)=="old PDF")
        for _,suffix in ipairs({".zotero-download.part",".zotero-download.part.response"}) do
            assert(not require("libs/libkoreader-lfs").attributes(directory.."/"..suffix))
        end
    end)

    it("retains compressed Zotero storage headers across a resumed download", function()
        local _,path=cached_attachment("imported_file",HELLO_MD5)
        local bytes=fixtures.plain.bytes
        support.response=function(req,index)
            if index==1 then
                return support.respond(req,"redirect",nil,{location="https://storage.invalid/file",["zotero-file-compressed"]="Yes",
                    ["zotero-file-md5"]=fixtures.plain.md5},302)
            end
            assert(not req.headers["Zotero-API-Key"])
            if index==2 then return support.respond(req,bytes:sub(1,40),nil,{["content-length"]=tostring(#bytes),etag='"'..fixtures.plain.md5..'"'}) end
            assert(req.headers.Range=="bytes=40-")
            return support.respond(req,bytes:sub(41),nil,{["content-length"]=tostring(#bytes-40),etag='"'..fixtures.plain.md5..'"',
                ["content-range"]=("bytes 40-%d/%d"):format(#bytes-1,#bytes)},206)
        end
        assert(API.downloadAndGetPath("ATTACH01")==path and support.read(path)=="hello")
    end)

    it("rejects unsolicited partial responses and oversized bodies", function()
        local _,path=cached_attachment()
        support.response=function(req) return support.respond(req,"hello",nil,{["content-range"]="bytes 0-4/5"},206) end
        assert(not API.downloadAndGetPath("ATTACH01") and support.read(path)=="old PDF")
        support.response=function(req) return support.respond(req,"hello",nil,{["content-length"]="4"}) end
        assert(not API.downloadAndGetPath("ATTACH01") and support.read(path)=="old PDF")
    end)

    it("keeps existing PDFs when WebDAV ZIPs are corrupt or omit the requested file", function()
        local directory,path=cached_attachment("imported_file",HELLO_MD5)
        API.setWebDAVUrl("https://dav.invalid/zotero")
        support.settings_data.webdav_enabled=true
        for _,content in ipairs({"not a zip",fixtures.missing.bytes}) do
            support.response=function(req) return support.respond(req,content) end
            assert(not API.downloadAndGetPath("ATTACH01") and support.read(path)=="old PDF")
            assert(not require("libs/libkoreader-lfs").attributes(directory.."/.zotero-download.zip"))
        end
    end)

    it("distinguishes zero and nonzero Lua 5.1 unzip exit codes", function()
        local _,path=cached_attachment()
        API.setWebDAVUrl("https://dav.invalid/zotero")
        support.settings_data.webdav_enabled=true
        support.response=function(req) return support.respond(req,fixtures.plain.bytes) end
        os.execute=function() return 256 end
        local result,err=API.downloadAndGetPath("ATTACH01")
        assert(not result and err:find("extract",1,true) and support.read(path)=="old PDF")
    end)

    it("quotes paths and escapes ZIP glob characters in attachment names", function()
        local name="A [paper]'?.pdf"
        local item=support.attachment("ATTACH01",name,false)
        item.data.md5=HELLO_MD5
        support.seed({ATTACH01=item})
        API.setWebDAVUrl("https://dav.invalid/zotero")
        support.settings_data.webdav_enabled=true
        support.response=function(req) return support.respond(req,fixtures.special.bytes) end
        local path,err=API.downloadAndGetPath("ATTACH01")
        assert(path and not err and support.read(path)=="hello")
    end)

    it("checks ZIP storage hashes separately from the uncompressed attachment hash", function()
        local _,path,item=cached_attachment("imported_file",HELLO_MD5)
        item.data.mtime="1700000000123"
        support.response=function(req,index)
            if index==1 then
                return support.respond(req,"redirect",nil,{location="https://storage.invalid/file",["zotero-file-compressed"]="Yes",
                    ["zotero-file-md5"]=fixtures.plain.md5,["zotero-file-modification-time"]=item.data.mtime},302)
            end
            return support.respond(req,fixtures.plain.bytes,nil,{etag='"'..fixtures.plain.md5..'"'})
        end
        assert(API.downloadAndGetPath("ATTACH01")==path and support.read(path)=="hello")
        assert(support.last_touch[3]==1700000000.123)
    end)

    it("keeps the existing PDF if a compressed download fails its storage checksum", function()
        local _,path=cached_attachment("imported_file",HELLO_MD5)
        support.response=function(req)
            return support.respond(req,fixtures.plain.bytes,nil,{["zotero-file-compressed"]="Yes",["zotero-file-md5"]=string.rep("1",32)})
        end
        local result,err=API.downloadAndGetPath("ATTACH01")
        assert(not result and err:find("ZIP",1,true) and support.read(path)=="old PDF")
    end)

    it("removes WebDAV credentials when a ZIP redirects to another host", function()
        local _,path=cached_attachment("imported_file",HELLO_MD5)
        API.setWebDAVUrl("https://dav.invalid/zotero")
        support.settings_data.webdav_enabled=true
        support.response=function(req,index)
            if index==1 then
                assert(req.headers.Authorization)
                return support.respond(req,"redirect",nil,{location="https://storage.invalid/file"},302)
            end
            assert(not req.headers.Authorization)
            return support.respond(req,fixtures.plain.bytes)
        end
        assert(API.downloadAndGetPath("ATTACH01")==path)
    end)

    it("treats search punctuation literally and keeps word-order matching", function()
        support.seed({ATTACH01=support.attachment("ATTACH01","A [paper] 10x1234 100% test.pdf",false),
            ATTACH02=support.attachment("ATTACH02","B 10.1234 test.pdf",false)})
        assert(#API.displaySearchResults("[")==1)
        assert(#API.displaySearchResults("10.1234")==1 and API.displaySearchResults("10.1234")[1].key=="ATTACH02")
        assert(#API.displaySearchResults("100%")==1 and #API.displaySearchResults("paper test")==1)
        assert(#API.displaySearchResults("test paper")==0 and #API.displaySearchResults("")==2)
    end)

    it("hides orphaned and trashed children and tolerates missing creator metadata", function()
        local parent={key="PARENT01",data={itemType="journalArticle",title="Paper",collections={"COLLECT1"},DOI="10.1234/example"}}
        local child=support.attachment("ATTACH01","paper.pdf","PARENT01")
        support.seed({PARENT01=parent,ATTACH01=child})
        assert(#API.displayCollection("COLLECT1")==1 and #API.displaySearchResults("example")==1)
        parent.data.deleted=1
        assert(#API.displaySearchResults("")==0)
        API.getItems().PARENT01=nil
        assert(#API.displaySearchResults("")==0)
    end)
end)
