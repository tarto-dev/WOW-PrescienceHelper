-- UI.lua -- secure action icons, state rendering, countdown, drag, sound.

local ADDON_NAME, PH = ...
local UI = PH.UI

-- Numeric spellID — same as Tracker — to avoid the localised-name pitfall
-- with C_Spell.GetSpellTexture on non-enUS clients.
local SPELL_ID_PRESCIENCE = 409311

local BORDER_GREY  = { 0.5, 0.5, 0.5, 1.0 }
local BORDER_RED   = { 1.0, 0.2, 0.2, 1.0 }
local BORDER_GREEN = { 0.2, 0.9, 0.2, 1.0 }

local ICON_SIZE        = 48
local BORDER_THICKNESS = 2

-- _root parents both buttons so a single Show()/Hide() flips visibility
-- atomically. MEDIUM strata sits above the world frame, below dialogs.
PH.UI._root = PH.UI._root or CreateFrame("Frame", nil, UIParent)
PH.UI._buttons = PH.UI._buttons or {}

PH.UI._root:SetSize(1, 1)
PH.UI._root:SetFrameStrata("MEDIUM")
PH.UI._root:Hide()

-- Cached combat flag, maintained by PLAYER_REGEN_*. The authoritative source
-- at every secure-attribute call site stays InCombatLockdown(); this flag is
-- a debug handle (/dump PH.state.inCombat).
PH.state.inCombat = PH.state.inCombat or false

local function createButton(slot)
    if PH.UI._buttons[slot] then return PH.UI._buttons[slot] end

    -- Global frame name so other addons (WeakAuras, etc.) can target it.
    local name = "PrescienceHelperIcon" .. slot
    local button = CreateFrame("Button", name, PH.UI._root, "SecureActionButtonTemplate")
    button:SetSize(ICON_SIZE, ICON_SIZE)
    button:SetPoint("CENTER", UIParent, "CENTER", (slot == 1) and -60 or 60, 0)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints(button)
    button.icon:SetTexture(C_Spell.GetSpellTexture(SPELL_ID_PRESCIENCE))

    -- 4 solid-color edge textures rather than a backdrop / nine-slice. Each
    -- edge is repainted by setBorderColor on state changes.
    local function makeEdge()
        local tex = button:CreateTexture(nil, "OVERLAY")
        tex:SetColorTexture(BORDER_GREY[1], BORDER_GREY[2], BORDER_GREY[3], BORDER_GREY[4])
        return tex
    end
    button.borderTop    = makeEdge()
    button.borderBottom = makeEdge()
    button.borderLeft   = makeEdge()
    button.borderRight  = makeEdge()

    button.borderTop:SetPoint("TOPLEFT",  button, "TOPLEFT",  0, 0)
    button.borderTop:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
    button.borderTop:SetHeight(BORDER_THICKNESS)
    button.borderBottom:SetPoint("BOTTOMLEFT",  button, "BOTTOMLEFT",  0, 0)
    button.borderBottom:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    button.borderBottom:SetHeight(BORDER_THICKNESS)
    button.borderLeft:SetPoint("TOPLEFT",    button, "TOPLEFT",    0, 0)
    button.borderLeft:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    button.borderLeft:SetWidth(BORDER_THICKNESS)
    button.borderRight:SetPoint("TOPRIGHT",    button, "TOPRIGHT",    0, 0)
    button.borderRight:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    button.borderRight:SetWidth(BORDER_THICKNESS)

    -- Stock cooldown swipe driven by CooldownFrame_Set(start, duration, 1).
    button.cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    button.cd:SetAllPoints(button)

    button.timer = button:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    button.timer:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.timer:SetText("")

    -- Pseudo (without realm) under the icon, refreshed by RefreshNameLabel.
    button.nameLabel = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.nameLabel:SetPoint("TOP", button, "BOTTOM", 0, -2)
    button.nameLabel:SetText("")

    -- Drag on left button only — right-click stays free for the secure macro.
    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")
    button:SetClampedToScreen(true)

    -- Drag is silently blocked when locked or in combat (canonical WoW UX).
    button:SetScript("OnDragStart", function(self)
        if PH.db and PH.db.lock then return end
        if InCombatLockdown() then return end
        self:StartMoving()
    end)

    -- Persist anchor immediately on drop. The relativeTo frame is intentionally
    -- not stored — we always re-anchor against UIParent.
    button:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if not (PH.db and PH.db.anchors) then return end
        local point, _relativeTo, relPoint, x, y = self:GetPoint(1)
        PH.db.anchors[slot] = {
            point    = point    or "CENTER",
            relPoint = relPoint or "CENTER",
            x        = x        or 0,
            y        = y        or 0,
        }
        if PH.debug then
            print((PH.prefix .. " UI:OnDragStop slot=%d point=%s relPoint=%s x=%.0f y=%.0f"):format(
                slot, tostring(point), tostring(relPoint), x or 0, y or 0))
        end
    end)

    PH.UI._buttons[slot] = button
    return button
end

createButton(1)
createButton(2)

-- SecureActionButtonTemplate is protected: ClearAllPoints / SetPoint throw a
-- TAINT error in combat. Stash a pending flag and let OnRegenEnabled retry.
-- Defensive type validation against malformed PH.db.anchors[slot].
local function applyAnchor(button, slot)
    if InCombatLockdown() then
        button._anchorPending = true
        return
    end
    local a = PH.db and PH.db.anchors and PH.db.anchors[slot]
    if not (a and type(a.point) == "string" and type(a.relPoint) == "string"
            and type(a.x) == "number" and type(a.y) == "number") then
        a = {
            point    = "CENTER",
            relPoint = "CENTER",
            x        = (slot == 1) and -60 or 60,
            y        = 0,
        }
    end
    button:ClearAllPoints()
    button:SetPoint(a.point, UIParent, a.relPoint, a.x, a.y)
    button._anchorPending = nil
end

-- Visual state: "unresolved" / "absent" / "oor" / "inrange".
local function slotVisualState(slot)
    local s = PH.slots[slot]
    if not s.resolved then return "unresolved" end
    if not s.hasPrescience then return "absent" end
    if s.inRange then return "inrange" else return "oor" end
end

local function setBorderColor(button, color)
    local r, g, b, a = color[1], color[2], color[3], color[4]
    button.borderTop:SetColorTexture(r, g, b, a)
    button.borderBottom:SetColorTexture(r, g, b, a)
    button.borderLeft:SetColorTexture(r, g, b, a)
    button.borderRight:SetColorTexture(r, g, b, a)
end

-- UIFrameFlash stacks if called twice — the _pulsing sentinel makes
-- start/stop idempotent.
local function startPulse(button)
    if button._pulsing then return end
    button._pulsing = true
    UIFrameFlash(button, 0.5, 0.5, -1, true, 0, 0)
end

local function stopPulse(button)
    if not button._pulsing then return end
    button._pulsing = false
    UIFrameFlashStop(button)
end

-- Timer color ladder: white > 5s, yellow ≤ 5s, red ≤ 2s.
local function timerColorFor(remaining)
    if remaining > 5 then return 1, 1, 1 end
    if remaining > 2 then return 1, 1, 0 end
    return 1, 0.2, 0.2
end

local function startTimerLoop(button, slot)
    local acc = 0
    button:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc < 0.1 then return end
        acc = 0
        UI:TickTimer(slot)
    end)
end

local function stopTimerLoop(button)
    button:SetScript("OnUpdate", nil)
    if button.timer then
        button.timer:SetText("")
    end
end

function UI:OnActivated(event)
    if PH.debug then
        print((PH.prefix .. " UI:%s"):format(event))
    end
    for slot = 1, 2 do
        applyAnchor(PH.UI._buttons[slot], slot)
    end
    PH.UI._root:Show()
    -- Initial repaint avoids a one-tick grey flicker if event ordering shifts.
    for slot = 1, 2 do
        UI:RenderResolution(slot)
        UI:RefreshNameLabel(slot)
    end
end

function UI:OnDeactivated(event)
    if PH.debug then
        print((PH.prefix .. " UI:%s"):format(event))
    end
    PH.UI._root:Hide()
    -- Hide cascades visibility but UIFrameFlash keeps running on its own
    -- driver — explicit teardown stops any pulse and clears the cooldown.
    for slot = 1, 2 do
        local button = PH.UI._buttons[slot]
        if button then
            stopPulse(button)
            button.cd:Clear()
            stopTimerLoop(button)
        end
    end
end

function UI:RenderResolution(slot)
    local button = PH.UI._buttons[slot]
    if not button then return end
    if slotVisualState(slot) == "unresolved" then
        setBorderColor(button, BORDER_GREY)
        button.icon:SetDesaturated(true)
        stopPulse(button)
        button.cd:Clear()
        stopTimerLoop(button)
        return
    end
    UI:RenderAura(slot)
end

function UI:RenderAura(slot)
    local button = PH.UI._buttons[slot]
    if not button then return end
    local state = slotVisualState(slot)
    if state == "unresolved" then
        UI:RenderResolution(slot)
        return
    end
    if state == "absent" then
        setBorderColor(button, BORDER_RED)
        button.icon:SetDesaturated(true)
        startPulse(button)
        button.cd:Clear()
        stopTimerLoop(button)
        return
    end
    -- Active: full color, no pulse, swipe running. Start derived from
    -- expirationTime - duration so a refresh restarts the swipe correctly.
    button.icon:SetDesaturated(false)
    stopPulse(button)
    local s = PH.slots[slot]
    local start = s.expirationTime - s.duration
    CooldownFrame_Set(button.cd, start, s.duration, 1)
    startTimerLoop(button, slot)
    UI:RenderRange(slot)
end

function UI:RenderRange(slot)
    local button = PH.UI._buttons[slot]
    if not button then return end
    local state = slotVisualState(slot)
    if state == "unresolved" or state == "absent" then return end
    if state == "inrange" then
        setBorderColor(button, BORDER_GREEN)
    else
        setBorderColor(button, BORDER_RED)
    end
end

function UI:TickTimer(slot)
    if not PH.state.isActive then return end
    local button = PH.UI._buttons[slot]
    if not button then return end
    local s = PH.slots[slot]
    if not s.hasPrescience then
        -- Race: aura dropped between fire and tick. Blank text so no stale
        -- digit lingers for a frame before RenderAura repaints.
        button.timer:SetText("")
        return
    end
    local remaining = s.expirationTime - GetTime()
    if remaining < 0 then remaining = 0 end
    button.timer:SetText(tostring(math.floor(remaining)))
    button.timer:SetTextColor(timerColorFor(remaining))
end

function UI:OnCacheRebuilt(event)
    if PH.debug then
        print((PH.prefix .. " UI:%s"):format(event))
    end
    if not PH.state.isActive then return end
    for slot = 1, 2 do
        UI:RenderResolution(slot)
        UI:RefreshNameLabel(slot)
    end
    -- Re-bind both slots. Idempotent SetAttribute; covers the case where the
    -- first rebuild happened in combat and the binding was deferred.
    for slot = 1, 2 do
        UI:ApplySecureBinding(slot)
    end
end

-- Strip realm: "Nom-Realm" -> "Nom". Defensive guards for missing
-- button / nameLabel / PH.slots all blank the label rather than erroring.
function UI:RefreshNameLabel(slot)
    local button = PH.UI._buttons[slot]
    if not button or not button.nameLabel then return end
    if not PH.slots then
        button.nameLabel:SetText("")
        return
    end
    local s = PH.slots[slot]
    if not s or not s.resolved or not s.fullName or s.fullName == "" then
        button.nameLabel:SetText("")
        return
    end
    local pseudo = s.fullName:match("^([^-]+)") or s.fullName
    button.nameLabel:SetText(pseudo)
end

function UI:OnAuraChanged(event, slot)
    if PH.debug then
        print((PH.prefix .. " UI:%s slot=%s"):format(event, tostring(slot)))
    end
    if not PH.state.isActive then return end
    if slot ~= 1 and slot ~= 2 then return end
    UI:RenderAura(slot)
end

function UI:OnRangeChanged(event, slot)
    if PH.debug then
        print((PH.prefix .. " UI:%s slot=%s"):format(event, tostring(slot)))
    end
    if not PH.state.isActive then return end
    if slot ~= 1 and slot ~= 2 then return end
    UI:RenderRange(slot)
end

-- PH_AURA_CHANGED already flipped the icon to "absent" visuals before we
-- arrive — our job is only the audible cue. Master channel so volume
-- follows the Master slider rather than effect/ambient subchannels.
function UI:OnPrescienceDropped(event, slot)
    if PH.debug then
        print((PH.prefix .. " UI:%s slot=%s"):format(event, tostring(slot)))
    end
    if not PH.state.isActive then return end
    if slot ~= 1 and slot ~= 2 then return end
    if PH.db and PH.db.soundEnabled then
        PlaySound(SOUNDKIT.RAID_WARNING, "Master")
    end
end

-- Config fans out PH_MACROS_CHANGED on UPDATE_MACROS so we re-bind the
-- secure attribute. ApplySecureBinding's combat gate is the single source
-- of truth — no extra gate here.
function UI:OnMacrosChanged(event)
    if PH.debug then
        print((PH.prefix .. " UI:%s"):format(event))
    end
    for slot = 1, 2 do
        UI:ApplySecureBinding(slot)
    end
end

-- Single canonical site for the type2/macro2 SetAttribute pair. Combat-gated
-- here so no other path can bypass the lockdown check. If skipped due to
-- combat, OnRegenEnabled reapplies on combat exit.
function UI:ApplySecureBinding(slot)
    local button = PH.UI._buttons[slot]
    if not button then return end
    if InCombatLockdown() then return end
    button:SetAttribute("type2", "macro")
    button:SetAttribute("macro2", "PRESCIENCE " .. slot)
    if PH.debug then
        print((PH.prefix .. " UI:ApplySecureBinding slot=%d macro=PRESCIENCE %d"):format(slot, slot))
    end
end

function UI:OnRegenDisabled(event)
    if PH.debug then
        print((PH.prefix .. " UI:%s"):format(event))
    end
    PH.state.inCombat = true
end

-- On combat exit, flush deferred anchor applies and re-bind both slots.
function UI:OnRegenEnabled(event)
    if PH.debug then
        print((PH.prefix .. " UI:%s"):format(event))
    end
    PH.state.inCombat = false
    for slot = 1, 2 do
        local button = PH.UI._buttons[slot]
        if button and button._anchorPending then
            applyAnchor(button, slot)
        end
    end
    for slot = 1, 2 do
        UI:ApplySecureBinding(slot)
    end
end

-- Public entry point for Config's "Reinitialiser les positions". Combat-safe
-- via applyAnchor's internal gate (queues for OnRegenEnabled flush).
function UI:ReapplyAnchors()
    if PH.debug then
        print(PH.prefix .. " UI:ReapplyAnchors")
    end
    for slot = 1, 2 do
        local button = PH.UI._buttons[slot]
        if button then
            applyAnchor(button, slot)
        end
    end
end

PH.Core:RegisterEvent("PH_ACTIVATED",          PH.UI, "OnActivated")
PH.Core:RegisterEvent("PH_DEACTIVATED",        PH.UI, "OnDeactivated")
PH.Core:RegisterEvent("PH_CACHE_REBUILT",      PH.UI, "OnCacheRebuilt")
PH.Core:RegisterEvent("PH_AURA_CHANGED",       PH.UI, "OnAuraChanged")
PH.Core:RegisterEvent("PH_RANGE_CHANGED",      PH.UI, "OnRangeChanged")
PH.Core:RegisterEvent("PH_PRESCIENCE_DROPPED", PH.UI, "OnPrescienceDropped")
PH.Core:RegisterEvent("PLAYER_REGEN_DISABLED", PH.UI, "OnRegenDisabled")
PH.Core:RegisterEvent("PLAYER_REGEN_ENABLED",  PH.UI, "OnRegenEnabled")
PH.Core:RegisterEvent("PH_MACROS_CHANGED",     PH.UI, "OnMacrosChanged")

-- Cold-path: if Tracker activated before UI.lua loaded (e.g. /reload mid-raid),
-- PH_ACTIVATED already dispatched and won't repeat — manually catch up.
if PH.state and PH.state.isActive then
    for slot = 1, 2 do
        applyAnchor(PH.UI._buttons[slot], slot)
    end
    PH.UI._root:Show()
    for slot = 1, 2 do
        UI:RenderResolution(slot)
    end
end
