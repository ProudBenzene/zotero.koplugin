local support = require("tests/support")
local Cleanup = require("downloadcleanup")
local LocalFiles = require("localfiles")
local lfs = require("libs/libkoreader-lfs")
local API, plugin, original_attributes, original_dir, original_scan, scheduled

local function download(user, key, name, legacy, bytes)
    local directory=API.zotero_dir.."/storage/"..(user~="" and user.."/" or "")..key
    assert(support.makePath(directory))
    local path=directory.."/"..name
    support.write(path,bytes or "download")
    local content_type=name:match("%.epub$") and "application/epub+zip" or "application/pdf"
    local receipt=legacy and {version=10} or {format=1,source="zotero.koplugin",user_id=user,
        attachment_key=key,filename=name,content_type=content_type,version=10}
    support.write(directory.."/.zotero-cache.json",support.JSON.encode(receipt))
    return path,directory
end
local function drain()
    while scheduled<#support.UI.scheduled do
        scheduled=scheduled+1
        assert(scheduled<1000,"Scheduled cleanup did not finish")
        support.UI.scheduled[scheduled]()
    end
end
local function remove(scan)
    local stats=Cleanup.newStats(scan)
    for _,target in ipairs(scan.targets) do Cleanup.processTarget(target,stats) end
    return stats
end

describe("All-account local download cleanup",function()
    before_each(function()
        API=support.setup();plugin=support.plugin()
        support.seed({ATTACH01=support.attachment("ATTACH01","paper.pdf",false)},{},10)
        original_attributes,original_dir,original_scan=lfs.attributes,lfs.dir,Cleanup.scanDownloads
        scheduled=0
    end)
    after_each(function()
        lfs.attributes,lfs.dir,Cleanup.scanDownloads=original_attributes,original_dir,original_scan
        support.teardown()
    end)

    it("deletes PDFs and EPUBs from every account offline while retaining library and settings",function()
        local pdf=download("123","ATTACH01","paper.pdf")
        local epub=download("456","ORPHAN01","book.epub")
        local outdated=download("123","OLDPDF01","old.pdf",true)
        API.getItems().OLDPDF01=support.attachment("OLDPDF01","old.pdf",false,11)
        assert(API.getAttachmentStatus("OLDPDF01")=="outdated")
        local library=support.read(API.cache_path)
        local scan=Cleanup.scanDownloads(API)
        assert(#scan.targets==3 and scan.pdf==2 and scan.epub==1 and scan.accounts==2)
        local stats=remove(scan)
        assert(stats.deleted==3 and stats.failed==0 and stats.pending==0 and stats.unknown==0)
        assert(not lfs.attributes(pdf) and not lfs.attributes(epub) and not lfs.attributes(outdated))
        assert(support.read(API.cache_path)==library and API.getUserID()=="123" and API.getAPIKey()=="FAKE-KEY")
        assert(API.getItems().ATTACH01 and API.getLibraryVersion()==10 and #support.requests==0)
        assert(#Cleanup.scanDownloads(API).targets==0)
    end)

    it("recognizes orphaned legacy receipts and legacy attachment slots without an account directory",function()
        local old=download("456","ORPHAN01","old.pdf",true)
        local legacy=download("","LEGACY01","old.epub",true)
        local stats=remove(Cleanup.scanDownloads(API))
        assert(stats.deleted==2 and stats.failed==0 and not lfs.attributes(old) and not lfs.attributes(legacy))
    end)

    it("uses receipt checksums to identify renamed copies without claiming unrelated PDFs",function()
        local path,dir=download("123","ATTACH01","old.pdf",true,"old bytes")
        support.write(dir.."/paper.pdf","new bytes")
        support.write(dir.."/unrelated.pdf","keep")
        local hash=string.rep("a",32)
        support.digests["old bytes"]=hash
        support.write(dir.."/.zotero-cache.json",support.JSON.encode({version=10,md5=hash}))
        local scan=Cleanup.scanDownloads(API)
        assert(#scan.targets==2 and #scan.unknown==1 and scan.unknown[1]==dir.."/unrelated.pdf")
        local stats=remove(scan)
        assert(stats.deleted==2 and not lfs.attributes(path) and not lfs.attributes(dir.."/paper.pdf"))
        assert(support.read(dir.."/unrelated.pdf")=="keep")
        assert(#Cleanup.scanDownloads(API).targets==0,"Remaining receipt must not claim the unrelated PDF on a later scan")
    end)

    it("recognizes tracked previous filenames and files without a PDF extension",function()
        local path,dir=download("456","ORPHAN01","document")
        local receipt={format=1,source="zotero.koplugin",user_id="456",attachment_key="ORPHAN01",
            filename="document",content_type="application/pdf",version=10,
            previous_files={{filename="previous.pdf",content_type="application/pdf"}}}
        support.write(dir.."/.zotero-cache.json",support.JSON.encode(receipt))
        support.write(dir.."/previous.pdf","previous")
        assert(remove(Cleanup.scanDownloads(API)).deleted==2 and not lfs.attributes(path))
    end)

    it("preserves ambiguous legacy downloads, unmarked files and receipts belonging to another slot",function()
        local path,dir=download("456","ORPHAN01","one.pdf",true)
        support.write(dir.."/two.epub","keep")
        local wrong,wrong_dir=download("789","ORPHAN02","wrong.pdf")
        local receipt=support.JSON.decode(support.read(wrong_dir.."/.zotero-cache.json"))
        receipt.user_id="999"
        support.write(wrong_dir.."/.zotero-cache.json",support.JSON.encode(receipt))
        support.write(API.zotero_dir.."/storage/shared.pdf","legacy shared")
        local scan=Cleanup.scanDownloads(API)
        assert(#scan.targets==0 and #scan.unknown>=4)
        assert(support.read(path)=="download" and support.read(wrong)=="download")
    end)

    it("cleans other accounts with corrupt metadata and no configured credentials",function()
        local path=download("456","ORPHAN01","book.epub")
        API.setAPIKey("")
        API.settings:saveSetting("user_id","")
        API.getItems=function() error("corrupt metadata") end
        assert(remove(Cleanup.scanDownloads(API)).deleted==1 and not lfs.attributes(path) and #support.requests==0)
    end)

    it("reads cold legacy metadata without migrating or rewriting the library",function()
        local path,dir=download("123","ATTACH01","paper.pdf")
        assert(os.remove(dir.."/.zotero-cache.json"))
        local state=support.JSON.decode(support.read(API.cache_path))
        state.compact=nil
        state.items.ATTACH01.data.unused="keep this legacy field"
        support.write(API.cache_path,support.JSON.encode(state))
        local library=support.read(API.cache_path)
        API.state=nil
        assert(remove(Cleanup.scanDownloads(API)).deleted==1 and not lfs.attributes(path))
        assert(API.state==nil and support.read(API.cache_path)==library)
    end)

    it("rejects redirected files and attachment directories including links within storage",function()
        local path,dir=download("456","ORPHAN01","paper.pdf")
        local elsewhere=support.directory.."/elsewhere.pdf"
        support.write(elsewhere,"keep")
        assert(os.remove(path))
        assert(support.execute("ln -s "..support.quote(elsewhere).." "..support.quote(path)))
        local linked=API.zotero_dir.."/storage/456/LINKED01"
        assert(support.execute("ln -s "..support.quote(dir).." "..support.quote(linked)))
        local scan=Cleanup.scanDownloads(API)
        assert(#scan.targets==0 and #scan.unknown>0 and support.read(elsewhere)=="keep")
    end)

    it("skips a replaced file after confirmation and does not expand the selected targets",function()
        local path,dir=download("123","ATTACH01","paper.pdf")
        support.digests["download"]=string.rep("a",32)
        support.digests["replaced"]=string.rep("b",32)
        local generation=1
        lfs.attributes=function(file,field)
            local attr=original_attributes(file)
            if attr and file==path then attr.ino=generation end
            return field and attr and attr[field] or (not field and attr or nil)
        end
        local scan=Cleanup.scanDownloads(API)
        generation=2
        support.write(path,"replaced")
        support.write(dir.."/new.pdf","new")
        local stats=remove(scan)
        assert(stats.skipped==1 and stats.deleted==0 and support.read(path)=="replaced")
        assert(support.read(dir.."/new.pdf")=="new")
    end)

    it("deletes unchanged bytes after filesystem inode and ctime values change",function()
        local pdf=download("123","ATTACH01","paper.pdf")
        local epub=download("456","ORPHAN01","book.epub")
        local generation=1
        lfs.attributes=function(file,field)
            local attr=original_attributes(file)
            if attr and attr.mode=="file" then attr.ino=generation;attr.change=generation;attr.modification=10 end
            return field and attr and attr[field] or (not field and attr or nil)
        end
        local scan=Cleanup.scanDownloads(API)
        generation=2
        local stats=remove(scan)
        assert(stats.deleted==2 and stats.skipped==0 and not lfs.attributes(pdf) and not lfs.attributes(epub))
    end)

    it("detects changed bytes even when size and every stat field stay the same",function()
        local path=download("123","ATTACH01","paper.pdf")
        support.digests["download"]=string.rep("a",32)
        support.digests["modified"]=string.rep("b",32)
        local scan=Cleanup.scanDownloads(API)
        support.write(path,"modified")
        local stats=remove(scan)
        assert(stats.skipped==1 and stats.deleted==0 and support.read(path)=="modified" and support.purged_path==nil)
    end)

    it("keeps unreadable documents out of the preview and yields while verifying large files",function()
        local path=download("123","ATTACH01","paper.pdf",false,string.rep("d",65537))
        local chunks=0
        local scan=Cleanup.scanDownloads(API,function() chunks=chunks+1 end)
        assert(chunks>=2 and #scan.targets==1)
        local stats=Cleanup.newStats(scan);chunks=0
        Cleanup.processTarget(scan.targets[1],stats,function() chunks=chunks+1 end)
        assert(stats.deleted==1 and chunks==2)
        path=download("123","ATTACH01","paper.pdf")
        local original=io.open
        io.open=function(file,mode) if file==path and mode=="rb" then return nil,"denied" end;return original(file,mode) end
        scan=Cleanup.scanDownloads(API)
        assert(#scan.targets==0 and #scan.unknown>0 and support.read(path)=="download")
    end)

    it("continues an interrupted journal when the unchanged document gets a new inode",function()
        local path,dir=download("123","ATTACH01","paper.pdf")
        local original=os.remove
        os.remove=function(file) if file==path then error("simulated interruption") end;return original(file) end
        assert(remove(Cleanup.scanDownloads(API)).failed==1 and lfs.attributes(dir.."/.zotero-cleanup.json"))
        os.remove=original
        lfs.attributes=function(file,field)
            local attr=original_attributes(file)
            if attr and file==path then attr.ino=99;attr.change=99 end
            return field and attr and attr[field] or (not field and attr or nil)
        end
        local scan=Cleanup.scanDownloads(API)
        assert(#scan.targets==1 and #scan.unknown==0)
        local stats=remove(scan)
        assert(stats.deleted==1 and stats.skipped==0 and stats.pending==0 and not lfs.attributes(path))
    end)

    it("yields to the UI before a large confirmed document finishes verification",function()
        local path=download("123","ATTACH01","paper.pdf",false,string.rep("d",2*1048576))
        plugin:onZoteroDeleteDownloads();drain()
        local preview=support.UI.shown[#support.UI.shown]
        preview.buttons_table[1][2].callback()
        scheduled=scheduled+1
        support.UI.scheduled[scheduled]()
        assert(API.isBusy() and lfs.attributes(path) and #support.UI.scheduled>scheduled)
        drain()
        assert(not API.isBusy() and not lfs.attributes(path))
    end)

    it("skips the open EPUB but continues deleting other downloads",function()
        local pdf=download("123","ATTACH01","paper.pdf")
        local epub=download("456","ORPHAN01","book.epub")
        support.real_paths["./open.epub"]=epub
        require("apps/reader/readerui").instance={document={file="./open.epub"}}
        local stats=remove(Cleanup.scanDownloads(API))
        assert(stats.deleted==1 and stats.open==1 and not lfs.attributes(pdf) and support.read(epub)=="download")
    end)

    it("retains annotations and reading data when deleting a document fails",function()
        local path,dir=download("123","ATTACH01","paper.pdf")
        support.write(dir.."/.zotero-annotations.json","keep annotations")
        local original=os.remove
        os.remove=function(file) if file==path then return nil,"permission denied" end;return original(file) end
        local stats=remove(Cleanup.scanDownloads(API))
        assert(stats.failed==1 and stats.deleted==0 and support.purged_path==nil)
        assert(support.read(path)=="download" and support.read(dir.."/.zotero-annotations.json")=="keep annotations")
    end)

    it("preserves hash settings shared with another open document",function()
        local path=download("123","ATTACH01","paper.pdf")
        local hash=string.rep("a",32)
        local sidecar=support.directory.."/hashdocsettings/aa/"..hash..".sdr"
        assert(support.makePath(sidecar))
        local metadata=sidecar.."/metadata.pdf.lua"
        support.write(metadata,"shared reading data")
        support.doc_settings[path]={hash_sidecar_dir=sidecar,candidates={{path=metadata}}}
        require("apps/reader/readerui").instance={document={file="/another.pdf"},
            doc_settings=require("docsettings"):open(path)}
        local stats=remove(Cleanup.scanDownloads(API))
        assert(stats.open==1 and stats.deleted==0 and support.read(path)=="download" and support.read(metadata)=="shared reading data")
    end)

    it("refuses to unlink a document unless its cleanup journal has been saved",function()
        local path=download("123","ATTACH01","paper.pdf")
        local original=os.rename
        os.rename=function(from,to) if to:match("%.zotero%-cleanup%.json$") then return nil,"disk failure" end;return original(from,to) end
        local stats=remove(Cleanup.scanDownloads(API))
        assert(stats.failed==1 and support.read(path)=="download" and support.purged_path==nil)
    end)

    it("retries cleanup after the PDF is gone including saved hash sidecar paths",function()
        local path,dir=download("123","ATTACH01","paper.pdf")
        local hash=string.rep("a",32)
        local sidecar=support.directory.."/hashdocsettings/aa/"..hash..".sdr"
        assert(support.makePath(sidecar))
        local metadata=sidecar.."/metadata.pdf.lua"
        support.write(metadata,"reading data")
        support.doc_settings[path]={hash_sidecar_dir=sidecar,candidates={{path=metadata}}}
        local original=os.remove
        os.remove=function(file) if file==metadata then return nil,"permission denied" end;return original(file) end
        local stats=remove(Cleanup.scanDownloads(API))
        assert(stats.deleted==1 and stats.pending==1 and not lfs.attributes(path) and lfs.attributes(dir.."/.zotero-cleanup.json"))
        os.remove=original
        local retry=Cleanup.scanDownloads(API)
        assert(retry.pending==1 and retry.pdf==0)
        stats=remove(retry)
        assert(stats.cleaned==1 and stats.failed==0 and not lfs.attributes(metadata) and not lfs.attributes(dir.."/.zotero-cleanup.json"))
    end)

    it("rejects a persisted cleanup record that points outside native document settings",function()
        local path,dir=download("123","ATTACH01","paper.pdf")
        support.write(dir.."/.zotero-annotations.json","cache")
        local original=os.remove
        os.remove=function(file) if file==dir.."/.zotero-annotations.json" then return nil,"denied" end;return original(file) end
        assert(remove(Cleanup.scanDownloads(API)).pending==1)
        os.remove=original
        local outside=support.directory.."/unrelated.lua"
        support.write(outside,"keep")
        local saved=support.JSON.decode(support.read(dir.."/.zotero-cleanup.json"))
        saved.tasks["paper.pdf"].files={outside}
        support.write(dir.."/.zotero-cleanup.json",support.JSON.encode(saved))
        assert(remove(Cleanup.scanDownloads(API)).failed==1 and support.read(outside)=="keep" and not lfs.attributes(path))
    end)

    it("asks once in Chinese and cancellation leaves files intact and releases the shared operation",function()
        local path=download("123","ATTACH01","paper.pdf")
        local epub=download("456","ORPHAN01","book.epub")
        API.getItems().ATTACH01.data.title="Full Text PDF"
        API.getItems().ATTACH01.data.parentItem="PARENT01"
        API.getItems().PARENT01={data={itemType="journalArticle",title="中文标题 / Original title"}}
        support.GetText.current_lang="zh_CN"
        local menus={};plugin:addToMainMenu(menus)
        local entry=menus.zotero.sub_item_table[3].sub_item_table[3]
        assert(entry.text=="删除所有本机下载的文献")
        entry.callback();drain()
        local confirm=support.UI.shown[#support.UI.shown]
        assert(confirm.text:find("PDF：1；EPUB：1；账户：2",1,true) and confirm.text:find("阅读进度",1,true))
        assert(confirm.title=="待删除文献预览" and confirm.show_menu==false)
        assert(confirm.text:find("中文标题 / Original title",1,true) and confirm.text:find("附件：Full Text PDF",1,true))
        assert(not confirm.text:find("文件名：",1,true) and not confirm.text:find("格式：",1,true))
        assert(not confirm.text:find("附件 key：",1,true) and not confirm.text:find("账户：123",1,true))
        assert(not confirm.text:find("账户：456",1,true) and confirm.text:find(path,1,true) and confirm.text:find(epub,1,true))
        assert(API.isBusy())
        confirm.buttons_table[1][1].callback()
        assert(not API.isBusy() and support.read(path)=="download" and #support.requests==0)
    end)

    it("previews skipped and unidentified files and treats closing the preview as cancellation",function()
        local path,dir=download("123","ATTACH01","paper.pdf")
        local legacy=download("","LEGACY01","old.epub",true)
        local unknown=dir.."/user-added.pdf"
        support.write(unknown,"keep")
        require("apps/reader/readerui").instance={document={file=path}}
        support.GetText.current_lang="zh_CN"
        plugin:onZoteroDeleteDownloads();drain()
        local preview=support.UI.shown[#support.UI.shown]
        assert(preview.text:find("正在阅读，将跳过。",1,true))
        assert(not preview.text:find("旧版下载（账户未知）",1,true) and preview.text:find(legacy,1,true))
        assert(preview.text:find("以下无法识别的文件将保留：\n"..unknown,1,true))
        support.UI:close(preview)
        preview.close_callback()
        preview.buttons_table[1][2].callback()
        drain()
        assert(not API.isBusy() and support.read(path)=="download" and support.read(legacy)=="download" and support.read(unknown)=="keep")
    end)

    it("labels retry-only entries in the preview without presenting them as existing files",function()
        local path,dir=download("123","ATTACH01","paper.pdf")
        local cache=dir.."/.zotero-annotations.json"
        support.write(cache,"annotation cache")
        local original=os.remove
        os.remove=function(file) if file==cache then return nil,"denied" end;return original(file) end
        assert(remove(Cleanup.scanDownloads(API)).pending==1)
        os.remove=original
        plugin:onZoteroDeleteDownloads();drain()
        local preview=support.UI.shown[#support.UI.shown]
        assert(preview.text:find(path,1,true) and preview.text:find("Document already deleted; only remaining local data will be cleaned.",1,true))
        assert(not lfs.attributes(path) and lfs.attributes(cache))
        preview.buttons_table[1][1].callback()
        assert(not API.isBusy() and lfs.attributes(cache))
    end)

    it("deletes the confirmed batch and reports unknown files while releasing the operation",function()
        local path,dir=download("123","ATTACH01","paper.pdf")
        support.write(dir.."/unrelated.txt","keep")
        plugin:onZoteroDeleteDownloads();drain()
        local preview=support.UI.shown[#support.UI.shown]
        preview.buttons_table[1][2].callback()
        preview.buttons_table[1][2].callback()
        drain()
        local result=support.UI.shown[#support.UI.shown]
        assert(not API.isBusy() and not lfs.attributes(path) and support.read(dir.."/unrelated.txt")=="keep")
        assert(result.text:find("Deleted: 1",1,true) and result.text:find("unrelated.txt",1,true))
    end)

    it("handles no downloads and scanning exceptions without retaining the operation",function()
        plugin:onZoteroDeleteDownloads();drain()
        assert(not API.isBusy())
        Cleanup.scanDownloads=function() error("scan failed") end
        plugin:onZoteroDeleteDownloads();drain()
        assert(not API.isBusy() and support.UI.shown[#support.UI.shown].text:find("scan failed",1,true))
    end)

    it("blocks download, synchronization and account changes while cleanup awaits confirmation",function()
        download("123","ATTACH01","paper.pdf")
        plugin:onZoteroDeleteDownloads();drain()
        local count=#support.UI.shown
        plugin.browser:onMenuSelect({key="ATTACH01"})
        plugin.browser:refreshAnnotations({key="ATTACH01"})
        plugin:setAccount();plugin:setWebdavAccount();plugin:onZoteroSyncAction()
        local menus={};plugin:addToMainMenu(menus)
        menus.zotero.sub_item_table[3].sub_item_table[1].callback()
        assert(#support.UI.shown==count and #support.UI.scheduled==scheduled and not API.settings:isTrue("force_full_sync"))
        support.UI.shown[#support.UI.shown].buttons_table[1][1].callback()
        assert(not API.isBusy())
    end)

    it("offers individual local deletion for EPUB attachments",function()
        local path=download("123","ATTACH01","paper.epub")
        API.getItems().ATTACH01.data.filename="paper.epub"
        API.getItems().ATTACH01.data.contentType="application/epub+zip"
        plugin.browser:onMenuHold({key="ATTACH01"})
        local viewer=support.UI.shown[#support.UI.shown]
        assert(#viewer.buttons_table==2 and viewer.buttons_table[2][1].enabled)
        viewer.buttons_table[2][1].callback()
        support.UI.shown[#support.UI.shown].ok_callback()
        assert(not lfs.attributes(path) and not API.isBusy())
    end)
end)
