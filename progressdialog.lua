local InfoMessage = require("ui/widget/infomessage")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local _ = require("gettext")

-- A conservative cadence for Kindle e-ink panels, including older devices.
local REFRESH_INTERVAL = time.s(2)
local stages = {
    checking_cache = _("Checking local file…"),
    cached = _("Opening local file…"),
    downloading = _("Downloading file…"),
    resuming = _("Download interrupted. Resuming…"),
    retrying_request = _("Connection interrupted. Retrying this page…"),
    retrying_archive = _("Invalid downloaded archive. Downloading again…"),
    extracting = _("Extracting attachment…"),
    verifying = _("Checking downloaded file…"),
    saving_attachment = _("Saving file…"),
    checking_account = _("Checking Zotero account…"),
    items = _("Fetching library items…"),
    collections = _("Fetching collections…"),
    deletions = _("Applying deletions…"),
    saving_library = _("Saving library…"),
    retrying = _("Library changed. Restarting synchronization…"),
    up_to_date = _("Library is up to date."),
    complete = _("Complete."),
}

local function format_bytes(bytes)
    if bytes < 1024 then return ("%d B"):format(bytes) end
    if bytes < 1024 * 1024 then return ("%.1f KiB"):format(bytes / 1024) end
    return ("%.1f MiB"):format(bytes / (1024 * 1024))
end

local ProgressDialog = InfoMessage:extend{
    honor_silent_mode = false,
    dismissable = false,
    unmovable = true,
    show_icon = false,
}

function ProgressDialog:init()
    -- Fixed geometry keeps old text covered when a status becomes shorter.
    self.width = math.floor(Screen:getWidth() * 0.8)
    self.height = math.min(Screen:scaleBySize(180), math.floor(Screen:getHeight() * 0.6))
    self.title = self.operation == "sync" and _("Synchronizing Zotero library") or _("Downloading attachment")
    if not self.text or self.text == "" then
        local initial_stage = self.operation == "sync" and stages.checking_account or _("Waiting for response…")
        self.text = self.title .. "\n" .. initial_stage
    end
    InfoMessage.init(self)
end

function ProgressDialog:onShow()
    self.last_refresh_time = time.now()
    return InfoMessage.onShow(self)
end

function ProgressDialog:update(event)
    if self.closed then return end
    local now = time.now()
    if self.last_refresh_time and now - self.last_refresh_time < REFRESH_INTERVAL then return end

    local lines = { self.title, stages[event.stage] or _("Preparing…") }
    if event.completed then
        if event.total and event.total > 0 then
            lines[#lines + 1] = (_("Processed: %d / %d (%d%%)")):format(
                event.completed, event.total, math.floor(event.completed / event.total * 100))
        else
            lines[#lines + 1] = (_("Processed: %d")):format(event.completed)
        end
    end
    if event.bytes and event.bytes > 0 then
        local label = event.stage == "verifying" and _("Checked: %s") or _("Received: %s")
        lines[#lines + 1] = label:format(format_bytes(event.bytes))
    elseif event.bytes == 0 then
        lines[#lines + 1] = _("Waiting for response…")
    end
    local text = table.concat(lines, "\n")
    if text == self.text then return end

    self.last_refresh_time = now
    self:free()
    self.text = text
    self:init()
    UIManager:setDirty(self, function() return "ui", self:getVisibleArea() end)
    -- HTTP and checksum work block the main loop: drain paints without processing
    -- input or scheduled actions that could start another network operation.
    UIManager:forceRePaint()
    UIManager:yieldToEPDC()
end

function ProgressDialog:onCloseWidget()
    self.closed = true
    return InfoMessage.onCloseWidget(self)
end

return ProgressDialog
