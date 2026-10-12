-- Run actual KOReader DocSettings open/flush/purge code on real PDF/EPUB stand-ins.
-- Hash calculation, directory enumeration and UI/history are test doubles.
-- Usage: pandoc lua tests/localfiles-integration.lua /path/to/frontend/docsettings.lua
package.path = "./?.lua;./tests/?.lua;" .. package.path
local source = assert(arg[1], "Supply KOReader frontend/docsettings.lua")
local support = require("tests/support")
local LocalFiles = require("localfiles")
local Cleanup = require("downloadcleanup")
local checks = 0
local function check(value, label)
    assert(value, label)
    checks = checks + 1
end

for _, extension in ipairs({"pdf","epub"}) do
for _, location in ipairs({"doc","dir","hash"}) do
    local API = support.setup()
    local ok, err = xpcall(function()
        local item = support.attachment("ATTACH01","paper."..extension,false)
        if extension=="epub" then item.data.contentType="application/epub+zip" end
        support.seed({ATTACH01=item})
        local directory,path = API.getDirAndPath(item.key)
        assert(support.makePath(directory))
        support.write(path,"document stand-in")
        support.write(directory.."/.zotero-cache.json",support.JSON.encode({version=10}))
        support.write(directory.."/.zotero-annotations.json","annotation cache")
        local storage = require("datastorage")
        local history,central,hashed = support.directory.."/history",support.directory.."/docsettings",support.directory.."/hash"
        storage.getHistoryDir = function() return history end
        storage.getDocSettingsDir = function() return central end
        storage.getDocSettingsHashDir = function() return hashed end
        assert(support.makePath(history) and support.makePath(central) and support.makePath(hashed))
        local settings = require("luasettings")
        settings.extend = require("ui/widget/container/widgetcontainer").extend
        settings.readSetting = function(self,key) return self.data[key] end
        package.loaded.dump = function() return "" end
        package.loaded.logger = {dbg=function() end,warn=function() end}
        local ffiutil = require("ffi/util")
        ffiutil.basename = function(file) return file:match("([^/]+)$") end
        local util = require("util")
        util.splitFileNameSuffix = function(file) return file:match("^(.*)%.([^%.]+)$") end
        util.removePath = function(dir) return os.remove(dir) end
        local hash_calls = 0
        local hash = string.rep("a",32)
        util.partialMD5 = function(file)
            check(support.read(file)=="document stand-in","Hash sidecar located before document removal")
            hash_calls = hash_calls+1
            return hash
        end
        G_reader_settings = {readSetting=function(_,key,default)
            if key=="document_metadata_folder" then return location end
            return default
        end}
        local lfs = require("libs/libkoreader-lfs")
        local attributes = lfs.attributes
        local directory_iterator = lfs.dir
        lfs.attributes = function(file,field)
            local attr = attributes(file)
            if attr then attr.modification=100 end
            return field and attr and attr[field] or (not field and attr or nil)
        end
        local files = {}
        lfs.dir = function(dir)
            local entries = {}
            for file in pairs(files) do
                if file:match("^(.*)/[^/]+$")==dir and lfs.attributes(file) then
                    entries[#entries+1] = file:match("([^/]+)$")
                end
            end
            local index = 0
            return function() index=index+1; return entries[index] end
        end
        local function write(file,content)
            assert(support.makePath(file:match("^(.*)/[^/]+$")))
            support.write(file,content); files[file]=true
        end
        local DocSettings = dofile(source)
        package.loaded.docsettings = DocSettings
        local sdrs = {doc=directory.."/paper.sdr",dir=central..directory.."/paper.sdr",hash=hashed.."/aa/"..hash..".sdr"}
        local page_cache = support.directory.."/cache/page.cache"
        local content = 'return {annotations={{text="local annotation"}},bookmarks={1},last_page=3,cache_file_path="'
            .. page_cache .. '"}'
        for _,dir in pairs(sdrs) do
            write(dir.."/metadata."..extension..".lua",content)
            write(dir.."/metadata."..extension..".lua.old",content)
        end
        write(sdrs.doc.."/paper."..extension..".lua",content)
        write(DocSettings:getHistoryPath(path),content)
        write(DocSettings:getHistoryPath(path)..".old",content)
        write(path..".kpdfview.lua",content)
        write(sdrs[location].."/cover.png","cover")
        write(sdrs[location].."/custom_metadata.lua","custom")
        write(page_cache,"page cache")
        local deleted,cleanup_err
        if extension=="pdf" then
            deleted,cleanup_err = LocalFiles.removePDF(API,item.key,path)
        else
            lfs.dir = directory_iterator
            local scan=Cleanup.scanDownloads(API)
            check(#scan.targets==1 and scan.epub==1,"Native EPUB found for batch cleanup")
            local stats=Cleanup.newStats(scan)
            Cleanup.processTarget(scan.targets[1],stats)
            deleted=stats.deleted==1 and stats.failed==0 and stats.pending==0
            cleanup_err=stats.errors[1] and stats.errors[1].message
        end
        check(deleted and not cleanup_err,"Native settings cleanup succeeds in "..location)
        check(not lfs.attributes(path),"Document removed")
        check(hash_calls==1,"Hash storage discovered once before unlink")
        for file in pairs(files) do check(not lfs.attributes(file),"Removed "..file) end
        check(not lfs.attributes(directory.."/.zotero-annotations.json"),"Cloud annotation cache removed")
        check(API.getItems().ATTACH01 and #support.requests==0,"Cloud metadata kept, no HTTP")
        lfs.attributes = attributes
        lfs.dir = directory_iterator
    end,debug.traceback)
    support.teardown()
    if not ok then error(err) end
end
end

-- The first native flush leaves candidates nil even though hash metadata exists.
-- Both individual deletion and batch cleanup must preserve an open ordinary copy.
for _, extension in ipairs({"pdf","epub"}) do
for _, method in ipairs({"single","batch"}) do
for _, first_save in ipairs({false,true}) do
    local API = support.setup()
    local lfs = require("libs/libkoreader-lfs")
    local attributes, directory_iterator = lfs.attributes, lfs.dir
    local ok, err = xpcall(function()
        local item = support.attachment("ATTACH01","paper."..extension,false)
        if extension=="epub" then item.data.contentType="application/epub+zip" end
        support.seed({ATTACH01=item})
        local directory,path = API.getDirAndPath(item.key)
        assert(support.makePath(directory))
        support.write(path,"identical document content")
        local receipt_path = directory.."/.zotero-cache.json"
        local receipt = support.JSON.encode({version=10})
        support.write(receipt_path,receipt)
        support.write(directory.."/.zotero-annotations.json","annotation cache")
        local other = support.directory.."/ordinary."..extension
        support.write(other,"identical document content")
        local storage = require("datastorage")
        storage.getHistoryDir = function() return support.directory.."/history" end
        storage.getDocSettingsDir = function() return support.directory.."/docsettings" end
        storage.getDocSettingsHashDir = function() return support.directory.."/hashdocsettings" end
        assert(support.makePath(storage:getDocSettingsHashDir()))
        local settings = require("luasettings")
        settings.extend = require("ui/widget/container/widgetcontainer").extend
        settings.readSetting = function(self,key) return self.data[key] end
        settings.backup = function() return false end
        local content = "return {last_page=42,bookmarks={7},annotations={{text='ordinary document note'}}}"
        package.loaded.dump = function() return content end
        package.loaded.logger = {dbg=function() end,warn=function() end}
        require("ffi/util").basename = function(file) return file:match("([^/]+)$") end
        local util = require("util")
        util.splitFileNameSuffix = function(file) return file:match("^(.*)%.([^%.]+)$") end
        util.removePath = function(folder) return os.remove(folder) end
        util.makePath = support.makePath
        util.writeToFile = function(value,file) support.write(file,value); return true end
        local hash = string.rep("a",32)
        util.partialMD5 = function(file)
            check(support.read(file)=="identical document content","Hash discovery reads the existing copy")
            return hash
        end
        G_reader_settings = {readSetting=function(_,key,default)
            if key=="document_metadata_folder" then return "hash" end
            return default
        end}
        lfs.attributes = function(file,field)
            local result = attributes(file)
            if result then result.modification=100 end
            return field and result and result[field] or (not field and result or nil)
        end
        lfs.dir = function(folder)
            if lfs.attributes(folder,"mode")~="directory" then return function() end end
            return directory_iterator(folder)
        end
        local metadata = storage:getDocSettingsHashDir().."/aa/"..hash..".sdr/metadata."..extension..".lua"
        if not first_save then
            assert(support.makePath(metadata:match("^(.*)/[^/]+$")))
            support.write(metadata,content)
        end
        local DocSettings = dofile(source)
        package.loaded.docsettings = DocSettings
        local active = DocSettings:open(other)
        if first_save then
            check(active.candidates==nil,"First open has no existing settings candidates")
            active.data.last_page=42
            active.data.bookmarks={7}
            active.data.annotations={{text="ordinary document note"}}
            check(active:flush(nil,true),"Native first settings flush succeeds")
            check(active.candidates==nil and lfs.attributes(metadata),"Native flush keeps candidates nil after creating metadata")
        end
        local reader = require("apps/reader/readerui")
        reader.instance = {document={file=other},doc_settings=active}
        local function remove()
            if method=="single" then return LocalFiles.removeAttachment(API,item.key,path) end
            local scan = Cleanup.scanDownloads(API)
            check(#scan.targets==1,"Batch scan identifies the managed copy")
            local stats = Cleanup.newStats(scan)
            Cleanup.processTarget(scan.targets[1],stats)
            check(stats.failed==0 and stats.pending==0,"Batch guard causes no partial cleanup")
            return stats.deleted==1,stats.errors[1] and stats.errors[1].message,stats.open
        end
        local deleted,message,open = remove()
        check(not deleted and message:find("share its reading data",1,true),"Shared "..extension.." settings block "..method.." deletion")
        if method=="batch" then check(open==1,"Batch counts a shared open document") end
        check(support.read(path)=="identical document content" and support.read(other)=="identical document content","Both copies remain intact")
        check(support.read(metadata)==content,"Saved annotations, bookmarks and progress remain intact")
        check(support.read(receipt_path)==receipt and support.read(directory.."/.zotero-annotations.json")=="annotation cache","Download caches remain intact")
        check(active.data.annotations[1].text=="ordinary document note" and active.data.last_page==42,"Open reader memory remains intact")
        reader.instance = nil
        deleted,message = remove()
        check(deleted and not message,"Closing the open reader permits "..method.." deletion")
        check(not lfs.attributes(path) and not lfs.attributes(metadata),"Managed copy and native settings are cleaned after closing")
        check(support.read(other)=="identical document content" and #support.requests==0,"Ordinary file and cloud data remain intact")
    end,debug.traceback)
    lfs.attributes, lfs.dir = attributes, directory_iterator
    support.teardown()
    if not ok then error(err) end
end
end
end
io.write(string.format("%d native DocSettings removal checks passed\n",checks))
