-- ============================================================================
-- AnimalHerdPolicy.lua -- WHAT A BARN KEEPS EACH BREED FOR, and the rules that
-- follow from it.
--
-- Requested 2026-09-02: *"player defines per barn and per breed whether the breed
-- is to be a producer or a breeder herd... The user should then be able to set
-- rules for that barn-breed that then govern all sales related to that breed."*
--
-- ---------------------------------------------------------------------------
-- WHY THE OWNER MOVED, and it is a correction rather than a new idea.
--
-- 24.1 drew the distinction itself: an ORDER is time-triggered (a count, a
-- cadence, an end) and a POLICY is condition-triggered. 24.9 then moved the
-- policy ONTO the order -- correctly deleting the pick rule that duplicated the
-- engine, but relocating the whole rule set along with it. That relocation is
-- what this file undoes.
--
-- THREE THINGS IT FIXES, and the first is the one that condemns the old owner:
--   * RULES DIED WITH THE ORDER. `pruneFinished` deletes a completed order a
--     month after it ends and its `cfg` goes with it, so a carefully set rule set
--     evaporates when the sale it was attached to finishes.
--   * TWO ORDERS ON ONE BARN could hold contradictory rules, and the engine built
--     a different plan for each -- so a barn could be a nursery for one order and
--     not the other, which is incoherent for a fact about the herd.
--   * NO ORDER MEANT NO RULES. A player who wants a standing policy and no timed
--     sale had nowhere to put one.
--
-- PER BARN AND PER BREED, confirmed by the author: the same Holsteins may be
-- producers in one shed and breeders in another. So the key is (barn uid, breed
-- name) and never the breed alone.
--
-- THE BREED IS STORED BY NAME, NEVER BY INDEX (10.4, measured): COW_HOLSTEIN is
-- 2 in the base game and 3 with RealisticLivestock, so an index silently repoints
-- every rule at a different animal when RL is enabled or removed.
--
-- ---------------------------------------------------------------------------
-- NOTHING READS THE RULES YET, and that is deliberate. This file stores the
-- player's intent and the tab shows it; `AnimalSellRules.plan` still reasons
-- whole-barn from the order's own cfg. Wiring the plan to honour a per-breed
-- purpose has to reckon with rules that are genuinely PEN facts (free slots are
-- shared) and is the delicate half, so it lands on its own once the data is
-- visibly right -- the same order the terms came in before the override (28.8).
-- ============================================================================

AnimalHerdPolicy = {}

---THE THREE STATES, and UNSET is one of them.
--
-- A two-way switch would force every barn-breed to be one or the other, which
-- means either imposing a default on barns nobody has touched or pretending the
-- engine's guess is the player's answer. Unset keeps them distinguishable: the
-- tab shows the engine's verdict as ADVICE in its own column, and the player's
-- column stays empty until they say something.
AnimalHerdPolicy.UNSET    = nil
AnimalHerdPolicy.PRODUCER = "PRODUCER"
AnimalHerdPolicy.BREEDER  = "BREEDER"

---The ring the in-row button steps through. Unset is IN it, so a purpose set by
-- accident can be taken back rather than only replaced.
AnimalHerdPolicy.RING = { AnimalHerdPolicy.PRODUCER, AnimalHerdPolicy.BREEDER, false }

---WHICH RULES MEAN ANYTHING FOR WHICH PURPOSE.
--
-- The split is not cosmetic. `keepFreeSlots` reserves pen space for BIRTHS: on a
-- breeding herd that is the core rule, and on a producing herd it is actively
-- wrong -- an empty slot earns nothing and the calf that fills it earns nothing
-- for a year (14.4's output cliff).
--
-- AND `sellCalves` IS TWO RULES WEARING ONE NAME, which this split is what
-- exposed. In `plan` it triggers the nursery branch, which does BOTH: harvest
-- every young animal AND sell the adult herd down to half capacity. For a
-- breeding herd run as a nursery both halves are right. For a PRODUCING herd the
-- harvest is exactly what is wanted -- births eat slots that producers should be
-- in -- while halving the adults would be catastrophic.
--
-- So the producer set names `sellNewborns` and the breeder set `runAsNursery`.
-- THEY ARE NOT ENGINE KEYS YET: `plan` knows only `sellCalves`, and splitting it
-- is part of the plan work this file deliberately defers. They are listed here so
-- the tab can show the right question per purpose, and `engineKey` is the single
-- place that maps them back.
AnimalHerdPolicy.FIELDS = {
    PRODUCER = { "sellNewborns", "keepAdults", "sellAtPeak", "minHealthToSell" },
    BREEDER  = { "runAsNursery", "keepBreeders", "headroomWorthIt", "sellAtPeak",
                 "minHealthToSell" },
}

---WHAT EACH QUESTION LOOKS LIKE. `kind` drives the control and `l10n` is STORED
-- rather than built from the key, for the reason AnimalSellPolicy.FIELDS records:
-- a key assembled by concatenation is invisible to check_l10n_animal.py and a
-- missing one renders as a raw "$l10n_..." with nothing in the log.
--
-- THE VALUE RINGS ARE THE ENGINE'S OWN, taken from AnimalSellPolicy so a floor
-- offered here cannot be a figure the engine would refuse.
AnimalHerdPolicy.FIELD_META = {
    sellNewborns    = { kind = "bool",  l10n = "ar_rul_sellNewborns" },
    runAsNursery    = { kind = "bool",  l10n = "ar_rul_runAsNursery" },
    sellAtPeak      = { kind = "bool",  l10n = "ar_rul_sellAtPeak" },
    headroomWorthIt = { kind = "bool",  l10n = "ar_rul_headroomWorthIt" },
    keepAdults      = { kind = "count", l10n = "ar_rul_keepAdults",
                        values = { 0, 2, 4, 6, 8, 10, 15, 20, 30, 50 } },
    keepBreeders    = { kind = "count", l10n = "ar_rul_keepBreeders",
                        values = { 0, 2, 4, 6, 8, 10, 15, 20, 30, 50 } },
    minHealthToSell = { kind = "pct",   l10n = "ar_rul_minHealthToSell",
                        values = { 0, 0.5, 0.6, 0.7, 0.75, 0.8, 0.9 } },
    keepFreeSlots   = { kind = "slots", l10n = "ar_rul_keepFreeSlots",
                        values = { -1, 0, 1, 2, 3, 4, 5, 6, 8, 10 } },
}

function AnimalHerdPolicy.metaOf(key) return AnimalHerdPolicy.FIELD_META[key] end

---THE VALUE A QUESTION CURRENTLY HOLDS, falling through to the ENGINE's default
-- for the key it stands for. One place decides what an unset rule means and it is
-- `AnimalSellRules.DEFAULTS` -- so `keepAdults` unset reads whatever
-- `keepBreeders` defaults to, because they ARE the same rule.
function AnimalHerdPolicy.valueOf(uid, breed, key)
    local v = AnimalHerdPolicy.rule(uid, breed, key)
    if v ~= nil then return v end
    local ek = AnimalHerdPolicy.engineKey(key)
    if ek ~= nil and AnimalSellRules ~= nil and AnimalSellRules.DEFAULTS ~= nil then
        return AnimalSellRules.DEFAULTS[ek]
    end
    return nil
end

---Every value a question can take, the words for each, and which is current --
-- the same shape AnimalSellPolicy.options returns, and for the same reason: handed
-- the whole ring, MultiTextOptionElement does left, right and wrapping itself
-- rather than the dialog turning every click into one forward step (24.11).
---Returns values, texts, index.
function AnimalHerdPolicy.options(uid, breed, key, l10n)
    local f = AnimalHerdPolicy.metaOf(key)
    if f == nil then return {}, {}, 1 end
    local cur = AnimalHerdPolicy.valueOf(uid, breed, key)
    local values = f.values
    -- OFF FIRST, so a boolean ring reads false -> true like every other field
    if f.kind == "bool" then values = { false, true } end
    values = values or {}
    local texts, index = {}, 1
    for i, v in ipairs(values) do
        texts[i] = AnimalHerdPolicy.textFor(f, v, l10n)
        if v == cur then index = i end
    end
    return values, texts, index
end

---The words for ONE value. `l10n` is handed in so this module stays free of any
-- GUI dependency, exactly as AnimalSellPolicy.textFor does.
function AnimalHerdPolicy.textFor(f, v, l10n)
    if f.kind == "bool" then
        if v == true then return l10n("ar_pol_on", "On") end
        return l10n("ar_pol_off", "Off")
    end
    if f.kind == "pct" then
        if v == 0 then return l10n("ar_pol_noFloor", "No floor") end
        return string.format(l10n("ar_pol_pct", "%d%% health"), math.floor(v * 100 + 0.5))
    end
    if f.kind == "slots" and v == -1 then
        return l10n("ar_pol_autoSlots", "Automatic (next births)")
    end
    if v == 0 then return l10n("ar_pol_noFloor", "No floor") end
    return tostring(v)
end

---RULES THAT BELONG TO THE PEN, not to a breed.
--
-- Free slots are SHARED. Two breeds cannot each reserve their own headroom out of
-- one pen, so this cannot be a per-breed rule however much the rest of the set
-- is. What purpose makes newly computable is WHO DEMANDS it: only breeder-purpose
-- breeds need room for births, and the sale that frees it should come from the
-- producers.
AnimalHerdPolicy.BARN_FIELDS = { "keepFreeSlots" }

---The engine key a purpose-specific rule stands for, where one exists today.
-- `keepAdults` and `keepBreeders` are the same floor asked in the vocabulary of
-- the herd's job, so both map to the engine's one key.
AnimalHerdPolicy.ENGINE_KEY = {
    sellNewborns    = "sellCalves",
    runAsNursery    = "sellCalves",
    keepAdults      = "keepBreeders",
    keepBreeders    = "keepBreeders",
    sellAtPeak      = "sellAtPeak",
    minHealthToSell = "minHealthToSell",
    headroomWorthIt = "headroomWorthIt",
    keepFreeSlots   = "keepFreeSlots",
}

function AnimalHerdPolicy.engineKey(k) return AnimalHerdPolicy.ENGINE_KEY[k] end

-- ---------------------------------------------------------------------------
-- THE STORE
-- ---------------------------------------------------------------------------
---uid -> breedName -> { purpose = ..., cfg = { ... } }. SPARSE: an entry exists
-- only where the player has said something, so an untouched farm stores nothing
-- and a save written before this loads unchanged.
AnimalHerdPolicy.byBarn = {}

local function warn(fmt, ...)
    if HusbandryRedux ~= nil and HusbandryRedux.warn ~= nil then return HusbandryRedux.warn(fmt, ...) end
    local ok, msg = pcall(string.format, fmt, ...)
    print("[HusbandryRedux] " .. (ok and msg or tostring(fmt)))
end

---Progress, not failure. Gated on the Debug setting so a normal session's log
-- carries only what went wrong (AnimalSettings, the "debug" row).
local function dbg(fmt, ...)
    if HusbandryRedux ~= nil and HusbandryRedux.log ~= nil then return HusbandryRedux.log(fmt, ...) end
end

local function keyOk(uid, breed)
    return type(uid) == "string" and uid ~= ""
       and type(breed) == "string" and breed ~= ""
end

---The stored record, or nil. READ ONLY -- callers must not mutate what they get
-- back, or a rule would be set without the write path ever running.
function AnimalHerdPolicy.get(uid, breed)
    if not keyOk(uid, breed) then return nil end
    local b = AnimalHerdPolicy.byBarn[uid]
    return b ~= nil and b[breed] or nil
end

---Created on demand, which is what keeps the store sparse.
local function entry(uid, breed)
    if not keyOk(uid, breed) then return nil end
    local b = AnimalHerdPolicy.byBarn[uid]
    if b == nil then b = {}; AnimalHerdPolicy.byBarn[uid] = b end
    local e = b[breed]
    if e == nil then e = { cfg = {} }; b[breed] = e end
    return e
end

---nil when the player has not said, which is a DIFFERENT fact from either answer
-- and is never collapsed into one (DR 5.46c, and this file's whole reason for a
-- third state).
function AnimalHerdPolicy.purposeOf(uid, breed)
    local e = AnimalHerdPolicy.get(uid, breed)
    return e ~= nil and e.purpose or nil
end

function AnimalHerdPolicy.setPurpose(uid, breed, purpose)
    if purpose ~= AnimalHerdPolicy.PRODUCER and purpose ~= AnimalHerdPolicy.BREEDER then
        purpose = nil
    end
    local e = entry(uid, breed)
    if e == nil then return nil end
    e.purpose = purpose
    AnimalHerdPolicy.prune(uid, breed)
    return purpose
end

---Step the ring. Returns the new purpose (nil for unset).
function AnimalHerdPolicy.cyclePurpose(uid, breed)
    local cur = AnimalHerdPolicy.purposeOf(uid, breed)
    local ring = AnimalHerdPolicy.RING
    local at = #ring                       -- unset sits last, so nil starts the ring
    for i, v in ipairs(ring) do
        if v == cur or (v == false and cur == nil) then at = i; break end
    end
    local nxt = ring[(at % #ring) + 1]
    if nxt == false then nxt = nil end
    return AnimalHerdPolicy.setPurpose(uid, breed, nxt)
end

---WHAT A BREED IS KEPT FOR WHEN NOBODY HAS SAID (2026-09-13).
--
-- A breed whose animals make anything besides MANURE or SLURRY is kept for what
-- it makes, so it defaults to PRODUCER. One whose only outputs are manure and
-- slurry earns its keep by breeding, so it defaults to BREEDER -- pigs are that
-- case.
--
-- A DEFAULT, NEVER A WRITE. purposeOf still answers nil for an untouched breed,
-- so the store stays sparse and everything that reads purposeOf (the adviser, the
-- rules) is unchanged by this. effectivePurpose is what a table SHOWS.
--
-- Read from the subtype's own declared outputs, by NAME, through the base game's
-- animalSystem:getSubTypeByName (Rideable.lua calls it). nil when the breed
-- cannot be resolved: an unknown answer is not a guess at either.
AnimalHerdPolicy.WASTE_OUTPUTS = { manure = true, liquidManure = true }

function AnimalHerdPolicy.defaultPurpose(breed)
    if type(breed) ~= "string" or breed == "" then return nil end
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil or asys.getSubTypeByName == nil then return nil end
    local ok, st = pcall(asys.getSubTypeByName, asys, breed)
    if not ok or type(st) ~= "table" or type(st.output) ~= "table" then return nil end
    for key, decl in pairs(st.output) do
        if decl and not AnimalHerdPolicy.WASTE_OUTPUTS[key] then
            return AnimalHerdPolicy.PRODUCER
        end
    end
    return AnimalHerdPolicy.BREEDER
end

---The purpose to SHOW: the player's where they set one, else the default. The
-- second return is true when it IS the default, so a caller can tell the two apart.
function AnimalHerdPolicy.effectivePurpose(uid, breed)
    local p = AnimalHerdPolicy.purposeOf(uid, breed)
    if p ~= nil then return p, false end
    return AnimalHerdPolicy.defaultPurpose(breed), true
end

---Flip between the two answers, starting from what is SHOWN, and always write an
-- explicit choice. For a table that displays the default: stepping the
-- three-state ring there would pass through UNSET, which looks exactly like the
-- default, so one press in three would appear to do nothing.
function AnimalHerdPolicy.togglePurpose(uid, breed)
    local cur = AnimalHerdPolicy.effectivePurpose(uid, breed)
    local nxt = (cur == AnimalHerdPolicy.PRODUCER) and AnimalHerdPolicy.BREEDER
                                                     or AnimalHerdPolicy.PRODUCER
    return AnimalHerdPolicy.setPurpose(uid, breed, nxt)
end

---A rule value, or nil to fall through to the engine's own default. Deliberately
-- NOT defaulted here: one place decides what an unset rule means, and it is
-- already `AnimalSellRules.DEFAULTS` (AnimalSellPolicy.value follows the same
-- rule and says so).
function AnimalHerdPolicy.rule(uid, breed, key)
    local e = AnimalHerdPolicy.get(uid, breed)
    if e == nil or e.cfg == nil then return nil end
    return e.cfg[key]
end

function AnimalHerdPolicy.setRule(uid, breed, key, value)
    if type(key) ~= "string" or key == "" then return nil end
    local e = entry(uid, breed)
    if e == nil then return nil end
    e.cfg[key] = value
    AnimalHerdPolicy.prune(uid, breed)
    return value
end

---The whole rule set for a barn-breed, never nil. A COPY, so a caller cannot
-- write through it and bypass `setRule`.
function AnimalHerdPolicy.rules(uid, breed)
    local out = {}
    local e = AnimalHerdPolicy.get(uid, breed)
    for k, v in pairs((e ~= nil and e.cfg) or {}) do out[k] = v end
    return out
end

---Which questions to ask for a purpose. An UNSET breed is asked the breeder set,
-- because that is what the engine's own defaults describe -- `keepFreeSlots` is
-- -1 (derive headroom from births) out of the box.
function AnimalHerdPolicy.fieldsFor(purpose)
    return AnimalHerdPolicy.FIELDS[purpose or AnimalHerdPolicy.BREEDER]
        or AnimalHerdPolicy.FIELDS.BREEDER
end

---Drop an entry that no longer says anything, so clearing a purpose and its rules
-- leaves the store as empty as it started rather than accumulating shells that
-- would then be written to every savegame.
function AnimalHerdPolicy.prune(uid, breed)
    local b = AnimalHerdPolicy.byBarn[uid]
    if b == nil then return end
    local e = b[breed]
    if e == nil then return end
    if e.purpose == nil and next(e.cfg or {}) == nil then
        b[breed] = nil
        if next(b) == nil then AnimalHerdPolicy.byBarn[uid] = nil end
    end
end

function AnimalHerdPolicy.clear() AnimalHerdPolicy.byBarn = {} end

---How many barn-breeds carry a setting -- for the log line on load, and for a
-- harness that wants to assert the store really is sparse.
function AnimalHerdPolicy.count()
    local n = 0
    for _, b in pairs(AnimalHerdPolicy.byBarn) do
        for _ in pairs(b) do n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- PERSISTENCE. A third section beside buySchedules and sellOrders, the pattern
-- AnimalPersist.register was built for.
--
-- VALUES ARE WRITTEN BY TYPE, not all as strings: a rule set holds booleans,
-- percentages and counts, and reading a "true" back as a string would make every
-- boolean rule true (24.11's collapse, one layer down).
-- ---------------------------------------------------------------------------
local function saveSection(xml, key)
    local i = 0
    for uid, breeds in pairs(AnimalHerdPolicy.byBarn) do
        for breed, e in pairs(breeds) do
            local k = string.format("%s.herd(%d)", key, i)
            setXMLString(xml, k .. "#uid", uid)
            setXMLString(xml, k .. "#breed", breed)
            if e.purpose ~= nil then setXMLString(xml, k .. "#purpose", e.purpose) end
            local j = 0
            for rk, rv in pairs(e.cfg or {}) do
                local rkey = string.format("%s.rule(%d)", k, j)
                setXMLString(xml, rkey .. "#key", rk)
                if type(rv) == "boolean" then
                    setXMLString(xml, rkey .. "#type", "bool")
                    setXMLBool(xml, rkey .. "#value", rv)
                elseif type(rv) == "number" then
                    setXMLString(xml, rkey .. "#type", "number")
                    setXMLFloat(xml, rkey .. "#value", rv)
                else
                    setXMLString(xml, rkey .. "#type", "string")
                    setXMLString(xml, rkey .. "#value", tostring(rv))
                end
                j = j + 1
            end
            i = i + 1
        end
    end
end

local function loadSection(xml, key)
    -- UNCONDITIONALLY CLEARED. The mod chunk re-runs on every mission load and
    -- this table is file scope, so a guard on "did we read anything" would carry
    -- one savegame's herd policy into another (DR 6.19's placement-stamp leak).
    AnimalHerdPolicy.clear()
    if xml == nil then return end
    local i = 0
    while true do
        local k = string.format("%s.herd(%d)", key, i)
        if not hasXMLProperty(xml, k) then break end
        local uid   = getXMLString(xml, k .. "#uid")
        local breed = getXMLString(xml, k .. "#breed")
        if keyOk(uid, breed) then
            AnimalHerdPolicy.setPurpose(uid, breed, getXMLString(xml, k .. "#purpose"))
            local j = 0
            while true do
                local rkey = string.format("%s.rule(%d)", k, j)
                if not hasXMLProperty(xml, rkey) then break end
                local rk = getXMLString(xml, rkey .. "#key")
                local ty = getXMLString(xml, rkey .. "#type")
                if type(rk) == "string" and rk ~= "" then
                    local v
                    if ty == "bool" then v = getXMLBool(xml, rkey .. "#value")
                    elseif ty == "number" then v = getXMLFloat(xml, rkey .. "#value")
                    else v = getXMLString(xml, rkey .. "#value") end
                    if v ~= nil then AnimalHerdPolicy.setRule(uid, breed, rk, v) end
                end
                j = j + 1
            end
        else
            warn("herd policy %d dropped on load: no barn or breed", i)
        end
        i = i + 1
    end
    local n = AnimalHerdPolicy.count()
    if n > 0 then dbg("%d barn-breed policy setting(s) restored", n) end
end

if AnimalPersist ~= nil and AnimalPersist.register ~= nil then
    AnimalPersist.register("herdPolicy", saveSection, loadSection)
end
