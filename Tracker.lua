-- Tracker.lua -- Resolution, aura scan, range sampling for two configurable raid slots.
--
-- Phase 2 scope (complete): slot struct, activation state machine (raid-gated +
-- test override), cross-realm resolution scan with reset-on-event debounce,
-- HELPFUL aura scan via AuraUtil.ForEachAura, and 10Hz range sampling via a
-- dedicated hidden frame's OnUpdate. All downstream consumers (Phase 3 UI/sound,
-- Phase 4 config) subscribe to PH_* events fired by this module.
local ADDON_NAME, PH = ...

local Tracker = PH.Tracker

-- 1. Slot state (D-01, D-02, D-03) -------------------------------------------
-- PH.slots is the single source of truth for all downstream consumers. Two
-- fixed integer-keyed entries (1 and 2), each holding the full 3-layer state:
-- resolution (unitID / fullName / resolved), aura (hasPrescience / expirationTime
-- / duration), range (inRange). The idempotent `or { ... }` idiom protects
-- against module reload while keeping the init readable.
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

-- 2. Activation state + range frame (D-11, D-27) -----------------------------
-- PH.state.isActive is the cached raid-activation flag; the raid-presence
-- check is performed only from UpdateActivation() so every other code path
-- treats the flag as the single source of truth (D-11). _ranger is the
-- dedicated hidden frame that drives the 10Hz range sampling (D-27); its
-- OnUpdate body is installed / torn down by UpdateActivation's transition
-- branches so it costs zero CPU outside an active session.
PH.state.isActive = PH.state.isActive or false
PH.Tracker._ranger = PH.Tracker._ranger or CreateFrame("Frame")

-- 3. Local helpers: resolution + debounce + aura (D-18..D-26, RESOLVE-01..04, TRACK-01..04)
-- All upvalues stay module-local to keep the namespace clean; only the public
-- methods on PH.Tracker cross the module boundary. `checkRosterDeadline` and
-- `scheduleResolve` are forward-declared so they can close over each other.
local checkRosterDeadline
local scheduleResolve

-- Debounce state for GROUP_ROSTER_UPDATE coalescing (RESOLVE-05, D-21, D-22).
-- `rosterDeadline` is a GetTime() timestamp that every new event pushes forward;
-- the callback re-arms itself if the deadline has been extended since arming,
-- implementing reset-on-each-event without ever cancelling a C_Timer.
local rosterDeadline = 0
local rosterPending  = false

-- Accumulator for 10Hz range throttle (RANGE-02, D-28). Incremented by every
-- OnUpdate tick; when it crosses the 0.1s threshold we sample IsSpellInRange
-- and reset back to 0. Reset is also performed on each transition-to-active in
-- UpdateActivation so a fresh activation never inherits a stale window.
local rangeElapsed = 0.0

-- Prescience spellID. Used both by the aura scan (match predicate TRACK-02) and
-- by the range sampler (C_Spell.IsSpellInRange). Passing the numeric ID instead
-- of the localised spell name is critical: IsSpellInRange("Prescience", unit)
-- returns nil on non-enUS clients (deDE / frFR / ...) because the API matches
-- the localised name. The addon ships frFR Notes, so we MUST use the ID path.
local SPELL_ID_PRESCIENCE = 409311

-- Normalize a user-supplied player string: strings already containing "-Realm"
-- are left untouched; bare "Name" gets the local realm appended via
-- GetNormalizedRealmName() (RESOLVE-01, RESOLVE-02). Empty string is returned
-- as-is so callers can detect the no-op case (D-20).
local function normalizeTarget(s)
    if type(s) ~= "string" or s == "" then return "" end
    if s:find("-", 1, true) then return s end
    return s .. "-" .. GetNormalizedRealmName()
end

-- Reconstruct the canonical "Name-Realm" string for a given unit token
-- ("player" or "raidN"). UnitFullName returns realm=nil for same-realm players,
-- in which case we substitute GetNormalizedRealmName() (RESOLVE-04). Returns
-- nil for units that fail to resolve (freshly joined member with no data yet).
local function buildFullName(unit)
    local name, realm = UnitFullName(unit)
    if not name or name == "" then return nil end
    if not realm or realm == "" then
        realm = GetNormalizedRealmName()
    end
    return name .. "-" .. realm
end

-- Exact string compare between normalized target and candidate fullName (D-19).
-- WoW names are case-locked server-side so we do not lowercase.
local function matchSlot(target, candidate)
    if target == "" or not candidate then return false end
    return target == candidate
end

-- Deadline re-check callback (D-22 reset-on-event). If another roster event
-- arrived between arming and firing, rosterDeadline has been pushed forward
-- and we simply re-arm for the remaining window instead of resolving yet.
checkRosterDeadline = function()
    local remaining = rosterDeadline - GetTime()
    if remaining > 0.001 then
        C_Timer.After(remaining, checkRosterDeadline)
        return
    end
    rosterPending = false
    Tracker:Resolve()
end

-- Schedule (or extend) a resolve after the 0.2s quiet window. Each call pushes
-- the deadline forward; only the first call arms a timer -- subsequent calls
-- piggyback on the re-arming loop inside checkRosterDeadline.
scheduleResolve = function()
    rosterDeadline = GetTime() + 0.2
    if rosterPending then return end
    rosterPending = true
    C_Timer.After(0.2, checkRosterDeadline)
end

-- Reset a single slot back to its default (unresolved) struct. Used by both
-- the transition-to-inactive branch of UpdateActivation (D-12 step 4) and as
-- the opening step of Resolve() so the scan always starts from a clean slate.
local function clearSlot(index)
    local s = PH.slots[index]
    s.unitID, s.fullName, s.resolved = nil, nil, false
    s.hasPrescience, s.expirationTime, s.duration = false, 0, 0
    s.inRange = false
end

-- Aura helpers (D-23..D-26, TRACK-01..04) ------------------------------------
-- Prescience spell id kept as a magic number adjacent to its only call site;
-- naming it a top-level constant is unwarranted for a single use. The
-- sourceUnit filter is the critical guard against false positives in a raid
-- with multiple Augmentation Evokers (TRACK-02): only Prescience cast by the
-- local player should light up our slot state.

-- Returns (hasPrescience, expirationTime, duration) from a player-cast HELPFUL
-- scan on the slot's unitID. Matches aura.spellId == 409311 AND aura.sourceUnit
-- == "player". Returns false/0/0 if the slot is unresolved or no match is found.
-- `usePackedAura=true` (D-25) gives us a packed AuraData table; iteration is
-- aborted on first match to save a handful of callback invocations per scan
-- (claude's discretion -- behavior identical either way).
--
-- Filter "HELPFUL|PLAYER" restricts iteration to auras cast by the player,
-- bypassing forbidden/secret auras applied by raid bosses or other systems --
-- those would throw "attempt to compare field 'spellId' (a secret number value
-- tainted by 'PrescienceHelper')" on direct field access. The pcall guard is
-- defense in depth: even with the PLAYER filter, certain edge auras may still
-- expose forbidden fields, so every aura read is wrapped.
local function scanAurasForSlot(slot)
    local s = PH.slots[slot]
    if not s.resolved or not s.unitID then
        return false, 0, 0
    end
    local found, exp, dur = false, 0, 0
    AuraUtil.ForEachAura(s.unitID, "HELPFUL|PLAYER", nil, function(aura)
        if not aura then return end
        local ok, isMatch = pcall(function()
            return aura.spellId == SPELL_ID_PRESCIENCE and aura.sourceUnit == "player"
        end)
        if not ok or not isMatch then return end
        local ok2, e, d = pcall(function() return aura.expirationTime, aura.duration end)
        if not ok2 then return end
        found = true
        exp   = e or 0
        dur   = d or 0
        return true  -- abort iteration once our Prescience is found
    end, true)
    return found, exp, dur
end

-- Fires the diff events for a slot AFTER its aura fields have been mutated to
-- the new values. `prev` is a snapshot captured BEFORE the mutation. Per D-26,
-- PH_AURA_CHANGED fires on any field delta; PH_PRESCIENCE_DROPPED fires only
-- on the true->false transition of hasPrescience. Event order per D-10:
-- AURA_CHANGED first, then PRESCIENCE_DROPPED within the same tick.
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

-- 4. Resolution scan (RESOLVE-01..06, D-15..D-22) ----------------------------
-- Tracker:Resolve rebuilds PH.slots[1] and PH.slots[2] from scratch. Three
-- mutually exclusive paths:
--   1. Test mode override (D-15, D-16): both slots forced to "player".
--   2. Not in raid (RESOLVE-03): slots stay cleared -- benign no-op.
--   3. In raid: scan "player" then "raid1..raidN" (D-18), first-match-wins
--      per slot (RESOLVE-04, D-19). Empty target strings are silently skipped
--      (D-20). Both slots share the same candidate walk to keep the cost at
--      a single O(N) iteration over the group.
-- After mutation we fire PH_CACHE_REBUILT (D-04) so downstream consumers
-- re-read PH.slots on their own terms.
function Tracker:Resolve()
    -- Always start from a clean slate; this also covers the "roster shrank,
    -- previously resolved slot no longer present" case.
    clearSlot(1)
    clearSlot(2)

    if PH.db and PH.db.test == true then
        -- Test override: both slots point at the local player so Phase 3 icons
        -- can be positioned and validated out of raid (D-15, D-16).
        local selfName = buildFullName("player")
        for i = 1, 2 do
            local s = PH.slots[i]
            s.unitID   = "player"
            s.fullName = selfName
            s.resolved = true
        end
        if PH.debug then
            print(("[PH] Tracker:Resolve test-mode slots=%s"):format(tostring(selfName)))
        end
        PH.Core:Fire("PH_CACHE_REBUILT")
        -- Prime aura state in test mode too so downstream consumers see the full
        -- 6-event contract on test-toggle-on without waiting for the next
        -- UNIT_AURA tick (mirrors the live-branch ordering at the end of Resolve;
        -- D-16: test mode forces isActive=true so the gate here is a defensive
        -- parity with the live path, not a raid-state check).
        if PH.state.isActive then
            Tracker:ScanAuras()
        end
        return
    end

    if not PH.state.isActive then
        -- Not active (not in raid, and test is off -- see D-11 invariant held
        -- by UpdateActivation): leave both slots cleared (RESOLVE-03). We
        -- still fire PH_CACHE_REBUILT so subscribers can react uniformly.
        -- Reading isActive here (not the raid check) enforces D-11.
        if PH.debug then
            print("[PH] Tracker:Resolve inactive -- slots cleared")
        end
        PH.Core:Fire("PH_CACHE_REBUILT")
        return
    end

    local target1 = normalizeTarget(PH.db and PH.db.player1 or "")
    local target2 = normalizeTarget(PH.db and PH.db.player2 or "")

    local resolved1 = (target1 == "")
    local resolved2 = (target2 == "")

    -- Candidate walk: "player" first, then raid1..raidN. First match per slot
    -- wins (D-18, D-19). Both slots may resolve to the same unit (user error)
    -- or to distinct units.
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
        print(("[PH] Tracker:Resolve slot1=%s slot2=%s"):format(
            tostring(PH.slots[1].unitID), tostring(PH.slots[2].unitID)))
    end
    PH.Core:Fire("PH_CACHE_REBUILT")

    -- Prime aura state for newly-resolved slots without waiting for the next
    -- UNIT_AURA tick (D-09, D-10). PH_CACHE_REBUILT has already fired, so the
    -- subsequent PH_AURA_CHANGED / PH_PRESCIENCE_DROPPED events arrive in the
    -- correct order for downstream consumers. Gate on isActive so test-toggle-
    -- off transitions (UpdateActivation routed through Resolve) do not scan.
    if PH.state.isActive then
        Tracker:ScanAuras()
    end
end

-- 5. Activation state machine (D-11..D-14, ACTIV-01, ACTIV-03) ---------------
-- Single choke point for the raid <-> non-raid transition. Callers from event
-- handlers always route through here; the raid-presence probe is consulted
-- nowhere else in the module. PH_ACTIVATED and PH_DEACTIVATED are fired BEFORE the cache
-- mutation they gate (D-10) so subscribers observe the transition edge first
-- and only then read the new slot state.
function Tracker:UpdateActivation()
    -- Test mode bypasses the raid gate entirely (D-16): Phase 3 icons must be
    -- placeable even when solo. db may legitimately be nil if this runs before
    -- OnAddonLoaded merges defaults, in which case we treat test as false.
    local testOn = (PH.db and PH.db.test == true)
    local now = testOn or IsInRaid()
    if now == PH.state.isActive then return end

    if now then
        PH.Core:Fire("PH_ACTIVATED")
        PH.state.isActive = true
        -- Fresh activation: reset the 10Hz accumulator so a new raid never
        -- inherits a stale window from a previous session, then install the
        -- OnUpdate callback on the dedicated frame (D-13, D-27, D-30). The
        -- closure delegates to Tracker:TickRange so the throttle logic stays
        -- testable / callable from other sites.
        rangeElapsed = 0
        PH.Tracker._ranger:SetScript("OnUpdate", function(_, elapsed)
            Tracker:TickRange(elapsed)
        end)
        Tracker:Resolve()
    else
        PH.Core:Fire("PH_DEACTIVATED")
        PH.state.isActive = false
        -- Stop any OnUpdate installed by a prior transition (D-13 idle-complete).
        PH.Tracker._ranger:SetScript("OnUpdate", nil)
        clearSlot(1)
        clearSlot(2)
        PH.Core:Fire("PH_CACHE_REBUILT")
    end
end

-- 6. Event handlers (D-14, D-31) ---------------------------------------------
-- These handlers are transition sources: they must run UpdateActivation()
-- BEFORE applying the defense-in-depth gate, otherwise we could never enter
-- the active state from an inactive baseline. The D-14 gate belongs on
-- consumer-side handlers (aura, range) that will be added by Plans 02-02/03.

-- Dispatcher-invoked: registered in Core.lua with "OnPlayerEnteringWorld".
-- RESOLVE-06: login in raid must populate the cache even without a subsequent
-- GROUP_ROSTER_UPDATE. We call UpdateActivation first (which itself calls
-- Resolve on a cold transition); if we were already active (rare edge: PEW
-- fires while isActive is already true after a /reload mid-raid), we force a
-- Resolve anyway so the slots reflect the current roster.
function Tracker:OnPlayerEnteringWorld(event, ...)
    if PH.debug then
        print(("[PH] Tracker:%s (count=%d)"):format(event, PH.state.counters[event] or 0))
    end
    local wasActive = PH.state.isActive
    Tracker:UpdateActivation()
    if wasActive and PH.state.isActive then
        Tracker:Resolve()
    end
end

-- Dispatcher-invoked: registered in Core.lua with "OnGroupUpdate".
-- Roster deltas can mean raid<->party transition or internal reshuffle; the
-- UpdateActivation call handles the first case, the debounced scheduleResolve
-- handles the second. If the transition took us inactive, do not schedule --
-- we just left the raid and Resolve would be a no-op anyway.
function Tracker:OnGroupUpdate(event, ...)
    if PH.debug then
        print(("[PH] Tracker:%s (count=%d)"):format(event, PH.state.counters[event] or 0))
    end
    Tracker:UpdateActivation()
    if PH.state.isActive then
        scheduleResolve()
    end
end

-- Synthetic: fired by Core.lua after the DB merge completes. First-boot prime
-- of the activation state machine -- do not call Resolve directly, because
-- UpdateActivation will call it during any cold transition to active.
function Tracker:OnDbReady(event)
    if PH.debug then
        print(("[PH] Tracker:%s"):format(event))
    end
    Tracker:UpdateActivation()
end

-- Synthetic: Phase 4 toggles PH.db.test then fires this event (D-17). We need
-- both UpdateActivation (to flip isActive when toggling on/off out of raid)
-- and Resolve (to repopulate slots if isActive was already true and did not
-- transition). Calling UpdateActivation first is safe: it calls Resolve on
-- transition, and we still call Resolve unconditionally below for the
-- already-active case. Double Resolve on cold transitions is cheap.
function Tracker:OnTestModeChanged(event)
    if PH.debug then
        print(("[PH] Tracker:%s"):format(event))
    end
    Tracker:UpdateActivation()
    if PH.state.isActive then
        Tracker:Resolve()
    end
end

-- Dispatcher-invoked: registered at the bottom of this file with "OnUnitAura".
-- Consumer-side handler: D-14 defense-in-depth gate applies (unlike the four
-- transition-source handlers above). UNIT_AURA is registered unconditionally
-- (D-24) so we can fire even before a roster resolve has run; the gate keeps
-- idle (non-raid, non-test) sessions at zero CPU cost. Payload is ignored per
-- D-23: the cost of rescanning 2 units is trivial compared to the branching
-- needed to filter on updateInfo.
function Tracker:OnUnitAura(event, unitTarget, updateInfo)
    if not PH.state.isActive then return end
    Tracker:ScanAuras()
end

-- 7. Aura scan method (TRACK-01..04, D-23..D-26) -----------------------------
-- Full 2-slot rescan. Captures a prev snapshot per slot (3 aura fields only),
-- mutates PH.slots[slot] from the fresh AuraUtil scan, then dispatches diff
-- events via fireAuraDiff. The D-14 defense-in-depth gate is duplicated here
-- even though all current call sites (OnUnitAura + Resolve post-mutation)
-- already gate: keeps the method safe to call from any future site without
-- leaking a scan into an idle session.
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

-- 8. Range sampling method (RANGE-01..03, D-27..D-30) ------------------------
-- Driven by the _ranger frame's OnUpdate (installed in UpdateActivation's
-- transition-to-active branch). Accumulator throttles the sampling to ~10Hz
-- (RANGE-02, D-28): every OnUpdate call adds `elapsed` to rangeElapsed; when
-- we cross 0.1s we sample IsSpellInRange for each resolved slot and reset.
--
-- D-14 defense-in-depth: guarded by isActive at entry. Redundant with the
-- SetScript(nil) stop in the transition-to-inactive branch (which drops the
-- callback entirely, D-13), but keeps TickRange safe to call from any future
-- site (debug harness, manual /run) without leaking work into idle sessions.
--
-- D-30: the tick continues even when both slots are unresolved -- the
-- per-slot guard (`s.resolved and s.unitID`) makes those iterations trivial
-- no-ops and we avoid start/stop churn on every resolve/unresolve transition.
-- D-29: C_Spell.IsSpellInRange returns true / false / nil; we collapse non-true
-- to false. We use the numeric spellID (not the localised name) so the range
-- check works on any client locale (frFR, deDE, etc.).
-- PH_RANGE_CHANGED fires exclusively on the boolean flip, never on steady state.
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

-- 9. Event registrations (D-31) ----------------------------------------------
-- Phase 1 already wired PLAYER_ENTERING_WORLD and GROUP_ROSTER_UPDATE from
-- Core.lua; we do not redeclare them here. Phase 2 adds UNIT_AURA for aura
-- tracking (TRACK-03, D-24 unconditional) plus the two synthetic events the
-- Tracker needs to prime itself (PH_DB_READY) and to react to the Phase 4
-- test toggle (PH_TEST_MODE_CHANGED).
PH.Core:RegisterEvent("UNIT_AURA",            PH.Tracker, "OnUnitAura")
PH.Core:RegisterEvent("PH_DB_READY",          PH.Tracker, "OnDbReady")
PH.Core:RegisterEvent("PH_TEST_MODE_CHANGED", PH.Tracker, "OnTestModeChanged")
