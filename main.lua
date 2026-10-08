local Blitbuffer = require("ffi/blitbuffer")
local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local ProgressDialog = require("progressdialog")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local SpinWidget = require("ui/widget/spinwidget")
local DataStorage = require("datastorage")
local FrameContainer = require("ui/widget/container/framecontainer")
local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local Menu = require("ui/widget/menu")
local Geom = require("ui/geometry")
local _ = require("gettext")
local ZoteroAPI = require("zoteroapi")
local AttachmentMenu = require("attachmentmenu")
local TextViewer = require("ui/widget/textviewer")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local lfs = require("libs/libkoreader-lfs")
local Annotations = require("annotations")
local LocalFiles = require("localfiles")
local ConfirmBox = require("ui/widget/confirmbox")
local logger = require("logger")


local DEFAULT_LINES_PER_PAGE = 14

local table_empty = function(table)
    -- see https://stackoverflow.com/a/1252776
    local next = next
    return (next(table) == nil)
end

local ZoteroBrowser = Menu:extend{
    no_title = false,
    is_borderless = true,
    is_popout = false,
    parent = nil,
    title_bar_left_icon = "appbar.search",
    covers_full_screen = true,
    return_arrow_propagation = false,
}


function ZoteroBrowser:init()
    -- Menu:init also runs when rebuilding the layout after a screen resize.
    local paths, current_view = self.paths, self.current_view
    Menu.init(self)
    self.paths = paths or {}
    self.current_view = current_view or { kind = "collection" }
    if self.page_return_arrow then self.page_return_arrow:enableDisable(#self.paths > 0) end
end

function ZoteroBrowser:showView(view)
    if view.kind == "attachments" then
        self:displayAttachments(view.key)
    elseif view.kind == "search" then
        self:displaySearchResults(view.query)
    else
        self:displayCollection(view.key)
    end
end

function ZoteroBrowser:navigate(view)
    table.insert(self.paths, self.current_view)
    self:showView(view)
end

-- Show search input
function ZoteroBrowser:onLeftButtonTap()
    local search_query_dialog
    search_query_dialog = InputDialog:new{
        title = _("Search Zotero titles"),
        input = "",
        input_hint = "search query",
        description = _("This will search title, first author and DOI of all entries."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(search_query_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(search_query_dialog)
                        self:navigate({ kind = "search", query = search_query_dialog:getInputText() })
                    end,
                },
            }
        }
    }
    UIManager:show(search_query_dialog)
    search_query_dialog:onShowKeyboard()
end


function ZoteroBrowser:onReturn()
    local previous = table.remove(self.paths)
    if previous then self:showView(previous) end
    return true
end


function ZoteroBrowser:onMenuSelect(item)
    if item.wildcard_collection == true then
        self:navigate({ kind = "search", query = "" })
    elseif item.collection == true then
        self:navigate({ kind = "collection", key = item.key })
    elseif item.attachment_group == true then
        self:navigate({ kind = "attachments", key = item.key })
    elseif item.is_label == true then
        -- nop
    else
        if self.downloading then return true end
        self.downloading = true
        self.download_dialog = ProgressDialog:new{ operation = "download" }
        UIManager:scheduleIn(0.05, function()
            local ok, full_path, e = pcall(ZoteroAPI.downloadAndGetPath, item.key, nil, function(event)
                self.download_dialog:update(event)
            end)
            if not ok then e, full_path = tostring(full_path), nil end
            local annotation_error
            if full_path and not e then
                local cached_ok, cached_result, cache_err = pcall(Annotations.ensureCached, ZoteroAPI, item.key, function(event)
                    self.download_dialog:update(event)
                end)
                annotation_error = cached_ok and cache_err or (not cached_ok and tostring(cached_result)) or nil
            end
            self.downloading = false
            UIManager:close(self.download_dialog)
            if e ~= nil then
                local b = InfoMessage:new{
                    text = _("Could not open file.") .. "\n" .. e,
                    honor_silent_mode = false,
                    flush_events_on_show = true,
                    icon = "notice-warning"
                }
                UIManager:show(b)
            else
                local ReaderUI = require("apps/reader/readerui")
                self.close_callback()
                ReaderUI:showReader(full_path)
                if annotation_error then
                    UIManager:show(InfoMessage:new{
                        text = Annotations.text("PDF annotations were not updated.") .. "\n" .. annotation_error,
                        icon = "notice-warning", honor_silent_mode = false,
                    })
                end
            end
        end)
        UIManager:show(self.download_dialog)
    end
end

function ZoteroBrowser:onMenuHold(item)
    if item.collection or item.is_label or item.wildcard_collection then return true end
    local details
    local buttons
    if not item.attachment_group then
        buttons = {{ {
            text = AttachmentMenu.text("Open"),
            callback = function()
                UIManager:close(details)
                self:onMenuSelect(item)
            end,
        } }}
        local attachment = ZoteroAPI.getItems()[item.key]
        if attachment and attachment.data.contentType == "application/pdf" then
            buttons[#buttons + 1] = {{
                text = Annotations.text("Refresh annotations"),
                enabled = ZoteroAPI.getAttachmentStatus(item.key) ~= "not_downloaded",
                callback = function()
                    UIManager:close(details)
                    self:refreshAnnotations(item)
                end,
            }}
            buttons[#buttons + 1] = {{
                text = AttachmentMenu.text("Delete local file"),
                enabled = LocalFiles.getPDFPath(ZoteroAPI, item.key) ~= nil,
                callback = function()
                    UIManager:close(details)
                    self:confirmDeleteLocalPDF(item)
                end,
            }}
        end
    end
    details = TextViewer:new{
        title = AttachmentMenu.text("Attachment details"),
        text = AttachmentMenu.details(item),
        show_menu = false,
        buttons_table = buttons,
        add_default_buttons = true,
    }
    UIManager:show(details)
    return true
end

function ZoteroBrowser:confirmDeleteLocalPDF(item)
    if self.downloading then return end
    local _, path, err = LocalFiles.getPDFPath(ZoteroAPI, item.key)
    if not path then
        UIManager:show(InfoMessage:new{ text = AttachmentMenu.text(err), icon = "notice-warning" })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = AttachmentMenu.text("Delete this local PDF, its annotations, bookmarks and reading progress? Zotero cloud data is kept. You can download it again.")
            .. "\n\n" .. ZoteroAPI.getItems()[item.key].data.filename,
        ok_text = AttachmentMenu.text("Delete local file"),
        ok_callback = function()
            if self.downloading then return end
            local ok, deleted, message = pcall(LocalFiles.removePDF, ZoteroAPI, item.key, path)
            if not ok then message, deleted = tostring(deleted), nil end
            if deleted then
                self:showView(self.current_view)
                self.refresh_callback()
            end
            local text = deleted and (message and AttachmentMenu.text("Local PDF deleted; some local data could not be removed.")
                or AttachmentMenu.text("Local PDF and annotations deleted."))
                or AttachmentMenu.text("Could not delete the local PDF.")
            if message then text = text .. "\n" .. AttachmentMenu.text(message) end
            UIManager:show(InfoMessage:new{
                text = text,
                icon = deleted and not message and "check" or "notice-warning",
                honor_silent_mode = false,
            })
        end,
    })
end

function ZoteroBrowser:refreshAnnotations(item)
    if self.downloading or ZoteroAPI.getAttachmentStatus(item.key) == "not_downloaded" then return end
    self.downloading = true
    local message = ProgressDialog:new{ operation = "annotations" }
    UIManager:show(message)
    UIManager:scheduleIn(0.05, function()
        local ok, cache, err = pcall(Annotations.ensureCached, ZoteroAPI, item.key,
            function(event) message:update(event) end, true)
        if not ok then err = tostring(cache) end
        self.downloading = false
        UIManager:close(message)
        UIManager:show(InfoMessage:new{
            text = ok and cache and (Annotations.text("PDF annotations updated.") .. "\n" ..
                Annotations.text("Cached annotations take effect when the PDF is next opened."))
                or (Annotations.text("PDF annotations were not updated.") .. "\n" .. tostring(err)),
            icon = ok and cache and "check" or "notice-warning", honor_silent_mode = false,
        })
    end)
end

function ZoteroBrowser:displayAttachments(parent_key)
    self.current_view = { kind = "attachments", key = parent_key }
    local items = AttachmentMenu.children(ZoteroAPI.displayAttachments(parent_key))
    if table_empty(items) then items[1] = { text = _("No Items"), is_label = true } end
    self:setItems(items, AttachmentMenu.text("Attachments"), true)
end

function ZoteroBrowser:displaySearchResults(query)
    self.current_view = { kind = "search", query = query }
    local ok, items = pcall(ZoteroAPI.displaySearchResults, query)
    if not ok then
        UIManager:show(InfoMessage:new{ text = tostring(items), icon = "notice-warning" })
        items = {}
    end
    if table_empty(items) then
        table.insert(items, 1, {
            ["text"] = _("No Results"),
            ["is_label"] = true,
        })
    end
    self:setItems(items, query == "" and _("All Items") or _("Search results"))
end

function ZoteroBrowser:displayCollection(collection_id)
    self.current_view = { kind = "collection", key = collection_id }
    local ok, items, collection = pcall(function()
        return ZoteroAPI.displayCollection(collection_id),
            collection_id and ZoteroAPI.getCollections()[collection_id]
    end)
    if not ok then
        UIManager:show(InfoMessage:new{ text = tostring(items), icon = "notice-warning" })
        items = {}
    end

    if collection_id == nil then
        table.insert(items, 1, {
            ["text"] = _("All Items"),
            ["wildcard_collection"] = true
        })
    end

    if table_empty(items) then
        table.insert(items, 1, {
            ["text"] = _("No Items"),
            ["is_label"] = true,
        })
    end

    self:setItems(items, collection and collection.data.name or _("Zotero"))
end

function ZoteroBrowser:setItems(items, title, attachments_view)
    self.title = title or _("Zotero")
    self:switchItemTable(self.title, attachments_view and items or AttachmentMenu.group(items))
end

local Plugin = WidgetContainer:new{
    name = "zotero",
    is_doc_only = false
}

function Plugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("zotero_open_action", {
        category="none",
        event="ZoteroOpenAction",
        title=_("Zotero Open"),
        general=true,
    })
    Dispatcher:registerAction("zotero_sync_action", {
        category="none",
        event="ZoteroSyncAction",
        title=_("Zotero Sync"),
        general=true
    })
end

function Plugin:init()
    self.initialized = false
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self.initialized = xpcall(function() self:initAPIAndBrowser() end,
        function(err) return self:initError(err) end)
    if self.initialized and self.ui.doc_settings then
        self:prepareAnnotationImport(self.ui.doc_settings, self.ui.document)
    end
end

function Plugin:prepareAnnotationImport(config, document)
    self.annotation_key = nil
    if not self.initialized then return end
    local ok, key = pcall(Annotations.managedKey, ZoteroAPI, document)
    if not ok or not key then return end
    self.annotation_key = key
    config:saveSetting("highlight_write_into_pdf", false)
end

function Plugin:onDocSettingsLoad(config, document)
    self:prepareAnnotationImport(config, document)
end

function Plugin:onReadSettings(config)
    -- Other handlers (notably docsettingtweak) can consume DocSettingsLoad.
    -- Resolve the current PDF again after native settings/migration instead of
    -- relying on that earlier event to have reached this plugin.
    self:prepareAnnotationImport(config, self.ui.document)
    if not self.annotation_key then return end
    if self.ui.highlight then self.ui.highlight.highlight_write_into_pdf = false end
    local ok, result, err = pcall(Annotations.applyToReader, ZoteroAPI, self.ui, config, self.annotation_key)
    if not ok then err = tostring(result) end
    if err then
        logger.warn("Zotero annotation import failed", self.annotation_key, err)
    elseif result then
        logger.info("Zotero annotations applied", self.annotation_key, result.imported, "imported", result.unsupported, "unsupported")
    end
    local message
    if err then message = Annotations.text("Could not apply Zotero annotations.") .. "\n" .. err
    elseif result and result.imported > 0 and self.ui.document.configurable.text_wrap == 1 then
        message = Annotations.text("Zotero annotations are displayed in original-page mode.")
    end
    if message then
        self.ui:registerPostReaderReadyCallback(function()
            UIManager:show(InfoMessage:new{ text = message, icon = "notice-warning", honor_silent_mode = false })
        end)
    end
end

function Plugin:onAnnotationsModified()
    if self.annotation_key then Annotations.reindex(self.ui) end
end

function Plugin:initError(e)
    self.init_error = tostring(e)
    return self.init_error
end

function Plugin:checkInitialized()
    local initialized = self.initialized and self.browser ~= nil and self.zotero_dialog ~= nil
    if not initialized then
        UIManager:show(InfoMessage:new{
            text = _("Could not initialize Zotero.") .. "\n" .. (self.init_error or ""),
            timeout = 3,
            icon = "notice-warning"
        })
    end

    return initialized
end

function Plugin:initAPIAndBrowser()
    self.zotero_dir_path = DataStorage:getDataDir() .. "/zotero"
    lfs.mkdir(self.zotero_dir_path)
    ZoteroAPI.init(self.zotero_dir_path, true)
    self.small_font_face = Font:getFace("smallffont")
    self.browser = ZoteroBrowser:new{
        refresh_callback = function()
            UIManager:setDirty(self.zotero_dialog)
            self.ui:onRefresh()
        end,
        close_callback = function()
            UIManager:close(self.zotero_dialog)
        end,
        items_per_page = self:getItemsPerPage()
    }
    self.zotero_dialog = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.browser
    }
    self.browser.show_parent = self.zotero_dialog
end

function Plugin:addToMainMenu(menu_items)
    menu_items.zotero = {
        text = _("Zotero"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Browse"),
                callback = function()
                    self:onZoteroOpenAction()
                end,
            },
            {
                text = _("Synchronize"),
                callback = function()
                    self:onZoteroSyncAction()
                end,

            },
            {
                text = _("Maintenance"),
                callback = function()
                    return nil
                end,
                sub_item_table = {
                    {
                        text = _("Resync entire collection"),
                        callback = function()
                            if not self:checkInitialized() then return end
                            ZoteroAPI.resetSyncState()
                            self:onZoteroSyncAction()
                        end,
                    },
                    {
                        text = Annotations.text("Refetch downloaded PDF annotations"),
                        callback = function() self:onZoteroSyncAction(true) end,
                    },
                },
            },
            {
                text = _("Settings"),
                callback = function()
                    return nil
                end,
                sub_item_table = {
                    {
                        text = _("Configure Zotero account"),
                        callback = function()
                            self:setAccount()
                        end,
                    },
                    {
                        text = _("Enable WebDAV storage"),
                        checked_func = function()
                            return self.initialized and ZoteroAPI.getWebDAVEnabled() or false
                        end,
                        callback = function()
                            if not self:checkInitialized() then return end
                            ZoteroAPI.toggleWebDAVEnabled()
                        end,
                    },
                    {
                        text = _("Configure WebDAV account"),
                        callback = function()
                            self:setWebdavAccount()
                        end,
                    },
                    {
                        text = _("Check WebDAV connection"),
                        callback = function()
                            if not self:checkInitialized() then return end
                            local msg = nil
                            local result = ZoteroAPI.checkWebDAV()
                            if result == nil then
                                msg = _("Success, WebDAV works!")
                            else
                                msg = _("WebDAV could not connect: ") .. result
                            end
                            UIManager:show(InfoMessage:new{
                                text = msg,
                                timeout = 3,
                                icon = "notice-info"
                            })
                        end,
                    },
                    {
                        text = _("Items per page"),
                        callback = function()
                            self:setItemsPerPage()
                        end,

                    },
                }
            }
        },
    }
end

function Plugin:setAccount()
    if not self:checkInitialized() then return end
    self.account_dialog = MultiInputDialog:new{
        title = _("Edit User Info"),
        fields = {
            {
                text = ZoteroAPI.getUserID(),
                hint = _("User ID (integer)"),
            },
            {
                text = ZoteroAPI.getAPIKey(),
                hint = _("API Key"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        self.account_dialog:onClose()
                        UIManager:close(self.account_dialog)
                    end
                },
                {
                    text = _("Update"),
                    callback = function()
                        local fields = self.account_dialog:getFields()
                        local user_id = (fields[1] or ""):match("^%s*(.-)%s*$")
                        if not user_id:match("^%d+$") then
                            UIManager:show(InfoMessage:new{
                                text = _("The User ID must be an integer number."),
                                timeout = 3,
                                icon = "notice-warning"
                            })
                            return
                        end

                        local ok, err = ZoteroAPI.setUserID(user_id)
                        if not ok then
                            UIManager:show(InfoMessage:new{ text = err, icon = "notice-warning" })
                            return
                        end
                        ZoteroAPI.setAPIKey(fields[2])
                        ZoteroAPI.saveSettings()
                        self.account_dialog:onClose()
                        UIManager:close(self.account_dialog)
                    end
                },
            },
        },
    }
    UIManager:show(self.account_dialog)
    self.account_dialog:onShowKeyboard()
end

function Plugin:setWebdavAccount()
    if not self:checkInitialized() then return end
    self.webdav_account_dialog = MultiInputDialog:new{
        title = _("Edit WebDAV credentials"),
        fields = {
            {
                text = ZoteroAPI.getWebDAVUrl(),
                hint = _("URL")
            },
            {
                text = ZoteroAPI.getWebDAVUser(),
                hint = _("Username"),
            },
            {
                text = ZoteroAPI.getWebDAVPassword(),
                hint = _("Password"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        self.webdav_account_dialog:onClose()
                        UIManager:close(self.webdav_account_dialog)
                    end
                },
                {
                    text = _("Update"),
                    callback = function()
                        local fields = self.webdav_account_dialog:getFields()

                        ZoteroAPI.setWebDAVUrl(fields[1])
                        ZoteroAPI.setWebDAVUser(fields[2])
                        ZoteroAPI.setWebDAVPassword(fields[3])
                        ZoteroAPI.saveSettings()
                        self.webdav_account_dialog:onClose()
                        UIManager:close(self.webdav_account_dialog)
                    end
                },
            },
        },
    }
    UIManager:show(self.webdav_account_dialog)
    self.webdav_account_dialog:onShowKeyboard()
end

function Plugin:setItemsPerPage()
    if not self:checkInitialized() then return end
    assert(ZoteroAPI.getSettings ~= nil)
    self.items_per_page_dialog = SpinWidget:new {
        title_text = _("Set items per page"),
        value = self:getItemsPerPage(),
        value_min = 1,
        value_max = 1000,
        callback = function(d)
            ZoteroAPI.getSettings():saveSetting("items_per_page", d.value)
            ZoteroAPI.saveSettings()
            UIManager:show(InfoMessage:new{
                text = _("This change requires a restart of KOReader to take effect."),
                timeout = 3,
                icon = "notice"
            })
        end,
    }
    UIManager:show(self.items_per_page_dialog)
end

function Plugin:getItemsPerPage()
    return ZoteroAPI.getSettings():readSetting("items_per_page", DEFAULT_LINES_PER_PAGE)
end

function Plugin:onZoteroOpenAction()
    if not self:checkInitialized() or self.browsing then return end
    self.browsing = true
    local loading
    local function open()
        local ok, err = pcall(function()
            self.browser.paths = {}
            self.browser.current_view = { kind = "collection" }
            self.browser:displayCollection(nil)
        end)
        self.browsing = false
        if loading then UIManager:close(loading) end
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("Could not load Zotero library.") .. "\n" .. tostring(err),
                honor_silent_mode = false, flush_events_on_show = true, icon = "notice-warning" })
            return
        end
        UIManager:show(self.zotero_dialog, "full", Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() })
    end
    if ZoteroAPI.isLibraryLoaded() then open()
    else
        loading = InfoMessage:new{ text = _("Loading Zotero library…"), honor_silent_mode = false,
            dismissable = false, unmovable = true }
        UIManager:show(loading)
        UIManager:scheduleIn(0.05, open)
    end
end

function Plugin:onZoteroSyncAction(force_annotations)
    if not self:checkInitialized() then
        return
    end
    if self.syncing then return end
    self.syncing = true
    local message = ProgressDialog:new{ operation = "sync" }
    UIManager:scheduleIn(1, function()
        local ok, e, summary = pcall(function()
            local err = ZoteroAPI.syncAllItems(function(event) message:update(event) end)
            if err then return err end
            local summary = ZoteroAPI.getLibrarySummary()
            summary.annotations = Annotations.refreshDownloaded(ZoteroAPI, function(event) message:update(event) end, force_annotations)
            return nil, summary
        end)
        if not ok then e = tostring(e) end
        self.syncing = false
        UIManager:close(message)

        if e == nil then
            UIManager:show(InfoMessage:new{
                text = _("Synchronization complete.") .. "\n" ..
                    (_("Library items: %d\nCollections: %d\nVisible PDF/EPUB attachments: %d")):format(
                        summary.items, summary.collections, summary.attachments) .. "\n" .. Annotations.summary(summary.annotations),
                honor_silent_mode = false,
                flush_events_on_show = true,
                icon = summary.annotations.failed > 0 and "notice-warning" or "check"
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("Synchronization failed.") .. "\n" .. e,
                honor_silent_mode = false,
                flush_events_on_show = true,
                icon = "notice-warning"
            })
        end
    end)

    UIManager:show(message)

end

return Plugin
