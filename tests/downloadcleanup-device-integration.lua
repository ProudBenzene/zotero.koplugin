-- Read a connected device; all unlink operations run on disposable local copies.
-- Usage: pandoc lua tests/downloadcleanup-device-integration.lua /Volumes/Kindle/koreader
assert(pandoc and pandoc.json, "Run with Pandoc's embedded Lua")
package.path = "./?.lua;./tests/?.lua;" .. package.path
local device = assert(arg[1], "Supply the mounted device's KOReader directory")
local support = require("tests/support")
local lfs = require("libs/libkoreader-lfs")
local sha2 = require("ffi/sha2")
sha2.md5 = dofile(device .. "/ffi/sha2.lua").md5
support.JSON.encode, support.JSON.decode = pandoc.json.encode, pandoc.json.decode
local baseline = dofile(device .. "/plugins/zotero.koplugin/downloadcleanup.lua")
local fixed = require("downloadcleanup")
local state = pandoc.json.decode(support.read(device .. "/zotero/library.json"))
local checks, original_attributes = 0, lfs.attributes
local function check(value, label)
    assert(value, label)
    checks = checks + 1
end
local function copy_dir(source, target)
    assert(support.makePath(target))
    for name in lfs.dir(source) do
        if name ~= "." and name ~= ".." then
            local from, to = source .. "/" .. name, target .. "/" .. name
            local mode = lfs.symlinkattributes(from, "mode")
            if mode == "directory" then copy_dir(from, to)
            elseif mode == "file" then support.write(to, support.read(from)) end
        end
    end
end

for _, phase in ipairs({ {name="Installed baseline", module=baseline}, {name="Content verification", module=fixed} }) do
    local API = support.setup()
    local ok, err = xpcall(function()
        check(support.directory:sub(1, #device) ~= device, "Test writes must stay outside the device")
        API.setUserID(state.user_id)
        local source_storage = device .. "/zotero/storage/" .. state.user_id
        local items, documents = {}, {}
        for key in lfs.dir(source_storage) do
            local item = state.items[key]
            if item and item.data.contentType == "application/pdf" then
                local source = source_storage .. "/" .. key
                local target = API.storage_dir .. "/" .. key
                copy_dir(source, target)
                local path = target .. "/" .. item.data.filename
                if lfs.attributes(path, "mode") == "file" then
                    local receipt = pandoc.json.decode(support.read(target .. "/.zotero-cache.json"))
                    check(sha2.md5(support.read(path)) == receipt.md5, "Cloned PDF matches its original download checksum")
                    items[key] = item
                    documents[#documents + 1] = { path=path, directory=target }
                    local sidecar = path:gsub("%.[^%.]+$", ".sdr")
                    local settings = { candidates={} }
                    if lfs.attributes(sidecar, "mode") == "directory" then
                        for name in lfs.dir(sidecar) do
                            if name == "custom_metadata.lua" then settings.metadata=sidecar .. "/" .. name
                            elseif name:match("^cover%.") then settings.cover=sidecar .. "/" .. name
                            elseif name:match("%.lua") then settings.candidates[#settings.candidates + 1]={path=sidecar .. "/" .. name} end
                        end
                    end
                    support.doc_settings[path] = settings
                end
            end
        end
        check(#documents > 0, "Found device PDFs to clone")
        -- A disposable first file reproduces the successful first unlink.
        local control = support.attachment("00000001", "control.pdf", false)
        items[control.key] = control
        support.seed(items)
        local directory, first = API.getDirAndPath(control.key)
        assert(support.makePath(directory)); support.write(first, "control document")
        local library, generation = support.read(API.cache_path), 1
        lfs.attributes = function(path, field)
            local attr = original_attributes(path)
            if attr and attr.mode == "file" and path:sub(1, #API.storage_dir) == API.storage_dir and path:match("%.pdf$") then
                attr.ino, attr.change = generation, generation
            end
            return field and attr and attr[field] or (not field and attr or nil)
        end
        local unlink = os.remove
        os.remove = function(path)
            assert(path:sub(1, #device) ~= device, "Must never delete from the connected device")
            local removed, remove_err = unlink(path)
            if path == first and removed then generation = generation + 1 end
            return removed, remove_err
        end
        local scan = phase.module.scanDownloads(API)
        check(#scan.targets == #documents + 1 and #scan.unknown == 0, "Preview contains exactly the cloned downloads")
        local stats = phase.module.newStats(scan)
        for _, target in ipairs(scan.targets) do phase.module.processTarget(target, stats) end
        if phase.module == baseline then
            check(stats.deleted == 1 and stats.skipped == #documents, "Baseline falsely skips unchanged PDFs after inode/ctime churn")
            for _, doc in ipairs(documents) do
                check(lfs.attributes(doc.path) and lfs.attributes(doc.directory .. "/.zotero-annotations.json"), "Skipped documents and annotation caches remain")
            end
        else
            check(stats.deleted == #documents + 1 and stats.skipped == 0 and stats.failed == 0 and stats.pending == 0,
                "Fixed cleanup deletes every unchanged clone")
            for _, doc in ipairs(documents) do
                check(not lfs.attributes(doc.path) and not lfs.attributes(doc.directory), "Clone, caches and reading data are fully removed")
            end
            check(#fixed.scanDownloads(API).targets == 0, "No local retry or document targets remain")
        end
        check(support.read(API.cache_path) == library and #support.requests == 0, "Library remains intact; no HTTP requests")
        io.write(("%s: deleted %d, skipped %d, failed %d, pending %d\n"):format(phase.name,stats.deleted,stats.skipped,stats.failed,stats.pending))
    end, debug.traceback)
    lfs.attributes = original_attributes
    support.teardown()
    if not ok then error(err) end
end
io.write(("%d device-copy cleanup checks passed; connected device was read only\n"):format(checks))
