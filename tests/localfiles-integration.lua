-- Run the actual KOReader v2026.03 DocSettings open/purge code on real files.
-- Hash calculation, directory enumeration and UI/history are test doubles.
-- Usage: pandoc lua tests/localfiles-integration.lua /path/to/frontend/docsettings.lua
package.path = "./?.lua;./tests/?.lua;" .. package.path
local source = assert(arg[1], "Supply KOReader v2026.03 frontend/docsettings.lua")
local support = require("tests/support")
local LocalFiles = require("localfiles")
local checks = 0
local function check(value, label)
    assert(value, label)
    checks = checks + 1
end

for _, location in ipairs({"doc","dir","hash"}) do
    local API = support.setup()
    local ok, err = xpcall(function()
        local item = support.attachment("ATTACH01","paper.pdf",false)
        support.seed({ATTACH01=item})
        local directory,path = API.getDirAndPath(item.key)
        assert(support.makePath(directory))
        support.write(path,"PDF stand-in")
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
            check(support.read(file)=="PDF stand-in","Hash sidecar located before PDF removal")
            hash_calls = hash_calls+1
            return hash
        end
        G_reader_settings = {readSetting=function(_,key,default)
            if key=="document_metadata_folder" then return location end
            return default
        end}
        local lfs = require("libs/libkoreader-lfs")
        local attributes = lfs.attributes
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
        local page_cache = support.directory.."/page.cache"
        local content = 'return {annotations={{text="local annotation"}},bookmarks={1},last_page=3,cache_file_path="'
            .. page_cache .. '"}'
        for _,dir in pairs(sdrs) do
            write(dir.."/metadata.pdf.lua",content)
            write(dir.."/metadata.pdf.lua.old",content)
        end
        write(sdrs.doc.."/paper.pdf.lua",content)
        write(DocSettings:getHistoryPath(path),content)
        write(DocSettings:getHistoryPath(path)..".old",content)
        write(path..".kpdfview.lua",content)
        write(sdrs[location].."/cover.png","cover")
        write(sdrs[location].."/custom_metadata.lua","custom")
        write(page_cache,"page cache")
        local deleted,cleanup_err = LocalFiles.removePDF(API,item.key,path)
        check(deleted and not cleanup_err,"Native settings cleanup succeeds in "..location)
        check(not lfs.attributes(path),"PDF removed")
        check(hash_calls==1,"Hash storage discovered once before unlink")
        for file in pairs(files) do check(not lfs.attributes(file),"Removed "..file) end
        check(not lfs.attributes(directory.."/.zotero-annotations.json"),"Cloud annotation cache removed")
        check(API.getItems().ATTACH01 and #support.requests==0,"Cloud metadata kept, no HTTP")
        lfs.attributes = attributes
    end,debug.traceback)
    support.teardown()
    if not ok then error(err) end
end
io.write(string.format("%d native DocSettings removal checks passed\n",checks))
