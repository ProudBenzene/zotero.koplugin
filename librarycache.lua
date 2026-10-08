-- Read a large legacy snapshot one record at a time. Its note/annotation bodies
-- must never coexist with a complete input JSON string in the Lua heap.
local Cache = {}
function Cache.read(path, JSON, item_projection, collection_projection)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local reader = { buffer = "", position = 1 }
    function reader:ready()
        if self.position <= #self.buffer then return true end
        self.buffer = file:read(65536) or ""
        self.position = 1
        return #self.buffer > 0
    end
    function reader:space()
        while self:ready() do
            local first = self.buffer:find("%S", self.position)
            if first then self.position = first; return end
            self.position = #self.buffer + 1
        end
    end
    function reader:expect(character)
        self:space()
        if self.buffer:sub(self.position, self.position) ~= character then error("Invalid cache JSON separator") end
        self.position = self.position + 1
    end
    function reader:value()
        self:space()
        local pieces, start = {}, self.position
        local first = self.buffer:sub(start,start)
        local compound = first == "{" or first == "[" or first == '"'
        local quoted, escaped, depth = false, false, 0
        local function finish(last, following)
            pieces[#pieces+1] = self.buffer:sub(start,last)
            self.position = following
            return table.concat(pieces)
        end
        while true do
            if not self:ready() then error("Unexpected end of cache JSON") end
            if escaped then
                self.position = self.position + 1
                escaped = false
            else
                local token = self.buffer:find(quoted and '["\\]' or '["\\{}%[%],%s]', self.position)
                if token then
                    local character = self.buffer:sub(token,token)
                    self.position = token + 1
                    if quoted then
                        if character == "\\" then escaped = true
                        elseif character == '"' then
                            quoted = false
                            if depth == 0 then return finish(token,token+1) end
                        end
                    elseif character == '"' then quoted = true
                    elseif character == "{" or character == "[" then depth = depth + 1
                    elseif character == "}" or character == "]" then
                        if depth == 0 then return finish(token-1,token) end
                        depth = depth - 1
                        if depth == 0 then return finish(token,token+1) end
                    elseif depth == 0 and not compound then return finish(token-1,token)
                    end
                else self.position = #self.buffer + 1 end
            end
            if self.position > #self.buffer then
                pieces[#pieces+1] = self.buffer:sub(start)
                if not self:ready() then error("Unexpected end of cache JSON") end
                start = 1
            end
        end
    end
    function reader:object(member)
        local object = {}
        self:expect("{")
        self:space()
        if self.buffer:sub(self.position,self.position) == "}" then self.position=self.position+1; return object end
        while true do
            local key = JSON.decode(self:value())
            if type(key) ~= "string" then error("Invalid cache object key") end
            self:expect(":")
            object[key] = member(key)
            self:space()
            local separator = self.buffer:sub(self.position,self.position)
            if separator == "}" then self.position=self.position+1; return object end
            self:expect(",")
        end
    end
    local ok, state = pcall(function()
        local parsed = reader:object(function(key)
            local projection = key == "items" and item_projection or key == "collections" and collection_projection
            if projection then
                return reader:object(function()
                    local item = JSON.decode(reader:value())
                    if type(item) ~= "table" or type(item.data) ~= "table" then error("Invalid cache record") end
                    return projection(item)
                end)
            end
            return JSON.decode(reader:value())
        end)
        reader:space()
        if reader:ready() then error("Unexpected trailing cache JSON") end
        return parsed
    end)
    file:close()
    if not ok then return nil, "Could not parse cache JSON: " .. tostring(state) end
    return state
end
return Cache
