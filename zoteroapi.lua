local BaseUtil = require("ffi/util")
local LuaSettings = require("luasettings")
local http = require("socket.http")
local URL = require("socket.url")
local socketutil = require("socketutil")
local ltn12 = require("ltn12")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local sha2 = require("ffi/sha2")
local util = require("util")

local API = {}
local API_ROOT = "https://api.zotero.org"
local CACHE_FORMAT = 1
local LIBRARY_CHANGED = "The Zotero library changed during synchronization. Please retry."
local SUPPORTED_MEDIA_TYPES = { ["application/pdf"] = true, ["application/epub+zip"] = true }

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function file_exists(path)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

local function file_slurp(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    return content
end

local function write_atomic(path, content)
    local temporary = path .. ".tmp"
    local f, err = io.open(temporary, "wb")
    if not f then return nil, err end
    local written, write_err = f:write(content)
    local closed, close_err = f:close()
    if not written or not closed then
        os.remove(temporary)
        return nil, write_err or close_err
    end
    local ok, rename_err = os.rename(temporary, path)
    if not ok then os.remove(temporary) end
    return ok, rename_err
end

local function write_json(path, value)
    local ok, content = pcall(JSON.encode, value)
    if not ok then return nil, "Could not encode cache data" end
    return write_atomic(path, content)
end

local function read_json(path)
    local content, err = file_slurp(path)
    if not content then return nil, err end
    local ok, data = pcall(JSON.decode, content)
    if not ok or type(data) ~= "table" then return nil, "Invalid JSON data" end
    return data
end

local function copy_table(source)
    local target = {}
    for key, value in pairs(source) do target[key] = value end
    return target
end

local function contains(values, value)
    if type(values) ~= "table" then return false end
    for _, candidate in pairs(values) do
        if candidate == value then return true end
    end
    return false
end

local function header(headers, name)
    for key, value in pairs(headers or {}) do
        if key:lower() == name then return value end
    end
    return nil
end

local function origin(url)
    local parsed = URL.parse(url)
    if not parsed or (parsed.scheme ~= "https" and parsed.scheme ~= "http") or not parsed.host then
        return nil
    end
    return parsed.scheme .. "://" .. parsed.host:lower() .. ":" ..
        tostring(parsed.port or (parsed.scheme == "https" and 443 or 80))
end

local function account_fingerprint()
    return sha2.sha256(API.getAPIKey() or "")
end

local function empty_state()
    return {
        format = CACHE_FORMAT,
        user_id = trim(API.getUserID()),
        key_fingerprint = account_fingerprint(),
        version = 0,
        items = {},
        collections = {},
    }
end

local function get_state()
    if not API.state then
        local state
        if file_exists(API.cache_path) then
            local err
            state, err = read_json(API.cache_path)
            if not state then error("Could not read Zotero cache: " .. tostring(err)) end
            if state.format ~= CACHE_FORMAT or type(state.items) ~= "table"
                or type(state.collections) ~= "table" or not tonumber(state.version) then
                error("Invalid Zotero cache. Use Maintenance > Resync entire collection.")
            end
        end
        if not state or state.user_id ~= trim(API.getUserID())
            or state.key_fingerprint ~= account_fingerprint() then
            state = empty_state()
        end
        API.state = state
    end
    return API.state
end

local function save_state(state)
    local ok, err = write_json(API.cache_path, state)
    if not ok then return nil, "Could not save Zotero cache: " .. tostring(err) end
    API.state = state
    return true
end

local function update_storage_dir(user_id)
    local storage_dir = BaseUtil.joinPath(API.zotero_dir, "storage")
    user_id = trim(user_id or API.getUserID())
    if user_id:match("^%d+$") then
        storage_dir = BaseUtil.joinPath(storage_dir, user_id)
    end
    local ok, err = util.makePath(storage_dir)
    if ok then API.storage_dir = storage_dir end
    return ok, err
end

function API.init(zotero_dir)
    local ok, err = util.makePath(zotero_dir)
    if not ok then error("Could not create Zotero directory: " .. tostring(err)) end
    API.zotero_dir = zotero_dir
    API.settings = LuaSettings:open(BaseUtil.joinPath(zotero_dir, "meta.lua"))
    API.cache_path = BaseUtil.joinPath(zotero_dir, "library.json")
    API.state = nil
    ok, err = update_storage_dir()
    if not ok then error("Could not create attachment storage: " .. tostring(err)) end
end

function API.getAPIKey() return API.settings:readSetting("api_key") end
function API.getUserID() return API.settings:readSetting("user_id") end

function API.setAPIKey(api_key)
    api_key = trim(api_key)
    if API.getAPIKey() ~= api_key then API.state = nil end
    API.settings:saveSetting("api_key", api_key)
end

function API.setUserID(user_id)
    user_id = trim(user_id)
    if not user_id:match("^%d+$") then return nil, "The User ID must be an integer number." end
    local ok, err = update_storage_dir(user_id)
    if not ok then return nil, "Could not create attachment storage: " .. tostring(err) end
    if trim(API.getUserID()) ~= user_id then API.state = nil end
    API.settings:saveSetting("user_id", user_id)
    return true
end

function API.getWebDAVEnabled() return API.settings:isTrue("webdav_enabled") end
function API.getWebDAVUser() return API.settings:readSetting("webdav_user") end
function API.getWebDAVPassword() return API.settings:readSetting("webdav_password") end
function API.getWebDAVUrl() return API.settings:readSetting("webdav_url") end
function API.toggleWebDAVEnabled()
    API.settings:toggle("webdav_enabled")
    API.saveSettings()
end
function API.setWebDAVUser(user) API.settings:saveSetting("webdav_user", user) end
function API.setWebDAVPassword(password) API.settings:saveSetting("webdav_password", password) end
function API.setWebDAVUrl(url) API.settings:saveSetting("webdav_url", trim(url):gsub("/+$", "")) end
function API.getSettings() return API.settings end
function API.saveSettings() API.settings:flush() end
-- Kept for callers of the old settings-flush helper; this plugin is read-only.
API.saveModifiedItems = API.saveSettings

function API.getLibraryVersion()
    if API.settings:isTrue("force_full_sync") then return 0 end
    return tonumber(get_state().version)
end

function API.getItems() return get_state().items end
function API.getCollections() return get_state().collections end

function API.setItems(items)
    local state = copy_table(get_state())
    state.items = items
    return save_state(state)
end
function API.setCollections(collections)
    local state = copy_table(get_state())
    state.collections = collections
    return save_state(state)
end
function API.setLibraryVersion(version)
    local state = copy_table(get_state())
    state.version = assert(tonumber(version), "Invalid library version")
    return save_state(state)
end

function API.resetSyncState()
    -- Keep the last good snapshot available offline until a full sync succeeds.
    API.settings:saveSetting("force_full_sync", true)
    API.saveSettings()
    -- An explicitly requested resync can also recover an unreadable snapshot.
    local ok = pcall(get_state)
    if not ok then API.state = empty_state() end
end

function API.ensureKeyAndID()
    local user_id, api_key = trim(API.getUserID()), trim(API.getAPIKey())
    if not user_id:match("^%d+$") then return "Error: must set a numeric User ID" end
    if api_key == "" then return "Error: must set API Key" end
    return nil, api_key, user_id
end

function API.getHeaders(api_key)
    return { ["Zotero-API-Key"] = api_key, ["Zotero-API-Version"] = "3" }
end

local function request(req, is_file)
    local previous_block, previous_total = socketutil.block_timeout, socketutil.total_timeout
    local total_timeout = is_file and socketutil.FILE_TOTAL_TIMEOUT or socketutil.LARGE_TOTAL_TIMEOUT
    socketutil:set_timeout(is_file and socketutil.FILE_BLOCK_TIMEOUT or socketutil.LARGE_BLOCK_TIMEOUT, total_timeout)
    if req.sink then
        local sink, started = req.sink, os.time()
        req.sink = function(chunk, err)
            if os.time() - started > total_timeout then return nil, "sink timeout" end
            return sink(chunk, err)
        end
    end
    local ok, result, code, headers = pcall(http.request, req)
    socketutil:set_timeout(previous_block, previous_total)
    if type(headers) ~= "table" then headers = {} end
    if not ok then return nil, "Network request failed: " .. tostring(result), {} end
    return result, code, headers
end

function API.verifyResponse(result, code)
    if result ~= 1 then return "Error: " .. tostring(code or "request failed") end
    if code ~= 200 then return "Error: API responded with status code " .. tostring(code) end
end

local function fetch_json(url, headers)
    local response = {}
    local result, code, response_headers = request{
        method = "GET", url = url, headers = headers, redirect = false,
        sink = ltn12.sink.table(response),
    }
    local err = API.verifyResponse(result, code)
    if err then return nil, err end
    local ok, data = pcall(JSON.decode, table.concat(response))
    if not ok or type(data) ~= "table" then return nil, "Error: failed to parse JSON in response" end
    return data, nil, response_headers
end

local function response_version(headers)
    local version = tonumber(header(headers, "last-modified-version"))
    if not version or version < 0 or version % 1 ~= 0 then
        return nil, "Error: missing or invalid Last-Modified-Version header"
    end
    return version
end

function API.fetchCollectionSize(collection_url, headers)
    local result, code, response_headers = request{method = "HEAD", url = collection_url, headers = headers, redirect = false}
    local err = API.verifyResponse(result, code)
    if err then return nil, err end
    local total = tonumber(header(response_headers, "total-results"))
    if not total or total < 0 then return nil, "Error: could not determine number of items in library" end
    return total
end

-- All pages must belong to the same library version. Callbacks should stage changes.
-- Without a callback, the third return value is the library version.
function API.fetchCollectionPaginated(collection_url, headers, callback, expected_version)
    local total, err = API.fetchCollectionSize(collection_url, headers)
    if err then return nil, err end
    local separator = collection_url:find("?", 1, true) and "&" or "?"
    local items, version = {}, expected_version
    -- Even an empty library needs one GET to obtain its version.
    for start = 0, math.max(total - 1, 0), 100 do
        local page_url = collection_url .. separator .. "limit=100&start=" .. start
        local data, response_headers
        data, err, response_headers = fetch_json(page_url, headers)
        if err then return nil, err end
        local page_version
        page_version, err = response_version(response_headers)
        if err then return nil, err end
        if version and version ~= page_version then return nil, LIBRARY_CHANGED end
        version = page_version
        for index in pairs(data) do
            if type(index) ~= "number" or index < 1 or index % 1 ~= 0 or index > #data then
                return nil, "Error: expected a JSON array in Zotero response"
            end
        end
        for _, item in ipairs(data) do
            if type(item) ~= "table" or type(item.key) ~= "string" or type(item.data) ~= "table" then
                return nil, "Error: invalid object in Zotero response"
            end
            if not callback then items[#items + 1] = item end
        end
        if callback then callback(data) end
    end
    if callback then return version end
    return items, nil, version
end

local function sync_library(api_key, user_id)
    local state = get_state()
    local since = API.getLibraryVersion()
    local headers = API.getHeaders(api_key)
    local prefix = API_ROOT .. "/users/" .. user_id
    local items = since == 0 and {} or copy_table(state.items)
    local collections = since == 0 and {} or copy_table(state.collections)
    local function merge(target)
        return function(entries)
            for _, item in ipairs(entries) do
                if item.data.deleted == true or item.data.deleted == 1 then target[item.key] = nil
                else target[item.key] = item end
            end
        end
    end
    local version, err = API.fetchCollectionPaginated(prefix .. "/items?since=" .. since .. "&includeTrashed=true", headers, merge(items))
    if err then return err end
    if version < since then return "The library version went backwards. Please resync the entire collection." end
    local collection_version
    collection_version, err = API.fetchCollectionPaginated(prefix .. "/collections?since=" .. since .. "&includeTrashed=true", headers, merge(collections), version)
    if err then return err end
    if collection_version ~= version then return LIBRARY_CHANGED end
    local snapshot = empty_state()
    snapshot.items, snapshot.collections, snapshot.version = items, collections, version
    local ok
    ok, err = save_state(snapshot)
    if not ok then return err end
    API.settings:saveSetting("force_full_sync", false)
    API.saveSettings()
    return nil
end

function API.syncAllItems()
    local err, api_key, user_id = API.ensureKeyAndID()
    if err then return err end
    local ok, result = pcall(sync_library, api_key, user_id)
    if not ok then return "Could not synchronize Zotero: " .. tostring(result) end
    return result
end

function API.getWebDAVHeaders()
    return { ["Authorization"] = "Basic " .. sha2.bin_to_base64((API.getWebDAVUser() or "") .. ":" .. (API.getWebDAVPassword() or "")) }
end

function API.checkWebDAV()
    local url = trim(API.getWebDAVUrl())
    if not origin(url) then return "A valid HTTP or HTTPS WebDAV URL is required" end
    local headers = API.getWebDAVHeaders()
    local result, code = request{url = url, method = "PROPFIND", headers = headers, redirect = false, sink = ltn12.sink.table({})}
    if result ~= 1 then return "Connection failed: " .. tostring(code) end
    if code == 200 or code == 207 then return nil end
    if code == 401 or code == 403 then return "Access forbidden. Check username and password." end
    return "WebDAV responded with status code " .. tostring(code)
end

function API.getDirAndPath(attachment_key)
    local attachment = API.getItems()[attachment_key]
    if not attachment or type(attachment.data) ~= "table" then return nil, nil, "Attachment not found" end
    local filename = attachment.data.filename
    if type(attachment_key) ~= "string" or not attachment_key:match("^[A-Z0-9]+$")
        or type(filename) ~= "string" or filename == "" or filename == "." or filename == ".."
        or filename:find("[/\\%z]") or filename:match("^%.zotero%-") then
        return nil, nil, "Invalid attachment key or filename"
    end
    local directory = BaseUtil.joinPath(API.storage_dir, attachment_key)
    return directory, BaseUtil.joinPath(directory, filename)
end

local function without_credentials(headers)
    local sanitized = {}
    for name, value in pairs(headers) do
        local lower = name:lower()
        if lower ~= "zotero-api-key" and lower ~= "authorization" and lower ~= "cookie" then sanitized[name] = value end
    end
    return sanitized
end

-- Explicit redirects prevent API keys and WebDAV passwords reaching a storage host.
local function download_file(url, headers, path)
    for redirect = 0, 5 do
        if not origin(url) then return nil, "Invalid download URL" end
        local f, err = io.open(path, "wb")
        if not f then return nil, "Could not create download file: " .. tostring(err) end
        local result, code, response_headers = request({
            url = url, headers = headers, redirect = false,
            sink = function(chunk)
                if chunk then return f:write(chunk) end
                return 1
            end,
        }, true)
        local closed, close_err = f:close()
        if not closed then os.remove(path); return nil, "Could not save download: " .. tostring(close_err) end
        if result == 1 and (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) then
            os.remove(path)
            local location = header(response_headers, "location")
            if not location then return nil, "Missing download redirect location" end
            local next_url = URL.absolute(url, location)
            if url:match("^https:") and not next_url:match("^https:") then return nil, "Refusing an HTTPS download redirect to HTTP" end
            if origin(next_url) ~= origin(url) then headers = without_credentials(headers) end
            url = next_url
        else
            err = API.verifyResponse(result, code)
            if err then os.remove(path); return nil, err end
            return true, nil, response_headers
        end
    end
    os.remove(path)
    return nil, "Too many download redirects"
end

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function command_succeeded(result)
    return result == true or result == 0 -- Lua 5.2+ and LuaJIT/Lua 5.1, respectively
end

local function extract_archive(zip_path, filename, target_path)
    local temporary = target_path .. ".part"
    local names = { filename }
    local extracted = false
    for _, name in ipairs(names) do
        local pattern = name:gsub("([%[%]%*%?\\])", "\\%1")
        local command = "unzip -p " .. shell_quote(zip_path) .. " " .. shell_quote(pattern) .. " > " .. shell_quote(temporary)
        local ran, result = pcall(os.execute, command)
        if ran and command_succeeded(result) and file_exists(temporary) then extracted = true; break end
    end
    if not extracted then os.remove(temporary); return nil, "Could not extract the attachment from its WebDAV archive" end
    local renamed, rename_err = os.rename(temporary, target_path)
    if not renamed then os.remove(temporary); return nil, "Could not save extracted attachment: " .. tostring(rename_err) end
    return target_path
end

function API.downloadWebDAV(key, target_dir, target_path)
    local url = trim(API.getWebDAVUrl()):gsub("/+$", "")
    if not origin(url) then return nil, "A valid HTTP or HTTPS WebDAV URL is required" end
    local zip_path = target_dir .. "/.zotero-download.zip"
    local ok, err = download_file(url .. "/" .. key .. ".zip", API.getWebDAVHeaders(), zip_path)
    if not ok then return nil, err end
    local path
    path, err = extract_archive(zip_path, API.getItems()[key].data.filename, target_path)
    os.remove(zip_path)
    return path, err
end

local function attachment_md5(attachment)
    local digest = attachment.data.md5
    if type(digest) == "string" and #digest == 32 and digest:match("^%x+$") then return digest:lower() end
end

local function file_md5(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local update = sha2.md5()
    while true do
        local chunk = f:read(65536)
        if not chunk then break end
        update(chunk)
    end
    f:close()
    return update()
end

local function download_attachment(key, download_callback)
    local err, api_key, user_id = API.ensureKeyAndID()
    if err then return nil, err end
    local attachment = API.getItems()[key]
    if not attachment or not attachment.data then return nil, "The attachment was not found in the library" end
    if attachment.data.itemType ~= "attachment" then return nil, "This item is not an attachment" end
    local mode = attachment.data.linkMode
    if mode ~= "imported_file" then
        return nil, "Unsupported attachment link mode: " .. tostring(mode) .. ". Linked files and linked URLs are not stored by Zotero."
    end
    if not SUPPORTED_MEDIA_TYPES[attachment.data.contentType] then return nil, "Only PDF and EPUB attachments are supported" end
    local target_dir, target_path, path_err = API.getDirAndPath(key)
    if not target_path then return nil, path_err end
    local ok
    ok, err = util.makePath(target_dir)
    if not ok then return nil, "Could not create attachment directory: " .. tostring(err) end
    local metadata_path = target_dir .. "/.zotero-cache.json"
    local metadata = read_json(metadata_path)
    local md5 = attachment_md5(attachment)
    local cached_attributes = lfs.attributes(target_path)
    local version = tonumber(attachment.version)
    if metadata and cached_attributes and cached_attributes.mode == "file" and cached_attributes.size > 0
        and ((md5 and metadata.md5 == md5) or (not md5 and version and tonumber(metadata.version) == version)) then
        return target_path
    end
    if download_callback then download_callback() end
    local temporary = target_dir .. "/.zotero-download.part"
    local response_headers
    if API.getWebDAVEnabled() then
        local path
        path, err = API.downloadWebDAV(key, target_dir, temporary)
        ok = path ~= nil
    else
        ok, err, response_headers = download_file(API_ROOT .. "/users/" .. user_id .. "/items/" .. key .. "/file", API.getHeaders(api_key), temporary)
    end
    if not ok then os.remove(temporary); return nil, err end
    if md5 and file_md5(temporary) ~= md5 then
        os.remove(temporary)
        return nil, "The downloaded file does not match Zotero's attachment metadata. Synchronize the library and retry."
    end
    local attributes = lfs.attributes(temporary)
    if not attributes or attributes.size == 0 then os.remove(temporary); return nil, "The downloaded attachment is empty" end
    ok, err = os.rename(temporary, target_path)
    if not ok then os.remove(temporary); return nil, "Could not save attachment: " .. tostring(err) end
    ok, err = write_json(metadata_path, { version = attachment.version, md5 = md5 })
    if not ok then return nil, "Could not save attachment metadata: " .. tostring(err) end
    return target_path
end

function API.downloadAndGetPath(key, download_callback)
    local ok, path, err = pcall(download_attachment, key, download_callback)
    if not ok then return nil, "Could not download attachment: " .. tostring(path) end
    return path, err
end

local function parent_item(items, item)
    if type(item.data.parentItem) == "string" and item.data.parentItem ~= "" then
        return items[item.data.parentItem], true
    end
    return nil, false
end

local function item_label(item)
    local author = item.meta and item.meta.creatorSummary or "Unknown"
    return author .. " - " .. (item.data.title or "Untitled")
end

local function visible_attachment(items, item)
    if not item.data or item.data.itemType ~= "attachment" or not SUPPORTED_MEDIA_TYPES[item.data.contentType]
        or item.data.deleted == true or item.data.deleted == 1 then return false end
    local parent, has_parent = parent_item(items, item)
    if has_parent and (not parent or parent.data.deleted == true or parent.data.deleted == 1) then return false end
    return true
end

function API.displayCollection(key)
    local results = {}
    for collection_key, collection in pairs(API.getCollections()) do
        local parent = collection.data.parentCollection
        if (key == nil and not parent) or parent == key then
            results[#results + 1] = { key = collection_key, text = collection.data.name .. "/", collection = true }
        end
    end
    local function by_text(a, b) return a.text < b.text end
    table.sort(results, by_text)
    local attachments, items = {}, API.getItems()
    for item_key, item in pairs(items) do
        if visible_attachment(items, item) then
            local parent = parent_item(items, item)
            local source = parent or item
            if contains(source.data.collections, key) then
                attachments[#attachments + 1] = { key = item_key, text = parent and item_label(parent) or (item.data.title or item.data.filename) }
            end
        end
    end
    table.sort(attachments, by_text)
    for _, item in ipairs(attachments) do results[#results + 1] = item end
    return results
end

function API.displaySearchResults(query)
    local words = {}
    for word in trim(query):lower():gmatch("%S+") do words[#words + 1] = word end
    local results, items = {}, API.getItems()
    for key, item in pairs(items) do
        if visible_attachment(items, item) then
            local parent = parent_item(items, item)
            local label = parent and item_label(parent) or (item.data.title or item.data.filename)
            if parent and type(parent.data.DOI) == "string" and parent.data.DOI ~= "" then label = label .. " - " .. parent.data.DOI end
            local start, matched = 1, true
            for _, word in ipairs(words) do
                local first, last = label:lower():find(word, start, true)
                if not first then matched = false; break end
                start = last + 1
            end
            if matched then results[#results + 1] = { key = key, text = label } end
        end
    end
    table.sort(results, function(a, b) return a.text < b.text end)
    return results
end

return API
