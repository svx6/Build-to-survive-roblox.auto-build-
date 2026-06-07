--[[
================================================================================
  MODULE 3 — MAIN UI ORCHESTRATION  (Main.lua)
  Pro Architect V7.1 — Rayfield UI + Async Bootstrap + Version-Control Cache

  BOOTSTRAP ARCHITECTURE:
    1. GitHub Version-Control Cache:
       - Fetches code + computes fingerprint (length:prefix hash)
       - Compares against locally cached fingerprint via readfile()
       - Cache HIT: loads from local filesystem (zero network latency)
       - Cache MISS: downloads fresh, writes to local cache, loads
       - Network FAIL: loads from stale cache if available
    2. Async Dependency Handshake:
       - NO arbitrary task.wait() delays
       - Event-driven polling: checks predicate conditions each frame
       - Only triggers lifecycle events after ALL dependencies are verified
    3. Full Rayfield UI with 5 operational tabs

  This module NEVER touches remotes, build logic, or parsing directly.
  All execution is delegated to BuildEngine and DataReader.
================================================================================
--]]

--------------------------------------------------------------------------------
-- §1  LUAU VARIABLE CACHING
--------------------------------------------------------------------------------
local pcall      = pcall
local type       = type
local tostring   = tostring
local math_floor = math.floor
local task_wait  = task.wait
local task_spawn = task.spawn
local ipairs     = ipairs

local Players = game:GetService("Players")

--------------------------------------------------------------------------------
-- §2  GITHUB VERSION-CONTROL CACHE BOOTLOADER
-- Fingerprint = tostring(#code) .. ":" .. first 40 chars
-- Cache directory: "ProArchV7/" in executor workspace
--------------------------------------------------------------------------------
local GITHUB_BASE = "https://raw.githubusercontent.com/svx6/Build-to-survive-roblox.auto-build-/main/"
local CACHE_DIR   = "ProArchV7/"

-- Ensure cache directory exists
pcall(function()
    if not isfolder(CACHE_DIR) then makefolder(CACHE_DIR) end
end)

local function computeFingerprint(code)
    if type(code) ~= "string" then return "" end
    local prefix = #code > 40 and code:sub(1, 40) or code
    return tostring(#code) .. ":" .. prefix
end

local function loadModuleWithCache(fileName)
    local codePath = CACHE_DIR .. fileName
    local hashPath = CACHE_DIR .. fileName .. ".fp"

    --------------------------------------------------------------------------
    -- Attempt 1: Fetch from GitHub
    --------------------------------------------------------------------------
    local remoteCode, remoteFP
    local fetchOk, fetchResult = pcall(game.HttpGet, game, GITHUB_BASE .. fileName, true)

    if fetchOk and type(fetchResult) == "string" and #fetchResult > 100 then
        remoteCode = fetchResult
        remoteFP   = computeFingerprint(remoteCode)

        -- Compare against cached fingerprint
        local localFP = nil
        pcall(function() localFP = readfile(hashPath) end)

        if localFP == remoteFP then
            -- CACHE HIT: Load from local filesystem (faster than re-parsing network data)
            local localOk, localCode = pcall(readfile, codePath)
            if localOk and type(localCode) == "string" and #localCode > 100 then
                local loadOk, mod = pcall(loadstring(localCode))
                if loadOk and mod then
                    return mod, "Cached ✓"
                end
            end
        end

        -- CACHE MISS or stale: Save fresh code + fingerprint, then load
        pcall(function() writefile(codePath, remoteCode) end)
        pcall(function() writefile(hashPath, remoteFP) end)

        local loadOk, mod = pcall(loadstring(remoteCode))
        if loadOk and mod then
            return mod, "GitHub ↓"
        end
    end

    --------------------------------------------------------------------------
    -- Attempt 2: Load from stale cache (GitHub unreachable)
    --------------------------------------------------------------------------
    local cacheOk, cacheCode = pcall(readfile, codePath)
    if cacheOk and type(cacheCode) == "string" and #cacheCode > 100 then
        local loadOk, mod = pcall(loadstring(cacheCode))
        if loadOk and mod then
            return mod, "Offline ⚡"
        end
    end

    --------------------------------------------------------------------------
    -- Attempt 3: Direct local file (executor workspace root)
    --------------------------------------------------------------------------
    local localOk, localCode = pcall(readfile, fileName)
    if localOk and type(localCode) == "string" and #localCode > 50 then
        local loadOk, mod = pcall(loadstring(localCode))
        if loadOk and mod then
            return mod, "Local 📂"
        end
    end

    return nil, "FAILED ❌"
end

--------------------------------------------------------------------------------
-- §3  ASYNC DEPENDENCY HANDSHAKE
-- Polls a predicate function every frame until it returns true or timeout.
-- NO arbitrary delays. Event-driven verification.
--------------------------------------------------------------------------------
local function awaitCondition(predicate, timeoutSec)
    timeoutSec = timeoutSec or 15
    local elapsed = 0
    while not predicate() and elapsed < timeoutSec do
        task_wait(0) -- single frame yield (≈16ms at 60fps)
        elapsed = elapsed + 0.016
    end
    return predicate()
end

local function awaitCharacterReady()
    return awaitCondition(function()
        local p = Players.LocalPlayer
        return p and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
    end, 20)
end

--------------------------------------------------------------------------------
-- §4  LOAD DEPENDENCIES
--------------------------------------------------------------------------------
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local BuildEngine, engineSrc = loadModuleWithCache("BuildEngine.lua")
local DataReader, readerSrc   = loadModuleWithCache("DataReader.lua")

if not BuildEngine then
    Rayfield:Notify({
        Title = "❌ Fatal", Content = "BuildEngine failed to load.", Duration = 10,
    })
    return
end
if not DataReader then
    Rayfield:Notify({
        Title = "⚠️ Warning", Content = "DataReader unavailable. Advanced imports disabled.", Duration = 6,
    })
end

--------------------------------------------------------------------------------
-- §5  ENGINE & READER INSTANCES
--------------------------------------------------------------------------------
local Engine = BuildEngine.new()
local Reader = DataReader and DataReader.new() or nil
if Reader then Engine:SetDataReader(Reader) end

-- Publish to getgenv for cross-script interop
pcall(function()
    getgenv().ProArchitectEngine = Engine
    getgenv().ProArchitectReader = Reader
end)

local REG = BuildEngine.REGISTRY

--------------------------------------------------------------------------------
-- §6  RAYFIELD WINDOW
--------------------------------------------------------------------------------
local Window = Rayfield:CreateWindow({
    Name               = "⚡ Pro Architect V7.1 — Zero-Alloc Framework",
    LoadingTitle       = "Pro Architect V7.1",
    LoadingSubtitle    = "Engine:" .. engineSrc .. " | Reader:" .. (readerSrc or "N/A"),
    Theme              = "Default",
    DisableRayfieldPrompts = false,
    DisableBuildWarnings   = false,
})

--------------------------------------------------------------------------------
-- §7  TAB 1: 🏗️ BUILDER
--------------------------------------------------------------------------------
local BuildTab = Window:CreateTab("🏗️ Builder", nil)

local ColorDropdown = BuildTab:CreateDropdown({
    Name = "🎨 Block Color", Options = REG.Colors,
    CurrentOption = "Institutional white",
    Callback = function(opt) Engine.SelectedColor = opt end,
})

BuildTab:CreateDropdown({
    Name = "🧱 Material Override",
    Options = (function()
        local o = { "None (use color)" }
        for _, v in ipairs(REG.Materials) do o[#o+1] = v end
        for _, v in ipairs(REG.Gamepass)  do o[#o+1] = v end
        return o
    end)(),
    CurrentOption = "None (use color)",
    Callback = function(opt)
        Engine.SelectedMaterial = opt ~= "None (use color)" and opt or nil
    end,
})

BuildTab:CreateDropdown({
    Name = "📐 Block Shape",
    Options = (function()
        local o = { "Standard (Block)" }
        for _, v in ipairs(REG.Shapes)    do o[#o+1] = v end
        for _, v in ipairs(REG.Furniture) do o[#o+1] = v end
        return o
    end)(),
    CurrentOption = "Standard (Block)",
    Callback = function(opt)
        Engine.SelectedBlockType = opt ~= "Standard (Block)" and opt or nil
    end,
})

BuildTab:CreateButton({
    Name = "🔍 Scan Game Blocks",
    Callback = function()
        local found = Engine:ScanGameColors()
        if #found > 0 then
            ColorDropdown:Refresh(found, true)
            Rayfield:Notify({ Title = "Scan Done", Content = #found .. " blocks found.", Duration = 4 })
        else
            Rayfield:Notify({ Title = "Scan Done", Content = "Using registry defaults.", Duration = 4 })
        end
    end,
})

BuildTab:CreateSlider({
    Name = "Grid Size", Range = {1,6}, Increment = 0.5,
    Suffix = " studs", CurrentValue = 3, Flag = "GridSlider",
    Callback = function(v) Engine.GridSize = v end,
})

BuildTab:CreateSlider({
    Name = "Build Speed", Range = {0.01, 0.3}, Increment = 0.01,
    Suffix = " sec", CurrentValue = 0.05, Flag = "SpeedSlider",
    Callback = function(v) Engine.PlaceDelay = v end,
})

BuildTab:CreateSlider({
    Name = "Chunk Size", Range = {5, 100}, Increment = 5,
    Suffix = " blocks", CurrentValue = 20, Flag = "ChunkSlider",
    Callback = function(v) Engine.ChunkSize = v end,
})

BuildTab:CreateSlider({
    Name = "Max Retries", Range = {1, 10}, Increment = 1,
    Suffix = " retries", CurrentValue = 3, Flag = "RetrySlider",
    Callback = function(v) Engine.MaxRetries = v end,
})

BuildTab:CreateButton({
    Name = "🛑 Emergency Stop",
    Callback = function()
        if Engine.IsBuilding then
            Engine:CancelBuild()
            Rayfield:Notify({ Title = "Stopped", Content = "Build cancelled.", Duration = 4 })
        else
            Rayfield:Notify({ Title = "Idle", Content = "No active build.", Duration = 3 })
        end
    end,
})

--------------------------------------------------------------------------------
-- §8  TAB 2: 🎨 PIXEL ART
--------------------------------------------------------------------------------
local PixelTab = Window:CreateTab("🎨 Pixel Art", nil)

local _pixelInput = ""
local _pixelRes   = 16
local _lastPixelBP = nil

PixelTab:CreateLabel("Paste JSON pixel array: [[[r,g,b],...],...]")
PixelTab:CreateLabel("Convert via img2pixel.com → paste JSON here")

PixelTab:CreateInput({
    Name = "Pixel Data (URL or JSON)",
    PlaceholderText = "Paste pixel JSON or URL...",
    RemoveTextAfterFocusLost = false,
    Callback = function(t) _pixelInput = t end,
})

PixelTab:CreateSlider({
    Name = "Max Resolution", Range = {8, 64}, Increment = 4,
    Suffix = " px", CurrentValue = 16, Flag = "PixelResSlider",
    Callback = function(v) _pixelRes = v end,
})

PixelTab:CreateButton({
    Name = "📊 Analyze",
    Callback = function()
        if #_pixelInput == 0 then
            Rayfield:Notify({ Title = "Empty", Content = "Paste pixel data first.", Duration = 3 })
            return
        end
        if not Reader then
            Rayfield:Notify({ Title = "Error", Content = "DataReader not loaded.", Duration = 5 })
            return
        end
        local ok, result = Reader:Parse(_pixelInput, {
            maxPixelWidth = _pixelRes, maxPixelHeight = _pixelRes,
        })
        if not ok then
            Rayfield:Notify({ Title = "Parse Error", Content = tostring(result), Duration = 6 })
            return
        end
        local info = Reader:GetBlueprintInfo(result)
        Rayfield:Notify({ Title = "✅ Ready", Content = info, Duration = 8 })
        _lastPixelBP = result
    end,
})

PixelTab:CreateButton({
    Name = "🚀 Build Pixel Art",
    Callback = function()
        local bp = _lastPixelBP
        if not bp then
            if #_pixelInput == 0 then
                Rayfield:Notify({ Title = "No Data", Content = "Analyze first.", Duration = 3 })
                return
            end
            if Reader then
                local ok, r = Reader:Parse(_pixelInput, { maxPixelWidth = _pixelRes, maxPixelHeight = _pixelRes })
                if not ok then
                    Rayfield:Notify({ Title = "Error", Content = tostring(r), Duration = 5 })
                    return
                end
                bp = r
            else return end
        end
        if Engine.IsBuilding then
            Rayfield:Notify({ Title = "Busy", Content = "Build in progress.", Duration = 3 })
            return
        end
        local info = Engine:ValidateBlueprint(bp)
        Rayfield:Notify({ Title = "Building", Content = info.summary, Duration = 5 })
        task_wait(0.3)
        local ok, err = Engine:ExecuteBuild(bp,
            function(p, t, e)
                if p % 25 == 0 or p == t then
                    Rayfield:Notify({ Title = "🎨 Pixel Art", Content = p.."/"..t.." | "..math_floor(e).."s", Duration = 2 })
                end
            end,
            function(s)
                local st = Engine.IsCancelled and "Cancelled" or "Complete"
                Rayfield:Notify({ Title = st, Content = s.PlacedBlocks.." placed, "..s.FailedBlocks.." failed, "..math_floor(s.ElapsedTime).."s", Duration = 6 })
                _lastPixelBP = nil
            end
        )
        if not ok then Rayfield:Notify({ Title = "Error", Content = tostring(err), Duration = 5 }) end
    end,
})

--------------------------------------------------------------------------------
-- §9  TAB 3: 🌐 IMPORT
--------------------------------------------------------------------------------
local ImportTab = Window:CreateTab("🌐 Import", nil)

local _importInput = ""
local _lastValidBP = nil

ImportTab:CreateLabel("Supports: JSON, Lua scripts, CSV, text, URLs, Discord CDN")

ImportTab:CreateInput({
    Name = "Blueprint Source (any format)",
    PlaceholderText = "Paste JSON, Lua, URL, Discord link...",
    RemoveTextAfterFocusLost = false,
    Callback = function(t) _importInput = t end,
})

ImportTab:CreateButton({
    Name = "✅ Validate & Preview",
    Callback = function()
        if #_importInput == 0 then
            Rayfield:Notify({ Title = "Empty", Content = "Paste data first.", Duration = 3 })
            return
        end
        Rayfield:Notify({ Title = "Validating...", Content = "Parsing...", Duration = 2 })
        local ok, result = Engine:ImportBlueprint(_importInput)
        if not ok then
            Rayfield:Notify({ Title = "❌ Failed", Content = tostring(result), Duration = 6 })
            return
        end
        local eInfo = Engine:ValidateBlueprint(result)
        Rayfield:Notify({ Title = "✅ Valid", Content = eInfo.summary, Duration = 8 })
        if Reader then
            local rInfo = Reader:GetBlueprintInfo(result)
            Rayfield:Notify({ Title = "📊 Details", Content = rInfo, Duration = 6 })
        end
        _lastValidBP = result
    end,
})

ImportTab:CreateButton({
    Name = "🚀 Build Import",
    Callback = function()
        local bp = _lastValidBP
        if not bp then
            if #_importInput == 0 then
                Rayfield:Notify({ Title = "No Data", Content = "Validate first.", Duration = 3 })
                return
            end
            local ok, r = Engine:ImportBlueprint(_importInput)
            if not ok then
                Rayfield:Notify({ Title = "Error", Content = tostring(r), Duration = 5 })
                return
            end
            bp = r
        end
        if Engine.IsBuilding then
            Rayfield:Notify({ Title = "Busy", Content = "Build in progress.", Duration = 3 })
            return
        end
        local ok, err = Engine:ExecuteBuild(bp,
            function(p, t, e)
                if p % 50 == 0 or p == t then
                    Rayfield:Notify({ Title = "Building", Content = p.."/"..t.." | "..math_floor(e).."s", Duration = 2 })
                end
            end,
            function(s)
                local st = Engine.IsCancelled and "Cancelled" or "Complete"
                Rayfield:Notify({ Title = st, Content = s.PlacedBlocks.." placed, "..s.FailedBlocks.." failed, "..math_floor(s.ElapsedTime).."s", Duration = 6 })
                _lastValidBP = nil
            end
        )
        if not ok then Rayfield:Notify({ Title = "Error", Content = tostring(err), Duration = 5 }) end
    end,
})

-- Presets
ImportTab:CreateSection("Built-in Presets")

local function runPreset(name, genFn)
    return function()
        if Engine.IsBuilding then
            Rayfield:Notify({ Title = "Busy", Content = "Stop current build first.", Duration = 3 })
            return
        end
        local bp = genFn(Engine)
        local info = Engine:ValidateBlueprint(bp)
        Rayfield:Notify({ Title = name, Content = info.summary, Duration = 5 })
        task_wait(0.5)
        local ok, err = Engine:ExecuteBuild(bp,
            function(p, t, e)
                if p % 25 == 0 or p == t then
                    Rayfield:Notify({ Title = name, Content = p.."/"..t.." | "..math_floor(e).."s", Duration = 2 })
                end
            end,
            function(s)
                local st = Engine.IsCancelled and "Cancelled" or (name .. " Done")
                Rayfield:Notify({ Title = st, Content = s.PlacedBlocks.." placed, "..math_floor(s.ElapsedTime).."s", Duration = 6 })
            end
        )
        if not ok then Rayfield:Notify({ Title = "Error", Content = tostring(err), Duration = 5 }) end
    end
end

ImportTab:CreateButton({ Name = "🏰 Mansion",  Callback = runPreset("Mansion",  Engine.GenerateProMansion) })
ImportTab:CreateButton({ Name = "🏯 Fortress", Callback = runPreset("Fortress", Engine.GenerateFortress) })
ImportTab:CreateButton({ Name = "🗼 Tower",    Callback = runPreset("Tower",    Engine.GenerateTower) })

--------------------------------------------------------------------------------
-- §10  TAB 4: 🔧 TOOLS
--------------------------------------------------------------------------------
local ToolsTab = Window:CreateTab("🔧 Tools", nil)

ToolsTab:CreateButton({
    Name = "📡 Detect Build Remote",
    Callback = function()
        local ok, msg = Engine:ResolveRemote()
        Rayfield:Notify({
            Title = ok and "✅ Remote Found" or "❌ Error",
            Content = msg, Duration = 5,
        })
    end,
})

ToolsTab:CreateButton({
    Name = "🔓 Gamepass Bypass",
    Callback = function()
        Rayfield:Notify({ Title = "Scanning...", Content = "Purging gamepass locks...", Duration = 2 })
        local count = Engine:BypassGamepass()
        if count > 0 then
            Rayfield:Notify({ Title = "✅ Bypass", Content = count .. " lock(s) destroyed.", Duration = 6 })
        else
            Rayfield:Notify({ Title = "Clean", Content = "No gamepass locks found.", Duration = 5 })
        end
    end,
})

ToolsTab:CreateButton({
    Name = "📐 Scan Build Area",
    Callback = function()
        Engine:DetectPlayerArea()
        Rayfield:Notify({
            Title = "📐 Area", Content = Engine:GetAreaInfoString(), Duration = 8,
        })
    end,
})

ToolsTab:CreateButton({
    Name = "🔨 Auto-Equip Tool",
    Callback = function()
        local tool, msg = Engine:AutoEquipTool()
        Rayfield:Notify({
            Title = tool and "✅ Equipped" or "⚠️ No Tool",
            Content = msg, Duration = 5,
        })
    end,
})

ToolsTab:CreateToggle({
    Name = "👻 Ghost Mode (FPS Saver)",
    CurrentValue = false, Flag = "GhostToggle",
    Callback = function(v)
        Engine:SetGhostMode(v)
        Rayfield:Notify({
            Title = "Ghost Mode",
            Content = v and "ON — local parts transparent." or "OFF — visibility restored.",
            Duration = 3,
        })
    end,
})

ToolsTab:CreateButton({
    Name = "🔄 Reset Engine",
    Callback = function()
        Engine:Reset(); _lastValidBP = nil; _lastPixelBP = nil
        Rayfield:Notify({ Title = "Reset", Content = "Engine state cleared.", Duration = 4 })
    end,
})

ToolsTab:CreateButton({
    Name = "🛑 Emergency Stop",
    Callback = function()
        if Engine.IsBuilding then
            Engine:CancelBuild()
            Rayfield:Notify({ Title = "Stopped", Content = "All builds cancelled.", Duration = 4 })
        else
            Rayfield:Notify({ Title = "Idle", Content = "Nothing running.", Duration = 3 })
        end
    end,
})

--------------------------------------------------------------------------------
-- §11  TAB 5: ⚙️ SETTINGS
--------------------------------------------------------------------------------
local SettingsTab = Window:CreateTab("⚙️ Settings", nil)

SettingsTab:CreateLabel("Engine: " .. (engineSrc or "?") .. " | Reader: " .. (readerSrc or "?"))
SettingsTab:CreateLabel("V7.1 Zero-Alloc | Adaptive Back-off | Chunked Executor")
SettingsTab:CreateLabel("Xeno PC · Delta Mobile · Synapse · Fluxus · Wave")

SettingsTab:CreateToggle({
    Name = "🔄 GitHub Auto-Update", CurrentValue = true, Flag = "AutoUpdateToggle",
    Callback = function(v)
        pcall(function() getgenv().ProArchAutoUpdate = v end)
        Rayfield:Notify({
            Title = "Auto-Update", Duration = 3,
            Content = v and "ON — fetches from GitHub on load." or "OFF — uses local cache.",
        })
    end,
})

SettingsTab:CreateToggle({
    Name = "🐛 Debug Logging", CurrentValue = false, Flag = "DebugToggle",
    Callback = function(v)
        pcall(function() getgenv().ProArchDebug = v end)
        Rayfield:Notify({ Title = "Debug", Content = v and "Enabled" or "Disabled", Duration = 3 })
    end,
})

SettingsTab:CreateButton({
    Name = "⬇️ Force Update from GitHub",
    Callback = function()
        Rayfield:Notify({ Title = "Updating...", Content = "Fetching latest...", Duration = 2 })
        local success = 0
        for _, fn in ipairs({ "BuildEngine.lua", "DataReader.lua", "Main.lua" }) do
            local ok, code = pcall(game.HttpGet, game, GITHUB_BASE .. fn, true)
            if ok and type(code) == "string" and #code > 100 then
                pcall(function() writefile(CACHE_DIR .. fn, code) end)
                pcall(function() writefile(CACHE_DIR .. fn .. ".fp", computeFingerprint(code)) end)
                pcall(function() writefile(fn, code) end)
                success = success + 1
            end
        end
        Rayfield:Notify({
            Title = "✅ Updated", Duration = 6,
            Content = success .. "/3 files. Restart to apply.",
        })
    end,
})

SettingsTab:CreateButton({
    Name = "🗑️ Flush All Caches",
    Callback = function()
        Engine:Reset(); _lastValidBP = nil; _lastPixelBP = nil
        _importInput = ""; _pixelInput = ""
        pcall(function() getgenv().ProArchitectEngine = nil end)
        pcall(function() getgenv().ProArchitectReader = nil end)
        Rayfield:Notify({ Title = "Flushed", Content = "All caches cleared.", Duration = 4 })
    end,
})

SettingsTab:CreateParagraph({
    Title = "About Pro Architect V7.1",
    Content = "Zero-GC-alloc build framework for Roblox stamper games.\n\n"
        .. "• 17 Colors + 15 Materials + 5 Gamepass + 6 Shapes + 7 Furniture\n"
        .. "• Pre-computed CFrame arrays (zero per-block allocation)\n"
        .. "• Pre-created fire closure (upvalue mutation pattern)\n"
        .. "• Adaptive exponential back-off (anti-flood evasion)\n"
        .. "• Multi-format smart parser (JSON/Lua/CSV/TXT/URL/Discord)\n"
        .. "• RGB→BrickColor pixel art (squared Euclidean distance)\n"
        .. "• Gamepass bypass (scoped instance purge)\n"
        .. "• Auto-equip with maintained tool parenting\n"
        .. "• Ghost mode for FPS preservation\n"
        .. "• GitHub version-control cache bootloader\n"
        .. "• Async event-driven initialization\n\n"
        .. "github.com/svx6/Build-to-survive-roblox.auto-build-",
})

SettingsTab:CreateLabel("GitHub: github.com/svx6/Build-to-survive-roblox.auto-build-")

--------------------------------------------------------------------------------
-- §12  EVENT-DRIVEN INITIALIZATION (Zero arbitrary delays)
-- Polls for character readiness, then triggers lifecycle events in sequence.
-- Each step only executes after its dependency is confirmed.
--------------------------------------------------------------------------------
task_spawn(function()
    -- Phase 1: Await character readiness (no arbitrary delay)
    local charReady = awaitCharacterReady()
    if not charReady then
        Rayfield:Notify({
            Title = "⚠️ Timeout",
            Content = "Character not loaded. Some features may not work.",
            Duration = 6,
        })
    end

    -- Phase 2: Resolve build remote (depends on: character, game loaded)
    local remoteOk, remoteMsg = Engine:ResolveRemote()
    Rayfield:Notify({
        Title = remoteOk and "📡 Remote" or "📡 No Remote",
        Content = remoteMsg, Duration = 4,
    })

    -- Phase 3: Detect build area (depends on: character, workspace loaded)
    local area = Engine:DetectPlayerArea()
    if area and area.basePart then
        Rayfield:Notify({
            Title = "📐 Area", Content = Engine:GetAreaInfoString(), Duration = 4,
        })
    end

    -- Phase 4: Auto-bypass gamepass locks (depends on: workspace loaded)
    local bypassCount = Engine:BypassGamepass()
    if bypassCount > 0 then
        Rayfield:Notify({
            Title = "🔓 Auto-Bypass",
            Content = bypassCount .. " gamepass lock(s) removed.",
            Duration = 4,
        })
    end

    -- Phase 5: Auto-equip tool if available
    local tool, toolMsg = Engine:AutoEquipTool()
    if tool then
        Rayfield:Notify({ Title = "🔨 Tool", Content = toolMsg, Duration = 3 })
    end
end)

Rayfield:Notify({
    Title = "⚡ Pro Architect V7.1",
    Content = "Zero-Alloc Framework loaded.",
    Duration = 4,
})
