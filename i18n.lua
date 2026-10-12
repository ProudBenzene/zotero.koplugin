-- Plugin messages are not shipped in KOReader's gettext catalog.
-- Keep this module lightweight: plugin metadata also loads it.
local gettext = require("gettext")
local I18n = {}

local chinese = {
    ["Delete all downloaded documents"] = "删除所有本机下载的文献",
    ["Delete all local downloads"] = "删除所有本机下载",
    ["Removing local downloads"] = "正在清理本机下载",
    ["Scanning local downloads…"] = "正在扫描本机下载…",
    ["Deleting local downloads…"] = "正在删除本机下载…",
    ["Local download cleanup"] = "本机下载清理结果",
    ["Preview local downloads to delete"] = "待删除文献预览",
    ["Account: %s; attachment key: %s"] = "账户：%s；附件 key：%s",
    ["Legacy (account unknown)"] = "旧版下载（账户未知）",
    ["Local path: %s"] = "本地路径：%s",
    ["Document already deleted; only remaining local data will be cleaned."] = "文献文件已删除，仅清理残留的本地数据。",
    ["Currently open — will be skipped."] = "正在阅读，将跳过。",
    ["Unidentified files will be kept:"] = "以下无法识别的文件将保留：",
    ["All identified local downloads deleted."] = "已清空可识别的本机下载。",
    ["No local downloads to delete."] = "没有可删除的本机下载。",
    ["Close the open document before deleting downloads that share its reading data."] = "这些下载与正在阅读的文献共用阅读数据，请关闭文献后再删除。",
    ["Local download cleanup finished with remaining files."] = "本机下载清理完成，仍有文件或数据未删除。",
    ["Could not scan local downloads."] = "无法扫描本机下载。",
    ["Deleted: %d; failed: %d; open: %d; changed: %d; cleanup pending: %d; unidentified: %d"] = "已删除：%d；失败：%d；正在阅读：%d；目标已变化：%d；数据待清理：%d；无法识别：%d",
    ["Unidentified: %s"] = "无法识别：%s",
    ["Delete this device's Zotero downloads from all accounts?\nPDF: %d; EPUB: %d; accounts: %d; file size: %.1f MiB; pending cleanup: %d"] = "删除本机所有账户的 Zotero 下载？\nPDF：%d；EPUB：%d；账户：%d；文件大小：%.1f MiB；待清理记录：%d",
    ["Local annotations, bookmarks and reading progress will also be deleted. Zotero cloud data is kept. You can download the documents again."] = "这些文件的本地批注、书签和阅读进度也会删除。Zotero 云端数据会保留，可重新下载文献。",
    ["Open and unidentified files will be skipped. Unidentified: %d"] = "正在阅读和无法识别的文件会跳过。无法识别：%d",
    ["Delete this local document, its annotations, bookmarks and reading progress? Zotero cloud data is kept. You can download it again."] = "删除本地文献及其批注、书签和阅读进度？Zotero 云端数据会保留，可重新下载。",
    ["Local document and reading data deleted."] = "已删除本地文献及其批注、书签和阅读进度。",
    ["Local document deleted; some local data could not be removed."] = "本地文献已删除，但部分本地数据未能清理。",
    ["Could not delete the local document."] = "无法删除本地文献。",
    ["Close this document before deleting its local copy."] = "请先关闭此文献，再删除本地文件。",
    ["Local document not found."] = "未找到本地文献。",
    ["Only downloaded PDF or EPUB attachments can be removed."] = "只能删除已下载的 PDF 或 EPUB 附件。",
    ["The document path does not match its attachment storage."] = "文献路径与附件存储目录不匹配。",
    ["The local document changed. Open its details again."] = "本地文献已发生变化，请重新打开附件信息。",
    ["The local file path changed. Scan the downloads again."] = "本地文件已发生变化，请重新扫描下载。",
    ["The local cleanup record is invalid."] = "本地清理记录无效。",
    ["The local cleanup paths are invalid."] = "本地清理路径无效。",
    ["Could not save the local cleanup record: %s"] = "无法保存本地清理记录：%s",
    ["The download storage is unavailable."] = "下载存储目录不可用。",
    ["The download storage path is redirected."] = "下载存储目录发生路径重定向。",
    ["Downloaded"] = "已下载",
    ["Not downloaded"] = "未下载",
    ["Update available"] = "待更新",
    ["%d files"] = "%d 个附件",
    ["%d files · %d downloaded"] = "%d 个附件 · 已下载 %d",
    ["Attachments"] = "附件",
    ["Attachment details"] = "附件信息",
    ["Document: %s"] = "文献：%s",
    ["Attachment: %s"] = "附件：%s",
    ["Filename: %s"] = "文件名：%s",
    ["Format: %s"] = "格式：%s",
    ["Status: %s"] = "状态：%s",
    ["Local size: %s"] = "本地大小：%s",
    ["File modified: %s"] = "文件修改时间：%s",
    ["Open"] = "打开",
    ["Delete local file"] = "删除本地文件",
    ["Delete this local PDF, its annotations, bookmarks and reading progress? Zotero cloud data is kept. You can download it again."] = "删除本地 PDF 及其批注、书签和阅读进度？Zotero 云端数据会保留，可重新下载。",
    ["Local PDF and annotations deleted."] = "已删除本地 PDF 及其批注、书签和阅读进度。",
    ["Local PDF deleted; some local data could not be removed."] = "本地 PDF 已删除，但部分本地数据未能清理。",
    ["Could not delete the local PDF."] = "无法删除本地 PDF。",
    ["Close this PDF before deleting its local copy."] = "请先关闭此 PDF，再删除本地文件。",
    ["Local PDF not found."] = "未找到本地 PDF。",
    ["Only downloaded PDF attachments can be removed."] = "只能删除已下载的 PDF 附件。",
    ["The PDF path does not match its attachment storage."] = "PDF 路径与附件存储目录不匹配。",
    ["The local PDF changed. Open its details again."] = "本地 PDF 已发生变化，请重新打开附件信息。",
    ["Long-press a file to see its full name and details."] = "长按附件可查看完整名称和详细信息。",
    ["Fetching PDF annotations…"] = "正在获取 PDF 批注…",
    ["Checking annotation file…"] = "正在核对批注对应的文件…",
    ["Saving PDF annotations…"] = "正在保存 PDF 批注…",
    ["Annotations changed. Retrying…"] = "批注有更新，正在重试…",
    ["Synchronizing downloaded PDF annotations"] = "正在同步已下载 PDF 的批注",
    ["Refetch downloaded PDF annotations"] = "重新获取已下载 PDF 的批注",
    ["Refresh annotations"] = "更新批注",
    ["Refreshing PDF annotations"] = "正在更新 PDF 批注",
    ["PDF annotations updated."] = "PDF 批注已更新。",
    ["Area annotation"] = "区域批注",
    ["No comment."] = "无评论。",
    ["Go to annotation"] = "转到批注",
    ["Yellow"] = "黄",
    ["Red"] = "红",
    ["Green"] = "绿",
    ["Blue"] = "蓝",
    ["Purple"] = "紫",
    ["Magenta"] = "品红",
    ["Orange"] = "橙",
    ["Gray"] = "灰",
    ["Olive"] = "橄榄",
    ["Cyan"] = "青",
    ["Zotero annotations are read-only"] = "Zotero 批注只读",
    ["Edit this annotation in Zotero, then synchronize and reopen the PDF."] = "请在 Zotero 中修改此批注，然后同步并重新打开 PDF。",
    ["PDF file protected by Zotero"] = "Zotero PDF 原文件已保护",
    ["This Zotero PDF is protected. Local annotations are saved in KOReader settings."] = "此 Zotero PDF 原文件已保护。本地批注保存于 KOReader 文档设置。",
    ["Apply current style and color to local highlights? Zotero annotations stay read-only."] = "将当前样式和颜色应用于本地高亮？Zotero 批注保持只读。",
    ["Update selected local annotations? Zotero annotations stay read-only."] = "修改选中的本地批注？Zotero 批注保持只读。",
    ["Local annotations updated: %d; read-only Zotero annotations skipped: %d"] = "已修改本地批注：%d；已跳过只读 Zotero 批注：%d",
    ["PDF annotations were not updated."] = "PDF 批注未更新。",
    ["Could not apply Zotero annotations."] = "未能显示 Zotero 批注。",
    ["Zotero annotations are displayed in original-page mode."] = "Zotero 批注支持原版页面显示，请关闭文字重排。",
    ["PDF annotations cached: %d; unchanged: %d; failed: %d"] = "PDF 批注已缓存：%d；未变化：%d；失败：%d",
    ["Unsupported annotations skipped: %d"] = "已跳过不支持的批注：%d",
    ["Cached annotations take effect when the PDF is next opened."] = "缓存批注将在下次打开 PDF 时生效。",
    ["Quick access to all PDFs of your Zotero library."] = "浏览 Zotero 文献库，下载并阅读 PDF/EPUB 附件。",
    ["Zotero Open"] = "打开 Zotero",
    ["Zotero Sync"] = "同步 Zotero",
    ["Browse"] = "浏览文献库",
    ["Synchronize"] = "同步",
    ["Maintenance"] = "维护",
    ["Resync entire collection"] = "重新同步整个文献库",
    ["Settings"] = "设置",
    ["Configure Zotero account"] = "配置 Zotero 账户",
    ["Enable WebDAV storage"] = "启用 WebDAV 存储",
    ["Configure WebDAV account"] = "配置 WebDAV 账户",
    ["Check WebDAV connection"] = "测试 WebDAV 连接",
    ["Items per page"] = "每页条目数",
    ["Edit User Info"] = "Zotero 账户设置",
    ["User ID (integer)"] = "用户 ID（数字）",
    ["API Key"] = "API 密钥",
    ["Cancel"] = "取消",
    ["Update"] = "保存",
    ["The User ID must be an integer number."] = "用户 ID 必须为纯数字。",
    ["Edit WebDAV credentials"] = "WebDAV 账户设置",
    ["URL"] = "WebDAV 地址",
    ["Username"] = "用户名",
    ["Password"] = "密码",
    ["Success, WebDAV works!"] = "WebDAV 连接正常。",
    ["WebDAV could not connect: "] = "WebDAV 无法连接：",
    ["Set items per page"] = "设置每页条目数",
    ["This change requires a restart of KOReader to take effect."] = "重启 KOReader 后生效。",
    ["Synchronizing Zotero library"] = "正在同步 Zotero 文献库",
    ["Downloading attachment"] = "正在下载附件",
    ["Checking local file…"] = "正在检查本地文件…",
    ["Opening local file…"] = "正在打开本地文件…",
    ["Downloading file…"] = "正在下载文件…",
    ["Download interrupted. Resuming…"] = "下载中断，正在恢复传输…",
    ["Connection interrupted. Retrying this page…"] = "连接中断，正在重新请求…",
    ["Invalid downloaded archive. Downloading again…"] = "下载的压缩包损坏，正在重新下载…",
    ["Extracting attachment…"] = "正在解压附件…",
    ["Checking downloaded file…"] = "正在校验下载文件…",
    ["Saving file…"] = "正在保存文件…",
    ["Checking Zotero account…"] = "正在检查 Zotero 账户…",
    ["Fetching library items…"] = "正在获取文献库条目…",
    ["Fetching collections…"] = "正在获取分类…",
    ["Applying deletions…"] = "正在更新已删除条目…",
    ["Saving library…"] = "正在保存文献库…",
    ["Library changed. Restarting synchronization…"] = "文献库有变动，正在重新同步…",
    ["Library is up to date."] = "文献库已是最新。",
    ["Complete."] = "已完成。",
    ["Preparing…"] = "正在准备…",
    ["Waiting for response…"] = "正在等待响应…",
    ["Processed: %d / %d (%d%%)"] = "已处理：%d / %d（%d%%）",
    ["Processed: %d"] = "已处理：%d",
    ["Received: %s"] = "已接收：%s",
    ["Checked: %s"] = "已校验：%s",
    ["Synchronization complete."] = "同步完成。",
    ["Library items: %d\nCollections: %d\nVisible PDF/EPUB attachments: %d"] = "文献库条目：%d\n分类：%d\n可阅读 PDF/EPUB 附件：%d",
    ["Synchronization failed."] = "同步失败。",
    ["… (%d)"] = "……（共 %d 条错误）",
    ["No Items"] = "暂无附件",
    ["Search results"] = "搜索结果",
    ["Search Zotero titles"] = "搜索 Zotero 文献",
    ["search query"] = "搜索关键词",
    ["This will search title, first author and DOI of all entries."] = "按标题、作者信息或 DOI 搜索 PDF/EPUB 附件。",
    ["Search"] = "搜索",
    ["Loading Zotero library…"] = "正在加载 Zotero 文献库…",
    ["Could not load Zotero library."] = "无法加载 Zotero 文献库。",
    ["Fetching %s (page %d): %s"] = "获取%s失败（接口分页第 %d 页）：%s",
    ["Checking Zotero account: %s"] = "检查 Zotero 账户：%s",
    ["Fetching deletions: %s"] = "获取已删除条目：%s",
    ["File download timed out while waiting for data (received %d bytes; %s)"] = "等待数据时文件下载超时（已接收 %d 字节；%s）",
    ["Incomplete file download: received %d of %d bytes. Please retry."] = "文件下载不完整：仅接收 %d / %d 字节，请重试。",
    ["Zotero requested a delay. Please retry in %d seconds."] = "Zotero 要求稍后再试，请在 %d 秒后重试。",
    ["Network request failed: %s"] = "网络请求失败：%s",
    ["Error: API responded with status code %s"] = "错误：API 返回状态码 %s",
    ["Connection failed: %s"] = "连接失败：%s",
    ["WebDAV responded with status code %s"] = "WebDAV 返回状态码：%s",
    ["The Zotero library changed during synchronization. Please retry."] = "文献库在同步期间发生变化，请重试。",
    ["Could not open file."] = "无法打开文件。",
    ["Could not initialize Zotero."] = "无法初始化 Zotero。",
    ["Could not encode cache data"] = "无法对缓存数据编码",
    ["Invalid JSON data"] = "JSON 数据无效",
    ["Could not read Zotero cache: "] = "无法读取 Zotero 缓存：",
    ["Could not save Zotero cache: "] = "无法保存 Zotero 缓存：",
    ["Could not create Zotero directory: "] = "无法创建 Zotero 目录：",
    ["Could not create attachment storage: "] = "无法创建附件存储目录：",
    ["Error: failed to parse JSON in response"] = "错误：响应 JSON 解析失败",
    ["Error: expected a JSON array in Zotero response"] = "错误：Zotero 响应应为 JSON 数组",
    ["Error: missing or invalid Last-Modified-Version header"] = "错误：响应缺失或包含无效的 Last-Modified-Version 标头",
    ["Error: invalid pagination link"] = "错误：分页链接无效",
    ["Error: incomplete JSON array in Zotero response"] = "错误：Zotero 响应中的 JSON 数组不完整",
    ["Error: invalid object in Zotero response"] = "错误：Zotero 响应中包含无效对象",
    ["Error: inconsistent Total-Results header"] = "错误：Total-Results 标头不一致",
    ["Error: incomplete pagination"] = "错误：分页未完全接收",
    ["Checking Zotero account: "] = "检查 Zotero 账户：",
    ["Could not synchronize Zotero: "] = "无法同步 Zotero：",
    ["Invalid attachment key or filename"] = "无效的附件标识或文件名",
    ["Invalid download URL"] = "下载地址无效",
    ["Could not create download file: "] = "无法创建下载临时文件：",
    ["Could not save download: "] = "无法保存下载文件：",
    ["Missing download redirect location"] = "缺少重定向地址",
    ["Refusing an HTTPS download redirect to HTTP"] = "拒绝从 HTTPS 重定向至不安全的 HTTP",
    ["Unexpected encoding in file download"] = "文件下载编码格式不支持",
    ["Invalid response length in file download"] = "文件下载响应长度无效",
    ["Could not save resumed download: "] = "无法保存续传文件：",
    ["Too many download redirects"] = "重定向次数过多",
    ["Could not extract the attachment from its WebDAV archive"] = "无法从 WebDAV 压缩包中解压附件",
    ["Could not save extracted attachment: "] = "无法保存解压后的附件：",
    ["The attachment was not found in the library"] = "文献库中未找到该附件",
    ["This item is not an attachment"] = "该条目不是附件",
    ["Could not create attachment directory: "] = "无法创建附件目录：",
    ["Could not save unpacked attachment: "] = "无法保存解压后的附件：",
    ["Could not save attachment: "] = "无法保存附件：",
    ["Could not save attachment metadata: "] = "无法保存附件元数据：",
    ["Only PDF annotations are supported"] = "仅支持 PDF 批注",
    ["Invalid PDF attachment in annotation response"] = "批注响应中包含无效的 PDF 附件",
    ["Could not fetch PDF annotations: "] = "无法获取 PDF 批注：",
    ["Invalid annotation cache JSON"] = "批注缓存 JSON 无效",
    ["Could not encode PDF annotations"] = "无法对 PDF 批注编码",
    ["Missing annotation position"] = "缺少批注位置信息",
    ["Invalid annotation page position"] = "批注页面位置无效",
    ["Invalid annotation rectangles"] = "批注选框矩形坐标无效",
    ["Invalid PDF annotation snapshot"] = "PDF 批注快照数据无效",
    ["Invalid annotation object in PDF snapshot"] = "PDF 快照中的批注对象无效",
    ["Invalid annotation field: "] = "批注字段无效：",
    ["The annotation library version went backwards"] = "批注版本异常倒退",
    ["Could not save PDF annotations: "] = "无法保存 PDF 批注：",
    ["Invalid annotation date"] = "批注日期无效",
    ["Invalid annotation timezone"] = "批注时区无效",
    ["Annotation page exceeds PDF page count"] = "批注所在页码超出 PDF 总页数",
    ["Could not read PDF page dimensions"] = "无法读取 PDF 页面尺寸",
    ["Annotation is outside the standard PDF page; special page geometry is unsupported"] = "批注超出标准 PDF 页面范围；不支持特殊页面几何参数",
    ["This PDF reader does not provide annotation geometry methods"] = "此 PDF 阅读器不支持批注位置计算",
    ["Reader annotations are not initialized"] = "阅读器批注未初始化",
    ["Could not confirm the PDF identity of previously imported annotations"] = "无法确认之前导入的批注是否对应当前 PDF",
    ["Could not save imported annotations: "] = "无法保存已导入的批注：",
    ["Invalid cache JSON separator"] = "缓存 JSON 分隔符无效",
    ["Unexpected end of cache JSON"] = "缓存 JSON 意外截断",
    ["Invalid cache object key"] = "缓存键名无效",
    ["Invalid cache record"] = "缓存记录无效",
    ["Unexpected trailing cache JSON"] = "缓存 JSON 包含多余的末尾内容",
    ["Could not parse cache JSON: "] = "无法解析缓存 JSON：",
    ["Invalid Zotero cache. Use Maintenance > Resync entire collection."] = "Zotero 本地缓存无效，请使用“维护 → 重新同步整个文献库”。",
    ["Error: must set a numeric User ID"] = "请先设置数字用户 ID。",
    ["Error: must set API Key"] = "请先设置 API 密钥。",
    ["Error: the API key does not belong to this User ID"] = "API 密钥与该用户 ID 不匹配。",
    ["Error: the API key does not permit reading your library"] = "该 API 密钥没有文献库读取权限。",
    ["Zotero rate limit reached. Please retry later."] = "已达到 Zotero 请求频率限制，请稍后重试。",
    ["Error: %s"] = "请求失败：%s",
    ["request failed"] = "请求失败",
    ["Error: incomplete metadata response (received %d of %d bytes)"] = "元数据响应不完整（已接收 %d / %d 字节）。",
    ["Error: invalid deletion log in Zotero response"] = "错误：Zotero 响应中的删除记录无效。",
    ["The library version went backwards. Please resync the entire collection."] = "文献库版本异常倒退，请重新同步整个文献库。",
    ["A valid HTTP or HTTPS WebDAV URL is required"] = "请填写有效的 HTTP 或 HTTPS WebDAV 地址。",
    ["Access forbidden. Check username and password."] = "访问被拒绝，请检查用户名和密码。",
    ["Attachment not found"] = "未找到附件。",
    ["The resumed download does not match the original file or byte range"] = "续传内容与原文件或字节范围不一致。",
    ["Unsupported attachment link mode: %s. Linked files and linked URLs are not stored by Zotero."] = "不支持的附件链接方式：%s。Zotero 不存储链接文件和链接网址附件。",
    ["Only PDF and EPUB attachments are supported"] = "仅支持 PDF 和 EPUB 附件。",
    ["The downloaded ZIP does not match Zotero's storage checksum."] = "下载的 ZIP 文件与 Zotero 校验和不匹配。",
    ["The downloaded file does not match Zotero's attachment metadata. Synchronize the library and retry."] = "下载的文件与 Zotero 附件元数据不匹配，请同步文献库后重试。",
    ["The downloaded attachment is empty"] = "下载的附件文件为空。",
    ["Could not download attachment: %s"] = "无法下载附件：%s",
    ["Cached annotations belong to a different PDF file; download the current attachment"] = "缓存批注属于不同的 PDF 文件，请下载当前附件。",
    ["unzip command failed (%s: %s)"] = "unzip 解压命令失败（%s：%s）",
    [". The unzip command failed."] = "。unzip 解压命令失败。",
    ["Unknown"] = "未知作者",
    ["Untitled"] = "无标题",
}

local contexts = {
    ["No Items"] = { attachments = "暂无附件", collection = "暂无分类或可阅读附件" },
    ["No Results"] = { library = "暂无可阅读附件", search = "未找到匹配的附件" },
}

local function is_chinese()
    local language = type(gettext) == "table" and gettext.current_lang or ""
    return language:match("^zh_CN") or language:match("^zh_Hans")
end

function I18n.text(message, context)
    if is_chinese() then
        local contextual = contexts[message]
        return contextual and contextual[context] or chinese[message] or gettext(message)
    end
    return gettext(message)
end

-- Only known, complete error templates are matched. Variables such as paths,
-- filenames and external diagnostics are kept verbatim unless marked nested.
local error_templates = {
    { message = "Could not save the local cleanup record: %s", nested = 1 },
    { message = "Fetching %s (page %d): %s", nested = 3, stage = 1 },
    { message = "File download timed out while waiting for data (received %d bytes; %s)", nested = 2 },
    { message = "Incomplete file download: received %d of %d bytes. Please retry." },
    { message = "Zotero requested a delay. Please retry in %d seconds." },
    { message = "Error: incomplete metadata response (received %d of %d bytes)" },
    { message = "Error: API responded with status code %s" },
    { message = "WebDAV responded with status code %s" },
    { message = "Unsupported attachment link mode: %s. Linked files and linked URLs are not stored by Zotero." },
    { message = "unzip command failed (%s: %s)" },
}
local stage_names = { items = "文献库条目", collections = "分类", annotations = "批注" }
local network_errors = {
    timeout = "连接超时", closed = "连接已关闭",
    ["sink timeout"] = "接收数据超时（sink timeout）",
    wantread = "正在等待接收数据（wantread）", ["request failed"] = "请求失败",
}
local error_prefixes = { "Error: ", "Could not download attachment: ", "Network request failed: ",
    "Connection failed: ", "Fetching deletions: " }
for message in pairs(chinese) do
    if message:sub(-2) == ": " then error_prefixes[#error_prefixes + 1] = message end
end

local function escape_pattern(value)
    return (value:gsub("(%W)", "%%%1"))
end

for _, template in ipairs(error_templates) do
    local parts, formats, offset = { "^" }, {}, 1
    while true do
        local first, last, format = template.message:find("%%([ds])", offset)
        if not first then break end
        parts[#parts + 1] = escape_pattern(template.message:sub(offset, first - 1))
        parts[#parts + 1] = format == "d" and "(%d+)" or "(.-)"
        formats[#formats + 1] = format
        offset = last + 1
    end
    parts[#parts + 1] = escape_pattern(template.message:sub(offset)) .. "$"
    template.pattern, template.formats = table.concat(parts), formats
end

local unpack_args = table.unpack or unpack
local function translate_error(message, depth)
    if depth > 16 then return message end
    if chinese[message] then return chinese[message] end
    if network_errors[message] then return network_errors[message] end
    for _, template in ipairs(error_templates) do
        local arguments = { message:match(template.pattern) }
        if #arguments > 0 then
            for index, format in ipairs(template.formats) do
                if format == "d" then arguments[index] = tonumber(arguments[index]) end
            end
            if template.nested then
                arguments[template.nested] = translate_error(arguments[template.nested], depth + 1)
            end
            if template.stage then
                arguments[template.stage] = stage_names[arguments[template.stage]] or arguments[template.stage]
            end
            return chinese[template.message]:format(unpack_args(arguments))
        end
    end
    for _, prefix in ipairs(error_prefixes) do
        if message:sub(1, #prefix) == prefix then
            local translated = prefix == "Error: " and chinese["Error: %s"]:format("")
                or chinese[prefix] or I18n.text(prefix .. "%s"):format("")
            return translated .. translate_error(message:sub(#prefix + 1), depth + 1)
        end
    end
    local archive = "Could not extract the attachment from its WebDAV archive"
    if message:sub(1, #archive + 2) == archive .. ": " then
        return chinese[archive] .. "：" .. translate_error(message:sub(#archive + 3), depth + 1)
    elseif message == archive .. ". The unzip command failed." then
        return chinese[archive] .. chinese[". The unzip command failed."]
    end
    -- pcall/error may prepend a Lua source location; keep that diagnostic.
    local location, detail = message:match("^(.-%.lua:%d+: )(.*)$")
    if location then return location .. translate_error(detail, depth + 1) end
    -- Annotation validation can identify the offending Zotero annotation key.
    local key, keyed_detail = message:match("^([A-Z0-9]+): (.*)$")
    if key and #key == 8 then return key .. ": " .. translate_error(keyed_detail, depth + 1) end
    return message
end

function I18n.error(message)
    message = tostring(message)
    if not is_chinese() then return message end
    return translate_error(message, 0)
end

return I18n
