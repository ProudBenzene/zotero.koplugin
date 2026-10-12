-- Shared file helpers. Callers enforce ownership and storage boundaries.
local JSON = require("json")
local FileUtil = {}

function FileUtil.validFilename(name)
    return type(name) == "string" and name ~= "" and name ~= "." and name ~= ".."
        and not name:find("[/\\%z]") and not name:match("^%.zotero%-")
end

function FileUtil.readJSON(path, invalid_message)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local content = file:read("*a")
    file:close()
    local ok, value = pcall(JSON.decode, content)
    if not ok or type(value) ~= "table" then return nil, invalid_message or "Invalid JSON data" end
    return value
end

function FileUtil.writeJSON(path, value, encode_message)
    local ok, content = pcall(JSON.encode, value)
    if not ok then return nil, encode_message or tostring(content) end
    local temporary = path .. ".tmp"
    local file, err = io.open(temporary, "wb")
    if not file then return nil, err end
    local written, write_err = file:write(content)
    local closed, close_err = file:close()
    if not written or not closed then os.remove(temporary); return nil, write_err or close_err end
    ok, err = os.rename(temporary, path)
    if not ok then os.remove(temporary) end
    return ok, err
end

function FileUtil.md5(path, progress)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local update, checked = require("ffi/sha2").md5(), 0
    while true do
        local chunk, read_err = file:read(65536)
        if not chunk then
            file:close()
            return not read_err and update() or nil, read_err
        end
        update(chunk)
        checked = checked + #chunk
        if progress then progress(checked) end
    end
end

return FileUtil
