-- Zotero is the source of imported annotations. This module never writes a PDF
-- or makes an HTTP write request, and never edits a sidecar outside ReaderUI.
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local Blitbuffer = require("ffi/blitbuffer")
local BaseUtil = require("ffi/util")
local _ = require("gettext")
local Annotations = {}
local CACHE_NAME = ".zotero-annotations.json"
local SOURCE = "zotero.koplugin"
local CONVERTER_VERSION = 2
local SUPPORTED = { highlight = "lighten", underline = "underscore", image = "zotero_region" }
local FIELDS = { "annotationType", "annotationPosition", "annotationText", "annotationComment",
    "annotationColor", "annotationPageLabel", "annotationSortIndex", "dateAdded", "dateModified" }

local chinese = {
    ["Fetching PDF annotations…"] = "正在获取 PDF 批注…",
    ["Checking annotation file…"] = "正在核对批注对应的文件…",
    ["Saving PDF annotations…"] = "正在保存 PDF 批注…",
    ["Annotations changed. Retrying…"] = "批注已变化，正在重试…",
    ["Synchronizing downloaded PDF annotations"] = "同步已下载 PDF 的批注",
    ["Refetch downloaded PDF annotations"] = "重新获取已下载 PDF 的批注",
    ["Refresh annotations"] = "更新批注",
    ["Refreshing PDF annotations"] = "正在更新 PDF 批注",
    ["PDF annotations updated."] = "PDF 批注已更新。",
    ["Area annotation"] = "区域批注",
    ["No comment."] = "无附属评论。",
    ["PDF annotations were not updated."] = "PDF 批注未更新。",
    ["Could not apply Zotero annotations."] = "未能显示 Zotero 批注。",
    ["Zotero annotations are displayed in original-page mode."] = "Zotero 批注支持原版页面显示，请关闭文字重排。",
    ["PDF annotations cached: %d; unchanged: %d; failed: %d"] = "PDF 批注已缓存：%d；未变化：%d；失败：%d",
    ["Unsupported annotations skipped: %d"] = "已跳过不支持的批注：%d",
    ["Cached annotations take effect when the PDF is next opened."] = "缓存批注将在下次打开 PDF 时生效。",
}
function Annotations.text(message)
    local language = type(_) == "table" and _.current_lang or ""
    if language:match("^zh_CN") or language:match("^zh_Hans") then return chinese[message] or _(message) end
    return _(message)
end

local function integer(value)
    return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
end
local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function array(value)
    if type(value) ~= "table" then return false end
    local count = 0
    for index in pairs(value) do
        if not integer(index) or index < 1 or index > #value then return false end
        count = count + 1
    end
    return count == #value
end
local function identity_valid(identity)
    return type(identity) == "table" and
        (type(identity.md5) == "string" and #identity.md5 == 32 and identity.md5:match("^%x+$")
        or identity.md5 == nil and integer(identity.version))
end
local function same_identity(a, b)
    if not identity_valid(a) or not identity_valid(b) then return false end
    if a.md5 or b.md5 then return a.md5 and b.md5 and a.md5:lower() == b.md5:lower() end
    return a.version == b.version
end
local function read_json(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local content = file:read("*a")
    file:close()
    local ok, value = pcall(JSON.decode, content)
    if not ok or type(value) ~= "table" then return nil, "Invalid annotation cache JSON" end
    return value
end
local function current_user(api)
    return tostring(api.getUserID()):match("^%s*(.-)%s*$")
end
local function write_json(path, value)
    local ok, content = pcall(JSON.encode, value)
    if not ok then return nil, "Could not encode PDF annotations" end
    local temporary = path .. ".tmp"
    local file, err = io.open(temporary, "wb")
    if not file then return nil, err end
    local written, write_err = file:write(content)
    local closed, close_err = file:close()
    if not written or not closed then os.remove(temporary); return nil, write_err or close_err end
    ok, err = os.rename(temporary, path)
    if not ok then os.remove(temporary) end
    return ok, err
end
local function emit(callback, stage, details)
    if callback then
        details = details or {}
        details.stage = stage
        pcall(callback, details)
    end
end

local function parse_position(value)
    if type(value) ~= "string" then return nil, "Missing annotation position" end
    local ok, position = pcall(JSON.decode, value)
    if not ok or type(position) ~= "table" or not integer(position.pageIndex) then
        return nil, "Invalid annotation page position"
    end
    local function rects_valid(rects)
        if not array(rects) or #rects == 0 then return false end
        for _, rect in ipairs(rects) do
            if not array(rect) or #rect ~= 4 or not finite(rect[1]) or not finite(rect[2])
                or not finite(rect[3]) or not finite(rect[4]) or rect[3] <= rect[1] or rect[4] <= rect[2] then
                return false
            end
        end
        return true
    end
    if not rects_valid(position.rects) or position.nextPageRects ~= nil and not rects_valid(position.nextPageRects) then
        return nil, "Invalid annotation rectangles"
    end
    return position
end

-- Copy only display fields; never allow an unexpected response or damaged cache
-- to masquerade as the authoritative empty list that removes imported items.
function Annotations.normalize(snapshot, user_id, key)
    if type(snapshot) ~= "table" or snapshot.format ~= 1 or snapshot.user_id ~= tostring(user_id)
        or snapshot.attachment_key ~= key or not integer(snapshot.library_version)
        or not identity_valid(snapshot.file_identity) or not array(snapshot.items) then
        return nil, "Invalid PDF annotation snapshot"
    end
    local result = { format = 1, user_id = snapshot.user_id, attachment_key = key,
        library_version = snapshot.library_version, file_identity = snapshot.file_identity, items = {} }
    local seen = {}
    for _, item in ipairs(snapshot.items) do
        if type(item) ~= "table" or type(item.key) ~= "string" or not item.key:match("^[A-Z0-9]+$")
            or seen[item.key] or not integer(item.version) or item.version > snapshot.library_version
            or type(item.data) ~= "table" or item.data.itemType ~= "annotation"
            or item.data.parentItem ~= key or item.data.deleted == true or item.data.deleted == 1
            or type(item.data.annotationType) ~= "string" then
            return nil, "Invalid annotation object in PDF snapshot"
        end
        seen[item.key] = true
        local data = { itemType = "annotation", parentItem = key }
        for _, field in ipairs(FIELDS) do
            local value = item.data[field]
            if value ~= nil and type(value) ~= "string" then return nil, "Invalid annotation field: " .. field end
            data[field] = value
        end
        if SUPPORTED[data.annotationType] then
            local position, err = parse_position(data.annotationPosition)
            if not position then return nil, item.key .. ": " .. err end
        end
        result.items[#result.items + 1] = { key = item.key, version = item.version, data = data }
    end
    return result
end

function Annotations.readCache(api, key)
    local directory, _, err = api.getDirAndPath(key)
    if not directory then return nil, err end
    if not lfs.attributes(directory .. "/" .. CACHE_NAME) then return nil end
    local snapshot
    snapshot, err = read_json(directory .. "/" .. CACHE_NAME)
    if not snapshot then return nil, err end
    return Annotations.normalize(snapshot, current_user(api), key)
end

local function local_identity(api, key)
    local directory, path = api.getDirAndPath(key)
    if not directory or not path then return nil end
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" or attr.size == 0 then return nil end
    local receipt = read_json(directory .. "/.zotero-cache.json")
    if not receipt then return nil end
    local identity = receipt.md5 and { md5 = receipt.md5 } or { version = receipt.version }
    if identity_valid(identity) then return identity end
end

-- Opening a cached document is offline. Only the plugin's explicit open path
-- calls this method, and only a missing/incompatible cache triggers a fetch.
function Annotations.ensureCached(api, key, callback, force)
    local item = api.getItems()[key]
    if not item or item.data.contentType ~= "application/pdf" then return nil, nil, "unsupported" end
    local cache = Annotations.readCache(api, key)
    if not force and cache and same_identity(cache.file_identity, local_identity(api, key)) then
        return cache, nil, "unchanged"
    end
    local snapshot, err = api.fetchAttachmentAnnotations(key, callback)
    if not snapshot then return nil, err end
    snapshot, err = Annotations.normalize(snapshot, current_user(api), key)
    if not snapshot then return nil, err end
    if cache and snapshot.library_version < cache.library_version then
        return nil, "The annotation library version went backwards"
    end
    local directory = api.getDirAndPath(key)
    emit(callback, "saving_annotations")
    local ok
    ok, err = write_json(directory .. "/" .. CACHE_NAME, snapshot)
    if not ok then return nil, "Could not save PDF annotations: " .. tostring(err) end
    return snapshot, nil, "updated"
end

local function versions_equal(items, versions)
    local count = 0
    for _ in pairs(versions) do count = count + 1 end
    for _, item in ipairs(items) do if versions[item.key] ~= item.version then return false end end
    return #items == count
end

function Annotations.refreshDownloaded(api, callback, force)
    local stats = { updated = 0, unchanged = 0, failed = 0, unsupported = 0, errors = {} }
    local items, targets, versions = api.getItems(), {}, {}
    for key, item in pairs(items) do
        if item.data.itemType == "attachment" and item.data.contentType == "application/pdf"
            and (item.data.linkMode == "imported_file" or item.data.linkMode == "imported_url")
            and api.getAttachmentStatus(key) ~= "not_downloaded" then
            targets[#targets + 1] = key
            versions[key] = {}
        end
    end
    table.sort(targets)
    for key, item in pairs(items) do
        if item.data.itemType == "annotation" and versions[item.data.parentItem] then
            versions[item.data.parentItem][key] = item.version
        end
    end
    local library_version = api.getLibraryVersion()
    for index, key in ipairs(targets) do
        emit(callback, "annotation_files", { completed = index - 1, total = #targets })
        local ok, cache, err, state = pcall(function()
            local previous = Annotations.readCache(api, key)
            local metadata_identity = items[key].data.md5 and { md5 = items[key].data.md5 } or { version = items[key].version }
            if not force and previous and (previous.library_version > library_version
                or same_identity(previous.file_identity, metadata_identity) and versions_equal(previous.items, versions[key])) then
                return previous, nil, "unchanged"
            end
            return Annotations.ensureCached(api, key, callback, true)
        end)
        if not ok then err, cache = tostring(cache), nil end
        if not cache then
            stats.failed = stats.failed + 1
            stats.errors[#stats.errors + 1] = key .. ": " .. tostring(err)
        else
            stats[state] = stats[state] + 1
            for _, item in ipairs(cache.items) do
                if not SUPPORTED[item.data.annotationType] then stats.unsupported = stats.unsupported + 1 end
            end
        end
        emit(callback, "annotation_files", { completed = index, total = #targets })
    end
    return stats
end

function Annotations.summary(stats)
    local lines = { Annotations.text("PDF annotations cached: %d; unchanged: %d; failed: %d")
        :format(stats.updated, stats.unchanged, stats.failed) }
    if stats.unsupported > 0 then lines[#lines + 1] = Annotations.text("Unsupported annotations skipped: %d"):format(stats.unsupported) end
    lines[#lines + 1] = Annotations.text("Cached annotations take effect when the PDF is next opened.")
    for index = 1, math.min(5, #stats.errors) do lines[#lines + 1] = stats.errors[index] end
    if #stats.errors > 5 then lines[#lines + 1] = ("… (%d)"):format(#stats.errors) end
    return table.concat(lines, "\n")
end

-- Gregorian civil date -> Unix time, independent of the device's timezone/DST.
local function local_date(iso)
    if iso == nil then return "" end
    local y, m, d, h, minute, second, suffix = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
    y, m, d, h, minute, second = tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(minute), tonumber(second)
    if not y or m < 1 or m > 12 or d < 1 or h > 23 or minute > 59 or second > 59 then return nil, "Invalid annotation date" end
    local leap = y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
    local month_days = {31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    if d > month_days[m] then return nil, "Invalid annotation date" end
    suffix = suffix:gsub("^%.%d+", "")
    local offset = 0
    if suffix ~= "Z" then
        local sign, oh, om = suffix:match("^([+-])(%d%d):(%d%d)$")
        if not sign or tonumber(oh) > 23 or tonumber(om) > 59 then return nil, "Invalid annotation timezone" end
        offset = (tonumber(oh) * 60 + tonumber(om)) * 60 * (sign == "+" and 1 or -1)
    end
    local year = y - (m <= 2 and 1 or 0)
    local era = math.floor(year / 400)
    local year_of_era = year - era * 400
    local day_of_year = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
    local days = era * 146097 + year_of_era * 365 + math.floor(year_of_era / 4)
        - math.floor(year_of_era / 100) + day_of_year - 719468
    return os.date("%Y-%m-%d %H:%M:%S", days * 86400 + h * 3600 + minute * 60 + second - offset)
end

local STANDARD_COLORS = { ["#ffd400"] = "yellow", ["#ff6666"] = "red", ["#5fb236"] = "green",
    ["#2ea8e5"] = "blue", ["#a28ae5"] = "purple", ["#e56eee"] = "purple",
    ["#f19837"] = "orange", ["#aaaaaa"] = "gray" }
local FALLBACK_COLORS = { yellow="#ffff00", red="#ff0000", green="#00ff00", blue="#0066ff",
    purple="#9900cc", orange="#ff9900", olive="#808000", cyan="#00ffff", gray="#808080" }
local function rgb(hex)
    if type(hex) == "string" and hex:match("^#%x%x%x%x%x%x$") then
        return tonumber(hex:sub(2,3),16), tonumber(hex:sub(4,5),16), tonumber(hex:sub(6,7),16)
    end
end
local function color_name(hex)
    if not hex then return "yellow" end
    hex = hex:lower()
    if STANDARD_COLORS[hex] then return STANDARD_COLORS[hex] end
    local r, g, b = rgb(hex)
    if not r then return "yellow" end
    local best, distance = "yellow", math.huge
    for name, value in pairs(Blitbuffer.HIGHLIGHT_COLORS or FALLBACK_COLORS) do
        local cr, cg, cb = rgb(value)
        if cr then
            local delta = (r-cr)^2 + (g-cg)^2 + (b-cb)^2
            if delta < distance or delta == distance and name < best then best, distance = name, delta end
        end
    end
    return best
end

function Annotations.convert(snapshot, document)
    local result, skipped, dimensions = {}, 0, {}
    local function boxes_for(page, rects)
        local size = dimensions[page]
        local count = document.info and document.info.number_of_pages
        if count and page > count then error("Annotation page exceeds PDF page count") end
        if not size then
            size = document:getNativePageDimensions(page)
            if not size or not finite(size.w) or not finite(size.h) or size.w <= 0 or size.h <= 0 then
                error("Could not read PDF page dimensions")
            end
            dimensions[page] = size
        end
        local boxes = {}
        for _, rect in ipairs(rects) do
            if rect[1] < -0.5 or rect[2] < -0.5 or rect[3] > size.w + 0.5 or rect[4] > size.h + 0.5 then
                error("Annotation is outside the standard PDF page; special page geometry is unsupported")
            end
            boxes[#boxes + 1] = { x = rect[1], y = size.h - rect[4], w = rect[3] - rect[1], h = rect[4] - rect[2] }
        end
        return boxes
    end
    local ok, err = pcall(function()
        for _, item in ipairs(snapshot.items) do
            local data = item.data
            if not SUPPORTED[data.annotationType] then skipped = skipped + 1
            else
                local position, position_err = parse_position(data.annotationPosition)
                if not position then error(position_err) end
                local page = position.pageIndex + 1
                local boxes = boxes_for(page, position.rects)
                local datetime, date_err = local_date(data.dateAdded or data.dateModified)
                if not datetime then error(date_err) end
                local updated
                updated, date_err = local_date(data.dateModified)
                if not updated then error(date_err) end
                local function endpoint(box, page_no, last)
                    return { page = page_no, zoom = 1, rotation = 0,
                        x = box.x + box.w * (last and 0.75 or 0.25),
                        y = box.y + box.h * (last and 0.75 or 0.25) }
                end
                local pos0, pos1 = endpoint(boxes[1], page, false), endpoint(boxes[#boxes], page, true)
                local converted = { page = page, pageno = page, pageref = data.annotationPageLabel,
                    pos0 = pos0, pos1 = pos1, pboxes = boxes, drawer = SUPPORTED[data.annotationType],
                    color = color_name(data.annotationColor), text = data.annotationText or "",
                    note = data.annotationComment ~= "" and data.annotationComment or nil,
                    datetime = datetime, datetime_updated = updated ~= datetime and updated or nil,
                    zotero_source = { plugin = SOURCE, user_id = snapshot.user_id, attachment_key = snapshot.attachment_key,
                        annotation_key = item.key, version = item.version, sort_index = data.annotationSortIndex,
                        annotation_type = data.annotationType } }
                if data.annotationType == "image" and converted.text == "" then
                    converted.text = Annotations.text("Area annotation")
                end
                if position.nextPageRects then
                    local following = boxes_for(page + 1, position.nextPageRects)
                    local start2 = endpoint(following[1], page + 1, false)
                    local end2 = endpoint(following[#following], page + 1, true)
                    converted.ext = {
                        [page] = { pos0 = pos0, pos1 = pos1, pboxes = boxes },
                        [page+1] = { pos0 = start2, pos1 = end2, pboxes = following },
                    }
                    converted.pos1 = end2
                end
                result[#result + 1] = converted
            end
        end
    end)
    if not ok then return nil, tostring(err) end
    return result, nil, skipped
end

local function owned(item, user_id, key)
    -- Cloud imports always have a drawer. Keep bookmarks local even if an
    -- older adapter attached a retained selection's source marker to them.
    if not item.drawer then return false end
    local source = item.zotero_source
    return type(source) == "table" and source.plugin == SOURCE
        and source.user_id == user_id and source.attachment_key == key
end

-- Resolve only this account's managed storage paths. Opening an arbitrary PDF
-- or a document belonging to another account must not touch its annotations.
function Annotations.managedKey(api, document)
    if not document or not document.is_pdf or type(document.file) ~= "string" then return nil end
    -- Browse may use ./zotero/... while history/filemanager use absolute paths.
    -- Resolve existing paths so every entry point recognizes the same document,
    -- without accepting a similarly named PDF outside this account's storage.
    local storage, file = BaseUtil.realpath(api.storage_dir), BaseUtil.realpath(document.file)
    if not storage or not file then return nil end
    local prefix = storage .. "/"
    if file:sub(1, #prefix) ~= prefix then return nil end
    local key = file:sub(#prefix + 1):match("^([A-Z0-9]+)/[^/]+$")
    if key then
        local _, path = api.getDirAndPath(key)
        if path and BaseUtil.realpath(path) == file then return key end
    end
end

-- Instance-local adapter: cloud boxes are authoritative, even without an OCR
-- text layer. Ordinary KOReader annotations still use the original methods.
function Annotations.installAdapter(ui, user_id, key)
    local document = ui.document
    local state = document._zotero_adapter
    if not state then
        local original_boxes, original_compare = document.getPageBoxesFromPositions, document.comparePositions
        if type(original_boxes) ~= "function" or type(original_compare) ~= "function" then
            error("This PDF reader does not provide annotation geometry methods")
        end
        state = { user_id = user_id, key = key, positions = {}, boxes = {} }
        document.getPageBoxesFromPositions = function(doc, page, pos0, pos1)
            if state.positions[pos0] and state.positions[pos1] then
                if state.file_matches == false or doc.configurable and doc.configurable.text_wrap == 1 then return nil end
                return state.boxes[pos0] and state.boxes[pos0][page]
            end
            return original_boxes(doc, page, pos0, pos1)
        end
        document.comparePositions = function(doc, a, b)
            if state.positions[a] or state.positions[b] then
                if a.page ~= b.page then return a.page < b.page and 1 or -1 end
                if a.y ~= b.y then return a.y < b.y and 1 or -1 end
                if a.x ~= b.x then return a.x < b.x and 1 or -1 end
                return 0
            end
            return original_compare(doc, a, b)
        end
        document._zotero_adapter = state
    end
    state.user_id, state.key = user_id, key
    local original_sort = ui.annotation.isItemInPositionOrderPaging
    if original_sort and not ui.annotation._zotero_sort_adapter then
        ui.annotation.isItemInPositionOrderPaging = function(reader, a, b)
            if a == b then return false end
            if a.page == b.page and (not a.drawer or not b.drawer) then
                if (not a.drawer) ~= (not b.drawer) then return not a.drawer end
                return (a.datetime or "") < (b.datetime or "")
            end
            if a.page == b.page and a.drawer and b.drawer then
                local ao, bo = owned(a, user_id, key), owned(b, user_id, key)
                -- Keep a consistent total order even if PDF text order differs
                -- from geometric order (e.g. columns). Native items keep their
                -- own ordering within the page, following the cloud items.
                if ao ~= bo then return ao end
                if ao then
                    local ai, bi = a.zotero_source.sort_index or "", b.zotero_source.sort_index or ""
                    if ai ~= bi then return ai < bi end
                    return a.zotero_source.annotation_key < b.zotero_source.annotation_key
                end
            end
            return original_sort(reader, a, b)
        end
        ui.annotation._zotero_sort_adapter = true
    end
    local original_match = ui.annotation.getMatchFunc
    if original_match and not ui.annotation._zotero_match_adapter then
        ui.annotation.getMatchFunc = function(reader)
            local match = original_match(reader)
            return function(a, b)
                local ao, bo = owned(a, user_id, key), owned(b, user_id, key)
                if ao or bo then return ao and bo and a.zotero_source.annotation_key == b.zotero_source.annotation_key end
                return match(a, b)
            end
        end
        ui.annotation._zotero_match_adapter = true
    end
    if ui.highlight and type(ui.highlight.extendSelection) == "function" and not ui.highlight._zotero_extend_adapter then
        local extend = ui.highlight.extendSelection
        ui.highlight.extendSelection = function(reader, ...)
            local item = ui.annotation.annotations[reader.highlight_idx]
            local source = item and owned(item, user_id, key) and item.zotero_source
            local result = extend(reader, ...)
            -- Native extension replaces the item via selected_text and drops
            -- unknown fields. Carry its explicit identity through that path.
            if source and reader.selected_text then reader.selected_text.zotero_source = source end
            return result
        end
        ui.highlight._zotero_extend_adapter = true
    end
    if ui.highlight and type(ui.annotation.addItem) == "function" and not ui.annotation._zotero_add_adapter then
        local add = ui.annotation.addItem
        ui.annotation.addItem = function(reader, item)
            local selection = ui.highlight.selected_text
            -- Native saveHighlight reuses the selection's endpoint objects.
            -- A dismissed More-menu can retain that selection; bookmarks and
            -- unrelated highlights must not inherit its cloud identity.
            if selection and owned(selection, user_id, key) and item.drawer
                and item.pos0 and item.pos1
                and item.pos0 == selection.pos0 and item.pos1 == selection.pos1 then
                item.zotero_source = selection.zotero_source
            end
            return add(reader, item)
        end
        ui.annotation._zotero_add_adapter = true
    end
    if ui.highlight and type(ui.highlight.getPageSavedHighlights) == "function" and not ui.highlight._zotero_pages_adapter then
        local get_highlights = ui.highlight.getPageSavedHighlights
        ui.highlight.getPageSavedHighlights = function(reader, page)
            local highlights, offset = get_highlights(reader, page)
            local indices = {}
            for index, item in ipairs(ui.annotation.annotations) do
                if item.drawer and item.pos0.page <= page and page <= item.pos1.page then
                    indices[#indices + 1] = index
                end
            end
            -- An extended highlight can precede this page's bookmarks. The
            -- native offset alone then points later highlights at wrong items.
            for index, item in ipairs(highlights) do
                local copy = {}
                for field, value in pairs(item) do copy[field] = value end
                copy.parent = indices[index]
                highlights[index] = copy
            end
            return highlights, offset
        end
        ui.highlight._zotero_pages_adapter = true
    end
    if ui.highlight and type(ui.highlight.showHighlightNoteOrDialog) == "function" and not ui.highlight._zotero_region_note_adapter then
        local show = ui.highlight.showHighlightNoteOrDialog
        ui.highlight.showHighlightNoteOrDialog = function(reader, index)
            local item = ui.annotation.annotations[index]
            if item and owned(item, user_id, key) and item.zotero_source.annotation_type == "image" then
                local TextViewer = require("ui/widget/textviewer")
                require("ui/uimanager"):show(TextViewer:new{
                    title = Annotations.text("Area annotation"), show_menu = false,
                    text = item.note or Annotations.text("No comment."), add_default_buttons = true,
                })
                return true
            end
            return show(reader, index)
        end
        ui.highlight._zotero_region_note_adapter = true
    end
    if ui.view and type(ui.view.drawHighlightRect) == "function" and not ui.view._zotero_region_draw_adapter then
        local draw = ui.view.drawHighlightRect
        ui.view.drawHighlightRect = function(view, bb, x, y, rect, drawer, color, note)
            if drawer == "zotero_region" then
                -- Keep the original image visible; native hit testing still
                -- covers the entire rectangle, including its unpainted center.
                color = color or Blitbuffer.COLOR_BLACK
                local width = math.max(1, require("device").screen:scaleBySize(2))
                width = math.min(width, rect.w / 2, rect.h / 2)
                if Blitbuffer.isColor8(color) then
                    bb:paintBorder(rect.x, rect.y, rect.w, rect.h, width, color)
                else
                    bb:paintBorderRGB32(rect.x, rect.y, rect.w, rect.h, width, color)
                end
                return
            end
            return draw(view, bb, x, y, rect, drawer, color, note)
        end
        ui.view._zotero_region_draw_adapter = true
    end
    if ui.view and type(ui.view.drawPageSavedHighlight) == "function" and not ui.view._zotero_draw_adapter then
        local draw = ui.view.drawPageSavedHighlight
        ui.view.drawPageSavedHighlight = function(view, ...)
            if document.configurable and document.configurable.text_wrap == 1 then view.highlight.page_boxes = {} end
            return draw(view, ...)
        end
        ui.view._zotero_draw_adapter = true
    end
    -- A cached native page must not bypass the reflow guard after toggling modes.
    if ui.view and ui.view.highlight then ui.view.highlight.page_boxes = {} end
end

function Annotations.reindex(ui)
    local state = ui.document and ui.document._zotero_adapter
    if not state then return end
    state.positions, state.boxes = {}, {}
    for _, item in ipairs(ui.annotation.annotations) do
        if owned(item, state.user_id, state.key) and item.drawer and item.pos0 and item.pos1 then
            state.positions[item.pos0], state.positions[item.pos1] = true, true
            state.boxes[item.pos0] = { [item.page] = item.pboxes }
            if item.ext then
                for page, part in pairs(item.ext) do
                    state.positions[part.pos0], state.positions[part.pos1] = true, true
                    state.boxes[part.pos0] = { [page] = part.pboxes }
                end
            end
        end
    end
end

-- Called after ReaderAnnotation:onReadSettings (including legacy migration).
-- The normal ReaderUI SaveSettings/flush persists the merged list and receipt
-- together; failed flushes cannot leave a separate 'applied' cursor on disk.
function Annotations.applyToReader(api, ui, config, key)
    if not ui.annotation or type(ui.annotation.annotations) ~= "table" then
        return nil, "Reader annotations are not initialized"
    end
    local identity, user_id = local_identity(api, key), current_user(api)
    local has_imports = false
    for _, item in ipairs(ui.annotation.annotations) do
        if owned(item, user_id, key) then has_imports = true; break end
    end
    -- Keep the previous successful projection usable if fetching/decoding the
    -- independent cache failed. Never draw it over a replacement PDF, though.
    if has_imports then
        local ok, adapter_err = pcall(Annotations.installAdapter, ui, user_id, key)
        if not ok then return nil, tostring(adapter_err) end
        Annotations.reindex(ui)
        local applied = config:readSetting("zotero_annotations_applied")
        ui.document._zotero_adapter.file_matches = type(applied) == "table"
            and applied.user_id == user_id and applied.attachment_key == key and same_identity(applied.file_identity, identity) or false
    end
    local cache, err = Annotations.readCache(api, key)
    if not cache then
        if not err and has_imports and not ui.document._zotero_adapter.file_matches then
            err = "Could not confirm the PDF identity of previously imported annotations"
        end
        return nil, err
    end
    if not same_identity(cache.file_identity, identity) then
        return nil, "Cached annotations belong to a different PDF file; download the current attachment"
    end
    local imported, skipped
    imported, err, skipped = Annotations.convert(cache, ui.document)
    if not imported then return nil, err end
    local combined = {}
    for _, item in ipairs(ui.annotation.annotations) do
        if not owned(item, cache.user_id, key) then combined[#combined + 1] = item end
    end
    for _, item in ipairs(imported) do combined[#combined + 1] = item end
    -- Prepare the adapter before publishing or scheduling the native sorter.
    local ok
    ok, err = pcall(Annotations.installAdapter, ui, cache.user_id, key)
    if not ok then return nil, tostring(err) end
    local previous_annotations = config:readSetting("annotations")
    local previous_applied = config:readSetting("zotero_annotations_applied")
    ok, err = pcall(function()
        config:saveSetting("annotations", combined)
        config:saveSetting("zotero_annotations_applied", { user_id = cache.user_id, attachment_key = key,
            library_version = cache.library_version, file_identity = cache.file_identity, converter_version = CONVERTER_VERSION })
    end)
    if not ok then
        -- LuaSettings changes are in memory here. Roll back both fields even if
        -- the failing saveSetting cannot be called again; native flush is later.
        config.data.annotations = previous_annotations
        config.data.zotero_annotations_applied = previous_applied
        return nil, "Could not save imported annotations: " .. tostring(err)
    end
    ui.annotation.annotations = combined
    Annotations.reindex(ui)
    ui.document._zotero_adapter.file_matches = true
    ui:registerPostReaderReadyCallback(function()
        ui.annotation:updateAnnotations(true, true)
        if ui.view and ui.view.highlight then ui.view.highlight.page_boxes = {} end
        if ui.onAnnotationsModified then ui:onAnnotationsModified() end
    end)
    return { imported = #imported, unsupported = skipped }
end

return Annotations
