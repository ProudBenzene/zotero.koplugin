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
local I18n = require("i18n")
local _ = I18n.text
local ZoteroAPI = require("zoteroapi")
local AttachmentMenu = require("attachmentmenu")
local TextViewer = require("ui/widget/textviewer")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local lfs = require("libs/libkoreader-lfs")
local Annotations = require("annotations")
local LocalFiles = require("localfiles")
local DownloadCleanup = require("downloadcleanup")
local ConfirmBox = require("ui/widget/confirmbox")
local logger = require("logger")


local DEFAULT_LINES_PER_PAGE = 14

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
        input_hint = _("search query"),
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
        if self.downloading or ZoteroAPI.isBusy() then return true end
        local token = ZoteroAPI.beginOperation("download")
        if not token then return true end
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
            ZoteroAPI.endOperation(token)
            UIManager:close(self.download_dialog)
            if e ~= nil then
                local b = InfoMessage:new{
                    text = _("Could not open file.") .. "\n" .. I18n.error(e),
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
                        text = Annotations.text("PDF annotations were not updated.") .. "\n" .. I18n.error(annotation_error),
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
        end
        if attachment and (attachment.data.contentType == "application/pdf" or attachment.data.contentType == "application/epub+zip") then
            buttons[#buttons + 1] = {{
                text = AttachmentMenu.text("Delete local file"),
                enabled = LocalFiles.getAttachmentPath(ZoteroAPI, item.key) ~= nil,
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
    if self.downloading or ZoteroAPI.isBusy() then return end
    local _, path, err = LocalFiles.getAttachmentPath(ZoteroAPI, item.key)
    if not path then
        UIManager:show(InfoMessage:new{ text = I18n.error(err), icon = "notice-warning" })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = AttachmentMenu.text("Delete this local document, its annotations, bookmarks and reading progress? Zotero cloud data is kept. You can download it again.")
            .. "\n\n" .. ZoteroAPI.getItems()[item.key].data.filename,
        ok_text = AttachmentMenu.text("Delete local file"),
        ok_callback = function()
            if self.downloading then return end
            local token = ZoteroAPI.beginOperation("delete")
            if not token then return end
            local ok, deleted, message = pcall(LocalFiles.removeAttachment, ZoteroAPI, item.key, path)
            ZoteroAPI.endOperation(token)
            if not ok then message, deleted = tostring(deleted), nil end
            if deleted then
                self:showView(self.current_view)
                self.refresh_callback()
            end
            local text = deleted and (message and AttachmentMenu.text("Local document deleted; some local data could not be removed.")
                or AttachmentMenu.text("Local document and reading data deleted."))
                or AttachmentMenu.text("Could not delete the local document.")
            if message then text = text .. "\n" .. I18n.error(message) end
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
    local token = ZoteroAPI.beginOperation("annotations")
    if not token then return end
    self.downloading = true
    local message = ProgressDialog:new{ operation = "annotations" }
    UIManager:show(message)
    UIManager:scheduleIn(0.05, function()
        local ok, cache, err = pcall(Annotations.ensureCached, ZoteroAPI, item.key,
            function(event) message:update(event) end, true)
        if not ok then err = tostring(cache) end
        self.downloading = false
        ZoteroAPI.endOperation(token)
        UIManager:close(message)
        UIManager:show(InfoMessage:new{
            text = ok and cache and (Annotations.text("PDF annotations updated.") .. "\n" ..
                Annotations.text("Cached annotations take effect when the PDF is next opened."))
                or (Annotations.text("PDF annotations were not updated.") .. "\n" .. I18n.error(err)),
            icon = ok and cache and "check" or "notice-warning", honor_silent_mode = false,
        })
    end)
end

function ZoteroBrowser:displayAttachments(parent_key)
    self.current_view = { kind = "attachments", key = parent_key }
    local items = AttachmentMenu.children(ZoteroAPI.displayAttachments(parent_key))
    if not next(items) then items[1] = { text = _("No Items", "attachments"), is_label = true } end
    self:setItems(items, AttachmentMenu.text("Attachments"), true)
end

function ZoteroBrowser:displaySearchResults(query)
    self.current_view = { kind = "search", query = query }
    local ok, items = pcall(ZoteroAPI.displaySearchResults, query)
    if not ok then
        UIManager:show(InfoMessage:new{ text = I18n.error(items), icon = "notice-warning" })
        items = {}
    end
    if not next(items) then
        table.insert(items, 1, {
            ["text"] = _("No Results", query == "" and "library" or "search"),
            ["is_label"] = true,
        })
    end
    -- Keep this Zotero label in English, independently of the host catalog.
    self:setItems(items, query == "" and "All Items" or _("Search results"))
end

function ZoteroBrowser:displayCollection(collection_id)
    self.current_view = { kind = "collection", key = collection_id }
    local ok, items, collection = pcall(function()
        return ZoteroAPI.displayCollection(collection_id),
            collection_id and ZoteroAPI.getCollections()[collection_id]
    end)
    if not ok then
        UIManager:show(InfoMessage:new{ text = I18n.error(items), icon = "notice-warning" })
        items = {}
    end

    if collection_id == nil then
        table.insert(items, 1, {
            ["text"] = "All Items",
            ["wildcard_collection"] = true
        })
    end

    if not next(items) then
        table.insert(items, 1, {
            ["text"] = _("No Items", "collection"),
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
    if not ok or not key then
        Annotations.releaseReader(self.ui)
        return
    end
    self.annotation_key = key
    Annotations.bindSettings(self.ui, config, tostring(ZoteroAPI.getUserID()):match("^%s*(.-)%s*$"), key)
    config:saveSetting("highlight_write_into_pdf", false)
    Annotations.protectReader(ZoteroAPI, self.ui, key)
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
    if err then message = Annotations.text("Could not apply Zotero annotations.") .. "\n" .. I18n.error(err)
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
            text = _("Could not initialize Zotero.") .. "\n" .. I18n.error(self.init_error or ""),
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
                            if not self:checkInitialized() or ZoteroAPI.isBusy() then return end
                            ZoteroAPI.resetSyncState()
                            self:onZoteroSyncAction(true)
                        end,
                    },
                    {
                        text = Annotations.text("Refetch downloaded PDF annotations"),
                        callback = function() self:onZoteroSyncAction(true) end,
                    },
                    {
                        text = _("Delete all downloaded documents"),
                        callback = function() self:onZoteroDeleteDownloads() end,
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
                            if not self:checkInitialized() or ZoteroAPI.isBusy() then return end
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
                                msg = _("WebDAV could not connect: ") .. I18n.error(result)
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

local function show_account_dialog(plugin, field, title, fields, save)
    local function close()
        plugin[field]:onClose()
        UIManager:close(plugin[field])
    end
    plugin[field] = MultiInputDialog:new{
        title = title,
        fields = fields,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = close },
            { text = _("Update"), callback = function()
                if ZoteroAPI.isBusy() or not save(plugin[field]:getFields()) then return end
                ZoteroAPI.saveSettings()
                close()
            end },
        }},
    }
    UIManager:show(plugin[field])
    plugin[field]:onShowKeyboard()
end

function Plugin:setAccount()
    if not self:checkInitialized() or ZoteroAPI.isBusy() then return end
    show_account_dialog(self, "account_dialog", _("Edit User Info"), {
        { text = ZoteroAPI.getUserID(), hint = _("User ID (integer)") },
        { text = ZoteroAPI.getAPIKey(), hint = _("API Key") },
    }, function(fields)
        local user_id = (fields[1] or ""):match("^%s*(.-)%s*$")
        if not user_id:match("^%d+$") then
            UIManager:show(InfoMessage:new{
                text = _("The User ID must be an integer number."),
                timeout = 3, icon = "notice-warning",
            })
            return
        end
        local ok, err = ZoteroAPI.setUserID(user_id)
        if not ok then
            UIManager:show(InfoMessage:new{ text = I18n.error(err), icon = "notice-warning" })
            return
        end
        ZoteroAPI.setAPIKey(fields[2])
        return true
    end)
end

function Plugin:setWebdavAccount()
    if not self:checkInitialized() or ZoteroAPI.isBusy() then return end
    show_account_dialog(self, "webdav_account_dialog", _("Edit WebDAV credentials"), {
        { text = ZoteroAPI.getWebDAVUrl(), hint = _("URL") },
        { text = ZoteroAPI.getWebDAVUser(), hint = _("Username") },
        { text = ZoteroAPI.getWebDAVPassword(), hint = _("Password") },
    }, function(fields)
        ZoteroAPI.setWebDAVUrl(fields[1])
        ZoteroAPI.setWebDAVUser(fields[2])
        ZoteroAPI.setWebDAVPassword(fields[3])
        return true
    end)
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
    if not self:checkInitialized() or self.browsing or ZoteroAPI.isBusy() then return end
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
            UIManager:show(InfoMessage:new{ text = _("Could not load Zotero library.") .. "\n" .. I18n.error(err),
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
    local token = ZoteroAPI.beginOperation("sync")
    if not token then return end
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
        ZoteroAPI.endOperation(token)
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
                text = _("Synchronization failed.") .. "\n" .. I18n.error(e),
                honor_silent_mode = false,
                flush_events_on_show = true,
                icon = "notice-warning"
            })
        end
    end)

    UIManager:show(message)

end

function Plugin:onZoteroDeleteDownloads()
    if not self:checkInitialized() or self.syncing or self.browser.downloading then return end
    local token = ZoteroAPI.beginOperation("delete_downloads")
    if not token then return end
    local progress = ProgressDialog:new{ operation = "cleanup" }
    UIManager:show(progress)
    local function release()
        ZoteroAPI.endOperation(token)
        UIManager:close(progress)
    end
    local function failure(err)
        release()
        UIManager:show(InfoMessage:new{ text = _("Could not scan local downloads.") .. "\n" .. I18n.error(err),
            icon = "notice-warning", honor_silent_mode = false })
    end
    local function result(scan, stats)
        release()
        if self.browser.current_view and ZoteroAPI.isLibraryLoaded() then
            pcall(function() self.browser:showView(self.browser.current_view) end)
        end
        pcall(function() self.ui:onRefresh() end)
        local complete = stats.failed == 0 and stats.open == 0 and stats.skipped == 0 and stats.pending == 0 and stats.unknown == 0
        local heading = complete and (stats.deleted == 0 and stats.cleaned == 0 and _("No local downloads to delete.")
            or _("All identified local downloads deleted.")) or _("Local download cleanup finished with remaining files.")
        local lines = { heading,
            _("Deleted: %d; failed: %d; open: %d; changed: %d; cleanup pending: %d; unidentified: %d")
                :format(stats.deleted, stats.failed, stats.open, stats.skipped, stats.pending, stats.unknown) }
        for _, err in ipairs(stats.errors) do lines[#lines + 1] = err.path .. "\n" .. I18n.error(err.message) end
        for index, path in ipairs(scan.unknown) do lines[#lines + 1] = _("Unidentified: %s"):format(path) end
        UIManager:show(TextViewer:new{ title = _("Local download cleanup"), text = table.concat(lines, "\n"),
            show_menu = false, add_default_buttons = true })
    end
    local function confirm(scan)
        UIManager:close(progress)
        if #scan.targets == 0 then
            result(scan, DownloadCleanup.newStats(scan))
            return
        end
        local consumed = false
        local lines = {
            _("Delete this device's Zotero downloads from all accounts?\nPDF: %d; EPUB: %d; accounts: %d; file size: %.1f MiB; pending cleanup: %d")
                :format(scan.pdf, scan.epub, scan.accounts, scan.bytes / 1048576, scan.pending)
                .. "\n\n" .. _("Local annotations, bookmarks and reading progress will also be deleted. Zotero cloud data is kept. You can download the documents again.")
                .. "\n\n" .. _("Open and unidentified files will be skipped. Unidentified: %d"):format(#scan.unknown),
        }
        for index, target in ipairs(scan.targets) do
            local entry = {
                ("%d. %s"):format(index, target.title or target.filename),
                _("Local path: %s"):format(target.path),
            }
            if target.attachment_title and target.attachment_title ~= target.title then
                table.insert(entry, 2, _("Attachment: %s"):format(target.attachment_title))
            end
            if target.cleanup_only then
                entry[#entry + 1] = _("Document already deleted; only remaining local data will be cleaned.")
            elseif LocalFiles.isOpen(target.path) then
                entry[#entry + 1] = _("Currently open — will be skipped.")
            end
            lines[#lines + 1] = table.concat(entry, "\n")
        end
        if #scan.unknown > 0 then
            lines[#lines + 1] = _("Unidentified files will be kept:") .. "\n" .. table.concat(scan.unknown, "\n")
        end
        local preview
        local function dismiss()
            if consumed then return end
            consumed = true; ZoteroAPI.endOperation(token)
        end
        local function cancel()
            dismiss()
            UIManager:close(preview)
        end
        local function execute()
            if consumed then return end
            consumed = true
            UIManager:close(preview)
            local message = ProgressDialog:new{ operation = "cleanup" }
            progress = message
            UIManager:show(message)
            local index, stats = 0, DownloadCleanup.newStats(scan)
            local worker
            local function step()
                if not worker then
                    index = index + 1
                    if index > #scan.targets then result(scan, stats); return end
                    worker = coroutine.create(function()
                        DownloadCleanup.processTarget(scan.targets[index], stats, function()
                            coroutine.yield()
                        end)
                    end)
                end
                for batch = 1, 16 do
                    local ok, err = coroutine.resume(worker)
                    if not ok then
                        stats.failed = stats.failed + 1
                        stats.errors[#stats.errors + 1] = { path = scan.targets[index].path, message = tostring(err) }
                        worker = nil
                        break
                    end
                    if coroutine.status(worker) == "dead" then worker = nil; break end
                end
                message:update({ stage = "deleting_downloads", completed = worker and index - 1 or index, total = #scan.targets })
                UIManager:scheduleIn(0.01, step)
            end
            UIManager:scheduleIn(0.05, step)
        end
        preview = TextViewer:new{
            title = _("Preview local downloads to delete"), text = table.concat(lines, "\n\n"), show_menu = false,
            close_callback = dismiss,
            buttons_table = {{
                { text = _("Cancel"), callback = cancel },
                { text = _("Delete all local downloads"), callback = execute },
            }},
        }
        local on_close = preview.onCloseWidget
        preview.onCloseWidget = function(widget)
            dismiss()
            if on_close then return on_close(widget) end
        end
        UIManager:show(preview)
    end
    local worker = coroutine.create(function()
        return DownloadCleanup.scanDownloads(ZoteroAPI, function(event) coroutine.yield(event) end)
    end)
    local function scan_step()
        -- Yield after a small batch of entries, including checksum chunks.
        for _ = 1, 16 do
            local ok, value = coroutine.resume(worker)
            if not ok then failure(value); return end
            if coroutine.status(worker) == "dead" then
                local displayed, err = pcall(confirm, value)
                if not displayed then failure(err) end
                return
            end
            progress:update(value)
        end
        UIManager:scheduleIn(0.01, scan_step)
    end
    UIManager:scheduleIn(0.05, scan_step)
end

return Plugin
