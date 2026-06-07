--[[
================================================================================
  PART 2 — RAYFIELD UI INTEGRATION  (Main.lua)
  
  A clean user interface layer wrapping the Build Engine Core (Part 1).
  
  This script:
    • Loads the Rayfield UI library
    • Instantiates a BuildEngine from Part 1
    • Provides controls for color selection, grid size, build speed
    • Accepts GitHub Raw URLs or raw JSON strings for external blueprints
    • Validates blueprints before building (block count, size, ETA)
    • Provides start/stop controls with live progress notifications
    
  The UI never touches networking, remotes, or build logic directly —
  all of that is delegated to BuildEngine.
================================================================================
--]]

--------------------------------------------------------------------------------
-- §1  LUAU VARIABLE CACHING (UI-side)
--------------------------------------------------------------------------------
local pcall       = pcall
local tostring    = tostring
local type        = type
local math_floor  = math.floor
local task_wait   = task.wait

--------------------------------------------------------------------------------
-- §2  LOAD DEPENDENCIES
--------------------------------------------------------------------------------

-- Load Rayfield UI framework
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

-- Load the Build Engine Core (Part 1)
-- In a single-script executor environment, the engine is defined above
-- or loaded inline. For modularity we use loadstring from a local/raw source.
-- If you keep both files side by side, paste the BuildEngine code above this
-- section or use your executor's file system (e.g., readfile/loadfile).
--
-- For a SINGLE-FILE deployment, the entire BuildEngine module can be
-- prepended above this line and captured via:
--     local BuildEngine = (function() ... end)()
--
-- For SPLIT-FILE deployment (recommended), use your executor's loader:
--     local BuildEngine = loadfile("BuildEngine.lua")()
--     -- or --
--     local BuildEngine = loadstring(readfile("BuildEngine.lua"))()

local BuildEngine = loadstring(readfile("BuildEngine.lua"))()

--------------------------------------------------------------------------------
-- §3  ENGINE INSTANCE
--------------------------------------------------------------------------------
local Engine = BuildEngine.new()

--------------------------------------------------------------------------------
-- §4  RAYFIELD WINDOW
--------------------------------------------------------------------------------
local Window = Rayfield:CreateWindow({
    Name              = "⚡ Pro Architect V6 — Production Framework",
    LoadingTitle      = "Initializing Build Framework...",
    LoadingSubtitle   = "Engine Core + Rayfield UI",
    Theme             = "Default",
    DisableRayfieldPrompts = false,
    DisableBuildWarnings   = false,
})

--------------------------------------------------------------------------------
-- §5  MAIN BUILDER TAB
--------------------------------------------------------------------------------
local BuildTab = Window:CreateTab("🏗️ Builder", nil)

-- ─── Color Selection ────────────────────────────────────────────────────────
local defaultColors = {
    "Institutional white", "Bright blue", "Really red",
    "Really black", "Bright green", "Neon orange",
    "Dark stone grey", "Reddish brown",
}

local ColorDropdown = BuildTab:CreateDropdown({
    Name          = "Block Color",
    Options       = defaultColors,
    CurrentOption = "Institutional white",
    Callback      = function(option)
        Engine.SelectedColor = option
    end,
})

-- ─── Scan Colors Button ─────────────────────────────────────────────────────
BuildTab:CreateButton({
    Name     = "🔍 Scan Game for Colors / Blocks",
    Callback = function()
        local found = Engine:ScanGameColors()
        if #found > 0 then
            ColorDropdown:Refresh(found, true)
            Rayfield:Notify({
                Title   = "Scan Complete",
                Content = "Discovered " .. #found .. " colors/blocks.",
                Duration = 4,
            })
        else
            Rayfield:Notify({
                Title   = "Scan Complete",
                Content = "No new colors found — using defaults.",
                Duration = 4,
            })
        end
    end,
})

-- ─── Fuzz Remote Button ─────────────────────────────────────────────────────
BuildTab:CreateButton({
    Name     = "📡 Auto-Detect Build Remote",
    Callback = function()
        local ok, msg = Engine:FuzzRemote()
        Rayfield:Notify({
            Title    = ok and "Remote Found" or "Remote Error",
            Content  = msg,
            Duration = 5,
        })
    end,
})

-- ─── Grid Size Slider ───────────────────────────────────────────────────────
BuildTab:CreateSlider({
    Name         = "Grid Size (Spacing)",
    Range        = {1, 6},
    Increment    = 0.5,
    Suffix       = " Studs",
    CurrentValue = 3,
    Flag         = "GridSlider",
    Callback     = function(value)
        Engine.GridSize = value
    end,
})

-- ─── Build Speed Slider ─────────────────────────────────────────────────────
BuildTab:CreateSlider({
    Name         = "Build Speed (Delay)",
    Range        = {0.01, 0.3},
    Increment    = 0.01,
    Suffix       = " Sec",
    CurrentValue = 0.05,
    Flag         = "SpeedSlider",
    Callback     = function(value)
        Engine.PlaceDelay = value
    end,
})

-- ─── Chunk Size Slider ──────────────────────────────────────────────────────
BuildTab:CreateSlider({
    Name         = "Chunk Size (Blocks/Batch)",
    Range        = {10, 200},
    Increment    = 10,
    Suffix       = " blocks",
    CurrentValue = 50,
    Flag         = "ChunkSlider",
    Callback     = function(value)
        Engine.ChunkSize = value
    end,
})

--------------------------------------------------------------------------------
-- §6  BUILT-IN BLUEPRINT: PRO MANSION
--------------------------------------------------------------------------------
local PresetsTab = Window:CreateTab("🏰 Presets", nil)

PresetsTab:CreateButton({
    Name     = "🏰 Build Pro Mansion",
    Callback = function()
        if Engine.IsBuilding then
            Rayfield:Notify({
                Title   = "Busy",
                Content = "A build is already in progress. Stop it first.",
                Duration = 3,
            })
            return
        end

        local blueprint = Engine:GenerateProMansion()
        local info      = Engine:ValidateBlueprint(blueprint)

        Rayfield:Notify({
            Title   = "Mansion Blueprint",
            Content = info.summary,
            Duration = 5,
        })

        -- Small delay so the user sees the validation notification
        task_wait(1)

        local ok, err = Engine:ExecuteBuild(
            blueprint,
            -- onProgress: periodic notifications
            function(placed, total, elapsed)
                -- Throttle UI updates to every 25 blocks
                if placed % 25 == 0 or placed == total then
                    Rayfield:Notify({
                        Title    = "Building...",
                        Content  = placed .. "/" .. total
                            .. " blocks  |  "
                            .. math_floor(elapsed) .. "s elapsed",
                        Duration = 2,
                    })
                end
            end,
            -- onComplete
            function(stats)
                local status = Engine.IsCancelled and "Build Cancelled" or "Build Complete"
                Rayfield:Notify({
                    Title   = status,
                    Content = stats.PlacedBlocks .. " placed, "
                        .. stats.FailedBlocks .. " failed, "
                        .. math_floor(stats.ElapsedTime) .. "s total.",
                    Duration = 6,
                })
            end
        )

        if not ok then
            Rayfield:Notify({
                Title   = "Build Error",
                Content = tostring(err),
                Duration = 5,
            })
        end
    end,
})

--------------------------------------------------------------------------------
-- §7  EXTERNAL BLUEPRINT TAB (URL / JSON IMPORT)
--------------------------------------------------------------------------------
local ImportTab = Window:CreateTab("🌐 Import", nil)

-- Stored input from the text box
local _importInput = ""

ImportTab:CreateInput({
    Name            = "Blueprint Source (URL or JSON)",
    PlaceholderText = "Paste GitHub Raw URL or JSON array...",
    RemoveTextAfterFocusLost = false,
    Callback        = function(text)
        _importInput = text
    end,
})

-- ─── Validate Button ────────────────────────────────────────────────────────
ImportTab:CreateButton({
    Name     = "✅ Validate Blueprint",
    Callback = function()
        if #_importInput == 0 then
            Rayfield:Notify({
                Title   = "Empty Input",
                Content = "Paste a URL or JSON into the text box first.",
                Duration = 3,
            })
            return
        end

        Rayfield:Notify({
            Title   = "Validating...",
            Content = "Downloading & parsing blueprint...",
            Duration = 3,
        })

        local ok, result = Engine:ImportBlueprint(_importInput)
        if not ok then
            Rayfield:Notify({
                Title   = "Validation Failed",
                Content = tostring(result),
                Duration = 5,
            })
            return
        end

        local info = Engine:ValidateBlueprint(result)
        Rayfield:Notify({
            Title   = "Validation Result",
            Content = info.summary,
            Duration = 8,
        })

        -- Store the validated blueprint for the Build button
        _lastValidatedBlueprint = result
    end,
})

-- ─── Build from Import Button ───────────────────────────────────────────────
ImportTab:CreateButton({
    Name     = "🚀 Build Imported Blueprint",
    Callback = function()
        -- If we have a pre-validated blueprint, use it; otherwise import fresh
        local blueprint = _lastValidatedBlueprint

        if not blueprint then
            if #_importInput == 0 then
                Rayfield:Notify({
                    Title   = "No Blueprint",
                    Content = "Paste a URL or JSON and validate first.",
                    Duration = 3,
                })
                return
            end

            local ok, result = Engine:ImportBlueprint(_importInput)
            if not ok then
                Rayfield:Notify({
                    Title   = "Import Error",
                    Content = tostring(result),
                    Duration = 5,
                })
                return
            end
            blueprint = result
        end

        if Engine.IsBuilding then
            Rayfield:Notify({
                Title   = "Busy",
                Content = "A build is already in progress.",
                Duration = 3,
            })
            return
        end

        local ok, err = Engine:ExecuteBuild(
            blueprint,
            -- onProgress
            function(placed, total, elapsed)
                if placed % 50 == 0 or placed == total then
                    Rayfield:Notify({
                        Title    = "Building...",
                        Content  = placed .. "/" .. total
                            .. " blocks  |  "
                            .. math_floor(elapsed) .. "s elapsed",
                        Duration = 2,
                    })
                end
            end,
            -- onComplete
            function(stats)
                local status = Engine.IsCancelled and "Build Cancelled" or "Build Complete"
                Rayfield:Notify({
                    Title   = status,
                    Content = stats.PlacedBlocks .. " placed, "
                        .. stats.FailedBlocks .. " failed, "
                        .. math_floor(stats.ElapsedTime) .. "s total.",
                    Duration = 6,
                })
                -- Clear the cached blueprint after use
                _lastValidatedBlueprint = nil
            end
        )

        if not ok then
            Rayfield:Notify({
                Title   = "Build Error",
                Content = tostring(err),
                Duration = 5,
            })
        end
    end,
})

--------------------------------------------------------------------------------
-- §8  CONTROLS TAB
--------------------------------------------------------------------------------
local ControlsTab = Window:CreateTab("🎛️ Controls", nil)

-- ─── Stop Build ─────────────────────────────────────────────────────────────
ControlsTab:CreateButton({
    Name     = "🛑 Emergency Stop",
    Callback = function()
        if Engine.IsBuilding then
            Engine:CancelBuild()
            Rayfield:Notify({
                Title   = "Stopped",
                Content = "Build cancelled. Thread terminated cleanly.",
                Duration = 4,
            })
        else
            Rayfield:Notify({
                Title   = "Idle",
                Content = "No active build to stop.",
                Duration = 3,
            })
        end
    end,
})

-- ─── Reset Engine ───────────────────────────────────────────────────────────
ControlsTab:CreateButton({
    Name     = "🔄 Reset Engine State",
    Callback = function()
        Engine:Reset()
        _lastValidatedBlueprint = nil
        Rayfield:Notify({
            Title   = "Reset",
            Content = "Engine state cleared. Remote cache flushed.",
            Duration = 4,
        })
    end,
})

-- ─── Max Retries Slider ─────────────────────────────────────────────────────
ControlsTab:CreateSlider({
    Name         = "Max Retries per Block",
    Range        = {1, 10},
    Increment    = 1,
    Suffix       = " retries",
    CurrentValue = 3,
    Flag         = "RetrySlider",
    Callback     = function(value)
        Engine.MaxRetries = value
    end,
})

-- ─── Info Label ─────────────────────────────────────────────────────────────
ControlsTab:CreateLabel("Engine: BuildEngine v6.0 | Adaptive Back-off | Chunked Executor")
ControlsTab:CreateLabel("Compatible: Xeno PC · Delta Mobile · Synapse · Fluxus")

--------------------------------------------------------------------------------
-- §9  INITIALIZATION
--------------------------------------------------------------------------------

-- Auto-fuzz remote on script load (non-blocking)
task.spawn(function()
    task_wait(1)  -- let the game settle
    local ok, msg = Engine:FuzzRemote()
    if ok then
        Rayfield:Notify({
            Title   = "Auto-Detect",
            Content = msg,
            Duration = 4,
        })
    else
        Rayfield:Notify({
            Title   = "Auto-Detect",
            Content = "No build remote found yet. Equip your tool and press '📡 Auto-Detect'.",
            Duration = 6,
        })
    end
end)

Rayfield:Notify({
    Title   = "Pro Architect V6",
    Content = "Framework loaded. Engine + UI ready.",
    Duration = 4,
})
