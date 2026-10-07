-- Offline test doubles for KOReader and HTTP. Disk writes and unzip are real.
local Support = { requests = {}, settings_data = {}, logs = {}, digests = {} }
local original_execute = os.execute
local original_print = print
local original_rename = os.rename
local original_open = io.open
local original_time = os.time
local json_values, json_counter = {}, 0

local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end

function Support.quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
function Support.execute(command)
    local status = original_execute(command)
    return status == true or status == 0
end
function Support.makePath(path)
    if Support.execute("mkdir -p " .. Support.quote(path)) then return true end
    return nil, "mkdir failed"
end
function Support.read(path)
    local file = assert(original_open(path, "rb"))
    local value = file:read("*a")
    file:close()
    return value
end
function Support.write(path, value)
    local file = assert(original_open(path, "wb"))
    assert(file:write(value))
    assert(file:close())
end

Support.JSON = {
    encode = function(value)
        json_counter = json_counter + 1
        local token = '"test-json-' .. json_counter .. '"'
        json_values[token] = clone(value)
        return token
    end,
    decode = function(content)
        if content == "[]" or content == "{}" then return {} end
        assert(json_values[content], "invalid test JSON")
        return clone(json_values[content])
    end,
}

local settings = {
    readSetting = function(_, key, default)
        local value = Support.settings_data[key]
        if value == nil then return default end
        return value
    end,
    saveSetting = function(_, key, value) Support.settings_data[key] = value end,
    isTrue = function(_, key) return Support.settings_data[key] == true end,
    toggle = function(_, key) Support.settings_data[key] = not Support.settings_data[key] end,
    flush = function() end,
}

Support.http = {request = function(req)
    Support.requests[#Support.requests + 1] = req
    return Support.response(req, #Support.requests)
end}
function Support.respond(req, value, version, headers, code)
    local body = type(value) == "table" and Support.JSON.encode(value) or value
    if body and req.sink then assert(req.sink(body)); assert(req.sink(nil)) end
    headers = headers or {}
    if version then headers["last-modified-version"] = tostring(version) end
    return 1, code or 200, headers
end
function Support.key(req)
    return Support.respond(req, {userID = tonumber(Support.settings_data.user_id), access = {user = {library = true, files = true}}})
end

local lfs = {}
function lfs.attributes(path, field)
    if not path then return nil end
    local attributes
    if Support.execute("test -d " .. Support.quote(path)) then attributes = {mode = "directory"}
    else
        local f = original_open(path, "rb")
        if not f then return nil end
        attributes = {mode = "file", size = f:seek("end")}
        f:close()
    end
    if field then return attributes[field] end
    return attributes
end
function lfs.mkdir(path) return Support.makePath(path) end
function lfs.touch(path, access, modification) Support.last_touch = {path, access, modification}; return true end

local function base64(input)
    local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    local output = {}
    for pos = 1, #input, 3 do
        local a,b,c = input:byte(pos, pos+2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        output[#output+1] = alphabet:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
            .. alphabet:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
            .. (b and alphabet:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or '=')
            .. (c and alphabet:sub(n % 64 + 1, n % 64 + 1) or '=')
    end
    return table.concat(output)
end
local sha2 = {
    sha256 = function(value) return "test-fingerprint:" .. value end,
    bin_to_base64 = base64,
    md5 = function(value)
        local chunks = {}
        local function update(chunk)
            if chunk then chunks[#chunks+1] = chunk; return update end
            return Support.digests[table.concat(chunks)] or string.rep("0",32)
        end
        if value then return update(value)() end
        return update
    end,
}

local socketutil = {
    block_timeout=60, total_timeout=-1, FILE_BLOCK_TIMEOUT=15, FILE_TOTAL_TIMEOUT=60,
    LARGE_BLOCK_TIMEOUT=10, LARGE_TOTAL_TIMEOUT=30,
    set_timeout=function(self, block, total) self.block_timeout, self.total_timeout=block,total end,
}
local URL = {}
function URL.parse(value)
    local scheme, authority = value:match("^(https?)://([^/]+)")
    if not scheme then return nil end
    local host, port = authority:match("^([^:]+):(%d+)$")
    return {scheme=scheme, host=host or authority, port=port}
end
function URL.absolute(base, relative)
    if relative:match("^%a+:") then return relative end
    local prefix = assert(base:match("^(https?://[^/]+)"))
    if relative:sub(1,2) == "//" then return base:match("^(https?):") .. ":" .. relative end
    if relative:sub(1,1) == "/" then return prefix .. relative end
    return (base:match("^(.*)/") or prefix) .. "/" .. relative
end

local Widget = {}
function Widget:extend(value) return setmetatable(value or {}, {__index=self}) end
function Widget:new(value)
    value = self:extend(value)
    if value.init then value:init() end
    return value
end
function Widget:onClose() end
function Widget:onShowKeyboard() end
function Widget:getInputText() return self.input end
function Widget:getFields() return self.test_fields end
function Widget:switchItemTable(_, items) self.last_items=items end
function Widget:init() end
local UI = {
    shown={}, closed={}, scheduled={},
    show=function(self, widget) self.shown[#self.shown+1] = widget end,
    close=function(self, widget) self.closed[#self.closed+1] = widget end,
    scheduleIn=function(self, _, callback) self.scheduled[#self.scheduled+1] = callback end,
}
Support.UI=UI
local modules = {
    ["ffi/util"]={joinPath=function(a,b) return a.."/"..b end, usleep=function() end},
    ["luasettings"]={open=function() return settings end},
    ["socket.http"]=Support.http, ["socket.url"]=URL, ["socketutil"]=socketutil,
    ["json"]=Support.JSON, ["libs/libkoreader-lfs"]=lfs, ["ffi/sha2"]=sha2,
    ["util"]={makePath=function(path) return Support.makePath(path) end},
    ["ltn12"]={
        sink={table=function(values) return function(chunk) if chunk then values[#values+1]=chunk end;return 1 end end},
        source={string=function(value) return function() local chunk=value;value=nil;return chunk end end},
    },
    ["ffi/blitbuffer"]={COLOR_WHITE=0}, ["dispatcher"]={registerAction=function() end},
    ["ui/widget/infomessage"]=Widget, ["ui/widget/inputdialog"]=Widget, ["ui/uimanager"]=UI,
    ["ui/widget/container/widgetcontainer"]=Widget, ["ui/widget/spinwidget"]=Widget,
    ["datastorage"]={getDataDir=function() return Support.directory end},
    ["ui/widget/container/framecontainer"]=Widget, ["device"]={screen={getWidth=function() return 600 end,getHeight=function() return 800 end}},
    ["ui/font"]={getFace=function() return {} end}, ["ui/widget/menu"]=Widget,
    ["ui/geometry"]=Widget, ["gettext"]=function(value) return value end,
    ["ui/widget/multiinputdialog"]=Widget,
    ["apps/reader/readerui"]={showReader=function(_, path) Support.opened_path=path end},
}
for name, module in pairs(modules) do
    local value = module
    package.preload[name]=function() return value end
end

function Support.setup()
    Support.requests, Support.logs, Support.settings_data = {}, {}, {api_key="FAKE-KEY",user_id="123"}
    Support.opened_path, Support.last_touch = nil,nil
    Support.response=function(req) error("Unexpected HTTP request: " .. req.url) end
    UI.shown, UI.closed, UI.scheduled = {}, {}, {}
    local temporary_root=os.getenv("TMPDIR") or "/tmp"
    Support.directory=temporary_root.."/zotero-tests-"..tostring(original_time()).."-"..tostring({}):gsub("[^%w]","")
    assert(Support.makePath(Support.directory))
    package.loaded.zoteroapi=nil
    local api=require("zoteroapi")
    api.init(Support.directory)
    Support.API=api
    print=function(...)
        local values={}
        for i=1,select("#",...) do values[i]=tostring(select(i,...)) end
        Support.logs[#Support.logs+1]=table.concat(values," ")
    end
    return api
end
function Support.teardown()
    os.execute, os.rename, io.open, print = original_execute,original_rename,original_open,original_print
    os.time=original_time
    if Support.directory then
        assert(Support.execute("rm -rf " .. Support.quote(Support.directory)))
    end
end
function Support.seed(items, collections, version)
    assert(Support.API.setItems(items or {}))
    assert(Support.API.setCollections(collections or {}))
    assert(Support.API.setLibraryVersion(version or 10))
end
function Support.attachment(key, filename, parent, version, mode)
    return {key=key,version=version or 10,data={itemType="attachment",title=filename,contentType="application/pdf",
        linkMode=mode or "imported_file",filename=filename,parentItem=parent,collections={}}}
end
function Support.plugin()
    local plugin=dofile("main.lua")
    plugin.ui={menu={registerToMainMenu=function() end},onRefresh=function() end}
    plugin:init()
    assert(plugin.initialized)
    return plugin
end
return Support
