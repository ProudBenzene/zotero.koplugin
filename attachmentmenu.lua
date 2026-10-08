local _ = require("gettext")
local API = require("zoteroapi")
local AttachmentMenu = {}

-- KOReader's catalog does not contain these plugin-specific messages.
local chinese = {
    ["Downloaded"] = "已下载", ["Not downloaded"] = "未下载", ["Update available"] = "待更新",
    ["%d files"] = "%d 个附件", ["%d files · %d downloaded"] = "%d 个附件 · 已下载 %d",
    ["Attachments"] = "附件", ["Attachment details"] = "附件信息",
    ["Document: %s"] = "文献：%s", ["Attachment: %s"] = "附件：%s",
    ["Filename: %s"] = "文件名：%s", ["Format: %s"] = "格式：%s",
    ["Status: %s"] = "状态：%s", ["Local size: %s"] = "本地大小：%s",
    ["File modified: %s"] = "文件修改时间：%s", ["Open"] = "打开",
    ["Delete local file"] = "删除本地文件",
    ["Delete this local PDF, its annotations, bookmarks and reading progress? Zotero cloud data is kept. You can download it again."]
        = "删除本机 PDF 及其批注、书签和阅读进度？Zotero 云端数据保留，之后可以重新下载。",
    ["Local PDF and annotations deleted."] = "已删除本机 PDF 及批注。",
    ["Local PDF deleted; some local data could not be removed."] = "本机 PDF 已删除，但部分本地数据未能清理。",
    ["Could not delete the local PDF."] = "无法删除本机 PDF。",
    ["Close this PDF before deleting its local copy."] = "请先关闭此 PDF，再删除本地文件。",
    ["Local PDF not found."] = "未找到本机 PDF。",
    ["Only downloaded PDF attachments can be removed."] = "只能删除已下载的 PDF 附件。",
    ["The PDF path does not match its attachment storage."] = "PDF 路径与附件存储目录不匹配。",
    ["The local PDF changed. Open its details again."] = "本机 PDF 已发生变化，请重新打开附件信息。",
    ["Long-press a file to see its full name and details."] = "长按附件可查看完整名称和详细信息。",
}

function AttachmentMenu.text(message)
    local language = type(_) == "table" and _.current_lang or ""
    if language:match("^zh_CN") or language:match("^zh_Hans") then
        return chinese[message] or _(message)
    end
    return _(message)
end

local function status_text(status)
    return AttachmentMenu.text(status == "downloaded" and "Downloaded"
        or status == "outdated" and "Update available" or "Not downloaded")
end

local function decorate(entry)
    entry.mandatory_func = function()
        local status = API.getAttachmentStatus(entry.key)
        local label = entry.file_type or ""
        if status ~= "not_downloaded" then label = label .. " · " .. status_text(status) end
        return label
    end
    return entry
end

function AttachmentMenu.group(entries)
    local results, groups = {}, {}
    for _, entry in ipairs(entries) do
        if entry.collection or entry.is_label or entry.wildcard_collection then
            results[#results + 1] = entry
        elseif not entry.parent_key then
            results[#results + 1] = decorate(entry)
        elseif groups[entry.parent_key] then
            local group = groups[entry.parent_key]
            group.attachment_keys[#group.attachment_keys + 1] = entry.key
        else
            local group = { key = entry.parent_key, text = entry.text,
                attachment_keys = { entry.key }, first_attachment = entry }
            groups[entry.parent_key] = group
            results[#results + 1] = group
        end
    end
    for index, entry in ipairs(results) do
        if entry.attachment_keys then
            if #entry.attachment_keys == 1 then
                results[index] = decorate(entry.first_attachment)
            else
                entry.first_attachment = nil
                entry.attachment_group = true
                entry.mandatory_func = function()
                    local downloaded = 0
                    for _, key in ipairs(entry.attachment_keys) do
                        if API.getAttachmentStatus(key) == "downloaded" then downloaded = downloaded + 1 end
                    end
                    if downloaded > 0 then
                        return AttachmentMenu.text("%d files · %d downloaded"):format(#entry.attachment_keys, downloaded)
                    end
                    return AttachmentMenu.text("%d files"):format(#entry.attachment_keys)
                end
            end
        end
    end
    return results
end

function AttachmentMenu.children(entries)
    for index, entry in ipairs(entries) do
        local title, filename = entry.attachment_title or "", entry.filename or ""
        local label = filename ~= "" and filename or title
        if title ~= "" and filename ~= "" and title ~= filename then label = title .. " — " .. filename end
        entry.text = index .. ". " .. label
        decorate(entry)
    end
    return entries
end

function AttachmentMenu.details(entry)
    local lines = {}
    local function field(message, value)
        if value and value ~= "" then lines[#lines + 1] = AttachmentMenu.text(message):format(value) end
    end
    local item = API.getItems()[entry.key]
    if not item then return entry.text end
    if entry.attachment_group then
        field("Document: %s", item.data.title)
        for _, attachment in ipairs(AttachmentMenu.children(API.displayAttachments(entry.key))) do
            lines[#lines + 1] = "\n" .. attachment.text .. "\n" .. attachment.mandatory_func()
        end
        lines[#lines + 1] = "\n" .. AttachmentMenu.text("Long-press a file to see its full name and details.")
    else
        local parent = API.getItems()[item.data.parentItem]
        field("Document: %s", parent and parent.data.title)
        field("Attachment: %s", item.data.title)
        field("Filename: %s", item.data.filename)
        field("Format: %s", entry.file_type or item.data.contentType)
        local status, _, size = API.getAttachmentStatus(entry.key)
        field("Status: %s", status_text(status))
        if size then field("Local size: %s", ("%.1f KiB"):format(size / 1024)) end
        local mtime = tonumber(item.data.mtime)
        if mtime then field("File modified: %s", os.date("%Y-%m-%d %H:%M", math.floor(mtime / 1000))) end
        if parent and parent.data.DOI then lines[#lines + 1] = "DOI: " .. parent.data.DOI end
        -- A stable identifier also distinguishes attachments with identical names.
        lines[#lines + 1] = "\nZotero key: " .. entry.key
    end
    return table.concat(lines, "\n")
end

return AttachmentMenu
