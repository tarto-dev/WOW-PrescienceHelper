-- UI.lua -- Secure action icons, state rendering, countdown timer, drag & sound.
--
-- Phase 3 scope: consumes the 6 PH_* events fired by Tracker.lua to render
-- 2 SecureActionButtonTemplate icons (48x48) with border state, cooldown swipe,
-- numeric timer, right-click macro cast, drag + anchor persistence, and a
-- drop-warning sound. Hides out of raid (ACTIV-02) via PH_ACTIVATED/DEACTIVATED.
-- All rendering logic lives here; Core.lua, Tracker.lua, Config.lua are frozen.
local ADDON_NAME, PH = ...

local UI = PH.UI

-- 1. Constants (D-06, D-08, UI-01, UI-02) ------------------------------------
-- Prescience spellID -- same numeric id Tracker uses (Tracker.lua line 66) so
-- that the localised-name pitfall (IsSpellInRange / GetSpellTexture returning
-- nil on non-enUS clients when passed a name) is avoided here too. Passed to
-- C_Spell.GetSpellTexture for the icon art (UI-02).
local SPELL_ID_PRESCIENCE = 409311

-- Border color palette (CONTEXT.md D-08). All 3 state colors are declared here
-- so the full state-visual vocabulary lives in one place; only BORDER_GREY is
-- used by this plan (03-01 paints every border grey at init). BORDER_RED and
-- BORDER_GREEN are consumed by 03-02's state classifier when it paints the
-- 4 visual states (unresolved / absent / active-out-of-range / active-in-range).
local BORDER_GREY  = { 0.5, 0.5, 0.5, 1.0 }
local BORDER_RED   = { 1.0, 0.2, 0.2, 1.0 }
local BORDER_GREEN = { 0.2, 0.9, 0.2, 1.0 }

-- Icon geometry. UI-01 locks the 48x48 button size. BORDER_THICKNESS is the
-- discretionary slot from D-05: try 2 px first, drop to 1 if 03-05 UAT
-- reports visual noise. Both values are referenced from exactly one site below
-- so a future tweak is a single-line change.
local ICON_SIZE        = 48
local BORDER_THICKNESS = 2

-- 2. Module state init (D-01..D-04) ------------------------------------------
-- PH.UI._root is a single hierarchical anchor that parents both buttons so a
-- single Show()/Hide() on _root cascades to the pair atomically (D-01, ACTIV-02
-- gate half). D-02: no backdrop / no texture on _root -- pure grouping anchor,
-- sized 1x1 because the buttons carry their own SetPoint against UIParent.
-- D-03: MEDIUM strata keeps the HUD above the world frame but below dialogs
-- and chat. Idempotent `or CreateFrame` (mirrors Tracker's _ranger idiom) so a
-- mid-session /reload reuses the existing frame rather than leaking a new one.
PH.UI._root = PH.UI._root or CreateFrame("Frame", nil, UIParent)
PH.UI._buttons = PH.UI._buttons or {}

PH.UI._root:SetSize(1, 1)
PH.UI._root:SetFrameStrata("MEDIUM")
-- Hidden at init; OnActivated flips to Show() when Tracker fires PH_ACTIVATED
-- (raid entry or test-mode toggle on). Section 7 handles the rare cold-path
-- where UI.lua loads after isActive is already true (mid-raid /reload).
PH.UI._root:Hide()

-- Combat gate flag (D-23, SECURE-02). Maintained by PLAYER_REGEN_DISABLED /
-- PLAYER_REGEN_ENABLED handlers below (Section 5.7 in 03-04). Mirrors the
-- PH.state.isActive idiom -- cached boolean that every secure-attribute call
-- site short-circuits on alongside the authoritative InCombatLockdown() check.
-- The `or false` guard keeps the flag idempotent through /reload so a reload
-- performed mid-combat does not accidentally flip the flag back to nil before
-- PLAYER_REGEN_* have had a chance to re-fire. Any SetAttribute call on the
-- buttons is gated by InCombatLockdown() inside UI:ApplySecureBinding; this
-- flag is defense-in-depth + a debug handle (/dump PH.state.inCombat).
PH.state.inCombat = PH.state.inCombat or false

-- 3. Local helper: createButton(slot) (D-04..D-06, D-09, D-10) ---------------
-- Builds one SecureActionButtonTemplate button with all its child components
-- (icon, 4 border edges, cooldown swipe, numeric timer FontString) and returns
-- it. Idempotent on the slot index: a second call for the same slot returns
-- the existing button unchanged, which keeps `/reload` cheap and safe. The
-- helper deliberately does NOT bind secure attributes (SECURE-01, deferred to
-- 03-04 after the combat gate exists) and does NOT enable drag movement
-- (UI-08 / UI-09, deferred to 03-04). The cooldown frame and timer FontString
-- are created but left unprimed -- 03-02 drives the cooldown swipe on aura
-- events, 03-03 drives button.timer text on the per-icon ticker loop.
local function createButton(slot)
    if PH.UI._buttons[slot] then return PH.UI._buttons[slot] end

    -- D-04: global frame name "PrescienceHelperIcon1" / "PrescienceHelperIcon2"
    -- so other addons (WeakAuras, etc.) can reference the frames by name.
    -- SecureActionButtonTemplate is the WoW-sanctioned template for right-
    -- click macro binding; the actual secure-attribute wiring lives in 03-04.
    local name = "PrescienceHelperIcon" .. slot
    local button = CreateFrame("Button", name, PH.UI._root, "SecureActionButtonTemplate")
    button:SetSize(ICON_SIZE, ICON_SIZE)

    -- Default position from Core.lua DB_DEFAULTS (-60 / +60 from screen center).
    -- OnActivated will call applyAnchor(button, slot) on every activation, which
    -- overrides this with PH.db.anchors[slot] once the DB is merged (D-25).
    button:SetPoint("CENTER", UIParent, "CENTER", (slot == 1) and -60 or 60, 0)

    -- Main icon texture (D-06, UI-02). ARTWORK layer sits above the button's
    -- default background but below the 4 OVERLAY border edges drawn below.
    -- C_Spell.GetSpellTexture is the modern API (legacy GetSpellTexture is
    -- deprecated); Tracker.lua uses C_Spell.IsSpellInRange so staying on the
    -- same namespace keeps the module conventions aligned.
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints(button)
    button.icon:SetTexture(C_Spell.GetSpellTexture(SPELL_ID_PRESCIENCE))

    -- 4 border edges (D-05, UI-06 initial grey state). Each edge is a plain
    -- OVERLAY texture painted with SetColorTexture -- no BackdropTemplate, no
    -- nine-slice art, just 4 solid-color rectangles hugging each edge. State
    -- transitions to BORDER_RED / BORDER_GREEN arrive in 03-02 via individual
    -- SetColorTexture calls on the same 4 textures. Thickness is fixed at
    -- BORDER_THICKNESS (= 2 px) per D-05's discretionary default.
    local function makeEdge()
        local tex = button:CreateTexture(nil, "OVERLAY")
        tex:SetColorTexture(BORDER_GREY[1], BORDER_GREY[2], BORDER_GREY[3], BORDER_GREY[4])
        return tex
    end
    button.borderTop    = makeEdge()
    button.borderBottom = makeEdge()
    button.borderLeft   = makeEdge()
    button.borderRight  = makeEdge()

    -- Top edge: full width, fixed height, glued to the top of the button.
    button.borderTop:SetPoint("TOPLEFT",  button, "TOPLEFT",  0, 0)
    button.borderTop:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
    button.borderTop:SetHeight(BORDER_THICKNESS)
    -- Bottom edge: full width, fixed height, glued to the bottom.
    button.borderBottom:SetPoint("BOTTOMLEFT",  button, "BOTTOMLEFT",  0, 0)
    button.borderBottom:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    button.borderBottom:SetHeight(BORDER_THICKNESS)
    -- Left edge: full height, fixed width, glued to the left.
    button.borderLeft:SetPoint("TOPLEFT",    button, "TOPLEFT",    0, 0)
    button.borderLeft:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    button.borderLeft:SetWidth(BORDER_THICKNESS)
    -- Right edge: full height, fixed width, glued to the right.
    button.borderRight:SetPoint("TOPRIGHT",    button, "TOPRIGHT",    0, 0)
    button.borderRight:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    button.borderRight:SetWidth(BORDER_THICKNESS)

    -- Cooldown swipe overlay (D-09, UI-03). Created here, driven by 03-02 on
    -- PH_AURA_CHANGED via the stock cooldown-frame priming API (start / duration
    -- / enable). The frame is idle on load -- no swipe until 03-02 wires the
    -- aura render.
    button.cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    button.cd:SetAllPoints(button)

    -- Numeric timer (D-10, UI-04). GameFontNormalLarge is the WoW stock outlined
    -- template -- legible over the 48x48 icon art. Centered on the button; text
    -- is blank until 03-03's per-icon OnUpdate loop writes the floor(remaining)
    -- each 0.1 s while hasPrescience is true.
    button.timer = button:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    button.timer:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.timer:SetText("")

    -- Phase 5 polish: pseudo (without realm) under the icon. GameFontNormalSmall
    -- keeps the label visually subordinate to the timer; anchored 2 px below the
    -- button so it never overlaps the swipe / border / timer trio. Updated by
    -- UI:RefreshNameLabel(slot) on every PH_CACHE_REBUILT or activation
    -- transition -- the label is blank when the slot is unresolved or empty.
    button.nameLabel = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.nameLabel:SetPoint("TOP", button, "BOTTOM", 0, -2)
    button.nameLabel:SetText("")

    -- Drag enablement (D-21, UI-08, UI-09). RegisterForDrag("LeftButton") binds
    -- the drag gesture to the LEFT mouse button, leaving RIGHT-click untouched
    -- so the secure macro binding (type2/macro2 wired by UI:ApplySecureBinding
    -- below) can fire on right-click without colliding with repositioning.
    -- SetClampedToScreen(true) prevents a user from dragging an icon outside
    -- the visible UIParent bounds where they could lose track of it. Set once
    -- at createButton time so idempotent reloads reuse the existing settings.
    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")
    button:SetClampedToScreen(true)

    -- OnDragStart (D-22, UI-09, SECURE-02). Double gate: (1) PH.db.lock == true
    -- blocks repositioning per the user's lock preference (UI-09); (2) combat
    -- lockdown blocks repositioning on SecureActionButtonTemplate regardless
    -- of lock (SECURE-02 -- secure frames are immutable in combat). Silent
    -- no-op on either gate -- the canonical WoW UX pattern (users expect
    -- "cannot reposition mid-pull" with no visual feedback; T-03-04-03 accept).
    -- The `slot` upvalue is captured per createButton invocation so slot 1 and
    -- slot 2 own distinct closures despite sharing this function body.
    button:SetScript("OnDragStart", function(self)
        if PH.db and PH.db.lock then return end
        if InCombatLockdown() then return end
        self:StartMoving()
    end)

    -- OnDragStop (D-22, UI-08). StopMovingOrSizing halts the WoW-native drag
    -- driver (mirror of StartMoving); we then read the new position via
    -- GetPoint(1) which returns (point, relativeTo, relativePoint, x, y). The
    -- relativeTo frame reference is intentionally NOT persisted -- Core.lua
    -- DB_DEFAULTS.anchors only carries {point, relPoint, x, y} and applyAnchor
    -- (read side, 03-01) always passes UIParent. Defensive `or` fallbacks on
    -- each scalar protect against GetPoint returning nils on pathological edge
    -- cases (T-03-04-02 tampering mitigation); malformed values also survive
    -- the applyAnchor round-trip thanks to its per-field type validation.
    -- Save is IMMEDIATE on drop per D-22 -- no deferred write to logout, so
    -- a /reload right after repositioning persists the new anchor reliably.
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

-- 4. Local helper: applyAnchor(button, slot) (D-25, UI-08 read side) ---------
-- Restores a saved position from PH.db.anchors[slot] onto a button. Runs on
-- every PH_ACTIVATED dispatch and on the cold-path catch-up below, so that a
-- position mutation performed via /run PrescienceHelperDB... between sessions
-- is picked up on the next activation without needing a new save roundtrip.
--
-- Defense against T-03-01-01 (tampering): another addon or the user may leave
-- PH.db.anchors[slot] in a malformed state (missing fields, non-numeric x/y).
-- We validate each field explicitly and fall back to the Core.lua DB_DEFAULTS
-- values rather than passing nil to SetPoint (which would raise a Lua error
-- and break the whole activation). The save side (OnDragStop writing back
-- PH.db.anchors[slot]) lives in 03-04.
local function applyAnchor(button, slot)
    -- SecureActionButtonTemplate inherits protected behaviour: ClearAllPoints
    -- and SetPoint are blocked in combat (throws a TAINT Lua error and breaks
    -- the whole addon). Gate on InCombatLockdown() and record a pending flag;
    -- OnRegenEnabled retries when combat ends. This covers:
    --   - PH_ACTIVATED fired mid-combat (GROUP_ROSTER_UPDATE / PLAYER_ENTERING_WORLD)
    --   - /reload in the middle of a pull (cold-path top-level applyAnchor)
    if InCombatLockdown() then
        button._anchorPending = true
        return
    end
    local a = PH.db and PH.db.anchors and PH.db.anchors[slot]
    if not (a and type(a.point) == "string" and type(a.relPoint) == "string"
            and type(a.x) == "number" and type(a.y) == "number") then
        -- Fallback mirrors Core.lua DB_DEFAULTS.anchors -- keeps the two sites
        -- in sync without reaching into Core's upvalue.
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

-- 4.5 State classifier + visual helpers (D-05..D-08, UI-06, UI-07) ----------
-- These upvalue helpers are the atomic building blocks consumed by the three
-- Render methods below. Keeping them module-local (not on PH.UI) preserves the
-- namespace discipline and lets the inliner collapse them at call sites.

-- Classify a slot's visual state from PH.slots. Returns one of four string
-- tokens consumed by the Render* methods (D-05 state table in 03-CONTEXT.md):
--   "unresolved" -- PH.slots[slot].resolved == false (no raid member matched)
--   "absent"     -- resolved but hasPrescience == false (must reapply)
--   "oor"        -- hasPrescience == true but inRange == false (> 25 yd)
--   "inrange"    -- hasPrescience == true and inRange == true (nominal)
-- The 4 tokens map 1:1 to the 4 visual states from ROADMAP success criterion 1
-- and to the UI-06 state ladder in REQUIREMENTS.md.
local function slotVisualState(slot)
    local s = PH.slots[slot]
    if not s.resolved then return "unresolved" end
    if not s.hasPrescience then return "absent" end
    if s.inRange then return "inrange" else return "oor" end
end

-- Paint all 4 border edges with a BORDER_* color table (D-05, D-08). The color
-- table is { r, g, b, a } with floats in 0..1. We splat the 4 components into
-- each edge's SetColorTexture call so a single helper covers every border
-- repaint in the render chain.
local function setBorderColor(button, color)
    local r, g, b, a = color[1], color[2], color[3], color[4]
    button.borderTop:SetColorTexture(r, g, b, a)
    button.borderBottom:SetColorTexture(r, g, b, a)
    button.borderLeft:SetColorTexture(r, g, b, a)
    button.borderRight:SetColorTexture(r, g, b, a)
end

-- Idempotent pulse start/stop for the "absent" state (D-07, UI-06).
-- UIFrameFlash does NOT guard against being called twice with the same frame;
-- each call installs a new flash driver on top of the previous one, leading to
-- visible stacking and a progressively faster pulse. We track a per-button
-- boolean sentinel (_pulsing) so startPulse is safe to call from every
-- RenderAura invocation and stopPulse is safe to call on every state change.
-- Parameters: fadeIn 0.5s, fadeOut 0.5s, duration -1 (infinite), showWhenDone
-- true, no hold times -- matches the D-07 default.
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

-- Timer color thresholds per D-11 / UI-05. Returns (r, g, b) triple consumed by
-- FontString:SetTextColor. Break-points inclusive on the lower side:
--   remaining > 5       -> white  (1, 1, 1)
--   2 < remaining <= 5  -> yellow (1, 1, 0)
--   remaining <= 2      -> red    (1, 0.2, 0.2)
-- Matches the 3-tier color ladder that amplifies urgency as Prescience nears
-- expiration -- the visual companion to the audible drop cue in OnPrescienceDropped.
local function timerColorFor(remaining)
    if remaining > 5 then return 1, 1, 1 end
    if remaining > 2 then return 1, 1, 0 end
    return 1, 0.2, 0.2
end

-- Install the per-button 0.1s accumulator OnUpdate closure (D-12, D-13). The
-- `acc` upvalue is captured by the closure so detaching the script (setting
-- OnUpdate back to nil in stopTimerLoop) frees it automatically via garbage
-- collection -- no explicit reset bookkeeping needed on the button. Idempotent:
-- if a loop is already installed, the new assignment replaces the previous
-- closure; the fresh acc starts at 0 which is harmless since the next tick
-- comes at most 0.1s later. Pattern mirrors Tracker._ranger's closure install
-- in UpdateActivation (Tracker.lua lines 304-307).
local function startTimerLoop(button, slot)
    local acc = 0
    button:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc < 0.1 then return end
        acc = 0
        UI:TickTimer(slot)
    end)
end

-- Detach the OnUpdate closure and blank the FontString so a stale value never
-- lingers between transitions (e.g. "2" left over when hasPrescience flips
-- false). D-13 idle-complete: dropping the script halts per-icon tick work
-- entirely -- zero CPU budget when the slot is not in an active state.
local function stopTimerLoop(button)
    button:SetScript("OnUpdate", nil)
    if button.timer then
        button.timer:SetText("")
    end
end

-- 5. Activation handlers (D-15, D-16, ACTIV-02) ------------------------------
-- Dispatcher-invoked methods. Signatures follow the Core.lua dispatch contract:
-- module[methodName](module, event, ...) -- so `self` is PH.UI and the first
-- explicit parameter is the event name. Both handlers emit a PH.debug-gated
-- trace print at entry per the Tracker.lua idiom (7 sites using :format).

-- PH_ACTIVATED: fired by Tracker on the inactive->active transition (raid entry
-- or test-mode toggle on). Restore both anchors from the DB (D-25) then Show()
-- the root, which cascades visibility to both buttons via the _root parent
-- link (D-01). Called on every activation, not only the first, so anchor
-- updates between sessions are always re-applied.
function UI:OnActivated(event)
    if PH.debug then
        print((PH.prefix .. " UI:%s"):format(event))
    end
    for slot = 1, 2 do
        applyAnchor(PH.UI._buttons[slot], slot)
    end
    PH.UI._root:Show()
    -- Initial repaint so the icons show the correct state immediately on raid
    -- entry. Tracker fires PH_CACHE_REBUILT right after PH_ACTIVATED per Phase 2
    -- D-10 ordering (which would re-render via OnCacheRebuilt), but calling
    -- RenderResolution directly here keeps the UI self-sufficient and avoids a
    -- one-tick "static grey" flicker if event ordering ever shifts.
    for slot = 1, 2 do
        UI:RenderResolution(slot)
        UI:RefreshNameLabel(slot)
    end
end

-- PH_DEACTIVATED: fired on the active->inactive transition (raid exit or test-
-- mode toggle off outside raid). Hide the root; children cascade. Cooldown /
-- timer / flash teardown is the concern of 03-02 and 03-03 -- here a plain
-- Hide is sufficient because this plan installs no ticker and no cooldown
-- animation on the buttons. When 03-03 wires the per-icon ticker loop, this
-- handler will extend to drop the per-button update callback and clear the
-- cooldown swipe per D-16; the _root:Hide() call remains the authoritative
-- visibility flip.
function UI:OnDeactivated(event)
    if PH.debug then
        print((PH.prefix .. " UI:%s"):format(event))
    end
    PH.UI._root:Hide()
    -- Teardown per D-16: stop any active pulse and clear the cooldown swipe so
    -- a hidden _root does not leave background animation running when it re-
    -- shows later (the _root:Hide() alone does not kill UIFrameFlash, which
    -- operates on the frame's alpha via its own driver). Guarded on button
    -- existence so a bootstrap-ordering regression still fails loud.
    for slot = 1, 2 do
        local button = PH.UI._buttons[slot]
        if button then
            stopPulse(button)
            button.cd:Clear()
            stopTimerLoop(button)  -- D-13 idle-on-deactivation: drop the
                                   -- per-button OnUpdate so an idle session
                                   -- (raid exit) costs zero CPU per tick
        end
    end
end

-- 5.5 Render methods (D-09, D-14, D-17, D-18, D-20, UI-03, UI-06, UI-07) -----
-- Three granular render methods, one per event class. Each method reads
-- PH.slots[slot] fresh (never caches state) and paints the 4 visual primitives:
-- border color, desaturation, cooldown swipe, pulse. All three are idempotent
-- and safe to call in any order on a given slot -- the net effect after the
-- last call is exactly the correct visual state for the current PH.slots data.

-- RenderResolution(slot) -- paint the resolution layer. When the slot is
-- unresolved (not in raid or target name did not match) we apply the grey-
-- border + desaturated + no-pulse + no-cooldown look per UI-06 / UI-07. When
-- resolved we delegate to RenderAura so a single call per slot from
-- OnCacheRebuilt / OnActivated gives a full repaint across the 3 resolved
-- states (absent / oor / inrange). D-17 anchor.
function UI:RenderResolution(slot)
    local button = PH.UI._buttons[slot]
    if not button then return end
    if slotVisualState(slot) == "unresolved" then
        setBorderColor(button, BORDER_GREY)
        button.icon:SetDesaturated(true)
        stopPulse(button)
        button.cd:Clear()
        stopTimerLoop(button)  -- D-13 defensive: covers the race where a
                               -- resolved+active slot suddenly un-resolves
                               -- (e.g. roster delta while Prescience is up)
        return
    end
    -- Resolved: hand off to RenderAura for the 3 resolved states. RenderAura
    -- will in turn delegate range-dependent border color to RenderRange, so
    -- the full visual state is produced in one call chain.
    UI:RenderAura(slot)
end

-- RenderAura(slot) -- paint the aura layer. Handles the "absent" case (red
-- border + pulse + desaturated + cooldown cleared) and the 2 active cases
-- (full color + no pulse + cooldown swipe running). The cooldown frame is set
-- exactly once per cast here (D-09, D-14): WoW's stock Cooldown frame animates
-- the swipe natively, so no OnUpdate is needed for the animation itself. The
-- start timestamp is derived as `expirationTime - duration` so a refresh mid-
-- cast restarts the swipe from the new expiration rather than extending the
-- old one. Range-dependent border color is delegated to RenderRange. D-18.
function UI:RenderAura(slot)
    local button = PH.UI._buttons[slot]
    if not button then return end
    local state = slotVisualState(slot)
    if state == "unresolved" then
        -- Resolution layer owns this state; bounce back so we do not skip the
        -- grey paint if RenderAura is called directly on an unresolved slot
        -- (e.g. a racy PH_AURA_CHANGED arriving before PH_CACHE_REBUILT in a
        -- future Tracker refactor).
        UI:RenderResolution(slot)
        return
    end
    if state == "absent" then
        setBorderColor(button, BORDER_RED)
        button.icon:SetDesaturated(true)
        startPulse(button)
        button.cd:Clear()
        stopTimerLoop(button)  -- D-13 idle-on-absent: countdown ends the moment
                               -- Prescience drops, zero CPU until next refresh
        return
    end
    -- Active (oor or inrange): full color, no pulse, cooldown swipe running.
    button.icon:SetDesaturated(false)
    stopPulse(button)
    local s = PH.slots[slot]
    local start = s.expirationTime - s.duration
    CooldownFrame_Set(button.cd, start, s.duration, 1)
    startTimerLoop(button, slot)  -- D-13 run-while-active: idempotent replace,
                                  -- a ping-pong between oor and inrange does
                                  -- not stack loops -- SetScript overwrites
    -- Range-dependent border delegated to RenderRange (green for inrange, red
    -- for oor). Calling it here keeps the full state transition atomic within
    -- a single RenderAura invocation.
    UI:RenderRange(slot)
end

-- RenderRange(slot) -- paint the range layer only. Flips the border color
-- between BORDER_GREEN (inrange) and BORDER_RED (oor) with no other side
-- effect: the cooldown frame keeps animating, desaturation stays off, pulse
-- stays off. No-op outside the 2 active states to avoid stomping the grey
-- border of "unresolved" or the red-pulsing border of "absent" that the
-- resolution / aura layers own. D-20 anchor.
function UI:RenderRange(slot)
    local button = PH.UI._buttons[slot]
    if not button then return end
    local state = slotVisualState(slot)
    if state == "unresolved" or state == "absent" then return end
    if state == "inrange" then
        setBorderColor(button, BORDER_GREEN)
    else  -- oor
        setBorderColor(button, BORDER_RED)
    end
end

-- UI:TickTimer(slot) -- per-icon timer tick, called at ~10Hz from the OnUpdate
-- closure installed by startTimerLoop. Reads PH.slots[slot], writes integer
-- remaining seconds to button.timer and applies the D-11 color ladder. The
-- D-14 gate is belt-and-suspenders here: stopTimerLoop already removes the
-- script on transitions out of hasPrescience, but a race where the aura drops
-- mid-frame is possible -- the isActive + hasPrescience guards keep the UI
-- consistent with Tracker's source of truth (Phase 2 D-02). Blanking the text
-- on the racy-drop branch avoids a sub-100ms leftover digit between the fire
-- and the next RenderAura repaint.
function UI:TickTimer(slot)
    if not PH.state.isActive then return end
    local button = PH.UI._buttons[slot]
    if not button then return end
    local s = PH.slots[slot]
    if not s.hasPrescience then
        -- Race: aura dropped between fire and tick. stopTimerLoop will be
        -- called by OnAuraChanged's RenderAura(absent branch) in the same
        -- dispatch, but a pending OnUpdate tick may still fire before that.
        -- Blank the text and bail so no stale digit lingers for one frame.
        button.timer:SetText("")
        return
    end
    local remaining = s.expirationTime - GetTime()
    if remaining < 0 then remaining = 0 end
    button.timer:SetText(tostring(math.floor(remaining)))
    button.timer:SetTextColor(timerColorFor(remaining))
end

-- 5.6 State-render event handlers (D-14, D-17, D-18, D-20) -------------------
-- Consumer-side handlers for the 3 state-change events fired by Tracker. All
-- three follow the Tracker.lua idiom: PH.debug-gated trace print at entry,
-- D-14 defense-in-depth gate (`if not PH.state.isActive then return end`), then
-- granular call to the appropriate Render* method. The D-14 gate is redundant
-- with the _root:Hide() visibility flip (the user cannot see the result of a
-- render on a hidden button), but it keeps these handlers safe to call from
-- any future site and aligns with Tracker's consumer-handler pattern (ScanAuras
-- / TickRange / OnUnitAura all apply the same gate).

-- PH_CACHE_REBUILT: Tracker fired a full resolution rebuild (raid entry, test-
-- mode toggle, roster resolve). Re-render both slots from scratch --
-- RenderResolution routes unresolved slots to the grey paint and resolved
-- slots through the RenderAura + RenderRange delegation chain (D-17). No
-- payload on this event per 02-CONTEXT D-04 (consumers re-read PH.slots).
function UI:OnCacheRebuilt(event)
    if PH.debug then
        print((PH.prefix .. " UI:%s"):format(event))
    end
    if not PH.state.isActive then return end
    for slot = 1, 2 do
        UI:RenderResolution(slot)
        UI:RefreshNameLabel(slot)
    end
    -- Secure binding refresh (D-17). Binding values are slot-dependent but
    -- stable ("PRESCIENCE "..slot), so this is effectively a one-time setup
    -- the first time OnCacheRebuilt fires outside combat. Re-running on every
    -- rebuild is cheap (idempotent SetAttribute) and covers the edge case
    -- where the first rebuild happened in combat (D-24) -- the next rebuild
    -- (typically a roster update post-encounter) will land the binding.
    -- OnRegenEnabled provides the other leg of the D-24 deferred flush.
    for slot = 1, 2 do
        UI:ApplySecureBinding(slot)
    end
end

-- UI:RefreshNameLabel(slot) -- Phase 5 polish. Paints button.nameLabel with
-- the resolved player's pseudo (without realm) below the icon. Reads PH.slots
-- and strips everything from the first "-" onward to drop the realm suffix
-- ("Tarto-Hyjal" -> "Tarto"). Empty when the slot is unresolved or fullName
-- is missing. Defensive guards: button absence (deactivated UI), nameLabel
-- absence (createButton skipped, e.g. test harness), PH.slots absence
-- (pre-PH_DB_READY) all return early without erroring.
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
    -- Strip realm suffix: "Nom-Realm" -> "Nom". Also handles "player" (test mode
    -- unitID) and any future bare unitID where no "-" is present (string.match
    -- returns nil, fallback to the original).
    local pseudo = s.fullName:match("^([^-]+)") or s.fullName
    button.nameLabel:SetText(pseudo)
end

-- PH_AURA_CHANGED(slot): Tracker saw a Prescience aura state delta on this
-- slot (gained, lost, refreshed). Re-render aura + range for this slot only,
-- which also (re)sets the cooldown swipe via CooldownFrame_Set if hasPrescience
-- is true, or clears it otherwise (D-09, D-14, D-18). T-03-02-01 mitigation:
-- payload guard rejects malformed slot values before we index PH.slots[slot].
function UI:OnAuraChanged(event, slot)
    if PH.debug then
        print((PH.prefix .. " UI:%s slot=%s"):format(event, tostring(slot)))
    end
    if not PH.state.isActive then return end
    if slot ~= 1 and slot ~= 2 then return end
    UI:RenderAura(slot)
end

-- PH_RANGE_CHANGED(slot): Tracker saw a range boolean flip. Re-render range
-- only; border flips green<->red when state is oor/inrange, no-op otherwise
-- (D-20). No cooldown re-set -- the cooldown is set once per cast by
-- RenderAura (D-14 set-once-per-cast). T-03-02-01 mitigation as above.
function UI:OnRangeChanged(event, slot)
    if PH.debug then
        print((PH.prefix .. " UI:%s slot=%s"):format(event, tostring(slot)))
    end
    if not PH.state.isActive then return end
    if slot ~= 1 and slot ~= 2 then return end
    UI:RenderRange(slot)
end

-- PH_PRESCIENCE_DROPPED(slot): Tracker fired this on the hasPrescience
-- true -> false transition. Per Phase 2 D-10 dispatch order, PH_AURA_CHANGED
-- arrives first within the same tick, so by the time this handler runs the
-- icon has already flipped to the "absent" visuals (red + pulse + desat) via
-- OnAuraChanged -> RenderAura. Our job here is only the audible cue. D-19
-- mandates PlaySound(SOUNDKIT.RAID_WARNING, "Master"); D-27 locks the Master
-- channel so volume follows the Master slider rather than ambient/effect
-- subchannels that can be muted individually. D-28 is explicit about the
-- absence of debouncing: Prescience drops are discrete events, and v1 does
-- not attempt to suppress pathological multi-drops -- Phase 5 QA will revisit
-- if real-world cases appear. T-03-03-03 tampering: slot payload guard rejects
-- anything other than 1 or 2 before we touch state.
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

-- UI:OnMacrosChanged(event) -- Phase 4 subscriber (D-28) added by Plan 04-04.
-- Config.lua fires PH_MACROS_CHANGED from its own macro-list change handler
-- (Plan 04-03), fanning out to UI so the secure macro2 attribute re-binds when
-- the user creates, deletes, or renames the PRESCIENCE N macro. We do NOT add
-- another combat gate here -- ApplySecureBinding's InCombatLockdown() check
-- (see the method below in Section 5.7) is the single authoritative gate, and
-- OnRegenEnabled's deferred re-bind loop is the combat-exit catch-up leg per
-- D-24. Re-binding to the same macro name is idempotent on the secure
-- attribute layer, so the call is essentially free when the triggering macro
-- list change was unrelated to our slot names (the typical case).
function UI:OnMacrosChanged(event)
    if PH.debug then
        print((PH.prefix .. " UI:%s"):format(event))
    end
    for slot = 1, 2 do
        UI:ApplySecureBinding(slot)
    end
end

-- 5.7 Secure binding + combat gate (D-17, D-23, D-24, SECURE-01, SECURE-02) --
-- Single canonical site for the type2/macro2 SetAttribute pair (SECURE-01) and
-- the combat lockdown guard (SECURE-02 / D-23). Collocating the two enforces
-- the invariant "no SetAttribute can ever execute while InCombatLockdown() is
-- true" by construction -- every caller goes through ApplySecureBinding, so
-- there is no other code path where the gate could be bypassed (T-03-04-01
-- mitigation). The guard is authoritative: PH.state.inCombat is a cached
-- debug handle, the InCombatLockdown() call is the runtime source of truth.
-- D-24 deferred flush: if the user enters combat BEFORE the first cache
-- rebuild (or between it and the binding call), the SetAttribute calls are
-- skipped silently; UI:OnRegenEnabled re-invokes ApplySecureBinding for both
-- slots on combat exit to catch up. The accepted failure mode (documented
-- canonical WoW limitation): the first right-click of a combat that started
-- before setup is a no-op. The macro name "PRESCIENCE " .. slot matches the
-- user's existing macros verbatim (PROJECT.md "specifics" section).
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

-- PLAYER_REGEN_DISABLED (D-23). Fires on combat start. Flip the inCombat flag
-- so any subsequent ApplySecureBinding invocation short-circuits alongside
-- the authoritative InCombatLockdown() check. We do NOT queue pending
-- bindings here -- OnCacheRebuilt re-fires on the next roster change after
-- combat ends, and OnRegenEnabled performs a defensive re-bind on exit, so
-- the missed-in-combat case is covered by two independent recovery paths.
function UI:OnRegenDisabled(event)
    if PH.debug then
        print((PH.prefix .. " UI:%s"):format(event))
    end
    PH.state.inCombat = true
end

-- PLAYER_REGEN_ENABLED (D-23, D-24). Fires on combat end. Clear the inCombat
-- flag and defensively re-apply BOTH slots' secure bindings. This is the
-- canonical "deferred flush" site -- if the user entered combat before the
-- first PH_CACHE_REBUILT (e.g. /reload during a pull), the binding was never
-- applied; this handler is the earliest safe point where a SetAttribute can
-- land. Idempotent: re-applying bindings that are already in place is a
-- harmless no-op on WoW's secure attribute layer.
function UI:OnRegenEnabled(event)
    if PH.debug then
        print((PH.prefix .. " UI:%s"):format(event))
    end
    PH.state.inCombat = false
    -- Flush pending anchor applies that were deferred because PH_ACTIVATED fired
    -- mid-combat (applyAnchor cannot ClearAllPoints/SetPoint on a protected frame
    -- while InCombatLockdown). Same deferred-flush pattern as the secure binding
    -- recovery below.
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

-- UI:ReapplyAnchors() -- Phase 4 public method (D-26) added by Plan 04-04 as
-- the canonical entry point for Config's "Reinitialiser les positions" button
-- (Plan 04-02 calls this after wiping PH.db.anchors back to Core's defaults).
-- Thin wrapper around the module-local applyAnchor helper: for each of the 2
-- slots, re-apply the stored anchor. The helper itself gates on
-- InCombatLockdown() and records a _anchorPending flag that OnRegenEnabled
-- later flushes (see applyAnchor + OnRegenEnabled above), so calling
-- ReapplyAnchors in combat is safe -- it becomes a queue-for-later rather than
-- a failure. Config's Reset handler also gates on combat belt-and-suspenders
-- style, so the dual gate covers both sides of the call site.
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

-- 6. Event registrations -----------------------------------------------------
-- Phase 3 owned 8/8 (03-01..03-04). Phase 4 Plan 04-04 adds 1 more
-- (PH_MACROS_CHANGED), total 9/9. Breakdown by originating plan:
--   03-01: PH_ACTIVATED, PH_DEACTIVATED                               (2 / 9)
--   03-02: PH_CACHE_REBUILT, PH_AURA_CHANGED, PH_RANGE_CHANGED        (3 / 9)
--   03-03: PH_PRESCIENCE_DROPPED                                      (1 / 9)
--   03-04: PLAYER_REGEN_DISABLED, PLAYER_REGEN_ENABLED                (2 / 9)
--   04-04: PH_MACROS_CHANGED                                          (9 / 9)
-- Registration order within this file follows the Tracker.lua convention of
-- placing the registration block at the bottom (after all method definitions)
-- so every handler name referenced is already defined when the dispatcher
-- receives the subscription. The two PLAYER_REGEN_* events are WoW-native
-- (not PH_*) and go through the same PH.Core:RegisterEvent path -- Core's
-- dispatcher (01-02) routes PH_-prefixed strings to the synthetic bus and
-- everything else to the WoW RegisterEvent path, so this sequence is uniform.
PH.Core:RegisterEvent("PH_ACTIVATED",          PH.UI, "OnActivated")
PH.Core:RegisterEvent("PH_DEACTIVATED",        PH.UI, "OnDeactivated")
PH.Core:RegisterEvent("PH_CACHE_REBUILT",      PH.UI, "OnCacheRebuilt")
PH.Core:RegisterEvent("PH_AURA_CHANGED",       PH.UI, "OnAuraChanged")
PH.Core:RegisterEvent("PH_RANGE_CHANGED",      PH.UI, "OnRangeChanged")
PH.Core:RegisterEvent("PH_PRESCIENCE_DROPPED", PH.UI, "OnPrescienceDropped")
PH.Core:RegisterEvent("PLAYER_REGEN_DISABLED", PH.UI, "OnRegenDisabled")
PH.Core:RegisterEvent("PLAYER_REGEN_ENABLED",  PH.UI, "OnRegenEnabled")
PH.Core:RegisterEvent("PH_MACROS_CHANGED",     PH.UI, "OnMacrosChanged")

-- 7. Cold-path catch-up (reload-mid-raid) ------------------------------------
-- Rare but real: if Tracker has already flipped PH.state.isActive to true by
-- the time UI.lua loads (e.g. /reload mid-raid, or a future load-order change
-- that queues Tracker ahead of UI), the PH_ACTIVATED fire has already been
-- dispatched and will NOT repeat. Without this catch-up, _root would stay
-- hidden until a deactivation+reactivation cycle occurs. We manually apply
-- both anchors and Show() the root to reach visual parity with the normal
-- activation path. Guarded on PH.state being present so a bootstrap ordering
-- regression (UI.lua loading before Core.lua sets PH.state) still fails loud
-- rather than silently.
if PH.state and PH.state.isActive then
    for slot = 1, 2 do
        applyAnchor(PH.UI._buttons[slot], slot)
    end
    PH.UI._root:Show()
    -- Repaint after Show so the catch-up path produces the same initial visual
    -- state as the normal PH_ACTIVATED flow. PH.slots may already hold the
    -- live raid state (Tracker's resolve ran before UI.lua loaded), so this
    -- renders absent/oor/inrange immediately rather than flashing grey.
    for slot = 1, 2 do
        UI:RenderResolution(slot)
    end
end
