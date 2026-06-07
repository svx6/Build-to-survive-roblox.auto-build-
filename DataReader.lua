--[[
================================================================================
  MODULE 1 — DATA READER  (DataReader.lua)
  Pro Architect V7.1 — GC-Optimized Multi-Format Parser

  CRITICAL ARCHITECTURAL CONSTRAINT:
    Every parser outputs the SAME flat-array blueprint format:
      {
        cframes  = { CFrame, CFrame, ... },  -- engine-allocated, NOT GC-tracked
        colors   = { "str", "str", ... },     -- string references, no per-block tables
        count    = N,
        sizeBytes = N,
        metadata = { ... },
      }
    This guarantees ZERO Lua GC allocations per block in BuildEngine's hot loop.

  CFrame and Vector3 are Roblox engine types (C++ heap, not Lua GC heap).
  By storing CFrame objects directly instead of {x,y,z} Lua tables, we eliminate
  N table allocations per blueprint parse AND N table reads per build iteration.
================================================================================
--]]

--------------------------------------------------------------------------------
-- §1  LUAU VARIABLE CACHING
--------------------------------------------------------------------------------
local pcall          = pcall
local type           = type
local ipairs         = ipairs
local tonumber       = tonumber
local tostring       = tostring
local math_floor     = math.floor
local math_sqrt      = math.sqrt
local math_min       = math.min
local math_max       = math.max
local math_abs       = math.abs
local math_huge      = math.huge
local string_find    = string.find
local string_sub     = string.sub
local string_lower   = string.lower
local string_match   = string.match
local string_gmatch  = string.gmatch
local string_gsub    = string.gsub
local string_byte    = string.byte
local table_insert   = table.insert
local table_create   = table.create
local table_sort     = table.sort
local table_concat   = table.concat
local CFrame_new     = CFrame.new

--------------------------------------------------------------------------------
-- §2  SERVICE CACHING
--------------------------------------------------------------------------------
local HttpService = game:GetService("HttpService")

--------------------------------------------------------------------------------
-- §3  VERIFIED COLOR RGB REGISTRY (17 game colors)
-- Pre-computed from BrickColor RGB values for Euclidean distance matching.
-- Stored as flat arrays for cache-line-friendly iteration.
--------------------------------------------------------------------------------
local COLOR_NAMES = {
    "Bright violet", "CGA brown", "Institutional white", "Lime green",
    "Magenta", "New Yeller", "Parsley green", "Really black",
    "Really blue", "Really red", "Reddish brown", "Smoky grey",
    "Deep orange", "Brown", "Toothpaste", "Navy blue", "Pink",
}
local COLOR_R = { 107, 175, 248,   0, 170, 255,  10,  17,   0, 255, 105,  91, 255, 106,   0,   0, 255 }
local COLOR_G = {  50, 148, 248, 255,   0, 255, 100,  17,   0,   0,  64,  93, 176,  57, 255,  32, 102 }
local COLOR_B = { 124,  73, 248,   0, 170,   0,  10,  17, 255,   0,  40, 105,   0,   9, 255,  96, 204 }
local COLOR_COUNT = #COLOR_NAMES

--------------------------------------------------------------------------------
-- §4  DATA READER CLASS
--------------------------------------------------------------------------------
local DataReader = {}
DataReader.__index = DataReader

function DataReader.new()
    local self = setmetatable({}, DataReader)
    self.MaxPixelResolution = 64
    return self
end

--------------------------------------------------------------------------------
-- §5  RGB → CLOSEST BRICKCOLOR (Optimized Euclidean Distance)
-- Uses squared distance to avoid sqrt overhead (comparison-only).
-- Falls through to exact match early-exit.
--------------------------------------------------------------------------------
function DataReader:GetClosestColor(r, g, b)
    local bestIdx = 1
    local bestDistSq = math_huge

    for i = 1, COLOR_COUNT do
        local dr = r - COLOR_R[i]
        local dg = g - COLOR_G[i]
        local db = b - COLOR_B[i]
        local distSq = dr * dr + dg * dg + db * db

        if distSq < bestDistSq then
            bestDistSq = distSq
            bestIdx = i
            if distSq == 0 then break end
        end
    end

    return COLOR_NAMES[bestIdx]
end

--------------------------------------------------------------------------------
-- §6  FORMAT SNIFFING
--------------------------------------------------------------------------------
function DataReader:DetectFormat(raw)
    if type(raw) ~= "string" or #raw == 0 then return "unknown" end

    -- Strip UTF-8 BOM
    local s = raw
    if string_byte(s, 1) == 0xEF and string_byte(s, 2) == 0xBB and string_byte(s, 3) == 0xBF then
        s = string_sub(s, 4)
    end

    local trimmed = string_match(s, "^%s*(.-)%s*$") or s

    -- URL detection (must precede content checks)
    if string_find(trimmed, "^https?://") then
        if string_find(trimmed, "cdn%.discordapp%.com")
            or string_find(trimmed, "media%.discordapp%.net")
            or string_find(trimmed, "discord%.com/channels/") then
            return "discord"
        end
        return "url"
    end

    -- Lua remote-spy script
    if string_find(trimmed, "local%s+args") then return "lua" end

    -- JSON (with pixel-data sub-detection)
    local fc = string_sub(trimmed, 1, 1)
    if fc == "[" or fc == "{" then
        if string_find(trimmed, "%[%s*%[%s*%[%s*%d") then return "pixeldata" end
        return "json"
    end

    -- CSV: lines starting with numbers separated by commas/spaces
    local firstLine = string_match(trimmed, "^([^\n]+)")
    if firstLine and string_find(firstLine, "^%-?%d+[%s,]+%-?%d+[%s,]+%-?%d+") then
        return "csv"
    end

    return "text"
end

--------------------------------------------------------------------------------
-- §7  JSON SANITIZATION
--------------------------------------------------------------------------------
function DataReader:SanitizeJSON(raw)
    local s = raw
    if string_byte(s, 1) == 0xEF and string_byte(s, 2) == 0xBB and string_byte(s, 3) == 0xBF then
        s = string_sub(s, 4)
    end
    s = string_gsub(s, "//[^\n]*", "")
    s = string_gsub(s, ",%s*%]", "]")
    s = string_gsub(s, ",%s*%}", "}")
    s = string_match(s, "^%s*(.-)%s*$") or s
    return s
end

--------------------------------------------------------------------------------
-- §8  JSON BLUEPRINT PARSER → CFrame[] + string[]
-- Supports: raw arrays, {blocks:[...]}, {Blocks:[...]}, {data:[...]}
-- Per-block fields: x/X, y/Y, z/Z, pos:[x,y,z], color, material, type
--------------------------------------------------------------------------------
function DataReader:ParseJSON(rawJSON)
    local cleaned = self:SanitizeJSON(rawJSON)
    local ok, parsed = pcall(HttpService.JSONDecode, HttpService, cleaned)
    if not ok then return false, "JSON decode error: " .. tostring(parsed) end
    if type(parsed) ~= "table" then return false, "JSON root must be a table." end

    -- Unwrap wrapper objects
    local entries = parsed
    if parsed.blocks and type(parsed.blocks) == "table" then
        entries = parsed.blocks
    elseif parsed.Blocks and type(parsed.Blocks) == "table" then
        entries = parsed.Blocks
    elseif parsed.data and type(parsed.data) == "table" then
        entries = parsed.data
    end

    local n = #entries
    local cframes = table_create(n)
    local colors  = table_create(n)
    local count   = 0

    for i = 1, n do
        local e = entries[i]
        if type(e) == "table" then
            local x, y, z
            if e.pos and type(e.pos) == "table" then
                x = tonumber(e.pos[1]) or 0
                y = tonumber(e.pos[2]) or 0
                z = tonumber(e.pos[3]) or 0
            else
                x = tonumber(e.x) or tonumber(e.X) or 0
                y = tonumber(e.y) or tonumber(e.Y) or 0
                z = tonumber(e.z) or tonumber(e.Z) or 0
            end

            local color = e.material or e.Material or e.color or e.Color or nil

            count = count + 1
            cframes[count] = CFrame_new(x, y, z)
            colors[count]  = color
        end
    end

    if count == 0 then return false, "JSON contains 0 valid blocks." end

    return true, {
        cframes   = cframes,
        colors    = colors,
        count     = count,
        sizeBytes = #rawJSON,
        metadata  = { format = "json" },
    }
end

--------------------------------------------------------------------------------
-- §9  LUA SCRIPT PARSER (Remote-Spy Format) → CFrame[] + string[]
-- Extracts [1]="BlockName" and [2]=CFrame.new(x,y,z) from each args block.
-- Auto-normalizes absolute world coordinates to 0-based grid offsets.
--------------------------------------------------------------------------------
function DataReader:ParseLuaScript(rawLua)
    local rawBlocks = {}  -- temporary: {x, y, z, name}
    local count = 0
    local minX, minY, minZ = math_huge, math_huge, math_huge

    -- Pass 1: Line-by-line stateful extraction
    -- (More robust than gmatch on multi-line blocks because it handles
    --  varying whitespace, line breaks inside args tables, and comments.)
    local curName = nil
    local curX, curY, curZ = nil, nil, nil

    for line in string_gmatch(rawLua, "[^\n]+") do
        local name = string_match(line, '%[1%]%s*=%s*"([^"]+)"')
        if name then curName = name end

        local lx, ly, lz = string_match(
            line, 'CFrame%.new%(([%d%.%-e]+)%s*,%s*([%d%.%-e]+)%s*,%s*([%d%.%-e]+)%)'
        )
        if lx then
            curX = tonumber(lx) or 0
            curY = tonumber(ly) or 0
            curZ = tonumber(lz) or 0
        end

        if string_find(line, "FireServer") then
            if curName and curX then
                count = count + 1
                rawBlocks[count] = { curX, curY, curZ, curName }
                if curX < minX then minX = curX end
                if curY < minY then minY = curY end
                if curZ < minZ then minZ = curZ end
            end
            curName, curX, curY, curZ = nil, nil, nil, nil
        end
    end

    if count == 0 then return false, "Lua script: 0 valid blocks found." end

    -- Pass 2: Detect grid spacing from coordinate deltas
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

    -- Pass 3: Normalize to 0-based grid → CFrame[]
    local cframes = table_create(count)
    local colors  = table_create(count)

    for i = 1, count do
        local b = rawBlocks[i]
        local gx = math_floor((b[1] - minX) / gridSpacing + 0.5)
        local gy = math_floor((b[2] - minY) / gridSpacing + 0.5)
        local gz = math_floor((b[3] - minZ) / gridSpacing + 0.5)
        cframes[i] = CFrame_new(gx, gy, gz)
        colors[i]  = b[4]
    end

    -- Release temporary table
    rawBlocks = nil

    return true, {
        cframes   = cframes,
        colors    = colors,
        count     = count,
        sizeBytes = #rawLua,
        metadata  = {
            format      = "lua",
            gridSpacing = gridSpacing,
            rawOrigin   = { minX, minY, minZ },
        },
    }
end

--------------------------------------------------------------------------------
-- §10  CSV PARSER → CFrame[] + string[]
-- Formats: x,y,z[,color]  or  x y z [color]
--------------------------------------------------------------------------------
function DataReader:ParseCSV(rawCSV)
    local cframes = {}
    local colors  = {}
    local count   = 0

    for line in string_gmatch(rawCSV, "[^\n\r]+") do
        local t = string_match(line, "^%s*(.-)%s*$") or line
        if #t > 0 and string_sub(t, 1, 1) ~= "#" and string_sub(t, 1, 2) ~= "//" then
            local x, y, z, c = string_match(t, "^([%d%.%-]+)%s*,%s*([%d%.%-]+)%s*,%s*([%d%.%-]+)%s*,?%s*(.*)")
            if not x then
                x, y, z, c = string_match(t, "^([%d%.%-]+)%s+([%d%.%-]+)%s+([%d%.%-]+)%s*(.*)")
            end
            if x then
                local colorStr = nil
                if c and #c > 0 then
                    colorStr = string_match(c, '^"(.-)"') or string_match(c, "^'(.-)'") or c
                    colorStr = string_match(colorStr, "^%s*(.-)%s*$")
                    if colorStr and #colorStr == 0 then colorStr = nil end
                end
                count = count + 1
                cframes[count] = CFrame_new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
                colors[count]  = colorStr
            end
        end
    end

    if count == 0 then return false, "CSV: 0 valid entries." end
    return true, {
        cframes = cframes, colors = colors, count = count,
        sizeBytes = #rawCSV, metadata = { format = "csv" },
    }
end

--------------------------------------------------------------------------------
-- §11  PLAIN TEXT PARSER → CFrame[] + string[]
-- One block name per line; placed linearly along X axis.
--------------------------------------------------------------------------------
function DataReader:ParseText(rawText)
    local cframes = {}
    local colors  = {}
    local count   = 0

    for line in string_gmatch(rawText, "[^\n\r]+") do
        local t = string_match(line, "^%s*(.-)%s*$") or line
        if #t > 0 and string_sub(t, 1, 1) ~= "#" and string_sub(t, 1, 2) ~= "//" then
            local name = string_match(t, '"([^"]+)"') or string_match(t, "'([^']+)'") or t
            if #name > 0 and #name < 60 then
                count = count + 1
                cframes[count] = CFrame_new(count - 1, 0, 0)
                colors[count]  = name
            end
        end
    end

    if count == 0 then return false, "Text: 0 valid block names." end
    return true, {
        cframes = cframes, colors = colors, count = count,
        sizeBytes = #rawText, metadata = { format = "text" },
    }
end

--------------------------------------------------------------------------------
-- §12  PIXEL ART DATA PARSER → CFrame[] + string[]
-- Input: JSON 2D array of [r,g,b] triplets.
-- Output: Flat wall of blocks with closest-match BrickColors.
-- Enforces maxWidth × maxHeight cap (default 64×64).
--------------------------------------------------------------------------------
function DataReader:ParsePixelData(rawJSON, maxW, maxH)
    maxW = maxW or self.MaxPixelResolution
    maxH = maxH or self.MaxPixelResolution

    local cleaned = self:SanitizeJSON(rawJSON)
    local ok, parsed = pcall(HttpService.JSONDecode, HttpService, cleaned)
    if not ok then return false, "Pixel JSON error: " .. tostring(parsed) end
    if type(parsed) ~= "table" or #parsed == 0 then
        return false, "Pixel data must be a non-empty 2D array."
    end

    -- Detect 1D vs 2D
    local rows = parsed
    if type(parsed[1]) == "number" then
        return false, "Pixel data must be 2D: [[[r,g,b],...],...]"
    end
    local is2D = type(parsed[1]) == "table" and type(parsed[1][1]) == "table"
    if not is2D then rows = { parsed } end

    local height = math_min(#rows, maxH)
    local width  = 0
    for y = 1, height do
        if type(rows[y]) == "table" then
            width = math_max(width, #rows[y])
        end
    end
    width = math_min(width, maxW)

    local cframes = table_create(width * height)
    local colors  = table_create(width * height)
    local count   = 0

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
                    colors[count]  = self:GetClosestColor(r, g, b)
                end
            end
        end
    end

    if count == 0 then return false, "Pixel data produced 0 blocks." end
    return true, {
        cframes = cframes, colors = colors, count = count,
        sizeBytes = #rawJSON,
        metadata = { format = "pixelart", pixelWidth = width, pixelHeight = height },
    }
end

--------------------------------------------------------------------------------
-- §13  URL DOWNLOADER
--------------------------------------------------------------------------------
function DataReader:DownloadContent(url)
    if type(url) ~= "string" or #url == 0 then return false, "URL is empty." end
    if string_find(url, "discord%.com/channels/") then
        return false, "Discord message links require a direct CDN URL. "
            .. "Right-click the file → 'Copy Link' for cdn.discordapp.com/..."
    end
    local ok, data = pcall(game.HttpGet, game, url)
    if not ok then return false, "HTTP failed: " .. tostring(data) end
    if type(data) ~= "string" or #data == 0 then return false, "Empty response." end
    return true, data
end

--------------------------------------------------------------------------------
-- §14  DISCORD CDN HANDLER
--------------------------------------------------------------------------------
function DataReader:HandleDiscordURL(url)
    local lower = string_lower(url)
    if string_find(lower, "%.png") or string_find(lower, "%.jpg")
        or string_find(lower, "%.jpeg") or string_find(lower, "%.gif")
        or string_find(lower, "%.webp") then
        return false, "Direct image files cannot be parsed in-game. "
            .. "Convert to JSON pixel array first (e.g. img2pixel.com). "
            .. "Format: [[[r,g,b],[r,g,b],...],...]"
    end
    local ok, content = self:DownloadContent(url)
    if not ok then return false, content end
    return self:Parse(content)
end

--------------------------------------------------------------------------------
-- §15  MASTER PARSE FUNCTION
--------------------------------------------------------------------------------
function DataReader:Parse(source, options)
    options = options or {}
    if type(source) ~= "string" or #source == 0 then
        return false, "Input source is empty."
    end

    -- Global BOM strip
    local s = source
    if string_byte(s, 1) == 0xEF and string_byte(s, 2) == 0xBB and string_byte(s, 3) == 0xBF then
        s = string_sub(s, 4)
    end

    local fmt = self:DetectFormat(s)

    if fmt == "url" then
        local ok, content = self:DownloadContent(s)
        if not ok then return false, content end
        local pOk, result = self:Parse(content, options)
        if pOk and result.metadata then
            result.metadata.sourceType = "url"
            result.metadata.sourceURL  = s
        end
        return pOk, result
    end

    if fmt == "discord" then
        local pOk, result = self:HandleDiscordURL(s)
        if pOk and result.metadata then
            result.metadata.sourceType = "discord"
            result.metadata.sourceURL  = s
        end
        return pOk, result
    end

    if fmt == "json"      then return self:ParseJSON(s) end
    if fmt == "lua"       then return self:ParseLuaScript(s) end
    if fmt == "csv"       then return self:ParseCSV(s) end
    if fmt == "pixeldata" then
        return self:ParsePixelData(s,
            options.maxPixelWidth  or self.MaxPixelResolution,
            options.maxPixelHeight or self.MaxPixelResolution)
    end
    if fmt == "text"      then return self:ParseText(s) end

    return false, "Unable to detect input format."
end

--------------------------------------------------------------------------------
-- §16  BLUEPRINT INFO STRING
--------------------------------------------------------------------------------
function DataReader:GetBlueprintInfo(bp)
    if not bp or type(bp) ~= "table" then return "No blueprint data." end

    local count = bp.count or 0
    local sz    = bp.sizeBytes or 0
    local meta  = bp.metadata or {}

    -- Count unique colors
    local seen, uc = {}, 0
    if bp.colors then
        for i = 1, math_min(count, 500) do
            local c = bp.colors[i]
            if c and not seen[c] then seen[c] = true; uc = uc + 1 end
        end
    end

    -- Bounding box from CFrames
    local mx, my, mz = 0, 0, 0
    if bp.cframes then
        for i = 1, count do
            local p = bp.cframes[i].Position
            if p.X > mx then mx = p.X end
            if p.Y > my then my = p.Y end
            if p.Z > mz then mz = p.Z end
        end
    end

    local sStr = sz > 1024 and (math_floor(sz / 1024) .. " KB") or (sz .. " B")
    local parts = {
        "Fmt:" .. (meta.format or "?"),
        count .. " blocks",
        sStr,
        uc .. " colors",
        (mx+1) .. "×" .. (my+1) .. "×" .. (mz+1) .. " grid",
    }
    if meta.pixelWidth then
        table_insert(parts, meta.pixelWidth .. "×" .. meta.pixelHeight .. " px")
    end
    return table_concat(parts, " | ")
end

--------------------------------------------------------------------------------
-- §17  SCALE BLUEPRINT TO FIT AREA
--------------------------------------------------------------------------------
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

    -- Rebuild CFrames at new scale, deduplicating positions
    local seen = {}
    local newCF = {}
    local newCL = {}
    local newCount = 0

    for i = 1, bp.count do
        local p = bp.cframes[i].Position
        local gx = math_floor(p.X * scale + 0.5)
        local gy = math_floor(p.Y * scale + 0.5)
        local gz = math_floor(p.Z * scale + 0.5)
        local key = gx * 100000000 + gy * 10000 + gz  -- integer hash
        if not seen[key] then
            seen[key] = true
            newCount = newCount + 1
            newCF[newCount] = CFrame_new(gx, gy, gz)
            newCL[newCount] = bp.colors[i]
        end
    end

    bp.cframes = newCF
    bp.colors  = newCL
    bp.count   = newCount
    return bp
end

--------------------------------------------------------------------------------
-- MODULE EXPORT
--------------------------------------------------------------------------------
return DataReader
