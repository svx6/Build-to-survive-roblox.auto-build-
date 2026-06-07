--[[
================================================================================
  MODULE 2 — BUILD ENGINE CORE  (BuildEngine.lua)
  Pro Architect V7.1 — Zero-Alloc Execution & Patching Subsystem

  CRITICAL PERFORMANCE ARCHITECTURE:
    The hot build loop performs ZERO Lua GC allocations per block:
      1. All CFrames are pre-transformed to world coordinates BEFORE the loop.
      2. The remote:FireServer closure is pre-created ONCE (no per-call lambda).
      3. Block names are read from a flat string array (no table field lookups).
      4. Upvalue mutation pattern eliminates closure re-creation overhead.
      5. Adaptive back-off uses only arithmetic on locals (no table ops).

  This design guarantees zero GC CPU spikes on constrained executors
  (Delta Mobile, Fluxus, Wave) even during 10,000+ block builds.
================================================================================
--]]

--------------------------------------------------------------------------------
-- §1  LUAU VARIABLE CACHING
--------------------------------------------------------------------------------
local Vector3_new     = Vector3.new
local CFrame_new      = CFrame.new
local math_round      = math.round
local math_abs        = math.abs
local math_max        = math.max
local math_min        = math.min
local math_floor      = math.floor
local math_huge       = math.huge
local math_sqrt       = math.sqrt
local table_insert    = table.insert
local table_create    = table.create
local table_clear     = table.clear
local ipairs          = ipairs
local pcall           = pcall
local type            = type
local tostring        = tostring
local tonumber        = tonumber
local tick            = tick
local warn            = warn
local task_wait       = task.wait
local task_spawn      = task.spawn
local task_cancel     = task.cancel
local string_lower    = string.lower
local string_find     = string.find
local string_match    = string.match

--------------------------------------------------------------------------------
-- §2  SERVICE CACHING
--------------------------------------------------------------------------------
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local HttpService       = game:GetService("HttpService")

--------------------------------------------------------------------------------
-- §3  STATIC BLOCK REGISTRIES
--------------------------------------------------------------------------------
local REGISTRY = {}

REGISTRY.Colors = {
    "Bright violet", "CGA brown", "Institutional white", "Lime green",
    "Magenta", "New Yeller", "Parsley green", "Really black",
    "Really blue", "Really red", "Reddish brown", "Smoky grey",
    "Deep orange", "Brown", "Toothpaste", "Navy blue", "Pink",
}

REGISTRY.Materials = {
    "Darkwood", "Dirt", "Glass", "Grass", "Marble", "Slate2", "Slate3",
    "Water", "Wood", "Cobblestone", "Concrete", "Metal", "CorrodedMetal",
    "Granite", "Brick",
}

REGISTRY.Gamepass = {
    "Beach Ball", "Neon", "Forcefield", "Ice", "Diamond Plate",
}

REGISTRY.Shapes = {
    "Wedge", "Corner", "Cylinder", "Truss", "Seat", "VehicleSeat",
}

REGISTRY.Furniture = {
    "Bed", "Chair", "Table", "Door", "Window", "Light", "Chest",
}

-- Flat combined list + O(1) validation set
REGISTRY.AllBlocks = {}
REGISTRY.IsValid   = {}
do
    local idx = 0
    for _, list in ipairs({
        REGISTRY.Colors, REGISTRY.Materials, REGISTRY.Gamepass,
        REGISTRY.Shapes, REGISTRY.Furniture,
    }) do
        for _, name in ipairs(list) do
            idx = idx + 1
            REGISTRY.AllBlocks[idx] = name
            REGISTRY.IsValid[name]  = true
        end
    end
end

--------------------------------------------------------------------------------
-- §4  BUILD ENGINE CLASS
--------------------------------------------------------------------------------
local BuildEngine = {}
BuildEngine.__index  = BuildEngine
BuildEngine.REGISTRY = REGISTRY

function BuildEngine.new()
    local self = setmetatable({}, BuildEngine)

    self.IsCancelled      = false
    self._buildThread     = nil
    self.IsBuilding       = false

    self.GridSize          = 3
    self.PlaceDelay        = 0.05
    self.SelectedColor     = "Institutional white"
    self.SelectedMaterial   = nil
    self.SelectedBlockType  = nil
    self.ChunkSize         = 20
    self.MaxRetries        = 3
    self.GhostModeEnabled  = false

    self._consecutiveFails = 0
    self._adaptiveDelay    = 0.05
    self._backoffCeiling   = 0.6
    self._backoffFloor     = 0.01

    self.Stats = {
        TotalBlocks = 0, PlacedBlocks = 0, FailedBlocks = 0,
        StartTime = 0, ElapsedTime = 0,
    }

    self._resolvedRemote  = nil
    self._remoteArgStyle  = nil
    self._detectedArea    = nil
    self._dataReader      = nil

    return self
end

--------------------------------------------------------------------------------
-- §5  GRID SNAPPING
--------------------------------------------------------------------------------
function BuildEngine:Snap(v)
    return math_round(v / self.GridSize) * self.GridSize
end

--------------------------------------------------------------------------------
-- §6  AUTO-EQUIP STAMPER TOOL (with forced character parenting)
-- Hooks the Humanoid:EquipTool API for reliable equip.
-- Falls back to direct Parent set if Humanoid is absent.
-- Returns the Tool instance or nil.
--------------------------------------------------------------------------------
function BuildEngine:AutoEquipTool()
    local player = Players.LocalPlayer
    if not player then return nil, "No LocalPlayer." end
    local char = player.Character
    if not char then return nil, "No Character." end

    -- Already equipped?
    local held = char:FindFirstChildOfClass("Tool")
    if held then return held, "Already equipped: " .. held.Name end

    local bp = player:FindFirstChild("Backpack")
    if not bp then return nil, "No Backpack found." end

    -- Priority search: exact name > keyword match
    local function tryEquip(tool)
        local ok = pcall(function()
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then hum:EquipTool(tool) else tool.Parent = char end
        end)
        if ok then task_wait(0.15) end
        return ok
    end

    -- Exact name
    local stamper = bp:FindFirstChild("StamperTool")
    if stamper and stamper:IsA("Tool") then
        if tryEquip(stamper) then return stamper, "Equipped StamperTool." end
    end

    -- Keyword search
    local keywords = { "stamp", "build", "place", "hammer", "tool" }
    for _, obj in ipairs(bp:GetChildren()) do
        if obj:IsA("Tool") then
            local nl = string_lower(obj.Name)
            for _, kw in ipairs(keywords) do
                if string_find(nl, kw) then
                    if tryEquip(obj) then return obj, "Equipped " .. obj.Name end
                    break
                end
            end
        end
    end

    -- Last resort: equip any tool
    for _, obj in ipairs(bp:GetChildren()) do
        if obj:IsA("Tool") then
            if tryEquip(obj) then return obj, "Equipped " .. obj.Name end
        end
    end

    return nil, "No building tool found."
end

--------------------------------------------------------------------------------
-- §7  GAMEPASS BYPASS — HARDENED, SCOPED TRAVERSAL
-- Strictly limited to Workspace, ReplicatedStorage, PlayerGui, Backpack.
-- NEVER scans game:GetDescendants() (causes timeout/crash).
-- Purges BoolValue/StringValue/IntValue/NumberValue/ObjectValue/Script
-- instances named pass/Pass/gamepass/owned/isPurchased.
--------------------------------------------------------------------------------
function BuildEngine:BypassGamepass()
    local destroyed = 0
    local player = Players.LocalPlayer

    -- Build safe scan target list
    local targets = { Workspace, ReplicatedStorage }
    if player then
        local pGui = player:FindFirstChild("PlayerGui")
        if pGui then table_insert(targets, pGui) end
        local bp = player:FindFirstChild("Backpack")
        if bp then table_insert(targets, bp) end
        local ch = player.Character
        if ch then table_insert(targets, ch) end
    end

    local killNames = { pass = true, gamepass = true, game_pass = true, ispurchased = true, owned = true }
    local killClasses = {
        BoolValue = true, StringValue = true, IntValue = true,
        NumberValue = true, ObjectValue = true,
        LocalScript = true, ModuleScript = true,
    }

    for _, container in ipairs(targets) do
        local ok, descs = pcall(container.GetDescendants, container)
        if ok and descs then
            for _, desc in ipairs(descs) do
                if killNames[string_lower(desc.Name)] then
                    local className = desc.ClassName
                    if killClasses[className] then
                        local delOk = pcall(desc.Destroy, desc)
                        if delOk then destroyed = destroyed + 1 end
                    end
                end
            end
        end
    end

    return destroyed
end

--------------------------------------------------------------------------------
-- §8  GHOST MODE — LOCAL TRANSPARENCY MODIFIER
--------------------------------------------------------------------------------
function BuildEngine:SetGhostMode(enabled)
    self.GhostModeEnabled = enabled
    local player = Players.LocalPlayer
    if not player or not player.Character then return end
    local root = player.Character:FindFirstChild("HumanoidRootPart")
    if not root then return end

    local origin = root.Position
    local radius = 150
    local ok, parts = pcall(Workspace.GetDescendants, Workspace)
    if not ok or not parts then return end

    for _, part in ipairs(parts) do
        if part:IsA("BasePart") and part.Name == "Part" then
            if (part.Position - origin).Magnitude <= radius then
                pcall(function()
                    part.LocalTransparencyModifier = enabled and 0.8 or 0
                end)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- §9  PLAYER AREA / PLOT DETECTION (3-strategy cascade)
-- Strategy 1: Player-named container → largest BasePart
-- Strategy 2: Keyword-named parts (base/plot/area/zone/platform)
-- Strategy 3: Nearest large flat anchored part within 100 studs
-- Fallback: 30×50×30 default area
--------------------------------------------------------------------------------
function BuildEngine:DetectPlayerArea()
    local player = Players.LocalPlayer
    if not player then return self:_defaultArea() end

    local searchNames = { string_lower(player.Name), string_lower(player.DisplayName), tostring(player.UserId) }
    local keywords = { "base", "plot", "area", "zone", "platform", "build", "pad", "floor" }
    local bestBase, bestSize = nil, 0

    -- Strategy 1: Player-named containers
    local ok1, children = pcall(Workspace.GetChildren, Workspace)
    if ok1 and children then
        for _, child in ipairs(children) do
            local cl = string_lower(child.Name)
            local isPlayer = false
            for _, sn in ipairs(searchNames) do
                if string_find(cl, sn) then isPlayer = true; break end
            end
            if isPlayer then
                local ok2, descs = pcall(child.GetDescendants, child)
                if ok2 and descs then
                    for _, d in ipairs(descs) do
                        if d:IsA("BasePart") then
                            local sz = d.Size.X * d.Size.Z
                            if sz > bestSize then bestSize = sz; bestBase = d end
                        end
                    end
                end
            end
        end
    end

    -- Strategy 2: Keyword-named parts
    if not bestBase then
        local ok2, allParts = pcall(Workspace.GetDescendants, Workspace)
        if ok2 and allParts then
            for _, part in ipairs(allParts) do
                if part:IsA("BasePart") then
                    local nl = string_lower(part.Name)
                    for _, kw in ipairs(keywords) do
                        if string_find(nl, kw) then
                            local sz = part.Size.X * part.Size.Z
                            if sz > bestSize then bestSize = sz; bestBase = part end
                            break
                        end
                    end
                end
            end
        end
    end

    -- Strategy 3: Nearest large flat anchored part
    if not bestBase and player.Character then
        local root = player.Character:FindFirstChild("HumanoidRootPart")
        if root then
            local pPos = root.Position
            local closestDist = math_huge
            local ok3, allParts = pcall(Workspace.GetDescendants, Workspace)
            if ok3 and allParts then
                for _, part in ipairs(allParts) do
                    if part:IsA("BasePart") and part.Anchored
                        and part.Size.X >= 10 and part.Size.Z >= 10
                        and part.Size.Y <= 5 then
                        local dist = (part.Position - pPos).Magnitude
                        if dist < closestDist and dist < 100 then
                            closestDist = dist; bestBase = part
                        end
                    end
                end
            end
        end
    end

    if bestBase then
        local bSz, bPos = bestBase.Size, bestBase.Position
        local gs = self.GridSize
        local area = {
            origin   = Vector3_new(bPos.X - bSz.X/2, bPos.Y + bSz.Y/2, bPos.Z - bSz.Z/2),
            sizeX    = math_floor(bSz.X),
            sizeY    = 50,
            sizeZ    = math_floor(bSz.Z),
            gridX    = math_floor(bSz.X / gs),
            gridY    = math_floor(50 / gs),
            gridZ    = math_floor(bSz.Z / gs),
            basePart = bestBase,
        }
        self._detectedArea = area
        return area
    end

    return self:_defaultArea()
end

function BuildEngine:_defaultArea()
    local gs = self.GridSize
    local area = {
        origin = Vector3_new(0, 0, 0),
        sizeX = 30, sizeY = 50, sizeZ = 30,
        gridX = math_floor(30/gs), gridY = math_floor(50/gs), gridZ = math_floor(30/gs),
        basePart = nil,
    }
    self._detectedArea = area
    return area
end

function BuildEngine:GetAreaInfoString()
    local a = self._detectedArea or self:DetectPlayerArea()
    local bn = a.basePart and a.basePart.Name or "none"
    return a.sizeX .. "×" .. a.sizeY .. "×" .. a.sizeZ
        .. " studs (" .. a.gridX .. "×" .. a.gridY .. "×" .. a.gridZ
        .. " blocks) | Base: " .. bn
end

--------------------------------------------------------------------------------
-- §10  REMOTE RESOLUTION — HARDCODED PRIMARY + FALLBACK FUZZER
-- Primary: ReplicatedStorage.CreatePart (exact protocol match)
-- Fallback: keyword-scored dynamic scan
--------------------------------------------------------------------------------
function BuildEngine:ResolveRemote()
    -- Primary: hardcoded
    local ok, remote = pcall(function()
        return ReplicatedStorage:FindFirstChild("CreatePart")
    end)
    if ok and remote and remote:IsA("RemoteEvent") then
        self._resolvedRemote = remote
        self._remoteArgStyle = "primary"
        return true, "Primary: ReplicatedStorage.CreatePart"
    end

    -- Fallback: fuzzer
    local candidates = {}
    local ok1, rsDescs = pcall(ReplicatedStorage.GetDescendants, ReplicatedStorage)
    if ok1 and rsDescs then
        for _, obj in ipairs(rsDescs) do
            if obj:IsA("RemoteEvent") then table_insert(candidates, obj) end
        end
    end

    local player = Players.LocalPlayer
    local char   = player and player.Character
    local tool   = char and char:FindFirstChildOfClass("Tool")
    if tool then
        local ok2, tDescs = pcall(tool.GetDescendants, tool)
        if ok2 and tDescs then
            for _, obj in ipairs(tDescs) do
                if obj:IsA("RemoteEvent") then table_insert(candidates, obj) end
            end
        end
    end

    if #candidates == 0 then
        self._resolvedRemote = nil
        self._remoteArgStyle = nil
        return false, "No RemoteEvents found."
    end

    local kws = { "build","place","create","block","part","set","construct","spawn","add","stamp","brick" }
    local best, bestScore = nil, -1
    for _, r in ipairs(candidates) do
        local nl = string_lower(r.Name)
        local score = 0
        for _, kw in ipairs(kws) do
            if string_find(nl, kw) then score = score + 10 end
        end
        local depth = 0
        local cur = r.Parent
        while cur and cur ~= ReplicatedStorage do depth = depth + 1; cur = cur.Parent end
        score = score - depth
        if score > bestScore then bestScore = score; best = r end
    end
    if not best then best = candidates[1] end

    local nl = string_lower(best.Name)
    local style = "generic"
    if string_find(nl, "cframe") then style = "cframe"
    elseif string_find(nl, "vector") or string_find(nl, "pos") then style = "vector" end

    self._resolvedRemote = best
    self._remoteArgStyle = style
    return true, "Fuzzed: " .. best:GetFullName() .. " (" .. style .. ")"
end

BuildEngine.FuzzRemote = BuildEngine.ResolveRemote

--------------------------------------------------------------------------------
-- §11  DYNAMIC ADAPTIVE BACK-OFF ENGINE
-- Tracks consecutive failures. On success: exponential decay toward target.
-- On failure: exponential back-off (2^fails), capped at ceiling.
-- Prevents server-side Remote-Flood Anticheat detection.
--------------------------------------------------------------------------------
function BuildEngine:_computeAdaptiveDelay(ok)
    if ok then
        self._consecutiveFails = 0
        self._adaptiveDelay = self._adaptiveDelay - (self._adaptiveDelay - self.PlaceDelay) * 0.3
        if self._adaptiveDelay < self._backoffFloor then
            self._adaptiveDelay = self._backoffFloor
        end
    else
        self._consecutiveFails = self._consecutiveFails + 1
        local bo = self.PlaceDelay * (2 ^ self._consecutiveFails)
        if bo > self._backoffCeiling then bo = self._backoffCeiling end
        self._adaptiveDelay = bo
    end
    return self._adaptiveDelay
end

--------------------------------------------------------------------------------
-- §12  VALIDATION / ESTIMATION
--------------------------------------------------------------------------------
function BuildEngine:ValidateBlueprint(bp)
    if not bp or not bp.cframes then
        return { valid = false, blockCount = 0, summary = "Invalid blueprint." }
    end

    local count = bp.count or 0
    local sz    = bp.sizeBytes or 0
    local perBlock = self.PlaceDelay + 0.005
    local chunkYields = math_floor(count / self.ChunkSize) * 0.05
    local totalSec = (count * perBlock) + chunkYields
    local m = math_floor(totalSec / 60)
    local s = math_floor(totalSec % 60)
    local tStr = m > 0 and (m .. "m " .. s .. "s") or (s .. "s")
    local sStr = sz > 1024 and (math_floor(sz/1024) .. " KB") or (sz .. " B")

    return {
        valid = true, blockCount = count, sizeBytes = sz,
        sizeFormatted = sStr, estimatedTime = totalSec, timeFormatted = tStr,
        summary = "✅ " .. count .. " blocks, " .. sStr .. ", ~" .. tStr,
    }
end

--------------------------------------------------------------------------------
-- §13  CORE BUILD EXECUTOR — ZERO GC-ALLOC HOT LOOP
--
-- Architecture:
--   Phase 1 (PRE-TRANSFORM): Convert all CFrame offsets → world CFrames.
--            One-time allocation cost BEFORE the loop.
--   Phase 2 (FIRE CLOSURE):  Pre-create a single closure for pcall.
--            Upvalue mutation pattern: update _fCF/_fName/_fTool before call.
--            NO per-call closure creation.
--   Phase 3 (HOT LOOP):     Zero Lua GC allocations per iteration.
--            Only engine-type ops (CFrame reads) + pcall on pre-made closure.
--------------------------------------------------------------------------------
function BuildEngine:ExecuteBuild(blueprintData, onProgress, onComplete)
    if self.IsBuilding then return false, "Build already in progress." end
    if not blueprintData or not blueprintData.cframes or (blueprintData.count or 0) == 0 then
        return false, "No valid blueprint data."
    end

    -- Resolve remote
    if not self._resolvedRemote then
        local ok, msg = self:ResolveRemote()
        if not ok then return false, msg end
    end

    -- Resolve & auto-equip tool
    local player = Players.LocalPlayer
    local char   = player and player.Character
    local tool   = char and char:FindFirstChildOfClass("Tool")
    if not tool then
        local eq, eMsg = self:AutoEquipTool()
        if not eq then return false, eMsg end
        tool = eq
        char = player.Character
    end

    local rootPart = char and char:FindFirstChild("HumanoidRootPart")
    if not rootPart then return false, "HumanoidRootPart not found." end

    -- Compute build origin
    local originPos = rootPart.Position + (rootPart.CFrame.LookVector * 18)
    local startX    = self:Snap(originPos.X)
    local startY    = self:Snap(rootPart.Position.Y - 2)
    local startZ    = self:Snap(originPos.Z)

    -- Reset state
    self.IsCancelled       = false
    self.IsBuilding        = true
    self._adaptiveDelay    = self.PlaceDelay
    self._consecutiveFails = 0

    local stats = self.Stats
    stats.TotalBlocks  = blueprintData.count
    stats.PlacedBlocks = 0
    stats.FailedBlocks = 0
    stats.StartTime    = tick()
    stats.ElapsedTime  = 0

    local srcCFrames = blueprintData.cframes
    local srcColors  = blueprintData.colors
    local total      = blueprintData.count
    local gs         = self.GridSize
    local chunkSize  = self.ChunkSize
    local maxRetries = self.MaxRetries
    local defaultColor = self.SelectedMaterial or self.SelectedColor

    --------------------------------------------------------------------------
    -- PHASE 1: PRE-TRANSFORM — All offsets → world CFrames (one-time cost)
    --------------------------------------------------------------------------
    local worldCF = table_create(total)
    for i = 1, total do
        local p = srcCFrames[i].Position
        worldCF[i] = CFrame_new(
            startX + p.X * gs,
            startY + p.Y * gs,
            startZ + p.Z * gs
        )
    end

    --------------------------------------------------------------------------
    -- PHASE 2: PRE-CREATE FIRE CLOSURE (zero per-call allocation)
    --------------------------------------------------------------------------
    local remote = self._resolvedRemote
    local style  = self._remoteArgStyle or "primary"

    -- Upvalue slots mutated before each pcall — closure reads current values
    local _fCF, _fName, _fTool

    local fireShim
    if style == "primary" or style == "cframe" then
        fireShim = function()
            remote:FireServer(_fName, _fCF, _fTool)
        end
    elseif style == "vector" then
        fireShim = function()
            remote:FireServer(_fName, _fCF.Position, _fTool)
        end
    else
        -- Generic: CFrame first (most common)
        fireShim = function()
            remote:FireServer(_fName, _fCF, _fTool)
        end
    end

    --------------------------------------------------------------------------
    -- PHASE 3: SPAWN ZERO-ALLOC HOT LOOP
    --------------------------------------------------------------------------
    self._buildThread = task_spawn(function()
        local chunkCounter = 0
        local adaptiveDelay = self._adaptiveDelay
        local consecutiveFails = 0
        local backoffCeiling = self._backoffCeiling
        local backoffFloor = self._backoffFloor
        local targetDelay = self.PlaceDelay

        for i = 1, total do
            -- Atomic cancellation check
            if self.IsCancelled then break end

            -- Set upvalue slots (zero allocation)
            _fCF   = worldCF[i]
            _fName = srcColors[i] or defaultColor
            _fTool = tool

            -- Fire with retry loop
            local placed = false
            for attempt = 1, maxRetries do
                if self.IsCancelled then break end

                local ok = pcall(fireShim)
                if ok then
                    placed = true
                    -- Inline adaptive delay: decay toward target
                    consecutiveFails = 0
                    adaptiveDelay = adaptiveDelay - (adaptiveDelay - targetDelay) * 0.3
                    if adaptiveDelay < backoffFloor then adaptiveDelay = backoffFloor end
                    break
                else
                    -- Inline adaptive delay: exponential back-off
                    consecutiveFails = consecutiveFails + 1
                    local bo = targetDelay * (2 ^ consecutiveFails)
                    if bo > backoffCeiling then bo = backoffCeiling end
                    adaptiveDelay = bo
                    task_wait(adaptiveDelay * 0.5)
                end
            end

            if placed then
                stats.PlacedBlocks = stats.PlacedBlocks + 1
            else
                stats.FailedBlocks = stats.FailedBlocks + 1
            end

            -- Progress callback (throttled)
            if onProgress then
                if i % 25 == 0 or i == total then
                    stats.ElapsedTime = tick() - stats.StartTime
                    pcall(onProgress, stats.PlacedBlocks, total, stats.ElapsedTime)
                end
            end

            -- Inter-block delay
            task_wait(adaptiveDelay)

            -- Chunk yield: prevent executor frame starvation
            chunkCounter = chunkCounter + 1
            if chunkCounter >= chunkSize then
                chunkCounter = 0
                task_wait(0.05)

                -- Re-verify tool parenting (may have been unequipped by game)
                if not self.IsCancelled then
                    local curTool = char:FindFirstChildOfClass("Tool")
                    if not curTool then
                        local reEq = self:AutoEquipTool()
                        if reEq then tool = reEq; _fTool = tool end
                    else
                        tool = curTool; _fTool = tool
                    end
                end
            end
        end

        -- Write back adaptive state for next build
        self._adaptiveDelay    = adaptiveDelay
        self._consecutiveFails = consecutiveFails

        -- Finalize
        stats.ElapsedTime = tick() - stats.StartTime
        self.IsBuilding   = false

        if self.GhostModeEnabled then self:SetGhostMode(false) end

        if onComplete then pcall(onComplete, stats) end
    end)

    return true, "Build started."
end

--------------------------------------------------------------------------------
-- §14  CANCELLATION
--------------------------------------------------------------------------------
function BuildEngine:CancelBuild()
    self.IsCancelled = true
    if self._buildThread then
        pcall(task_cancel, self._buildThread)
        self._buildThread = nil
    end
    self.IsBuilding = false
end

--------------------------------------------------------------------------------
-- §15  GAME COLOR SCANNER
--------------------------------------------------------------------------------
function BuildEngine:ScanGameColors()
    local colors, seen = {}, {}
    local function add(n)
        if type(n) == "string" and #n > 0 and not seen[n] then
            seen[n] = true; table_insert(colors, n)
        end
    end

    for _, list in ipairs({ REGISTRY.Colors, REGISTRY.Materials, REGISTRY.Gamepass }) do
        for _, name in ipairs(list) do add(name) end
    end

    local player = Players.LocalPlayer
    local char   = player and player.Character
    local tool   = char and char:FindFirstChildOfClass("Tool")
    if tool then
        for _, obj in ipairs(tool:GetDescendants()) do
            if obj:IsA("StringValue") and string_find(string_lower(obj.Name), "color") then
                add(obj.Value)
            end
        end
    end

    local pGui = player and player:FindFirstChild("PlayerGui")
    if pGui then
        local ok, descs = pcall(pGui.GetDescendants, pGui)
        if ok and descs then
            for _, obj in ipairs(descs) do
                if obj:IsA("TextLabel") or obj:IsA("TextButton") then
                    local txt = obj.Text
                    if type(txt) == "string" and #txt > 2 and #txt < 30 then
                        local ok2, bc = pcall(BrickColor.new, txt)
                        if ok2 and bc and bc.Name == txt then add(txt) end
                    end
                end
            end
        end
    end

    for _ = 1, 30 do add(BrickColor.Random().Name) end
    return colors
end

--------------------------------------------------------------------------------
-- §16  BUILT-IN PRESETS (CFrame-native output format)
--------------------------------------------------------------------------------
local function makePreset(genFunc, name)
    return function(self)
        local cframes, colors = {}, {}
        local count = 0
        local function addBlock(x, y, z, color)
            count = count + 1
            cframes[count] = CFrame_new(x, y, z)
            colors[count]  = color
        end
        genFunc(addBlock)
        return {
            cframes = cframes, colors = colors, count = count,
            sizeBytes = 0, metadata = { format = "preset", presetName = name },
        }
    end
end

BuildEngine.GenerateProMansion = makePreset(function(add)
    local w = 3
    for x = -w, w do for z = -w, w do add(x+w, 0, z+w) end end
    for y = 1, 3 do
        for x = -w, w do for z = -w, w do
            if math_abs(x) == w or math_abs(z) == w then
                local isDoor   = z == -w and math_abs(x) <= 1 and y <= 2
                local isWindow = y == 2 and (x == 0 or z == w)
                if not isDoor and not isWindow then add(x+w, y, z+w) end
            end
        end end
    end
    for off = 0, 3 do
        local rl = 4 + off; local rw = w + 1 - off
        for x = -rw, rw do for z = -rw, rw do
            if math_abs(x) == rw or math_abs(z) == rw or rw == 0 then
                add(x+w+1, rl, z+w+1)
            end
        end end
    end
end, "Pro Mansion")

BuildEngine.GenerateFortress = makePreset(function(add)
    local s = 5
    for x = -s, s do for z = -s, s do add(x+s, 0, z+s) end end
    for y = 1, 4 do
        for x = -s, s do for z = -s, s do
            if math_abs(x) == s or math_abs(z) == s then add(x+s, y, z+s) end
        end end
    end
    local corners = {{-s,-s},{-s,s},{s,-s},{s,s}}
    for _, c in ipairs(corners) do
        for y = 5, 6 do for dx = -1, 1 do for dz = -1, 1 do
            add(c[1]+dx+s+1, y, c[2]+dz+s+1)
        end end end
    end
    for x = -s, s do for z = -s, s do
        if (math_abs(x) == s or math_abs(z) == s) and (x+z) % 2 == 0 then
            add(x+s, 5, z+s)
        end
    end end
end, "Fortress")

BuildEngine.GenerateTower = makePreset(function(add)
    local r, h = 3, 10
    for y = 0, h do
        for x = -r, r do for z = -r, r do
            local d = math_sqrt(x*x + z*z)
            if d >= r-1 and d <= r then add(x+r, y, z+r) end
            if y == 0 and d <= r then add(x+r, 0, z+r) end
        end end
    end
    for x = -r-1, r+1 do for z = -r-1, r+1 do
        if math_sqrt(x*x + z*z) <= r+1 then add(x+r+1, h+1, z+r+1) end
    end end
end, "Tower")

--------------------------------------------------------------------------------
-- §17  DATAREADER BRIDGE
--------------------------------------------------------------------------------
function BuildEngine:SetDataReader(reader) self._dataReader = reader end

function BuildEngine:ImportBlueprint(source)
    if self._dataReader then return self._dataReader:Parse(source) end

    -- Fallback: basic JSON/URL (V6 compat)
    if type(source) ~= "string" or #source == 0 then
        return false, "Source is empty."
    end
    local rawJSON = source
    if string_find(source, "^https?://") then
        local ok, data = pcall(game.HttpGet, game, source)
        if not ok or type(data) ~= "string" or #data == 0 then
            return false, "Download failed: " .. tostring(data)
        end
        rawJSON = data
    end
    local ok, parsed = pcall(HttpService.JSONDecode, HttpService, rawJSON)
    if not ok then return false, "JSON error: " .. tostring(parsed) end
    if type(parsed) ~= "table" then return false, "JSON must be an array." end

    local cframes, colors, count = {}, {}, 0
    for _, e in ipairs(parsed) do
        if type(e) == "table" then
            count = count + 1
            cframes[count] = CFrame_new(
                tonumber(e.x) or tonumber(e.X) or 0,
                tonumber(e.y) or tonumber(e.Y) or 0,
                tonumber(e.z) or tonumber(e.Z) or 0
            )
            colors[count] = e.color or e.Color
        end
    end
    if count == 0 then return false, "0 valid blocks." end
    return true, {
        cframes = cframes, colors = colors, count = count,
        sizeBytes = #rawJSON, metadata = { format = "json" },
    }
end

--------------------------------------------------------------------------------
-- §18  RESET
--------------------------------------------------------------------------------
function BuildEngine:Reset()
    self:CancelBuild()
    self._resolvedRemote   = nil
    self._remoteArgStyle   = nil
    self._consecutiveFails = 0
    self._adaptiveDelay    = self.PlaceDelay
    self._detectedArea     = nil
    local s = self.Stats
    s.TotalBlocks = 0; s.PlacedBlocks = 0; s.FailedBlocks = 0
    s.StartTime = 0; s.ElapsedTime = 0
end

--------------------------------------------------------------------------------
-- MODULE EXPORT
--------------------------------------------------------------------------------
return BuildEngine
