local pcall = pcall
local type = type
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local math_floor = math.floor
local math_min = math.min
local math_max = math.max
local math_abs = math.abs
local math_huge = math.huge
local math_rad = math.rad
local string_find = string.find
local string_sub = string.sub
local string_lower = string.lower
local string_match = string.match
local string_gmatch = string.gmatch
local string_gsub = string.gsub
local string_byte = string.byte
local table_insert = table.insert
local table_create = table.create
local table_sort = table.sort
local table_concat = table.concat
local CFrame_new = CFrame.new
local CFrame_Angles = CFrame.Angles

local HttpService = game:GetService("HttpService")

local COLOR_NAMES = {
    "Bright violet", "CGA brown", "Institutional white", "Lime green",
    "Magenta", "New Yeller", "Parsley green", "Really black",
    "Really blue", "Really red", "Reddish brown", "Smoky grey",
    "Deep orange", "Brown", "Toothpaste", "Navy blue", "Pink",
}
local COLOR_R = {107,175,248,0,170,255,10,17,0,255,105,91,255,106,0,0,255}
local COLOR_G = {50,148,248,255,0,255,100,17,0,0,64,93,176,57,255,32,102}
local COLOR_B = {124,73,248,0,170,0,10,17,255,0,40,105,0,9,255,96,204}
local COLOR_COUNT = 17

local LUT_DIV = 16
local LUT_STEP = 16
local LUT_SIZE = LUT_DIV * LUT_DIV * LUT_DIV
local colorLUT = table_create(LUT_SIZE)

do
    for ri = 0, LUT_DIV - 1 do
        local rc = ri * LUT_STEP + 8
        local riOff = ri * LUT_DIV * LUT_DIV
        for gi = 0, LUT_DIV - 1 do
            local gc = gi * LUT_STEP + 8
            local giOff = gi * LUT_DIV
            for bi = 0, LUT_DIV - 1 do
                local bc = bi * LUT_STEP + 8
                local bestIdx = 1
                local bestDist = 999999
                for c = 1, COLOR_COUNT do
                    local dr = rc - COLOR_R[c]
                    local dg = gc - COLOR_G[c]
                    local db = bc - COLOR_B[c]
                    local d = dr*dr + dg*dg + db*db
                    if d < bestDist then bestDist = d; bestIdx = c end
                end
                colorLUT[riOff + giOff + bi + 1] = bestIdx
            end
        end
    end
end

local function smartAngle(v)
    v = tonumber(v) or 0
    if math_abs(v) > 6.3 then return math_rad(v) end
    return v
end

local function stripBOM(s)
    if string_byte(s,1)==0xEF and string_byte(s,2)==0xBB and string_byte(s,3)==0xBF then
        return string_sub(s, 4)
    end
    return s
end

local DataReader = {}
DataReader.__index = DataReader

function DataReader.new()
    local self = setmetatable({}, DataReader)
    self.MaxPixelResolution = 64
    return self
end

function DataReader:GetClosestColor(r, g, b)
    local ri = math_min(math_floor(r / LUT_STEP), LUT_DIV - 1)
    local gi = math_min(math_floor(g / LUT_STEP), LUT_DIV - 1)
    local bi = math_min(math_floor(b / LUT_STEP), LUT_DIV - 1)
    return COLOR_NAMES[colorLUT[ri * LUT_DIV * LUT_DIV + gi * LUT_DIV + bi + 1]]
end

function DataReader:DetectFormat(raw)
    if type(raw) ~= "string" or #raw == 0 then return "unknown" end
    local s = stripBOM(raw)
    local t = string_match(s, "^%s*(.-)%s*$") or s
    if string_find(t, "^https?://") then
        if string_find(t,"cdn%.discordapp%.com") or string_find(t,"media%.discordapp%.net") or string_find(t,"discord%.com/channels/") then
            return "discord"
        end
        return "url"
    end
    if string_find(t, "local%s+args") then return "lua" end
    local fc = string_sub(t, 1, 1)
    if fc == "[" or fc == "{" then
        if string_find(t, "%[%s*%[%s*%[%s*%d") then return "pixeldata" end
        if string_find(t, '"ClassName"') or string_find(t, '"className"') or string_find(t, '"class"') then return "rbxmodel" end
        return "json"
    end
    local fl = string_match(t, "^([^\n]+)")
    if fl and string_find(fl, "^%-?%d+[%s,]+%-?%d+[%s,]+%-?%d+") then return "csv" end
    return "text"
end

function DataReader:SanitizeJSON(raw)
    local s = stripBOM(raw)
    s = string_gsub(s, "//[^\n]*", "")
    s = string_gsub(s, ",%s*%]", "]")
    s = string_gsub(s, ",%s*%}", "}")
    return string_match(s, "^%s*(.-)%s*$") or s
end

function DataReader:ParseJSON(rawJSON)
    local cleaned = self:SanitizeJSON(rawJSON)
    local ok, parsed = pcall(HttpService.JSONDecode, HttpService, cleaned)
    if not ok then return false, "JSON decode error: "..tostring(parsed) end
    if type(parsed) ~= "table" then return false, "JSON root must be a table." end

    local entries = parsed
    if parsed.blocks and type(parsed.blocks) == "table" then entries = parsed.blocks
    elseif parsed.Blocks and type(parsed.Blocks) == "table" then entries = parsed.Blocks
    elseif parsed.data and type(parsed.data) == "table" then entries = parsed.data
    elseif parsed.parts and type(parsed.parts) == "table" then entries = parsed.parts
    elseif parsed.Parts and type(parsed.Parts) == "table" then entries = parsed.Parts end

    local n = #entries
    local cframes = table_create(n)
    local colors = table_create(n)
    local count = 0

    for i = 1, n do
        local e = entries[i]
        if type(e) == "table" then
            local x, y, z = 0, 0, 0
            local rot = nil

            if e.CFrame and type(e.CFrame) == "table" then
                local cf = e.CFrame
                if #cf >= 12 then
                    count = count + 1
                    cframes[count] = CFrame_new(cf[1],cf[2],cf[3],cf[4],cf[5],cf[6],cf[7],cf[8],cf[9],cf[10],cf[11],cf[12])
                    colors[count] = e.material or e.Material or e.color or e.Color or e.BrickColor or e.brickColor
                    continue
                elseif #cf >= 6 then
                    x, y, z = tonumber(cf[1]) or 0, tonumber(cf[2]) or 0, tonumber(cf[3]) or 0
                    rot = CFrame_Angles(smartAngle(cf[4]), smartAngle(cf[5]), smartAngle(cf[6]))
                elseif #cf >= 3 then
                    x, y, z = tonumber(cf[1]) or 0, tonumber(cf[2]) or 0, tonumber(cf[3]) or 0
                end
            elseif e.pos and type(e.pos) == "table" then
                x = tonumber(e.pos[1]) or 0
                y = tonumber(e.pos[2]) or 0
                z = tonumber(e.pos[3]) or 0
            elseif e.position and type(e.position) == "table" then
                x = tonumber(e.position[1] or e.position.X) or 0
                y = tonumber(e.position[2] or e.position.Y) or 0
                z = tonumber(e.position[3] or e.position.Z) or 0
            else
                x = tonumber(e.x) or tonumber(e.X) or 0
                y = tonumber(e.y) or tonumber(e.Y) or 0
                z = tonumber(e.z) or tonumber(e.Z) or 0
            end

            if not rot then
                local r = e.rot or e.rotation or e.Rotation or e.orientation or e.Orientation
                if r and type(r) == "table" then
                    rot = CFrame_Angles(smartAngle(tonumber(r[1] or r.X) or 0), smartAngle(tonumber(r[2] or r.Y) or 0), smartAngle(tonumber(r[3] or r.Z) or 0))
                end
            end

            local color = e.material or e.Material or e.color or e.Color or e.BrickColor or e.brickColor
            if type(color) == "table" then
                local cr = tonumber(color[1] or color.R or color.r) or 0
                local cg = tonumber(color[2] or color.G or color.g) or 0
                local cb = tonumber(color[3] or color.B or color.b) or 0
                if cr <= 1 and cg <= 1 and cb <= 1 then cr,cg,cb = cr*255, cg*255, cb*255 end
                color = self:GetClosestColor(math_floor(cr), math_floor(cg), math_floor(cb))
            end

            count = count + 1
            local cf = CFrame_new(x, y, z)
            if rot then cf = cf * rot end
            cframes[count] = cf
            colors[count] = type(color) == "string" and color or nil
        end
    end

    if count == 0 then return false, "JSON: 0 valid blocks." end
    return true, {cframes=cframes, colors=colors, count=count, sizeBytes=#rawJSON, metadata={format="json"}}
end

function DataReader:ParseRobloxModel(rawJSON)
    local cleaned = self:SanitizeJSON(rawJSON)
    local ok, parsed = pcall(HttpService.JSONDecode, HttpService, cleaned)
    if not ok then return false, "Model JSON error: "..tostring(parsed) end
    if type(parsed) ~= "table" then return false, "Model JSON root must be a table." end

    local rawParts = {}
    local partCount = 0
    local minX, minY, minZ = math_huge, math_huge, math_huge

    local partClasses = {Part=true, WedgePart=true, SpawnLocation=true, MeshPart=true, UnionOperation=true, TrussPart=true, CornerWedgePart=true, Seat=true, VehicleSeat=true}

    local function extract(node)
        if type(node) ~= "table" then return end
        local cn = node.ClassName or node.className or node.class
        if cn and partClasses[cn] then
            local props = node.Properties or node.properties or node
            local px, py, pz = 0, 0, 0
            local rotCF = nil
            local color = nil

            local pos = props.Position or props.position
            if pos and type(pos) == "table" then
                px = tonumber(pos.X or pos[1]) or 0
                py = tonumber(pos.Y or pos[2]) or 0
                pz = tonumber(pos.Z or pos[3]) or 0
            end

            local cfProp = props.CFrame or props.cframe
            if cfProp and type(cfProp) == "table" then
                if #cfProp >= 12 then
                    px, py, pz = tonumber(cfProp[1]) or 0, tonumber(cfProp[2]) or 0, tonumber(cfProp[3]) or 0
                    rotCF = CFrame_new(0,0,0, cfProp[4],cfProp[5],cfProp[6], cfProp[7],cfProp[8],cfProp[9], cfProp[10],cfProp[11],cfProp[12])
                elseif #cfProp >= 3 then
                    px, py, pz = tonumber(cfProp[1]) or 0, tonumber(cfProp[2]) or 0, tonumber(cfProp[3]) or 0
                end
            end

            local ori = props.Orientation or props.orientation
            if not rotCF and ori and type(ori) == "table" then
                rotCF = CFrame_Angles(
                    math_rad(tonumber(ori.X or ori[1]) or 0),
                    math_rad(tonumber(ori.Y or ori[2]) or 0),
                    math_rad(tonumber(ori.Z or ori[3]) or 0)
                )
            end

            color = props.BrickColor or props.brickColor or props.Color or props.color
            if type(color) == "table" then
                local cr = tonumber(color.R or color.r or color[1]) or 0
                local cg = tonumber(color.G or color.g or color[2]) or 0
                local cb = tonumber(color.B or color.b or color[3]) or 0
                if cr <= 1 and cg <= 1 and cb <= 1 then cr,cg,cb = cr*255, cg*255, cb*255 end
                color = self:GetClosestColor(math_floor(cr), math_floor(cg), math_floor(cb))
            end

            if px < minX then minX = px end
            if py < minY then minY = py end
            if pz < minZ then minZ = pz end

            partCount = partCount + 1
            rawParts[partCount] = {px, py, pz, color, rotCF}
        end

        local children = node.Children or node.children
        if children and type(children) == "table" then
            for _, child in ipairs(children) do extract(child) end
        end
        if node[1] and type(node[1]) == "table" then
            for _, child in ipairs(node) do extract(child) end
        end
    end

    extract(parsed)
    if partCount == 0 then return false, "Model: 0 parts found." end

    local gridSpacing = 3
    local cframes = table_create(partCount)
    local colors = table_create(partCount)

    for i = 1, partCount do
        local b = rawParts[i]
        local gx = math_floor((b[1] - minX) / gridSpacing + 0.5)
        local gy = math_floor((b[2] - minY) / gridSpacing + 0.5)
        local gz = math_floor((b[3] - minZ) / gridSpacing + 0.5)
        local cf = CFrame_new(gx, gy, gz)
        if b[5] then cf = cf * b[5] end
        cframes[i] = cf
        colors[i] = type(b[4]) == "string" and b[4] or nil
    end

    return true, {cframes=cframes, colors=colors, count=partCount, sizeBytes=#rawJSON, metadata={format="rbxmodel"}}
end

function DataReader:ParseLuaScript(rawLua)
    local rawBlocks = {}
    local count = 0
    local minX, minY, minZ = math_huge, math_huge, math_huge

    local curName = nil
    local curX, curY, curZ = nil, nil, nil
    local curRot = nil

    for line in string_gmatch(rawLua, "[^\n]+") do
        local name = string_match(line, '%[1%]%s*=%s*"([^"]+)"')
        if name then curName = name end

        local lx, ly, lz = string_match(line, 'CFrame%.new%(([%d%.%-e]+)%s*,%s*([%d%.%-e]+)%s*,%s*([%d%.%-e]+)')
        if lx then
            curX = tonumber(lx) or 0
            curY = tonumber(ly) or 0
            curZ = tonumber(lz) or 0
        end

        local arx, ary, arz = string_match(line, 'CFrame%.Angles%(([%d%.%-e]+)%s*,%s*([%d%.%-e]+)%s*,%s*([%d%.%-e]+)')
        if arx then
            curRot = CFrame_Angles(tonumber(arx) or 0, tonumber(ary) or 0, tonumber(arz) or 0)
        end

        if string_find(line, "FireServer") then
            if curName and curX then
                if curX < minX then minX = curX end
                if curY < minY then minY = curY end
                if curZ < minZ then minZ = curZ end
                count = count + 1
                rawBlocks[count] = {curX, curY, curZ, curName, curRot}
            end
            curName, curX, curY, curZ, curRot = nil, nil, nil, nil, nil
        end
    end

    if count == 0 then return false, "Lua: 0 valid blocks." end

    local gridSpacing = 3
    if count >= 2 then
        local diffs = {}
        local limit = math_min(count, 30)
        for i = 1, limit do
            for j = i + 1, limit do
                local dx = math_abs(rawBlocks[i][1] - rawBlocks[j][1])
                local dy = math_abs(rawBlocks[i][2] - rawBlocks[j][2])
                local dz = math_abs(rawBlocks[i][3] - rawBlocks[j][3])
                if dx > 0.5 then table_insert(diffs, dx) end
                if dy > 0.5 then table_insert(diffs, dy) end
                if dz > 0.5 then table_insert(diffs, dz) end
            end
        end
        if #diffs > 0 then
            table_sort(diffs)
            gridSpacing = diffs[1]
            if gridSpacing < 1 then gridSpacing = 3 end
        end
    end

    local cframes = table_create(count)
    local colors = table_create(count)

    for i = 1, count do
        local b = rawBlocks[i]
        local gx = math_floor((b[1] - minX) / gridSpacing + 0.5)
        local gy = math_floor((b[2] - minY) / gridSpacing + 0.5)
        local gz = math_floor((b[3] - minZ) / gridSpacing + 0.5)
        local cf = CFrame_new(gx, gy, gz)
        if b[5] then cf = cf * b[5] end
        cframes[i] = cf
        colors[i] = b[4]
    end

    rawBlocks = nil
    return true, {
        cframes=cframes, colors=colors, count=count, sizeBytes=#rawLua,
        metadata={format="lua", gridSpacing=gridSpacing, rawOrigin={minX,minY,minZ}},
    }
end

function DataReader:ParseCSV(rawCSV)
    local cframes, colors, count = {}, {}, 0
    for line in string_gmatch(rawCSV, "[^\n\r]+") do
        local t = string_match(line, "^%s*(.-)%s*$") or line
        if #t > 0 and string_sub(t,1,1) ~= "#" and string_sub(t,1,2) ~= "//" then
            local x,y,z,c = string_match(t, "^([%d%.%-]+)%s*,%s*([%d%.%-]+)%s*,%s*([%d%.%-]+)%s*,?%s*(.*)")
            if not x then x,y,z,c = string_match(t, "^([%d%.%-]+)%s+([%d%.%-]+)%s+([%d%.%-]+)%s*(.*)") end
            if x then
                local cs = nil
                if c and #c > 0 then
                    cs = string_match(c, '^"(.-)"') or string_match(c, "^'(.-)'") or c
                    cs = string_match(cs, "^%s*(.-)%s*$")
                    if cs and #cs == 0 then cs = nil end
                end
                count = count + 1
                cframes[count] = CFrame_new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
                colors[count] = cs
            end
        end
    end
    if count == 0 then return false, "CSV: 0 valid entries." end
    return true, {cframes=cframes, colors=colors, count=count, sizeBytes=#rawCSV, metadata={format="csv"}}
end

function DataReader:ParseText(rawText)
    local cframes, colors, count = {}, {}, 0
    for line in string_gmatch(rawText, "[^\n\r]+") do
        local t = string_match(line, "^%s*(.-)%s*$") or line
        if #t > 0 and string_sub(t,1,1) ~= "#" and string_sub(t,1,2) ~= "//" then
            local name = string_match(t, '"([^"]+)"') or string_match(t, "'([^']+)'") or t
            if #name > 0 and #name < 60 then
                count = count + 1
                cframes[count] = CFrame_new(count - 1, 0, 0)
                colors[count] = name
            end
        end
    end
    if count == 0 then return false, "Text: 0 valid names." end
    return true, {cframes=cframes, colors=colors, count=count, sizeBytes=#rawText, metadata={format="text"}}
end

function DataReader:ParsePixelData(rawJSON, maxW, maxH)
    maxW = maxW or self.MaxPixelResolution
    maxH = maxH or self.MaxPixelResolution
    local cleaned = self:SanitizeJSON(rawJSON)
    local ok, parsed = pcall(HttpService.JSONDecode, HttpService, cleaned)
    if not ok then return false, "Pixel JSON error: "..tostring(parsed) end
    if type(parsed) ~= "table" or #parsed == 0 then return false, "Pixel data must be non-empty." end
    local rows = parsed
    if type(parsed[1]) == "number" then return false, "Pixel data must be 2D." end
    local is2D = type(parsed[1]) == "table" and type(parsed[1][1]) == "table"
    if not is2D then rows = {parsed} end
    local height = math_min(#rows, maxH)
    local width = 0
    for y = 1, height do
        if type(rows[y]) == "table" then width = math_max(width, #rows[y]) end
    end
    width = math_min(width, maxW)
    local cframes = table_create(width * height)
    local colors = table_create(width * height)
    local count = 0
    for y = 1, height do
        local row = rows[y]
        if type(row) == "table" then
            local rw = math_min(#row, width)
            for x = 1, rw do
                local px = row[x]
                if type(px) == "table" and #px >= 3 then
                    local r = math_max(0, math_min(255, math_floor(tonumber(px[1]) or 0)))
                    local g = math_max(0, math_min(255, math_floor(tonumber(px[2]) or 0)))
                    local b = math_max(0, math_min(255, math_floor(tonumber(px[3]) or 0)))
                    count = count + 1
                    cframes[count] = CFrame_new(x - 1, height - y, 0)
                    colors[count] = self:GetClosestColor(r, g, b)
                end
            end
        end
    end
    if count == 0 then return false, "Pixel data: 0 blocks." end
    return true, {cframes=cframes, colors=colors, count=count, sizeBytes=#rawJSON, metadata={format="pixelart", pixelWidth=width, pixelHeight=height}}
end

function DataReader:DownloadContent(url)
    if type(url) ~= "string" or #url == 0 then return false, "URL empty." end
    if string_find(url, "discord%.com/channels/") then
        return false, "Use direct CDN link (cdn.discordapp.com/...)."
    end
    local ok, data = pcall(game.HttpGet, game, url)
    if not ok then return false, "HTTP failed: "..tostring(data) end
    if type(data) ~= "string" or #data == 0 then return false, "Empty response." end
    return true, data
end

function DataReader:HandleDiscordURL(url)
    local lower = string_lower(url)
    if string_find(lower,"%.png") or string_find(lower,"%.jpg") or string_find(lower,"%.jpeg") or string_find(lower,"%.gif") or string_find(lower,"%.webp") then
        return false, "Image files can't be parsed in-game. Convert to JSON pixel array first."
    end
    local ok, content = self:DownloadContent(url)
    if not ok then return false, content end
    return self:Parse(content)
end

function DataReader:Parse(source, options)
    options = options or {}
    if type(source) ~= "string" or #source == 0 then return false, "Input empty." end
    local s = stripBOM(source)
    local fmt = self:DetectFormat(s)

    if fmt == "url" then
        local ok, content = self:DownloadContent(s)
        if not ok then return false, content end
        local pOk, result = self:Parse(content, options)
        if pOk and result.metadata then result.metadata.sourceType = "url"; result.metadata.sourceURL = s end
        return pOk, result
    end
    if fmt == "discord" then
        local pOk, result = self:HandleDiscordURL(s)
        if pOk and result.metadata then result.metadata.sourceType = "discord"; result.metadata.sourceURL = s end
        return pOk, result
    end
    if fmt == "rbxmodel" then return self:ParseRobloxModel(s) end
    if fmt == "json" then return self:ParseJSON(s) end
    if fmt == "lua" then return self:ParseLuaScript(s) end
    if fmt == "csv" then return self:ParseCSV(s) end
    if fmt == "pixeldata" then
        return self:ParsePixelData(s, options.maxPixelWidth or self.MaxPixelResolution, options.maxPixelHeight or self.MaxPixelResolution)
    end
    if fmt == "text" then return self:ParseText(s) end
    return false, "Unknown format."
end

function DataReader:GetBlueprintInfo(bp)
    if not bp or type(bp) ~= "table" then return "No data." end
    local count = bp.count or 0
    local sz = bp.sizeBytes or 0
    local meta = bp.metadata or {}
    local seen, uc = {}, 0
    if bp.colors then
        for i = 1, math_min(count, 500) do
            local c = bp.colors[i]
            if c and not seen[c] then seen[c] = true; uc = uc + 1 end
        end
    end
    local mx, my, mz = 0, 0, 0
    if bp.cframes then
        for i = 1, count do
            local p = bp.cframes[i].Position
            if p.X > mx then mx = p.X end
            if p.Y > my then my = p.Y end
            if p.Z > mz then mz = p.Z end
        end
    end
    local sStr = sz > 1024 and (math_floor(sz/1024).." KB") or (sz.." B")
    local parts = {(meta.format or "?"), count.." blocks", sStr, uc.." colors", (mx+1).."x"..(my+1).."x"..(mz+1)}
    if meta.pixelWidth then table_insert(parts, meta.pixelWidth.."x"..meta.pixelHeight.." px") end
    return table_concat(parts, " | ")
end

function DataReader:ScaleToFit(bp, maxX, maxY, maxZ)
    if not bp or not bp.cframes or bp.count == 0 then return bp end
    local curMX, curMY, curMZ = 0, 0, 0
    for i = 1, bp.count do
        local p = bp.cframes[i].Position
        if p.X > curMX then curMX = p.X end
        if p.Y > curMY then curMY = p.Y end
        if p.Z > curMZ then curMZ = p.Z end
    end
    local sX = curMX > 0 and (maxX / curMX) or 1
    local sY = curMY > 0 and (maxY / curMY) or 1
    local sZ = curMZ > 0 and (maxZ / curMZ) or 1
    local scale = math_min(sX, sY, sZ)
    if scale >= 1.0 then return bp end
    local seen = {}
    local newCF, newCL, newCount = {}, {}, 0
    for i = 1, bp.count do
        local cf = bp.cframes[i]
        local p = cf.Position
        local gx = math_floor(p.X * scale + 0.5)
        local gy = math_floor(p.Y * scale + 0.5)
        local gz = math_floor(p.Z * scale + 0.5)
        local key = gx * 100000000 + gy * 10000 + gz
        if not seen[key] then
            seen[key] = true
            newCount = newCount + 1
            local rot = cf - p
            newCF[newCount] = CFrame_new(gx, gy, gz) * rot
            newCL[newCount] = bp.colors[i]
        end
    end
    bp.cframes = newCF; bp.colors = newCL; bp.count = newCount
    return bp
end

return DataReader
