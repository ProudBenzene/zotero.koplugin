-- Exercise real KOReader mutation/menu/PDF methods with fake native PDF and
-- widget backends. No account, network, MuPDF renderer or hardware is required.
-- Usage: pandoc lua tests/annotationpolicy-integration.lua /path/to/koreader/frontend
package.path = "./?.lua;./tests/?.lua;" .. package.path
local source = assert(arg[1], "Supply the KOReader frontend directory")
local support = require("tests/support")
local API = support.setup()
local Annotations = require("annotations")
local Widget = require("ui/widget/container/widgetcontainer")
local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end
local function button(widget, text)
    for _, row in ipairs(widget.buttons or widget.buttons_table or {}) do
        for _, entry in ipairs(row) do if entry.text == text then return entry end end
    end
    error("Missing button: " .. text)
end
local function last() return support.UI.shown[#support.UI.shown] end

local ok, err = xpcall(function()
    unpack = unpack or table.unpack
    bit = {rshift = function(value, bits) return math.floor(value / 2^bits) end}
    local globals = { highlight_write_into_pdf = true, device_id = "this-device", bookmarks_items_per_page = 10 }
    G_reader_settings = {
        readSetting = function(_, key, default) if globals[key] == nil then return default end; return globals[key] end,
        saveSetting = function(_, key, value) globals[key] = value end,
        isTrue = function(_, key) return globals[key] == true end,
        hasNot = function(_, key) return globals[key] == nil end,
        nilOrTrue = function(_, key) return globals[key] ~= false end,
    }
    G_defaults = { readSetting = function() return 0 end }
    package.loaded.logger = { dbg = function() end, info = function() end, warn = function() end }
    package.loaded.dbg = { dassert = assert }
    package.loaded.random = { uuid = function() return "this-device" end }
    package.loaded.ffi = { C = {} }
    package.loaded["ffi/drawcontext"] = { new = function() return {} end }
    package.loaded["document/document"] = Widget:extend{ close = function(self) self.closed = true end }
    package.loaded["document/documentregistry"] = { getReferenceCount = function() return 1 end }
    package.loaded["ui/translator"] = { genSettingsMenu = function() return {} end }
    package.loaded["ui/event"] = { new = function(_, name, ...) return { name = name, args = {...} } end }
    package.loaded["ui/widget/textboxwidget"] = { PTF_BOLD_START = "", PTF_BOLD_END = "", PTF_HEADER = "" }
    package.loaded.docsettings = { getSidecarDir = function(_, path) return path .. ".sdr" end }
    local util = require("util")
    util.tableDeepCopy, util.cleanupSelectedText = copy, function(value) return value end
    util.getFileNameSuffix = function(path) return path:match("%.([^%.]+)$") end
    local ffiutil = require("ffi/util")
    ffiutil.template = function(value, ...)
        local arguments = {...}
        return (value:gsub("%%(%d+)", function(index) return tostring(arguments[tonumber(index)]) end))
    end
    ffiutil.orderedPairs = function(values)
        local names = {}; for name in pairs(values) do names[#names + 1] = name end; table.sort(names)
        local index = 0
        return function() index = index + 1; local name = names[index]; if name then return name, values[name] end end
    end
    support.GetText.pgettext = function(_, value) return value end
    support.GetText.ngettext = function(one, many, count) return count == 1 and one or many end
    local device = require("device")
    device.hasClipboard, device.canShareText, device.isTouchDevice = function() return true end, function() return false end, function() return true end
    device.screen.getSize = function() return { w = 600, h = 800 } end
    device.input = { setClipboardText = function(value) device.clipboard = value end }
    local buffer = require("ffi/blitbuffer")
    buffer.gray, buffer.colorFromName = function(value) return value end, function(value) return value end
    local Menu = require("ui/widget/menu")
    Menu.getItemFontSize = function() return 16 end
    Menu.setTitleBarLeftIcon = function(self, value) self.left_icon = value end
    local menu_init = Menu.init
    Menu.init = function(self)
        menu_init(self)
        self.perpage = self.items_per_page or 10
    end
    Menu.switchItemTable = function(self, title, items, itemnumber)
        self.title, self.item_table = title or self.title, items or self.item_table
        if itemnumber == nil then self.page = 1
        elseif itemnumber >= 0 then self.page = math.max(1, math.ceil(math.min(itemnumber, #self.item_table) / self.perpage)) end
        -- Native Menu:updateItems assigns idx only to rows on the displayed page.
        local first = (self.page - 1) * self.perpage + 1
        for i = first, math.min(first + self.perpage - 1, #self.item_table) do self.item_table[i].idx = i end
    end
    Menu.perpage = 10
    package.loaded["ui/bidi"] = {
        mirroredUILayout = function() return false end,
        ltr = function(value) return value end,
        flipDirectionIfMirroredUILayout = function(value) return value end,
        getArrowLabels = function() return "Previous", "Next", "First", "Last" end,
    }
    local function load(name)
        local file = source .. "/" .. name .. ".lua"
        local input = assert(io.open(file, "rb")); local code = input:read("*a"); input:close()
        for dependency in code:gmatch('require%("([^"]+)"%)') do
            if not package.loaded[dependency] and not package.preload[dependency] then
                package.preload[dependency] = function() return Widget end
            end
        end
        return dofile(file)
    end
    local ReaderAnnotation = load("apps/reader/modules/readerannotation")
    local ReaderHighlight = load("apps/reader/modules/readerhighlight")
    local ReaderBookmark = load("apps/reader/modules/readerbookmark")
    local PdfDocument = load("document/pdfdocument")
    local original_save, original_delete = PdfDocument.saveHighlight, ReaderHighlight.deleteHighlight
    local original_bookmark_index = ReaderBookmark.getBookmarkItemIndex
    local plugin = support.plugin()
    local attachment = support.attachment("ATTACH01", "paper.pdf", false)
    attachment.data.md5 = string.rep("0", 32)
    support.seed({ ATTACH01 = attachment })
    local directory, path = API.getDirAndPath("ATTACH01")
    assert(support.makePath(directory)); support.write(path, "unchanged PDF bytes")
    support.write(directory .. "/.zotero-cache.json", support.JSON.encode({ md5 = attachment.data.md5, version = 10 }))
    local function cloud_item(key, kind, text)
        return { key = key, version = 10, data = {
            itemType = "annotation", parentItem = "ATTACH01", annotationType = kind or "highlight",
            annotationText = text or "Cloud text", annotationComment = "Cloud comment", annotationColor = "#2ea8e5",
            annotationPosition = support.JSON.encode({ pageIndex = 0, rects = {{10, 100, 100, 120}} }),
            annotationSortIndex = key, dateAdded = "2026-10-08T04:00:00Z", dateModified = "2026-10-08T04:00:00Z",
        } }
    end
    local function cache(items, version)
        support.write(directory .. "/.zotero-annotations.json", support.JSON.encode({ format = 1, user_id = "123",
            attachment_key = "ATTACH01", library_version = version or 10, file_identity = { md5 = attachment.data.md5 }, items = items }))
    end
    local ui = { paging = true, callbacks = {}, menu = { registerToMainMenu = function() end },
        toc = { getTocTitleByPage = function() return "Chapter" end },
        link = { addCurrentLocationToStack = function() end },
    }
    ui.registerPostInitCallback = function() end
    ui.registerPostReaderReadyCallback = function(self, callback) self.callbacks[#self.callbacks + 1] = callback end
    ui.onAnnotationsModified = function() Annotations.reindex(ui) end
    ui.handleEvent = function(self, event)
        if event.name == "AnnotationsModified" then self.annotation:onAnnotationsModified(event.args[1]); Annotations.reindex(self) end
    end
    local native_writes, native_pages, embedded_reads = 0, 0, 0
    ui.document = PdfDocument:extend{
        file = path, info = { number_of_pages = 2, has_pages = true }, configurable = { text_wrap = 0 },
        getNativePageDimensions = function() return { w = 600, h = 800 } end,
        hasHiddenFlows = function() return false end,
        comparePositions = function(_, a, b) return a.x < b.x and 1 or a.x == b.x and 0 or -1 end,
        getPageBoxesFromPositions = function() return {{x = 1, y = 1, w = 20, h = 10}} end,
        getTextFromPositions = function() return { text = "Extended local text", pboxes = {{x = 1, y = 1, w = 20, h = 10}} } end,
        getEmbeddedAnnotations = function() embedded_reads = embedded_reads + 1; return {} end,
        _document = {
            openPage = function() native_pages = native_pages + 1; error("Managed PDF reached native mutation") end,
            writeDocument = function(_, file) native_writes = native_writes + 1; support.write(file, "modified PDF bytes") end,
        },
    }
    ui.view = { highlight = { saved_drawer = "lighten", saved_color = "gray", temp = {}, note_mark = false },
        footer = { maybeUpdateFooter = function() end }, state = { page = 1 },
        dogear = { onSetDogearVisibility = function() end },
        flipping = { getRefreshRegion = function() return {} end },
    }
    ui.annotation = ReaderAnnotation:extend{ui = ui, document = ui.document, view = ui.view, annotations = {}}
    ui.highlight = ReaderHighlight:extend{ui = ui, document = ui.document, view = ui.view, dialog = ui}
    ui.highlight.setSelectionColor = function() end
    ui.highlight:init()
    ui.bookmark = ReaderBookmark:extend{ui = ui, document = ui.document, view = ui.view, dialog = ui,
        getCurrentPageNumber = function() return 1 end, gotoBookmark = function(self) self.jumped = true end,
        getDogearBookmarkIndex = function() return nil end,
    }
    ui.bookmark:init()
    local local_item = { page = 1, pos0 = {page = 1, x = 1, y = 1}, pos1 = {page = 1, x = 2, y = 2},
        drawer = "lighten", color = "gray", text = "Local text", note = "Local note", datetime = "2026-10-07 10:00:00" }
    local dogear = { page = 2, datetime = "2026-10-07 11:00:00" }
    ui.annotation.annotations = { local_item, dogear }
    local config = { data = { percent_finished = 0.65 }, readSetting = function(self, key) return self.data[key] end,
        saveSetting = function(self, key, value) self.data[key] = value end }
    cache({ cloud_item("ANNOT001"), cloud_item("REGION01", "image", "") })
    check(Annotations.applyToReader(API, ui, config, "ATTACH01"), "Apply the cloud snapshot")
    for _, callback in ipairs(ui.callbacks) do callback() end
    local cloud, cloud_index
    for i, item in ipairs(ui.annotation.annotations) do
        if item.zotero_source and item.zotero_source.annotation_key == "ANNOT001" then cloud, cloud_index = item, i end
    end
    local pos0, pos1, count = cloud.pos0, cloud.pos1, #ui.annotation.annotations
    do
        local original_items = ui.annotation.annotations
        for _, cloud_count in ipairs({10, 20}) do
            local paged_items = {}
            for i = 1, cloud_count do
                local item = copy(cloud)
                item.zotero_source.annotation_key = string.format("NAV%05d", i)
                item.zotero_source.sort_index = string.format("%05d", i)
                paged_items[i] = item
            end
            local paged_local = copy(local_item)
            paged_local.color = "blue"
            local local_index = cloud_count + 1
            paged_items[local_index], paged_items[local_index + 1] = paged_local, copy(dogear)
            ui.annotation.annotations = paged_items
            Annotations.reindex(ui)
            for _, color_filter in ipairs({false, true}) do
                ui.bookmark:onShowBookmark()
                if color_filter then
                    ui.bookmark:filterByHighlightColor()
                    last().callback("blue")
                end
                local paged_list = ui.bookmark.bookmark_menu[1]
                check(paged_list.page == 1 and paged_list.item_table[11].idx == nil
                    and paged_list.item_table[local_index].idx == nil, "Unvisited menu pages have no row indices")
                ui.bookmark:showBookmarkDetails(paged_list.item_table[10])
                for i = 11, local_index do
                    button(last(), "▶").callback()
                    if i == 11 and cloud_count > 10 then
                        check(paged_list.page == 2 and paged_list.item_table[i].idx == i
                            and last().title == "Zotero Annotation · Blue", "Cloud-to-cloud navigation renders the next menu page")
                    end
                end
                check(paged_list.page == math.ceil(local_index / 10) and paged_list.item_table[local_index].idx == local_index
                    and last().text:find("Local text", 1, true) and button(last(), "Edit text").enabled,
                    "Cloud-to-local navigation across menu pages opens editable native details")
                button(last(), "Previous").callback()
                check(paged_list.page == cloud_count / 10 and last().title == "Zotero Annotation · Blue",
                    "Native local-to-cloud navigation returns to the correct menu page")
                paged_list.close_callback()
            end
        end
        ui.annotation.annotations = original_items
        Annotations.reindex(ui)
        globals.bookmarks_items_per_page, globals.bookmarks_items_reverse_sorting = 2, true
        ui.bookmark:onShowBookmark()
        local reversed_list = ui.bookmark.bookmark_menu[1]
        check(reversed_list.page == 2 and reversed_list.item_table[2].idx == nil,
            "Reverse navigation starts with an unvisited previous menu page")
        ui.bookmark:showBookmarkDetails(reversed_list.item_table[3])
        button(last(), "◀").callback()
        check(reversed_list.page == 1 and reversed_list.item_table[2].idx == 2
            and last().text:find("Local text", 1, true) and button(last(), "Edit text").enabled,
            "Cloud-to-local navigation also renders the previous menu page")
        reversed_list.close_callback()
        globals.bookmarks_items_per_page, globals.bookmarks_items_reverse_sorting = 10, nil
        ui.bookmark:showBookmarkDetails(cloud_index)
        button(last(), "▶").callback()
        button(last(), "▶").callback()
        check(not ui.bookmark.bookmark_menu and last().text:find("Local text", 1, true)
            and button(last(), "Edit text").enabled, "Reader-only detail navigation works without a bookmark menu")
        last().close_callback()
    end
    local function filtered_list(color)
        ui.bookmark:onShowBookmark()
        ui.bookmark:filterByHighlightColor()
        last().callback(color)
        return ui.bookmark.bookmark_menu[1]
    end
    local filtered = filtered_list("gray")
    local row = filtered.item_table[1]
    local local_source_index = ui.annotation:getItemIndex(local_item)
    check(#filtered.item_table == 1 and row.idx == 1 and local_source_index ~= row.idx,
        "Color filtering renumbers a local row independently of its annotation index")
    ui.bookmark:showBookmarkDetails(row)
    check(last().text:find("Local text", 1, true) and button(last(), "Edit text").enabled,
        "A color-filtered local row opens its editable native details")
    check(ui.bookmark:getBookmarkItemIndex(row) == local_source_index,
        "Native bookmark operations resolve the filtered row by annotation identity")
    button(last(), "Edit text").callback()
    local input = last(); input.input = "Filtered local text"; button(input, "Save").callback()
    check(local_item.text == "Filtered local text" and cloud.text == "Cloud text",
        "Editing filtered local text updates only the selected annotation")
    button(last(), "Edit note").callback()
    input = last(); input.input = "Filtered local note"; button(input, "Save").callback()
    check(local_item.note == "Filtered local note" and cloud.note == "Cloud comment",
        "Editing a filtered local note updates only the selected annotation")
    last().close_callback()
    filtered:toggleSelectMode(); row.dim = true; filtered.select_count = 1
    filtered:onLeftButtonTap(); button(last(), "Delete note").callback(); last().ok_callback()
    check(local_item.note == nil and cloud.note == "Cloud comment" and last().text:find("updated: 1", 1, true)
        and last().text:find("skipped: 0", 1, true), "Filtered bulk note deletion updates the local note without skipping it")
    filtered.close_callback()

    local disposable = { page = 1, pos0 = {page = 1, x = 7, y = 7}, pos1 = {page = 1, x = 8, y = 8},
        drawer = "lighten", color = "red", text = "Disposable local text", datetime = "2026-10-07 12:00:00" }
    ui.annotation:addItem(disposable)
    filtered = filtered_list("red")
    row = filtered.item_table[1]
    check(#filtered.item_table == 1 and row.idx ~= ui.annotation:getItemIndex(disposable),
        "The filtered removal fixture has different display and source indices")
    filtered:toggleSelectMode(); row.dim = true; filtered.select_count = 1
    filtered:onLeftButtonTap(); button(last(), "Remove").callback(); last().ok_callback()
    check(#ui.annotation.annotations == count and not ui.annotation:getItemIndex(disposable)
        and ui.annotation.annotations[cloud_index] == cloud and ui.annotation:getItemIndex(local_item)
        and #filtered.item_table == 0, "Filtered bulk removal deletes only the selected local annotation")
    filtered.close_callback()

    globals.bookmarks_items_reverse_sorting = true
    filtered = filtered_list("blue")
    for _, candidate in ipairs(filtered.item_table) do
        if candidate.zotero_source.annotation_key == "ANNOT001" then row = candidate end
    end
    check(row.idx ~= cloud_index and #filtered.item_table == 2, "Reversed color filtering also renumbers cloud rows")
    ui.bookmark:showBookmarkDetails(row)
    check(last().title == "Zotero Annotation · Blue" and last().text:find("Cloud text", 1, true),
        "A reversed color-filtered cloud row keeps the correct read-only details")
    ui.bookmark:setHighlightedText(row, "Changed through filtered row", function() end)
    check(cloud.text == "Cloud text" and local_item.text == "Filtered local text",
        "Reversed color-filtered cloud editing is blocked without changing a local annotation")
    filtered:toggleSelectMode()
    for _, item in ipairs(filtered.item_table) do item.dim = true end
    filtered.select_count = #filtered.item_table
    filtered:onLeftButtonTap(); button(last(), "Remove").callback(); last().ok_callback()
    check(#ui.annotation.annotations == count and #filtered.item_table == 2 and last().text:find("skipped: 2", 1, true),
        "Reversed color-filtered bulk removal preserves all cloud annotations")
    filtered.close_callback()
    globals.bookmarks_items_reverse_sorting = nil
    for _, name in ipairs({"deleteHighlight", "editNote", "editHighlightStyle", "editHighlightColor", "updateHighlight", "startSelection"}) do
        ui.highlight[name](ui.highlight, cloud_index)
        check(#ui.annotation.annotations == count and cloud.pos0 == pos0 and cloud.pos1 == pos1, "Block native " .. name)
    end
    ui.highlight.highlight_idx = cloud_index
    ui.highlight:extendSelection()
    check(ui.annotation.annotations[cloud_index] == cloud, "Block native extension before removing the starting fragment")
    ui.highlight:updateHighlightPaging(cloud, 0, -1)
    check(cloud.pos0 == pos0, "Block the lower-level boundary method")
    for _, name in ipairs({"removeItem", "removeItemByIndex", "deleteItemNote", "setBookmarkNote", "editHighlightedText", "setHighlightedText"}) do
        local value = (name == "removeItem" or name == "deleteItemNote") and copy(cloud) or cloud_index
        ui.bookmark[name](ui.bookmark, value, "Changed", function() end)
        check(cloud.note == "Cloud comment" and cloud.text == "Cloud text" and #ui.annotation.annotations == count, "Block bookmark " .. name)
    end
    ui.annotation:addItem(copy(cloud))
    check(#ui.annotation.annotations == count, "Reject native insertion of a copied cloud item")
    ui.highlight:showHighlightNoteOrDialog(cloud_index)
    check(last().title == "Zotero Annotation · Blue" and last().text:find("Cloud comment", 1, true), "Cloud comment viewer identifies Zotero and its source color")
    button(last(), "…").callback()
    local more = last()
    for _, text in ipairs({"Extend", "Highlight", "Add note"}) do
        check(button(more, text).enabled == false, "Disable cloud More-menu " .. text)
        button(more, text).callback()
    end
    check(button(more, "Copy").enabled == true and button(more, "Dictionary").callback, "Keep copy and dictionary actions")
    button(more, "Copy").callback()
    check(device.clipboard == "Cloud text", "Native clipboard still copies cloud text")
    ui.highlight.selected_text = copy(cloud)
    ui.highlight:saveHighlight()
    check(#ui.annotation.annotations == count, "Retained cloud selection cannot be saved as a local duplicate")
    ui.highlight.selected_text = nil
    local menus = {}
    ui.highlight:addToMainMenu(menus)
    local batch, pdf_menu
    for _, item in ipairs(menus.highlight_options.sub_item_table) do
        if item.text == "Apply current style and color to all highlights" then batch = item end
        for _, child in ipairs(item.sub_item_table or {}) do if child.text == "Write all highlights into PDF file" then pdf_menu = item end end
    end
    check(pdf_menu and not pdf_menu.enabled_func(), "Disable PDF-write settings and batch menu")
    for _, item in ipairs(pdf_menu.sub_item_table) do
        item.callback(); item.hold_callback()
    end
    check(globals.highlight_write_into_pdf == true, "Protected menu leaves the global preference intact")
    ui.view.highlight.saved_drawer, ui.view.highlight.saved_color = "underscore", "yellow"
    batch.callback(); last().ok_callback()
    check(local_item.drawer == "underscore" and local_item.color == "yellow", "Apply batch style to local highlights")
    check(cloud.drawer == "lighten" and cloud.color == "blue" and last().text:find("skipped: 2", 1, true), "Batch style keeps cloud fields and reports skips")
    ui.highlight.highlight_write_into_pdf = true
    ui.highlight:writePdfAnnotation("delete", cloud)
    ui.document:saveHighlight(1, local_item); ui.document:deleteHighlight(1, cloud); ui.document:updateHighlightContents(1, cloud, "Changed")
    ui.document:writeDocument()
    ui.document.is_edited = true; ui.document:close()
    check(native_writes == 0 and native_pages == 0 and support.read(path) == "unchanged PDF bytes", "All PDF mutation and close-write paths preserve file bytes")
    check(ui.document:_checkIfWritable() == false, "Native writability check cannot re-enable PDF editing")
    ui.bookmark:importEmbeddedAnnotations(); ui.highlight:importEmbeddedAnnotations({})
    check(embedded_reads == 0 and #ui.annotation.annotations == count, "Embedded import is blocked as a whole")
    local local_index = ui.annotation:getItemIndex(local_item)
    ui.highlight:editHighlightStyle(local_index); last().callback("strikeout")
    ui.highlight:editHighlightColor(local_index); last().callback("green")
    ui.bookmark:setHighlightedText(local_index, "Edited local text", function() end)
    ui.bookmark:setBookmarkNote(local_index, false, nil, function() end)
    local input = last(); input.input = "Edited local note"; button(input, "Save").callback()
    check(local_item.drawer == "strikeout" and local_item.color == "green" and local_item.note == "Edited local note", "Native local style, color, text and note editing still works")
    ui.highlight.selected_text = { pos0 = {page = 1, x = 3, y = 3}, pos1 = {page = 1, x = 4, y = 4},
        text = "New local text", pboxes = {{x = 3, y = 3, w = 20, h = 10}} }
    local new_index = ui.highlight:saveHighlight()
    local new_local = ui.annotation.annotations[new_index]
    check(new_local and not new_local.zotero_source and #ui.annotation.annotations == count + 1, "Native local creation stays independent")
    ui.highlight.hold_pos = {page = 1}
    ui.highlight.highlight_idx = new_index
    ui.highlight.selected_text = {pos0 = {page = 1, x = 5, y = 5}, pos1 = {page = 1, x = 6, y = 6}, text = "Local fragment"}
    ui.highlight:extendSelection()
    new_index = ui.highlight:saveHighlight()
    check(ui.annotation.annotations[new_index].text == "Extended local text" and not ui.annotation.annotations[new_index].zotero_source, "Native local extension works without cloud provenance")
    ui.highlight.selected_text, ui.highlight.hold_pos, ui.highlight.select_mode = nil, nil, false
    ui.bookmark:onShowBookmark()
    local list = ui.bookmark.bookmark_menu[1]
    list:toggleSelectMode()
    for _, item in ipairs(list.item_table) do item.dim = true end
    list.select_count = #list.item_table
    list:onLeftButtonTap(); button(last(), "Delete note").callback(); last().ok_callback()
    check(cloud.note == "Cloud comment" and local_item.note == nil, "Mixed selected-list note deletion skips cloud notes")
    check(last().text:find("skipped: 2", 1, true), "Selected-list note deletion reports skips")
    list:toggleSelectMode()
    for _, item in ipairs(list.item_table) do item.dim = true end
    list.select_count = #list.item_table
    list:onLeftButtonTap(); button(last(), "Remove").callback(); last().ok_callback()
    check(#ui.annotation.annotations == 2 and #list.item_table == 2, "Mixed selected-list removal preserves cloud annotations and visible rows")
    check(last().text:find("skipped: 2", 1, true), "Selected-list removal reports skips")
    ui.bookmark.bookmark_menu = nil
    local export = directory .. "/export.lua"
    support.write(export, "native import stand-in")
    local imported_local = {page = 2, datetime = "2026-10-09 11:00:00"}
    local malicious_cloud = copy(cloud); malicious_cloud.note = "Changed by device export"
    local LuaSettings = require("luasettings")
    LuaSettings.open = function() return {readSetting = function(_, key)
        return ({device_id = "other-device", paging = true, datetime = "2099-01-01 00:00:00", annotations = {malicious_cloud, imported_local}})[key]
    end} end
    ui.annotation.getExportAnnotationsFilepath = function() return export end
    check(ui.annotation:importAnnotations(), "Native cross-device import still processes local entries")
    check(#ui.annotation.annotations == 3 and cloud.note == "Cloud comment", "Cross-device import cannot replace or remove current cloud entries")
    local before = ui.annotation.annotations
    ui.annotation:importAnnotations()
    check(ui.annotation.annotations == before, "No-op native import preserves the sorted list and settings reference")
    cache({cloud_item("ANNOT001", nil, "Changed remotely")}, 11)
    check(Annotations.applyToReader(API, ui, config, "ATTACH01"), "Cloud refresh bypasses native editing restrictions")
    check(#ui.annotation.annotations == 2 and config.data.percent_finished == 0.65, "Cloud deletion preserves local imported bookmark and progress")
    local updated
    for _, item in ipairs(ui.annotation.annotations) do if item.zotero_source then updated = item end end
    check(updated.text == "Changed remotely", "Cloud changes remain authoritative")
    check(native_writes == 0 and native_pages == 0 and support.read(path) == "unchanged PDF bytes" and #support.requests == 0, "Local and cloud changes never write PDF or make network requests")
    local gettext_mt = getmetatable(support.GetText)
    local native_gettext = gettext_mt.__call
    local native_chinese = {
        ["Apply current style and color to all highlights"] = "将当前样式和颜色应用于所有高亮",
        ["Write all highlights into PDF file"] = "将所有高亮写入 PDF 文件",
    }
    gettext_mt.__call = function(_, text) return native_chinese[text] or text end
    support.GetText.current_lang = "zh_CN"
    ui.highlight:showHighlightNoteOrDialog(ui.annotation:getItemIndex(updated))
    check(last().title == "Zotero Annotation · 蓝" and last().text:find("Changed remotely", 1, true),
        "Chinese annotation details keep the proper name, translate colors and preserve source text")
    ui.highlight:deleteHighlight(ui.annotation:getItemIndex(updated))
    check(last().text == "请在 Zotero 中修改此批注，然后同步并重新打开 PDF。",
        "Chinese interface still denies native cloud mutation")
    local chinese_menus = {}
    ui.highlight:addToMainMenu(chinese_menus)
    local style_found, write_found = false, false
    for _, entry in ipairs(chinese_menus.highlight_options.sub_item_table) do
        if entry.text == native_chinese["Apply current style and color to all highlights"] then
            entry.callback()
            style_found = last().text == "将当前样式和颜色应用于本地高亮？Zotero 批注保持只读。"
        end
        for _, child in ipairs(entry.sub_item_table or {}) do
            if child.text == native_chinese["Write all highlights into PDF file"] then
                write_found = entry.text_func() == "Zotero PDF 原文件已保护" and child.enabled == false
            end
        end
    end
    check(style_found and write_found, "Translated native menu labels still receive local-only and PDF-write protection")
    support.GetText.current_lang = "C"
    gettext_mt.__call = native_gettext
    check(PdfDocument.saveHighlight == original_save and ReaderHighlight.deleteHighlight == original_delete
        and ReaderBookmark.getBookmarkItemIndex == original_bookmark_index, "Native classes are unchanged")
    local ordinary = PdfDocument:extend{file = directory .. "/ordinary.pdf", _document = ui.document._document}
    support.write(ordinary.file, "ordinary PDF bytes")
    check(ordinary:_checkIfWritable() == true, "An ordinary PDF keeps native writability")
    ordinary:writeDocument()
    check(native_writes == 1 and support.read(ordinary.file) == "modified PDF bytes", "An ordinary PDF keeps native writing")
    plugin.ui = ui
    ui.document.file = ordinary.file
    plugin:prepareAnnotationImport(config, ui.document)
    check(not ui.document._zotero_policy and ui.document.writeDocument == PdfDocument.writeDocument, "Unmanaged path restores instance methods")
    check(ui.bookmark.getBookmarkItemIndex == original_bookmark_index and rawget(ui.bookmark, "getBookmarkItemIndex") == nil,
        "Unmanaged path restores the native bookmark index resolver")
end, debug.traceback)
support.teardown()
if not ok then error(err) end
io.write(string.format("%d KOReader annotation policy checks passed\n", checks))
