-- Local removal only: this module never calls a Zotero or WebDAV endpoint.
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local FileUtil = require("fileutil")
local LocalFiles = {}
local media = { ["application/pdf"] = true, ["application/epub+zip"] = true }

function LocalFiles.getAttachmentPath(api, key, pdf_only)
    local item = api.getItems()[key]
    if not item or type(item.data) ~= "table" or item.data.itemType ~= "attachment"
        or not media[item.data.contentType] or pdf_only and item.data.contentType ~= "application/pdf"
        or (item.data.linkMode ~= "imported_file" and item.data.linkMode ~= "imported_url") then
        return nil, nil, pdf_only and "Only downloaded PDF attachments can be removed." or "Only downloaded PDF or EPUB attachments can be removed."
    end
    local directory, path, err = api.getDirAndPath(key)
    if not path then return nil, nil, err end
    if lfs.attributes(path, "mode") ~= "file" then return nil, nil, pdf_only and "Local PDF not found." or "Local document not found." end
    local storage = ffiutil.realpath(api.storage_dir)
    local real_directory, real_path = ffiutil.realpath(directory), ffiutil.realpath(path)
    -- Do not follow a replaced attachment directory or file outside its own slot.
    if not storage or real_directory ~= storage .. "/" .. key
        or real_path ~= real_directory .. "/" .. item.data.filename
        or lfs.symlinkattributes and (lfs.symlinkattributes(directory, "mode") == "link"
            or lfs.symlinkattributes(path, "mode") == "link") then
        return nil, nil, pdf_only and "The PDF path does not match its attachment storage." or "The document path does not match its attachment storage."
    end
    return real_directory, real_path
end

function LocalFiles.getPDFPath(api, key)
    return LocalFiles.getAttachmentPath(api, key, true)
end

function LocalFiles.isOpen(path)
    local reader = require("apps/reader/readerui").instance
    return reader and reader.document and ffiutil.realpath(reader.document.file) == path or false
end

function LocalFiles.settingsTask(settings)
    local task = { files = {}, dirs = {}, cache_file = settings:readSetting("cache_file_path") }
    for _, candidate in ipairs(settings.candidates or {}) do
        task.files[#task.files + 1] = candidate.path
    end
    local cover, metadata = settings:getCustomCoverFile(), settings:getCustomMetadataFile()
    if cover then task.files[#task.files + 1] = cover end
    if metadata then task.files[#task.files + 1] = metadata end
    for _, field in ipairs({ "doc_sidecar_dir", "dir_sidecar_dir", "hash_sidecar_dir" }) do
        if settings[field] then task.dirs[#task.dirs + 1] = settings[field] end
    end
    return task
end

function LocalFiles.captureSettings(path)
    local settings = require("docsettings"):open(path)
    return LocalFiles.settingsTask(settings), settings
end

local function settings_path(path)
    if type(path) ~= "string" or path == "" or path:find("%z") then return nil end
    path = ffiutil.realpath(path) or path
    if path:sub(1, 1) ~= "/" then path = (ffiutil.realpath(".") or ".") .. "/" .. path end
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then table.remove(parts)
        elseif part ~= "." then parts[#parts + 1] = part end
    end
    return "/" .. table.concat(parts, "/")
end

function LocalFiles.sharesOpenSettings(task)
    local reader = require("apps/reader/readerui").instance
    if not reader or not reader.doc_settings then return false end
    local active = LocalFiles.settingsTask(reader.doc_settings)
    local protected = {}
    local function protect(path)
        path = settings_path(path)
        if path then protected[path] = true end
    end
    for _, path in ipairs(active.files) do protect(path) end
    protect(active.cache_file)
    -- DocSettings:flush() can create metadata without refreshing candidates.
    -- Shared directories still identify reading data used by the open reader.
    for _, path in ipairs(active.dirs) do protect(path) end
    for _, path in ipairs(task.files) do
        if protected[settings_path(path)] then return true end
    end
    if protected[settings_path(task.cache_file)] then return true end
    for _, path in ipairs(task.dirs or {}) do
        if protected[settings_path(path)] then return true end
    end
    return false
end

local function has_other_downloads(api, key, directory, path)
    local receipt_path = directory .. "/.zotero-cache.json"
    if lfs.attributes(receipt_path, "mode") ~= "file"
        or lfs.symlinkattributes and lfs.symlinkattributes(receipt_path, "mode") == "link"
        or ffiutil.realpath(receipt_path) ~= receipt_path
        or (lfs.attributes(receipt_path, "size") or 0) > 1024 * 1024 then return false end
    local receipt = FileUtil.readJSON(receipt_path)
    local user = tostring(api.getUserID() or ""):match("^%s*(.-)%s*$")
    if not receipt or receipt.format ~= 1 or receipt.source ~= "zotero.koplugin"
        or receipt.user_id ~= user or receipt.attachment_key ~= key or not media[receipt.content_type] then return false end
    local function remains(record)
        local name = type(record) == "table" and record.filename
        if not FileUtil.validFilename(name) or not media[record.content_type] then return false end
        local other = directory .. "/" .. name
        return other ~= path and lfs.attributes(other, "mode") == "file" and ffiutil.realpath(other) == other
            and not (lfs.symlinkattributes and lfs.symlinkattributes(other, "mode") == "link")
    end
    if remains(receipt) then return true end
    for _, previous in ipairs(type(receipt.previous_files) == "table" and receipt.previous_files or {}) do
        if remains(previous) then return true end
    end
    return false
end

-- Callers validate the document and (for persisted tasks) every cleanup path.
-- Only unlink known files; directory removal always requires it to be empty.
function LocalFiles.cleanup(path, directory, task, settings, keep_slot_cache)
    local errors = {}
    local function attempt(callback)
        local success, message = pcall(callback)
        if not success then errors[#errors + 1] = tostring(message) end
    end
    local function remove_file(file)
        if file and lfs.attributes(file) then
            local removed, message = os.remove(file)
            if not removed then errors[#errors + 1] = file .. ": " .. tostring(message) end
        end
    end
    if settings then attempt(function() settings:purge() end) end
    for _, file in ipairs(task.files) do remove_file(file) end
    remove_file(task.cache_file)
    if not keep_slot_cache then
        for _, name in ipairs({ ".zotero-cache.json", ".zotero-cache.json.tmp",
            ".zotero-annotations.json", ".zotero-annotations.json.tmp",
            ".zotero-download.part", ".zotero-download.part.unpacked", ".zotero-download.part.unpacked.part" }) do
            remove_file(directory .. "/" .. name)
        end
    end
    attempt(function() require("ui/widget/booklist").resetBookInfoCache(path) end)
    attempt(function() require("readhistory"):fileDeleted(path) end)
    attempt(function() require("readcollection"):removeItem(path) end)
    for _, dir in ipairs(task.dirs or {}) do os.remove(dir) end
    os.remove(directory)
    return #errors == 0, #errors > 0 and table.concat(errors, "\n") or nil
end

function LocalFiles.removeAttachment(api, key, expected_path, pdf_only)
    local directory, path, err = LocalFiles.getAttachmentPath(api, key, pdf_only)
    if not path then return nil, err end
    if path ~= expected_path then return nil, pdf_only and "The local PDF changed. Open its details again." or "The local document changed. Open its details again." end
    if LocalFiles.isOpen(path) then
        return nil, pdf_only and "Close this PDF before deleting its local copy." or "Close this document before deleting its local copy."
    end

    -- Open settings while the file still exists, so hash-based sidecars are
    -- located correctly. Never purge annotations when removing the PDF fails.
    local task, settings = LocalFiles.captureSettings(path)
    if LocalFiles.sharesOpenSettings(task) then
        return nil, "Close the open document before deleting downloads that share its reading data."
    end
    -- A renamed old copy needs this receipt to remain identifiable by cleanup.
    local keep_slot_cache = has_other_downloads(api, key, directory, path)
    local ok
    ok, err = os.remove(path)
    if not ok then return nil, err end

    local _, message = LocalFiles.cleanup(path, directory, task, settings, keep_slot_cache)
    return true, message
end

function LocalFiles.removePDF(api, key, expected_path)
    return LocalFiles.removeAttachment(api, key, expected_path, true)
end

return LocalFiles
