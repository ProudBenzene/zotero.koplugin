local support = require("tests/support")
local I18n = require("i18n")
local API
local gettext_metatable = getmetatable(support.GetText)
local native_gettext = gettext_metatable.__call

describe("Plugin localization", function()
    before_each(function() API = support.setup() end)
    after_each(function()
        gettext_metatable.__call = native_gettext
        support.teardown()
    end)

    it("uses the current interface language and delegates other languages and missing keys to gettext", function()
        gettext_metatable.__call = function(_, value) return "catalog:" .. value end
        for _, language in ipairs({"zh_CN", "zh_CN.UTF-8", "zh_Hans", "zh_Hans_CN"}) do
            support.GetText.current_lang = language
            assert(I18n.text("Synchronize") == "同步")
            assert(I18n.text("Unlisted message") == "catalog:Unlisted message")
        end
        for _, language in ipairs({"C", "en", "fr", "zh_TW"}) do
            support.GetText.current_lang = language
            assert(I18n.text("Synchronize") == "catalog:Synchronize")
            assert(I18n.error("Error: timeout") == "Error: timeout")
        end
    end)

    it("localizes menus and forms while keeping account data verbatim", function()
        local plugin = support.plugin()
        support.GetText.current_lang = "zh_CN"
        local menus = {}
        plugin:addToMainMenu(menus)
        local entries = menus.zotero.sub_item_table
        assert(entries[1].text == "浏览文献库" and entries[2].text == "同步")
        assert(entries[3].text == "维护" and entries[3].sub_item_table[1].text == "重新同步整个文献库")
        plugin:setAccount()
        local account = plugin.account_dialog
        assert(account.title == "Zotero 账户设置" and account.fields[1].hint == "用户 ID（数字）")
        assert(account.fields[2].hint == "API 密钥" and account.fields[2].text == "FAKE-KEY")
        assert(account.buttons[1][2].text == "保存")
        plugin:setWebdavAccount()
        assert(plugin.webdav_account_dialog.fields[1].hint == "WebDAV 地址")
        assert(dofile("_meta.lua").description == "浏览 Zotero 文献库，下载并阅读 PDF/EPUB 附件。")
    end)

    it("distinguishes empty attachment, collection, library and search views", function()
        local browser = support.plugin().browser
        support.seed({}, {EMPTY001={key="EMPTY001",data={name="Empty",parentCollection=false}}})
        gettext_metatable.__call = function(_, value)
            return value == "All Items" and "宿主翻译的 All Items" or value
        end
        support.GetText.current_lang = "zh_CN"
        browser:displayCollection(nil)
        assert(browser.last_items[1].text == "All Items")
        browser:displayAttachments("MISSING1")
        assert(browser.last_items[1].text == "暂无附件")
        browser:displayCollection("EMPTY001")
        assert(browser.last_items[1].text == "暂无分类或可阅读附件" and browser.title == "Empty")
        browser:displaySearchResults("")
        assert(browser.title == "All Items" and browser.last_items[1].text == "暂无可阅读附件")
        browser:displaySearchResults("missing")
        assert(browser.last_items[1].text == "未找到匹配的附件")
        browser:onLeftButtonTap()
        local search = support.UI.shown[#support.UI.shown]
        assert(search.input_hint == "搜索关键词")
        assert(search.description == "按标题、作者信息或 DOI 搜索 PDF/EPUB 附件。")
        support.GetText.current_lang = "C"
        browser:displaySearchResults("missing")
        assert(browser.last_items[1].text == "No Results")
    end)

    it("translates progress stages after the module has already loaded", function()
        local ProgressDialog = require("progressdialog")
        support.GetText.current_lang = "zh_Hans"
        local dialog = ProgressDialog:new{operation="sync"}
        assert(dialog.text == "正在同步 Zotero 文献库\n正在检查 Zotero 账户…")
        dialog:update{stage="items", completed=50, total=100, bytes=1024}
        assert(dialog.text:find("正在获取文献库条目…",1,true))
        assert(dialog.text:find("已处理：50 / 100（50%）",1,true))
        assert(dialog.text:find("已接收：1.0 KiB",1,true))
        support.GetText.current_lang = "C"
        local english = ProgressDialog:new{operation="sync"}
        english:update{stage="items", completed=1}
        assert(english.text:find("Fetching library items…",1,true))
    end)

    it("translates nested sync and download errors without changing technical values", function()
        support.GetText.current_lang = "zh_CN"
        local nested = "Fetching collections (page 2): Error: Network request failed: timeout"
        assert(I18n.error(nested) == "获取分类失败（接口分页第 2 页）：请求失败：网络请求失败：连接超时")
        assert(I18n.error("Checking Zotero account: Error: API responded with status code 403")
            == "检查 Zotero 账户：错误：API 返回状态码 403")
        assert(I18n.error("Fetching deletions: Error: invalid deletion log in Zotero response")
            == "获取已删除条目：错误：Zotero 响应中的删除记录无效。")
        assert(I18n.error("Could not download attachment: Error: File download timed out while waiting for data (received 42 bytes; timeout)")
            == "无法下载附件：请求失败：等待数据时文件下载超时（已接收 42 字节；连接超时）")
        local diagnostic = "/tmp/English Title.pdf: Permission denied"
        assert(I18n.error("Could not save attachment: " .. diagnostic) == "无法保存附件：" .. diagnostic)
        assert(I18n.error("Could not read Zotero cache: librarycache.lua:23: Invalid cache JSON separator")
            == "无法读取 Zotero 缓存：librarycache.lua:23: 缓存 JSON 分隔符无效")
        assert(I18n.error("ANNOT001: Missing annotation position") == "ANNOT001: 缺少批注位置信息")
        local raw = "archive: bad CRC for English Title.pdf"
        assert(I18n.error("Could not extract the attachment from its WebDAV archive: " .. raw)
            == "无法从 WebDAV 压缩包中解压附件：" .. raw)
        assert(I18n.error("Unknown external error: /tmp/timeout.pdf") == "Unknown external error: /tmp/timeout.pdf")
    end)

    it("keeps library-change retries in English internally and translates the final UI error", function()
        local plugin = support.plugin()
        support.GetText.current_lang = "zh_CN"
        support.response = function(req, index)
            if index == 1 then return support.key(req) end
            return support.respond(req, {}, index)
        end
        local sentinel = "The Zotero library changed during synchronization. Please retry."
        assert(API.syncAllItems() == sentinel and #support.requests == 7)
        API.syncAllItems = function() return sentinel end
        plugin:onZoteroSyncAction()
        support.UI.scheduled[1]()
        assert(support.UI.shown[#support.UI.shown].text == "同步失败。\n文献库在同步期间发生变化，请重试。")
    end)

    it("reports Chinese sync statistics without changing the library object counts", function()
        local plugin = support.plugin()
        support.GetText.current_lang = "zh_CN"
        support.seed({
            PARENT01={key="PARENT01",data={itemType="journalArticle",title="Paper"}},
            ATTACH01=support.attachment("ATTACH01","paper.pdf","PARENT01"),
            NOTE0001={key="NOTE0001",data={itemType="note"}},
        }, {COLLECT1={key="COLLECT1",data={name="Collection",parentCollection=false}}})
        API.syncAllItems = function() return nil end
        plugin:onZoteroSyncAction()
        support.UI.scheduled[1]()
        local result = support.UI.shown[#support.UI.shown].text
        assert(result:find("同步完成。\n文献库条目：3\n分类：1\n可阅读 PDF/EPUB 附件：1",1,true))
        assert(result:find("PDF 批注已缓存：0；未变化：0；失败：0",1,true))
    end)

    it("keeps English titles, filenames, keys and real metadata intact", function()
        local browser = support.plugin().browser
        support.GetText.current_lang = "zh_CN"
        local parent = {key="PARENT01",meta={creatorSummary="Unknown"},data={itemType="journalArticle",title="Untitled"}}
        local attachment = support.attachment("ATTACH01", "English Title.pdf", "PARENT01")
        attachment.data.title = "Supplementary material"
        support.seed({PARENT01=parent, ATTACH01=attachment})
        browser:displaySearchResults("")
        assert(browser.last_items[1].text == "Unknown - Untitled")
        browser:onMenuHold(browser.last_items[1])
        local details = support.UI.shown[#support.UI.shown].text
        assert(details:find("文件名：English Title.pdf",1,true) and details:find("Zotero key: ATTACH01",1,true))
        parent.meta, parent.data.title = nil, nil
        support.seed({PARENT01=parent, ATTACH01=attachment})
        browser:displaySearchResults("")
        assert(browser.last_items[1].text == "未知作者 - 无标题")
    end)

    it("translates annotation error details and reports the total error count", function()
        local Annotations = require("annotations")
        support.GetText.current_lang = "zh_CN"
        local errors = {}
        for index = 1, 6 do errors[index] = "ATTACH0" .. index .. ": ANNOT001: Missing annotation position" end
        local stats = {updated=0, unchanged=0, failed=6, unsupported=0, errors=errors}
        local summary = Annotations.summary(stats)
        assert(summary:find("ATTACH01: ANNOT001: 缺少批注位置信息",1,true))
        assert(summary:find("……（共 6 条错误）",1,true) and not summary:find("ATTACH06",1,true))
        assert(stats.errors[1] == "ATTACH01: ANNOT001: Missing annotation position")
        support.GetText.current_lang = "C"
        assert(Annotations.summary(stats):find("ATTACH01: ANNOT001: Missing annotation position",1,true))
    end)
end)
