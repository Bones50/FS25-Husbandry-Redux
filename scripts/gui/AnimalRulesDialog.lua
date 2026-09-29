-- ============================================================================
-- AnimalRulesDialog.lua -- the SELL RULES for one barn-breed.
--
-- Opened from the BREEDS tab (29.7), which is where the purpose is set, so this
-- window never has to ask which barn or which breed. Author, 2026-09-02: *"the
-- only options here should be sell rules and buy rules, which would open up the
-- relevant config pop-up."*
--
-- ---------------------------------------------------------------------------
-- IT DECIDES NOTHING. Every question, its value ring and its wording come from
-- AnimalHerdPolicy; every answer is written back through `setRule`. This file
-- chooses, displays and calls -- the same division AnimalBuyScheduleDialog's
-- header states, and the reason a rule can never mean one thing here and another
-- in the store.
--
-- THE QUESTIONS DEPEND ON THE PURPOSE. `fieldsFor` returns the producer set or
-- the breeder set, so a producing herd is never asked to reserve room for births
-- and a breeding one is never asked the same calf question twice under two names
-- (29.3). Six generic slots, and the ones a purpose does not use are HIDDEN
-- rather than repositioned (DR 5.37).
--
-- WRITES ARE IMMEDIATE. There is no OK button and nothing to cancel: the store is
-- sparse and self-pruning, so a rule set back to its default removes itself, and
-- an accidental change is undone by changing it back rather than by a modal
-- bargain the player has to remember they are in.
-- ============================================================================

AnimalRulesDialog = {}
local AnimalRulesDialog_mt = Class(AnimalRulesDialog, MessageDialog)

AnimalRulesDialog.SLOTS = 6

-- WHAT EACH RULE DOES, mapped EXPLICITLY. A key built by concatenating a prefix
-- onto the field name would be invisible to check_l10n_animal.py, and a rule with
-- no wording renders as blank with nothing in the log (the reason
-- AnimalBuyScheduleDialog's HELP_KEY is written out the same way).
local HELP_KEY = {
    sellNewborns    = "ar_rul_help_sellNewborns",
    runAsNursery    = "ar_rul_help_runAsNursery",
    sellAtPeak      = "ar_rul_help_sellAtPeak",
    headroomWorthIt = "ar_rul_help_headroomWorthIt",
    keepAdults      = "ar_rul_help_keepAdults",
    keepBreeders    = "ar_rul_help_keepBreeders",
    minHealthToSell = "ar_rul_help_minHealthToSell",
    keepFreeSlots   = "ar_rul_help_keepFreeSlots",
}

local function l10n(key, fallback)
    if HusbandryRedux ~= nil and HusbandryRedux.l10n ~= nil then return HusbandryRedux.l10n(key, fallback) end
    return fallback
end

local function setText(el, txt)
    if el ~= nil and el.setText ~= nil then el:setText(txt or "") end
end
local function setVisible(el, on)
    if el ~= nil and el.setVisible ~= nil then el:setVisible(on == true) end
end

---The state a MultiTextOption is reporting. It hands the new index to onClick, but
-- a caller may also ask the element -- so both routes are accepted rather than the
-- argument being assumed present.
local function stateOf(opt, state)
    if type(state) == "number" then return state end
    if opt ~= nil and opt.getState ~= nil then
        local ok, s = pcall(opt.getState, opt)
        if ok then return s end
    end
    return nil
end

function AnimalRulesDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or AnimalRulesDialog_mt)
    return self
end

---Open it on one barn-breed. `barnName` is for the subtitle only; the UID is the
-- key, because two barns may hold the same breed and mean different things by it.
function AnimalRulesDialog.show(uid, breed, barnName)
    local d = AnimalRulesDialog._instance
    if d == nil or uid == nil or breed == nil then return false end
    d.uid, d.breed, d.barnName = uid, breed, barnName
    d.notice = nil
    g_gui:showDialog("AnimalRulesDialog")
    return true
end

function AnimalRulesDialog:onOpen()
    AnimalRulesDialog:superClass().onOpen(self)
    self:refresh()
end

---Which questions this purpose asks, plus the ones that belong to the PEN.
--
-- BARN FIELDS COME LAST AND ARE THE SAME FOR EVERY BREED IN THE BARN: free slots
-- are shared, so `keepFreeSlots` cannot be per breed however much the rest of the
-- set is (29.3). It is stored against the breed the player happened to be looking
-- at, which is a compromise worth naming: the plan wiring will have to read it
-- from the barn rather than from one breed.
function AnimalRulesDialog:fields()
    if AnimalHerdPolicy == nil then return {} end
    local out = {}
    for _, k in ipairs(AnimalHerdPolicy.fieldsFor(
                           AnimalHerdPolicy.purposeOf(self.uid, self.breed)) or {}) do
        out[#out + 1] = k
    end
    for _, k in ipairs(AnimalHerdPolicy.BARN_FIELDS or {}) do out[#out + 1] = k end
    return out
end

function AnimalRulesDialog:refresh()
    self._refreshing = true
    local purpose = AnimalHerdPolicy ~= nil
                    and AnimalHerdPolicy.purposeOf(self.uid, self.breed) or nil

    setText(self.dialogTextElement, string.format(
        l10n("ar_rul_subtitle", "%s  -  %s"), tostring(self.barnName or "?"), tostring(self.breed or "?")))

    -- THE PURPOSE IS STATED, NOT SETTABLE HERE. It is chosen on the tab behind this
    -- window; repeating the control would be two places to change one fact.
    local word = l10n("ar_rul_purposeUnset", "no purpose set - these are the default rules")
    if purpose == AnimalHerdPolicy.PRODUCER then
        word = l10n("ar_rul_purposeProducer", "kept for PRODUCTION")
    elseif purpose == AnimalHerdPolicy.BREEDER then
        word = l10n("ar_rul_purposeBreeder", "kept for BREEDING")
    end
    setText(self.purposeText, word)

    local fields = self:fields()
    for i = 1, AnimalRulesDialog.SLOTS do
        local key = fields[i]
        setVisible(self["lblBox" .. i], key ~= nil)
        setVisible(self["optBox" .. i], key ~= nil)
        if key ~= nil then
            local f = AnimalHerdPolicy.metaOf(key)
            setText(self["lbl" .. i], l10n(f ~= nil and f.l10n or "", key))
            local o = self["opt" .. i]
            local _, texts, index = AnimalHerdPolicy.options(self.uid, self.breed, key, l10n)
            if o ~= nil and o.setTexts ~= nil then
                o:setTexts(texts)
                if o.setState ~= nil then
                    pcall(o.setState, o, math.max(1, math.min(index, math.max(1, #texts))))
                end
            end
        end
    end

    setText(self.noteText, self.notice or l10n("ar_rul_hint",
        "Touch a rule to see what it does. Changes are kept as you make them."))
    self._refreshing = false
end

---A rule moved.
--
-- STORED ONLY WHEN IT DIFFERS FROM THE ENGINE'S DEFAULT, so the store stays sparse
-- and a rule put back where it started removes itself rather than leaving an entry
-- that would be written to every savegame (29.2).
function AnimalRulesDialog:onSlot(i, state)
    if self._refreshing then return end
    local key = self:fields()[i]
    if key == nil or AnimalHerdPolicy == nil then return end
    local sel = stateOf(self["opt" .. i], state)
    if sel == nil then return end

    local values = AnimalHerdPolicy.options(self.uid, self.breed, key, l10n)
    local v = values[sel]
    if v == nil then return end

    local ek = AnimalHerdPolicy.engineKey(key)
    local dflt = (ek ~= nil and AnimalSellRules ~= nil) and AnimalSellRules.DEFAULTS[ek] or nil
    if v == dflt then AnimalHerdPolicy.setRule(self.uid, self.breed, key, nil)
    else AnimalHerdPolicy.setRule(self.uid, self.breed, key, v) end

    -- WHAT IT DOES, the moment it is touched.
    self.notice = l10n(HELP_KEY[key] or "", "")
    if self.notice == "" then self.notice = nil end
    self:refresh()
end

for i = 1, AnimalRulesDialog.SLOTS do
    local n = i
    AnimalRulesDialog["onOpt" .. n] = function(self, st) return self:onSlot(n, st) end
end

---Everything back to the engine's defaults for this barn-breed. It clears the
-- ENTRY rather than writing defaults into it, so the store returns to holding
-- nothing at all about this breed.
function AnimalRulesDialog:onReset()
    if AnimalHerdPolicy == nil then return end
    for _, key in ipairs(self:fields()) do
        AnimalHerdPolicy.setRule(self.uid, self.breed, key, nil)
    end
    self.notice = l10n("ar_rul_reset", "Back to the default rules for this breed.")
    self:refresh()
end

function AnimalRulesDialog:onClickBack()
    self:close()
    return true
end

function AnimalRulesDialog.register()
    if AnimalRulesDialog._instance ~= nil then return true end
    if g_gui == nil or HusbandryRedux == nil then return false end
    -- AR's own profiles must already be in g_gui; this dialog names none of them
    -- today, but the page that opens it loads them before its own layout (29.7d).
    local d = AnimalRulesDialog.new()
    g_gui:loadGui(HusbandryRedux.MOD_DIR .. "gui/AnimalRulesDialog.xml", "AnimalRulesDialog", d)
    AnimalRulesDialog._instance = d
    return true
end
