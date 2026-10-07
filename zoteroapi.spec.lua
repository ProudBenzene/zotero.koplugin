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

    it("caps redirect loops and total streaming time", function()
        local directory,path=cached_attachment()
        support.response=function(req) return support.respond(req,"redirect",nil,{location=req.url},302) end
        local result,err=API.downloadAndGetPath("ATTACH01")
        assert(not result and err:find("Too many",1,true) and #support.requests==6)
        local time=os.time
        local clock=time()
        os.time=function() return clock end
        support.response=function(req)
            clock=clock+61
            local ok,reason=req.sink("late chunk")
            assert(not ok and reason=="sink timeout")
            return nil,reason,nil
        end
        result,err=API.downloadAndGetPath("ATTACH01")
        os.time=time
        assert(not result and err:find("sink timeout",1,true) and support.read(path)=="old PDF")
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
