-- Restrictions belong to the current document/reader instances. Native
-- classes, global preferences, and independent local annotations stay intact.
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local Policy = {}
local SOURCE_COLOR_LABELS = {
    ["#ffd400"] = "Yellow", ["#ff6666"] = "Red", ["#5fb236"] = "Green", ["#2ea8e5"] = "Blue",
    ["#a28ae5"] = "Purple", ["#e56eee"] = "Magenta", ["#f19837"] = "Orange", ["#aaaaaa"] = "Gray",
}
local DISPLAY_COLOR_LABELS = {
    yellow = "Yellow", red = "Red", green = "Green", blue = "Blue", purple = "Purple",
    orange = "Orange", gray = "Gray", olive = "Olive", cyan = "Cyan",
}

local function annotation_title(state, item)
    local source_color = item.zotero_source.annotation_color
    local label
    if type(source_color) == "string" and source_color:match("^#%x%x%x%x%x%x$") then
        source_color = source_color:lower()
        label = SOURCE_COLOR_LABELS[source_color]
        label = label and state.text(label) or source_color
    else
        label = DISPLAY_COLOR_LABELS[item.color]
        label = label and state.text(label)
    end
    return "Zotero Annotation" .. (label and " · " .. label or "")
end

local function hook(state, object, name, wrapper)
    if not object or type(object[name]) ~= "function" then return end
    state.hooks[object] = state.hooks[object] or {}
    if state.hooks[object][name] then return end
    local original = object[name]
    local replacement = wrapper(original)
    state.hooks[object][name] = { original = rawget(object, name), replacement = replacement }
    object[name] = replacement
end

local function message(state, value)
    UIManager:show(require("ui/widget/infomessage"):new{ text = state.text(value) })
end

local function imported(state, item)
    return type(item) == "table" and state.is_imported(item)
end

local function target(ui, value)
    if type(value) == "number" then return ui.annotation.annotations[value] end
    if type(value) == "table" and ui.annotation.getItemIndex then
        -- A filtered menu row's idx belongs to the visible list, not annotations.
        local index = ui.annotation:getItemIndex(value)
        return ui.annotation.annotations[index] or value
    end
    return value
end

local function selection_owned(state, ui, item)
    local selection = ui.highlight and ui.highlight.selected_text
    return imported(state, selection) and (not item or item.drawer and item.pos0
        and item.pos0 == selection.pos0 and item.pos1 == selection.pos1)
end

local function deny(state)
    message(state, "Edit this annotation in Zotero, then synchronize and reopen the PDF.")
end

local function report(state, changed, skipped)
    UIManager:show(require("ui/widget/infomessage"):new{
        text = string.format(state.text("Local annotations updated: %d; read-only Zotero annotations skipped: %d"), changed, skipped),
    })
end

local function readonly_view(state, ui, item, value)
    local TextViewer = require("ui/widget/textviewer")
    local screen = require("device").screen
    local screen_w, screen_h = screen:getWidth(), screen:getHeight()
    local viewer
    local buttons = {}
    local bookmark = ui.bookmark
    local menu = bookmark and bookmark.bookmark_menu and bookmark.bookmark_menu[1]
    local items = menu and menu.item_table or ui.annotation.annotations
    local index
    for i, candidate in ipairs(items) do
        if candidate == item or imported(state, candidate)
            and candidate.zotero_source.annotation_key == item.zotero_source.annotation_key then index = i; break end
    end
    local function close() UIManager:close(viewer) end
    if bookmark and bookmark.showBookmarkDetails and index then
        local function navigate(i)
            close()
            -- Native details need the target row's idx from the displayed menu page.
            if menu then bookmark:updateBookmarkList(nil, i) end
            bookmark:showBookmarkDetails(menu and items[i] or i)
        end
        buttons[#buttons + 1] = {
            { text = "◀", enabled = index > 1, callback = function() navigate(index - 1) end },
            { text = "▶", enabled = index < #items, callback = function() navigate(index + 1) end },
        }
    end
    local actions = {}
    -- Hide the redundant jump on the current page, but retain list/other-page navigation.
    local current_page = bookmark and bookmark.getCurrentPageNumber and bookmark:getCurrentPageNumber()
    if bookmark and bookmark.gotoBookmark and (menu or current_page and item.page ~= current_page) then
        actions[#actions + 1] = { text = state.text("Go to annotation"), callback = function()
            close()
            if ui.link then ui.link:addCurrentLocationToStack() end
            bookmark:gotoBookmark(item.page, item.pos0)
            if menu and menu.close_callback then menu.close_callback() end
        end }
    end
    if ui.highlight and ui.highlight.onShowHighlightMenu then
        actions[#actions + 1] = { text = "…", callback = function()
            close()
            ui.highlight.selected_text = require("util").tableDeepCopy(item)
            local source_index = ui.annotation.getItemIndex and ui.annotation:getItemIndex(item)
            ui.highlight:onShowHighlightMenu(source_index or (type(value) == "number" and value or nil))
        end }
    end
    actions[#actions + 1] = { text = _("Close"), callback = close }
    buttons[#buttons + 1] = actions
    local content = item.note or state.text("No comment.")
    if item.zotero_source.annotation_type ~= "image" then
        content = (item.text or "") .. "\n\n" .. content
    end
    viewer = TextViewer:new{
        title = annotation_title(state, item), show_menu = false,
        text = content,
        -- Match ReaderHighlight's plain-note popup rather than TextViewer's large defaults.
        width = math.floor(math.min(screen_w, screen_h) * 0.8),
        height = math.floor(math.max(screen_w, screen_h) * 0.4),
        buttons_table = buttons,
    }
    UIManager:show(viewer)
    return true
end

local function install_selection_menu(state, ui)
    local highlight = ui.highlight
    if not highlight then return end
    for __, name in ipairs({ "01_select", "02_highlight", "04_add_note" }) do
        hook(state, highlight._highlight_buttons, name, function(original)
            return function(reader, index)
                local button = original(reader, index)
                if imported(state, target(ui, index)) or selection_owned(state, ui) then
                    button.enabled = false
                    button.callback = function() deny(state) end
                    button.hold_callback = nil
                end
                return button
            end
        end)
    end
end

local function install_highlight_menu(state, ui)
    hook(state, ui.highlight, "addToMainMenu", function(original)
        return function(reader, menus)
            local result = original(reader, menus)
            local options = menus.highlight_options and menus.highlight_options.sub_item_table or {}
            for __, entry in ipairs(options) do
                if entry.text == _("Apply current style and color to all highlights") then
                    entry.callback = function()
                        UIManager:show(require("ui/widget/confirmbox"):new{
                            text = state.text("Apply current style and color to local highlights? Zotero annotations stay read-only."),
                            ok_callback = function()
                                local changed, skipped = 0, 0
                                for __, item in ipairs(ui.annotation.annotations) do
                                    if imported(state, item) then skipped = skipped + 1
                                    elseif item.drawer then
                                        item.drawer, item.color = ui.view.highlight.saved_drawer, ui.view.highlight.saved_color
                                        changed = changed + 1
                                    end
                                end
                                UIManager:setDirty(reader.dialog, "ui")
                                report(state, changed, skipped)
                            end,
                        })
                    end
                end
                for __, child in ipairs(entry.sub_item_table or {}) do
                    if child.text == _("Write all highlights into PDF file") then
                        entry.text_func = function() return state.text("PDF file protected by Zotero") end
                        entry.enabled, entry.enabled_func = false, function() return false end
                        for __, action in ipairs(entry.sub_item_table) do
                            action.enabled, action.enabled_func = false, function() return false end
                            action.callback = function() message(state, "This Zotero PDF is protected. Local annotations are saved in KOReader settings.") end
                            action.hold_callback = action.callback
                        end
                        break
                    end
                end
            end
            return result
        end
    end)
end

-- Native selected-list removal also removes menu rows even when removeItem
-- refuses a cloud item. Own the select-mode actions so cloud rows remain visible.
local function install_bookmark_menu(state, ui)
    hook(state, ui.bookmark, "onShowBookmark", function(original)
        return function(reader, ...)
            local result = original(reader, ...)
            local menu = reader.bookmark_menu and reader.bookmark_menu[1]
            if menu then
                -- This menu is transient; do not retain it in the document's
                -- restoration table after each opening of the bookmark list.
                local left = menu.onLeftButtonTap
                menu.onLeftButtonTap = function(list)
                    if not state.active or not list.select_count then return left(list) end
                    local dialog
                    local function close() UIManager:close(dialog) end
                    local function select_items(first, last, selected)
                        close()
                        for i = first, last do list.item_table[i].dim = selected or nil end
                        list.select_count = 0
                        for __, item in ipairs(list.item_table) do
                            if item.dim then list.select_count = list.select_count + 1 end
                            item.mandatory_dim = not item.dim and item.after_curr_page or nil
                        end
                        reader:updateBookmarkList(nil, -1)
                    end
                    local function change(remove)
                        UIManager:show(require("ui/widget/confirmbox"):new{
                            text = state.text("Update selected local annotations? Zotero annotations stay read-only."),
                            ok_callback = function()
                                close()
                                local changed, skipped = 0, 0
                                for i = #list.item_table, 1, -1 do
                                    local item = list.item_table[i]
                                    if item.dim then
                                        if imported(state, target(ui, item)) then skipped = skipped + 1
                                        elseif remove then
                                            reader:removeItem(item)
                                            table.remove(list.item_table, i)
                                            changed = changed + 1
                                        elseif item.note then
                                            reader:deleteItemNote(item)
                                            item.note = nil
                                            item.type = reader.getBookmarkType(item)
                                            item.text = reader:getBookmarkItemText(item)
                                            changed = changed + 1
                                        end
                                    end
                                end
                                list:toggleSelectMode()
                                reader:updateBookmarkList(list.item_table, -1)
                                report(state, changed, skipped)
                            end,
                        })
                    end
                    dialog = require("ui/widget/buttondialog"):new{
                        title = state.text("Zotero annotations are read-only"),
                        buttons = {
                            {
                                { text = _("Select all"), callback = function() select_items(1, #list.item_table, true) end },
                                { text = _("Select page"), callback = function()
                                    local first = (list.page - 1) * list.perpage + 1
                                    select_items(first, math.min(first + list.perpage - 1, #list.item_table), true)
                                end },
                            },
                            {
                                { text = _("Deselect all"), callback = function() select_items(1, #list.item_table, false) end },
                                { text = _("Delete note"), enabled = list.select_count > 0, callback = function() change(false) end },
                            },
                            {
                                { text = _("Exit select mode"), callback = function() close(); list:toggleSelectMode() end },
                                { text = _("Remove"), enabled = list.select_count > 0 and not ui.highlight.select_mode,
                                    callback = function() change(true) end },
                            },
                        },
                    }
                    UIManager:show(dialog)
                end
            end
            return result
        end
    end)
end

function Policy.install(ui, is_imported, text)
    local document = ui.document
    local state = document._zotero_policy
    if not state then state = { hooks = {} }; document._zotero_policy = state end
    state.is_imported, state.text, state.active = is_imported, text, true
    for __, name in ipairs({ "_checkIfWritable", "saveHighlight", "deleteHighlight", "updateHighlightContents", "writeDocument" }) do
        hook(state, document, name, function() return function() return false end end)
    end
    if ui.highlight then ui.highlight.highlight_write_into_pdf = false end
    hook(state, ui.highlight, "writePdfAnnotation", function() return function() return false end end)
    for __, module in ipairs({ ui.highlight or {}, ui.bookmark or {} }) do
        hook(state, module, "importEmbeddedAnnotations", function()
            return function()
                message(state, "This Zotero PDF is protected. Local annotations are saved in KOReader settings.")
                return 0, 0
            end
        end)
    end
    hook(state, ui.highlight, "onReadSettings", function(original)
        return function(reader, ...)
            local result = original(reader, ...)
            reader.highlight_write_into_pdf = false
            return result
        end
    end)
    for __, name in ipairs({ "deleteHighlight", "editNote", "editHighlightStyle", "editHighlightColor", "updateHighlight", "startSelection" }) do
        hook(state, ui.highlight, name, function(original)
            return function(reader, index, ...)
                if imported(state, target(ui, index)) or name == "startSelection" and not index and selection_owned(state, ui) then
                    deny(state); return
                end
                return original(reader, index, ...)
            end
        end)
    end
    for __, name in ipairs({ "updateHighlightPaging", "updateHighlightRolling" }) do
        hook(state, ui.highlight, name, function(original)
            return function(reader, item, ...)
                if imported(state, item) then deny(state); return end
                return original(reader, item, ...)
            end
        end)
    end
    hook(state, ui.highlight, "extendSelection", function(original)
        return function(reader, ...)
            if imported(state, target(ui, reader.highlight_idx)) then deny(state); return end
            return original(reader, ...)
        end
    end)
    for __, name in ipairs({ "saveHighlight", "showHighlightPrompt" }) do
        hook(state, ui.highlight, name, function(original)
            return function(reader, ...)
                if selection_owned(state, ui) then deny(state); return end
                return original(reader, ...)
            end
        end)
    end
    for __, name in ipairs({ "showHighlightNoteOrDialog", "showHighlightDialog" }) do
        hook(state, ui.highlight, name, function(original)
            return function(reader, index, ...)
                local item = target(ui, index)
                if imported(state, item) then return readonly_view(state, ui, item, index) end
                return original(reader, index, ...)
            end
        end)
    end
    hook(state, ui.bookmark, "getBookmarkItemIndex", function(original)
        return function(reader, item)
            -- Native bookmark edits/removals also need the source index. Its
            -- fast path overlooks color filtering and trusts the display idx.
            if reader.show_color_only then return ui.annotation:getItemIndex(item) end
            return original(reader, item)
        end
    end)
    for __, name in ipairs({ "removeItem", "removeItemByIndex", "deleteItemNote", "setBookmarkNote", "editHighlightedText", "setHighlightedText" }) do
        hook(state, ui.bookmark, name, function(original)
            return function(reader, value, ...)
                if imported(state, target(ui, value)) then deny(state); return end
                return original(reader, value, ...)
            end
        end)
    end
    hook(state, ui.bookmark, "showBookmarkDetails", function(original)
        return function(reader, value, ...)
            local item = target(ui, value)
            if imported(state, item) then return readonly_view(state, ui, item, value) end
            return original(reader, value, ...)
        end
    end)
    hook(state, ui.annotation, "addItem", function(original)
        return function(reader, item)
            if imported(state, item) or selection_owned(state, ui, item) then deny(state); return end
            return original(reader, item)
        end
    end)
    -- Native cross-device import may delete/replace saved cloud entries before
    -- the plugin loads its cache. Only Zotero may supply their authoritative copy.
    hook(state, ui.annotation, "importAnnotations", function(original)
        return function(reader, ...)
            local previous = reader.annotations
            local cloud, native = {}, {}
            for __, item in ipairs(reader.annotations or {}) do
                local list = imported(state, item) and cloud or native
                list[#list + 1] = item
            end
            reader.annotations = native
            local ok, result = pcall(original, reader, ...)
            if not ok or not result then
                reader.annotations = previous
                if not ok then error(result) end
                return result
            end
            local combined = {}
            for __, item in ipairs(reader.annotations) do
                if not imported(state, item) then combined[#combined + 1] = item end
            end
            for __, item in ipairs(cloud) do combined[#combined + 1] = item end
            reader.annotations = combined
            if reader.sortItems then reader:sortItems(combined) end
            return result
        end
    end)
    install_selection_menu(state, ui)
    install_highlight_menu(state, ui)
    install_bookmark_menu(state, ui)
end

function Policy.remove(ui)
    local state = ui.document and ui.document._zotero_policy
    if not state then return end
    state.active = false
    for object, methods in pairs(state.hooks) do
        for name, entry in pairs(methods) do
            if object[name] == entry.replacement then object[name] = entry.original end
        end
    end
    ui.document._zotero_policy = nil
end

return Policy
