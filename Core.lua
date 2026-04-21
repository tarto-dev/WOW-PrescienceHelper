-- Core.lua -- namespace, event dispatcher, DB bootstrap.

local ADDON_NAME, PH = ...

PH.Core    = PH.Core    or {}
PH.Tracker = PH.Tracker or {}
PH.UI      = PH.UI      or {}
PH.Config  = PH.Config  or {}

-- Chat-line prefix: light-red brackets + light-green PH so addon output
-- stands out from raid spam. Single source of truth for the palette.
PH.prefix = "|cFFFF6666[|r|cFF66FF66PH|r|cFFFF6666]|r"
PH.debug = false
PH.state = PH.state or { counters = {} }

-- One hidden frame owns every WoW OnEvent. Subscriptions are { module, methodName }
-- pairs per event; dispatch order = registration order. Synthetic PH_* events
-- bypass the WoW registration so Fire() pushes them through the same path.
PH.Core._dispatcher    = PH.Core._dispatcher    or CreateFrame("Frame")
PH.Core._subscriptions = PH.Core._subscriptions or {}

local function dispatch(event, ...)
    local list = PH.Core._subscriptions[event]
    if not list then return end
    PH.state.counters[event] = (PH.state.counters[event] or 0) + 1
    if PH.debug then
        print((PH.prefix .. " Event: %s"):format(event))
    end
    for i = 1, #list do
        local sub = list[i]
        sub.module[sub.methodName](sub.module, event, ...)
    end
end

function PH.Core:RegisterEvent(event, module, methodName)
    assert(type(event) == "string", "event must be a string")
    assert(type(module) == "table", "module must be a table")
    assert(type(methodName) == "string", "methodName must be a string")
    local subs = PH.Core._subscriptions
    if not subs[event] then
        subs[event] = {}
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

local DB_DEFAULTS = {
    schema = 1,
    player1 = "",
    player2 = "",
    lock = false,
    test = false,
    soundEnabled = true,
    debug = false,
    activeRaid = true,
    activeDungeon = false,
    anchors = {
        [1] = { point = "CENTER", relPoint = "CENTER", x = -60, y = 0 },
        [2] = { point = "CENTER", relPoint = "CENTER", x =  60, y = 0 },
    },
}

-- Deep additive merge: fills missing keys at any depth without overwriting
-- existing user values. CopyTable clones default subtables so user DB entries
-- never alias the defaults.
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

function PH.Core:OnAddonLoaded(event, loadedAddon)
    if loadedAddon ~= ADDON_NAME then return end
    PrescienceHelperDB = PrescienceHelperDB or {}
    Merge(DB_DEFAULTS, PrescienceHelperDB)
    PH.db = PrescienceHelperDB
    -- Mirror persisted debug into the cached flag so prints honor user
    -- preference from login. Config's debug toggle keeps both in sync live.
    PH.debug = PH.db.debug and true or false
    if PH.debug then
        print(PH.prefix .. " DB initialized.")
    end
    PH.Core:Fire("PH_DB_READY")
end

PH.Core:RegisterEvent("ADDON_LOADED", PH.Core, "OnAddonLoaded")

SLASH_PH1 = "/ph"
SLASH_PH2 = "/prescience"
SlashCmdList["PH"] = function(msg)
    PH.Config:Open(msg)
end

PH.Core:RegisterEvent("PLAYER_ENTERING_WORLD", PH.Tracker, "OnPlayerEnteringWorld")
PH.Core:RegisterEvent("GROUP_ROSTER_UPDATE",   PH.Tracker, "OnGroupUpdate")
