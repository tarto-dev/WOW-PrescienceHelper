-- Tracker.lua -- resolution, aura scan, range sampling for two raid slots.

local ADDON_NAME, PH = ...
local Tracker = PH.Tracker

PH.slots = PH.slots or {
    [1] = {
        unitID = nil, fullName = nil, resolved = false,
        hasPrescience = false, expirationTime = 0, duration = 0,
        inRange = false,
    },
    [2] = {
        unitID = nil, fullName = nil, resolved = false,
        hasPrescience = false, expirationTime = 0, duration = 0,
        inRange = false,
    },
}

PH.state.isActive = PH.state.isActive or false
PH.Tracker._ranger = PH.Tracker._ranger or CreateFrame("Frame")

local checkRosterDeadline
local scheduleResolve
local rosterDeadline = 0
local rosterPending  = false
local rangeElapsed   = 0.0

-- Numeric spellID, NOT the localised name: IsSpellInRange("Prescience", unit)
-- returns nil on non-enUS clients (deDE / frFR / ...) since the API matches
-- the localised name. The numeric path is locale-independent.
local SPELL_ID_PRESCIENCE = 409311

local function normalizeTarget(s)
    if type(s) ~= "string" or s == "" then return "" end
    if s:find("-", 1, true) then return s end
    return s .. "-" .. GetNormalizedRealmName()
end

local function buildFullName(unit)
    local name, realm = UnitFullName(unit)
    if not name or name == "" then return nil end
    if not realm or realm == "" then
        realm = GetNormalizedRealmName()
    end
    return name .. "-" .. realm
end

local function matchSlot(target, candidate)
    if target == "" or not candidate then return false end
    return target == candidate
end

-- Reset-on-each-event debounce: every roster event pushes the deadline
-- forward; the callback re-arms itself if the deadline moved since arming.
checkRosterDeadline = function()
    local remaining = rosterDeadline - GetTime()
    if remaining > 0.001 then
        C_Timer.After(remaining, checkRosterDeadline)
        return
    end
    rosterPending = false
    Tracker:Resolve()
end

scheduleResolve = function()
    rosterDeadline = GetTime() + 0.2
    if rosterPending then return end
    rosterPending = true
    C_Timer.After(0.2, checkRosterDeadline)
end

local function clearSlot(index)
    local s = PH.slots[index]
    s.unitID, s.fullName, s.resolved = nil, nil, false
    s.hasPrescience, s.expirationTime, s.duration = false, 0, 0
    s.inRange = false
end

-- Activation gates. db may be nil if these run before OnAddonLoaded merges
-- defaults — treat absent flags as false to keep cold boot safe.
local function gateRaid()
    return (PH.db and PH.db.activeRaid == true) and IsInRaid() or false
end

local function gateDungeon()
    return (PH.db and PH.db.activeDungeon == true)
        and IsInGroup() and not IsInRaid() or false
end

-- HELPFUL|PLAYER filter restricts iteration to player-cast auras, bypassing
-- forbidden / "secret" auras applied by raid bosses or other systems — those
-- throw "attempt to compare field 'spellId' (a secret number value tainted by
-- 'PrescienceHelper')" on direct field access. The pcall guard is defense in
-- depth in case an edge aura still slips through.
-- TRACK-02 (no cross-Aug false positives) is enforced by the HELPFUL|PLAYER
-- filter alone: it iterates only auras whose caster is the local player.
local function scanAurasForSlot(slot)
    local s = PH.slots[slot]
    if not s.resolved or not s.unitID then
        return false, 0, 0
    end
    local found, exp, dur = false, 0, 0
    if PH.debug then
        print((PH.prefix .. " scanAurasForSlot[%d] unitID=%s resolved=%s"):format(
            slot, tostring(s.unitID), tostring(s.resolved)))
    end
    local seen = 0
    AuraUtil.ForEachAura(s.unitID, "HELPFUL|PLAYER", nil, function(aura)
        if not aura then return end
        seen = seen + 1
        if PH.debug then
            local okp, sid, su, nm = pcall(function()
                return aura.spellId, tostring(aura.sourceUnit), tostring(aura.name)
            end)
            if okp then
                print((PH.prefix .. "   aura spellId=%s sourceUnit=%s name=%s"):format(
                    tostring(sid), tostring(su), tostring(nm)))
            end
        end
        local ok, isMatch = pcall(function()
            return aura.spellId == SPELL_ID_PRESCIENCE
        end)
        if not ok or not isMatch then return end
        local ok2, e, d = pcall(function() return aura.expirationTime, aura.duration end)
        if not ok2 then return end
        found = true
        exp   = e or 0
        dur   = d or 0
        return true
    end, true)
    if PH.debug then
        print((PH.prefix .. " scanAurasForSlot[%d] seen=%d found=%s exp=%s dur=%s"):format(
            slot, seen, tostring(found), tostring(exp), tostring(dur)))
    end
    return found, exp, dur
end

local function fireAuraDiff(slot, prev)
    local s = PH.slots[slot]
    local changed = (prev.hasPrescience  ~= s.hasPrescience)
                 or (prev.expirationTime ~= s.expirationTime)
                 or (prev.duration       ~= s.duration)
    if changed then
        PH.Core:Fire("PH_AURA_CHANGED", slot)
    end
    if prev.hasPrescience == true and s.hasPrescience == false then
        PH.Core:Fire("PH_PRESCIENCE_DROPPED", slot)
    end
end

-- Rebuilds PH.slots[1] and PH.slots[2] from scratch. Three modes:
--   test:    both slots forced to "player" so icons are placeable solo
--   dungeon: ignores configured pseudos, picks 2 DAMAGER from party1..party4
--   raid:    scans player + raid1..raidN against configured pseudos
function Tracker:Resolve()
    clearSlot(1)
    clearSlot(2)

    if PH.db and PH.db.test == true then
        local selfName = buildFullName("player")
        for i = 1, 2 do
            local s = PH.slots[i]
            s.unitID   = "player"
            s.fullName = selfName
            s.resolved = true
        end
        if PH.debug then
            print((PH.prefix .. " Tracker:Resolve test-mode slots=%s"):format(tostring(selfName)))
        end
        PH.Core:Fire("PH_CACHE_REBUILT")
        if PH.state.isActive then
            Tracker:ScanAuras()
        end
        return
    end

    if not PH.state.isActive then
        if PH.debug then
            print(PH.prefix .. " Tracker:Resolve inactive -- slots cleared")
        end
        PH.Core:Fire("PH_CACHE_REBUILT")
        return
    end

    -- Dungeon mode: pull 2 DPS from the live party roster. The local player is
    -- excluded by definition (party1..party4 lists OTHERS). If <2 DPS are
    -- detectable (queue-pop, partial group), unfilled slots stay cleared.
    if gateDungeon() then
        local found = 0
        for i = 1, 4 do
            if found >= 2 then break end
            local unit = "party" .. i
            if UnitExists(unit) and UnitGroupRolesAssigned(unit) == "DAMAGER" then
                local fullName = buildFullName(unit)
                if fullName then
                    found = found + 1
                    local s = PH.slots[found]
                    s.unitID, s.fullName, s.resolved = unit, fullName, true
                end
            end
        end
        if PH.debug then
            print((PH.prefix .. " Tracker:Resolve dungeon-mode found=%d slots=%s,%s"):format(
                found, tostring(PH.slots[1].fullName), tostring(PH.slots[2].fullName)))
        end
        PH.Core:Fire("PH_CACHE_REBUILT")
        if PH.state.isActive then
            Tracker:ScanAuras()
        end
        return
    end

    local target1 = normalizeTarget(PH.db and PH.db.player1 or "")
    local target2 = normalizeTarget(PH.db and PH.db.player2 or "")

    local resolved1 = (target1 == "")
    local resolved2 = (target2 == "")

    local function tryCandidate(unit)
        local fullName = buildFullName(unit)
        if not fullName then return end
        if not resolved1 and matchSlot(target1, fullName) then
            local s = PH.slots[1]
            s.unitID, s.fullName, s.resolved = unit, fullName, true
            resolved1 = true
        end
        if not resolved2 and matchSlot(target2, fullName) then
            local s = PH.slots[2]
            s.unitID, s.fullName, s.resolved = unit, fullName, true
            resolved2 = true
        end
    end

    tryCandidate("player")
    if not (resolved1 and resolved2) then
        local n = GetNumGroupMembers()
        for i = 1, n do
            if resolved1 and resolved2 then break end
            tryCandidate("raid" .. i)
        end
    end

    if PH.debug then
        print((PH.prefix .. " Tracker:Resolve slot1=%s slot2=%s"):format(
            tostring(PH.slots[1].unitID), tostring(PH.slots[2].unitID)))
    end
    PH.Core:Fire("PH_CACHE_REBUILT")

    -- Prime aura state for newly-resolved slots without waiting for the next
    -- UNIT_AURA tick. PH_CACHE_REBUILT already fired so subsequent
    -- PH_AURA_CHANGED / PH_PRESCIENCE_DROPPED arrive in order.
    if PH.state.isActive then
        Tracker:ScanAuras()
    end
end

-- Single choke point for active <-> inactive transitions. Fires PH_ACTIVATED
-- / PH_DEACTIVATED BEFORE mutating cache state so subscribers observe the
-- edge first. Combined gate: test OR raid OR dungeon (any toggle is enough).
function Tracker:UpdateActivation()
    local testOn = (PH.db and PH.db.test == true)
    local now = testOn or gateRaid() or gateDungeon()
    if now == PH.state.isActive then return end

    if now then
        PH.Core:Fire("PH_ACTIVATED")
        PH.state.isActive = true
        rangeElapsed = 0
        PH.Tracker._ranger:SetScript("OnUpdate", function(_, elapsed)
            Tracker:TickRange(elapsed)
        end)
        Tracker:Resolve()
    else
        PH.Core:Fire("PH_DEACTIVATED")
        PH.state.isActive = false
        PH.Tracker._ranger:SetScript("OnUpdate", nil)
        clearSlot(1)
        clearSlot(2)
        PH.Core:Fire("PH_CACHE_REBUILT")
    end
end

function Tracker:OnPlayerEnteringWorld(event, ...)
    if PH.debug then
        print((PH.prefix .. " Tracker:%s (count=%d)"):format(event, PH.state.counters[event] or 0))
    end
    -- Login-in-raid edge: must populate the cache even without a subsequent
    -- GROUP_ROSTER_UPDATE. UpdateActivation calls Resolve on a cold transition;
    -- if we were already active (e.g. /reload mid-raid), force a Resolve too.
    local wasActive = PH.state.isActive
    Tracker:UpdateActivation()
    if wasActive and PH.state.isActive then
        Tracker:Resolve()
    end
end

function Tracker:OnGroupUpdate(event, ...)
    if PH.debug then
        print((PH.prefix .. " Tracker:%s (count=%d)"):format(event, PH.state.counters[event] or 0))
    end
    Tracker:UpdateActivation()
    if PH.state.isActive then
        scheduleResolve()
    end
end

function Tracker:OnDbReady(event)
    if PH.debug then
        print((PH.prefix .. " Tracker:%s"):format(event))
    end
    Tracker:UpdateActivation()
end

function Tracker:OnTestModeChanged(event)
    if PH.debug then
        print((PH.prefix .. " Tracker:%s"):format(event))
    end
    Tracker:UpdateActivation()
    if PH.state.isActive then
        Tracker:Resolve()
    end
end

function Tracker:OnActiveGateChanged(event)
    if PH.debug then
        print((PH.prefix .. " Tracker:%s"):format(event))
    end
    Tracker:UpdateActivation()
    if PH.state.isActive then
        Tracker:Resolve()
    end
end

function Tracker:OnUnitAura(event, unitTarget, updateInfo)
    if PH.debug then
        print((PH.prefix .. " OnUnitAura unit=%s isActive=%s"):format(
            tostring(unitTarget), tostring(PH.state.isActive)))
    end
    if not PH.state.isActive then return end
    Tracker:ScanAuras()
end

function Tracker:ScanAuras()
    if not PH.state.isActive then return end
    for slot = 1, 2 do
        local s = PH.slots[slot]
        local prev = {
            hasPrescience  = s.hasPrescience,
            expirationTime = s.expirationTime,
            duration       = s.duration,
        }
        local has, exp, dur = scanAurasForSlot(slot)
        s.hasPrescience, s.expirationTime, s.duration = has, exp, dur
        fireAuraDiff(slot, prev)
    end
end

-- 10Hz range sampling, throttled by accumulator. PH_RANGE_CHANGED fires only
-- on the boolean flip, never on steady state.
function Tracker:TickRange(elapsed)
    if not PH.state.isActive then return end
    rangeElapsed = rangeElapsed + elapsed
    if rangeElapsed < 0.1 then return end
    rangeElapsed = 0
    for slot = 1, 2 do
        local s = PH.slots[slot]
        if s.resolved and s.unitID then
            local result = C_Spell.IsSpellInRange(SPELL_ID_PRESCIENCE, s.unitID)
            local newInRange = (result == true)
            if newInRange ~= s.inRange then
                s.inRange = newInRange
                PH.Core:Fire("PH_RANGE_CHANGED", slot)
            end
        end
    end
end

-- Debug-gated trace: prints when the player casts Prescience on a tracked slot.
function Tracker:OnSpellcastSent(event, unit, target, castGUID, spellID)
    if unit ~= "player" then return end
    if spellID ~= SPELL_ID_PRESCIENCE then return end
    if not PH.debug then return end
    if not target or target == "" then return end
    for slot = 1, 2 do
        if PH.slots[slot].fullName == target then
            print((PH.prefix .. " Macro %d utilisee sur %s"):format(slot, target))
            return
        end
    end
end

PH.Core:RegisterEvent("UNIT_AURA",              PH.Tracker, "OnUnitAura")
PH.Core:RegisterEvent("PH_DB_READY",            PH.Tracker, "OnDbReady")
PH.Core:RegisterEvent("PH_TEST_MODE_CHANGED",   PH.Tracker, "OnTestModeChanged")
PH.Core:RegisterEvent("UNIT_SPELLCAST_SENT",    PH.Tracker, "OnSpellcastSent")
PH.Core:RegisterEvent("PLAYER_ROLES_ASSIGNED",  PH.Tracker, "OnGroupUpdate")
PH.Core:RegisterEvent("PH_ACTIVE_GATE_CHANGED", PH.Tracker, "OnActiveGateChanged")
