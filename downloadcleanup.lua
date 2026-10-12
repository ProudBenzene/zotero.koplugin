-- Enumerate plugin-owned downloads across accounts. No credentials or HTTP.
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local ffiutil = require("ffi/util")
local FileUtil = require("fileutil")
local LocalFiles = require("localfiles")
local LibraryCache = require("librarycache")
local logger = require("logger")
local Cleanup = {}
local JOURNAL = ".zotero-cleanup.json"
local SOURCE = "zotero.koplugin"
local media = { ["application/pdf"] = "PDF", ["application/epub+zip"] = "EPUB" }
local cache_names = { [".zotero-cache.json"] = true, [".zotero-cache.json.tmp"] = true,
    [".zotero-annotations.json"] = true, [".zotero-annotations.json.tmp"] = true,
    [".zotero-download.part"] = true, [".zotero-download.part.unpacked"] = true,
    [".zotero-download.part.unpacked.part"] = true, [JOURNAL] = true, [JOURNAL .. ".tmp"] = true }

local filename = FileUtil.validFilename
local function array(value)
    if type(value) ~= "table" then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #value then return false end
        count = count + 1
    end
    return count == #value
end
local function absolute(path)
    if type(path) ~= "string" or path == "" or path:find("%z") then return nil end
    if path:sub(1, 1) ~= "/" then path = (ffiutil.realpath(".") or ".") .. "/" .. path end
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then return nil end
        if part ~= "." then parts[#parts + 1] = part end
    end
    return "/" .. table.concat(parts, "/")
end
local function unredirected(path, mode)
    if lfs.symlinkattributes(path, "mode") == "link" then return false end
    local attr = lfs.attributes(path)
    return attr and (not mode or attr.mode == mode) and ffiutil.realpath(path) == path
end
local function read_json(path)
    if not unredirected(path, "file") or (lfs.attributes(path, "size") or 0) > 1024 * 1024 then return nil end
    return FileUtil.readJSON(path)
end
local function write_json(path, value)
    if lfs.symlinkattributes(path, "mode") == "link" or lfs.symlinkattributes(path .. ".tmp", "mode") == "link" then
        return nil, "The local file path changed. Scan the downloads again."
    end
    return FileUtil.writeJSON(path, value)
end
local function entries(path)
    local result = {}
    local ok, err = pcall(function()
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then result[#result + 1] = name end
        end
    end)
    if not ok then return nil, tostring(err) end
    table.sort(result)
    return result
end
local function identity(path)
    local attr = lfs.attributes(path)
    return attr and { size = attr.size, modification = attr.modification,
        change = attr.change, ino = attr.ino, dev = attr.dev } or nil
end
local function kind(name)
    local suffix = name:lower():match("%.([^%.]+)$")
    return suffix == "pdf" and "PDF" or suffix == "epub" and "EPUB" or nil
end
local function journal(directory)
    local value = read_json(directory .. "/" .. JOURNAL)
    if value and value.format == 1 and value.source == SOURCE and type(value.tasks) == "table" then return value end
end
local function valid_receipt(value)
    return value and (type(value.version) == "number" and value.version >= 0 and value.version % 1 == 0
        or type(value.md5) == "string" and #value.md5 == 32 and value.md5:match("^%x+$"))
end
local function digest(path, progress)
    return FileUtil.md5(path, progress and function() progress({ stage = "scanning_downloads" }) end)
end

local function snapshot(path, progress)
    local before = identity(path)
    if not before or not unredirected(path, "file") then return nil end
    local md5 = digest(path, progress)
    local after = identity(path)
    if not md5 or not after or before.size ~= after.size or before.modification ~= after.modification
        or not unredirected(path, "file") then return nil end
    after.md5 = md5
    return after
end

local function matches(path, expected, progress)
    local attr = identity(path)
    if not attr or type(expected) ~= "table" then return false, "missing identity" end
    if attr.size ~= expected.size then return false, "size" end
    if expected.md5 ~= nil then
        if type(expected.md5) ~= "string" or #expected.md5 ~= 32 or not expected.md5:match("^%x+$") then return false, "invalid digest" end
        -- VFAT can rebuild inode numbers, and ctime can change without a new
        -- document. Compare the actual previewed bytes, even if stat is equal.
        local current = snapshot(path, progress)
        if not current then return false, "could not read a stable file" end
        if current.md5 ~= expected.md5 then return false, "content" end
        return true
    end
    -- Compatibility for a pre-fingerprint journal whose document still exists.
    for _, field in ipairs({ "modification", "change", "ino", "dev" }) do
        if attr[field] ~= expected[field] then return false, field end
    end
    return true
end

local function metadata_items(api, user)
    if api.isLibraryLoaded() then
        local ok, items = pcall(api.getItems)
        return ok and items or {}
    end
    -- getItems() can migrate and rewrite an old snapshot. Cleanup only reads it.
    local state
    local cache_path = api.cache_path and absolute(api.cache_path)
    if cache_path and unredirected(cache_path, "file") then
        if (lfs.attributes(cache_path, "size") or 0) <= 1024 * 1024 then
            state = read_json(cache_path)
        else
            local ok, value = pcall(LibraryCache.read, cache_path, JSON, function(item)
                local data = item.data
                return { data = { itemType = data.itemType, contentType = data.contentType,
                    linkMode = data.linkMode, filename = data.filename, title = data.title, parentItem = data.parentItem } }
            end, function() return {} end)
            if ok then state = value end
        end
    end
    return state and state.format == 1 and state.user_id == user and type(state.items) == "table" and state.items or {}
end

function Cleanup.scanDownloads(api, progress)
    local root = ffiutil.realpath(api.zotero_dir)
    if not root then error("The download storage is unavailable.") end
    if lfs.symlinkattributes(api.zotero_dir, "mode") == "link" then error("The download storage path is redirected.") end
    local storage = root .. "/storage"
    local scan = { root = root, storage = storage, targets = {}, unknown = {}, pdf = 0, epub = 0,
        bytes = 0, accounts = 0, pending = 0 }
    local seen_unknown, accounts = {}, {}
    local function unknown(path)
        if not seen_unknown[path] then
            scan.unknown[#scan.unknown + 1] = path; seen_unknown[path] = true
        end
    end
    if not lfs.attributes(storage) then return scan end
    if not unredirected(storage, "directory") then error("The download storage path is redirected.") end
    local current_user = tostring(api.getUserID() or ""):match("^%s*(.-)%s*$")
    local items = metadata_items(api, current_user)
    local function slot(directory, user, key)
        if not unredirected(directory, "directory") then unknown(directory); return end
        local names, err = entries(directory)
        if not names then unknown(directory .. ": " .. err); return end
        local receipt = read_json(directory .. "/.zotero-cache.json")
        local saved = journal(directory)
        local candidates, owned, types = {}, {}, {}
        local function own(name, file_type)
            if filename(name) and unredirected(directory .. "/" .. name, "file") then
                owned[name], types[name] = true, file_type or kind(name)
            end
        end
        local item = user == current_user and items[key]
        local title, attachment_title
        if item and type(item.data) == "table" and item.data.itemType == "attachment"
            and media[item.data.contentType] and (item.data.linkMode == "imported_file" or item.data.linkMode == "imported_url") then
            own(item.data.filename, media[item.data.contentType])
            local parent = items[item.data.parentItem]
            attachment_title = type(item.data.title) == "string" and item.data.title or nil
            title = parent and type(parent.data) == "table" and type(parent.data.title) == "string"
                and parent.data.title or attachment_title
        end
        for _, name in ipairs(names) do
            if filename(name) and kind(name) and unredirected(directory .. "/" .. name, "file") then
                candidates[#candidates + 1] = name
            end
        end
        if receipt and receipt.format == 1 and receipt.source == SOURCE and receipt.user_id == user
            and receipt.attachment_key == key and media[receipt.content_type] then
            own(receipt.filename, media[receipt.content_type])
            for _, previous in ipairs(type(receipt.previous_files) == "table" and receipt.previous_files or {}) do
                if type(previous) == "table" and media[previous.content_type] then own(previous.filename, media[previous.content_type]) end
            end
        elseif valid_receipt(receipt) and receipt.format == nil and receipt.source == nil then
            if #candidates == 1 then own(candidates[1])
            elseif type(receipt.md5) == "string" then
                for _, name in ipairs(candidates) do
                    if digest(directory .. "/" .. name, progress) == receipt.md5:lower() then own(name) end
                end
            end
        end
        local pending_names = {}
        if saved then
            for name, task in pairs(saved.tasks) do
                if filename(name) and type(task) == "table" and media[task.content_type] then
                    pending_names[name] = true
                    local path = directory .. "/" .. name
                    if not lfs.symlinkattributes(path) then
                        scan.targets[#scan.targets + 1] = { root = root, storage = storage, directory = directory,
                            user = user, key = key, filename = name, file_type = media[task.content_type],
                            path = path, title = title, attachment_title = attachment_title, cleanup_only = true, task = task }
                        scan.pending = scan.pending + 1; accounts[user] = true
                    elseif unredirected(path, "file") and matches(path, task.identity, progress) then
                        own(name, media[task.content_type])
                    else
                        owned[name], types[name] = nil, nil
                        unknown(path)
                    end
                else unknown(directory .. "/" .. JOURNAL) end
            end
        elseif lfs.attributes(directory .. "/" .. JOURNAL) then unknown(directory .. "/" .. JOURNAL) end
        local slot_files, related = {}, {}
        for name in pairs(owned) do slot_files[#slot_files + 1] = name end
        table.sort(slot_files)
        for _, documents in ipairs({ owned, pending_names }) do
            for name in pairs(documents) do
                related[(name:match("^(.*)%.") or name) .. ".sdr"] = true
                related[name .. ".kpdfview.lua"] = true
            end
        end
        for _, name in ipairs(names) do
            local path = directory .. "/" .. name
            if owned[name] and types[name] then
                local file_type = types[name]
                local captured = snapshot(path, progress)
                if captured then
                    scan.targets[#scan.targets + 1] = { root = root, storage = storage, directory = directory,
                        user = user, key = key, filename = name, path = path, file_type = file_type,
                        title = title, attachment_title = attachment_title, slot_files = slot_files, identity = captured }
                    local field = file_type == "PDF" and "pdf" or "epub"
                    scan[field] = scan[field] + 1; scan.bytes = scan.bytes + captured.size
                    accounts[user] = true
                else
                    logger.warn("Zotero cleanup could not verify download", key)
                    unknown(path)
                end
            elseif not cache_names[name] and not related[name] then
                unknown(path)
            end
            if progress then progress({ stage = "scanning_downloads" }) end
        end
        -- Cache-only folders without a journal cannot locate old hash sidecars.
        if not next(owned) and not next(pending_names) and #names > 0 then unknown(directory) end
    end
    local names, err = entries(storage)
    if not names then error(err) end
    for _, name in ipairs(names) do
        local path = storage .. "/" .. name
        if name:match("^%d+$") and unredirected(path, "directory") then
            local children, child_err = entries(path)
            if not children then unknown(path .. ": " .. child_err) else
                for _, key in ipairs(children) do
                    if key:match("^[A-Z0-9]+$") then slot(path .. "/" .. key, name, key)
                    else unknown(path .. "/" .. key) end
                    if progress then progress({ stage = "scanning_downloads" }) end
                end
            end
        elseif name:match("^[A-Z0-9]+$") then slot(path, "", name)
        else unknown(path) end
        if progress then progress({ stage = "scanning_downloads" }) end
    end
    for _ in pairs(accounts) do scan.accounts = scan.accounts + 1 end
    table.sort(scan.targets, function(a, b) return a.path < b.path end)
    table.sort(scan.unknown)
    return scan
end

local function validate_record(record)
    if not filename(record.filename) or not record.key:match("^[A-Z0-9]+$")
        or record.user ~= "" and not record.user:match("^%d+$") then return nil end
    local directory = record.storage .. (record.user ~= "" and "/" .. record.user or "") .. "/" .. record.key
    if record.storage ~= record.root .. "/storage" or record.directory ~= directory
        or record.path ~= directory .. "/" .. record.filename then return nil end
    if not unredirected(record.storage, "directory") or not unredirected(directory, "directory") then return nil end
    if record.user ~= "" and not unredirected(record.storage .. "/" .. record.user, "directory") then return nil end
    return true
end

local function normalize_task(task)
    for _, paths in ipairs({ task.files, task.dirs }) do
        for i, path in ipairs(paths) do
            local normalized = absolute(path)
            if not normalized then return nil end
            paths[i] = normalized
        end
    end
    if task.cache_file then
        local normalized = absolute(task.cache_file)
        if not normalized then return nil end
        task.cache_file = normalized
    end
    return task
end

-- A persisted JSON task is data, never a general-purpose list of paths to delete.
-- Reconstruct the allowed native locations from the document and known roots.
local function validate_task(record, task)
    if not array(task.files) or not array(task.dirs) or task.slot_files and not array(task.slot_files) then return false end
    local DocSettings = require("docsettings")
    local DataStorage = require("datastorage")
    local allowed_dirs = {}
    for _, location in ipairs({ "doc", "dir" }) do
        allowed_dirs[absolute(DocSettings:getSidecarDir(record.path, location))] = true
    end
    local hash_root = absolute(DataStorage:getDocSettingsHashDir())
    for _, dir in ipairs(task.dirs) do
        if type(dir) ~= "string" then return false end
        local hash = dir:sub(#hash_root + 1):match("^/%x%x/(%x+)%.sdr$")
        if dir:sub(1, #hash_root) == hash_root and hash and #hash == 32
            and dir == hash_root .. "/" .. hash:sub(1, 2) .. "/" .. hash .. ".sdr" then allowed_dirs[dir] = true end
        if not allowed_dirs[dir] or lfs.attributes(dir) and not unredirected(dir, "directory") then return false end
    end
    local history = absolute(DocSettings:getHistoryPath(record.path))
    local sidecar_name = DocSettings.getSidecarFilename(record.path)
    for _, file in ipairs(task.files) do
        if type(file) ~= "string" or absolute(file) ~= file then return false end
        local dir, name = file:match("^(.*)/([^/]+)$")
        local allowed = file == history or file == history .. ".old" or file == record.path .. ".kpdfview.lua"
            or allowed_dirs[dir] and (name == sidecar_name or name == sidecar_name .. ".old"
                or name == record.filename .. ".lua" or name == "custom_metadata.lua" or name:match("^cover%.[%w]+$"))
        if not allowed or lfs.symlinkattributes(file) and not unredirected(file, "file") then return false end
    end
    if task.cache_file then
        local cache_root = absolute(DataStorage:getDataDir()) .. "/cache/"
        if type(task.cache_file) ~= "string" or absolute(task.cache_file) ~= task.cache_file
            or task.cache_file:sub(1, #cache_root) ~= cache_root
            or lfs.symlinkattributes(task.cache_file) and not unredirected(task.cache_file, "file") then return false end
    end
    return true
end

local function save_journal(directory, value)
    if next(value.tasks) then return write_json(directory .. "/" .. JOURNAL, value) end
    if lfs.attributes(directory .. "/" .. JOURNAL) then return os.remove(directory .. "/" .. JOURNAL) end
    return true
end

local function same_task(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or a.content_type ~= b.content_type or a.cache_file ~= b.cache_file then return false end
    for _, field in ipairs({ "files", "dirs", "slot_files" }) do
        local left, right = a[field] or {}, b[field] or {}
        if not array(left) or not array(right) or #left ~= #right then return false end
        for index, value in ipairs(left) do if right[index] ~= value then return false end end
    end
    return true
end

function Cleanup.removeTarget(record, progress)
    local function changed(reason)
        logger.warn("Zotero cleanup target changed", record.key, reason)
        return "skipped", "The local file path changed. Scan the downloads again."
    end
    if not validate_record(record) then return changed("storage path") end
    if LocalFiles.isOpen(record.path) then return "open", "Close this document before deleting its local copy." end
    local saved = journal(record.directory)
    if lfs.attributes(record.directory .. "/" .. JOURNAL) and not saved then
        return "failed", "The local cleanup record is invalid."
    end
    saved = saved or { format = 1, source = SOURCE, tasks = {} }
    local task, settings
    if record.cleanup_only then
        if lfs.symlinkattributes(record.path) then return changed("document recreated") end
        task = saved.tasks[record.filename]
        if not same_task(task, record.task) then return changed("cleanup record") end
    else
        if not unredirected(record.path, "file") then return changed("document path") end
        local same, reason = matches(record.path, record.identity, progress)
        if not same then return changed(reason) end
        task, settings = LocalFiles.captureSettings(record.path)
        if not normalize_task(task) then return "failed", "The local cleanup paths are invalid." end
        task.identity = record.identity
        task.content_type = record.file_type == "PDF" and "application/pdf" or "application/epub+zip"
        task.slot_files = record.slot_files
    end
    if not task or not validate_task(record, task) then return "failed", "The local cleanup paths are invalid." end
    if LocalFiles.sharesOpenSettings(task) then
        return "open", "Close the open document before deleting downloads that share its reading data."
    end
    if not record.cleanup_only then
        saved.tasks[record.filename] = task
        local ok, err = save_journal(record.directory, saved)
        if not ok then return "failed", "Could not save the local cleanup record: " .. tostring(err) end
        ok, err = os.remove(record.path)
        if not ok then
            saved.tasks[record.filename] = nil
            save_journal(record.directory, saved)
            return "failed", tostring(err)
        end
    end
    -- Keep shared slot caches until the other recognized document has gone.
    local keep_cache = false
    for _, name in ipairs(task.slot_files or {}) do
        if filename(name) and lfs.attributes(record.directory .. "/" .. name, "mode") == "file" then keep_cache = true end
    end
    local cleaned, err = LocalFiles.cleanup(record.path, record.directory, task, settings, keep_cache)
    if not cleaned then return "pending", err, not record.cleanup_only end
    saved.tasks[record.filename] = nil
    local ok, save_err = save_journal(record.directory, saved)
    os.remove(record.directory)
    if record.user ~= "" then os.remove(record.storage .. "/" .. record.user) end
    if not ok then return "pending", tostring(save_err), not record.cleanup_only end
    return record.cleanup_only and "cleaned" or "deleted"
end

function Cleanup.newStats(scan)
    return { deleted = 0, cleaned = 0, failed = 0, open = 0, skipped = 0, pending = 0,
        unknown = #scan.unknown, errors = {}, bytes = 0 }
end
function Cleanup.processTarget(record, stats, progress)
    local ok, state, err, deleted = pcall(Cleanup.removeTarget, record, progress)
    if not ok then err, state = tostring(state), "failed" end
    stats[state] = stats[state] + 1
    if state == "deleted" or deleted then
        if deleted then stats.deleted = stats.deleted + 1 end
        stats.bytes = stats.bytes + (record.identity and record.identity.size or 0)
    end
    if err then stats.errors[#stats.errors + 1] = { path = record.path, message = tostring(err) } end
end

return Cleanup
