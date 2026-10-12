local support = require("tests/support")
local LocalFiles = require("localfiles")
local API, browser, directory, path

describe("Local PDF removal", function()
    before_each(function()
        API = support.setup()
        browser = support.plugin().browser
        support.seed({ATTACH01=support.attachment("ATTACH01","paper.pdf",false)})
        directory,path = API.getDirAndPath("ATTACH01")
        assert(support.makePath(directory))
        support.write(path,"local PDF")
        support.write(directory.."/.zotero-cache.json",support.JSON.encode({version=10}))
        support.write(directory.."/.zotero-annotations.json","cached cloud annotations")
        browser:displaySearchResults("")
    end)
    after_each(support.teardown)

    it("asks for confirmation and does nothing when cancelled",function()
        support.GetText.current_lang="zh_CN"
        browser:onMenuHold(browser.last_items[1])
        local details = support.UI.shown[#support.UI.shown]
        local button = details.buttons_table[3][1]
        assert(button.text=="删除本地文件" and button.enabled)
        button.callback()
        local confirm = support.UI.shown[#support.UI.shown]
        assert(confirm.ok_callback and confirm.text:find("书签和阅读进度",1,true)
            and confirm.text:find("Zotero 云端数据会保留",1,true))
        support.UI:close(confirm)
        assert(support.read(path)=="local PDF" and support.purged_path==nil and #support.requests==0)
    end)

    it("deletes PDF, cloud cache and native sidecars without changing library or sibling files",function()
        local sidecar = directory.."/paper.sdr"
        local central = support.directory.."/central.sdr"
        assert(support.makePath(sidecar) and support.makePath(central))
        local files = {sidecar.."/metadata.pdf.lua",sidecar.."/metadata.pdf.lua.old",
            central.."/metadata.pdf.lua",central.."/metadata.pdf.lua.old"}
        for _,file in ipairs(files) do support.write(file,"annotations, bookmarks and progress") end
        local cover,metadata,cache = central.."/cover.png",central.."/custom_metadata.lua",support.directory.."/page.cache"
        support.write(cover,"cover"); support.write(metadata,"custom"); support.write(cache,"page cache")
        support.doc_settings[path] = {candidates={},cover=cover,metadata=metadata,data={cache_file_path=cache}}
        for _,file in ipairs(files) do
            table.insert(support.doc_settings[path].candidates,{path=file})
        end
        local other_dir = API.storage_dir.."/ATTACH02"
        assert(support.makePath(other_dir))
        support.write(other_dir.."/other.pdf","other PDF")
        support.write(directory.."/unrelated.txt","keep")
        local library = support.read(API.cache_path)
        browser:confirmDeleteLocalPDF(browser.last_items[1])
        support.UI.shown[#support.UI.shown].ok_callback()
        local lfs = require("libs/libkoreader-lfs")
        assert(not lfs.attributes(path) and not lfs.attributes(directory.."/.zotero-annotations.json")
            and not lfs.attributes(directory.."/.zotero-cache.json"))
        for _,file in ipairs(files) do assert(not lfs.attributes(file)) end
        assert(not lfs.attributes(cover) and not lfs.attributes(metadata) and not lfs.attributes(cache))
        assert(support.read(other_dir.."/other.pdf")=="other PDF" and support.read(directory.."/unrelated.txt")=="keep")
        assert(support.read(API.cache_path)==library and API.getItems().ATTACH01 and API.getLibraryVersion()==10)
        assert(support.book_cache_reset==path and support.history_deleted==path and support.collection_removed==path)
        assert(browser.last_items[1].key=="ATTACH01" and browser.last_items[1].mandatory_func()=="PDF")
        assert(#support.requests==0 and support.UI.shown[#support.UI.shown].icon=="check")
    end)

    it("retains annotations and reading data when the PDF cannot be removed",function()
        local original = os.remove
        os.remove = function(file)
            if file==path then return nil,"permission denied" end
            return original(file)
        end
        local deleted,err = LocalFiles.removePDF(API,"ATTACH01",path)
        assert(not deleted and err=="permission denied" and support.purged_path==nil)
        assert(support.read(path)=="local PDF" and API.getAttachmentStatus("ATTACH01")=="downloaded")
        assert(support.read(directory.."/.zotero-annotations.json")=="cached cloud annotations")
        assert(not support.history_deleted and #support.requests==0)
    end)

    it("blocks removal of an open PDF even when its reader uses a different path spelling",function()
        local ReaderUI = require("apps/reader/readerui")
        support.real_paths["./active.pdf"] = path
        ReaderUI.instance = {document={file="./active.pdf"}}
        browser:confirmDeleteLocalPDF(browser.last_items[1])
        support.UI.shown[#support.UI.shown].ok_callback()
        assert(support.read(path)=="local PDF" and support.purged_path==nil)
        assert(support.UI.shown[#support.UI.shown].text:find("Close this document",1,true))
        ReaderUI.instance = {document={file="/another.pdf"}}
        assert(LocalFiles.removePDF(API,"ATTACH01",path))
    end)

    it("blocks individual EPUB deletion when an open copy shares newly saved hash settings",function()
        local item = API.getItems().ATTACH01
        item.data.contentType = "application/epub+zip"
        item.data.filename = "paper.epub"
        path = directory.."/paper.epub"
        support.write(path,"local EPUB")
        local sidecar = support.directory.."/shared.sdr"
        assert(support.makePath(sidecar))
        local metadata = sidecar.."/metadata.epub.lua"
        support.write(metadata,"open document reading data")
        support.doc_settings[path] = {hash_sidecar_dir=sidecar,candidates={{path=metadata}}}
        local other = support.directory.."/ordinary.epub"
        support.doc_settings[other] = {hash_sidecar_dir=sidecar.."/./"}
        local reader = require("apps/reader/readerui")
        reader.instance = {document={file=other},doc_settings=require("docsettings"):open(other)}
        local deleted,err = LocalFiles.removeAttachment(API,"ATTACH01",path)
        assert(not deleted and err:find("share its reading data",1,true))
        assert(support.read(path)=="local EPUB" and support.read(metadata)=="open document reading data")
        assert(support.read(directory.."/.zotero-annotations.json")=="cached cloud annotations" and not support.purged_path)
        reader.instance = nil
        assert(LocalFiles.removeAttachment(API,"ATTACH01",path))
        assert(not require("libs/libkoreader-lfs").attributes(metadata) and #support.requests==0)
    end)

    it("protects a shared page cache and allows deletion when the open reader uses different settings",function()
        local cache = support.directory.."/page.cache"
        support.write(cache,"open page cache")
        support.doc_settings[path] = {data={cache_file_path=cache}}
        local other = support.directory.."/ordinary.pdf"
        support.doc_settings[other] = {data={cache_file_path=cache}}
        local reader = require("apps/reader/readerui")
        reader.instance = {document={file=other},doc_settings=require("docsettings"):open(other)}
        assert(not LocalFiles.removePDF(API,"ATTACH01",path))
        assert(support.read(cache)=="open page cache" and support.read(path)=="local PDF")
        support.doc_settings[other] = {}
        reader.instance.doc_settings = require("docsettings"):open(other)
        assert(LocalFiles.removePDF(API,"ATTACH01",path))
        assert(not require("libs/libkoreader-lfs").attributes(cache))
    end)

    it("keeps renamed download receipts until batch cleanup removes the last tracked copy",function()
        local Cleanup = require("downloadcleanup")
        local item = API.getItems().ATTACH01
        -- Exercise the real legacy receipt upgrade and rename download flow.
        assert(API.downloadAndGetPath(item.key)==path and #support.requests==0)
        item.data.filename = "renamed.epub"
        item.data.contentType = "application/epub+zip"
        support.response = function(req) return support.respond(req,"renamed EPUB") end
        local renamed = assert(API.downloadAndGetPath(item.key))
        local requests = #support.requests
        local receipt_path = directory.."/.zotero-cache.json"
        local receipt = support.read(receipt_path)
        assert(support.JSON.decode(receipt).previous_files[1].filename=="paper.pdf")
        local unknown = directory.."/user-added.pdf"
        support.write(unknown,"keep")
        assert(LocalFiles.removeAttachment(API,item.key,renamed))
        assert(support.read(path)=="local PDF" and support.read(receipt_path)==receipt)
        assert(support.read(directory.."/.zotero-annotations.json")=="cached cloud annotations")
        local scan = Cleanup.scanDownloads(API)
        assert(#scan.targets==1 and scan.targets[1].path==path and #scan.unknown==1 and scan.unknown[1]==unknown)
        local stats = Cleanup.newStats(scan)
        Cleanup.processTarget(scan.targets[1],stats)
        local lfs = require("libs/libkoreader-lfs")
        assert(stats.deleted==1 and stats.failed==0 and stats.pending==0 and not lfs.attributes(path))
        assert(not lfs.attributes(receipt_path) and not lfs.attributes(directory.."/.zotero-annotations.json"))
        assert(support.read(unknown)=="keep" and #Cleanup.scanDownloads(API).targets==0 and #support.requests==requests)
    end)

    it("does not keep a receipt solely for missing tracked copies or untracked documents",function()
        support.write(directory.."/.zotero-cache.json",support.JSON.encode({format=1,source="zotero.koplugin",
            user_id="123",attachment_key="ATTACH01",filename="paper.pdf",content_type="application/pdf",
            previous_files={{filename="missing.pdf",content_type="application/pdf"}}}))
        support.write(directory.."/untracked.pdf","keep")
        assert(LocalFiles.removePDF(API,"ATTACH01",path))
        assert(not require("libs/libkoreader-lfs").attributes(directory.."/.zotero-cache.json"))
        assert(support.read(directory.."/untracked.pdf")=="keep" and #require("downloadcleanup").scanDownloads(API).targets==0)
    end)

    it("refuses a changed confirmation target or a redirected attachment directory",function()
        browser:confirmDeleteLocalPDF(browser.last_items[1])
        local confirmation = support.UI.shown[#support.UI.shown]
        API.getItems().ATTACH01.data.filename = "replacement.pdf"
        support.write(directory.."/replacement.pdf","replacement")
        confirmation.ok_callback()
        assert(support.read(path)=="local PDF" and support.read(directory.."/replacement.pdf")=="replacement")
        assert(support.purged_path==nil)
        API.getItems().ATTACH01.data.filename = "paper.pdf"
        support.real_paths[directory] = support.directory.."/outside"
        assert(not LocalFiles.removePDF(API,"ATTACH01",path))
        support.real_paths[directory] = nil
        support.real_paths[path] = support.directory.."/outside.pdf"
        assert(not LocalFiles.removePDF(API,"ATTACH01",path) and support.read(path)=="local PDF")
    end)

    it("offers removal for outdated PDFs and disables it for missing files",function()
        API.getItems().ATTACH01.version = 11
        assert(API.getAttachmentStatus("ATTACH01")=="outdated")
        browser:onMenuHold(browser.last_items[1])
        assert(support.UI.shown[#support.UI.shown].buttons_table[3][1].enabled)
        assert(LocalFiles.removePDF(API,"ATTACH01",path))
        browser:onMenuHold(browser.last_items[1])
        assert(not support.UI.shown[#support.UI.shown].buttons_table[3][1].enabled)
        API.getItems().ATTACH01.data.contentType = "application/epub+zip"
        browser:onMenuHold(browser.last_items[1])
        assert(#support.UI.shown[#support.UI.shown].buttons_table==2)
    end)

    it("reports partial cleanup failures without claiming the PDF is still present",function()
        local original = os.remove
        os.remove = function(file)
            if file==directory.."/.zotero-annotations.json" then return nil,"permission denied" end
            return original(file)
        end
        browser:confirmDeleteLocalPDF(browser.last_items[1])
        support.UI.shown[#support.UI.shown].ok_callback()
        assert(API.getAttachmentStatus("ATTACH01")=="not_downloaded")
        assert(support.UI.shown[#support.UI.shown].text:find("some local data",1,true)
            and support.UI.shown[#support.UI.shown].icon=="notice-warning")
        assert(support.history_deleted==path and #support.requests==0)
    end)

    it("allows a removed PDF to be downloaded again and skips its annotations in batch sync until then",function()
        assert(LocalFiles.removePDF(API,"ATTACH01",path))
        local Annotations = require("annotations")
        local stats = Annotations.refreshDownloaded(API)
        assert(stats.updated==0 and stats.failed==0 and #support.requests==0)
        support.response = function(req)
            if req.url:find("/file",1,true) then return support.respond(req,"downloaded again") end
            return support.key(req)
        end
        assert(API.downloadAndGetPath("ATTACH01")==path)
        assert(support.read(path)=="downloaded again" and API.getAttachmentStatus("ATTACH01")=="downloaded")
        assert(not Annotations.readCache(API,"ATTACH01"))
        for _,req in ipairs(support.requests) do assert(not req.method or req.method=="GET") end
    end)

    it("does not delete while a download or annotation refresh is queued",function()
        browser.downloading = true
        local shown = #support.UI.shown
        browser:confirmDeleteLocalPDF(browser.last_items[1])
        assert(#support.UI.shown==shown and support.read(path)=="local PDF")
        browser.downloading = false
        browser:confirmDeleteLocalPDF(browser.last_items[1])
        local confirmation = support.UI.shown[#support.UI.shown]
        browser.downloading = true
        confirmation.ok_callback()
        assert(support.read(path)=="local PDF" and support.purged_path==nil)
    end)
end)
