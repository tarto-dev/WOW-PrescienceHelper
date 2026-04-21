-- Core.lua -- PrescienceHelper foundation: namespace, event dispatcher, DB bootstrap.
--
-- Exposes the PH table (shared via varargs `...`) to Tracker/UI/Config. Owns the
-- centralized event dispatcher (WoW events + internal PH_* pub/sub), bootstraps
-- PrescienceHelperDB with deep-merged defaults, and registers the /ph /prescience
-- slash commands. Zero global leak beyond the sanctioned SLASH_* and SavedVariable
-- globals the WoW protocol requires.

local ADDON_NAME, PH = ...

-- 1. Namespace root (BOOT-02) -------------------------------------------------
-- Every module table is created here so that Core.lua can safely reference
-- PH.Tracker / PH.UI / PH.Config when wiring test events below, even before the
-- actual module files load. Downstream files (Tracker.lua, UI.lua, Config.lua)
-- attach their methods to these same tables via the `or {}` idempotent idiom.
PH.Core    = PH.Core    or {}
PH.Tracker = PH.Tracker or {}
PH.UI      = PH.UI      or {}
PH.Config  = PH.Config  or {}

-- 2. Debug infrastructure (D-10, D-11, D-12) ---------------------------------
-- Permanent infrastructure, not Phase 1 scaffolding. `PH.debug` gates verbose
-- prints; `PH.state.counters` tracks dispatch counts per event and is inspected
-- via `/dump PH.state` in-game.
--
-- Phase 5 polish: `PH.prefix` is the canonical chat-line prefix used by every
-- addon-originated print across Core/Tracker/UI/Config. Colors the brackets
-- in light red (|cFFFF6666) and the "PH" glyphs in light green (|cFF66FF66)
-- so addon output stands out from raid chat spam without needing chat-filter
-- rules. Every `print(PH.prefix .. "...")` site uses `PH.prefix .. " ..."` instead,
-- so changing the palette here is a one-line edit.
PH.prefix = "|cFFFF6666[|r|cFF66FF66PH|r|cFFFF6666]|r"
PH.debug = false
PH.state = PH.state or { counters = {} }

-- 3. Event dispatcher (D-01..D-05, BOOT-04) ----------------------------------
-- Single hidden frame owns all WoW OnEvent callbacks. Subscriptions are stored
-- per-event as an array of { module, methodName } pairs; dispatch order equals
-- registration order (D-04). Internal PH_* events bypass the WoW registration
-- call so Fire() can push them through the same subscription path (D-03).
PH.Core._dispatcher    = PH.Core._dispatcher    or CreateFrame("Frame")
PH.Core._subscriptions = PH.Core._subscriptions or {}

-- Shared dispatch loop used by both the OnEvent bridge and the Fire API.
-- Factored out so the two call sites stay in lockstep; any future change
-- (error handling, tracing) lands in exactly one place.
local function dispatch(event, ...)
    local list = PH.Core._subscriptions[event]
    if not list then return end
    PH.state.counters[event] = (PH.state.counters[event] or 0) + 1
    if PH.debug then
        print((PH.prefix .. " Event: %s"):format(event))
    end
    for i = 1, #list do
        local sub = list[i]
        local module, methodName = sub.module, sub.methodName
        module[methodName](module, event, ...)
    end
end

function PH.Core:RegisterEvent(event, module, methodName)
    assert(type(event) == "string", "event must be a string")
    assert(type(module) == "table", "module must be a table")
    assert(type(methodName) == "string", "methodName must be a string")
    local subs = PH.Core._subscriptions
    if not subs[event] then
        subs[event] = {}
        -- Only register with WoW if this is a real WoW event.
        -- Synthetic PH_* events are internal-only and never touch the client.
        if not event:match("^PH_") then
            PH.Core._dispatcher:RegisterEvent(event)
        end
    end
    table.insert(subs[event], { module = module, methodName = methodName })
end

function PH.Core:Fire(event, ...)
    dispatch(event, ...)
end

PH.Core._dispatcher:SetScript("OnEvent", function(_, event, ...)
    dispatch(event, ...)
end)

-- 4. DB defaults + Merge helper (D-07, D-08, D-09) ---------------------------
-- `schema = 1` is seeded on first load. Future v2 bumps will insert a migration
-- branch in the ADDON_LOADED handler BEFORE the Merge call; the slot is reserved
-- here for that forward contract (D-09).
local DB_DEFAULTS = {
    schema = 1,
    player1 = "",
    player2 = "",
    lock = false,
    test = false,
    soundEnabled = true,
    debug = false,
    anchors = {
        [1] = { point = "CENTER", relPoint = "CENTER", x = -60, y = 0 },
        [2] = { point = "CENTER", relPoint = "CENTER", x =  60, y = 0 },
    },
}

-- Deep, additive merge: fills missing keys at any nesting depth without ever
-- overwriting existing user values. `CopyTable` (WoW built-in) clones default
-- sub-tables so user DB entries never alias the defaults table.
local function Merge(default, db)
    for k, v in pairs(default) do
        if db[k] == nil then
            db[k] = (type(v) == "table") and CopyTable(v) or v
        elseif type(v) == "table" and type(db[k]) == "table" then
            Merge(v, db[k])
        end
    end
    return db
end

-- 5. ADDON_LOADED handler: merge DB, then fire bootstrap (BOOT-03) -----------
function PH.Core:OnAddonLoaded(event, loadedAddon)
    if loadedAddon ~= ADDON_NAME then return end
    PrescienceHelperDB = PrescienceHelperDB or {}
    -- (Future: schema migration goes here, before Merge, when schema > 1 appears.)
    Merge(DB_DEFAULTS, PrescienceHelperDB)
    PH.db = PrescienceHelperDB
    -- Sync the cached `PH.debug` flag with the persisted `PH.db.debug` toggle so
    -- gated prints in Tracker/UI/Config see the user's last choice as soon as
    -- the DB is ready. Config's debug CheckButton OnClick handler also rewrites
    -- PH.debug whenever the toggle flips so live changes propagate without /reload.
    PH.debug = PH.db.debug and true or false
    if PH.debug then
        print(PH.prefix .. " DB initialized.")
    end
    -- Forward contract: downstream phases can subscribe to PH_DB_READY for a
    -- deterministic hook after defaults are merged. Phase 1 has no subscribers.
    PH.Core:Fire("PH_DB_READY")
end

PH.Core:RegisterEvent("ADDON_LOADED", PH.Core, "OnAddonLoaded")

-- 6. Slash command registration (D-24, D-25, D-26) ---------------------------
-- SLASH_PH1, SLASH_PH2 and SlashCmdList["PH"] are the three sanctioned globals
-- the WoW slash-command protocol requires. Both /ph and /prescience map to the
-- single "PH" key derived from the SLASH_PHn suffix.
SLASH_PH1 = "/ph"
SLASH_PH2 = "/prescience"
SlashCmdList["PH"] = function(msg)
    PH.Config:Open(msg)
end

-- 7. Register test events with dispatcher (D-13, D-14) -----------------------
-- Proves the dispatcher routes real WoW events to module stubs. Plan 03 ships
-- the OnPlayerEnteringWorld / OnGroupUpdate method bodies on PH.Tracker.
PH.Core:RegisterEvent("PLAYER_ENTERING_WORLD", PH.Tracker, "OnPlayerEnteringWorld")
PH.Core:RegisterEvent("GROUP_ROSTER_UPDATE",   PH.Tracker, "OnGroupUpdate")
