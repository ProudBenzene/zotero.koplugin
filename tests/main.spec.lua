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
        assert(support.UI.shown[#support.UI.shown].text=="sync failed")
    end)

    it("rejects mixed-text IDs in the account dialog",function()
        plugin:setAccount()
        plugin.account_dialog.test_fields={"user123","NEW-KEY"}
        plugin.account_dialog.buttons[1][2].callback()
        assert(API.getUserID()=="123" and API.getAPIKey()=="FAKE-KEY")
    end)
end)
