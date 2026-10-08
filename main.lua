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
local MultiInputDialog = require("ui/widget/multiinputdialog")
local lfs = require("libs/libkoreader-lfs")


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
    if view.kind == "search" then
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
            end
        end)
        UIManager:show(self.download_dialog)
    end
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

function ZoteroBrowser:setItems(items, title)
    self.title = title or _("Zotero")
    self:switchItemTable(self.title, items)
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

function Plugin:onZoteroSyncAction()
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
            return nil, ZoteroAPI.getLibrarySummary()
        end)
        if not ok then e = tostring(e) end
        self.syncing = false
        UIManager:close(message)

        if e == nil then
            UIManager:show(InfoMessage:new{
                text = _("Synchronization complete.") .. "\n" ..
                    (_("Library items: %d\nCollections: %d\nVisible PDF/EPUB attachments: %d")):format(
                        summary.items, summary.collections, summary.attachments),
                honor_silent_mode = false,
                flush_events_on_show = true,
                icon = "check"
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
