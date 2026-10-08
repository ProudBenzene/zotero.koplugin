local support = require("tests/support")
local Annotations = require("annotations")
local API, directory, path, attachment
local MD5 = "5d41402abc4b2a76b9719d911017c592"

local function annotation(key, version, options)
    options = options or {}
    return { key = key or "ANNOT001", version = version or 10, data = {
        itemType = "annotation", parentItem = options.parent or "ATTACH01",
        annotationType = options.kind or "highlight", annotationColor = options.color or "#2ea8e5",
        annotationText = options.text or "Selected text", annotationComment = options.comment or "Comment",
        annotationPageLabel = "i", annotationSortIndex = options.sort or "00000|000001|00010",
        annotationPosition = support.JSON.encode(options.position or {pageIndex=0,rects={{10,100,100,120},{20,80,90,95}}}),
        dateAdded = "2026-10-08T04:00:00Z", dateModified = "2026-10-08T05:00:00Z",
    } }
end
local function snapshot(items, version, identity)
    return { format=1,user_id="123",attachment_key="ATTACH01",library_version=version or 10,
        file_identity=identity or {md5=MD5},items=items or {} }
end
local function serve(items, version, parent)
    support.response = function(req)
        assert(req.method=="GET", "Annotation sync must not write to Zotero")
        if req.url:find("/keys/current",1,true) then return support.key(req) end
        if req.url:find("/children?",1,true) then return support.respond(req,items or {},version or 10) end
        if req.url:match("/ATTACH01$") then return support.respond(req,parent or attachment) end
        error("Unexpected annotation request "..req.url)
    end
end
local function cache(items, version, identity)
    support.write(directory.."/.zotero-annotations.json",support.JSON.encode(snapshot(items,version,identity)))
end
local function settings(data)
    return { data=data or {},
        readSetting=function(self,key) return self.data[key] end,
        saveSetting=function(self,key,value) self.data[key]=value end,
    }
end
local function reader(local_items)
    local ui={callbacks={},annotation={annotations=local_items or {}},view={highlight={page_boxes={old=true}}}}
    ui.document={file=path,is_pdf=true,info={number_of_pages=3},configurable={text_wrap=0},
        getNativePageDimensions=function(_,page) return {w=page==2 and 400 or 600,h=page==2 and 500 or 800} end,
        getPageBoxesFromPositions=function() return {"native boxes"} end,
        comparePositions=function() return -1 end,
    }
    ui.registerPostReaderReadyCallback=function(self,fn) self.callbacks[#self.callbacks+1]=fn end
    ui.annotation.updateAnnotations=function(self) self.updated=true end
    ui.onAnnotationsModified=function(self) self.modified=true end
    return ui
end

describe("One-way Zotero PDF annotations",function()
    before_each(function()
        API=support.setup()
        support.plugin() -- Reader/FileManager instances use the data-dir/zotero namespace.
        attachment=support.attachment("ATTACH01","paper.pdf",false)
        attachment.data.md5=MD5
        support.seed({ATTACH01=attachment},{},10)
        directory,path=API.getDirAndPath("ATTACH01")
        assert(support.makePath(directory))
        support.write(path,"hello")
        support.write(directory.."/.zotero-cache.json",support.JSON.encode({version=10,md5=MD5}))
    end)
    after_each(support.teardown)

    it("fetches complete children and checks the parent without advancing the main cursor",function()
        serve({annotation()},12)
        local events={}
        local result,err=API.fetchAttachmentAnnotations("ATTACH01",function(e) events[#events+1]=e.stage end)
        assert(result and not err and result.library_version==12 and result.file_identity.md5==MD5)
        assert(#result.items==1 and #support.requests==3 and API.getLibraryVersion()==10)
        assert(API.getItems().ANNOT001==nil and events[#events]=="checking_annotation_file")
    end)

    it("verifies account ownership and permissions before fetching child data",function()
        support.response=function(req) return support.respond(req,{userID=456,access={user={library=true}}}) end
        local result,err=API.fetchAttachmentAnnotations("ATTACH01")
        assert(not result and err:find("does not belong",1,true) and #support.requests==1)
    end)

    it("restarts a child snapshot whose pagination version changed",function()
        local first=true
        support.response=function(req)
            if req.url:find("/keys/current",1,true) then return support.key(req) end
            if req.url:find("start=100",1,true) then first=false;return support.respond(req,{annotation("ANNOT002",11)},11) end
            if req.url:find("/children?",1,true) then
                if first then return support.respond(req,{annotation()},10,{link='<https://api.zotero.org/users/123/items/ATTACH01/children?start=100>; rel="next"'}) end
                return support.respond(req,{annotation("ANNOT002",11)},11)
            end
            return support.respond(req,attachment)
        end
        local result,err=API.fetchAttachmentAnnotations("ATTACH01")
        assert(not err and #result.items==1 and result.items[1].key=="ANNOT002" and #support.requests==5)
    end)

    it("retries when a newer parent could refer to a different file",function()
        local calls=0
        local parent=support.attachment("ATTACH01","paper.pdf",false,11)
        parent.data.md5=MD5
        support.response=function(req)
            if req.url:find("/keys/current",1,true) then return support.key(req) end
            if req.url:find("/children?",1,true) then calls=calls+1;return support.respond(req,{},calls==1 and 10 or 11) end
            return support.respond(req,parent)
        end
        assert(API.fetchAttachmentAnnotations("ATTACH01").library_version==11 and calls==2)
    end)

    it("bounds changing-parent retries and leaves the previous cache intact",function()
        cache({annotation()})
        local old=support.read(directory.."/.zotero-annotations.json")
        local parent=support.attachment("ATTACH01","paper.pdf",false,100)
        serve({},10,parent)
        local result,err=Annotations.ensureCached(API,"ATTACH01",nil,true)
        assert(not result and err:find("changed",1,true) and #support.requests==7)
        assert(support.read(directory.."/.zotero-annotations.json")==old)
    end)

    it("honors overload responses and reports missing parent data without emptying the cache",function()
        cache({annotation()})
        local old=support.read(directory.."/.zotero-annotations.json")
        support.response=function(req)
            if req.url:find("/keys/current",1,true) then return support.key(req) end
            return support.respond(req,"",nil,{["retry-after"]="60"},429)
        end
        local result,err=Annotations.ensureCached(API,"ATTACH01",nil,true)
        assert(not result and err:find("delay",1,true) and #support.requests==2)
        assert(support.read(directory.."/.zotero-annotations.json")==old)
        API.backoff_until=0
        support.response=function(req)
            if req.url:find("/children?",1,true) then return support.respond(req,{},11) end
            return support.respond(req,"",nil,nil,404)
        end
        result,err=Annotations.ensureCached(API,"ATTACH01",nil,true)
        assert(not result and err:find("404",1,true) and support.read(directory.."/.zotero-annotations.json")==old)
    end)

    it("never fetches a non-PDF or an invalid attachment key",function()
        local epub=support.attachment("ATTACH02","book.epub",false);epub.data.contentType="application/epub+zip"
        API.getItems().ATTACH02=epub
        assert(not API.fetchAttachmentAnnotations("ATTACH02"))
        assert(not API.fetchAttachmentAnnotations("../ATTACH01"))
        local result,err,state=Annotations.ensureCached(API,"ATTACH02")
        assert(not result and not err and state=="unsupported" and #support.requests==0)
    end)

    it("does not interpret a JSON object or an incomplete result count as an empty list",function()
        cache({annotation()})
        local old=support.read(directory.."/.zotero-annotations.json")
        for _,body in ipairs({"{}","[]"}) do
            support.response=function(req)
                if req.url:find("/keys/current",1,true) then return support.key(req) end
                return support.respond(req,body,11,{["total-results"]="1"})
            end
            local result,err=Annotations.ensureCached(API,"ATTACH01",nil,true)
            assert(not result and err and support.read(directory.."/.zotero-annotations.json")==old)
        end
    end)

    it("rejects sparse child arrays and contradictory result counts before replacing the cache",function()
        cache({annotation()})
        local old=support.read(directory.."/.zotero-annotations.json")
        local sparse={[1]=annotation(),[3]=annotation("ANNOT003"),[4]=annotation("ANNOT004")}
        serve(sparse,11)
        assert(not Annotations.ensureCached(API,"ATTACH01",nil,true))
        for _,total in ipairs({"0","-1","1.5","invalid"}) do
            support.response=function(req)
                if req.url:find("/keys/current",1,true) then return support.key(req) end
                return support.respond(req,{annotation()},11,{["total-results"]=total})
            end
            assert(not Annotations.ensureCached(API,"ATTACH01",nil,true))
        end
        assert(support.read(directory.."/.zotero-annotations.json")==old)
    end)

    it("backfills stripped annotation bodies and then skips an unchanged PDF without HTTP",function()
        local remote=annotation()
        API.getItems().ANNOT001={key=remote.key,version=remote.version,data={itemType="annotation",parentItem="ATTACH01"}}
        serve({remote})
        local stats=Annotations.refreshDownloaded(API)
        assert(stats.updated==1 and stats.failed==0 and #support.requests==3)
        assert(Annotations.readCache(API,"ATTACH01").items[1].data.annotationText=="Selected text")
        assert(API.getItems().ANNOT001.data.annotationText==nil)
        support.requests={}
        stats=Annotations.refreshDownloaded(API)
        assert(stats.unchanged==1 and stats.updated==0 and #support.requests==0)
    end)

    it("skips fetching annotations for PDFs that have not been downloaded",function()
        os.remove(path)
        assert(Annotations.refreshDownloaded(API).updated==0 and #support.requests==0)
    end)

    it("fetches cloud changes and the deletion of the last annotation",function()
        cache({annotation()})
        API.getItems().ANNOT001={key="ANNOT001",version=11,data={itemType="annotation",parentItem="ATTACH01"}}
        API.setLibraryVersion(11)
        serve({annotation(nil,11,{text="Updated",comment=""})},11)
        assert(Annotations.refreshDownloaded(API).updated==1)
        assert(Annotations.readCache(API,"ATTACH01").items[1].data.annotationText=="Updated")
        API.getItems().ANNOT001=nil
        API.setLibraryVersion(12)
        serve({},12)
        assert(Annotations.refreshDownloaded(API).updated==1 and #Annotations.readCache(API,"ATTACH01").items==0)
    end)

    it("does not infer deletion from a main library older than the independent snapshot",function()
        cache({annotation("ANNOT002",12)},12)
        local stats=Annotations.refreshDownloaded(API)
        assert(stats.unchanged==1 and #support.requests==0)
        serve({annotation("ANNOT002",12)},12)
        stats=Annotations.refreshDownloaded(API,nil,true)
        assert(stats.updated==1 and #support.requests==3)
    end)

    it("reports partial failures and continues to other cached PDFs",function()
        local second=support.attachment("ATTACH02","other.pdf",false)
        API.getItems().ATTACH02=second
        local dir,file=API.getDirAndPath("ATTACH02")
        assert(support.makePath(dir));support.write(file,"other")
        support.write(dir.."/.zotero-cache.json",support.JSON.encode({version=10}))
        API.fetchAttachmentAnnotations=function(key)
            if key=="ATTACH01" then return nil,"failed first PDF" end
            local result=snapshot({},11,{version=10});result.attachment_key=key;return result
        end
        local stats=Annotations.refreshDownloaded(API)
        assert(stats.updated==1 and stats.failed==1 and #stats.errors==1)
        assert(Annotations.readCache(API,"ATTACH02"))
    end)

    it("preserves the cache and cleans temporary files when atomic publication fails",function()
        cache({annotation()})
        local old=support.read(directory.."/.zotero-annotations.json")
        serve({},11)
        os.rename=function() return nil,"disk error" end
        local result,err=Annotations.ensureCached(API,"ATTACH01",nil,true)
        assert(not result and err:find("disk error",1,true))
        assert(support.read(directory.."/.zotero-annotations.json")==old)
        assert(not require("libs/libkoreader-lfs").attributes(directory.."/.zotero-annotations.json.tmp"))
    end)

    it("recovers a damaged cache only after fetching a valid complete replacement",function()
        support.write(directory.."/.zotero-annotations.json","damaged JSON")
        serve({annotation()})
        assert(Annotations.ensureCached(API,"ATTACH01"))
        assert(Annotations.readCache(API,"ATTACH01"))
    end)

    it("rejects duplicate keys, wrong parents, sparse arrays and invalid supported positions",function()
        local bad=annotation()
        for _,items in ipairs({{bad,bad},{annotation(nil,nil,{parent="OTHER001"})},{[2]=bad},{[1]=bad,[3]=annotation("ANNOT003")}}) do
            assert(not Annotations.normalize(snapshot(items),"123","ATTACH01"))
        end
        bad.data.annotationPosition="invalid JSON"
        assert(not Annotations.normalize(snapshot({bad}),"123","ATTACH01"))
        bad=annotation(nil,nil,{position={pageIndex=0,rects={{1,2,0,3}}}})
        assert(not Annotations.normalize(snapshot({bad}),"123","ATTACH01"))
        assert(not Annotations.normalize(snapshot({}),"456","ATTACH01"))
    end)

    it("does not overwrite a good cache with a malformed response or a backwards version",function()
        cache({annotation()},12)
        local old=support.read(directory.."/.zotero-annotations.json")
        serve({annotation(nil,nil,{parent="OTHER001"})},12)
        assert(not Annotations.ensureCached(API,"ATTACH01",nil,true))
        serve({},11)
        local result,err=Annotations.ensureCached(API,"ATTACH01",nil,true)
        assert(not result and err:find("backwards",1,true) and support.read(directory.."/.zotero-annotations.json")==old)
    end)

    it("keeps source text, comments and colors separate from the compact main library",function()
        local raw=annotation();raw.data.largeUnusedField=string.rep("x",1000)
        serve({raw})
        assert(Annotations.ensureCached(API,"ATTACH01"))
        local cached=Annotations.readCache(API,"ATTACH01")
        assert(cached.items[1].data.largeUnusedField==nil and cached.items[1].data.annotationComment=="Comment")
        assert(not support.read(API.cache_path):find("annotationComment",1,true))
    end)

    it("converts per-page geometry, underline, comments and standard colors",function()
        local ui=reader()
        local first=annotation()
        local second=annotation("ANNOT002",10,{kind="underline",comment="",color="#e56eee",
            position={pageIndex=1,rects={{30,200,90,220}}}})
        local list,err=Annotations.convert(snapshot({first,second}),ui.document)
        assert(not err and #list==2 and list[1].pboxes[1].y==680 and list[1].pboxes[2].y==705)
        assert(list[1].color=="blue" and list[1].note=="Comment" and list[1].pageno==1)
        assert(list[2].pboxes[1].y==280 and list[2].drawer=="underscore" and list[2].color=="purple" and list[2].note==nil)
        assert(list[1].zotero_source.annotation_key=="ANNOT001" and list[1].zotero_source.version==10)
    end)

    it("maps custom colors deterministically and retains the original source color",function()
        local item=annotation(nil,nil,{color="#000000"})
        local raw=snapshot({item})
        local list=assert(Annotations.convert(raw,reader().document))
        assert(list[1].color=="gray" or list[1].color=="olive")
        assert(raw.items[1].data.annotationColor=="#000000")
    end)

    it("converts UTC and explicit-offset dates using the device timezone",function()
        local item=annotation()
        item.data.dateAdded="2026-10-08T12:00:00+08:00"
        item.data.dateModified="2026-10-08T04:00:00.123Z"
        local list=assert(Annotations.convert(snapshot({item}),reader().document))
        local utc=1791432000 -- 2026-10-08 04:00:00 UTC
        assert(list[1].datetime==os.date("%Y-%m-%d %H:%M:%S",utc) and list[1].datetime_updated==nil)
        item.data.dateAdded="2026-02-30T12:00:00Z"
        assert(not Annotations.convert(snapshot({item}),reader().document))
    end)

    it("handles a two-page highlight using each page's dimensions",function()
        local item=annotation(nil,nil,{position={pageIndex=0,rects={{10,100,100,120}},nextPageRects={{10,100,100,120}}}})
        local list=assert(Annotations.convert(snapshot({item}),reader().document))
        assert(list[1].pos0.page==1 and list[1].pos1.page==2)
        assert(list[1].ext[1].pboxes[1].y==680 and list[1].ext[2].pboxes[1].y==380)
    end)

    it("counts unsupported types without requesting geometry or discarding native items",function()
        cache({annotation(nil,nil,{kind="ink"})})
        local native={page=1,datetime="2026-10-07 00:00:00"}
        local ui=reader({native})
        ui.document.getNativePageDimensions=function() error("unsupported annotation must not read pages") end
        local stats=assert(Annotations.applyToReader(API,ui,settings(),"ATTACH01"))
        assert(stats.imported==0 and stats.unsupported==1 and ui.annotation.annotations[1]==native)
    end)

    it("preserves native annotations, bookmarks and progress while restoring edited imported items",function()
        cache({annotation()})
        local local_highlight={page=1,drawer="lighten",pos0={page=1,x=1,y=1},pos1={page=1,x=2,y=2},text="Local"}
        local bookmark={page=2,datetime="2026-10-07 00:00:00"}
        local ui=reader({local_highlight,bookmark})
        local config=settings({percent_finished=0.7,last_page=2})
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01"))
        local imported=ui.annotation.annotations[3]
        imported.text="Locally edited";imported.note="Local change"
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01"))
        assert(#ui.annotation.annotations==3 and ui.annotation.annotations[1]==local_highlight and ui.annotation.annotations[2]==bookmark)
        assert(ui.annotation.annotations[3].text=="Selected text" and ui.annotation.annotations[3].note=="Comment")
        assert(config.data.percent_finished==0.7 and config.data.last_page==2)
        table.remove(ui.annotation.annotations,3)
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01") and #ui.annotation.annotations==3)
        assert(support.read(path)=="hello" and #support.requests==0)
    end)

    it("removes only owned imports when the remote list becomes empty",function()
        cache({annotation()})
        local foreign={page=1,zoteroKey="LEGACY01",zotero_source={plugin="other",user_id="123",attachment_key="ATTACH01"}}
        local ui=reader({foreign});local config=settings()
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01") and #ui.annotation.annotations==2)
        cache({},11)
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01"))
        assert(#ui.annotation.annotations==1 and ui.annotation.annotations[1]==foreign)
        assert(config.data.zotero_annotations_applied.library_version==11)
    end)

    it("carries explicit ownership through native highlight extension and replacement",function()
        cache({annotation()})
        local ui=reader();local config=settings()
        ui.annotation.addItem=function(self,item) self.annotations[#self.annotations+1]=item;return #self.annotations end
        ui.highlight={extendSelection=function(self)
            table.remove(ui.annotation.annotations,self.highlight_idx)
            self.selected_text={text="Extended selection",is_extended=true,drawer="lighten",
                pos0={page=1,x=10,y=10},pos1={page=1,x=30,y=30}}
        end}
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01"))
        ui.highlight.highlight_idx=1;ui.highlight:extendSelection()
        local replacement={page=1,drawer="lighten",text=ui.highlight.selected_text.text,
            pos0=ui.highlight.selected_text.pos0,pos1=ui.highlight.selected_text.pos1}
        ui.annotation:addItem(replacement)
        assert(replacement.zotero_source.annotation_key=="ANNOT001")
        ui.highlight.selected_text={text="A separate local highlight"}
        local native={page=2,drawer="lighten",text="Local"}
        ui.annotation:addItem(native)
        assert(not native.zotero_source)
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01"))
        assert(#ui.annotation.annotations==2 and ui.annotation.annotations[1]==native)
        assert(ui.annotation.annotations[2].text=="Selected text")
    end)

    it("preserves new bookmarks and unrelated highlights while a cloud selection is retained",function()
        cache({annotation()})
        local ui=reader();local config=settings()
        ui.annotation.addItem=function(self,item) self.annotations[#self.annotations+1]=item;return #self.annotations end
        ui.highlight={}
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01"))
        -- Native More-menu dismissal leaves this selection present when hold_pos is nil.
        ui.highlight.selected_text=ui.annotation.annotations[1]
        local bookmark={page=2,text="Local bookmark"}
        local native={page=1,drawer="lighten",text="Independent local highlight",
            pos0={page=1,x=1,y=1},pos1={page=1,x=2,y=2}}
        ui.annotation:addItem(bookmark)
        ui.annotation:addItem(native)
        assert(not bookmark.zotero_source and not native.zotero_source)
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01"))
        assert(#ui.annotation.annotations==3 and ui.annotation.annotations[1]==bookmark
            and ui.annotation.annotations[2]==native)
        assert(ui.annotation.annotations[3].zotero_source.annotation_key=="ANNOT001")
    end)

    it("preserves bookmarks incorrectly tagged by the previous selection adapter",function()
        cache({annotation()})
        local ui=reader();local config=settings()
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01"))
        local bookmark={page=2,text="Previously misclassified bookmark",
            zotero_source=ui.annotation.annotations[1].zotero_source}
        ui.annotation.annotations[#ui.annotation.annotations+1]=bookmark
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01"))
        assert(#ui.annotation.annotations==2 and ui.annotation.annotations[1]==bookmark)
        cache({},11)
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01"))
        assert(#ui.annotation.annotations==1 and ui.annotation.annotations[1]==bookmark)
    end)

    it("does not advance applied state or replace the displayed list after a geometry failure",function()
        cache({annotation()})
        local ui=reader();local config=settings()
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01"))
        local previous,receipt=ui.annotation.annotations,config.data.zotero_annotations_applied
        cache({annotation(nil,11)},11)
        ui.document.getNativePageDimensions=function() return nil end
        local result,err=Annotations.applyToReader(API,ui,config,"ATTACH01")
        assert(not result and err:find("dimensions",1,true) and ui.annotation.annotations==previous)
        assert(config.data.zotero_annotations_applied==receipt)
        ui.document.getNativePageDimensions=function() return {w=600,h=800} end
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01") and config.data.zotero_annotations_applied.library_version==11)
    end)

    it("rejects changed files, out-of-range pages and invalid standard-page geometry",function()
        cache({annotation()},10,{md5=string.rep("1",32)})
        local ui=reader({{page=1}});local config=settings()
        local result,err=Annotations.applyToReader(API,ui,config,"ATTACH01")
        assert(not result and err:find("different PDF",1,true) and config.data.zotero_annotations_applied==nil)
        for _,position in ipairs({{pageIndex=3,rects={{10,100,100,120}}},{pageIndex=0,rects={{10,100,700,120}}}}) do
            cache({annotation(nil,nil,{position=position})})
            assert(not Annotations.applyToReader(API,ui,config,"ATTACH01") and #ui.annotation.annotations==1)
        end
    end)

    it("rolls back an in-memory settings failure and retries the same source snapshot",function()
        cache({annotation()})
        local ui=reader();local config=settings()
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01"))
        local old,applied=ui.annotation.annotations,config.data.zotero_annotations_applied
        cache({},11)
        local save=config.saveSetting
        config.saveSetting=function(self,name,value)
            if name=="zotero_annotations_applied" then error("settings failure") end
            save(self,name,value)
        end
        local result,err=Annotations.applyToReader(API,ui,config,"ATTACH01")
        assert(not result and err:find("settings failure",1,true))
        assert(ui.annotation.annotations==old and config.data.annotations==old and config.data.zotero_annotations_applied==applied)
        config.saveSetting=save
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01") and #ui.annotation.annotations==0)
        assert(config.data.zotero_annotations_applied.library_version==11)
    end)

    it("keeps the last applied rectangles usable when the independent cache is damaged",function()
        cache({annotation()})
        local first=reader();local config=settings()
        assert(Annotations.applyToReader(API,first,config,"ATTACH01"))
        local reopened=reader(config.data.annotations)
        support.write(directory.."/.zotero-annotations.json","damaged")
        local result,err=Annotations.applyToReader(API,reopened,config,"ATTACH01")
        assert(not result and err and config.data.zotero_annotations_applied.library_version==10)
        local item=reopened.annotation.annotations[1]
        assert(reopened.document:getPageBoxesFromPositions(1,item.pos0,item.pos1)==item.pboxes)
        support.write(directory.."/.zotero-cache.json",support.JSON.encode({version=11,md5=string.rep("1",32)}))
        assert(not Annotations.applyToReader(API,reopened,config,"ATTACH01"))
        assert(reopened.document:getPageBoxesFromPositions(1,item.pos0,item.pos1)==nil)
    end)

    it("fetches fresh source data and recomputes positions after the verified PDF changes",function()
        cache({annotation()})
        local new_md5=string.rep("1",32)
        attachment.data.md5=new_md5;attachment.version=11
        support.write(directory.."/.zotero-cache.json",support.JSON.encode({version=11,md5=new_md5}))
        serve({annotation()},11)
        assert(Annotations.ensureCached(API,"ATTACH01").file_identity.md5==new_md5)
        local ui=reader();ui.document.getNativePageDimensions=function() return {w=600,h=600} end
        assert(Annotations.applyToReader(API,ui,settings(),"ATTACH01"))
        assert(ui.annotation.annotations[1].pboxes[1].y==480)
    end)

    it("does not advance the cache after a temporary file write fails",function()
        cache({annotation()});serve({},11)
        local old=support.read(directory.."/.zotero-annotations.json")
        local open=io.open
        io.open=function(file,mode)
            if file==directory.."/.zotero-annotations.json.tmp" then
                return {write=function() return nil,"disk full" end,close=function() return true end}
            end
            return open(file,mode)
        end
        local result,err=Annotations.ensureCached(API,"ATTACH01",nil,true)
        assert(not result and err:find("disk full",1,true) and support.read(directory.."/.zotero-annotations.json")==old)
    end)

    it("supports version-only file receipts when Zotero does not supply an MD5",function()
        support.write(directory.."/.zotero-cache.json",support.JSON.encode({version=10}))
        cache({annotation()},10,{version=10})
        assert(Annotations.applyToReader(API,reader(),settings(),"ATTACH01"))
        cache({annotation()},11,{version=11})
        assert(not Annotations.applyToReader(API,reader(),settings(),"ATTACH01"))
    end)

    it("uses exact rectangles without text lookup and delegates native positions",function()
        cache({annotation()})
        local ui=reader();local config=settings()
        ui.document.comparePositions=function() error("OCR must not be consulted for cloud positions") end
        assert(Annotations.applyToReader(API,ui,config,"ATTACH01"))
        local item=ui.annotation.annotations[1]
        local boxes=ui.document:getPageBoxesFromPositions(1,item.pos0,item.pos1)
        assert(boxes==item.pboxes and #boxes==2)
        assert(ui.document:comparePositions(item.pos0,item.pos1)==1)
        assert(ui.document:getPageBoxesFromPositions(1,{page=1},{page=1})[1]=="native boxes")
        ui.document.configurable.text_wrap=1
        assert(ui.document:getPageBoxesFromPositions(1,item.pos0,item.pos1)==nil)
        ui.document.configurable.text_wrap=0
        assert(ui.document:getPageBoxesFromPositions(1,item.pos0,item.pos1)==boxes)
        ui.callbacks[1]()
        assert(ui.annotation.updated and ui.modified)
    end)

    it("reindexes edited positions and clears native render cache in reflow mode",function()
        cache({annotation()})
        local ui=reader()
        ui.view.drawPageSavedHighlight=function(view) return next(view.highlight.page_boxes) end
        assert(Annotations.applyToReader(API,ui,settings(),"ATTACH01"))
        local item=ui.annotation.annotations[1]
        item.pos0={page=1,x=20,y=20}
        Annotations.reindex(ui)
        assert(ui.document:getPageBoxesFromPositions(1,item.pos0,item.pos1)==item.pboxes)
        ui.view.highlight.page_boxes={stale=true};ui.document.configurable.text_wrap=1
        assert(ui.view:drawPageSavedHighlight()==nil)
    end)

    it("resolves only this account's exact managed PDF path",function()
        local doc=reader().document
        assert(Annotations.managedKey(API,doc)=="ATTACH01")
        doc.file=path..".other";assert(not Annotations.managedKey(API,doc))
        doc.file=path:gsub("/123/","/456/");assert(not Annotations.managedKey(API,doc))
        doc.file=path;doc.is_pdf=false;assert(not Annotations.managedKey(API,doc))
    end)

    it("applies cached annotations on the first absolute-path open when storage uses a relative path",function()
        cache({annotation()})
        local original=API.storage_dir
        local command=assert(io.popen("pwd"));local cwd=command:read("*l");command:close()
        local _,depth=cwd:gsub("/[^/]+","")
        local relative=string.rep("../",depth)..original:sub(2)
        API.storage_dir=relative
        support.real_paths[relative]=original
        local _,relative_path=API.getDirAndPath("ATTACH01")
        support.real_paths[relative_path]=path
        local ui=reader();local plugin=support.plugin();plugin.ui=ui
        -- init() uses the original absolute test DataStorage path; retain the
        -- Kindle-like relative namespace for the loading events under test.
        API.storage_dir=relative
        local config=settings({highlight_write_into_pdf=true,percent_finished=0.4})
        plugin:onDocSettingsLoad(config,ui.document);plugin:onReadSettings(config)
        assert(plugin.annotation_key=="ATTACH01" and #ui.annotation.annotations==1)
        assert(config.data.highlight_write_into_pdf==false and config.data.percent_finished==0.4)
        assert(ui.document:getPageBoxesFromPositions(1,ui.annotation.annotations[1].pos0,ui.annotation.annotations[1].pos1))
        assert(#support.requests==0)
    end)

    it("matches canonical aliases but rejects unresolved and foreign document paths",function()
        local alias=directory.."/../ATTACH01/paper.pdf"
        support.real_paths[alias]=path
        local doc=reader().document;doc.file=alias
        assert(Annotations.managedKey(API,doc)=="ATTACH01")
        support.real_paths[alias]=false
        local realpath=require("ffi/util").realpath
        require("ffi/util").realpath=function(value) if value==alias then return nil end;return realpath(value) end
        assert(not Annotations.managedKey(API,doc))
        require("ffi/util").realpath=realpath
        doc.file="/other/storage/123/ATTACH01/paper.pdf"
        assert(not Annotations.managedKey(API,doc))
    end)

    it("converts an image annotation to a clickable unfilled region with its comment",function()
        local item=annotation(nil,nil,{kind="image",text="",position={pageIndex=1,rects={{30,200,190,320}}}})
        local list=assert(Annotations.convert(assert(Annotations.normalize(snapshot({item}),"123","ATTACH01")),reader().document))
        assert(list[1].drawer=="zotero_region" and list[1].pboxes[1].y==180)
        assert(list[1].text=="Area annotation" and list[1].note=="Comment")
        assert(list[1].zotero_source.annotation_type=="image")
        item.data.annotationPosition=support.JSON.encode({pageIndex=0,rects={}})
        assert(not Annotations.normalize(snapshot({item}),"123","ATTACH01"))
    end)

    it("draws only a region border and delegates normal native drawing",function()
        cache({annotation(nil,nil,{kind="image"})})
        local ui=reader();local delegated=0
        ui.view.drawHighlightRect=function() delegated=delegated+1;return "native" end
        assert(Annotations.applyToReader(API,ui,settings(),"ATTACH01"))
        local calls={};local bb={paintBorder=function(_,...) calls[#calls+1]={...} end,
            paintBorderRGB32=function(_,...) calls[#calls+1]={...} end}
        ui.view:drawHighlightRect(bb,0,0,{x=10,y=20,w=100,h=80},"zotero_region",15,true)
        ui.view:drawHighlightRect(bb,0,0,{x=10,y=20,w=100,h=80},"zotero_region","blue",true)
        assert(#calls==2 and calls[1][1]==10 and calls[1][3]==100 and calls[1][5]==2 and delegated==0)
        assert(ui.view:drawHighlightRect(bb,0,0,{},"lighten",nil,nil)=="native" and delegated==1)
    end)

    it("shows a region's comment without text lookup and handles an empty comment",function()
        cache({annotation(nil,nil,{kind="image",comment=""})})
        local ui=reader();local delegated=0
        ui.highlight={showHighlightNoteOrDialog=function() delegated=delegated+1 end}
        assert(Annotations.applyToReader(API,ui,settings(),"ATTACH01"))
        ui.highlight:showHighlightNoteOrDialog(1)
        assert(support.UI.shown[#support.UI.shown].text=="No comment." and delegated==0)
        ui.annotation.annotations[1].note="区域的评论"
        ui.highlight:showHighlightNoteOrDialog(1)
        assert(support.UI.shown[#support.UI.shown].text=="区域的评论")
        ui.annotation.annotations[1].zotero_source.annotation_type="highlight"
        ui.highlight:showHighlightNoteOrDialog(1);assert(delegated==1)
    end)

    it("refreshes only a downloaded PDF from its hold menu and preserves the file",function()
        cache({annotation()});serve({annotation(nil,11,{text="Changed remotely"})},11)
        local plugin=support.plugin();local browser=plugin.browser
        browser:onMenuHold({key="ATTACH01",text="Paper",file_type="PDF"})
        local viewer=support.UI.shown[#support.UI.shown]
        assert(viewer.buttons_table[2][1].text=="Refresh annotations" and viewer.buttons_table[2][1].enabled)
        API.syncAllItems=function() error("Single-file refresh must not sync the full library") end
        API.downloadAndGetPath=function() error("Single-file refresh must not download a PDF") end
        viewer.buttons_table[2][1].callback()
        browser:refreshAnnotations({key="ATTACH01"})
        assert(#support.UI.scheduled==1)
        support.UI.scheduled[1]()
        assert(Annotations.readCache(API,"ATTACH01").items[1].data.annotationText=="Changed remotely")
        assert(support.read(path)=="hello" and not browser.downloading and support.opened_path==nil)
        assert(support.UI.shown[#support.UI.shown].text:find("PDF annotations updated",1,true))
        for _,req in ipairs(support.requests) do assert(req.method=="GET") end
    end)

    it("preserves a good cache when a hold-menu refresh fails and skips undownloaded PDFs",function()
        cache({annotation()});local old=support.read(directory.."/.zotero-annotations.json")
        local browser=support.plugin().browser
        API.fetchAttachmentAnnotations=function() return nil,"offline" end
        browser:refreshAnnotations({key="ATTACH01"});support.UI.scheduled[1]()
        assert(not browser.downloading and support.read(directory.."/.zotero-annotations.json")==old)
        assert(support.UI.shown[#support.UI.shown].icon=="notice-warning")
        os.remove(path)
        browser:onMenuHold({key="ATTACH01",file_type="PDF"})
        assert(not support.UI.shown[#support.UI.shown].buttons_table[2][1].enabled)
        browser:refreshAnnotations({key="ATTACH01"});assert(#support.UI.scheduled==1)
        attachment.data.contentType="application/epub+zip"
        browser:onMenuHold({key="ATTACH01",file_type="EPUB"})
        assert(#support.UI.shown[#support.UI.shown].buttons_table==1)
    end)

    it("loads managed PDFs through reader events without HTTP and disables embedded writing per file",function()
        cache({annotation()})
        local plugin=support.plugin()
        local ui=reader({{page=2}});plugin.ui=ui
        local config=settings({highlight_write_into_pdf=true})
        plugin:onDocSettingsLoad(config,ui.document)
        assert(config.data.highlight_write_into_pdf==false)
        plugin:onReadSettings(config)
        assert(#ui.annotation.annotations==2 and #support.requests==0)
        local other=settings({highlight_write_into_pdf=true})
        ui.document.file="/other/paper.pdf"
        plugin:onDocSettingsLoad(other,ui.document)
        plugin:onReadSettings(other)
        assert(other.data.highlight_write_into_pdf==true and #ui.annotation.annotations==2)
    end)

    it("imports without DocSettingsLoad and resets a PDF-write preference loaded by the reader",function()
        cache({annotation(),annotation("REGION01",10,{kind="image"})})
        local plugin=support.plugin()
        local ui=reader({{page=2}});plugin.ui=ui
        ui.highlight={highlight_write_into_pdf=true}
        local config=settings({highlight_write_into_pdf=true,percent_finished=0.7})
        assert(plugin.annotation_key==nil)
        plugin:onReadSettings(config)
        assert(plugin.annotation_key=="ATTACH01" and #ui.annotation.annotations==3)
        assert(config.data.highlight_write_into_pdf==false and ui.highlight.highlight_write_into_pdf==false)
        assert(config.data.percent_finished==0.7 and #support.requests==0 and support.read(path)=="hello")
    end)

    it("prepares a managed PDF before native settings events during plugin initialization",function()
        local plugin=dofile("main.lua")
        local ui=reader()
        ui.menu={registerToMainMenu=function() end}
        ui.doc_settings=settings({highlight_write_into_pdf=true})
        plugin.ui=ui
        plugin:init()
        assert(plugin.initialized and plugin.annotation_key=="ATTACH01")
        assert(ui.doc_settings.data.highlight_write_into_pdf==false and #support.requests==0)
    end)

    it("continues opening a PDF when first-time annotation fetching fails",function()
        local plugin=support.plugin()
        plugin.browser.close_callback=function() end
        API.fetchAttachmentAnnotations=function() return nil,"offline" end
        plugin.browser:onMenuSelect({key="ATTACH01"})
        support.UI.scheduled[1]()
        assert(support.opened_path==path and support.read(path)=="hello")
        assert(support.UI.shown[#support.UI.shown].text:find("PDF annotations were not updated",1,true))
    end)

    it("adds forced annotation refresh to Maintenance and reports partial success",function()
        cache({annotation()})
        local plugin=support.plugin()
        local menus={};plugin:addToMainMenu(menus)
        API.syncAllItems=function() end
        API.fetchAttachmentAnnotations=function() return nil,"offline" end
        menus.zotero.sub_item_table[3].sub_item_table[2].callback()
        support.UI.scheduled[1]()
        local message=support.UI.shown[#support.UI.shown]
        assert(message.icon=="notice-warning" and message.text:find("failed: 1",1,true))
        assert(Annotations.readCache(API,"ATTACH01") and not plugin.syncing)
    end)

    it("updates only the cache while a PDF is being read and applies it on the next load",function()
        cache({annotation()})
        local plugin=support.plugin();local ui=reader();plugin.ui=ui
        local config=settings()
        plugin:onDocSettingsLoad(config,ui.document);plugin:onReadSettings(config)
        local displayed=ui.annotation.annotations
        API.syncAllItems=function() return nil end
        serve({annotation(nil,11,{text="Changed remotely"})},11)
        plugin:onZoteroSyncAction()
        support.UI.scheduled[1]()
        assert(Annotations.readCache(API,"ATTACH01").library_version==11)
        assert(ui.annotation.annotations==displayed and displayed[1].text=="Selected text")
        assert(config.data.zotero_annotations_applied.library_version==10)
        plugin:onReadSettings(config)
        assert(ui.annotation.annotations[1].text=="Changed remotely" and config.data.zotero_annotations_applied.library_version==11)
    end)

    it("shows Chinese annotation progress and summary messages",function()
        support.GetText.current_lang="zh_CN"
        assert(Annotations.text("Fetching PDF annotations…")=="正在获取 PDF 批注…")
        assert(Annotations.summary({updated=1,unchanged=2,failed=0,unsupported=1,errors={}}):find("已缓存：1",1,true))
    end)
end)
