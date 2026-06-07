local pcall = pcall
local type = type
local tostring = tostring
local math_floor = math.floor
local task_wait = task.wait
local task_spawn = task.spawn
local ipairs = ipairs
local tick = tick

local Players = game:GetService("Players")

local GITHUB_BASE = "https://raw.githubusercontent.com/svx6/Build-to-survive-roblox.auto-build-/main/"
local CACHE_DIR = "ProArchV7/"

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

    local remoteCode, remoteFP
    local fetchOk, fetchResult = pcall(game.HttpGet, game, GITHUB_BASE .. fileName, true)

    if fetchOk and type(fetchResult) == "string" and #fetchResult > 100 then
        remoteCode = fetchResult
        remoteFP = computeFingerprint(remoteCode)

        local localFP = nil
        pcall(function() localFP = readfile(hashPath) end)

        if localFP == remoteFP then
            local localOk, localCode = pcall(readfile, codePath)
            if localOk and type(localCode) == "string" and #localCode > 100 then
                local fn = loadstring(localCode)
                if fn then
                    local loadOk, mod = pcall(fn)
                    if loadOk and mod then return mod, "Cached" end
                end
            end
        end

        pcall(function() writefile(codePath, remoteCode) end)
        pcall(function() writefile(hashPath, remoteFP) end)

        local fn = loadstring(remoteCode)
        if fn then
            local loadOk, mod = pcall(fn)
            if loadOk and mod then return mod, "GitHub" end
        end
    end

    local cacheOk, cacheCode = pcall(readfile, codePath)
    if cacheOk and type(cacheCode) == "string" and #cacheCode > 100 then
        local fn = loadstring(cacheCode)
        if fn then
            local loadOk, mod = pcall(fn)
            if loadOk and mod then return mod, "Offline" end
        end
    end

    local localOk, localCode = pcall(readfile, fileName)
    if localOk and type(localCode) == "string" and #localCode > 50 then
        local fn = loadstring(localCode)
        if fn then
            local loadOk, mod = pcall(fn)
            if loadOk and mod then return mod, "Local" end
        end
    end

    return nil, "FAILED"
end

local function awaitCondition(predicate, timeoutSec)
    timeoutSec = timeoutSec or 15
    local startT = tick()
    while not predicate() and (tick() - startT) < timeoutSec do
        task_wait(0.1)
    end
    return predicate()
end

local function awaitCharacterReady()
    return awaitCondition(function()
        local p = Players.LocalPlayer
        return p and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
    end, 20)
end

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local BuildEngine, engineSrc = loadModuleWithCache("BuildEngine.lua")
local DataReader, readerSrc = loadModuleWithCache("DataReader.lua")

if not BuildEngine then
    Rayfield:Notify({ Title = "Fatal Error", Content = "BuildEngine failed to load.", Duration = 10 })
    return
end
if not DataReader then
    Rayfield:Notify({ Title = "Warning", Content = "DataReader unavailable.", Duration = 6 })
end

local Engine = BuildEngine.new()
local Reader = DataReader and DataReader.new() or nil
if Reader then Engine:SetDataReader(Reader) end

pcall(function()
    getgenv().ProArchitectEngine = Engine
    getgenv().ProArchitectReader = Reader
end)

local REG = BuildEngine.REGISTRY

local Window = Rayfield:CreateWindow({
    Name = "Pro Architect V7.1",
    LoadingTitle = "Pro Architect V7.1",
    LoadingSubtitle = "Engine:" .. engineSrc .. " | Reader:" .. (readerSrc or "N/A"),
    Theme = "Default",
    DisableRayfieldPrompts = false,
    DisableBuildWarnings = false,
})

local _lastValidBP = nil
local _lastPixelBP = nil
local _importInput = ""
local _pixelInput = ""
local _pixelRes = 16

local BuildTab = Window:CreateTab("Builder", nil)

local allBlockOptions = {}
for _, v in ipairs(REG.Colors) do allBlockOptions[#allBlockOptions + 1] = v end

local ColorDropdown = BuildTab:CreateDropdown({
    Name = "Block Color",
    Options = REG.Colors,
    CurrentOption = "Institutional white",
    Callback = function(opt)
        Engine.SelectedColor = opt
    end,
})

local materialOptions = { "None (use color)" }
for _, v in ipairs(REG.Materials) do materialOptions[#materialOptions + 1] = v end
for _, v in ipairs(REG.Gamepass) do materialOptions[#materialOptions + 1] = v end

BuildTab:CreateDropdown({
    Name = "Material Override (forces ALL blocks)",
    Options = materialOptions,
    CurrentOption = "None (use color)",
    Callback = function(opt)
        if opt == "None (use color)" then
            Engine.SelectedMaterial = nil
        else
            Engine.SelectedMaterial = opt
        end
    end,
})

local shapeOptions = { "Standard (Block)" }
for _, v in ipairs(REG.Shapes) do shapeOptions[#shapeOptions + 1] = v end
for _, v in ipairs(REG.Furniture) do shapeOptions[#shapeOptions + 1] = v end

BuildTab:CreateDropdown({
    Name = "Block Shape",
    Options = shapeOptions,
    CurrentOption = "Standard (Block)",
    Callback = function(opt)
        Engine.SelectedBlockType = opt ~= "Standard (Block)" and opt or nil
    end,
})

BuildTab:CreateButton({
    Name = "Scan Game Blocks",
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
    Name = "Grid Size",
    Range = { 1, 6 },
    Increment = 0.5,
    Suffix = " studs",
    CurrentValue = 3,
    Flag = "GridSlider",
    Callback = function(v) Engine.GridSize = v end,
})

BuildTab:CreateSlider({
    Name = "Build Speed",
    Range = { 0.01, 0.3 },
    Increment = 0.01,
    Suffix = " sec",
    CurrentValue = 0.05,
    Flag = "SpeedSlider",
    Callback = function(v) Engine.PlaceDelay = v end,
})

BuildTab:CreateSlider({
    Name = "Chunk Size",
    Range = { 5, 100 },
    Increment = 5,
    Suffix = " blocks",
    CurrentValue = 20,
    Flag = "ChunkSlider",
    Callback = function(v) Engine.ChunkSize = v end,
})

BuildTab:CreateSlider({
    Name = "Max Retries",
    Range = { 1, 10 },
    Increment = 1,
    Suffix = " retries",
    CurrentValue = 3,
    Flag = "RetrySlider",
    Callback = function(v) Engine.MaxRetries = v end,
})

BuildTab:CreateButton({
    Name = "STOP BUILD",
    Callback = function()
        if Engine.IsBuilding then
            Engine:CancelBuild()
            Rayfield:Notify({ Title = "Stopped", Content = "Build cancelled.", Duration = 4 })
        else
            Rayfield:Notify({ Title = "Idle", Content = "No active build.", Duration = 3 })
        end
    end,
})

local PixelTab = Window:CreateTab("Pixel Art", nil)

PixelTab:CreateParagraph({
    Title = "How to use Pixel Art",
    Content = "1. Go to img2pixel.com\n2. Upload your image\n3. Copy the JSON output\n4. Paste it below\n5. Click Analyze then Build\n\nFormat: [[[r,g,b],[r,g,b],...],...]",
})

PixelTab:CreateInput({
    Name = "Pixel Data (URL or JSON)",
    PlaceholderText = "Paste pixel JSON or URL here...",
    RemoveTextAfterFocusLost = false,
    Callback = function(t) _pixelInput = t end,
})

PixelTab:CreateSlider({
    Name = "Max Resolution",
    Range = { 8, 64 },
    Increment = 4,
    Suffix = " px",
    CurrentValue = 16,
    Flag = "PixelResSlider",
    Callback = function(v) _pixelRes = v end,
})

PixelTab:CreateButton({
    Name = "Analyze Pixel Data",
    Callback = function()
        if #_pixelInput == 0 then
            Rayfield:Notify({ Title = "Empty", Content = "Paste pixel data first.", Duration = 3 })
            return
        end
        if not Reader then
            Rayfield:Notify({ Title = "Error", Content = "DataReader not loaded.", Duration = 5 })
            return
        end
        Rayfield:Notify({ Title = "Analyzing...", Content = "Parsing pixel data...", Duration = 2 })
        local ok, result = Reader:Parse(_pixelInput, {
            maxPixelWidth = _pixelRes,
            maxPixelHeight = _pixelRes,
        })
        if not ok then
            Rayfield:Notify({ Title = "Parse Error", Content = tostring(result), Duration = 8 })
            return
        end
        local info = Reader:GetBlueprintInfo(result)
        Rayfield:Notify({ Title = "Ready", Content = info, Duration = 8 })
        _lastPixelBP = result
    end,
})

PixelTab:CreateButton({
    Name = "Build Pixel Art",
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
            else
                return
            end
        end
        if Engine.IsBuilding then
            Rayfield:Notify({ Title = "Busy", Content = "Build already in progress.", Duration = 3 })
            return
        end
        local info = Engine:ValidateBlueprint(bp)
        Rayfield:Notify({ Title = "Building Pixel Art", Content = info.summary, Duration = 5 })
        task_wait(0.3)
        local ok, err = Engine:ExecuteBuild(bp,
            function(p, t, e)
                if p % 50 == 0 or p == t then
                    local pct = math_floor(p / t * 100)
                    Rayfield:Notify({ Title = "Pixel Art " .. pct .. "%", Content = p .. "/" .. t .. " | " .. math_floor(e) .. "s", Duration = 2 })
                end
            end,
            function(s)
                local st = Engine.IsCancelled and "Cancelled" or "Complete"
                Rayfield:Notify({ Title = st, Content = s.PlacedBlocks .. " placed, " .. s.FailedBlocks .. " failed, " .. math_floor(s.ElapsedTime) .. "s", Duration = 6 })
                _lastPixelBP = nil
            end
        )
        if not ok then
            Rayfield:Notify({ Title = "Error", Content = tostring(err), Duration = 5 })
        end
    end,
})

local ImportTab = Window:CreateTab("Import", nil)

ImportTab:CreateParagraph({
    Title = "Supported Formats",
    Content = "JSON blueprints, Lua remote spy scripts, CSV coordinates,\nplain text block names, direct URLs, Discord CDN file links\n\nFor Discord: Right-click the file -> Copy Link\n(must be cdn.discordapp.com link, NOT a message link)",
})

ImportTab:CreateInput({
    Name = "Blueprint Source",
    PlaceholderText = "Paste JSON, Lua script, URL, or Discord link...",
    RemoveTextAfterFocusLost = false,
    Callback = function(t) _importInput = t end,
})

ImportTab:CreateButton({
    Name = "Validate & Preview",
    Callback = function()
        if #_importInput == 0 then
            Rayfield:Notify({ Title = "Empty", Content = "Paste data first.", Duration = 3 })
            return
        end
        Rayfield:Notify({ Title = "Validating...", Content = "Parsing input...", Duration = 2 })
        local ok, result = Engine:ImportBlueprint(_importInput)
        if not ok then
            Rayfield:Notify({ Title = "Failed", Content = tostring(result), Duration = 8 })
            return
        end
        local eInfo = Engine:ValidateBlueprint(result)
        Rayfield:Notify({ Title = "Valid Blueprint", Content = eInfo.summary, Duration = 8 })
        if Reader then
            local rInfo = Reader:GetBlueprintInfo(result)
            Rayfield:Notify({ Title = "Details", Content = rInfo, Duration = 6 })
        end
        _lastValidBP = result
    end,
})

ImportTab:CreateButton({
    Name = "Build Import",
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
            Rayfield:Notify({ Title = "Busy", Content = "Build already in progress.", Duration = 3 })
            return
        end
        local ok, err = Engine:ExecuteBuild(bp,
            function(p, t, e)
                if p % 50 == 0 or p == t then
                    local pct = math_floor(p / t * 100)
                    Rayfield:Notify({ Title = "Building " .. pct .. "%", Content = p .. "/" .. t .. " | " .. math_floor(e) .. "s", Duration = 2 })
                end
            end,
            function(s)
                local st = Engine.IsCancelled and "Cancelled" or "Complete"
                Rayfield:Notify({ Title = st, Content = s.PlacedBlocks .. " placed, " .. s.FailedBlocks .. " failed, " .. math_floor(s.ElapsedTime) .. "s", Duration = 6 })
                _lastValidBP = nil
            end
        )
        if not ok then
            Rayfield:Notify({ Title = "Error", Content = tostring(err), Duration = 5 })
        end
    end,
})

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
                    local pct = math_floor(p / t * 100)
                    Rayfield:Notify({ Title = name .. " " .. pct .. "%", Content = p .. "/" .. t .. " | " .. math_floor(e) .. "s", Duration = 2 })
                end
            end,
            function(s)
                local st = Engine.IsCancelled and "Cancelled" or (name .. " Done")
                Rayfield:Notify({ Title = st, Content = s.PlacedBlocks .. " placed, " .. math_floor(s.ElapsedTime) .. "s", Duration = 6 })
            end
        )
        if not ok then
            Rayfield:Notify({ Title = "Error", Content = tostring(err), Duration = 5 })
        end
    end
end

ImportTab:CreateButton({ Name = "Mansion", Callback = runPreset("Mansion", Engine.GenerateProMansion) })
ImportTab:CreateButton({ Name = "Fortress", Callback = runPreset("Fortress", Engine.GenerateFortress) })
ImportTab:CreateButton({ Name = "Tower", Callback = runPreset("Tower", Engine.GenerateTower) })

local ToolsTab = Window:CreateTab("Tools", nil)

ToolsTab:CreateButton({
    Name = "Detect Build Remote",
    Callback = function()
        local ok, msg = Engine:ResolveRemote()
        Rayfield:Notify({
            Title = ok and "Remote Found" or "No Remote",
            Content = msg,
            Duration = 5,
        })
    end,
})

ToolsTab:CreateButton({
    Name = "Gamepass Bypass",
    Callback = function()
        Rayfield:Notify({ Title = "Scanning...", Content = "Purging gamepass locks...", Duration = 2 })
        local count = Engine:BypassGamepass()
        if count > 0 then
            Rayfield:Notify({ Title = "Bypass Done", Content = count .. " lock(s) destroyed.", Duration = 6 })
        else
            Rayfield:Notify({ Title = "Clean", Content = "No gamepass locks found.", Duration = 5 })
        end
    end,
})

ToolsTab:CreateButton({
    Name = "Scan Build Area",
    Callback = function()
        Rayfield:Notify({ Title = "Scanning...", Content = "Detecting player area...", Duration = 2 })
        Engine:DetectPlayerArea()
        Rayfield:Notify({
            Title = "Area Detected",
            Content = Engine:GetAreaInfoString(),
            Duration = 8,
        })
    end,
})

ToolsTab:CreateButton({
    Name = "Auto-Equip Tool",
    Callback = function()
        local tool, msg = Engine:AutoEquipTool()
        Rayfield:Notify({
            Title = tool and "Equipped" or "No Tool Found",
            Content = msg,
            Duration = 5,
        })
    end,
})

ToolsTab:CreateToggle({
    Name = "Ghost Mode (FPS Saver)",
    CurrentValue = false,
    Flag = "GhostToggle",
    Callback = function(v)
        Engine:SetGhostMode(v)
        Rayfield:Notify({
            Title = "Ghost Mode",
            Content = v and "ON - local parts transparent" or "OFF - visibility restored",
            Duration = 3,
        })
    end,
})

ToolsTab:CreateButton({
    Name = "Reset Engine",
    Callback = function()
        Engine:Reset()
        _lastValidBP = nil
        _lastPixelBP = nil
        Rayfield:Notify({ Title = "Reset", Content = "Engine state cleared.", Duration = 4 })
    end,
})

ToolsTab:CreateButton({
    Name = "STOP ALL BUILDS",
    Callback = function()
        if Engine.IsBuilding then
            Engine:CancelBuild()
            Rayfield:Notify({ Title = "Stopped", Content = "All builds cancelled.", Duration = 4 })
        else
            Rayfield:Notify({ Title = "Idle", Content = "Nothing running.", Duration = 3 })
        end
    end,
})

local SettingsTab = Window:CreateTab("Settings", nil)

SettingsTab:CreateLabel("Engine: " .. (engineSrc or "?") .. " | Reader: " .. (readerSrc or "?"))
SettingsTab:CreateLabel("V7.1 | Zero-Alloc Build Loop | Adaptive Back-off")
SettingsTab:CreateLabel("Compatible: Xeno PC, Delta Mobile, Synapse, Fluxus, Wave, Hydrx")

SettingsTab:CreateToggle({
    Name = "GitHub Auto-Update",
    CurrentValue = true,
    Flag = "AutoUpdateToggle",
    Callback = function(v)
        pcall(function() getgenv().ProArchAutoUpdate = v end)
        Rayfield:Notify({
            Title = "Auto-Update",
            Content = v and "ON" or "OFF",
            Duration = 3,
        })
    end,
})

SettingsTab:CreateButton({
    Name = "Force Update from GitHub",
    Callback = function()
        Rayfield:Notify({ Title = "Updating...", Content = "Fetching latest code...", Duration = 2 })
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
            Title = "Updated",
            Content = success .. "/3 files downloaded. Restart to apply.",
            Duration = 6,
        })
    end,
})

SettingsTab:CreateButton({
    Name = "Flush All Caches",
    Callback = function()
        Engine:Reset()
        _lastValidBP = nil
        _lastPixelBP = nil
        _importInput = ""
        _pixelInput = ""
        pcall(function() getgenv().ProArchitectEngine = nil end)
        pcall(function() getgenv().ProArchitectReader = nil end)
        Rayfield:Notify({ Title = "Flushed", Content = "All caches cleared.", Duration = 4 })
    end,
})

SettingsTab:CreateParagraph({
    Title = "About Pro Architect V7.1",
    Content = "Auto-builder for Roblox stamper/build games.\n\n"
        .. "17 Colors + 15 Materials + 5 Gamepass + 6 Shapes + 7 Furniture\n"
        .. "Zero-GC build loop with pre-computed CFrames\n"
        .. "Adaptive exponential back-off (anti-flood)\n"
        .. "Multi-format parser (JSON/Lua/CSV/TXT/URL/Discord)\n"
        .. "RGB pixel art engine with Euclidean distance\n"
        .. "Scoped gamepass bypass\n"
        .. "Auto-equip + maintained tool parenting\n"
        .. "Auto area detection for Build to Survive games\n\n"
        .. "github.com/svx6/Build-to-survive-roblox.auto-build-",
})

task_spawn(function()
    local charReady = awaitCharacterReady()
    if not charReady then
        Rayfield:Notify({
            Title = "Timeout",
            Content = "Character not loaded. Some features may not work.",
            Duration = 6,
        })
    end

    local remoteOk, remoteMsg = Engine:ResolveRemote()
    Rayfield:Notify({
        Title = remoteOk and "Remote Found" or "No Remote",
        Content = remoteMsg,
        Duration = 4,
    })

    local area = Engine:DetectPlayerArea()
    if area and area.basePart then
        Rayfield:Notify({
            Title = "Build Area",
            Content = Engine:GetAreaInfoString(),
            Duration = 4,
        })
    end

    local bypassCount = Engine:BypassGamepass()
    if bypassCount > 0 then
        Rayfield:Notify({
            Title = "Auto-Bypass",
            Content = bypassCount .. " gamepass lock(s) removed.",
            Duration = 4,
        })
    end

    local tool, toolMsg = Engine:AutoEquipTool()
    if tool then
        Rayfield:Notify({ Title = "Tool Equipped", Content = toolMsg, Duration = 3 })
    end
end)

Rayfield:Notify({
    Title = "Pro Architect V7.1",
    Content = "Loaded successfully.",
    Duration = 4,
})
