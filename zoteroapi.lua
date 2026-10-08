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
local LibraryCache = require("librarycache")

local API = {}
local API_ROOT = "https://api.zotero.org"
local CACHE_FORMAT = 1
local MAX_SYNC_ATTEMPTS = 3
local MAX_DOWNLOAD_RESUMES = 3
local MAX_METADATA_ATTEMPTS = 3
local LIBRARY_CHANGED = "The Zotero library changed during synchronization. Please retry."
local NOT_MODIFIED = "not_modified"
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

-- Browsing/downloading needs only a small part of Zotero's full records. Keeping
-- note HTML, annotation text and API links inflates large libraries on Kindle.
local ITEM_FIELDS = { itemType=true, title=true, parentItem=true, collections=true,
    deleted=true, contentType=true, linkMode=true, filename=true, md5=true, mtime=true, DOI=true }
local OBJECT_FIELDS = { key=true, version=true, data=true, meta=true }
local COLLECTION_FIELDS = { name=true, parentCollection=true }
local function compact_object(item, fields)
    for key in pairs(item) do if not OBJECT_FIELDS[key] then item[key] = nil end end
    if type(item.data) == "table" then
        for key in pairs(item.data) do if not fields[key] then item.data[key] = nil end end
    end
    if type(item.meta) == "table" then
        for key in pairs(item.meta) do if key ~= "creatorSummary" then item.meta[key] = nil end end
        if next(item.meta) == nil then item.meta = nil end
    end
    return item
end
local function compact_state(state)
    for _, item in pairs(state.items) do compact_object(item, ITEM_FIELDS) end
    for _, collection in pairs(state.collections) do compact_object(collection, COLLECTION_FIELDS) end
    state.compact = true
    return state
end

-- Progress is local to an operation; callbacks receive independent snapshots.
local function report_progress(callback, stage, details)
    if not callback then return end
    local event = copy_table(details or {})
    event.stage = stage
    -- An observer must not interrupt a transfer or leave an open file behind.
    pcall(callback, event)
end

local function transfer_progress(callback, stage, details)
    if not callback then return nil end
    return function(bytes)
        local event = copy_table(details or {})
        event.bytes = bytes
        report_progress(callback, stage, event)
    end
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
        compact = true,
    }
end

local function get_state()
    if not API.state then
        local state
        if file_exists(API.cache_path) then
            local err
            if (lfs.attributes(API.cache_path, "size") or 0) > 2 * 1024 * 1024 then
                state, err = LibraryCache.read(API.cache_path, JSON,
                    function(item) return compact_object(item, ITEM_FIELDS) end,
                    function(collection) return compact_object(collection, COLLECTION_FIELDS) end)
            else state, err = read_json(API.cache_path) end
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
        if not state.compact then
            compact_state(state)
            -- Release large discarded notes and the input JSON before encoding.
            collectgarbage("collect")
            local ok, err = write_json(API.cache_path, state)
            if not ok then print("Zotero: could not compact the local cache: " .. tostring(err)) end
        end
        API.state = state
    end
    return API.state
end

local function save_state(state)
    compact_state(state)
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

function API.init(zotero_dir, reuse_state)
    local ok, err = util.makePath(zotero_dir)
    if not ok then error("Could not create Zotero directory: " .. tostring(err)) end
    local previous_path, previous_state = API.cache_path, API.state
    API.zotero_dir = zotero_dir
    API.settings = LuaSettings:open(BaseUtil.joinPath(zotero_dir, "meta.lua"))
    API.cache_path = BaseUtil.joinPath(zotero_dir, "library.json")
    reuse_state = reuse_state and previous_path == API.cache_path and previous_state
        and previous_state.user_id == trim(API.getUserID())
        and previous_state.key_fingerprint == account_fingerprint()
    API.state = reuse_state and previous_state or nil
    if not reuse_state then
        API.backoff_until = 0
        API.backoff_attempts = 0
        API.sync_in_progress = false
    end
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
function API.isLibraryLoaded() return API.state ~= nil end

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

local function backoff_error()
    local remaining = (API.backoff_until or 0) - os.time()
    if remaining > 0 then
        return ("Zotero requested a delay. Please retry in %d seconds."):format(remaining)
    end
end

local function request(req, is_file, progress_callback)
    local is_api = origin(req.url) == origin(API_ROOT)
    if is_api and not API.sync_in_progress then
        local err = backoff_error()
        if err then return nil, err, {} end
    end
    if progress_callback then progress_callback(0) end
    local previous_block, previous_total = socketutil.block_timeout, socketutil.total_timeout
    -- A page containing large Zotero notes can also take longer than 30 seconds.
    -- Bound waits for data, rather than killing a response that is still arriving.
    local total_timeout = -1
    local received = 0
    socketutil:set_timeout(is_file and socketutil.FILE_BLOCK_TIMEOUT or socketutil.LARGE_BLOCK_TIMEOUT, total_timeout)
    if req.sink then
        local sink = req.sink
        req.sink = function(chunk, err)
            local accepted, sink_err = sink(chunk, err)
            if accepted and chunk and #chunk > 0 then
                received = received + #chunk
                if progress_callback then progress_callback(received) end
            end
            return accepted, sink_err
        end
    end
    local ok, result, code, headers = pcall(http.request, req)
    socketutil:set_timeout(previous_block, previous_total)
    if type(headers) ~= "table" then headers = {} end
    if not ok then return nil, "Network request failed: " .. tostring(result), {} end
    if is_file and result ~= 1 and (code == "timeout" or code == "wantread") then
        code = ("File download timed out while waiting for data (received %d bytes; %s)"):format(received, code)
    end
    if is_api then
        local delay = tonumber(header(headers, "backoff")) or 0
        if code == 429 or code == 503 then
            local retry_after = tonumber(header(headers, "retry-after"))
            if code == 429 then
                API.backoff_attempts = (API.backoff_attempts or 0) + 1
                retry_after = retry_after or math.min(60 * 2 ^ (API.backoff_attempts - 1), 3600)
            end
            delay = math.max(delay, retry_after or 0)
        elseif code == 200 then
            API.backoff_attempts = 0
        end
        if delay > 0 then API.backoff_until = math.max(API.backoff_until or 0, os.time() + math.ceil(delay)) end
    end
    return result, code, headers
end

function API.verifyResponse(result, code)
    if result ~= 1 then return "Error: " .. tostring(code or "request failed") end
    if code == 429 then return backoff_error() or "Zotero rate limit reached. Please retry later." end
    if code ~= 200 then return "Error: API responded with status code " .. tostring(code) end
end

local function fetch_json(url, headers, allow_not_modified, progress_callback, retry_callback)
    for attempt = 1, MAX_METADATA_ATTEMPTS do
        local response, received = {}, 0
        local result, code, response_headers = request({
            method = "GET", url = url, headers = headers, redirect = false,
            sink = function(chunk)
                if chunk then response[#response + 1] = chunk; received = received + #chunk end
                return 1
            end,
        }, false, progress_callback)
        if result == 1 and code == 304 and allow_not_modified then return nil, NOT_MODIFIED, response_headers end
        local err = API.verifyResponse(result, code)
        local retryable = result ~= 1 and (code == "timeout" or code == "closed" or code == "wantread" or code == "sink timeout")
            or result == 1 and (code == 502 or code == 504)
        local length = tonumber(header(response_headers, "content-length"))
        if not err and length and not header(response_headers, "transfer-encoding") and received ~= length then
            err = ("Error: incomplete metadata response (received %d of %d bytes)"):format(received, length)
            retryable = true
        end
        if not err then
            local ok, data = pcall(JSON.decode, table.concat(response))
            if not ok or type(data) ~= "table" then return nil, "Error: failed to parse JSON in response" end
            return data, nil, response_headers
        end
        if not retryable or attempt == MAX_METADATA_ATTEMPTS then return nil, err end
        response = nil
        if retry_callback then retry_callback(attempt + 1) end
        BaseUtil.usleep(250000 * 2 ^ (attempt - 1))
    end
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
-- Progress includes stage, completed objects, optional total, page and current response bytes.
function API.fetchCollectionPaginated(collection_url, headers, callback, expected_version, progress_callback, stage)
    local separator = collection_url:find("?", 1, true) and "&" or "?"
    local page_url = collection_url .. separator .. "limit=100"
    local items, visited, version = {}, {}, expected_version
    local completed, total, page = 0, nil, 0
    stage = stage or "items"
    local function failure(err)
        return nil, ("Fetching %s (page %d): %s"):format(stage, page, err)
    end
    while page_url do
        if origin(page_url) ~= origin(API_ROOT) or visited[page_url] then
            return nil, "Error: invalid pagination link"
        end
        visited[page_url] = true
        page = page + 1
        local conditional = header(headers, "if-modified-since-version") ~= nil and not version
        local data, err, response_headers = fetch_json(page_url, headers, conditional,
            transfer_progress(progress_callback, stage, { completed = completed, total = total, page = page }),
            function(attempt) report_progress(progress_callback, "retrying_request", {
                page = page, attempt = attempt, completed = completed, total = total }) end)
        if err then
            if err == NOT_MODIFIED then return nil, err end
            return failure(err)
        end
        local page_version
        page_version, err = response_version(response_headers)
        if err then return failure(err) end
        if version and version ~= page_version then return nil, LIBRARY_CHANGED end
        version = page_version
        for index in pairs(data) do
            if type(index) ~= "number" or index < 1 or index % 1 ~= 0 or index > #data then
                return failure("Error: expected a JSON array in Zotero response")
            end
        end
        for _, item in ipairs(data) do
            if type(item) ~= "table" or type(item.key) ~= "string" or type(item.data) ~= "table" then
                return failure("Error: invalid object in Zotero response")
            end
            if not callback then items[#items + 1] = item end
        end
        if callback then callback(data) end
        completed = completed + #data
        local reported_total = tonumber(header(response_headers, "total-results"))
        total = reported_total or total
        if total and (total < completed or total % 1 ~= 0) then total = nil end
        report_progress(progress_callback, stage, { completed = completed, total = total, page = page })
        page_url = nil
        for link, relation in (header(response_headers, "link") or ""):gmatch('<([^>]+)>;%s*rel="([^"]+)"') do
            if relation == "next" then page_url = URL.absolute(collection_url, link) end
        end
    end
    if callback then return version end
    return items, nil, version
end

local function verify_key(api_key, user_id, progress_callback)
    local key, err = fetch_json(API_ROOT .. "/keys/current", API.getHeaders(api_key), false,
        transfer_progress(progress_callback, "checking_account"))
    if err then return err end
    if tostring(key.userID) ~= user_id then return "Error: the API key does not belong to this User ID" end
    if type(key.access) ~= "table" or type(key.access.user) ~= "table" or not key.access.user.library then
        return "Error: the API key does not permit reading your library"
    end
end

local function sync_library(api_key, user_id, progress_callback)
    local state = get_state()
    local since = API.getLibraryVersion()
    local headers = API.getHeaders(api_key)
    local item_headers = copy_table(headers)
    if since > 0 then item_headers["If-Modified-Since-Version"] = tostring(since) end
    local prefix = API_ROOT .. "/users/" .. user_id
    for attempt = 1, MAX_SYNC_ATTEMPTS do
        local items = since == 0 and {} or copy_table(state.items)
        local collections = since == 0 and {} or copy_table(state.collections)
        local function merge(target)
            return function(entries)
                for _, item in ipairs(entries) do
                    if item.data.deleted == true or item.data.deleted == 1 then target[item.key] = nil
                    else target[item.key] = compact_object(item, target == collections and COLLECTION_FIELDS or ITEM_FIELDS) end
                end
            end
        end
        local version, err = API.fetchCollectionPaginated(prefix .. "/items?since=" .. since .. "&includeTrashed=1",
            item_headers, merge(items), nil, progress_callback, "items")
        if err == NOT_MODIFIED and since > 0 then
            report_progress(progress_callback, "up_to_date")
            return nil
        end
        if not err and version < since then return "The library version went backwards. Please resync the entire collection." end
        if not err then
            local collection_version
            collection_version, err = API.fetchCollectionPaginated(prefix .. "/collections?since=" .. since,
                headers, merge(collections), version, progress_callback, "collections")
            if not err and collection_version ~= version then err = LIBRARY_CHANGED end
        end
        -- A full refresh starts empty; there are no old objects whose deletion log is needed.
        if not err and since ~= 0 then
            local deleted, deleted_headers
            deleted, err, deleted_headers = fetch_json(prefix .. "/deleted?since=" .. since, headers, false,
                transfer_progress(progress_callback, "deletions"))
            if err then err = "Fetching deletions: " .. err end
            if not err then
                local deleted_version
                deleted_version, err = response_version(deleted_headers)
                if not err and deleted_version ~= version then err = LIBRARY_CHANGED end
                if not err then
                    if type(deleted.items) ~= "table" or type(deleted.collections) ~= "table" then
                        err = "Error: invalid deletion log in Zotero response"
                    else
                        for _, key in ipairs(deleted.items) do items[key] = nil end
                        for _, key in ipairs(deleted.collections) do collections[key] = nil end
                    end
                end
            end
        end
        if not err then
            report_progress(progress_callback, "saving_library")
            local snapshot = empty_state()
            snapshot.items, snapshot.collections, snapshot.version = items, collections, version
            local ok
            ok, err = save_state(snapshot)
            if not ok then return err end
            API.settings:saveSetting("force_full_sync", false)
            API.saveSettings()
            report_progress(progress_callback, "complete")
            return nil
        end
        if err ~= LIBRARY_CHANGED or attempt == MAX_SYNC_ATTEMPTS then return err end
        -- Honor an overload response instead of immediately restarting a busy server.
        local delay_error = backoff_error()
        if delay_error then return delay_error end
        report_progress(progress_callback, "retrying", { attempt = attempt + 1 })
        BaseUtil.usleep(100000 * 2 ^ (attempt - 1))
    end
end

-- The optional observer reports transfer, stage, retry and publication progress.
function API.syncAllItems(progress_callback)
    local err, api_key, user_id = API.ensureKeyAndID()
    if err then return err end
    err = backoff_error()
    if err then return err end
    local ok, result = pcall(verify_key, api_key, user_id, progress_callback)
    if ok then err = result else err = tostring(result) end
    if err then return "Checking Zotero account: " .. err end
    API.sync_in_progress = true
    ok, result = pcall(sync_library, api_key, user_id, progress_callback)
    API.sync_in_progress = false
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
    headers.Depth = "0"
    local body = '<?xml version="1.0"?><propfind xmlns="DAV:"><prop><getcontentlength/></prop></propfind>'
    headers["Content-Type"] = "application/xml; charset=utf-8"
    headers["Content-Length"] = tostring(#body)
    local result, code = request{url = url, method = "PROPFIND", headers = headers, redirect = false,
        source = ltn12.source.string(body), sink = ltn12.sink.table({})}
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
local function append_file(source_path, target_path)
    local source, err = io.open(source_path, "rb")
    if not source then return nil, err end
    local target
    target, err = io.open(target_path, "ab")
    if not target then source:close(); return nil, err end
    local ok = true
    while true do
        local chunk, read_err = source:read(65536)
        if not chunk then
            if read_err then ok, err = nil, read_err end
            break
        end
        ok, err = target:write(chunk)
        if not ok then break end
    end
    source:close()
    local closed, close_err = target:close()
    return ok and closed, err or close_err
end

local function download_file(url, headers, path, progress_callback)
    local file_headers, redirects, resumes = {}, 0, 0
    local offset, total, validator = 0, nil, nil
    local response_path = path .. ".response"
    local function failed(err)
        os.remove(response_path)
        os.remove(path)
        return nil, err
    end
    while redirects <= 5 do
        if not origin(url) then return failed("Invalid download URL") end
        local f, err = io.open(response_path, "wb")
        if not f then return failed("Could not create download file: " .. tostring(err)) end
        local received = 0
        local request_headers = copy_table(headers)
        request_headers["Accept-Encoding"] = "identity"
        if offset > 0 then
            request_headers.Range = "bytes=" .. offset .. "-"
            request_headers["If-Range"] = validator
        end
        local progress = transfer_progress(progress_callback, "downloading")
        local result, code, response_headers = request({
            url = url, headers = request_headers, redirect = false,
            sink = function(chunk)
                if chunk then
                    local written, write_err = f:write(chunk)
                    if written then received = received + #chunk end
                    return written, write_err
                end
                return 1
            end,
        }, true, progress and function(bytes) progress(offset + bytes) end)
        if origin(url) == origin(API_ROOT) then
            for _, name in ipairs({ "zotero-file-md5", "zotero-file-compressed", "zotero-file-modification-time" }) do
                local value = header(response_headers, name)
                if value then file_headers[name] = value end
            end
        end
        local closed, close_err = f:close()
        if not closed then return failed("Could not save download: " .. tostring(close_err)) end
        if result == 1 and (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) then
            os.remove(response_path)
            os.remove(path)
            local location = header(response_headers, "location")
            if not location then return failed("Missing download redirect location") end
            local next_url = URL.absolute(url, location)
            if url:match("^https:") and not next_url:match("^https:") then return failed("Refusing an HTTPS download redirect to HTTP") end
            if origin(next_url) ~= origin(url) then headers = without_credentials(headers) end
            url = next_url
            redirects = redirects + 1
            offset, total, validator = 0, nil, nil
        else
            if result ~= 1 or (code ~= 200 and code ~= 206) then
                return failed(API.verifyResponse(result, code))
            end
            local encoding = header(response_headers, "content-encoding")
            if encoding and encoding:lower() ~= "identity" then return failed("Unexpected encoding in file download") end
            local length = tonumber(header(response_headers, "content-length"))
            local transfer_encoding = header(response_headers, "transfer-encoding")
            if transfer_encoding and transfer_encoding:lower() ~= "identity" then length = nil end
            if length and (length < 0 or length % 1 ~= 0 or received > length) then
                return failed("Invalid response length in file download")
            end
            if code == 206 then
                local first, last, size = (header(response_headers, "content-range") or ""):match("^bytes (%d+)%-(%d+)/(%d+)$")
                first, last, size = tonumber(first), tonumber(last), tonumber(size)
                if offset == 0 or not first or first ~= offset or size ~= total or last < first or last >= size
                    or received > last - first + 1 or (length and length ~= last - first + 1)
                    or header(response_headers, "etag") ~= validator then
                    return failed("The resumed download does not match the original file or byte range")
                end
                local appended, append_err = append_file(response_path, path)
                if not appended then return failed("Could not save resumed download: " .. tostring(append_err)) end
                os.remove(response_path)
                offset = offset + received
            else
                -- A server may ignore Range or return a new representation. Never append a 200 response.
                local renamed, rename_err = os.rename(response_path, path)
                if not renamed then return failed("Could not save download: " .. tostring(rename_err)) end
                offset, total = received, length
                local etag = header(response_headers, "etag")
                validator = type(etag) == "string" and etag:match('^"[^"\r\n]+"$') and etag or nil
            end
            if total and offset < total then
                if received == 0 or not validator or resumes >= MAX_DOWNLOAD_RESUMES then
                    return failed(("Incomplete file download: received %d of %d bytes. Please retry."):format(offset, total))
                end
                resumes = resumes + 1
                report_progress(progress_callback, "resuming", { bytes = offset, attempt = resumes })
            else
                for name, value in pairs(file_headers) do response_headers[name] = value end
                return true, nil, response_headers
            end
        end
    end
    return failed("Too many download redirects")
end

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function command_succeeded(result)
    return result == true or result == 0 -- Lua 5.2+ and LuaJIT/Lua 5.1, respectively
end

local function extract_archive(zip_path, filename, target_path)
    local temporary = target_path .. ".part"
    local error_path = temporary .. ".error"
    -- Current Zotero ZIPs use plain paths; old ZIPs use base64(UTF-8 path) + %ZB64.
    local names = { filename, sha2.bin_to_base64(filename) .. "%ZB64" }
    local extracted, details, retryable = false, nil, false
    for _, name in ipairs(names) do
        local pattern = name:gsub("([%[%]%*%?\\])", "\\%1")
        local command = "unzip -p " .. shell_quote(zip_path) .. " " .. shell_quote(pattern)
            .. " > " .. shell_quote(temporary) .. " 2> " .. shell_quote(error_path)
        local ran, result, status, exit_code = pcall(os.execute, command)
        if ran and command_succeeded(result) and file_exists(temporary) then extracted = true; break end
        local error_file = io.open(error_path, "rb")
        local message = error_file and error_file:read(2048) or ""
        if error_file then error_file:close() end
        message = message:gsub(zip_path:gsub("(%W)", "%%%1"), "archive"):gsub("%s+", " ")
        local lower = message:lower()
        local corrupt = false
        for _, marker in ipairs({ "end-of-central-directory", "unexpected end", "short read",
            "bad crc", "crc error", "invalid compressed data", "inflate error", "invalid zip magic" }) do
            if lower:find(marker, 1, true) then corrupt = true end
        end
        retryable = retryable or corrupt
        -- A missing legacy fallback name must not hide the main file's CRC error.
        if message ~= "" and (not details or corrupt) then details = message
        elseif not details then
            details = "unzip command failed (" .. tostring(status or "status") .. ": " .. tostring(exit_code or result) .. ")"
        end
    end
    os.remove(error_path)
    if not extracted then
        os.remove(temporary)
        return nil, "Could not extract the attachment from its WebDAV archive"
            .. (details and (": " .. details:sub(1,240)) or ". The unzip command failed."), retryable
    end
    local renamed, rename_err = os.rename(temporary, target_path)
    if not renamed then os.remove(temporary); return nil, "Could not save extracted attachment: " .. tostring(rename_err) end
    return target_path
end

function API.downloadWebDAV(key, target_dir, target_path, progress_callback)
    local url = trim(API.getWebDAVUrl()):gsub("/+$", "")
    if not origin(url) then return nil, "A valid HTTP or HTTPS WebDAV URL is required" end
    local zip_path = target_dir .. "/.zotero-download.zip"
    for attempt = 1, 2 do
        local ok, err = download_file(url .. "/" .. key .. ".zip", API.getWebDAVHeaders(), zip_path, progress_callback)
        if not ok then return nil, err end
        report_progress(progress_callback, "extracting")
        local path, retryable
        path, err, retryable = extract_archive(zip_path, API.getItems()[key].data.filename, target_path)
        if path then os.remove(zip_path); return path end
        -- Retain one failed archive and its explanation, even if a retry works.
        local attributes = lfs.attributes(zip_path)
        local report = io.open(API.zotero_dir .. "/download-error.log", "w")
        if report then
            report:write(("Attachment: %s\nArchive bytes: %d\n%s\n"):format(key, attributes and attributes.size or 0, err))
            report:close()
        end
        os.rename(zip_path, API.zotero_dir .. "/.zotero-failed-download.zip")
        os.remove(zip_path)
        if not retryable or attempt == 2 then return nil, err end
        report_progress(progress_callback, "retrying_archive", { attempt = attempt + 1 })
    end
end

local function attachment_md5(attachment)
    local digest = attachment.data.md5
    if type(digest) == "string" and #digest == 32 and digest:match("^%x+$") then return digest:lower() end
end

-- Use the same cache decision for browsing and opening. This only reads the
-- small receipt and file attributes; browsing must not hash PDFs or use HTTP.
local function attachment_status(attachment, directory, path)
    local attributes = path and lfs.attributes(path)
    if not attributes or attributes.mode ~= "file" or attributes.size == 0 then
        return "not_downloaded"
    end
    local metadata = read_json(directory .. "/.zotero-cache.json")
    local md5, version = attachment_md5(attachment), tonumber(attachment.version)
    if metadata and ((md5 and metadata.md5 == md5)
        or (not md5 and version and tonumber(metadata.version) == version)) then
        return "downloaded", path, attributes.size
    end
    return "outdated", path, attributes.size
end

function API.getAttachmentStatus(key)
    local directory, path = API.getDirAndPath(key)
    if not path then return "not_downloaded" end
    return attachment_status(API.getItems()[key], directory, path)
end

local function file_md5(path, progress_callback)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local update = sha2.md5()
    local checked = 0
    while true do
        local chunk = f:read(65536)
        if not chunk then break end
        update(chunk)
        checked = checked + #chunk
        report_progress(progress_callback, "verifying", { bytes = checked })
    end
    f:close()
    return update()
end

local function download_attachment(key, download_callback, progress_callback)
    local err, api_key, user_id = API.ensureKeyAndID()
    if err then return nil, err end
    report_progress(progress_callback, "checking_cache")
    local attachment = API.getItems()[key]
    if not attachment or not attachment.data then return nil, "The attachment was not found in the library" end
    if attachment.data.itemType ~= "attachment" then return nil, "This item is not an attachment" end
    local mode = attachment.data.linkMode
    if mode ~= "imported_file" and mode ~= "imported_url" then
        return nil, "Unsupported attachment link mode: " .. tostring(mode) .. ". Linked files and linked URLs are not stored by Zotero."
    end
    if not SUPPORTED_MEDIA_TYPES[attachment.data.contentType] then return nil, "Only PDF and EPUB attachments are supported" end
    local target_dir, target_path, path_err = API.getDirAndPath(key)
    if not target_path then return nil, path_err end
    local ok
    ok, err = util.makePath(target_dir)
    if not ok then return nil, "Could not create attachment directory: " .. tostring(err) end
    local metadata_path = target_dir .. "/.zotero-cache.json"
    local md5 = attachment_md5(attachment)
    if attachment_status(attachment, target_dir, target_path) == "downloaded" then
        report_progress(progress_callback, "cached")
        return target_path
    end
    if download_callback then download_callback() end
    local temporary = target_dir .. "/.zotero-download.part"
    local response_headers
    if API.getWebDAVEnabled() then
        local path
        path, err = API.downloadWebDAV(key, target_dir, temporary, progress_callback)
        ok = path ~= nil
    else
        ok, err, response_headers = download_file(API_ROOT .. "/users/" .. user_id .. "/items/" .. key .. "/file",
            API.getHeaders(api_key), temporary, progress_callback)
    end
    if not ok then os.remove(temporary); return nil, err end
    report_progress(progress_callback, "verifying")
    local compressed = (header(response_headers, "zotero-file-compressed") or ""):lower() == "yes"
    local etag = header(response_headers, "etag")
    if etag then etag = etag:gsub('^"', ""):gsub('"$', ""):lower() end
    local remote_md5 = header(response_headers, "zotero-file-md5")
    if remote_md5 then remote_md5 = remote_md5:lower() end
    if compressed then
        -- The storage hash/ETag describes the ZIP, while data.md5 describes its main file.
        local zip_md5 = file_md5(temporary, progress_callback)
        if (remote_md5 and remote_md5 ~= zip_md5) or (etag and etag ~= zip_md5) then
            os.remove(temporary)
            return nil, "The downloaded ZIP does not match Zotero's storage checksum."
        end
        local unpacked = temporary .. ".unpacked"
        local path
        report_progress(progress_callback, "extracting")
        path, err = extract_archive(temporary, attachment.data.filename, unpacked)
        os.remove(temporary)
        if not path then return nil, err end
        ok, err = os.rename(unpacked, temporary)
        if not ok then os.remove(unpacked); return nil, "Could not save unpacked attachment: " .. tostring(err) end
    end
    if md5 and ((not compressed and remote_md5 and remote_md5 ~= md5)
        or (not compressed and etag and etag ~= md5) or file_md5(temporary, progress_callback) ~= md5) then
        os.remove(temporary)
        return nil, "The downloaded file does not match Zotero's attachment metadata. Synchronize the library and retry."
    end
    local attributes = lfs.attributes(temporary)
    if not attributes or attributes.size == 0 then os.remove(temporary); return nil, "The downloaded attachment is empty" end
    report_progress(progress_callback, "saving_attachment")
    ok, err = os.rename(temporary, target_path)
    if not ok then os.remove(temporary); return nil, "Could not save attachment: " .. tostring(err) end
    local mtime = tonumber(attachment.data.mtime)
    if mtime then lfs.touch(target_path, os.time(), mtime / 1000) end
    ok, err = write_json(metadata_path, { version = attachment.version, md5 = md5 })
    if not ok then return nil, "Could not save attachment metadata: " .. tostring(err) end
    report_progress(progress_callback, "complete")
    return target_path
end

-- Keep the legacy download-start callback separate from the optional progress callback.
function API.downloadAndGetPath(key, download_callback, progress_callback)
    local ok, path, err = pcall(download_attachment, key, download_callback, progress_callback)
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

local function attachment_entry(key, item, parent, label)
    return { key = key, text = label, parent_key = parent and item.data.parentItem,
        attachment_title = item.data.title, filename = item.data.filename,
        file_type = item.data.contentType == "application/pdf" and "PDF" or "EPUB" }
end

local function by_text(a, b)
    if a.text ~= b.text then return a.text < b.text end
    return a.key < b.key
end

function API.displayAttachments(parent_key)
    local results, items = {}, API.getItems()
    local parent = items[parent_key]
    if not parent then return results end
    for key, item in pairs(items) do
        if visible_attachment(items, item) and item.data.parentItem == parent_key then
            results[#results + 1] = attachment_entry(key, item, parent, item_label(parent))
        end
    end
    table.sort(results, function(a, b)
        local a_name, b_name = a.attachment_title or a.filename or "", b.attachment_title or b.filename or ""
        if a_name ~= b_name then return a_name < b_name end
        if a.filename ~= b.filename then return (a.filename or "") < (b.filename or "") end
        return a.key < b.key
    end)
    return results
end

function API.getLibrarySummary()
    local items, collections = API.getItems(), API.getCollections()
    local summary = { items = 0, collections = 0, attachments = 0 }
    for _, item in pairs(items) do
        summary.items = summary.items + 1
        if visible_attachment(items, item) then summary.attachments = summary.attachments + 1 end
    end
    for _ in pairs(collections) do summary.collections = summary.collections + 1 end
    return summary
end

function API.displayCollection(key)
    local results = {}
    for collection_key, collection in pairs(API.getCollections()) do
        local parent = collection.data.parentCollection
        if (key == nil and not parent) or parent == key then
            results[#results + 1] = { key = collection_key, text = collection.data.name .. "/", collection = true }
        end
    end
    table.sort(results, by_text)
    local attachments, items = {}, API.getItems()
    for item_key, item in pairs(items) do
        if visible_attachment(items, item) then
            local parent = parent_item(items, item)
            local source = parent or item
            if contains(source.data.collections, key) then
                attachments[#attachments + 1] = attachment_entry(item_key, item, parent,
                    parent and item_label(parent) or (item.data.title or item.data.filename or "Untitled"))
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
            local label = parent and item_label(parent) or (item.data.title or item.data.filename or "Untitled")
            if parent and type(parent.data.DOI) == "string" and parent.data.DOI ~= "" then label = label .. " - " .. parent.data.DOI end
            local start, matched = 1, true
            for _, word in ipairs(words) do
                local first, last = label:lower():find(word, start, true)
                if not first then matched = false; break end
                start = last + 1
            end
            if matched then results[#results + 1] = attachment_entry(key, item, parent, label) end
        end
    end
    table.sort(results, by_text)
    return results
end

return API
