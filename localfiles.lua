-- Local removal only: this module never calls a Zotero or WebDAV endpoint.
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
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
    local ok
    ok, err = os.remove(path)
    if not ok then return nil, err end

    local _, message = LocalFiles.cleanup(path, directory, task, settings)
    return true, message
end

function LocalFiles.removePDF(api, key, expected_path)
    return LocalFiles.removeAttachment(api, key, expected_path, true)
end

return LocalFiles
