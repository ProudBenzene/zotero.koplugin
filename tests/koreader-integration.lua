-- Optional contract check against an actual KOReader checkout, with fake PDF
-- geometry and paint primitives. This does not test MuPDF, pixels or hardware.
-- Usage: pandoc lua tests/koreader-integration.lua /path/to/koreader/frontend
package.path = "./?.lua;./tests/?.lua;" .. package.path
local source_dir = assert(arg[1], "Supply a KOReader frontend directory (target: v2026.03)")
local support = require("tests/support")
local API = support.setup()
local Annotations = require("annotations")
local Widget = require("ui/widget/container/widgetcontainer")
local checks = 0
local function check(value, label)
    assert(value, label)
    checks = checks + 1
end

local ok, err = xpcall(function()
    local logger = {warn=function() end,dbg=function() end,info=function() end}
    package.loaded.logger = logger
    package.loaded.dbg = {dassert=assert,guard=function() end}
    package.loaded.random = {uuid=function() return "test-device" end}
    package.loaded.docsettings = {getSidecarDir=function(_,file) return file .. ".sdr" end}
    package.loaded["ui/event"] = {new=function(_,name,...) return {name=name,args={...}} end}
    package.loaded.util.cleanupSelectedText = function(value) return value end
    package.loaded["ffi/util"].template = function(value) return value end
    support.GetText.pgettext = function(_,value) return value end
    support.GetText.ngettext = function(value) return value end
    local globals = {
        readSetting=function(_,_,default) return default end,
        isTrue=function() return false end,
    }
    G_reader_settings = globals
    G_defaults = {readSetting=function() return 0 end}
    bit = {rshift=function(value,bits) return math.floor(value/2^bits) end}
    bit.band = function(a,b)
        local value,place = 0,1
        a,b = a % 2^32,b % 2^32
        for _=1,32 do
            if a%2==1 and b%2==1 then value=value+place end
            a,b,place=math.floor(a/2),math.floor(b/2),place*2
        end
        return value
    end
    package.loaded.bit = bit
    local buffer = require("ffi/blitbuffer")
    buffer.gray = function(value) return value end
    buffer.colorFromName = function(name) return name end
    buffer.isColor8 = function() return false end
    package.loaded.optmath = dofile(source_dir.."/optmath.lua")
    local geom = dofile(source_dir.."/ui/geometry.lua")
    package.loaded["ui/geometry"] = geom
    local function dependencies(file)
        local input = assert(io.open(file,"rb"))
        local code = input:read("*a");input:close()
        for name in code:gmatch('require%("([^"]+)"%)') do
            if not package.loaded[name] and not package.preload[name] then
                package.preload[name] = function() return Widget end
            end
        end
        return dofile(file)
    end
    local ReaderAnnotation = dependencies(source_dir.."/apps/reader/modules/readerannotation.lua")
    local ReaderView = dependencies(source_dir.."/apps/reader/modules/readerview.lua")
    local ReaderHighlight = dependencies(source_dir.."/apps/reader/modules/readerhighlight.lua")
    local plugin = support.plugin()
    local attachment = support.attachment("ATTACH01","paper.pdf",false)
    local md5 = string.rep("0",32)
    attachment.data.md5 = md5
    support.seed({ATTACH01=attachment})
    local directory,path = API.getDirAndPath("ATTACH01")
    assert(support.makePath(directory))
    support.write(path,"immutable PDF stand-in")
    support.write(directory.."/.zotero-cache.json",support.JSON.encode({version=10,md5=md5}))
    local function annotation(key,page,rects,next_rects,kind)
        return {key=key,version=10,data={itemType="annotation",parentItem="ATTACH01",annotationType=kind or "highlight",
            annotationColor="#2ea8e5",annotationText="Cloud text",annotationComment="Cloud comment",
            annotationSortIndex=string.format("%05d|000000|00100",page),dateAdded="2026-10-08T04:00:00Z",
            dateModified="2026-10-08T04:00:00Z",
            annotationPosition=support.JSON.encode({pageIndex=page,rects=rects,nextPageRects=next_rects})}}
    end
    local function cache(items,version)
        support.write(directory.."/.zotero-annotations.json",support.JSON.encode({format=1,user_id="123",
            attachment_key="ATTACH01",library_version=version or 10,file_identity={md5=md5},items=items}))
    end
    local ui = {paging=true,rolling=false,callbacks={},toc={getTocTitleByPage=function() return "Chapter" end}}
    local painted = {}
    ui.registerPostReaderReadyCallback = function(self,fn) self.callbacks[#self.callbacks+1]=fn end
    ui.onAnnotationsModified = function() end
    local editing = false
    ui.document = {is_pdf=true,file=path,info={number_of_pages=2},configurable={text_wrap=0},
        hasHiddenFlows=function() return false end,
        getNativePageDimensions=function() return {w=600,h=800} end,
        getPageBoxesFromPositions=function(_,_,a)
            if editing then return {geom:new{x=120,y=680,w=90,h=50}} end
            if a.x==5 then return {geom:new{x=5,y=5,w=1,h=1}} end
            error("Cloud drawing must not reconstruct word boxes")
        end,
        comparePositions=function(_,a,b)
            if a.y ~= b.y then return a.y < b.y and 1 or -1 end
            return a.x == b.x and 0 or (a.x < b.x and 1 or -1)
        end,
        getTextFromPositions=function() return {text="Extended cloud text",pboxes={{x=120,y=680,w=90,h=50}}} end,
    }
    ui.view = ReaderView:extend{ui=ui,document=ui.document,page_scroll=false,
        highlight={page_boxes={},visible_boxes={},saved_drawer="lighten",saved_color="gray"},
        state={page=1,zoom=2,offset={x=15,y=30}},visible_area=geom:new{x=20,y=1200,w=600,h=600}}
    ui.view.drawHighlightRect = function(_,_,_,_,rect,drawer,color,mark)
        painted[#painted+1] = {rect=rect,drawer=drawer,color=color,mark=mark}
    end
    ui.highlight = ReaderHighlight:extend{ui=ui,document=ui.document,view=ui.view,dialog=ui}
    ui.bookmark = {isBookmarkAutoText=function() return false end,
        removeItemByIndex=function(_,index) table.remove(ui.annotation.annotations,index) end}
    ui.view.footer = {maybeUpdateFooter=function() end}
    ui.view.highlight.temp = {}
    ui.annotation = ReaderAnnotation:extend{ui=ui,document=ui.document,view=ui.view}
    local data = {doc_path=path,percent_finished=0.65,highlights_imported=true,bookmarks={
        {page=1,datetime="2026-10-07 10:00:00",notes="Native text",highlighted=true,
            pos0={page=1,x=5,y=5},pos1={page=1,x=6,y=6}},
        {page=2,datetime="2026-10-07 11:00:00"},
    },highlight={[1]={{page=1,datetime="2026-10-07 10:00:00",drawer="lighten",color="gray",
        pos0={page=1,x=5,y=5},pos1={page=1,x=6,y=6},pboxes={{x=5,y=5,w=1,h=1}}}}}}
    local config = {data=data,
        readSetting=function(self,key,default) local v=self.data[key];if v==nil then return default end;return v end,
        saveSetting=function(self,key,value) self.data[key]=value end,
        has=function(self,key) return self.data[key]~=nil end,
        hasNot=function(self,key) return self.data[key]==nil end,
        isTrue=function(self,key) return self.data[key]==true end,
        delSetting=function(self,key) self.data[key]=nil end,
    }
    ui.doc_settings = config
    plugin.ui = ui
    ui.handleEvent = function() plugin:onAnnotationsModified() end
    cache({annotation("ANNOT001",0,{{10,100,100,120}},{{10,100,100,120}}),
        annotation("ANNOT002",1,{{120,100,200,120}})})
    ui.annotation:onReadSettings(config) -- exact native migration/load behavior
    check(#ui.annotation.annotations==2,"Legacy local highlight/bookmark migration")
    -- Use the real event propagation and the installed built-in settings
    -- plugin: in v2026.07.2 its DocSettingsLoad handler returns true and
    -- consumes the event before later plugins see it, even on first opens.
    unpack = unpack or table.unpack
    local EventListener = dofile(source_dir.."/ui/widget/eventlistener.lua")
    package.loaded["ui/widget/eventlistener"] = EventListener
    package.loaded["ui/widget/widget"] = dofile(source_dir.."/ui/widget/widget.lua")
    local NativeContainer = dofile(source_dir.."/ui/widget/container/widgetcontainer.lua")
    require("datastorage").getSettingsDir = function() return directory end
    require("device").hasFewKeys = function() return false end
    require("device").isTouchDevice = function() return true end
    local SettingsTweak = dependencies(source_dir.."/../plugins/docsettingtweak.koplugin/main.lua")
    if SettingsTweak.loadDefaults then SettingsTweak:loadDefaults() end -- v2026.03
    local tweak = SettingsTweak:extend{ui=ui,settings_file=directory.."/absent-defaults.lua"}
    tweak.handleEvent = EventListener.handleEvent
    ui.annotation.handleEvent = EventListener.handleEvent
    plugin.handleEvent = EventListener.handleEvent
    local events = NativeContainer:extend{tweak,ui.annotation,plugin}
    ui.document.is_new = true
    local consumed = events:handleEvent{handler="onDocSettingsLoad",args={config,ui.document,n=2}}
    check(consumed and plugin.annotation_key==nil or not consumed and plugin.annotation_key=="ATTACH01",
        "Native event propagation handles consumed (v2026.07.2) and unconsumed (v2026.03) load events")
    ui.highlight.highlight_write_into_pdf = true -- a global/default PDF-write preference
    events:handleEvent{handler="onReadSettings",args={config,n=1}}
    for _,callback in ipairs(ui.callbacks) do callback() end
    check(#ui.annotation.annotations==4,"Merge two cloud items with two native items")
    check(config.data.highlight_write_into_pdf==false,"Managed PDF write setting")
    check(ui.highlight.highlight_write_into_pdf==false,"Active highlight module cannot write PDF after consumed load event")
    check(config.data.percent_finished==0.65,"Reading progress preserved")
    check(ui.annotation.annotations[1].zotero_source.annotation_key=="ANNOT001","Native sorting accepts cloud positions")
    check(ui.annotation.annotations[1].pageno==1,"Native page number update")
    -- Use the actual More-menu callback and dismissal before creating a local
    -- bookmark: native clear() leaves selected_text present when hold_pos is nil.
    local ReaderBookmark = dependencies(source_dir.."/apps/reader/modules/readerbookmark.lua")
    require("ui/bidi").mirroredUILayout = function() return false end
    local function copy(value)
        if type(value) ~= "table" then return value end
        local result = {}
        for field, item in pairs(value) do result[field] = copy(item) end
        return result
    end
    require("util").tableDeepCopy = copy
    require("ffi/util").orderedPairs = pairs
    ui.highlight._highlight_buttons = {}
    ui.highlight.hold_pos = nil
    ui.highlight:showHighlightDialog(1)
    local dialog = support.UI.shown[#support.UI.shown]
    dialog.buttons[1][6].callback()
    ui.highlight.highlight_dialog.tap_close_callback()
    ui.highlight:clear()
    check(ui.highlight.selected_text.zotero_source~=nil,"Native More-menu leaves cloud selection present")
    local bookmark = ReaderBookmark:extend{ui=ui,document=ui.document,
        getCurrentPageNumber=function() return 1 end,
        getDogearBookmarkIndex=function() return nil end}
    bookmark:toggleBookmark()
    local local_bookmark
    for _, item in ipairs(ui.annotation.annotations) do
        if not item.drawer and item.page==1 then local_bookmark=item end
    end
    check(local_bookmark and not local_bookmark.zotero_source,"New native bookmark keeps local ownership")
    plugin:onReadSettings(config)
    for _, callback in ipairs(ui.callbacks) do callback() end
    local bookmark_index
    for index, item in ipairs(ui.annotation.annotations) do
        if item==local_bookmark then bookmark_index=index end
    end
    check(bookmark_index~=nil,"Local bookmark survives reopening after the cloud More-menu")
    ui.bookmark:removeItemByIndex(bookmark_index)
    ui.highlight.selected_text = nil
    local cloud = ui.annotation.annotations[1]
    local match = ui.annotation:getMatchFunc()
    local same = {page=cloud.page,pos0=cloud.pos0,pos1=cloud.pos1,datetime=cloud.datetime,drawer=cloud.drawer}
    check(not match(cloud,same),"Native match cannot confuse cloud and local annotations")
    local function draw(page,zoom,visible)
        painted = {}
        ui.view.state.page,ui.view.state.zoom,ui.view.visible_area = page,zoom,visible
        local function border(_,x,y,w,h,width,color)
            painted[#painted+1] = {rect={x=x,y=y,w=w,h=h},drawer="zotero_region",color=color,border=width}
        end
        ui.view:drawSavedHighlight({paintBorder=border,paintBorderRGB32=border},0,0)
        return painted
    end
    local visible = geom:new{x=20,y=1200,w=600,h=600}
    local painted = draw(1,2,visible)
    check(#painted==1,"Actual ReaderView paints cloud rectangles")
    check(painted[1].rect.x==15 and painted[1].rect.y==190 and painted[1].rect.w==180 and painted[1].rect.h==40,
        "Native zoom/crop/offset transforms")
    check(painted[1].mark and painted[1].color=="blue","Comment marker and color")
    painted = draw(2,2,visible)
    check(#painted==2,"Two-page cloud highlight and another highlight")
    for _,box in ipairs(ui.view.highlight.visible_boxes) do
        check(ui.annotation.annotations[box.index].zotero_source~=nil,"Visible click targets point at cloud items, not the intervening bookmark")
    end
    ui.document.configurable.text_wrap=1
    painted=draw(2,2,visible)
    check(#painted==0,"Reflow suppresses imports even after a cached native draw")
    ui.document.configurable.text_wrap=0
    painted=draw(2,2,visible)
    check(#painted==2,"Returning to native mode restores cloud drawing")
    ui.annotation:onSaveSettings()
    check(config.data.annotations==ui.annotation.annotations,"Native SaveSettings retains provenance and merged items")
    for index,item in ipairs(ui.annotation.annotations) do
        if item.zotero_source and item.zotero_source.annotation_key=="ANNOT002" then ui.highlight.highlight_idx=index end
    end
    ui.highlight.hold_pos={page=2}
    ui.highlight.selected_text={pos0={page=2,x=200,y=720},pos1={page=2,x=210,y=730},text="New fragment"}
    editing=true
    ui.highlight:extendSelection()
    local index=ui.highlight:saveHighlight()
    editing=false
    check(ui.annotation.annotations[index].zotero_source.annotation_key=="ANNOT002","Native extension/save retains provenance")
    plugin:onReadSettings(config)
    check(#ui.annotation.annotations==4,"Reopening after an extension restores cloud items without a local duplicate")
    local region=annotation("REGION01",1,{{120,100,220,140}},nil,"image")
    region.data.annotationText=""
    region.data.annotationComment="A figure comment"
    cache({annotation("ANNOT001",0,{{10,100,100,120}},{{10,100,100,120}}),
        annotation("ANNOT002",1,{{120,100,200,120}}),region})
    plugin:onReadSettings(config)
    painted=draw(2,2,visible)
    local region_paint
    for _,part in ipairs(painted) do if part.drawer=="zotero_region" then region_paint=part end end
    check(region_paint and region_paint.border==2 and region_paint.rect.w==200,"Native render path draws an unfilled area border")
    ui.highlight.hold_pos=nil
    -- The original image remains unpainted inside the border, but its entire
    -- rectangle is in native visible_boxes and is therefore a click target.
    local rect=region_paint.rect
    ui.highlight.screen_w,ui.highlight.screen_h=600,800
    check(ui.highlight:onTap(nil,{pos={x=rect.x+10,y=rect.y+10}}),"Native tap detects an image annotation's interior")
    check(support.UI.shown[#support.UI.shown].text=="A figure comment","Native tap opens the area comment viewer")
    ui.document.configurable.text_wrap=1
    painted=draw(2,2,visible)
    check(#painted==0,"Reflow also hides area rectangles")
    ui.document.configurable.text_wrap=0
    cache({},11)
    plugin:onReadSettings(config)
    check(#ui.annotation.annotations==2 and config.data.zotero_annotations_applied.library_version==11,"Empty cloud list keeps native items")
    check(support.read(path)=="immutable PDF stand-in" and #support.requests==0,"Reader load neither writes PDF nor uses HTTP")
end,debug.traceback)
support.teardown()
if not ok then error(err) end
io.write(string.format("%d KOReader source integration checks passed\n",checks))
