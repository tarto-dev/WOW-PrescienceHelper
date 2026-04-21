-- Config.lua -- Settings panel, slash target, status refresh, macro management.

local ADDON_NAME, PH = ...
local Config = PH.Config

local PADDING = 8
local ROW_HEIGHT = 28
local EDITBOX_WIDTH = 240
local LEFT_X = 16
local RIGHT_X = 390
local TOP_Y = -16

local function makeEditBox(parent, labelText)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(EDITBOX_WIDTH, ROW_HEIGHT - 6)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(48)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetText(labelText)
    return eb, label
end

local function makeCheckButton(parent, labelText)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetText(labelText)
    return cb, label
end

local function makeButton(parent, labelText, width)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(width or 180, ROW_HEIGHT)
    btn:SetText(labelText)
    return btn
end

local function makeStatusLine(parent)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetText("")
    return fs
end

PH.Config._category = PH.Config._category or nil
PH.Config._panel    = PH.Config._panel    or nil
PH.Config._widgets  = PH.Config._widgets  or { player = {}, check = {}, status = { resolution = {}, macro = {} } }

-- No SetSize: the Settings system owns the panel dimensions. Global name
-- exposed so other addons (Leatrix, ConfigurationAssistant) can target it.
PH.Config._panel = PH.Config._panel or CreateFrame("Frame", "PrescienceHelperOptionsPanel", UIParent)

local function buildLayout(panel)
    -- Player EditBoxes (rows 1-2). +60 on the EditBox x-offset aligns inputs
    -- across both rows despite label-width variation (ASCII labels only).
    local eb1, lb1 = makeEditBox(panel, PH.L["Player 1"])
    lb1:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y)
    eb1:SetPoint("LEFT", lb1, "RIGHT", PADDING + 60, 0)
    PH.Config._widgets.player[1] = eb1

    local eb2, lb2 = makeEditBox(panel, PH.L["Player 2"])
    lb2:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y - ROW_HEIGHT)
    eb2:SetPoint("LEFT", lb2, "RIGHT", PADDING + 60, 0)
    PH.Config._widgets.player[2] = eb2

    -- Activation gates (rows 3-4). activeRaid default ON, activeDungeon OFF.
    local cbActiveRaid, lbActiveRaid = makeCheckButton(panel, PH.L["Enable in raid"])
    cbActiveRaid:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y - 2 * ROW_HEIGHT)
    lbActiveRaid:SetPoint("LEFT", cbActiveRaid, "RIGHT", PADDING, 0)
    PH.Config._widgets.check.activeRaid = cbActiveRaid

    local cbActiveDungeon, lbActiveDungeon = makeCheckButton(panel, PH.L["Enable in dungeon"])
    cbActiveDungeon:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y - 3 * ROW_HEIGHT)
    lbActiveDungeon:SetPoint("LEFT", cbActiveDungeon, "RIGHT", PADDING, 0)
    PH.Config._widgets.check.activeDungeon = cbActiveDungeon

    -- Behavior toggles (rows 5-7).
    local cbLock, lbLock = makeCheckButton(panel, PH.L["Lock icons"])
    cbLock:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y - 4 * ROW_HEIGHT)
    lbLock:SetPoint("LEFT", cbLock, "RIGHT", PADDING, 0)
    PH.Config._widgets.check.lock = cbLock

    local cbTest, lbTest = makeCheckButton(panel, PH.L["Test mode"])
    cbTest:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y - 5 * ROW_HEIGHT)
    lbTest:SetPoint("LEFT", cbTest, "RIGHT", PADDING, 0)
    PH.Config._widgets.check.test = cbTest

    local cbSound, lbSound = makeCheckButton(panel, PH.L["Sound enabled"])
    cbSound:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y - 6 * ROW_HEIGHT)
    lbSound:SetPoint("LEFT", cbSound, "RIGHT", PADDING, 0)
    PH.Config._widgets.check.sound = cbSound

    local cbDebug, lbDebug = makeCheckButton(panel, PH.L["Debug mode"])
    cbDebug:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y - 7 * ROW_HEIGHT)
    lbDebug:SetPoint("LEFT", cbDebug, "RIGHT", PADDING, 0)
    PH.Config._widgets.check.debug = cbDebug

    -- Action buttons (rows 9-10), separated from the toggle stack by PADDING.
    local btnReset = makeButton(panel, PH.L["Reset positions"])
    btnReset:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y - 8 * ROW_HEIGHT - PADDING)
    PH.Config._widgets.reset = btnReset

    local btnRecreate = makeButton(panel, PH.L["Save and recreate macros"], 240)
    btnRecreate:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y - 9 * ROW_HEIGHT - PADDING)
    PH.Config._widgets.recreate = btnRecreate

    -- Right column status FontStrings (resolution rows 1-2, macro near reset).
    local res1 = makeStatusLine(panel)
    res1:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT_X, TOP_Y)
    PH.Config._widgets.status.resolution[1] = res1

    local res2 = makeStatusLine(panel)
    res2:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT_X, TOP_Y - ROW_HEIGHT)
    PH.Config._widgets.status.resolution[2] = res2

    local mac1 = makeStatusLine(panel)
    mac1:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT_X, TOP_Y - 8 * ROW_HEIGHT - PADDING)
    PH.Config._widgets.status.macro[1] = mac1
    local mac2 = makeStatusLine(panel)
    mac2:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT_X, TOP_Y - 8 * ROW_HEIGHT - PADDING - math.floor(ROW_HEIGHT / 2))
    PH.Config._widgets.status.macro[2] = mac2
end

buildLayout(PH.Config._panel)

-- Per-letter color gradient: text colored char by char along c1 -> c2 -> c3
-- with the midpoint forced to c2. Used for the author footer.
local function gradientText(text, c1, c2, c3)
    local n = #text
    if n == 0 then return "" end
    local mid = (n + 1) / 2
    local out = {}
    for i = 1, n do
        local t, ca, cb
        if i <= mid then
            t = (mid > 1) and ((i - 1) / (mid - 1)) or 0
            ca, cb = c1, c2
        else
            t = (i - mid) / (n - mid)
            ca, cb = c2, c3
        end
        local r = math.floor(ca[1] + (cb[1] - ca[1]) * t + 0.5)
        local g = math.floor(ca[2] + (cb[2] - ca[2]) * t + 0.5)
        local b = math.floor(ca[3] + (cb[3] - ca[3]) * t + 0.5)
        out[#out + 1] = ("|cFF%02X%02X%02X%s|r"):format(r, g, b, text:sub(i, i))
    end
    return table.concat(out)
end

local AUTHOR_HANDLE = "Claralicious_"
local FR_BLEU  = { 0x00, 0x55, 0xA4 }
local FR_BLANC = { 0xFF, 0xFF, 0xFF }
local FR_ROUGE = { 0xEF, 0x41, 0x35 }

local function buildFooter(panel)
    local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", LEFT_X, PADDING)
    fs:SetText("By " .. gradientText(AUTHOR_HANDLE, FR_BLEU, FR_BLANC, FR_ROUGE))
end

buildFooter(PH.Config._panel)

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Local copy of the default anchors. Must stay in sync with Core.lua's
-- DB_DEFAULTS.anchors. CopyTable used at write time so the live DB never
-- aliases this template.
local DB_DEFAULT_ANCHORS = {
    [1] = { point = "CENTER", relPoint = "CENTER", x = -60, y = 0 },
    [2] = { point = "CENTER", relPoint = "CENTER", x =  60, y = 0 },
}

-- Macro single source of truth: PH.db.playerN drives the PRESCIENCE N body.
-- Body shape: #showtooltip Prescience + /cast [@<pseudo>,help,nodead] Prescience
--   - help,nodead avoids "invalid target" failures on dead/hostile units
--   - empty pseudo collapses to [@none] so the macro stays defined but inert
-- Per-character macro slots (1-18) so alts get distinct targets.
-- EditMacro / CreateMacro both error in combat: applyMacroForSlot defers to
-- _macroPending and PLAYER_REGEN_ENABLED flushes once combat ends.
local SPELL_ID_PRESCIENCE = 409311
local MACRO_NAME_FMT      = "PRESCIENCE %d"
local MACRO_ICON_FALLBACK = "INV_Misc_QuestionMark"
local _macroPending       = _macroPending or {}

local function macroIcon()
    return C_Spell.GetSpellTexture(SPELL_ID_PRESCIENCE) or MACRO_ICON_FALLBACK
end

local function buildMacroBody(pseudo)
    if not pseudo or pseudo == "" then
        return "#showtooltip Prescience\n/cast [@none,help,nodead] Prescience"
    end
    return ("#showtooltip Prescience\n/cast [@%s,help,nodead] Prescience"):format(pseudo)
end

local function applyMacroForSlot(slot, pseudo)
    if slot ~= 1 and slot ~= 2 then return end
    if InCombatLockdown() then
        _macroPending[slot] = pseudo or ""
        if PH.debug then
            print((PH.prefix .. " Config:Macro %d update deferred (combat)"):format(slot))
        end
        return
    end
    local macroName = MACRO_NAME_FMT:format(slot)
    local body = buildMacroBody(pseudo)
    local idx = GetMacroIndexByName(macroName)
    if idx and idx > 0 then
        EditMacro(idx, macroName, macroIcon(), body)
    else
        -- pcall so an at-cap macro slot doesn't break the EditBox commit path.
        local ok, err = pcall(CreateMacro, macroName, macroIcon(), body, true)
        if not ok and PH.debug then
            print((PH.prefix .. " Config:CreateMacro %s failed: %s"):format(macroName, tostring(err)))
        end
    end
    _macroPending[slot] = nil
    if PH.debug then
        print((PH.prefix .. " Config:Macro %d ecrite -> %s"):format(slot, body:gsub("\n", " | ")))
    end
end

local function wireWidgets(panel)
    -- EditBox commit: trim, persist, resolve, sync the macro body.
    for slot = 1, 2 do
        local eb = PH.Config._widgets.player[slot]
        eb:SetScript("OnEditFocusLost", function(self)
            if not PH.db then return end
            local value = trim(self:GetText())
            PH.db["player" .. slot] = value
            self:SetText(value)
            self:SetCursorPosition(0)
            if PH.debug then
                print((PH.prefix .. " Config:EditBox slot=%d value=%q"):format(slot, value))
            end
            if PH.Tracker and PH.Tracker.Resolve then
                PH.Tracker:Resolve()
            end
            applyMacroForSlot(slot, value)
        end)
        eb:SetScript("OnEnterPressed", function(self)
            self:ClearFocus()
        end)
    end

    -- Activation toggles: write then fire so Tracker re-runs UpdateActivation.
    PH.Config._widgets.check.activeRaid:SetScript("OnClick", function(self)
        if not PH.db then return end
        PH.db.activeRaid = self:GetChecked() and true or false
        if PH.debug then
            print((PH.prefix .. " Config:CheckButton activeRaid=%s"):format(tostring(PH.db.activeRaid)))
        end
        PH.Core:Fire("PH_ACTIVE_GATE_CHANGED")
    end)
    PH.Config._widgets.check.activeDungeon:SetScript("OnClick", function(self)
        if not PH.db then return end
        PH.db.activeDungeon = self:GetChecked() and true or false
        if PH.debug then
            print((PH.prefix .. " Config:CheckButton activeDungeon=%s"):format(tostring(PH.db.activeDungeon)))
        end
        PH.Core:Fire("PH_ACTIVE_GATE_CHANGED")
    end)

    -- Behavior toggles: write only, consumers read PH.db.* live at use time.
    PH.Config._widgets.check.lock:SetScript("OnClick", function(self)
        if not PH.db then return end
        PH.db.lock = self:GetChecked() and true or false
        if PH.debug then
            print((PH.prefix .. " Config:CheckButton lock=%s"):format(tostring(PH.db.lock)))
        end
    end)

    -- Test toggle fires the synthetic event so Tracker forces both slots to
    -- the local player and re-runs UpdateActivation.
    PH.Config._widgets.check.test:SetScript("OnClick", function(self)
        if not PH.db then return end
        PH.db.test = self:GetChecked() and true or false
        if PH.debug then
            print((PH.prefix .. " Config:CheckButton test=%s"):format(tostring(PH.db.test)))
        end
        PH.Core:Fire("PH_TEST_MODE_CHANGED")
    end)

    PH.Config._widgets.check.sound:SetScript("OnClick", function(self)
        if not PH.db then return end
        PH.db.soundEnabled = self:GetChecked() and true or false
        if PH.debug then
            print((PH.prefix .. " Config:CheckButton soundEnabled=%s"):format(tostring(PH.db.soundEnabled)))
        end
    end)

    -- Debug mirrors PH.debug so prints update without /reload.
    PH.Config._widgets.check.debug:SetScript("OnClick", function(self)
        if not PH.db then return end
        PH.db.debug = self:GetChecked() and true or false
        PH.debug = PH.db.debug
        if PH.debug then
            print((PH.prefix .. " Config:CheckButton debug=%s"):format(tostring(PH.db.debug)))
        end
    end)

    -- Reset positions: combat-gate, deep-copy defaults into the live DB,
    -- delegate visual reapply to UI:ReapplyAnchors. CopyTable is mandatory
    -- to avoid aliasing the template into the live DB.
    PH.Config._widgets.reset:SetScript("OnClick", function()
        if InCombatLockdown() then
            print(PH.prefix .. " " .. PH.L["Not possible in combat. Try again after."])
            return
        end
        if not (PH.db and PH.db.anchors) then return end
        PH.db.anchors = CopyTable(DB_DEFAULT_ANCHORS)
        if PH.UI and PH.UI.ReapplyAnchors then
            PH.UI:ReapplyAnchors()
        end
        if PH.debug then
            print(PH.prefix .. " Anchors reinitialises.")
        end
    end)

    -- Manual SSOT trigger: re-applies both PRESCIENCE N macros from current
    -- PH.db state. Subsequent UPDATE_MACROS event re-paints the status lines.
    PH.Config._widgets.recreate:SetScript("OnClick", function()
        if InCombatLockdown() then
            print(PH.prefix .. " " .. PH.L["Not possible in combat. Try again after."])
            return
        end
        if not PH.db then return end
        applyMacroForSlot(1, PH.db.player1)
        applyMacroForSlot(2, PH.db.player2)
        print(PH.prefix .. " " .. PH.L["Macros PRESCIENCE 1 / 2 saved from config."])
    end)
end

wireWidgets(PH.Config._panel)

-- Push PH.db into input widgets. Covers /run-driven changes between opens
-- and /reload while the panel was closed.
function Config:SyncWidgetsFromDB()
    if not PH.db then return end
    local w = PH.Config._widgets
    for slot = 1, 2 do
        local eb = w.player[slot]
        local value = PH.db["player" .. slot] or ""
        eb:SetText(value)
        eb:SetCursorPosition(0)
    end
    w.check.activeRaid:SetChecked(PH.db.activeRaid and true or false)
    w.check.activeDungeon:SetChecked(PH.db.activeDungeon and true or false)
    w.check.lock:SetChecked(PH.db.lock and true or false)
    w.check.test:SetChecked(PH.db.test and true or false)
    w.check.sound:SetChecked(PH.db.soundEnabled and true or false)
    w.check.debug:SetChecked(PH.db.debug and true or false)
end

PH.Config._panel:SetScript("OnShow", function()
    Config:SyncWidgetsFromDB()
    Config:RefreshAll()
end)

-- Idempotent canvas-category registration. Early-return on _category makes
-- /reload mid-session a no-op.
function Config:RegisterPanel()
    if PH.Config._category then return end
    if not PH.Config._panel then return end
    local category = Settings.RegisterCanvasLayoutCategory(PH.Config._panel, "PrescienceHelper")
    Settings.RegisterAddOnCategory(category)
    PH.Config._category = category
    if PH.debug then
        print((PH.prefix .. " Config:RegisterPanel category.ID=%s"):format(tostring(category.ID)))
    end
end

function Config:OnDbReady(event)
    if PH.debug then
        print((PH.prefix .. " Config:%s"):format(event))
    end
    Config:RegisterPanel()
    Config:RefreshAll()
    -- Macro initial sync: fresh install creates the two macros, /reload
    -- re-asserts the canonical body.
    applyMacroForSlot(1, PH.db.player1)
    applyMacroForSlot(2, PH.db.player2)
end

-- Flush deferred macro writes when combat ends.
function Config:OnRegenEnabled(event)
    if not next(_macroPending) then return end
    if PH.debug then
        print(PH.prefix .. " Config:OnRegenEnabled flushing pending macro writes.")
    end
    -- Snapshot before iterating: applyMacroForSlot mutates _macroPending and
    -- pairs() over a mutating table is undefined.
    local pending = {}
    for slot, pseudo in pairs(_macroPending) do
        pending[slot] = pseudo
    end
    for slot, pseudo in pairs(pending) do
        applyMacroForSlot(slot, pseudo)
    end
end

function Config:Open(msg)
    if not PH.Config._category then
        if PH.debug then
            print(PH.prefix .. " Config:Open called before PH_DB_READY -- panel not yet registered.")
        end
        return
    end
    Settings.OpenToCategory(PH.Config._category.ID)
end

-- Inline ReadyCheck textures render the ✓ / X glyphs reliably regardless of
-- font glyph coverage (U+2713 / U+26A0 hit .notdef on stock WoW fonts). The
-- textures carry their own vertex colors so SetTextColor is not used.
function Config:RefreshResolutionStatus(slot)
    if slot ~= 1 and slot ~= 2 then return end
    if not PH.db then return end
    local fs = PH.Config._widgets.status.resolution[slot]
    if not fs then return end

    local playerKey = "player" .. slot
    local target = PH.db[playerKey] or ""
    local s = PH.slots and PH.slots[slot]

    local text
    if target == "" then
        text = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t " .. PH.L["Empty name"]
    elseif s and s.resolved then
        text = ("|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t " .. PH.L["Found as %s (%s)"]):format(
            tostring(s.unitID), tostring(s.fullName))
    else
        text = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t " .. PH.L["Not in current group"]
    end

    fs:SetText(text)
end

function Config:RefreshMacroStatus(slot)
    if slot ~= 1 and slot ~= 2 then return end
    local fs = PH.Config._widgets.status.macro[slot]
    if not fs then return end

    local macroName = "PRESCIENCE " .. slot
    local index = GetMacroIndexByName(macroName)

    local text
    if not index or index == 0 then
        text = ("|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t " .. PH.L["Macro \"%s\" not found"]):format(macroName)
    else
        text = ("|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t " .. PH.L["Macro \"%s\" found"]):format(macroName)
    end

    fs:SetText(text)
end

function Config:RefreshAll()
    for slot = 1, 2 do
        Config:RefreshResolutionStatus(slot)
        Config:RefreshMacroStatus(slot)
    end
end

function Config:OnCacheRebuilt(event)
    if PH.debug then
        print((PH.prefix .. " Config:%s"):format(event))
    end
    for slot = 1, 2 do
        Config:RefreshResolutionStatus(slot)
    end
end

-- UPDATE_MACROS fires on macro create / delete / rename. Refresh local status
-- AND fan out to UI via PH_MACROS_CHANGED so the secure binding is rebound.
function Config:OnMacrosChanged(event, ...)
    if PH.debug then
        print((PH.prefix .. " Config:%s"):format(event))
    end
    for slot = 1, 2 do
        Config:RefreshMacroStatus(slot)
    end
    PH.Core:Fire("PH_MACROS_CHANGED")
end

function Config:OnTestModeChanged(event)
    if PH.debug then
        print((PH.prefix .. " Config:%s"):format(event))
    end
    for slot = 1, 2 do
        Config:RefreshResolutionStatus(slot)
    end
end

PH.Core:RegisterEvent("PH_DB_READY",            PH.Config, "OnDbReady")
PH.Core:RegisterEvent("PH_CACHE_REBUILT",       PH.Config, "OnCacheRebuilt")
PH.Core:RegisterEvent("UPDATE_MACROS",          PH.Config, "OnMacrosChanged")
PH.Core:RegisterEvent("PH_TEST_MODE_CHANGED",   PH.Config, "OnTestModeChanged")
PH.Core:RegisterEvent("PLAYER_REGEN_ENABLED",   PH.Config, "OnRegenEnabled")
