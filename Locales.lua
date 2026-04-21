-- Locales.lua -- localization table keyed on English source strings.
-- enUS / default: __index returns the key itself, so untranslated strings
-- fall through as readable English rather than crashing or printing nil.

local ADDON_NAME, PH = ...

local L = setmetatable({}, { __index = function(_, k) return k end })
local locale = GetLocale()

if locale == "frFR" then
    -- Player slots
    L["Player 1"] = "Joueur 1"
    L["Player 2"] = "Joueur 2"
    -- Activation gates
    L["Enable in raid"]    = "Activer en raid"
    L["Enable in dungeon"] = "Activer en donjon"
    -- Behavior toggles
    L["Lock icons"]    = "Verrouiller les ic\195\180nes"       -- icones
    L["Test mode"]     = "Mode test"
    L["Sound enabled"] = "Son activ\195\169"                    -- active
    L["Debug mode"]    = "Mode debug"
    -- Action buttons
    L["Reset positions"]          = "R\195\169initialiser les positions"   -- Reinitialiser
    L["Save and recreate macros"] = "Enregistrer et recr\195\169er les macros" -- recreer
    -- Status lines (resolution)
    L["Empty name"]            = "Pseudo vide"
    L["Found as %s (%s)"]      = "Trouv\195\169 comme %s (%s)"               -- Trouve
    L["Not in current group"]  = "Pas dans le groupe actuel"
    -- Status lines (macro)
    L["Macro \"%s\" not found"] = "Macro \"%s\" introuvable"
    L["Macro \"%s\" found"]     = "Macro \"%s\" trouv\195\169e"              -- trouvee
    -- Combat-gated messages
    L["Not possible in combat. Try again after."] = "Impossible en combat. R\195\169essaie apr\195\168s." -- Reessaie apres
    L["Anchors reset."]                           = "Ancrages r\195\169initialis\195\169s."             -- reinitialises
    L["Macros PRESCIENCE 1 / 2 saved from config."] = "Macros PRESCIENCE 1 / 2 enregistr\195\169es depuis la config." -- enregistrees
    -- Debug print (Tracker): French-shaped in v1.1, now routed
    L["Macro %d used on %s"] = "Macro %d utilis\195\169e sur %s"             -- utilisee
end

if locale == "deDE" then
    L["Player 1"] = "Spieler 1"
    L["Player 2"] = "Spieler 2"
    L["Enable in raid"]    = "In Schlachtzug aktivieren"
    L["Enable in dungeon"] = "In Dungeon aktivieren"
    L["Lock icons"]    = "Symbole sperren"
    L["Test mode"]     = "Testmodus"
    L["Sound enabled"] = "Ton aktiviert"
    L["Debug mode"]    = "Debug-Modus"
    L["Reset positions"]          = "Positionen zur\195\188cksetzen"          -- zuruecksetzen
    L["Save and recreate macros"] = "Makros speichern und neu erstellen"
    L["Empty name"]            = "Name leer"
    L["Found as %s (%s)"]      = "Gefunden als %s (%s)"
    L["Not in current group"]  = "Nicht in der aktuellen Gruppe"
    L["Macro \"%s\" not found"] = "Makro \"%s\" nicht gefunden"
    L["Macro \"%s\" found"]     = "Makro \"%s\" gefunden"
    L["Not possible in combat. Try again after."] = "Im Kampf nicht m\195\182glich. Versuch es danach erneut." -- moeglich
    L["Anchors reset."]                           = "Verankerungen zur\195\188ckgesetzt."                       -- zurueckgesetzt
    L["Macros PRESCIENCE 1 / 2 saved from config."] = "Makros PRESCIENCE 1 / 2 aus der Konfiguration gespeichert."
    L["Macro %d used on %s"] = "Makro %d verwendet auf %s"
end

PH.L = L
