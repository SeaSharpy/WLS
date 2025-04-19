local json = require("json")
local lines = io.lines("mime.json")
local mime = ""
for line in lines do
    mime = mime .. line
end

local mimes = json.decode(mime)
local mime_file = "return {"

for _, mime in ipairs(mimes) do
    local name = mime.name
    local file_types = mime.fileTypes
    for _, file_type in ipairs(file_types) do
        mime_file = mime_file .. [[
    ["]] .. file_type .. [["] = "]] .. name .. [[",
]]
    end
end

mime_file = mime_file .. "}"
local mime_file_f = io.open("mime.lua", "w")
mime_file_f:write(mime_file)
mime_file_f:close()