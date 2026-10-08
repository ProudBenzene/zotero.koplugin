-- Local removal only: this module never calls a Zotero or WebDAV endpoint.
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local LocalFiles = {}

function LocalFiles.getPDFPath(api, key)
    local item = api.getItems()[key]
    if not item or type(item.data) ~= "table" or item.data.itemType ~= "attachment" or item.data.contentType ~= "application/pdf"
        or (item.data.linkMode ~= "imported_file" and item.data.linkMode ~= "imported_url") then
        return nil, nil, "Only downloaded PDF attachments can be removed."
    end
    local directory, path, err = api.getDirAndPath(key)
    if not path then return nil, nil, err end
    if lfs.attributes(path, "mode") ~= "file" then return nil, nil, "Local PDF not found." end
    local storage = ffiutil.realpath(api.storage_dir)
    local real_directory, real_path = ffiutil.realpath(directory), ffiutil.realpath(path)
    -- Do not follow a replaced attachment directory or file outside its own slot.
    if not storage or real_directory ~= storage .. "/" .. key
        or real_path ~= real_directory .. "/" .. item.data.filename then
        return nil, nil, "The PDF path does not match its attachment storage."
    end
    return real_directory, real_path
end

function LocalFiles.removePDF(api, key, expected_path)
    local directory, path, err = LocalFiles.getPDFPath(api, key)
    if not path then return nil, err end
    if path ~= expected_path then return nil, "The local PDF changed. Open its details again." end
    local reader = require("apps/reader/readerui").instance
    if reader and reader.document and ffiutil.realpath(reader.document.file) == path then
        return nil, "Close this PDF before deleting its local copy."
    end

    -- Open settings while the file still exists, so hash-based sidecars are
    -- located correctly. Never purge annotations when removing the PDF fails.
    local settings = require("docsettings"):open(path)
    local settings_files = {}
    for _, candidate in ipairs(settings.candidates or {}) do
        settings_files[#settings_files + 1] = candidate.path
    end
    local cover, metadata = settings:getCustomCoverFile(), settings:getCustomMetadataFile()
    if cover then settings_files[#settings_files + 1] = cover end
    if metadata then settings_files[#settings_files + 1] = metadata end
    local cache_file = settings:readSetting("cache_file_path")
    local ok
    ok, err = os.remove(path)
    if not ok then return nil, err end

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
    attempt(function() settings:purge() end)
    -- Native purge does not return errors; verify its known files and retry
    -- individual leftovers instead of recursively deleting a sidecar folder.
    for _, file in ipairs(settings_files) do remove_file(file) end
    remove_file(cache_file)
    for _, name in ipairs({ ".zotero-cache.json", ".zotero-cache.json.tmp",
        ".zotero-annotations.json", ".zotero-annotations.json.tmp" }) do
        remove_file(directory .. "/" .. name)
    end
    attempt(function() require("ui/widget/booklist").resetBookInfoCache(path) end)
    attempt(function() require("readhistory"):fileDeleted(path) end)
    attempt(function() require("readcollection"):removeItem(path) end)
    os.remove(directory) -- Remove it only if empty; preserve unrelated files.
    return true, #errors > 0 and table.concat(errors, "\n") or nil
end

return LocalFiles
