-- Config.lua -- In-game Settings panel, slash target, live status refresh, test/reset actions.
--
-- Phase 4 scope: replaces the Phase 1 10-line stub with a modern Settings.*
-- canvas category registered on PH_DB_READY, a 2-column widget grid (inputs
-- left / status mirrors right) built with stock templates, event-driven status
-- refresh (resolution + macro existence), and a fan-out event triggered by
-- the WoW macro-update event for the secure-binding consumer. Ownership map:
-- Core.lua / Tracker.lua / UI.lua are frozen in this phase; Config.lua grows
-- from 10 L to ~150-200 L in Plan 04-01 (scaffolding), then picks up commit
-- handlers (Plan 04-02) and live refresh + fan-out (Plan 04-03). Plan 04-04
-- adds one small public method to UI.lua (UI:ReapplyAnchors) for the Reset-
-- positions button payload.
local ADDON_NAME, PH = ...
local Config = PH.Config

-- 1. Layout constants (D-07) --------------------------------------------------
-- Explicit SetPoint math -- no grid / flex framework. The six constants define
-- the 2-column geometry referenced by every widget below: left column anchored
-- TOPLEFT + (LEFT_X, TOP_Y), right column TOPLEFT + (RIGHT_X, TOP_Y), rows
-- pitched at ROW_HEIGHT on the y axis. TOP_Y is negative because WoW anchors
-- grow downward from TOPLEFT, so offsetting by -Y moves a widget down the panel.
local PADDING = 8
local ROW_HEIGHT = 28
local EDITBOX_WIDTH = 240
local LEFT_X = 16
local RIGHT_X = 390
local TOP_Y = -16

-- 2. Widget builder helpers (D-05, D-06, D-08, UI-SPEC templates table) -------
-- Four pure factories that instantiate a widget pair (widget + optional label)
-- using stock WoW templates. No SetPoint calls here -- positioning is the job
-- of buildLayout in Section 4 so these helpers stay reusable / composable. No
-- click / blur / show scripts either -- behaviour wiring ships in Plans 04-02
-- (commit handlers) and 04-03 (live status refresh).

-- InputBoxTemplate provides the default WoW chrome for a single-line text
-- input (border + caret + selection). Blur-to-commit wiring lands in Plan 04-02
-- per D-17: the edit-focus-lost script reads the trimmed text, writes
-- PH.db.playerN, then calls Tracker:Resolve() directly (D-18). SetAutoFocus(false) prevents the
-- first EditBox from stealing keyboard focus the moment the panel opens --
-- users should be able to read the layout before typing. SetMaxLetters(48) is
-- the realistic ceiling for a "Name-Realm" string (24 + 1 + 24 chars max).
local function makeEditBox(parent, labelText)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(EDITBOX_WIDTH, ROW_HEIGHT - 6)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(48)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetText(labelText)
    return eb, label
end

-- UICheckButtonTemplate includes the stock check graphic (unchecked / checked
-- texture pair, highlight, disabled art). Click toggle handlers wire in Plan
-- 04-02 per D-20..D-22: each of the three checkboxes (lock / test / sound)
-- writes PH.db.<key> = self:GetChecked() in its own closure, with the test
-- checkbox also firing the synthetic test-mode-changed event so Tracker
-- re-runs UpdateActivation.
local function makeCheckButton(parent, labelText)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetText(labelText)
    return cb, label
end

-- UIPanelButtonTemplate renders the stock yellow-bordered WoW button. Click
-- handler wires in Plan 04-02 per D-24..D-26: combat-lockdown gate, deep-copy
-- of DB_DEFAULTS.anchors onto PH.db.anchors, then a call to PH.UI:ReapplyAnchors
-- (new public method added in Plan 04-04). The button carries its own text so
-- no separate label FontString is returned -- callers only need the button.
local function makeButton(parent, labelText)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(180, ROW_HEIGHT)
    btn:SetText(labelText)
    return btn
end

-- Status FontString using GameFontHighlight (stock high-contrast white). The
-- initial text is blank: Plan 04-03's resolution-status and macro-status
-- refresh methods populate it and override the color via SetTextColor to the
-- D-09 palette (green 0.2/0.9/0.2 for OK, amber 1.0/0.8/0.0 for warnings).
-- Scaffolded blank here so the layout pass can reserve space without implying
-- a paint.
local function makeStatusLine(parent)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetText("")
    return fs
end

-- 3. Module state (D-02, D-04) -----------------------------------------------
-- State survives /reload via the `or` idempotency idiom; matches the Core.lua /
-- Tracker.lua / UI.lua convention (PH.UI._root, PH.Tracker._ranger, etc.). The
-- three slots reserved here are:
--   _category -- Settings-API category object returned by RegisterCanvasLayoutCategory
--                (Task 3). Cached so Config:Open can call Settings.OpenToCategory
--                with the stored ID, and so a /reload does not register twice.
--   _panel    -- the canvas Frame passed to the Settings system (Task 2 creates it).
--   _widgets  -- pre-seeded subtable holding direct references to every built
--                widget. Plans 04-02 (commit handlers) and 04-03 (status refresh)
--                read this shape directly -- no re-discovery of children, no
--                GetName() round-trips. Shape is locked: player[1..2], check.lock/
--                test/sound, reset, status.resolution[1..2], status.macro[1..2].
PH.Config._category = PH.Config._category or nil
PH.Config._panel    = PH.Config._panel    or nil
PH.Config._widgets  = PH.Config._widgets  or { player = {}, check = {}, status = { resolution = {}, macro = {} } }

-- 4. Canvas frame + 2-column layout (D-02, D-05, D-06, D-07) ------------------
-- The panel is created once at file load (not on PH_DB_READY, because the
-- Settings registration step needs a concrete frame handle to pass to
-- Settings.RegisterCanvasLayoutCategory in Task 3's OnDbReady handler). No
-- SetSize: per D-02 the Settings system owns the panel dimensions and would
-- overwrite any value we set here. The global name "PrescienceHelperOptionsPanel"
-- is exposed so other addons (Leatrix, ConfigurationAssistant) can target the
-- panel by name.
PH.Config._panel = PH.Config._panel or CreateFrame("Frame", "PrescienceHelperOptionsPanel", UIParent)

-- buildLayout(panel) -- instantiate all widgets and position them via explicit
-- SetPoint math against the panel's TOPLEFT. Rows 1-6 on the left column, with
-- three status mirrors on the right column (rows 1, 2, 6 only per D-06; rows
-- 3-5 are left empty in v1). The function is called exactly once at file load
-- after the panel creation. Each widget is stored on PH.Config._widgets so
-- downstream plans (04-02 / 04-03) can consume it by direct reference.
local function buildLayout(panel)
    -- Left column, row 1: Joueur 1 EditBox + label anchored at (LEFT_X, TOP_Y).
    -- The +60 on the EditBox x-offset aligns inputs across the two player rows
    -- despite label-text-width variation (ASCII only -- the label width is
    -- stable enough for static math, no GetStringWidth runtime probe needed).
    local eb1, lb1 = makeEditBox(panel, "Joueur 1")
    lb1:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y)
    eb1:SetPoint("LEFT", lb1, "RIGHT", PADDING + 60, 0)
    PH.Config._widgets.player[1] = eb1

    -- Left column, row 2: Joueur 2 EditBox + label (y offset one ROW_HEIGHT).
    local eb2, lb2 = makeEditBox(panel, "Joueur 2")
    lb2:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y - ROW_HEIGHT)
    eb2:SetPoint("LEFT", lb2, "RIGHT", PADDING + 60, 0)
    PH.Config._widgets.player[2] = eb2

    -- Left column, row 3: lock CheckButton (y offset two rows). Label sits to
    -- the right of the check with PADDING gap. ASCII-only per CLAUDE.md +
    -- CONTEXT.md D-07 "Claude's Discretion"; accents restored in a later phase
    -- only if needed.
    local cbLock, lbLock = makeCheckButton(panel, "Verrouiller les icones")
    cbLock:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y - 2 * ROW_HEIGHT)
    lbLock:SetPoint("LEFT", cbLock, "RIGHT", PADDING, 0)
    PH.Config._widgets.check.lock = cbLock

    -- Left column, row 4: test CheckButton.
    local cbTest, lbTest = makeCheckButton(panel, "Mode test")
    cbTest:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y - 3 * ROW_HEIGHT)
    lbTest:SetPoint("LEFT", cbTest, "RIGHT", PADDING, 0)
    PH.Config._widgets.check.test = cbTest

    -- Left column, row 5: sound CheckButton.
    local cbSound, lbSound = makeCheckButton(panel, "Son active")
    cbSound:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y - 4 * ROW_HEIGHT)
    lbSound:SetPoint("LEFT", cbSound, "RIGHT", PADDING, 0)
    PH.Config._widgets.check.sound = cbSound

    -- Left column, row 6: Reset-positions Button. Extra PADDING on the y
    -- offset adds a small visual gap between the three checkboxes above and
    -- the action-button below, signalling the control-vs-action boundary.
    local btnReset = makeButton(panel, "Reinitialiser les positions")
    btnReset:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_X, TOP_Y - 5 * ROW_HEIGHT - PADDING)
    PH.Config._widgets.reset = btnReset

    -- Right column (D-06): only rows 1, 2, 6 carry status in v1. Rows 3-5 are
    -- deliberately empty (no FontString reserved) per CONTEXT.md -- the lock /
    -- test / sound checkboxes do not need a mirrored status line.

    -- Mirror row 1: resolution status slot 1 -- Plan 04-03 populates the text
    -- via Config's resolution-status refresh method, reading PH.slots[1] +
    -- PH.db.player1 to pick among {empty, found, not-in-group}.
    local res1 = makeStatusLine(panel)
    res1:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT_X, TOP_Y)
    PH.Config._widgets.status.resolution[1] = res1

    -- Mirror row 2: resolution status slot 2.
    local res2 = makeStatusLine(panel)
    res2:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT_X, TOP_Y - ROW_HEIGHT)
    PH.Config._widgets.status.resolution[2] = res2

    -- Mirror row 6: two stacked macro status FontStrings. Slot 1 aligns with
    -- the Reset button's y; slot 2 sits half a row below so the two macro
    -- status lines are visually grouped as a unit. Plan 04-03's macro-status
    -- refresh method resolves the macro-by-name lookup for the PRESCIENCE N
    -- macro and paints the FontString with the D-09 palette.
    local mac1 = makeStatusLine(panel)
    mac1:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT_X, TOP_Y - 5 * ROW_HEIGHT - PADDING)
    PH.Config._widgets.status.macro[1] = mac1
    local mac2 = makeStatusLine(panel)
    mac2:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT_X, TOP_Y - 5 * ROW_HEIGHT - PADDING - math.floor(ROW_HEIGHT / 2))
    PH.Config._widgets.status.macro[2] = mac2
end

buildLayout(PH.Config._panel)

-- 4.1 Author credit footer (Phase 5 polish) ---------------------------------
-- Subtle bottom-left author line. The "FR" suffix is colored as the French
-- flag tricolor via WoW's |cAARRGGBB...|r escape -- bleu #0055A4, blanc
-- #FFFFFF, rouge #EF4135. ASCII characters only (CLAUDE.md byte convention);
-- no Unicode flag emoji because WoW's default font has no Supplementary
-- Multilingual Plane glyphs and would render .notdef squares.
-- GameFontDisableSmall keeps the credit visually subordinate to the controls.
local function buildFooter(panel)
    local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", LEFT_X, PADDING)
    fs:SetText("By Claralicious_  |cFF0055A4F|r|cFFFFFFFFR|r|cFFEF4135!|r")
end

buildFooter(PH.Config._panel)

-- 4.5 Widget wiring (D-17, D-18, D-19, D-20, D-21, D-22, D-23) ---------------
-- Plan 04-02 payload: attach scripts to the inert widgets scaffolded by Plan
-- 04-01's buildLayout. Two EditBoxes (slots 1..2) get the edit-focus-lost +
-- enter-pressed blur-to-commit pair; three CheckButtons (lock / test / sound)
-- get click toggle handlers. The Reset button wiring lives in Task 2 below
-- inside the same wireWidgets(panel) function so every widget's script surface
-- is declared in one place. EditBox commit path is the D-18 canonical call
-- (Tracker:Resolve direct invocation) -- supersedes D-17's synthetic-event
-- approach: Config writes PH.db.playerN, then calls Tracker:Resolve() via
-- the public API. The test CheckButton is the sole fire site for the test-
-- mode-changed synthetic event, per D-21, matching Tracker's existing
-- subscriber which re-runs UpdateActivation + Resolve.

-- trim(s) -- D-19 mandates leading/trailing whitespace strip on EditBox
-- commits. The double-gsub pattern is the idiomatic Lua approach (no external
-- dep). Non-string input returns empty -- defensive against GetText() edge
-- cases where a template regression could return nil / userdata.
local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Plan 04-02 D-25 discretion: re-declare the default anchor shape locally
-- instead of reading from Core.lua's DB_DEFAULTS (which is an upvalue not
-- exposed through any module-level getter). Keeps Config decoupled from Core
-- internals; the two definitions MUST stay identical whenever Core.lua's
-- DB_DEFAULTS.anchors changes -- both CENTER / CENTER / +/-60 / 0. The Reset
-- handler below deep-copies this table via CopyTable before assigning to
-- PH.db.anchors, so the template itself is never aliased into the live DB.
local DB_DEFAULT_ANCHORS = {
    [1] = { point = "CENTER", relPoint = "CENTER", x = -60, y = 0 },
    [2] = { point = "CENTER", relPoint = "CENTER", x =  60, y = 0 },
}

-- wireWidgets(panel) -- install every widget script in one pass. Declared as
-- a module-local function (not a Config method) because the wiring is a
-- one-shot at file load, not a reusable operation -- there is no "re-wire"
-- scenario the caller would need.
local function wireWidgets(panel)
    -- 1) EditBox wiring slots 1..2 (D-17, D-18, D-19) -----------------------
    -- The direct Tracker:Resolve() call (D-18 canonical path) bypasses the
    -- PH_PLAYER_CHANGED / PH_DB_READY synthetic-event routes that D-17
    -- initially considered -- Resolve is idempotent and cheap (clearSlot +
    -- at most 41 candidate walks; Tracker.lua section 4). D-19 trim runs once
    -- on commit; SetText + SetCursorPosition overwrite the visual with the
    -- cleaned value so a user who pasted with trailing spaces sees the
    -- trimmed form immediately. Guard on PH.Tracker existence is defensive
    -- against bootstrap ordering regressions (TOC load order guarantees
    -- Tracker.lua before Config.lua, so the method is present, but the guard
    -- costs nothing and catches accidental re-orderings).
    for slot = 1, 2 do
        local eb = PH.Config._widgets.player[slot]
        eb:SetScript("OnEditFocusLost", function(self)
            if not PH.db then return end
            local value = trim(self:GetText())
            PH.db["player" .. slot] = value
            self:SetText(value)
            self:SetCursorPosition(0)
            if PH.debug then
                print(("[PH] Config:EditBox slot=%d value=%q"):format(slot, value))
            end
            if PH.Tracker and PH.Tracker.Resolve then
                PH.Tracker:Resolve()
            end
        end)
        -- Enter-to-commit: ClearFocus triggers the focus-lost handler above,
        -- which does the actual save. Standard WoW idiom -- avoids duplicating
        -- the trim + write + Resolve block in two handlers.
        eb:SetScript("OnEnterPressed", function(self)
            self:ClearFocus()
        end)
    end

    -- 2) CheckButton wiring (D-20, D-21, D-22, D-23) ------------------------
    -- Lock: writes PH.db.lock = self:GetChecked() and true or false -- no
    -- event fire. Phase 3's UI.lua OnDragStart reads PH.db.lock at drag time
    -- (UI.lua line 167 region), so the effect is immediate without any fan-
    -- out. The `and true or false` canonicalization keeps PH.db.lock a pure
    -- boolean even if a template regression has GetChecked return nil.
    PH.Config._widgets.check.lock:SetScript("OnClick", function(self)
        if not PH.db then return end
        PH.db.lock = self:GetChecked() and true or false
        if PH.debug then
            print(("[PH] Config:CheckButton lock=%s"):format(tostring(PH.db.lock)))
        end
    end)

    -- Test: writes PH.db.test THEN fires the test-mode-changed synthetic
    -- event so Tracker:OnTestModeChanged (Tracker.lua line 374-382 region)
    -- reads the new value and re-runs UpdateActivation + Resolve. The fire
    -- comes AFTER the db write so subscribers observe the post-toggle state.
    -- When db.test flips on, Tracker forces both slots to the "player"
    -- unitID (Tracker.lua lines 196-219 region); the resulting activation +
    -- cache-rebuilt cascade re-paints Phase 3 icons.
    PH.Config._widgets.check.test:SetScript("OnClick", function(self)
        if not PH.db then return end
        PH.db.test = self:GetChecked() and true or false
        if PH.debug then
            print(("[PH] Config:CheckButton test=%s"):format(tostring(PH.db.test)))
        end
        PH.Core:Fire("PH_TEST_MODE_CHANGED")
    end)

    -- Sound: writes PH.db.soundEnabled = self:GetChecked() -- no event fire.
    -- Phase 3's OnPrescienceDropped reads PH.db.soundEnabled at drop time
    -- (UI.lua line 601 region), so the effect is immediate.
    PH.Config._widgets.check.sound:SetScript("OnClick", function(self)
        if not PH.db then return end
        PH.db.soundEnabled = self:GetChecked() and true or false
        if PH.debug then
            print(("[PH] Config:CheckButton soundEnabled=%s"):format(tostring(PH.db.soundEnabled)))
        end
    end)

    -- 3) Reset button wiring (D-24, D-25, D-26, UI-10) ---------------------
    -- Reset Positions closes UI-10, the last Phase 3-origin requirement
    -- deferred to Phase 4. The wipe-and-reapply is intentionally not wrapped
    -- in a confirmation dialog (YAGNI -- users who click "Reinitialiser les
    -- positions" expect reset, not a modal). CopyTable is the non-negotiable
    -- idiom: a shallow alias of DB_DEFAULT_ANCHORS into PH.db.anchors would
    -- turn the next OnDragStop into a silent tamper of the default template,
    -- creating a second-click tampering vector (T-04-02-03). Two-layer combat
    -- gate: our OnClick check below blocks the common case and gives user-
    -- visible feedback; UI.lua's applyAnchor has its own InCombatLockdown
    -- gate (UI.lua lines 225-228 region) that catches any pathological race
    -- where combat begins between our gate and the call site.
    PH.Config._widgets.reset:SetScript("OnClick", function()
        -- Step 1 (D-25): combat gate with user-visible feedback. ASCII-only
        -- French per project convention. Unlike silent drag no-ops in
        -- Phase 3's OnDragStop, a deliberate Reset click deserves an explicit
        -- print so the user knows the action was refused, not lost.
        if InCombatLockdown() then
            print("[PH] Impossible en combat. Reessaie apres.")
            return
        end
        if not (PH.db and PH.db.anchors) then return end
        -- Step 2 (D-25): deep-copy the default anchors into PH.db.anchors.
        -- CopyTable is the WoW stdlib deep-copy -- assigning DB_DEFAULT_ANCHORS
        -- directly would alias the module-local with the live DB, breaking
        -- the next user drag (OnDragStop would mutate the default template).
        PH.db.anchors = CopyTable(DB_DEFAULT_ANCHORS)
        -- Step 3 (D-25, D-26): reapply anchors through UI's public entry point.
        -- PH.UI:ReapplyAnchors is defined by Plan 04-04 and iterates slots
        -- 1..2 calling the module-local applyAnchor helper. applyAnchor
        -- itself gates on InCombatLockdown so this call is doubly safe. The
        -- `if PH.UI and PH.UI.ReapplyAnchors then` guard is belt-and-
        -- suspenders against bootstrap ordering regressions -- the TOC order
        -- (Core -> Tracker -> UI -> Config) guarantees the method is present
        -- at Reset click time, but the guard costs nothing.
        if PH.UI and PH.UI.ReapplyAnchors then
            PH.UI:ReapplyAnchors()
        end
        -- Step 4 (D-25): optional debug trace gated on PH.debug.
        if PH.debug then
            print("[PH] Anchors reinitialises.")
        end
    end)
end

wireWidgets(PH.Config._panel)

-- 4.6 Panel sync + first-show hook (CONTEXT D-14 extension) -------------------
-- Config:SyncWidgetsFromDB -- read PH.db and push values into the input
-- widgets so the panel visual tracks the persisted state. Covers the case
-- where the user modifies PH.db via /run between panel opens, or runs /reload
-- while the panel is closed and then reopens it. Distinct from Plan 04-03's
-- live status refresh (which paints resolution / macro status FontStrings
-- via event-driven handlers): this method only syncs INPUT widgets that do
-- not have their own event-driven refresh path. PH.db guard covers the
-- theoretical case where OnShow fires before PH_DB_READY -- in practice the
-- Settings system only exposes the panel after RegisterPanel has run, which
-- itself runs on PH_DB_READY, so the guard is belt-and-suspenders.
function Config:SyncWidgetsFromDB()
    if not PH.db then return end
    local w = PH.Config._widgets
    for slot = 1, 2 do
        local eb = w.player[slot]
        local value = PH.db["player" .. slot] or ""
        eb:SetText(value)
        eb:SetCursorPosition(0)
    end
    w.check.lock:SetChecked(PH.db.lock and true or false)
    w.check.test:SetChecked(PH.db.test and true or false)
    w.check.sound:SetChecked(PH.db.soundEnabled and true or false)
end

-- Panel show script: sync widgets to PH.db AND refresh status FontStrings
-- every time the user navigates to the PrescienceHelper category in the
-- Settings window. After this plan, the full panel (inputs + status mirrors)
-- snaps to live state on every open regardless of which events were missed
-- while the panel was hidden (D-14). SyncWidgetsFromDB handles the INPUT
-- widgets (EditBoxes, CheckButtons); Config:RefreshAll handles the STATUS
-- FontStrings (resolution + macro) per CONFIG-04 / CONFIG-05.
PH.Config._panel:SetScript("OnShow", function()
    Config:SyncWidgetsFromDB()
    Config:RefreshAll()
end)

-- 5. Settings registration + slash body (D-01, D-03, D-04, BOOT-05) ----------
-- Plan 04-01's behavioural payload: close BOOT-05 (slash opens the panel) and
-- scaffold CONFIG-01 (Settings.RegisterCanvasLayoutCategory call). Registration
-- is deferred to PH_DB_READY rather than run at file top-level because the
-- refresh pipeline that Plan 04-03 wires (Config:RefreshAll on first panel
-- show) reads PH.db, which is nil until Core.lua's ADDON_LOADED handler
-- finishes merging DB_DEFAULTS into PrescienceHelperDB. Collapsing the "db nil
-- on first open" edge case into a single ordering (register only after
-- PH_DB_READY) keeps the downstream refresh logic free of defensive nil-
-- guards on PH.db.

-- Config:RegisterPanel -- idempotent one-shot registration of the canvas
-- category with the Settings system. Settings.RegisterCanvasLayoutCategory is
-- the Retail modern API (replaces the deprecated InterfaceOptions_AddCategory
-- per PROJECT.md Key Decisions). The early-return on _category makes a
-- /reload mid-session a no-op: the second call observes the cached category
-- and bails, so we never register two competing categories under the same
-- name. The _panel guard is purely defensive -- Task 2 creates the panel at
-- file load, so _panel being nil here indicates a bootstrap-ordering bug
-- rather than a runtime case.
function Config:RegisterPanel()
    if PH.Config._category then return end  -- already registered, /reload safe
    if not PH.Config._panel then return end  -- defensive: Task 2 creates the panel
    local category = Settings.RegisterCanvasLayoutCategory(PH.Config._panel, "PrescienceHelper")
    Settings.RegisterAddOnCategory(category)
    PH.Config._category = category
    if PH.debug then
        print(("[PH] Config:RegisterPanel category.ID=%s"):format(tostring(category.ID)))
    end
end

-- Config:OnDbReady -- dispatcher-invoked subscriber for PH_DB_READY. Core.lua
-- fires the synthetic event once per session after its Merge pass completes
-- (Phase 1 D-09). Registering the panel at this hook rather than at file
-- top-level lets Plan 04-03 attach a first-show script to _panel that calls
-- Config:RefreshAll -- which reads PH.db and PH.slots -- without any nil-
-- guard boilerplate. Signature matches the Core.lua dispatch contract
-- (module, event, ...); the event string is used only for the debug trace.
function Config:OnDbReady(event)
    if PH.debug then
        print(("[PH] Config:%s"):format(event))
    end
    Config:RegisterPanel()
    -- D-14: initial status paint so the panel is diagnosable immediately when
    -- the user opens it for the first time. PH_CACHE_REBUILT from Tracker's
    -- first UpdateActivation may or may not have fired by now depending on
    -- whether the user is in a raid at login; RefreshAll is idempotent and
    -- reads live PH.slots + PH.db, so it paints the correct state regardless.
    Config:RefreshAll()
end

-- Config:Open -- bound by SlashCmdList["PH"] in Core.lua (FROZEN, lines 129-133).
-- Replaces the Phase 1 placeholder print verbatim: the new body opens the
-- Settings window focused on the PrescienceHelper category. The msg argument
-- is ignored per D-03 -- v1 does not support /ph subcommands, the Settings
-- panel is the sole interaction surface.
--
-- The nil-guard on _category covers the pathological "user types /ph before
-- ADDON_LOADED completes" case. In practice the ADDON_LOADED -> PH_DB_READY
-- window is ~100 ms at login; reaching it requires a slash-macro on the login
-- screen (rare but observable). The debug-gated print avoids chat spam when
-- PH.debug is off (the default) while still surfacing the race to anyone who
-- enabled debug for diagnostics.
function Config:Open(msg)
    if not PH.Config._category then
        if PH.debug then
            print("[PH] Config:Open called before PH_DB_READY -- panel not yet registered.")
        end
        return
    end
    Settings.OpenToCategory(PH.Config._category.ID)
end

-- 5.5 Status refresh methods (D-09, D-11, D-12, D-13, D-14, D-16) -------------
-- Plan 04-03 Task 1 payload: the three public refresh methods that paint the
-- right-column status FontStrings scaffolded by Plan 04-01's buildLayout. The
-- refresh pipeline is intentionally stateless -- each call reads live PH.slots
-- + PH.db.playerN + GetMacroIndexByName and writes SetText in one pass. D-16
-- explicitly waives throttling: the per-slot work is 1 table read + 1-2 string
-- builds + 1 SetText, well below 1 ms even on an UPDATE_MACROS storm. Task 2
-- below installs the event handlers that drive these refresh methods from
-- PH_CACHE_REBUILT / UPDATE_MACROS / PH_TEST_MODE_CHANGED.
--
-- D-09 revision (Phase 5 QA): the original palette (green 0.2/0.9/0.2 /
-- amber 1.0/0.8/0.0) relied on rendering U+2713 / U+26A0 glyphs that WoW's
-- default font lacks -- the decimal-escape fix still emitted the glyph codepoint
-- and the font painted it as .notdef (a colored square). Replaced with inline
-- texture tags pointing at the stock ReadyCheck atlas: ReadyCheck-Ready (green
-- check) and ReadyCheck-NotReady (red X) carry their own vertex colors, so
-- SetTextColor is dropped to avoid tint-multiplying the texture into mud.

-- Config:RefreshResolutionStatus(slot) -- paint the resolution status FontString
-- for one slot. Three mutually exclusive, exhaustive branches per D-12:
--   1) PH.db.playerN == ""           -> red X    "Pseudo vide"
--   2) PH.slots[slot].resolved       -> green V  "Trouve comme <unit> (<full>)"
--   3) otherwise (non-empty, unresolved) -> red X "Pas dans le groupe actuel"
-- Inline textures |TInterface\\RaidFrame\\ReadyCheck-Ready:14|t and
-- ...ReadyCheck-NotReady:14|t render the WoW stock 14x14 ready-check glyphs
-- inside the FontString. tostring() on unitID and fullName is defensive
-- nil-safety -- PH.slots values should be string|nil per Tracker.lua lines
-- 18-29, but the cost of the guard is zero and it prevents a nil-concat
-- crash if another addon corrupts PH.slots (T-04-03-02). Guards on PH.db /
-- PH.slots return early before first PH_DB_READY dispatch; the FontString
-- guard catches the pre-buildLayout window.
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
        text = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t Pseudo vide"  -- D-12 branch 1
    elseif s and s.resolved then
        text = ("|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t Trouve comme %s (%s)"):format(
            tostring(s.unitID), tostring(s.fullName))  -- D-12 branch 2
    else
        text = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t Pas dans le groupe actuel"  -- D-12 branch 3
    end

    fs:SetText(text)
end

-- Config:RefreshMacroStatus(slot) -- paint the macro status FontString for one
-- slot. Two branches per D-13: GetMacroIndexByName returns 0 when no macro
-- matches the exact name, or a positive integer = macro table slot. Either
-- value flips the status surface atomically. SECURE-03 mandates this lookup
-- as the diagnostic surface for macro presence; D-29 is explicit that we do
-- NOT create the macro automatically -- the user must create "PRESCIENCE N"
-- via the WoW macro UI. The `not index or index == 0` double-check covers
-- any WoW API edge case where GetMacroIndexByName returns nil instead of 0.
function Config:RefreshMacroStatus(slot)
    if slot ~= 1 and slot ~= 2 then return end
    local fs = PH.Config._widgets.status.macro[slot]
    if not fs then return end

    local macroName = "PRESCIENCE " .. slot
    local index = GetMacroIndexByName(macroName)

    local text
    if not index or index == 0 then
        text = ("|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t Macro \"%s\" introuvable"):format(macroName)  -- D-13
    else
        text = ("|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t Macro \"%s\" trouvee"):format(macroName)  -- D-13
    end

    fs:SetText(text)
end

-- Config:RefreshAll -- run both refresh methods for both slots. Called from:
--   - Config:OnDbReady (Task 2) -- initial paint right after PH.db is ready,
--     so the panel is diagnosable immediately on first user open even if
--     PH_CACHE_REBUILT has not fired yet (e.g. user logs in solo, opens
--     config before joining a raid).
--   - _panel OnShow (Task 2) -- every panel open, so widget sync + status
--     refresh happen together and the full panel snaps to live state
--     regardless of which events fired while the panel was hidden (D-14).
--   - Config:OnCacheRebuilt / OnMacrosChanged / OnTestModeChanged (Task 2) --
--     event-driven incremental refresh paths (though those handlers call
--     the per-slot methods directly rather than RefreshAll; RefreshAll is
--     for the full-panel "paint everything" sites).
-- D-16 permits the always-full-refresh pattern: 4 string builds + 4 SetText
-- + 4 SetTextColor is trivially cheap on any modern client.
function Config:RefreshAll()
    for slot = 1, 2 do
        Config:RefreshResolutionStatus(slot)
        Config:RefreshMacroStatus(slot)
    end
end

-- 5.6 Event handlers (D-11, D-15, D-27, D-28, D-30) ---------------------------
-- Plan 04-03 Task 2 payload: the three Core.lua-dispatched handlers that drive
-- the refresh methods above. Each handler follows the standard Core.lua
-- dispatch signature (module, event, ...) -- the event string is used only
-- for the debug trace. All three handlers restrict their work to per-slot
-- partial refresh (resolution OR macro, not both) because each driving event
-- has an orthogonal semantic cause; the full RefreshAll fan-out is reserved
-- for the panel-open path (OnDbReady / OnShow) where "paint everything" is
-- cheaper than classifying which subset changed.

-- Config:OnCacheRebuilt -- PH_CACHE_REBUILT subscriber (D-11 + D-30).
-- Tracker.lua fires PH_CACHE_REBUILT on any resolution rebuild: cold activate,
-- roster-update debounce flush, test-mode toggle, EditBox commit via
-- Tracker:Resolve(). We only need resolution-status refresh here -- macro
-- status is orthogonal and refreshes on UPDATE_MACROS only.
function Config:OnCacheRebuilt(event)
    if PH.debug then
        print(("[PH] Config:%s"):format(event))
    end
    for slot = 1, 2 do
        Config:RefreshResolutionStatus(slot)
    end
end

-- Config:OnMacrosChanged -- UPDATE_MACROS subscriber (D-27 + D-28 + SECURE-03).
-- UPDATE_MACROS is the WoW-native event (no PH_ prefix) that fires on macro
-- create, delete, and rename. Two things happen here:
--   (a) local macro-status paint refresh (D-27 / CONFIG-05 surfacing)
--   (b) PH_MACROS_CHANGED fan-out (D-28 / SECURE-03 UI leg) so Plan 04-04's
--       UI subscriber re-runs ApplySecureBinding for both slots -- UI's
--       combat-gate (UI.lua lines 623-630 region) handles the InCombatLockdown
--       deferral path, so no duplication of that gate logic here.
-- Separating (a) and (b) keeps responsibilities clean: Config informs the
-- user via the status line; UI re-binds the secure attributes. The event
-- name "PH_MACROS_CHANGED" is a string literal at the fire site -- no
-- dynamic construction (T-04-03-05 spoofing mitigation).
function Config:OnMacrosChanged(event, ...)
    if PH.debug then
        print(("[PH] Config:%s"):format(event))
    end
    for slot = 1, 2 do
        Config:RefreshMacroStatus(slot)
    end
    PH.Core:Fire("PH_MACROS_CHANGED")
end

-- Config:OnTestModeChanged -- PH_TEST_MODE_CHANGED subscriber (D-15 + D-30).
-- Config FIRES PH_TEST_MODE_CHANGED from its own test-checkbox OnClick (Plan
-- 04-02); it ALSO subscribes here. Core.lua dispatches synchronously to all
-- subscribers (Core.lua dispatch loop), so Config's own OnTestModeChanged
-- runs AFTER Tracker's OnTestModeChanged within the same tick -- meaning
-- PH.slots has already been updated by Tracker:Resolve by the time
-- RefreshResolutionStatus reads it. This is the correct ordering for the
-- status paint. Belt-and-suspenders given that PH_CACHE_REBUILT will also
-- fire from Tracker as a consequence; cheap per D-16.
function Config:OnTestModeChanged(event)
    if PH.debug then
        print(("[PH] Config:%s"):format(event))
    end
    for slot = 1, 2 do
        Config:RefreshResolutionStatus(slot)
    end
end

-- 6. Event registrations ------------------------------------------------------
-- Phase 4 Config claims 4 event subscriptions spread across Plans 04-01..04-03.
-- After Plan 04-03 the registration block is COMPLETE with 4 / 4:
--   * 04-01: PH_DB_READY         -> Config:OnDbReady
--   * 04-03: PH_CACHE_REBUILT    -> Config:OnCacheRebuilt       (resolution refresh)
--   * 04-03: UPDATE_MACROS       -> Config:OnMacrosChanged      (macro refresh + PH_MACROS_CHANGED fan-out)
--   * 04-03: PH_TEST_MODE_CHANGED -> Config:OnTestModeChanged    (test-mode resolution re-render)
-- Notes:
--   - UPDATE_MACROS is WoW-native so it flows through Core.lua's
--     PH.Core._dispatcher:RegisterEvent path (Core.lua line 63 region).
--   - The synthetic PH_MACROS_CHANGED event fired by OnMacrosChanged bypasses
--     that path and dispatches only through the internal subscription table.
--   - Plan 04-04 adds one registration on UI.lua (PH_MACROS_CHANGED subscriber)
--     that belongs to UI's Section 6, not here.
-- Registration order mirrors the Tracker.lua Section 9 convention -- block
-- placed at file tail after every handler method is defined so the dispatcher
-- sees the method name resolved.
PH.Core:RegisterEvent("PH_DB_READY", PH.Config, "OnDbReady")
PH.Core:RegisterEvent("PH_CACHE_REBUILT",     PH.Config, "OnCacheRebuilt")
PH.Core:RegisterEvent("UPDATE_MACROS",        PH.Config, "OnMacrosChanged")
PH.Core:RegisterEvent("PH_TEST_MODE_CHANGED", PH.Config, "OnTestModeChanged")
