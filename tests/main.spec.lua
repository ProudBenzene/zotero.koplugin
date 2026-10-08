local support=require("tests/support")
local API,plugin,browser
describe("Zotero browser offline regressions",function()
    before_each(function()
        API=support.setup()
        plugin=support.plugin()
        browser=plugin.browser
        support.seed({ATTACH01=support.attachment("ATTACH01","paper.pdf",false)},{
            COLLECT1={key="COLLECT1",data={name="Collection",parentCollection=false}},
        })
        browser:displayCollection(nil)
    end)
    after_each(support.teardown)

    it("keeps collection levels separate from All Items and restores their titles when returning",function()
        local parent={key="PARENT01",data={itemType="journalArticle",title="Paper",collections={"LEAF0001"}}}
        support.seed({PARENT01=parent,ATTACH01=support.attachment("ATTACH01","paper.pdf","PARENT01")},{
            ROOT0001={key="ROOT0001",data={name="Parent",parentCollection=false}},
            CHILD001={key="CHILD001",data={name="Child",parentCollection="ROOT0001"}},
            LEAF0001={key="LEAF0001",data={name="Leaf",parentCollection="CHILD001"}},
            EMPTY001={key="EMPTY001",data={name="Empty",parentCollection=false}},
        })
        browser:displayCollection(nil)
        assert(browser.title=="Zotero" and #browser.last_items==3 and browser.last_items[1].wildcard_collection)
        browser:onMenuSelect(browser.last_items[1])
        assert(browser.title=="All Items" and #browser.last_items==1 and browser.last_items[1].key=="ATTACH01")
        assert(not browser.last_items[1].collection)
        browser:onReturn()
        assert(browser.title=="Zotero" and #browser.last_items==3)
        browser:onMenuSelect({collection=true,key="ROOT0001"})
        assert(browser.title=="Parent" and #browser.last_items==1 and browser.last_items[1].key=="CHILD001")
        browser:onMenuSelect(browser.last_items[1])
        assert(browser.title=="Child" and #browser.last_items==1 and browser.last_items[1].key=="LEAF0001")
        browser:onMenuSelect(browser.last_items[1])
        assert(browser.title=="Leaf" and #browser.last_items==1 and browser.last_items[1].key=="ATTACH01")
        browser:onReturn()
        assert(browser.title=="Child" and browser.last_items[1].key=="LEAF0001")
        browser:onReturn()
        assert(browser.title=="Parent" and browser.last_items[1].key=="CHILD001")
        browser:onReturn()
        assert(browser.title=="Zotero" and #browser.paths==0)
    end)

    it("keeps navigation history when KOReader rebuilds the menu layout",function()
        browser:onMenuSelect({collection=true,key="COLLECT1"})
        assert(browser.current_view.key=="COLLECT1" and #browser.paths==1 and browser.page_return_arrow.enabled)
        browser:init()
        assert(browser.current_view.key=="COLLECT1" and #browser.paths==1 and browser.page_return_arrow.enabled)
        browser:onReturn()
        assert(browser.title=="Zotero" and browser.last_items[1].wildcard_collection and #browser.paths==0)
    end)

    it("opens All Items even if a menu entry also has a collection decoration",function()
        browser:onMenuSelect({wildcard_collection=true,collection=false,key="COLLECT1"})
        assert(browser.current_view.kind=="search" and browser.title=="All Items")
        assert(browser.last_items[1].key=="ATTACH01" and not browser.last_items[1].collection)
    end)

    it("reopens Browse at the root before showing its previously used widget",function()
        browser:onMenuSelect({collection=true,key="COLLECT1"})
        local original_show=support.UI.show
        local view_at_show,items_at_show,title_at_show
        support.UI.show=function(ui,widget,...)
            if widget==plugin.zotero_dialog then
                view_at_show,items_at_show,title_at_show=browser.current_view,browser.last_items,browser.title
            end
            return original_show(ui,widget,...)
        end
        plugin:onZoteroOpenAction()
        support.UI.show=original_show
        assert(view_at_show and view_at_show.kind=="collection" and view_at_show.key==nil)
        assert(title_at_show=="Zotero" and items_at_show[1].wildcard_collection)
        assert(browser.last_items[2].key=="COLLECT1" and #browser.paths==0)
    end)

    it("shows a loading message before cold cache work and queues only one Browse action",function()
        API.init(API.zotero_dir)
        assert(not API.isLibraryLoaded())
        plugin:onZoteroOpenAction()
        local message=support.UI.shown[#support.UI.shown]
        assert(message.text:find("Loading Zotero library",1,true) and plugin.browsing)
        plugin:onZoteroOpenAction()
        assert(#support.UI.scheduled==1 and not API.isLibraryLoaded())
        support.UI.scheduled[1]()
        assert(not plugin.browsing and support.UI.closed[#support.UI.closed]==message)
        assert(support.UI.shown[#support.UI.shown]==plugin.zotero_dialog and API.isLibraryLoaded())
        assert(browser.last_items[2].key=="COLLECT1")
    end)

    it("does not change return history when a search is cancelled",function()
        browser:onMenuSelect({collection=true,key="COLLECT1"})
        browser:onLeftButtonTap()
        local dialog=support.UI.shown[#support.UI.shown]
        dialog.buttons[1][1].callback()
        browser:onReturn()
        assert(browser.current_view.kind=="collection" and browser.current_view.key==nil and #browser.paths==0)
    end)

    it("restores the previous query after successive searches",function()
        for _,query in ipairs({"paper","none"}) do
            browser:onLeftButtonTap()
            local dialog=support.UI.shown[#support.UI.shown]
            dialog.input=query
            dialog.buttons[1][2].callback()
        end
        assert(browser.last_items[1].text=="No Results")
        browser:onReturn()
        assert(browser.current_view.kind=="search" and browser.current_view.query=="paper")
        assert(browser.last_items[1].key=="ATTACH01")
        browser:onReturn()
        assert(browser.current_view.kind=="collection" and browser.current_view.key==nil)
    end)

    it("restores All Items after searching from that view",function()
        browser:onMenuSelect({wildcard_collection=true})
        browser:onLeftButtonTap()
        local dialog=support.UI.shown[#support.UI.shown]
        dialog.input="missing"
        dialog.buttons[1][2].callback()
        browser:onReturn()
        assert(browser.current_view.kind=="search" and browser.current_view.query=="" and #browser.last_items==1)
        assert(browser.last_items[1].key=="ATTACH01")
        browser:onReturn()
        assert(browser.last_items[1].wildcard_collection and #browser.paths==0)
    end)

    it("blocks menu actions after initialization fails",function()
        local broken=dofile("main.lua")
        broken.ui=plugin.ui
        broken.initAPIAndBrowser=function() error("initialization failed") end
        broken:init()
        assert(not broken.initialized and not broken:checkInitialized())
        local scheduled=#support.UI.scheduled
        broken:onZoteroOpenAction()
        broken:onZoteroSyncAction()
        API.settings=nil
        broken:setAccount()
        broken:setWebdavAccount()
        broken:setItemsPerPage()
        local menus={}
        broken:addToMainMenu(menus)
        local maintenance=menus.zotero.sub_item_table[3].sub_item_table
        maintenance[1].callback()
        local settings=menus.zotero.sub_item_table[4].sub_item_table
        assert(settings[2].checked_func()==false)
        settings[2].callback()
        settings[4].callback()
        assert(#support.UI.scheduled==scheduled)
        assert(broken.init_error:find("initialization failed",1,true))
    end)

    it("groups siblings while keeping distinct papers with identical titles separate",function()
        local items={}
        for _,key in ipairs({"PARENT01","PARENT02"}) do
            items[key]={key=key,data={itemType="journalArticle",title="Same paper",collections={"COLLECT1"}}}
        end
        for index,parent in ipairs({"PARENT01","PARENT01","PARENT02","PARENT02"}) do
            local key="ATTACH0"..index
            items[key]=support.attachment(key,"paper.pdf",parent)
        end
        support.seed(items,{COLLECT1={key="COLLECT1",data={name="Collection",parentCollection=false}}})
        browser:displayCollection("COLLECT1")
        assert(#browser.last_items==2 and browser.last_items[1].attachment_group and browser.last_items[2].attachment_group)
        assert(browser.last_items[1].key~=browser.last_items[2].key)
        assert(browser.last_items[1].mandatory_func()=="2 files")
        browser:onMenuSelect(browser.last_items[1])
        assert(browser.current_view.kind=="attachments" and #browser.last_items==2 and #support.UI.scheduled==0)
        assert(browser.last_items[1].text~=browser.last_items[2].text and browser.last_items[1].mandatory_func()=="PDF")
        local first=browser.last_items[1].key
        browser:init()
        assert(browser.current_view.kind=="attachments" and browser.last_items[1].key==first)
        browser:onReturn()
        assert(browser.current_view.kind=="collection" and browser.current_view.key=="COLLECT1" and #browser.last_items==2)
        browser:displaySearchResults("same paper")
        assert(#browser.last_items==2)
        browser:onMenuSelect(browser.last_items[1])
        browser:onReturn()
        assert(browser.current_view.kind=="search" and browser.current_view.query=="same paper")
    end)

    it("updates download badges after downloading, metadata changes and local file removal",function()
        local parent={key="PARENT01",data={itemType="journalArticle",title="Paper"}}
        support.seed({PARENT01=parent,ATTACH01=support.attachment("ATTACH01","paper.pdf","PARENT01"),
            ATTACH02=support.attachment("ATTACH02","supplement.pdf","PARENT01")})
        browser:displaySearchResults("")
        local group=browser.last_items[1]
        assert(group.mandatory_func()=="2 files")
        browser:onMenuSelect(group)
        local attachment=browser.last_items[1]
        support.response=function(req) return support.respond(req,"a complete PDF") end
        browser:onMenuSelect(attachment)
        support.UI.scheduled[1]()
        assert(attachment.mandatory_func()=="PDF · Downloaded" and group.mandatory_func()=="2 files · 1 downloaded")
        API.getItems()[attachment.key].version=11
        assert(attachment.mandatory_func()=="PDF · Update available" and group.mandatory_func()=="2 files")
        os.remove(support.opened_path)
        assert(attachment.mandatory_func()=="PDF")
    end)

    it("shows full attachment details on hold and opens only after choosing Open",function()
        local parent={key="PARENT01",data={itemType="journalArticle",title=string.rep("Long paper title ",20),DOI="10.1234/example"}}
        local attachment=support.attachment("ATTACH01",string.rep("filename",20)..".pdf","PARENT01")
        attachment.data.title="Supplementary material"
        support.seed({PARENT01=parent,ATTACH01=attachment,ATTACH02=support.attachment("ATTACH02","main.pdf","PARENT01")})
        browser:displaySearchResults("")
        browser:onMenuHold(browser.last_items[1])
        assert(support.UI.shown[#support.UI.shown].text:find(attachment.data.filename,1,true))
        browser:onMenuSelect(browser.last_items[1])
        local selected
        for _,entry in ipairs(browser.last_items) do if entry.key==attachment.key then selected=entry end end
        assert(selected.text:find("Supplementary material",1,true) and selected.text:find(attachment.data.filename,1,true))
        browser:onMenuHold(selected)
        local viewer=support.UI.shown[#support.UI.shown]
        assert(viewer.text:find(parent.data.title,1,true) and viewer.text:find(attachment.data.filename,1,true))
        assert(viewer.text:find("Not downloaded",1,true) and viewer.text:find("10.1234/example",1,true))
        assert(viewer.text:find("Zotero key: ATTACH01",1,true) and #support.UI.scheduled==0)
        viewer.buttons_table[1][1].callback()
        assert(support.UI.closed[#support.UI.closed]==viewer and #support.UI.scheduled==1)
    end)

    it("shows Chinese download and attachment labels in a Chinese KOReader interface",function()
        support.GetText.current_lang="zh_CN"
        local directory,path=API.getDirAndPath("ATTACH01")
        assert(support.makePath(directory))
        support.write(path,"PDF")
        support.write(directory.."/.zotero-cache.json",support.JSON.encode({version=10}))
        browser:displaySearchResults("")
        assert(browser.last_items[1].mandatory_func()=="PDF · 已下载")
        browser:onMenuHold(browser.last_items[1])
        local viewer=support.UI.shown[#support.UI.shown]
        assert(viewer.title=="附件信息" and viewer.text:find("状态：已下载",1,true))
    end)

    it("closes the download message on failure and prevents duplicate queued downloads",function()
        API.downloadAndGetPath=function() return nil,"download failed" end
        browser:onMenuSelect({key="ATTACH01"})
        local message=browser.download_dialog
        browser:onMenuSelect({key="ATTACH01"})
        assert(#support.UI.scheduled==1)
        support.UI.scheduled[1]()
        assert(support.UI.closed[#support.UI.closed]==message and not browser.downloading)
        assert(support.UI.shown[#support.UI.shown].text:find("download failed",1,true))
    end)

    it("guards against duplicate queued syncs and closes the progress message",function()
        API.syncAllItems=function() return "sync failed" end
        plugin:onZoteroSyncAction()
        local message=support.UI.shown[#support.UI.shown]
        plugin:onZoteroSyncAction()
        assert(#support.UI.scheduled==1)
        support.UI.scheduled[1]()
        assert(not plugin.syncing and support.UI.closed[#support.UI.closed]==message)
        local result=support.UI.shown[#support.UI.shown]
        assert(result.text:find("sync failed",1,true))
        assert(result.timeout==nil and result.honor_silent_mode==false and result.flush_events_on_show)
    end)

    it("repaints actual streaming progress at most every two seconds inside the HTTP request",function()
        local finished=false
        support.response=function(req)
            for _,now in ipairs({0.1,0.9,1.99,2,2.01,4,6}) do
                support.clock=now
                assert(req.sink(string.rep("x",1024)))
                if now>=2 then
                    assert(#support.UI.paints>0 and not finished)
                end
            end
            finished=true
            return 1,200,{}
        end
        browser:onMenuSelect({key="ATTACH01"})
        local message=browser.download_dialog
        assert(message.text:find("Waiting for response",1,true) and not message.dismissable and message.unmovable)
        support.UI.scheduled[1]()
        assert(support.opened_path and not browser.downloading and #support.UI.paints==3)
        for index,paint in ipairs(support.UI.paints) do
            assert(paint.time==index*2 and paint.mode=="ui")
            assert(paint.region.w<600 and paint.region.h<800)
            assert(paint.text:find("Received:",1,true) and not paint.text:find("%%"))
            if index>1 then
                local previous=support.UI.paints[index-1].region
                assert(paint.region.x==previous.x and paint.region.y==previous.y
                    and paint.region.w==previous.w and paint.region.h==previous.h)
            end
        end
        assert(support.UI.paints[1].text:find("4.0 KiB",1,true) and support.UI.paints[3].text:find("7.0 KiB",1,true))
        local paints=#support.UI.paints
        support.clock=30
        message:update({stage="downloading",bytes=99999})
        assert(#support.UI.paints==paints and message.closed and #support.UI.scheduled==1)
    end)

    it("throttles stage changes and skips identical progress text even after the interval",function()
        browser:onMenuSelect({key="ATTACH01"})
        local message=browser.download_dialog
        support.clock=2
        message:update({stage="downloading",bytes=2048})
        support.clock=2.5
        message:update({stage="verifying",bytes=2048})
        support.clock=4
        message:update({stage="downloading",bytes=2048})
        assert(#support.UI.paints==1)
        support.clock=4.1
        message:update({stage="verifying",bytes=2048})
        assert(#support.UI.paints==2 and support.UI.paints[2].text:find("Checked: 2.0 KiB",1,true))
        assert(#support.UI.scheduled==1)
    end)

    it("displays sync percentages per stage and counts when the total is unknown",function()
        API.syncAllItems=function(progress)
            support.clock=2
            progress({stage="items",completed=100,total=250})
            support.clock=2.1
            progress({stage="collections",completed=1,total=2})
            support.clock=4
            progress({stage="collections",completed=1,total=2})
            support.clock=6
            progress({stage="items",completed=7})
        end
        plugin:onZoteroSyncAction()
        support.UI.scheduled[1]()
        assert(#support.UI.paints==3 and not plugin.syncing)
        assert(support.UI.paints[1].text:find("100 / 250 (40%)",1,true))
        assert(support.UI.paints[2].text:find("1 / 2 (50%)",1,true))
        assert(support.UI.paints[3].text:find("Processed: 7",1,true) and not support.UI.paints[3].text:find("%%"))
        local result=support.UI.shown[#support.UI.shown]
        assert(result.text:find("Synchronization complete.",1,true))
        assert(result.text:find("Library items: 1",1,true) and result.text:find("Collections: 1",1,true))
        assert(result.text:find("Visible PDF/EPUB attachments: 1",1,true))
        assert(result.timeout==nil and result.honor_silent_mode==false and result.flush_events_on_show)
    end)

    it("releases busy flags and closes progress dialogs after unexpected API exceptions",function()
        API.downloadAndGetPath=function() error("unexpected download error") end
        browser:onMenuSelect({key="ATTACH01"})
        local message=browser.download_dialog
        support.UI.scheduled[1]()
        assert(not browser.downloading and message.closed and support.UI.closed[#support.UI.closed]==message)
        assert(support.UI.shown[#support.UI.shown].text:find("unexpected download error",1,true))
        API.syncAllItems=function() error("unexpected sync error") end
        plugin:onZoteroSyncAction()
        message=support.UI.shown[#support.UI.shown]
        support.UI.scheduled[2]()
        assert(not plugin.syncing and message.closed and support.UI.closed[#support.UI.closed]==message)
        assert(support.UI.shown[#support.UI.shown].text:find("unexpected sync error",1,true))
    end)

    it("rejects mixed-text IDs in the account dialog",function()
        plugin:setAccount()
        plugin.account_dialog.test_fields={"user123","NEW-KEY"}
        plugin.account_dialog.buttons[1][2].callback()
        assert(API.getUserID()=="123" and API.getAPIKey()=="FAKE-KEY")
    end)
end)
