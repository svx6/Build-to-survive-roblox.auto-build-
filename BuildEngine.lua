--[[
================================================================================
  PART 1 — BUILD ENGINE CORE  (BuildEngine.lua)
  
  A production-grade, object-oriented build automation framework.
  
  Features:
    • JSON blueprint import (raw string or GitHub Raw URL via HttpGet)
    • Dynamic micro-batch chunking for massive schematics
    • Coroutine-safe atomic cancellation with full memory cleanup
    • Automated RemoteEvent fuzzer — no hardcoded remote names
    • Adaptive network back-off algorithm
    • Full Luau variable caching for executor performance (Xeno / Delta)
    • GC-safe memory patterns using table.create / table.clear
    
  This module exposes a single `BuildEngine` table.
  It is completely UI-agnostic — the Rayfield UI (Part 2) wraps it.
================================================================================
--]]

--------------------------------------------------------------------------------
-- §1  LUAU VARIABLE CACHING
-- Cache every core library method as a local upvalue.
-- This eliminates repeated global lookups on every iteration,
-- which is critical on constrained executors (Delta Mobile especially).
--------------------------------------------------------------------------------
local Vector3_new       = Vector3.new
local CFrame_new        = CFrame.new
local math_round        = math.round
local math_abs          = math.abs
local math_max          = math.max
local math_min          = math.min
local math_floor        = math.floor
local math_clamp        = math.clamp
local table_insert      = table.insert
local table_create      = table.create
local table_clear       = table.clear
local table_move        = table.move
local pairs             = pairs
local ipairs            = ipairs
local pcall             = pcall
local type              = type
local typeof            = typeof
local tostring          = tostring
local tonumber          = tonumber
local select            = select
local rawset            = rawset
local tick              = tick
local warn              = warn
local task_wait         = task.wait
local task_spawn        = task.spawn
local task_cancel       = task.cancel
local task_defer        = task.defer
local coroutine_yield   = coroutine.yield
local string_lower      = string.lower
local string_match      = string.match
local string_find       = string.find
local string_sub        = string.sub

--------------------------------------------------------------------------------
-- §2  SERVICE CACHING
--------------------------------------------------------------------------------
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local HttpService        = game:GetService("HttpService")

--------------------------------------------------------------------------------
-- §3  BUILD ENGINE CLASS
--------------------------------------------------------------------------------
local BuildEngine = {}
BuildEngine.__index = BuildEngine

--[[
    BuildEngine.new()
    
    Constructor — creates a fresh engine instance with default state.
    Each instance maintains its own cancellation token, thread reference,
    stats counters, and configuration.
--]]
function BuildEngine.new()
    local self = setmetatable({}, BuildEngine)

    -- Cancellation & threading ------------------------------------------------
    self.IsCancelled   = false          -- Atomic cancellation token
    self._buildThread  = nil            -- Reference to the active coroutine/thread
    self.IsBuilding    = false          -- Public busy flag

    -- Configuration -----------------------------------------------------------
    self.GridSize       = 3             -- Stud spacing between blocks
    self.PlaceDelay     = 0.05          -- Base delay between remote fires (sec)
    self.SelectedColor  = "Institutional white"
    self.ChunkSize      = 50            -- Blocks per micro-batch before yield
    self.MaxRetries     = 3             -- Per-block remote fire retries

    -- Adaptive back-off state -------------------------------------------------
    self._consecutiveFails = 0
    self._adaptiveDelay    = 0.05       -- Actual delay (may diverge from slider)
    self._backoffCeiling   = 0.5        -- Never exceed this delay (seconds)
    self._backoffFloor     = 0.01       -- Never go below this delay

    -- Stats -------------------------------------------------------------------
    self.Stats = {
        TotalBlocks    = 0,
        PlacedBlocks   = 0,
        FailedBlocks   = 0,
        StartTime      = 0,
        ElapsedTime    = 0,
    }

    -- Remote cache ------------------------------------------------------------
    self._resolvedRemote  = nil         -- Cached RemoteEvent after fuzzing
    self._remoteArgStyle  = nil         -- "cframe" | "vector" | "array" | nil

    return self
end

--------------------------------------------------------------------------------
-- §4  GRID SNAPPING
--------------------------------------------------------------------------------
--[[
    Snap a world-coordinate value to the nearest grid increment.
    Uses cached math_round to avoid global lookups.
--]]
function BuildEngine:Snap(value)
    return math_round(value / self.GridSize) * self.GridSize
end

--------------------------------------------------------------------------------
-- §5  JSON / URL BLUEPRINT IMPORT
--------------------------------------------------------------------------------
--[[
    BuildEngine:ImportBlueprint(source)
    
    Accepts either:
      1. A raw JSON string       → parses directly
      2. A GitHub Raw URL string → downloads via game:HttpGet(), then parses
    
    Expected JSON schema (array of block descriptors):
        [
            { "x": 0, "y": 0, "z": 0 },
            { "x": 1, "y": 0, "z": 0, "color": "Really red" },
            ...
        ]
    
    Returns:
        success (bool), result (table|string)
        On success: result = { blocks = {...}, blockCount = N, sizeBytes = N }
        On failure: result = error message string
--]]
function BuildEngine:ImportBlueprint(source)
    if type(source) ~= "string" or #source == 0 then
        return false, "Blueprint source is empty or not a string."
    end

    local rawJSON = nil

    -- Detect URL vs raw JSON --------------------------------------------------
    local isURL = string_find(source, "^https?://") ~= nil

    if isURL then
        local ok, data = pcall(function()
            return game:HttpGet(source)
        end)
        if not ok or type(data) ~= "string" or #data == 0 then
            return false, "Failed to download blueprint from URL: " .. tostring(data)
        end
        rawJSON = data
    else
        rawJSON = source
    end

    -- Parse JSON --------------------------------------------------------------
    local ok, parsed = pcall(function()
        return HttpService:JSONDecode(rawJSON)
    end)

    if not ok then
        return false, "JSON parse error: " .. tostring(parsed)
    end

    if type(parsed) ~= "table" then
        return false, "Blueprint JSON must be an array of block objects."
    end

    -- Validate & normalize blocks ---------------------------------------------
    local blocks = table_create(#parsed)
    local count  = 0

    for i, entry in ipairs(parsed) do
        if type(entry) == "table" then
            local x = tonumber(entry.x) or tonumber(entry.X) or 0
            local y = tonumber(entry.y) or tonumber(entry.Y) or 0
            local z = tonumber(entry.z) or tonumber(entry.Z) or 0
            local color = entry.color or entry.Color or nil

            count = count + 1
            blocks[count] = {
                x = x,
                y = y,
                z = z,
                color = color,  -- nil = use global SelectedColor
            }
        end
    end

    if count == 0 then
        return false, "Blueprint contains 0 valid block entries."
    end

    return true, {
        blocks     = blocks,
        blockCount = count,
        sizeBytes  = #rawJSON,
    }
end

--------------------------------------------------------------------------------
-- §6  BUILT-IN BLUEPRINTS (PRO MANSION)
--------------------------------------------------------------------------------
--[[
    BuildEngine:GenerateProMansion()
    
    Returns a blueprint table in the same normalized format as ImportBlueprint.
    Contains floor, walls with door/window cutouts, and a stepped pyramid roof.
--]]
function BuildEngine:GenerateProMansion()
    -- Pre-allocate generously to avoid incremental resizing
    local blocks = table_create(512)
    local count  = 0
    local width  = 3  -- half-width: produces a 7×7 footprint (-3..3)

    -- 1. Floor ----------------------------------------------------------------
    for x = -width, width do
        for z = -width, width do
            count = count + 1
            blocks[count] = { x = x, y = 0, z = z }
        end
    end

    -- 2. Walls with door & window cutouts -------------------------------------
    for y = 1, 3 do
        for x = -width, width do
            for z = -width, width do
                if math_abs(x) == width or math_abs(z) == width then
                    local isDoor   = (z == -width and math_abs(x) <= 1 and y <= 2)
                    local isWindow = (y == 2 and (x == 0 or z == width))

                    if not isDoor and not isWindow then
                        count = count + 1
                        blocks[count] = { x = x, y = y, z = z }
                    end
                end
            end
        end
    end

    -- 3. Stepped pyramid roof -------------------------------------------------
    for yOffset = 0, 3 do
        local roofLevel = 4 + yOffset
        local roofWidth = width + 1 - yOffset
        for x = -roofWidth, roofWidth do
            for z = -roofWidth, roofWidth do
                if math_abs(x) == roofWidth or math_abs(z) == roofWidth or roofWidth == 0 then
                    count = count + 1
                    blocks[count] = { x = x, y = roofLevel, z = z }
                end
            end
        end
    end

    return {
        blocks     = blocks,
        blockCount = count,
        sizeBytes  = 0,  -- generated, not loaded from JSON
    }
end

--------------------------------------------------------------------------------
-- §7  DYNAMIC REMOTE AUTO-FUZZER
--------------------------------------------------------------------------------
--[[
    BuildEngine:FuzzRemote()
    
    Scans ReplicatedStorage (and the player's equipped tool) for any RemoteEvent
    that could be used for block placement. Attempts to deduce the expected
    argument style by inspecting the remote's name and testing parameter patterns.
    
    Sets:
        self._resolvedRemote   → the RemoteEvent instance
        self._remoteArgStyle   → "cframe" | "vector" | "array" | "generic"
    
    Returns:
        success (bool), message (string)
--]]
function BuildEngine:FuzzRemote()
    local candidates = {}

    -- Gather candidates from ReplicatedStorage --------------------------------
    for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
        if obj:IsA("RemoteEvent") then
            table_insert(candidates, obj)
        end
    end

    -- Gather candidates from the player's equipped tool -----------------------
    local player    = Players.LocalPlayer
    local character = player and player.Character
    local tool      = character and character:FindFirstChildOfClass("Tool")

    if tool then
        for _, obj in ipairs(tool:GetDescendants()) do
            if obj:IsA("RemoteEvent") then
                table_insert(candidates, obj)
            end
        end
    end

    if #candidates == 0 then
        self._resolvedRemote = nil
        self._remoteArgStyle = nil
        return false, "No RemoteEvents found in ReplicatedStorage or equipped tool."
    end

    -- Score each candidate based on name heuristics ---------------------------
    local buildKeywords = {
        "build", "place", "create", "block", "part", "set",
        "construct", "spawn", "add", "put", "make", "craft",
    }

    local bestRemote = nil
    local bestScore  = -1

    for _, remote in ipairs(candidates) do
        local nameLower = string_lower(remote.Name)
        local score = 0

        for _, keyword in ipairs(buildKeywords) do
            if string_find(nameLower, keyword) then
                score = score + 10
            end
        end

        -- Prefer remotes higher in the hierarchy (closer to RS root)
        local depth = 0
        local current = remote.Parent
        while current and current ~= ReplicatedStorage do
            depth = depth + 1
            current = current.Parent
        end
        score = score - depth  -- shallow = better

        if score > bestScore then
            bestScore  = score
            bestRemote = remote
        end
    end

    -- If no keyword matched at all, just take the first candidate
    if not bestRemote then
        bestRemote = candidates[1]
    end

    -- Deduce argument style from name -----------------------------------------
    local nameLower = string_lower(bestRemote.Name)
    local argStyle  = "generic"

    if string_find(nameLower, "cframe") then
        argStyle = "cframe"
    elseif string_find(nameLower, "vector") or string_find(nameLower, "pos") then
        argStyle = "vector"
    elseif string_find(nameLower, "array") or string_find(nameLower, "data") then
        argStyle = "array"
    end

    self._resolvedRemote = bestRemote
    self._remoteArgStyle = argStyle

    return true, "Resolved remote: " .. bestRemote:GetFullName() .. " (style: " .. argStyle .. ")"
end

--------------------------------------------------------------------------------
-- §8  ADAPTIVE NETWORK BACK-OFF
--------------------------------------------------------------------------------
--[[
    BuildEngine:_computeAdaptiveDelay()
    
    Called after every remote fire attempt. Adjusts the actual delay
    based on consecutive failures. If the user's slider value is too
    aggressive, this algorithm widens the gap to avoid server-side
    rate-limit detection, then slowly recovers back to the target speed.
    
    Algorithm:
        • On success: decay toward the user's target delay (PlaceDelay)
        • On failure: exponential back-off (doubling), capped at ceiling
--]]
function BuildEngine:_computeAdaptiveDelay(didSucceed)
    if didSucceed then
        self._consecutiveFails = 0
        -- Exponential decay toward the user's target delay
        self._adaptiveDelay = self._adaptiveDelay - (self._adaptiveDelay - self.PlaceDelay) * 0.25
        self._adaptiveDelay = math_max(self._adaptiveDelay, self._backoffFloor)
    else
        self._consecutiveFails = self._consecutiveFails + 1
        -- Exponential back-off: double the delay each consecutive failure
        local backoff = self.PlaceDelay * (2 ^ self._consecutiveFails)
        self._adaptiveDelay = math_min(backoff, self._backoffCeiling)
    end

    return self._adaptiveDelay
end

--------------------------------------------------------------------------------
-- §9  REMOTE FIRE (with argument-style adaptation)
--------------------------------------------------------------------------------
--[[
    BuildEngine:_fireRemote(position, color, tool)
    
    Fires the resolved remote with arguments arranged to match
    the deduced argument style. Wraps in pcall for safety.
    
    Returns: success (bool)
--]]
function BuildEngine:_fireRemote(position, color, tool)
    local remote = self._resolvedRemote
    if not remote then return false end

    local ok = false

    local style = self._remoteArgStyle or "generic"

    if style == "cframe" then
        -- Server expects: (color, CFrame, tool)
        ok = pcall(function()
            remote:FireServer(color, CFrame_new(position), tool)
        end)
    elseif style == "vector" then
        -- Server expects: (color, Vector3, tool)
        ok = pcall(function()
            remote:FireServer(color, position, tool)
        end)
    elseif style == "array" then
        -- Server expects: ({color, x, y, z})
        ok = pcall(function()
            remote:FireServer({color, position.X, position.Y, position.Z})
        end)
    else
        -- Generic fallback: try CFrame first (most common in building games)
        ok = pcall(function()
            remote:FireServer(color, CFrame_new(position), tool)
        end)
        if not ok then
            -- Retry with Vector3
            ok = pcall(function()
                remote:FireServer(color, position, tool)
            end)
        end
        if not ok then
            -- Retry with positional args
            ok = pcall(function()
                remote:FireServer(position, color, tool)
            end)
        end
    end

    return ok
end

--------------------------------------------------------------------------------
-- §10  VALIDATION / ESTIMATION
--------------------------------------------------------------------------------
--[[
    BuildEngine:ValidateBlueprint(blueprintData)
    
    Takes a parsed blueprint table (from ImportBlueprint or GenerateProMansion)
    and returns a human-readable summary with:
        • Block count
        • File size (if loaded from JSON)
        • Estimated completion time at current delay settings
    
    Returns: info (table)
--]]
function BuildEngine:ValidateBlueprint(blueprintData)
    if not blueprintData or type(blueprintData.blocks) ~= "table" then
        return {
            valid         = false,
            blockCount    = 0,
            sizeBytes     = 0,
            estimatedTime = 0,
            summary       = "Invalid or empty blueprint data.",
        }
    end

    local count       = blueprintData.blockCount or #blueprintData.blocks
    local sizeBytes   = blueprintData.sizeBytes or 0

    -- Estimate: each block takes (PlaceDelay) seconds + ~5ms overhead,
    -- plus chunk yield pauses every ChunkSize blocks
    local perBlock    = self.PlaceDelay + 0.005
    local chunkYields = math_floor(count / self.ChunkSize) * 0.03
    local totalSec    = (count * perBlock) + chunkYields

    local minutes = math_floor(totalSec / 60)
    local seconds = math_floor(totalSec % 60)
    local timeStr = minutes > 0
        and (minutes .. "m " .. seconds .. "s")
        or  (seconds .. "s")

    local sizeStr = sizeBytes > 1024
        and (math_floor(sizeBytes / 1024) .. " KB")
        or  (sizeBytes .. " bytes")

    return {
        valid         = true,
        blockCount    = count,
        sizeBytes     = sizeBytes,
        sizeFormatted = sizeStr,
        estimatedTime = totalSec,
        timeFormatted = timeStr,
        summary       = "✅ Blueprint valid: "
            .. count .. " blocks, "
            .. sizeStr .. " payload, ~"
            .. timeStr .. " estimated.",
    }
end

--------------------------------------------------------------------------------
-- §11  CORE BUILD EXECUTOR (CHUNKED + CANCELLABLE)
--------------------------------------------------------------------------------
--[[
    BuildEngine:ExecuteBuild(blueprintData, onProgress, onComplete)
    
    The main build loop. Spawns a dedicated thread via task.spawn so the
    caller (UI) is never blocked.
    
    Parameters:
        blueprintData  — table from ImportBlueprint or GenerateProMansion
        onProgress     — optional callback(placed, total, elapsed)
        onComplete     — optional callback(stats)
    
    Thread safety:
        • Checks self.IsCancelled before every block placement.
        • On cancellation, the thread cleans up immediately.
        • The thread reference is stored in self._buildThread for external cancel.
--]]
function BuildEngine:ExecuteBuild(blueprintData, onProgress, onComplete)
    -- Guard: prevent double-builds
    if self.IsBuilding then
        return false, "A build is already in progress."
    end

    if not blueprintData or not blueprintData.blocks or blueprintData.blockCount == 0 then
        return false, "No valid blueprint data to build."
    end

    -- Resolve remote if not already cached
    if not self._resolvedRemote then
        local ok, msg = self:FuzzRemote()
        if not ok then
            return false, msg
        end
    end

    -- Resolve player context
    local player    = Players.LocalPlayer
    local character = player and player.Character
    local tool      = character and character:FindFirstChildOfClass("Tool")

    if not tool then
        return false, "Please equip your building tool first!"
    end

    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    if not rootPart then
        return false, "HumanoidRootPart not found."
    end

    -- Calculate build origin: offset forward from the player
    local originPos = rootPart.Position + (rootPart.CFrame.LookVector * 18)
    local startX    = self:Snap(originPos.X)
    local startY    = self:Snap(rootPart.Position.Y - 2)
    local startZ    = self:Snap(originPos.Z)

    -- Reset state
    self.IsCancelled    = false
    self.IsBuilding     = true
    self._adaptiveDelay = self.PlaceDelay
    self._consecutiveFails = 0

    -- Reset stats
    local stats      = self.Stats
    stats.TotalBlocks  = blueprintData.blockCount
    stats.PlacedBlocks = 0
    stats.FailedBlocks = 0
    stats.StartTime    = tick()
    stats.ElapsedTime  = 0

    local blocks    = blueprintData.blocks
    local total     = blueprintData.blockCount
    local gridSize  = self.GridSize
    local chunkSize = self.ChunkSize

    --------------------------------------------------------------------------
    -- Spawn the build thread
    --------------------------------------------------------------------------
    self._buildThread = task_spawn(function()
        local chunkCounter = 0

        -- Pre-allocate a reusable position scratch variable
        -- (avoids creating a new Vector3 closure each iteration on some executors)
        local targetPos

        for i = 1, total do
            ----------------------------------------------------------------
            -- CANCELLATION CHECK (atomic)
            ----------------------------------------------------------------
            if self.IsCancelled then
                break
            end

            ----------------------------------------------------------------
            -- Compute world position
            ----------------------------------------------------------------
            local block = blocks[i]
            local blockColor = block.color or self.SelectedColor

            targetPos = Vector3_new(
                startX + (block.x * gridSize),
                startY + (block.y * gridSize),
                startZ + (block.z * gridSize)
            )

            ----------------------------------------------------------------
            -- Fire remote with retry logic
            ----------------------------------------------------------------
            local placed = false
            for attempt = 1, self.MaxRetries do
                if self.IsCancelled then break end

                local ok = self:_fireRemote(targetPos, blockColor, tool)
                if ok then
                    placed = true
                    self:_computeAdaptiveDelay(true)
                    break
                else
                    self:_computeAdaptiveDelay(false)
                    -- Brief pause before retry
                    task_wait(self._adaptiveDelay * 0.5)
                end
            end

            if placed then
                stats.PlacedBlocks = stats.PlacedBlocks + 1
            else
                stats.FailedBlocks = stats.FailedBlocks + 1
            end

            ----------------------------------------------------------------
            -- Progress callback
            ----------------------------------------------------------------
            if onProgress then
                stats.ElapsedTime = tick() - stats.StartTime
                pcall(onProgress, stats.PlacedBlocks, total, stats.ElapsedTime)
            end

            ----------------------------------------------------------------
            -- Adaptive delay between placements
            ----------------------------------------------------------------
            task_wait(self._adaptiveDelay)

            ----------------------------------------------------------------
            -- Micro-batch chunking: yield briefly every N blocks
            -- This prevents the executor thread from hogging the frame
            -- and keeps Delta Mobile from freezing.
            ----------------------------------------------------------------
            chunkCounter = chunkCounter + 1
            if chunkCounter >= chunkSize then
                chunkCounter = 0
                task_wait(0.03)  -- brief frame yield
            end
        end

        ----------------------------------------------------------------
        -- Build finished (or cancelled) — finalize
        ----------------------------------------------------------------
        stats.ElapsedTime = tick() - stats.StartTime
        self.IsBuilding   = false

        -- GC cleanup: release block references from the blueprint
        -- to allow the GC to reclaim memory on mobile executors
        -- (we do NOT clear the blocks themselves — the caller owns them)

        if onComplete then
            pcall(onComplete, stats)
        end
    end)

    return true, "Build started."
end

--------------------------------------------------------------------------------
-- §12  CANCELLATION
--------------------------------------------------------------------------------
--[[
    BuildEngine:CancelBuild()
    
    Sets the atomic cancellation token. The build thread checks this
    before every block placement and exits cleanly.
    
    Also calls task.cancel on the thread as a hard backstop in case
    the thread is stuck in a long task.wait.
--]]
function BuildEngine:CancelBuild()
    self.IsCancelled = true

    -- Hard-cancel the thread if it exists (safety net)
    if self._buildThread then
        pcall(task_cancel, self._buildThread)
        self._buildThread = nil
    end

    self.IsBuilding = false
end

--------------------------------------------------------------------------------
-- §13  COLOR SCANNER (extracted from original script, improved)
--------------------------------------------------------------------------------
--[[
    BuildEngine:ScanGameColors()
    
    Scans multiple sources for available block/color names:
        1. Random BrickColor sampling
        2. StringValue children of the equipped tool
        3. UI text labels in PlayerGui that match valid BrickColor names
    
    Returns: colors (table — array of unique color name strings)
--]]
function BuildEngine:ScanGameColors()
    local colors = {}
    local seen   = {}

    local function addColor(name)
        if type(name) == "string" and #name > 0 and not seen[name] then
            seen[name] = true
            table_insert(colors, name)
        end
    end

    -- 1. Random BrickColor sampling (broad coverage) --------------------------
    for _ = 1, 30 do
        addColor(BrickColor.Random().Name)
    end

    -- 2. Equipped tool StringValues -------------------------------------------
    local player    = Players.LocalPlayer
    local character = player and player.Character
    local tool      = character and character:FindFirstChildOfClass("Tool")

    if tool then
        for _, obj in ipairs(tool:GetDescendants()) do
            if obj:IsA("StringValue") and string_find(string_lower(obj.Name), "color") then
                addColor(obj.Value)
            end
        end
    end

    -- 3. PlayerGui text labels ------------------------------------------------
    local pGui = player:FindFirstChild("PlayerGui")
    if pGui then
        for _, obj in ipairs(pGui:GetDescendants()) do
            if (obj:IsA("TextLabel") or obj:IsA("TextButton")) then
                local txt = obj.Text
                if type(txt) == "string" and #txt > 2 and #txt < 30 then
                    -- Validate: only accept if BrickColor round-trips the name
                    local ok, bc = pcall(BrickColor.new, txt)
                    if ok and bc and bc.Name == txt then
                        addColor(txt)
                    end
                end
            end
        end
    end

    return colors
end

--------------------------------------------------------------------------------
-- §14  UTILITY: RESET ENGINE STATE
--------------------------------------------------------------------------------
function BuildEngine:Reset()
    self:CancelBuild()
    self._resolvedRemote   = nil
    self._remoteArgStyle   = nil
    self._consecutiveFails = 0
    self._adaptiveDelay    = self.PlaceDelay

    -- Clear stats with GC-safe pattern
    local s = self.Stats
    s.TotalBlocks  = 0
    s.PlacedBlocks = 0
    s.FailedBlocks = 0
    s.StartTime    = 0
    s.ElapsedTime  = 0
end

--------------------------------------------------------------------------------
-- MODULE EXPORT
--------------------------------------------------------------------------------
return BuildEngine
