-- Real DocSettings + ReaderAnnotation load/save and ReaderBookmark mutation.
-- JSON and disk writes are real; identical PDF bytes use a checked hash double.
-- Usage: pandoc lua tests/annotationstorage-integration.lua /path/to/frontend [annotations.lua]
package.path = "./?.lua;./tests/?.lua;" .. package.path
local frontend = assert(arg[1], "Supply KOReader frontend")
local support = require("tests/support")
support.JSON.encode, support.JSON.decode = pandoc.json.encode, pandoc.json.decode
local Widget = require("ui/widget/container/widgetcontainer")
local Annotations = arg[2] and dofile(arg[2]) or require("annotations")
local lfs = require("libs/libkoreader-lfs")
local attributes, dir = lfs.attributes, lfs.dir
bit = { rshift = function(value, shift) return math.floor(value / 2^shift) end }
local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end
local function literal(value)
    if type(value) ~= "table" then return type(value) == "string" and string.format("%q",value) or tostring(value) end
    local fields = {}
    for key, item in pairs(value) do fields[#fields+1] = "["..literal(key).."]="..literal(item) end
    return "{"..table.concat(fields,",").."}"
end
local function load(name)
    local path = frontend .. "/" .. name .. ".lua"
    for dependency in support.read(path):gmatch('require%("([^"]+)"%)') do
        if not package.loaded[dependency] and not package.preload[dependency] then
            package.preload[dependency] = function() return Widget end
        end
    end
    return dofile(path)
end

for _, mode in ipairs({"hash","hash-to-doc","hash-to-dir","doc","dir"}) do
for _, cross_account in ipairs({false,true}) do
    local API = support.setup()
    local ok, err = xpcall(function()
        local location = mode:match("^hash%-to%-") and "hash" or mode
        local hash = string.rep("a",32)
        local storage = require("datastorage")
        storage.getHistoryDir = function() return support.directory.."/history" end
        storage.getDocSettingsDir = function() return support.directory.."/docsettings" end
        storage.getDocSettingsHashDir = function() return support.directory.."/hashdocsettings" end
        assert(support.makePath(storage:getDocSettingsHashDir()))
        local settings = require("luasettings")
        settings.extend = Widget.extend
        settings.readSetting = function(self,key,default) local v=self.data[key];if v==nil then return default end;return v end
        settings.saveSetting = function(self,key,value) self.data[key]=value end
        settings.isTrue = function(self,key) return self.data[key]==true end
        settings.has = function(self,key) return self.data[key]~=nil end
        settings.delSetting = function(self,key) self.data[key]=nil end
        settings.backup = function() return false end
        package.loaded.dump = function(data) return "return "..literal(data) end
        package.loaded.logger = {dbg=function() end,warn=function() end}
        package.loaded.random = {uuid=function() return "device" end}
        package.loaded["ui/event"] = {new=function(_,name,...) return {name=name,args={...}} end}
        local ffiutil = require("ffi/util")
        ffiutil.basename = function(file) return file:match("([^/]+)$") end
        ffiutil.template = function(value) return value end
        local util = require("util")
        util.splitFileNameSuffix = function(file) return file:match("^(.*)%.([^%.]+)$") end
        util.removePath = function(folder) return os.remove(folder) end
        util.makePath = support.makePath
        util.writeToFile = function(value,file) support.write(file,value);return true end
        util.partialMD5 = function(file)
            check(support.read(file)=="identical PDF bytes", "Shared hash is based on identical content")
            return hash
        end
        G_reader_settings = {
            readSetting=function(_,key,default) if key=="document_metadata_folder" then return location end;return default end,
            isTrue=function() return false end,
        }
        support.GetText.pgettext = function(_,value) return value end
        support.GetText.ngettext = function(value) return value end
        lfs.attributes = function(file,field)
            local value = attributes(file);if value then value.modification=100 end
            return field and value and value[field] or (not field and value or nil)
        end
        lfs.dir = function(folder)
            if lfs.attributes(folder,"mode")~="directory" then return function() end end
            return dir(folder)
        end
        local DocSettings = dofile(frontend.."/docsettings.lua")
        package.loaded.docsettings = DocSettings
        local ReaderAnnotation = load("apps/reader/modules/readerannotation")
        local ReaderBookmark = load("apps/reader/modules/readerbookmark")
        local function document(path)
            return {file=path,is_pdf=true,info={number_of_pages=2},configurable={text_wrap=0},
                getNativePageDimensions=function() return {w=600,h=800} end,
                getPageBoxesFromPositions=function() return {} end,
                comparePositions=function(_,a,b) return a.y < b.y and 1 or a.y > b.y and -1 or 0 end,
                hasHiddenFlows=function() return false end}
        end
        local function prepare(user,key,annotation_key,text)
            assert(API.setUserID(user))
            local item=support.attachment(key,"paper.pdf",false);item.data.md5=hash
            support.seed({[key]=item},{},10)
            local directory,path=API.getDirAndPath(key)
            assert(support.makePath(directory));support.write(path,"identical PDF bytes")
            support.write(directory.."/.zotero-cache.json",support.JSON.encode({md5=hash,version=10}))
            local snapshot={format=1,user_id=user,attachment_key=key,library_version=10,file_identity={md5=hash},items={{
                key=annotation_key,version=10,data={itemType="annotation",parentItem=key,annotationType="highlight",
                    annotationText=text,annotationPosition=support.JSON.encode({pageIndex=0,rects={{10,20,100,40}}})}}}}
            support.write(directory.."/.zotero-annotations.json",support.JSON.encode(snapshot))
            return {user=user,key=key,path=path,directory=directory,item=item,snapshot=snapshot}
        end
        local a=prepare("123","ATTACH01","ANNOT001","Only A")
        local b=prepare(cross_account and "456" or "123",cross_account and "ATTACH01" or "ATTACH02","ANNOT002","Only B")
        local function activate(record)
            assert(API.setUserID(record.user));support.seed({[record.key]=record.item},{},10)
        end
        local locals={
            {page=1,drawer="lighten",text="Local note",datetime="2026-10-07 00:00:00",pos0={page=1,x=1,y=1},pos1={page=1,x=2,y=2}},
            {page=2,text="Bookmark",datetime="2026-10-07 00:00:00"},
            {page=2,text="Old tagged bookmark",datetime="2026-10-07 00:00:01",
                zotero_source={plugin="zotero.koplugin",user_id="123",attachment_key="ATTACH01"}},
        }
        -- Seed both ordinary path stores and the common hash store with local data.
        for _,record in ipairs({a,b}) do
            local config=DocSettings:open(record.path)
            config.data.annotations=locals;config.data.last_page=2;config.data.percent_finished=0.7
            assert(config:flush(nil,true))
        end
        local function open(record, expected_error, alter)
            activate(record)
            local config=DocSettings:open(record.path)
            local ui={document=document(record.path),paging=true,doc_settings=config,callbacks={},handleEvent=function() end,
                registerPostReaderReadyCallback=function(self,callback) self.callbacks[#self.callbacks+1]=callback end}
            ui.view={highlight={page_boxes={}},footer={maybeUpdateFooter=function() end}}
            ui.annotation=ReaderAnnotation:extend{ui=ui,document=ui.document,view=ui.view}
            ui.bookmark=ReaderBookmark:extend{ui=ui,document=ui.document,view=ui.view}
            if alter then alter(ui,config) end
            if Annotations.bindSettings then Annotations.bindSettings(ui,config,record.user,record.key) end
            Annotations.protectReader(API,ui,record.key)
            ui.annotation:onReadSettings(config)
            local result, apply_err=Annotations.applyToReader(API,ui,config,record.key)
            check(expected_error and not result and (apply_err or expected_error=="missing")
                or result and not apply_err, "Apply result matches cache condition")
            for _, callback in ipairs(ui.callbacks) do callback() end
            local own, local_count=0,0
            for _, item in ipairs(ui.annotation.annotations) do
                if item.drawer and item.zotero_source then
                    check(item.zotero_source.user_id==record.user and item.zotero_source.attachment_key==record.key,
                        "No other account/attachment cloud item is visible")
                    own=own+1
                else local_count=local_count+1 end
            end
            check(local_count==3 and config.data.last_page==2 and config.data.percent_finished==0.7,
                "Local highlights, both bookmarks and reading progress survive")
            return ui,config,own
        end
        local function save(ui,config)
            ui.annotation:onSaveSettings() -- actual native save, followed by actual native flush
            assert(config:flush(nil,true))
        end
        local function navigation(ui)
            check(ui.bookmark:getLastBookmarkedPage(1)==2,"Fallback keeps last-bookmark navigation")
            check(ui.bookmark:getNextBookmarkedPage(1)==2 and ui.bookmark:getPreviousBookmarkedPage(2)==1,
                "Fallback keeps next/previous bookmark navigation")
            local index=ui.bookmark:getDogearBookmarkIndex(2)
            local item=index and ui.annotation.annotations[index]
            check(item and item.page==2 and not item.drawer,"Fallback keeps the local bookmark's dogear")
        end
        local ua,ca,count=open(a);check(count==1,"A imports only its own snapshot");save(ua,ca)
        local switched=mode:match("^hash%-to%-(.*)$");if switched then location=switched end
        local ub,cb,count_b=open(b);check(count_b==1,"B imports only its own snapshot");save(ub,cb)
        local again,again_settings,again_count=open(a);check(again_count==1,"A remains isolated after B saves");save(again,again_settings)
        if mode=="hash" or switched then
            check(lfs.attributes(ca.hash_sidecar_dir.."/metadata.pdf.lua","mode")=="file",
                "Shared hash metadata remains available to the other copy after migration")
        end
        -- Shared native annotations never export cloud projections to an ordinary copy.
        check(#cb.data.annotations==3,"Native persistence contains only the three local items")
        local ordinary=support.directory.."/ordinary.pdf"
        support.write(ordinary,"identical PDF bytes")
        local ordinary_settings=DocSettings:open(ordinary)
        for _,item in ipairs(ordinary_settings:readSetting("annotations",{})) do
            check(not (item.drawer and item.zotero_source),"Unmanaged copies cannot load a cloud projection from native annotations")
        end
        for index,item in ipairs(ub.annotation.annotations) do
            if item.drawer and item.zotero_source then
                local before=#ub.annotation.annotations;ub.bookmark:removeItemByIndex(index)
                check(#ub.annotation.annotations==before,"Own cloud item remains read-only through native deletion")
            end
        end
        -- Guard unexpected foreign projections even if another importer inserts one.
        local foreign=assert(Annotations.convert(a.snapshot,document(a.path)))[1]
        ub.annotation.annotations[#ub.annotation.annotations+1]=foreign
        local before=#ub.annotation.annotations
        ub.bookmark:removeItemByIndex(before)
        check(#ub.annotation.annotations==before,"Foreign cloud provenance cannot bypass the managed reader's mutation guard")
        table.remove(ub.annotation.annotations)
        if mode=="hash" and not cross_account then
            a.snapshot.library_version=11;a.snapshot.items[1].version=11
            a.snapshot.items[1].data.annotationText="New unflushed A"
            support.write(a.directory.."/.zotero-annotations.json",support.JSON.encode(a.snapshot))
            local pending,pc=open(a)
            pending.annotation:onSaveSettings()
            local write=util.writeToFile;util.writeToFile=function() return false end
            check(not pc:flush(nil,true),"Native flush failure is propagated")
            util.writeToFile=write
            local persisted=DocSettings:open(a.path):readSetting("zotero_annotations")["123/ATTACH01"]
            check(persisted.applied.library_version==10 and persisted.annotations[1].text=="Only A",
                "A failed native flush cannot publish a new applied cursor without its projection")
        end
        support.write(a.directory.."/.zotero-annotations.json","corrupt cache")
        local fallback,fc,fallback_count=open(a,true)
        check(fallback_count==1,"Last successful scoped projection survives corrupt cache and another attachment's save")
        local cloud
        for _,item in ipairs(fallback.annotation.annotations) do if item.drawer and item.zotero_source then cloud=item end end
        check(fallback.document:getPageBoxesFromPositions(cloud.page,cloud.pos0,cloud.pos1)==cloud.pboxes,
            "Fallback geometry remains tied to its verified PDF")
        check(cloud.text=="Only A","Corrupt-cache fallback uses the last projection that reached the sidecar")
        navigation(fallback)
        if mode=="hash" and not cross_account then
            local receipt_path=a.directory.."/.zotero-cache.json"
            local receipt=support.read(receipt_path)
            for _,failure in ipairs({"missing","identity","pending","geometry","save"}) do
                support.write(receipt_path,receipt)
                local snapshot=support.JSON.decode(support.JSON.encode(a.snapshot))
                if failure=="identity" then snapshot.file_identity={md5=string.rep("b",32)} end
                local cache_path=a.directory.."/.zotero-annotations.json"
                support.write(cache_path,support.JSON.encode(snapshot))
                if failure=="missing" then assert(os.remove(cache_path)) end
                if failure=="pending" then
                    local pending=support.JSON.decode(receipt);pending.download_pending=true
                    support.write(receipt_path,support.JSON.encode(pending))
                end
                local failed,settings,count=open(a,failure=="missing" and "missing" or true,function(ui,config)
                    if failure=="geometry" then ui.document.getNativePageDimensions=function() return nil end end
                    if failure=="save" then
                        local save=config.saveSetting
                        config.saveSetting=function(self,key,value)
                            save(self,key,value)
                            if key=="zotero_annotations_applied" then error("native settings failure") end
                        end
                    end
                end)
                navigation(failed)
                local applied=settings:readSetting("zotero_annotations_applied")
                check(count==1 and applied.library_version==10,"Failed import preserves the last successful scoped state")
            end
            support.write(receipt_path,receipt)
        end
        save(fallback,fc)
        a.snapshot.items={};a.snapshot.library_version=11
        support.write(a.directory.."/.zotero-annotations.json",support.JSON.encode(a.snapshot))
        local empty,ec,empty_count=open(a)
        check(empty_count==0,"Legitimate empty snapshot removes only A's cloud projection");save(empty,ec)
        local remaining,rc,remaining_count=open(b)
        check(remaining_count==1,"A deletion does not clear B's independent cloud projection");save(remaining,rc)
        check(#support.requests==0 and support.read(a.path)=="identical PDF bytes" and support.read(b.path)=="identical PDF bytes",
            "No HTTP or document write occurs")
    end,debug.traceback)
    lfs.attributes,lfs.dir=attributes,dir
    support.teardown()
    assert(ok,err)
end
end
io.write(string.format("%d native annotation storage checks passed\n",checks))
