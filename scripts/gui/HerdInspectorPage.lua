-- ============================================================================
-- HerdInspectorPage.lua  (Husbandry Redux) -- the second Animals tab
--
-- A SECOND tab beside the existing one, not a replacement. Both load, both work,
-- and the old one is deleted only once this has earned it -- which is the whole
-- point: the comparison is the acceptance test, so breaking the baseline would
-- defeat it. Nothing here writes to the old page.
--
-- TWO VIEWS.
--   GROUPS  every animal group on the farm, filtered by animal type. Full width,
--           no barn list: the BARN column already says where each group is, and
--           the list would cost 370px to repeat it.
--   BARN    the barn list on the left; on the right a summary strip across the
--           top, then the barn's groups beside its feed and production.
--
-- A CLUSTER IS THE UNIT THE GAME THINKS IN. Every recommendation the sell rules
-- make acts on one, so a screen that only ever shows barn totals is a screen you
-- cannot check the recommendations against. 10.3 measured a horse barn as 16
-- clusters of ONE animal -- which is also why the type filter is not a
-- convenience: unfiltered, this farm is 18 rows and 16 of them are horses.
--
-- L/DAY IS THE COLUMN THAT IS NEW, and it is the reason for the tab. 14.4
-- measured every output as age-curved and matched the live spec on 17 rows of
-- 17: milk is a CLIFF at 12 months, manure and slurry RAMP FROM BIRTH. So a
-- young group reports an honest zero for milk while still making manure, which
-- no current screen says.
--
-- THE CLASS IS BUILT AT INSTALL TIME, not at chunk load: it extends DR's
-- DistributionMenuPage and DR's environment does not exist when this file is
-- sourced (mods load alphabetically and FS25_Husbandry_Redux comes first). Methods
-- are defined on a plain table here; the inheritance is wired in install().
-- ============================================================================

HerdInspectorPage = {}

HerdInspectorPage.VIEW_GROUPS, HerdInspectorPage.VIEW_BARN = 1, 2
---THE THIRD VIEW: what this barn keeps each BREED for. It shares the barn list
-- with VIEW_BARN, because a purpose is per (barn, breed) and the barn has to be
-- chosen before the question means anything (29.1).
HerdInspectorPage.VIEW_BREEDS = 3
---THE FOURTH VIEW: the BARN view, narrowed to ONE animal type (2026-09-13).
-- Requested so a player can work one species at a time. It is the barn view in
-- every respect -- same panel, same tables, same footer -- with the barn list
-- filtered. The filter is a TABLE keyed by view rather than a pig special case,
-- so a Cows or Sheep tab later is one entry here plus a tab slot and a label.
HerdInspectorPage.VIEW_PIGS = 4
---THE FIFTH VIEW: COWS (author, 2026-09-24). The Pigs tab in every respect -- same two
-- tables, same in-row Buy / Sell / Auto Trader, same feeding switch -- with two
-- differences that come from the animal rather than the page, and both live in the DATA:
--   PRODUCTION  cows make milk from 12 months (14.4) where a pig makes nothing but its
--               own growth, so a dairy herd earns while it is held
--   AGE         only cows lose value after peak (11.3), so "sell each cohort at peak" is
--               the right rotation for a pig and the wrong one for a milking cow
-- HusbandryRedux.rotationOf answers both through the sale-age search (AnimalAdvisor.saleAge)
-- for any breed whose curve declines; the page itself needs no cow special case.
HerdInspectorPage.VIEW_COWS = 5
---EVERY OTHER ANIMAL TYPE (author, 2026-09-24), and the BARN INSPECTOR RETIRED with them:
-- once every type has its own tab, a view listing all barns of all types is the same
-- barns again in a worse layout. VIEW_BARN stays DEFINED (isBarnLayout still names it)
-- but no tab leads to it.
--
-- THE FIVE BASE-GAME TYPES, read from sdk/xmlDoku/character/animals.xml: COW, PIG, SHEEP,
-- HORSE, CHICKEN. Goats are a SHEEP subtype, not a type of their own, so they appear on the
-- Sheep tab.
--
-- AND "OTHER", because a mod can register a type of its own, and with no Barn Inspector a
-- barn of that type would otherwise have no tab at all -- unreachable rather than merely
-- untidy. It takes every barn whose type is not one of the five (or cannot be resolved),
-- and like every type tab it only appears when such a barn exists.
HerdInspectorPage.VIEW_SHEEP    = 6
HerdInspectorPage.VIEW_HORSES   = 7
HerdInspectorPage.VIEW_CHICKENS = 8
HerdInspectorPage.VIEW_OTHER    = 9
HerdInspectorPage.VIEW_MAX      = 9
---The sentinel the OTHER view filters on: "not one of the known types".
HerdInspectorPage.OTHER_TYPES = "*OTHER*"
---Which animal TYPE each type view shows, compared against the barn's declared
-- type name upper-cased (the same normalisation breedsOfType uses).
HerdInspectorPage.VIEW_TYPE_FILTER = { [HerdInspectorPage.VIEW_PIGS]     = "PIG",
                                       [HerdInspectorPage.VIEW_COWS]     = "COW",
                                       [HerdInspectorPage.VIEW_SHEEP]    = "SHEEP",
                                       [HerdInspectorPage.VIEW_HORSES]   = "HORSE",
                                       [HerdInspectorPage.VIEW_CHICKENS] = "CHICKEN",
                                       [HerdInspectorPage.VIEW_OTHER]    = HerdInspectorPage.OTHER_TYPES }

---Is this a TYPE view? They share one layout -- the split breed / animal tables -- so
-- every "is this the Pigs tab" test on the page asks this instead.
function HerdInspectorPage.isTypeView(v)
    return HerdInspectorPage.VIEW_TYPE_FILTER[v] ~= nil
end

---Does view `v` take a barn whose type is `typeName`? Views that are not type views take
-- every barn. OTHER takes whatever none of the named types claims -- including a barn
-- whose type could not be resolved, which would otherwise be unreachable.
function HerdInspectorPage.viewTakesType(v, typeName)
    local want = HerdInspectorPage.VIEW_TYPE_FILTER[v]
    if want == nil then return true end
    local t = (typeName ~= nil) and tostring(typeName):upper() or nil
    if want == HerdInspectorPage.OTHER_TYPES then
        if t == nil then return true end
        for view, name in pairs(HerdInspectorPage.VIEW_TYPE_FILTER) do
            if view ~= v and name == t then return false end
        end
        return true
    end
    return t == want
end

---WHICH HOST A PAGE INSTANCE SERVES (2026-09-27). With a Distribution Redux new enough to
-- navigate an Overview tab to a page (its API v15), the page is built TWICE from the same class
-- and XML:
--   MODE_OVERVIEW  the Animals and Breeds views, reached from the Overview's HUSBANDRY REDUX tab.
--                  Its header strip is the OVERVIEW'S strip, and the two views are switched by a
--                  button selector in the row beneath it.
--   MODE_TYPES     the Herd Inspector's own left row: one tab per animal type the farm keeps.
--   nil            everything in one strip -- standalone, or a DR too old to host the split. That
--                  is the layout this page had before, unchanged.
-- Author, 2026-09-27: "move the animals and breeds tabs to the overview UI under the Husbandry
-- Redux tab. By default it should show the Animals page."
HerdInspectorPage.MODE_OVERVIEW = "overview"
HerdInspectorPage.MODE_TYPES    = "types"

---May this instance show view `v` at all? Presence (does the farm have one) is a separate test.
function HerdInspectorPage:viewAllowed(v)
    local m = self.hostMode
    if m == nil then return true end
    if m == HerdInspectorPage.MODE_OVERVIEW then
        return v == HerdInspectorPage.VIEW_GROUPS or v == HerdInspectorPage.VIEW_BREEDS
    end
    if m == HerdInspectorPage.MODE_TYPES then return HerdInspectorPage.isTypeView(v) end
    return true
end

---THE TAB ORDER. The strip shows the subset of these that have something to show
-- (tabViews), so this is the order they appear in, not a list of slots.
HerdInspectorPage.TAB_ORDER = {
    HerdInspectorPage.VIEW_GROUPS, HerdInspectorPage.VIEW_BREEDS,
    HerdInspectorPage.VIEW_PIGS, HerdInspectorPage.VIEW_COWS, HerdInspectorPage.VIEW_SHEEP,
    HerdInspectorPage.VIEW_HORSES, HerdInspectorPage.VIEW_CHICKENS, HerdInspectorPage.VIEW_OTHER,
}
---Each view's tab label and page title. Keys are LITERALS so check_l10n_animal can see them.
HerdInspectorPage.VIEW_TEXT = {
    [HerdInspectorPage.VIEW_GROUPS]   = { "ar_hi_view_groups",   "Animals",        "ar_hi_page_title",          "HUSBANDRY REDUX - HERD INSPECTOR" },
    [HerdInspectorPage.VIEW_BREEDS]   = { "ar_hi_view_breeds",   "BREEDS",         "ar_hi_page_title_breeds",   "HUSBANDRY REDUX - BREEDS" },
    [HerdInspectorPage.VIEW_PIGS]     = { "ar_hi_view_pigs",     "Pigs",           "ar_hi_page_title_pigs",     "HUSBANDRY REDUX - PIGS" },
    [HerdInspectorPage.VIEW_COWS]     = { "ar_hi_view_cows",     "Cows",           "ar_hi_page_title_cows",     "HUSBANDRY REDUX - COWS" },
    [HerdInspectorPage.VIEW_SHEEP]    = { "ar_hi_view_sheep",    "Sheep",          "ar_hi_page_title_sheep",    "HUSBANDRY REDUX - SHEEP" },
    [HerdInspectorPage.VIEW_HORSES]   = { "ar_hi_view_horses",   "Horses",         "ar_hi_page_title_horses",   "HUSBANDRY REDUX - HORSES" },
    [HerdInspectorPage.VIEW_CHICKENS] = { "ar_hi_view_chickens", "Chickens",       "ar_hi_page_title_chickens", "HUSBANDRY REDUX - CHICKENS" },
    [HerdInspectorPage.VIEW_OTHER]    = { "ar_hi_view_other",    "Other",          "ar_hi_page_title_other",    "HUSBANDRY REDUX - OTHER ANIMALS" },
}

---WHICH VIEWS HAVE SOMETHING TO SHOW, from a list of barns carrying `typeName`.
-- The Herd Inspector always shows (it is where a farm with no animals says so); Breeds
-- needs a barn; a type view needs a barn of its type. Returns the set and a signature,
-- so a caller can tell cheaply whether the strip needs redrawing.
function HerdInspectorPage.presenceOf(barns)
    local present = { [HerdInspectorPage.VIEW_GROUPS] = true }
    for _, b in ipairs(barns or {}) do
        present[HerdInspectorPage.VIEW_BREEDS] = true
        for v in pairs(HerdInspectorPage.VIEW_TYPE_FILTER) do
            if not present[v] and HerdInspectorPage.viewTakesType(v, b.typeName) then present[v] = true end
        end
    end
    local sig = {}
    for _, v in ipairs(HerdInspectorPage.TAB_ORDER) do
        if present[v] then sig[#sig + 1] = tostring(v) end
    end
    return present, table.concat(sig, ",")
end

---The views the strip shows, in TAB_ORDER. Before anything has been enumerated only the
-- Herd Inspector is known to have something to show.
function HerdInspectorPage:tabViews()
    local present = self._present or { [HerdInspectorPage.VIEW_GROUPS] = true }
    local out = {}
    for _, v in ipairs(HerdInspectorPage.TAB_ORDER) do
        if present[v] and self:viewAllowed(v) then out[#out + 1] = v end
    end
    -- A TYPES PAGE ON A FARM WITH NO ANIMALS has no type tab to show. It falls back to the
    -- Animals view, which is where a farm with no animals is told so -- a page with no view at
    -- all would draw its last one or nothing.
    if #out == 0 then out[1] = HerdInspectorPage.VIEW_GROUPS end
    return out
end

---Enumerate the barns and record which views have something to show. Its own enumerate,
-- for the moments BEFORE rebuild runs (a frame opening); rebuild keeps it current after.
function HerdInspectorPage:refreshPresence()
    local all = (AnimalHerdData ~= nil and AnimalHerdData.enumerate ~= nil) and AnimalHerdData.enumerate() or {}
    for _, b in ipairs(all) do
        if b.typeName == nil and AnimalHerdData.animalTypeOf ~= nil then
            b.typeIndex, b.typeName = AnimalHerdData.animalTypeOf(b.placeable)
        end
    end
    self._present, self._tabSig = HerdInspectorPage.presenceOf(all)
end

---KEEP THE CURRENT VIEW ONE THE STRIP ACTUALLY SHOWS. A view whose last barn was
-- demolished -- or the first open, with nothing chosen yet -- lands on the first ANIMAL tab,
-- since those carry the panel and the tables the Barn Inspector used to; with no animals at
-- all, on the Herd Inspector. Returns true when the view changed.
function HerdInspectorPage:ensureViewValid()
    local views = self:tabViews()
    for _, v in ipairs(views) do
        if v == self.viewIndex then return false end
    end
    -- views[1] is the Animals view whenever this instance offers it (TAB_ORDER puts it first),
    -- so the rule below is unchanged for the combined page and gives the Overview page Animals.
    local pick = views[1] or HerdInspectorPage.VIEW_GROUPS
    for _, v in ipairs(views) do
        if HerdInspectorPage.isTypeView(v) then pick = v; break end
    end
    self.viewIndex = pick
    return true
end

---Is this a view drawn with the BARN layout (panel + tables)? The plain barn
-- view and every type-filtered view alike. BREEDS shares the barn list but not
-- the layout, so it is deliberately not included.
function HerdInspectorPage.isBarnLayout(v)
    return v == HerdInspectorPage.VIEW_BARN or HerdInspectorPage.VIEW_TYPE_FILTER[v] ~= nil
end

---EVERY LIST ON THE PAGE, and the subset that depends on WHICH BARN is selected.
--
-- NAMED BECAUSE THE LITERALS DRIFTED TWICE IN ONE BUILD. Adding the breed list
-- meant adding its id to five separate hand-written lists, and two were missed:
-- one bound every list's data source (so the new list had none) and one reloaded
-- the right-hand panes after a barn was clicked (so the new list did not refresh
-- until the next PACED tick, reported as "it takes a few seconds"). Neither
-- errored; both simply did nothing.
HerdInspectorPage.LIST_IDS = { "groupList", "barnList", "barnGroupList",
                               "inputList", "madeList", "prodList", "breedList",
                               "pigBreedList", "pigGroupList" }
---The panes that answer for the SELECTED barn. barnList is excluded deliberately:
-- it is the list being clicked, and reloading a list inside its own selection
-- callback is how a selection gets reset out from under the player.
HerdInspectorPage.DETAIL_LISTS = { "barnGroupList", "inputList", "madeList", "prodList", "breedList",
                                   "pigBreedList", "pigGroupList" }

-- ---------------------------------------------------------------------------
-- THE TIMESCALE.
--
-- Every rate on this page is stored in its NATURAL unit -- the feed and output
-- tables per HOUR, the value-change column per MONTH, because that is what the
-- price curve's three-month sampling can honestly resolve -- and scaled only at
-- render time. So changing the period is a repopulate, never a rebuild, and the
-- row data never carries a unit that depends on a widget.
--
-- A CYCLE IS ONE IN-GAME HOUR: that is DR's own word for one hourly allocation
-- pass, which is the granularity everything here is actually computed at.
-- A MONTH is 24 x daysPerPeriod hours, read from the environment rather than
-- assumed, and a YEAR is twelve of them.
--
-- THE COLUMN HEADERS CARRY NO UNIT (DR 5.11 dropped its own "/mo" suffixes for
-- exactly this reason): one legend at the top of the page beats eight headers
-- that would have to be re-tiled every time the period changed, and re-tiling
-- hand-pitched columns is where 5.55's truncation bug came from.
HerdInspectorPage.PERIOD_CYCLE, HerdInspectorPage.PERIOD_MONTH, HerdInspectorPage.PERIOD_YEAR = 1, 2, 3
-- The profit key is STORED, not composed from `key`. A key built at runtime is
-- invisible to tools/check_l10n_animal.py, which is the only thing that would ever
-- notice one of these going missing -- and a missing key renders as a raw
-- "$l10n_..." on screen with nothing in the log (5.60).
HerdInspectorPage.PERIODS = {
    { key = "cycle", label = "ar_hi_per_cycle", fallback = "PER: CYCLE (1 HOUR)",
      profit = "ar_hi_profit_cycle", profitFallback = "PROFIT / CYCLE" },
    { key = "month", label = "ar_hi_per_month", fallback = "PER: MONTH",
      profit = "ar_hi_profit_month", profitFallback = "PROFIT / MO" },
    { key = "year",  label = "ar_hi_per_year",  fallback = "PER: YEAR",
      profit = "ar_hi_profit_year",  profitFallback = "PROFIT / YR" },
}

-- ---------------------------------------------------------------------------
local function l10n(key, fallback)
    if HusbandryRedux ~= nil and HusbandryRedux.l10n ~= nil then return HusbandryRedux.l10n(key, fallback) end
    return fallback
end

---Volumes: litres below 1,000, kilolitres above. AR'S OWN COPY, used always.
--
-- This used to call DR's formatVolume with a bare "%d L" fallback, so the SAME figure read
-- "600 kL" or "600000 L" depending on whether DR happened to be installed. AnimalPanel carries a
-- port of DR 5.56's formatter, so the page reads identically either way.
local function vol(v)
    if AnimalPanel ~= nil and AnimalPanel.formatVolume ~= nil then
        local ok, s = pcall(AnimalPanel.formatVolume, v)
        if ok and s ~= nil then return s end
    end
    return string.format("%d L", math.floor((v or 0) + 0.5))
end

---A fill type's DISPLAY title, not its internal name.
local function ftTitle(ft)
    if ft == nil then return "?" end
    local m = g_fillTypeManager
    if m ~= nil and m.getFillTypeTitleByIndex ~= nil then
        local ok, t = pcall(m.getFillTypeTitleByIndex, m, ft)
        if ok and t ~= nil then return tostring(t) end
    end
    return "?"
end

-- `signedVol` LIVED HERE AND IS GONE with the two CHANGE columns it formatted.
-- Verified callerless before deleting rather than assumed (6.27).

local function money(v)
    if v == nil then return "-" end
    local places = (v ~= 0 and math.abs(v) < 10) and 2 or 0
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, s = pcall(g_i18n.formatMoney, g_i18n, v, places, true, true)
        if ok and s ~= nil then return tostring(s) end
    end
    return string.format("%." .. places .. "f", v)
end

---ALL FOUR COLOURS, never setTextColor alone. TextElement:getColor prefers the
-- selected / focused colours whenever the row is in those states, so a status
-- colour written only to `textColor` is silently discarded on the selected row --
-- which on a fresh list is row 1 (DR 5.77b, and 16.6 here).
local function setColour(cell, tone)
    if cell == nil or cell.setTextColor == nil then return end
    local r, g, b
    if tone == "bad" then      r, g, b = 0.85, 0.20, 0.20
    elseif tone == "warn" then r, g, b = 0.95, 0.65, 0.15
    elseif tone == "good" then r, g, b = 0.55, 0.78, 0.25
    elseif tone == "mute" then r, g, b = 0.59, 0.61, 0.64
    else                       r, g, b = 1, 1, 1 end
    cell:setTextColor(r, g, b, 1)
    for _, setter in ipairs({ "setTextSelectedColor", "setTextFocusedColor",
                              "setTextFocusedSelectedColor" }) do
        if type(cell[setter]) == "function" then pcall(cell[setter], cell, r, g, b, 1) end
    end
end

---An icon cell, which must be actively HIDDEN when there is no file: SmoothList
-- recycles cells, so a row with no picture would otherwise inherit the last
-- row's. `setImageFilename` on a missing file leaves the previous texture in
-- place, so hiding is the only reliable clear.
local function setIcon(cell, name, file)
    local c = cell:getAttribute(name)
    if c == nil then return end
    if file ~= nil and c.setImageFilename ~= nil then
        pcall(c.setImageFilename, c, file)
        if c.setVisible ~= nil then c:setVisible(true) end
    elseif c.setVisible ~= nil then
        c:setVisible(false)
    end
end

---Cells are RECYCLED by SmoothList, so every field must be written on every path
-- including its colour, or a row inherits whatever the last row left there.
local function setc(cell, name, text, tone)
    local c = cell:getAttribute(name)
    if c == nil then return end
    if c.setText ~= nil then c:setText(text or "") end
    setColour(c, tone)
end

-- ---------------------------------------------------------------------------
-- DATA
-- ---------------------------------------------------------------------------

---What a cluster's reproduction state actually is, in the engine's own order:
-- age gate first, then health. 11.9 measured both; `assess` applies them the same
-- way, and this only words the answer.
local function reproText(c)
    if c.tooYoung then return l10n("ar_hi_repro_young", "too young"), "mute" end
    if c.unwell then return l10n("ar_hi_repro_unwell", "below the 75% gate"), "warn" end
    if c.dueInMonths ~= nil then
        return string.format(l10n("ar_hi_repro_due", "breeding - due %d mo"), c.dueInMonths), nil
    end
    return l10n("ar_hi_repro_breeding", "breeding"), nil
end

---Every group on the farm, one row per cluster, with its barn attached.
-- Barn identity travels as an INDEX into self.barns AND as a uid: the index is
-- what the drill-through selects, the uid is what survives a rebuild sliding a
-- different barn underneath it (DR 5.37).
---Hours in one of this page's periods. daysPerPeriod is READ, never assumed: a
-- server running 3-day months would otherwise be out by 3x on every figure here.
function HerdInspectorPage:periodHours()
    local idx = self:periodIndexSafe()
    if idx == HerdInspectorPage.PERIOD_CYCLE then return 1 end
    local days = 1
    if AnimalEconomics ~= nil and AnimalEconomics.daysPerMonth ~= nil then
        local ok, d = pcall(AnimalEconomics.daysPerMonth)
        if ok and type(d) == "number" and d >= 1 then days = d end
    end
    local month = 24 * days
    if idx == HerdInspectorPage.PERIOD_YEAR then return month * 12 end
    return month
end

---Multiplier for a figure stored PER HOUR (the feed and output tables).
function HerdInspectorPage:hourScale() return self:periodHours() end

---Multiplier for a figure stored PER MONTH (the value-change column, and the
-- panel's profit block). Expressed as a RATIO of the two periods rather than
-- recomputed, so the two scales can never disagree about how long a month is.
function HerdInspectorPage:monthScale()
    local days = 1
    if AnimalEconomics ~= nil and AnimalEconomics.daysPerMonth ~= nil then
        local ok, d = pcall(AnimalEconomics.daysPerMonth)
        if ok and type(d) == "number" and d >= 1 then days = d end
    end
    return self:periodHours() / (24 * days)
end

---nil in, nil out -- a figure we could not compute must not become a zero just
-- because it was multiplied (15.6).
local function scaled(v, k)
    if type(v) ~= "number" then return nil end
    return v * k
end

-- THE ANIMALS VIEW'S RECOMMENDATION COLUMN IS GONE (2026-09-28): advice is per BREED now
-- and lives on the breed tables, so a per-group verdict beside it would be a second,
-- competing answer. AnimalSellRules.recommendation is kept; nothing here calls it.

function HerdInspectorPage:buildGroupRows()
    local rows = {}
    for bi, b in ipairs(self.barns or {}) do
        local eff = 1
        if AnimalEconomics ~= nil and AnimalEconomics.efficiency ~= nil then
            local okE, e = pcall(AnimalEconomics.efficiency, b.placeable)
            if okE and type(e) == "number" then eff = e end
        end
        for _, c in ipairs(b.clusters or {}) do
            -- RESOLVED FROM THE INDEX. assess carries subTypeIndex and NOT the
            -- subtype, so reading c.subType yields nil and every curve with it.
            local st = c.subType or AnimalHerdData.subTypeOf(c.subTypeIndex)
            local milk = nil
            if st ~= nil then
                local per = AnimalHerdData.ratePerAnimal(st, c.age, "milk")
                if per ~= nil then milk = per * (c.count or 0) * eff end
            end
            local rTxt, rTone = reproText(c)
            -- WHAT THIS GROUP'S BOOK VALUE DID THIS MONTH, for the whole group.
            -- `driftPerMonth` is signed the other way (positive = LOSING), so it
            -- is negated here: this column answers "richer or poorer", and a
            -- reader should not have to invert a sign to find out which.
            -- nil where the price curve could not be sampled -- never a zero,
            -- which would read as "flat" (15.6).
            local change = nil
            local dpm = (c.econ ~= nil) and c.econ.driftPerMonth or nil
            if type(dpm) == "number" then change = -dpm * (c.count or 0) end
            rows[#rows + 1] = {
                icon = AnimalHerdData.animalIconFile(c.subTypeIndex, c.age),
                animal = c.name, barn = b.name, barnIndex = bi, barnUid = b.uid,
                typeIndex = b.typeIndex, count = c.count, age = c.age,
                healthPct = c.healthPct, repro = rTxt, reproTone = rTone,
                litresPerDay = milk, each = c.each, total = c.total,
                change = change, capped = (eff < 0.999),
                cluster = c.cluster,   -- identity, for the trade dialog's default
            }
        end
    end
    table.sort(rows, function(x, y)
        if x.barn ~= y.barn then return x.barn < y.barn end
        return (x.age or 0) > (y.age or 0)
    end)
    return rows
end

---The animal types actually present, for the filter. DERIVED FROM THE FARM, so
-- it can never offer a type nothing is standing in, and never miss a modded one.
function HerdInspectorPage:buildTypeList()
    local seen, list = {}, {}
    for _, b in ipairs(self.barns or {}) do
        if b.typeIndex ~= nil and seen[b.typeIndex] == nil then
            seen[b.typeIndex] = true
            list[#list + 1] = { index = b.typeIndex, name = b.typeName or tostring(b.typeIndex) }
        end
    end
    table.sort(list, function(x, y) return x.name < y.name end)
    table.insert(list, 1, { index = nil, name = l10n("ar_hi_filter_all", "All animals") })
    return list
end

---EVERY INPUT THE BARN TAKES, one row per PRODUCT rather than per group.
--
-- A food GROUP is a tier (a cow has TMR / Silage / Hay / Grass) and SEVERAL
-- PRODUCTS can satisfy each one, so a per-group table cannot say which of them
-- the barn is actually holding. This lists the products and names the group each
-- answers to, then goes wider than food: a barn's inputs are everything it takes
-- in, which is how DR treats any receiver.
--
-- NEEDS / H IS THE GROUP'S, repeated on each of its products, and COST / H is
-- what meeting that need ENTIRELY FROM THIS PRODUCT would cost per hour. That is
-- the comparison worth having, because it says which way of feeding a tier is
-- cheapest, and a per-group table cannot express it at all.
---What to call a declared (non-food) input in the GROUP column. It names the
-- PURPOSE, not the product, which is why it is not simply the fill type's title:
-- "Bedding" says what the straw is for.
function HerdInspectorPage.inputGroupTitle(key)
    if key == "water" then return l10n("ar_hi_group_water", "Water") end
    if key == "straw" then return l10n("ar_hi_group_bedding", "Bedding") end
    return tostring(key or "?")
end

---STRAW IS HELD TWICE ON A ROBOT BARN and the two are not the same straw: one sits
-- in the robot's 49,000 L mix bunker, the other is bedding in spec_husbandryStraw.
-- Different purposes, different rates, two real holdings of one fill type -- so two
-- rows, distinguished by this label. Merging them would force one HELD figure and
-- lie about the other.
function HerdInspectorPage.mixGroupTitle()
    return l10n("ar_hi_group_mix", "Mix ingredient")
end

---The GROUP column for a complete ration such as pig food: it satisfies every
-- group at once, so it belongs to none of them.
function HerdInspectorPage.rationGroupTitle()
    return l10n("ar_hi_group_ration", "Complete ration")
end

function HerdInspectorPage:buildInputRows(b)
    local rows = {}
    if b == nil then return rows end
    local trough = b.trough or {}
    local function priceOf(ft)
        if AnimalEconomics == nil or AnimalEconomics.pricePerLitre == nil then return nil end
        return AnimalEconomics.pricePerLitre(ft)
    end

    -- WHAT THE BARN IS ACTUALLY EATING, AND WHAT THAT COSTS -- resolved by
    -- AnimalEconomics.feedCostPerHour, not here.
    --
    -- The tier rule (SERIAL feeds from the best tier PRESENT, PARALLEL from every
    -- group with stock) used to be written out in this function AND in the
    -- husbandry panel AND, once profit was added, in a third place. It is one
    -- rule, so it is one function now -- which is also what stops the COST NOW
    -- column below disagreeing with the PROFIT figure on the panel above it, a
    -- figure computed from exactly these litres.
    --
    -- It also brought the GRAZING correction with it: getAvailableFood reports
    -- trough PLUS meadow, so this column used to charge market price for pasture
    -- the farm already owns -- a fully-grazing barn was billed in full for eating
    -- nothing it bought. Only the trough's share is charged now.
    local feed = nil
    if AnimalEconomics ~= nil and AnimalEconomics.feedCostPerHour ~= nil then
        local okF, fc = pcall(AnimalEconomics.feedCostPerHour,
                              b.placeable, b.model, b.trough, b.demand)
        if okF and type(fc) == "table" then feed = fc end
    end
    local byFt = (feed ~= nil and feed.byFillType) or {}

    -- ---- THE ROBOT'S INGREDIENT BUNKERS ---------------------------------
    --
    -- These are the products a robot barn actually BUYS, and until now not one of
    -- them had an honest row: silage, hay and straw read zero because `trough`
    -- holds only the mixed product, and MINERAL FEED had no row at all -- it is in
    -- no cow food group and no declared subtype input, so neither loop below could
    -- ever produce one. At 1.20/L against silage at 0.121 it is the most expensive
    -- thing in the mix and was invisible on every screen, including the profit line.
    local bunkers = b.robotBunkers or {}
    local rates = b.ingredientRates or {}
    -- NIL IS NOT AN EMPTY TROUGH. A caller that predates the delivered/grazed split
    -- carries no troughMap at all, and defaulting it to {} would read every held
    -- figure as ZERO rather than as "unknown" -- a silent false zero on the one
    -- column this whole change exists to make honest. Absent means fall back to
    -- availability, which IS the pre-split behaviour and is identical on any barn
    -- without a meadow.
    local troughMap = b.troughMap
    local seen = {}

    -- ---- COMPLETE RATIONS (pig food) --------------------------------------
    --
    -- 2026-09-14. Pig food is split into its crops as it reaches the trough, so it
    -- had no row anywhere and was charged as crops. One row per mixture the barn's
    -- animals can eat, ALWAYS shown, so its cost is visible before any is bought:
    --   HELD      the pig food still in the trough, as the crops it became
    --   NEEDS     the whole appetite, since one ration can cover every group
    --   COST IF ALL  that appetite at the ration's price
    --   USED / COST NOW  what the ledger says is being eaten from it
    local derived = {}
    if AnimalFeedModel ~= nil and AnimalFeedModel.MixLedger ~= nil and b.placeable ~= nil then
        local okD, d = pcall(AnimalFeedModel.MixLedger.derivedOf, b.placeable)
        if okD and type(d) == "table" then derived = d end
    end
    local mixHeldBy = {}
    for _, d in pairs(derived) do
        for ft, litres in pairs(d.byIngredient or {}) do
            mixHeldBy[ft] = (mixHeldBy[ft] or 0) + litres
        end
    end
    local rationTitle = HerdInspectorPage.rationGroupTitle()
    for _, mixFt in ipairs((b.model ~= nil and b.model.mixtures) or {}) do
        if mixFt ~= b.mixedFt and not seen[mixFt] then
            seen[mixFt] = "ration"
            local price = priceOf(mixFt)
            local e = byFt[mixFt]
            local d = derived[mixFt]
            local demand = tonumber(b.demand)
            rows[#rows + 1] = {
                fillType = mixFt, group = rationTitle,
                held = (d ~= nil and d.held) or 0,
                needs = demand,
                cost = (price ~= nil and demand ~= nil) and (price * demand) or nil,
                actual = price ~= nil and ((e ~= nil and e.cost) or 0) or nil,
                used = (e ~= nil and e.eaten) or 0,
                charged = (e ~= nil and e.charged) or 0,
            }
        end
    end

    for ft, bunk in pairs(bunkers) do
        seen[ft] = "bunker"
        local price = priceOf(ft)
        local e = byFt[ft]
        -- NEEDS is the hourly draw at the recipe ratio; nil (not zero) when the
        -- recipe could not be read, because "costs nothing" and "cannot be priced"
        -- are different facts and only one of them is true here.
        local needs = rates[ft]
        rows[#rows + 1] = {
            fillType = ft, group = HerdInspectorPage.mixGroupTitle(),
            held = bunk.held, capacity = bunk.capacity, needs = needs,
            cost = (price ~= nil and needs ~= nil) and (price * needs) or nil,
            actual = (price ~= nil and e ~= nil) and e.cost or nil,
            -- eaten / charged: the grazing split (see the USED column)
            used = e ~= nil and e.eaten or nil,
            charged = e ~= nil and e.charged or nil,
        }
    end

    for _, g in ipairs(b.groups or {}) do
        for _, ft in ipairs(g.fts or {}) do
            -- THE MIXED PRODUCT IS NOT AN INPUT ON A ROBOT BARN. The farm never
            -- bought a litre of it; the robot made it from the bunkers above, so it
            -- belongs in the PRODUCED table with a value rather than a cost.
            local skip = (ft == b.mixedFt)
            -- ...and a tier whose product IS one of those bunkers is already listed,
            -- so it is only worth a SECOND row when the pool genuinely holds some --
            -- i.e. somebody tipped it straight into the trough. Otherwise a robot
            -- barn shows Silage and Hay twice, once with the real figure and once
            -- with a permanent zero.
            if not skip and seen[ft] == "bunker"
               and ((troughMap ~= nil and troughMap[ft] or 0) <= 0) then skip = true end
            if not skip then
            seen[ft] = true
            local price = priceOf(ft)
            -- AVAILABLE, NOT DELIVERED -- and this REVERSES the rule that stood
            -- here, deliberately (author, 2026-09-10):
            --
            --   "the grass never goes through the trough ... include the grass in
            --    the meadow as grass in the trough ... this ensures the grass
            --    inputs reflect the meadow as well as the trough and now the
            --    consumption makes more sense."
            --
            -- The old rule showed the TROUGH alone, to keep the delivered/grazed
            -- split honest. Its stated objection was that counting the meadow here
            -- too "would show the same litres twice" -- true, and it is no longer
            -- the greater evil: a grazing pen read **HELD 0 against USED 45**,
            -- which is not a split, it is a contradiction. HELD now answers the
            -- question the column is actually read for -- "how much can they eat"
            -- -- while COST NOW still charges only the bought share, and the
            -- PRODUCED table still breaks out where it came from.
            local held = (trough ~= nil) and (trough[ft] or 0) or nil
            if held == nil and troughMap ~= nil then held = troughMap[ft] or 0 end
            -- THE PIG-FOOD PART OF THIS CROP IS NOT ITS OWN. It is listed under the
            -- ration it came from (the row above) and in PRODUCED (what it became),
            -- so this row carries only the crop that was delivered loose.
            local mixHeld = mixHeldBy[ft] or 0
            if held ~= nil and mixHeld > 0 then held = math.max(0, held - mixHeld) end
            local e = byFt[ft]
            local fromMix = (e ~= nil and e.fromMix) or 0
            -- A REAL ZERO READS AS ONE and an unpriceable product still reports
            -- nil: "costing nothing" and "cannot be priced" are different facts.
            local actual = nil
            if price ~= nil then actual = (e ~= nil and e.cost or 0) end
            rows[#rows + 1] = {
                fillType = ft, group = g.title,
                held = held, needs = g.need,
                cost = (price ~= nil and g.need ~= nil) and (price * g.need) or nil,
                actual = actual,
                used = e ~= nil and math.max(0, (e.eaten or 0) - fromMix) or nil,
                charged = e ~= nil and math.max(0, (e.charged or 0) - fromMix) or nil,
            }
            end
        end
    end

    -- BEDDING, AND ANYTHING ELSE THE SUBTYPE DECLARES AS AN INPUT. Straw is
    -- age-curved (15.4), so its need is summed over CLUSTERS exactly as the
    -- outputs are rather than assumed flat across the herd.
    --
    -- BEDDING AND WATER, FROM THE SAME FUNCTION THE PROFIT LINE USES.
    --
    -- This block used to gate COST NOW on `trough[ft]` -- and `trough` only ever
    -- holds FOOD fill types, so straw and water resolved nil and read as "using
    -- nothing" on EVERY barn ever shown. A permanent false zero, whose tell was the
    -- "-" sitting in their HELD column. Meanwhile the panel above charged both
    -- unconditionally, so one hour read -31 there and -24 here. Reported 2026-08-31.
    --
    -- declaredInputCostPerHour asks the BUILDING (getHusbandryFillLevel) instead,
    -- which is the only thing that can answer it, and knows that a barn with no
    -- water tank is paying by direct debit rather than drinking free.
    -- `food` stays excluded: it is the same litres the tier table above prices.
    local decl = nil
    if AnimalEconomics ~= nil and AnimalEconomics.declaredInputCostPerHour ~= nil then
        local okD, d = pcall(AnimalEconomics.declaredInputCostPerHour, b.placeable, b.clusters)
        if okD and type(d) == "table" then decl = d end
    end
    for slot, e in pairs((decl ~= nil and decl.byFillType) or {}) do
        local ft = e.fillType
        if ft ~= nil and not seen[ft] then
            local price = priceOf(ft)
            rows[#rows + 1] = {
                fillType = ft, group = HerdInspectorPage.inputGroupTitle(e.key),
                held = e.held, autoSupply = e.auto, needs = e.rate,
                -- COST IF ALL is still the hypothetical FULL rate, so the two
                -- columns keep meaning what they mean on the food rows above
                cost = price ~= nil and (price * e.rate) or nil,
                actual = e.cost,
                -- straw and water are never grazed, so used == charged and the
                -- USED column simply reports consumption
                used = e.consumed, charged = e.consumed,
            }
        end
    end

    -- grouped, so a tier's products sit together and the tiers keep the order
    -- readBarn sorted them into (the best tier first). BUNKER ROWS LEAD, because on
    -- a robot barn they are the whole of what the farm buys.
    local order = {}
    local mixTitle = HerdInspectorPage.mixGroupTitle()
    order[mixTitle] = 0
    order[HerdInspectorPage.rationGroupTitle()] = 0.5
    for i, g in ipairs(b.groups or {}) do order[g.title] = i end
    table.sort(rows, function(x, y)
        local ox, oy = order[x.group] or 99, order[y.group] or 99
        if ox ~= oy then return ox < oy end
        return (x.fillType or 0) < (y.fillType or 0)
    end)
    return rows
end

---WHAT THE BARN MAKES FOR ITSELF: feed it did not buy.
--
-- TWO SOURCES, ONE RULE. A feeding robot mixes bought ingredients into TMR; a
-- meadow grows grass out of nothing. Both are feed that appears in the barn
-- without a purchase, so both belong here rather than sitting in INPUTS looking
-- like a bill -- which is exactly what caught the author out: grass showed as a
-- priced input while the cost model (correctly) charged nothing for it. The
-- display and the economics disagreed, and this is what settles them.
--
-- VALUE, NOT COST, and it is deliberately NOT added to the barn's running cost.
-- For the mix that would double-count the ingredients that made it; for grazing
-- there is nothing to count at all. What the column says is what the feed WOULD
-- have cost to buy -- for a meadow, what it saves you.
function HerdInspectorPage:buildProducedRows(b)
    local rows = {}
    if b == nil then return rows end
    local function priceOf(ft)
        if AnimalEconomics == nil or AnimalEconomics.pricePerLitre == nil then return nil end
        return AnimalEconomics.pricePerLitre(ft)
    end
    local feed = nil
    if AnimalEconomics ~= nil and AnimalEconomics.feedCostPerHour ~= nil then
        local okF, fc = pcall(AnimalEconomics.feedCostPerHour,
                              b.placeable, b.model, b.trough, b.demand)
        if okF and type(fc) == "table" then feed = fc end
    end
    local byFt = (feed ~= nil and feed.byFillType) or {}
    local troughMap = b.troughMap or b.trough or {}   -- see the note in buildInputRows

    -- (a) the robot's mix. HELD is the pool, which is the only thing in it.
    if b.mixedFt ~= nil then
        local e = byFt[b.mixedFt]
        local price = priceOf(b.mixedFt)
        local rate = (e ~= nil and e.eaten) or 0
        rows[#rows + 1] = {
            product = b.mixedFt, group = l10n("ar_hi_group_mixed", "Mixed feed"),
            held = troughMap[b.mixedFt] or 0, rate = rate,
            value = price ~= nil and (rate * price) or nil,
        }
    end

    -- (c) COMPLETE RATIONS: what the pig food became. HELD is the part of each crop
    -- in the trough that came from the ration, RATE the part being eaten, and VALUE
    -- what that much of the crop would cost bought loose -- so the row says whether
    -- the ration is dearer or cheaper than its own ingredients.
    local derivedMix = {}
    if AnimalFeedModel ~= nil and AnimalFeedModel.MixLedger ~= nil and b.placeable ~= nil then
        local okD, d = pcall(AnimalFeedModel.MixLedger.derivedOf, b.placeable)
        if okD and type(d) == "table" then derivedMix = d end
    end
    local mixFts, seenMix = {}, {}
    for mixFt in pairs(derivedMix) do
        if not seenMix[mixFt] then seenMix[mixFt] = true; mixFts[#mixFts + 1] = mixFt end
    end
    for ft, e in pairs(byFt) do
        if e.mixture and not seenMix[ft] then seenMix[ft] = true; mixFts[#mixFts + 1] = ft end
    end
    table.sort(mixFts)
    for _, mixFt in ipairs(mixFts) do
        local d = derivedMix[mixFt] or { byIngredient = {} }
        local e = byFt[mixFt]
        local rates = (e ~= nil and e.ingredients) or {}
        local ings, seenIng = {}, {}
        for ft in pairs(d.byIngredient or {}) do
            if not seenIng[ft] then seenIng[ft] = true; ings[#ings + 1] = ft end
        end
        for ft in pairs(rates) do
            if not seenIng[ft] then seenIng[ft] = true; ings[#ings + 1] = ft end
        end
        table.sort(ings)
        for _, ft in ipairs(ings) do
            local held = (d.byIngredient or {})[ft] or 0
            local rate = rates[ft] or 0
            if held > 0 or rate > 0 then
                local price = priceOf(ft)
                rows[#rows + 1] = {
                    product = ft, group = ftTitle(mixFt),
                    held = held, rate = rate,
                    value = price ~= nil and (rate * price) or nil,
                }
            end
        end
    end

    -- (b) grazing. The grazed share of a product is availability MINUS the trough,
    -- the same split feedCostPerHour uses to avoid billing for pasture; the free
    -- share of what was eaten is `eaten - charged`, which is that correction's own
    -- arithmetic read back out.
    if b.grazes then
        for _, g in ipairs(b.groups or {}) do
            for _, ft in ipairs(g.fts or {}) do
                if ft ~= b.mixedFt then
                    local avail = (b.trough or {})[ft] or 0
                    local grazedHeld = math.max(0, avail - (troughMap[ft] or 0))
                    local e = byFt[ft]
                    local grazedRate = math.max(0, ((e ~= nil and e.eaten) or 0)
                                                  - ((e ~= nil and e.charged) or 0))
                    if grazedHeld > 0 or grazedRate > 0 then
                        local price = priceOf(ft)
                        rows[#rows + 1] = {
                            product = ft, group = l10n("ar_hi_group_grazed", "Grazed"),
                            held = grazedHeld, rate = grazedRate,
                            value = price ~= nil and (grazedRate * price) or nil,
                        }
                    end
                end
            end
        end
    end
    return rows
end

---WHAT THE BARN PRODUCES: what it is holding, how fast, and what that is worth.
--
-- PRODUCT | HELD | PROD RATE | VALUE (author's call). The two CHANGE columns are
-- gone: they carried a one-month forecast, which sat oddly beside a period selector
-- offering three of them, and HELD is the figure a reader actually wants next to a
-- rate -- what is in the barn now, and how fast it is filling.
--
-- AN ANIMAL'S DECLARATION IS NOT A BUILDING'S CAPABILITY. Reported 2026-08-31: the
-- base Cow Barn (large) listed SLURRY at 2 L/h. COW_ANGUS declares
-- output.liquidManure, so the animal is willing -- but specialCowStable has no
-- <liquidManure> block, so the barn has no slurry spec and the code that would make
-- it never runs. producibleOutputKeys asks the BUILDING.
--
-- PER ANIMAL IS GONE for its own reason: a per-animal rate on a mixed-age barn
-- described no animal standing in it.
--
-- VALUE IS AT TODAY'S PRICE and says so by being nil when there is no price: pricing
-- an output at zero would read as "worthless" rather than "unpriced".
function HerdInspectorPage:buildProductionRows(b)
    local rows = {}
    if b == nil or AnimalHerdData == nil then return rows end
    local eff, allowed = 1, nil
    if AnimalEconomics ~= nil then
        if AnimalEconomics.efficiency ~= nil then
            local okE, e = pcall(AnimalEconomics.efficiency, b.placeable)
            if okE and type(e) == "number" then eff = e end
        end
        if AnimalEconomics.producibleOutputKeys ~= nil then
            allowed = AnimalEconomics.producibleOutputKeys(b.placeable)
        end
    end

    -- summed over CLUSTERS at their own ages: a barn holding a calf and a cow does
    -- not produce twice the cow's rate
    local acc, order = {}, {}
    for _, c in ipairs(b.clusters or {}) do
        local st = c.subType or AnimalHerdData.subTypeOf(c.subTypeIndex)
        for _, r in ipairs(AnimalHerdData.outputRates(st, c.age or 0, allowed)) do
            local e = acc[r.key]
            if e == nil then
                e = { key = r.key, fillType = r.fillType, rate = 0 }
                acc[r.key] = e; order[#order + 1] = e
            end
            -- per DAY from the curve, reported per HOUR
            e.rate = e.rate + r.perDay * (c.count or 0) * eff / 24
        end
    end

    -- HELD comes from DR's assetHeld, which is the figure DR's own tabs print -- it
    -- folds a pen's pallets and its pending queue in (5.21), which getHusbandryFillLevel
    -- alone cannot see. One basis for one quantity across both mods.
    local SD = HusbandryRedux ~= nil and HusbandryRedux.DR or nil
    for _, e in ipairs(order) do
        local price = nil
        if AnimalEconomics ~= nil and AnimalEconomics.pricePerLitre ~= nil then
            price = AnimalEconomics.pricePerLitre(e.fillType)
        end
        -- DR'S FIGURE WHEN DR IS THERE, OUR OWN WHEN IT IS NOT -- and here that preference is the
        -- right way round, unlike the panel above. DR's assetHeld is EXACT: it folds a pen's pallets
        -- and its pending queue into one figure (DR 5.21), and while DR is running it also owns
        -- spec_husbandryPallets.fillLevels outright (DR 5.32). AnimalHerdData.heldOf can only
        -- APPROXIMATE that from the specs, so preferring the exact source where it exists keeps one
        -- basis for one quantity across both mods, which is what this column was written for.
        --
        -- THE FALLBACK IS HARNESS-TESTED (tools/herdinspector.lua) rather than left to be exercised
        -- only by players without DR -- which is the objection that made the PANEL always use AR's
        -- own copy. An untested fallback rots; a tested one is simply the standalone answer.
        local held = nil
        if SD ~= nil and SD.assetHeld ~= nil and e.fillType ~= nil then
            local okH, h = pcall(SD.assetHeld, b.placeable, e.fillType)
            if okH and type(h) == "number" then held = h end
        end
        if held == nil and AnimalHerdData ~= nil and AnimalHerdData.heldOf ~= nil then
            local okH, h = pcall(AnimalHerdData.heldOf, b.placeable, e.fillType)
            if okH and type(h) == "number" then held = h end
        end
        rows[#rows + 1] = {
            product = e.fillType, key = e.key, held = held,
            rate = e.rate,
            value = price ~= nil and (e.rate * price) or nil,
        }
    end
    return rows
end

-- ---------------------------------------------------------------------------
function HerdInspectorPage:rebuild()
    local all = (AnimalHerdData ~= nil and AnimalHerdData.enumerate ~= nil)
        and AnimalHerdData.enumerate() or {}

    -- A TYPE VIEW keeps only barns of its animal type. Filtered BEFORE the plan
    -- pass below, because that pass walks every cluster of every barn and there
    -- is no reason to pay for barns this view will never show.
    local view = self:viewIndexSafe()
    self.barns = {}
    for _, b in ipairs(all) do
        if AnimalHerdData ~= nil and AnimalHerdData.animalTypeOf ~= nil then
            b.typeIndex, b.typeName = AnimalHerdData.animalTypeOf(b.placeable)
        end
        if HerdInspectorPage.viewTakesType(view, b.typeName) then
            self.barns[#self.barns + 1] = b
        end
    end
    -- WHICH TABS HAVE ANYTHING, kept current from the barns this pass already read. A change
    -- (the first pigsty built, the last one demolished) is only FLAGGED here; the strip is
    -- redrawn by rebuildRealtimeData, because this runs inside applyView and redrawing -- or
    -- worse, switching view -- from in here would recurse.
    local present, sig = HerdInspectorPage.presenceOf(all)
    if sig ~= self._tabSig then
        self._present, self._tabSig, self._tabsDirty = present, sig, true
    end

    -- the cluster pass
    for _, b in ipairs(self.barns) do
        b.clusters, b.plan = {}, nil
        -- PLAN, NOT assess -- and it costs no more. `plan` calls `assess` itself and
        -- hands it back as `plan.assess`, so asking for both would walk every cluster
        -- twice. The plan is what makes the RECOMMENDATION column agree with the
        -- Animals tab rather than being a second opinion about the same herd.
        if AnimalSellRules ~= nil and AnimalSellRules.plan ~= nil then
            local ok, pl = pcall(AnimalSellRules.plan, b.placeable)
            if ok and type(pl) == "table" and type(pl.assess) == "table" then
                b.plan = pl
                local a = pl.assess
                b.clusters = a.clusters or {}
                b.herdValue = a.value
                b.animals, b.capacity, b.free = a.animals, a.capacity, a.free
            end
        end
    end

    -- SELECTION FOLLOWS THE BUILDING, not the row number: the list is rebuilt on
    -- every refresh tick and a barn being built or demolished would otherwise
    -- slide a different one under the player's selection.
    self.selectedBarn = self.selectedBarn or 1
    if self.selectedUid ~= nil then
        -- NOT FOUND RESETS TO THE FIRST ROW. A type view's list is a subset, so the
        -- selected barn is routinely absent from it, and keeping the old INDEX would
        -- point at whichever barn happens to sit at that row in the shorter list.
        -- applyView then re-selects that row in the list, which raises the list's
        -- selection event and moves selectedUid to it -- so the SELECTION FOLLOWS
        -- THE LAST BARN LOOKED AT: after the Pigs tab, the Barns tab opens on
        -- that pigsty rather than on the barn picked before.
        local found = false
        for i, b in ipairs(self.barns) do
            if b.uid == self.selectedUid then self.selectedBarn = i; found = true; break end
        end
        if not found then self.selectedBarn = 1 end
    end
    if self.selectedBarn > #self.barns then self.selectedBarn = 1 end

    self.types = self:buildTypeList()
    local allGroups = self:buildGroupRows()
    local want = self.filterType
    if want == nil then
        self.groupRows = allGroups
    else
        self.groupRows = {}
        for _, r in ipairs(allGroups) do
            if r.typeIndex == want then self.groupRows[#self.groupRows + 1] = r end
        end
    end

    local sel = self.barns[self.selectedBarn]
    self.barnGroupRows = {}
    for _, r in ipairs(allGroups) do
        if sel ~= nil and r.barnUid == sel.uid then
            self.barnGroupRows[#self.barnGroupRows + 1] = r
        end
    end
    self.inputRows = self:buildInputRows(sel)
    self.madeRows = self:buildProducedRows(sel)
    self.prodRows = self:buildProductionRows(sel)
    -- THE BREEDS VIEW SPANS THE FARM (2026-09-29): one row per breed actually held, in every
    -- barn, with no barn chooser. The type tabs keep the per-barn list, unheld breeds included,
    -- because that is where a purpose is set before the animals arrive.
    if self:viewIndexSafe() == HerdInspectorPage.VIEW_BREEDS then
        self.breedRows = self:buildFarmBreedRows()
    else
        self.breedRows = self:buildBreedRows(sel)
    end
end

---EVERY BREED HELD ANYWHERE ON THE FARM, one row per (barn, breed).
--
-- PER BARN, NOT MERGED: purpose, the sell order and the barn's feed / profit advice are all
-- per (barn, breed), so one row for two barns would have to invent a single answer for two
-- questions. The BARN column says which barn a row is. Breeds with no animals are left out.
-- Sorted by breed then barn, so one breed's barns sit together and the order does not move
-- as animals are bought and sold (24.3).
function HerdInspectorPage:buildFarmBreedRows()
    local rows = {}
    -- self.barns is already in localised name order (AnimalHerdData.sortByName), so the barn's
    -- POSITION there is the tie-break -- zero-padded, because the id is compared as a string.
    for pos, b in ipairs(self.barns or {}) do
        for _, r in ipairs(self:buildBreedRows(b)) do
            if r.held and (r.count or 0) > 0 then
                r.barnName = b.name
                r.barnPos  = pos
                r.barnPlaceable = b.placeable
                r.barnType = b.typeName
                rows[#rows + 1] = r
            end
        end
    end
    if AnimalHerdData ~= nil and AnimalHerdData.sortByName ~= nil then
        AnimalHerdData.sortByName(rows, function(r) return r.name end,
                                  function(r) return string.format("%05d", r.barnPos or 0) end)
    end
    return rows
end

---ONE ROW PER BREED THIS BARN COULD HOLD, held ones first.
--
-- BREEDS WITH NO STOCK ARE SHOWN TOO (author's call): a purpose and its rules are
-- worth setting BEFORE the animals arrive, and a list that appeared a row at a
-- time as stock changed would be a poor place to prepare a purchase.
--
-- THEY HAVE NO ECONOMICS, and that is honest rather than broken: an unheld breed
-- has no clusters, so no verdict, no earnings and no terms. Those cells read as a
-- dash and the row carries only what the player has said about it.
--
-- SORTED HELD-FIRST THEN BY NAME, never by count. A list ordered by headcount
-- reshuffles under the player as animals are bought and sold, which is 24.3's
-- complaint about clusters one level up -- and this list is one you click on.
function HerdInspectorPage:buildBreedRows(b)
    local rows = {}
    if b == nil then return rows end

    -- what the barn HOLDS, with its verdict and its terms (28.7 / 28.8)
    local byName = {}
    local a = b.plan ~= nil and b.plan.assess or nil
    if a ~= nil and AnimalSellRules ~= nil and AnimalSellRules.slotUseByType ~= nil then
        for _, g in ipairs(AnimalSellRules.slotUseByType(a) or {}) do
            g.held = true
            byName[g.name] = g
            rows[#rows + 1] = g
        end
    end

    -- ...and every other breed of this barn's animal TYPE, so a purpose can be set
    -- before the first one is bought.
    for _, st in ipairs(self:breedsOfType(b.placeable, b.typeIndex, b.typeName)) do
        if byName[st] == nil then
            rows[#rows + 1] = { name = st, count = 0, held = false }
        end
    end

    -- THE SELL ORDER, per breed -- which is the scope a sell order actually has
    -- (author, 2026-09-10). The barn page keeps its own wording: a barn holding
    -- two breeds cannot be expressed as one order.
    --
    -- X IS THE BIRTHS PER CYCLE, NOT THE PLAN'S PENDING COUNT.
    --
    -- The first build took X from `plan.lines`, and those only exist when a sale
    -- is due RIGHT NOW -- so on a herd quietly breeding toward a full pen there
    -- was no line, no order, and the column fell back to the verdict. The author
    -- saw exactly that on a 48-head Angus barn.
    --
    -- A repeating order needs the STEADY-STATE figure: yield is 1:1 (11.9), so a
    -- breeding cohort DOUBLES each cycle and holding the herd level means selling
    -- the increase -- one animal per breeder, every cycle. That is a forward
    -- instruction the player can set up once, which is what an order is; the
    -- plan's pending count answers "what should I do today" and is already on the
    -- barn page and the Animals tab. Different questions, so no second opinion.
    --
    --   X  breeders of this breed = calves per cycle
    --   Y  `cycleMonths`, one birth per this many months
    --   Z  `dueInMonths - 1`, the month BEFORE the calves land -- the room has to
    --      exist by then, because a full pen destroys the births AND the gestation
    --      that made them (11.5)
    local bornBy, dueBy, cycleBy = {}, {}, {}
    for _, c in ipairs((a ~= nil and a.clusters) or {}) do
        if c.willBreed and c.name ~= nil then
            bornBy[c.name] = (bornBy[c.name] or 0) + (c.count or 0)
            -- SOONEST-DUE cohort sets the deadline, not an average: an average
            -- would schedule the sale after some calves had already been lost.
            if type(c.dueInMonths) == "number"
               and (dueBy[c.name] == nil or c.dueInMonths < dueBy[c.name]) then
                dueBy[c.name] = c.dueInMonths
                if type(c.cycleMonths) == "number" and c.cycleMonths > 0 then
                    cycleBy[c.name] = c.cycleMonths
                end
            end
        end
    end

    -- THE ROTATING-HERD GUIDANCE, per breed (HusbandryRedux.rotationOf, shared with the
    -- panel's sell order note so both judge an order against the same figures).
    local rot = (HusbandryRedux ~= nil and HusbandryRedux.rotationOf ~= nil) and HusbandryRedux.rotationOf(a, b.placeable) or {}
    -- ...and whether a PRODUCER herd is worth keeping at all, feed included (producerSaleFor)
    local prodSale = (HusbandryRedux ~= nil and HusbandryRedux.producerSaleFor ~= nil)
                     and HusbandryRedux.producerSaleFor(b.placeable, a) or nil
    -- ...and the barn's own feed and profit advice, shared by every breed in it (actionsFor)
    local barnActs = HerdInspectorPage.barnActions(self:barnPanel(b.placeable))

    for _, r in ipairs(rows) do
        r.barnUid  = b.uid
        r.barnActions = barnActs
        r.prodSale = prodSale ~= nil and prodSale[r.name] or nil
        local e = rot[r.name]
        if e ~= nil and e.sell ~= nil then
            r.rotSell, r.rotEvery, r.rotStart = e.sell, e.cycle, e.start
        end
        r.purpose  = AnimalHerdPolicy ~= nil and AnimalHerdPolicy.purposeOf(b.uid, r.name) or nil
        -- WHAT THE PIGS TAB SHOWS: the player's choice, else the breed's default.
        -- r.purpose stays the stored answer, so the Breeds tab is unchanged.
        if AnimalHerdPolicy ~= nil and AnimalHerdPolicy.effectivePurpose ~= nil then
            r.purposeShown, r.purposeDefaulted = AnimalHerdPolicy.effectivePurpose(b.uid, r.name)
        end
        r.sellNow  = bornBy[r.name]
        r.everyMonths = cycleBy[r.name]
        if dueBy[r.name] ~= nil then r.startIn = math.max(0, dueBy[r.name] - 1) end
    end
    table.sort(rows, function(x, y)
        if x.held ~= y.held then return x.held end
        return tostring(x.name) < tostring(y.name)
    end)
    return rows
end

---Pull subtype NAMES out of whatever shape a subtypes list turns out to be:
-- records, or indices to be resolved. `want` filters on the type where the list
-- covers more than one; nil takes everything, which is right for a list that came
-- off a single type in the first place.
local function subTypeNames(list, out, want)
    if type(list) ~= "table" then return false end
    local found = false
    for _, e in pairs(list) do
        local st = e
        if type(e) == "number" then
            local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
            if asys ~= nil and asys.getSubTypeByIndex ~= nil then
                local okS, v = pcall(asys.getSubTypeByIndex, asys, e)
                st = okS and v or nil
            end
        end
        if type(st) == "table" and type(st.name) == "string" and st.name ~= "" then
            if want == nil or st.typeIndex == want then
                out[#out + 1] = st.name
                found = true
            end
        end
    end
    return found
end

---EVERY BREED OF ONE ANIMAL TYPE, by NAME.
--
-- BY NAME AND NOT BY INDEX, because that is what the policy store is keyed on and
-- an index means a different animal with RealisticLivestock enabled (10.4).
--
-- THE FIRST VERSION CALLED a getSubTypes method, WHICH DOES NOT EXIST. It was a
-- guessed name, it failed inside a pcall, and the tab therefore listed only the
-- breeds a barn already held. SILENTLY, because a pcall that fails returns exactly
-- what "this barn has no other breeds" returns. Reported as the feature simply not
-- being there.
--
-- AnimalSystem is NOT in the readable SDK source (8.1), so the shape cannot be read
-- and a second guess would be no better than the first. These are the routes AR
-- ALREADY PROVES elsewhere, tried in order:
--   1. the barn own spec_husbandryAnimals.animalType table, which
--      AnimalHerdData.animalTypeOf already reads for its name;
--   2. getTypeByIndex, which that same function already calls successfully;
--   3. an index walk over getSubTypeByIndex, used in shipping code in three
--      places, filtered by the type own name prefix.
--
-- ROUTE 3 FILTERS ON THE NAME, and that limit is worth stating: a subtype matches
-- when it is called COW_something for a type called COW. A modded breed not
-- following that convention is missed, which costs a row in a list and never a
-- wrong answer about a breed that IS there.
--
-- IT SAYS WHICH ROUTE ANSWERED, once. The failure mode here is silence rather than
-- an error, and a player cannot be talked through enabling debug (5.63).
function HerdInspectorPage:breedsOfType(placeable, typeIndex, typeName)
    if typeIndex == nil then return {} end
    self._breedCache = self._breedCache or {}
    if self._breedCache[typeIndex] ~= nil then return self._breedCache[typeIndex] end

    local out, route = {}, nil
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil

    local spec = placeable ~= nil and placeable.spec_husbandryAnimals or nil
    local at = spec ~= nil and spec.animalType or nil
    if type(at) == "table" and subTypeNames(at.subTypes, out, nil) then route = "barn spec" end

    if route == nil and asys ~= nil and asys.getTypeByIndex ~= nil then
        local okT, t = pcall(asys.getTypeByIndex, asys, typeIndex)
        if okT and type(t) == "table" and subTypeNames(t.subTypes, out, nil) then
            route = "getTypeByIndex"
        end
    end

    if route == nil and asys ~= nil and asys.getSubTypeByIndex ~= nil
       and type(typeName) == "string" and typeName ~= "" then
        local prefix = typeName:upper() .. "_"
        for i = 1, 200 do
            local okS, st = pcall(asys.getSubTypeByIndex, asys, i)
            if okS and type(st) == "table" and type(st.name) == "string"
               and st.name:upper():sub(1, #prefix) == prefix then
                out[#out + 1] = st.name
            end
        end
        if #out > 0 then route = "index walk" end
    end

    table.sort(out)
    self._breedCache[typeIndex] = out
    if not self._breedRouteSaid then
        self._breedRouteSaid = true
        -- SAID ONLY WHEN IT IS INTERESTING. Finding nothing means the breed list
        -- will be empty and the player will see a blank tab with no explanation
        -- (29.11: a guessed method name failing silently is what this line exists
        -- to catch), so that stays unconditional. A route that WORKED is progress
        -- chatter and follows the Debug setting.
        local msg = string.format("breeds of type %s: %d found via %s",
                                  tostring(typeName or typeIndex), #out,
                                  tostring(route or "NOTHING"))
        if route == nil or #out == 0 then
            if HusbandryRedux ~= nil and HusbandryRedux.warn ~= nil then HusbandryRedux.warn("%s", msg)
            else print("[HusbandryRedux] " .. msg) end
        elseif HusbandryRedux ~= nil and HusbandryRedux.log ~= nil then
            HusbandryRedux.log("%s", msg)
        end
    end
    return out
end

function HerdInspectorPage:rebuildRealtimeData()
    self:rebuild()
    -- A TAB APPEARED OR VANISHED since the strip was drawn. Redraw it, and if the view
    -- being shown is the one that vanished, move to a view that exists -- applyView
    -- rebuilds for it, so nothing below needs to run a second time.
    if self._tabsDirty then
        self._tabsDirty = false
        local moved = self:ensureViewValid()
        self:initViewOption()
        if moved then self:applyView(); return end
    end
    self:updateSummary()
end

---THE BARN HEADER IS DR'S OWN PANEL, DRAWN BY DR'S OWN FUNCTION.
--
-- Not a second implementation of the same figures. `drawHusbandryPanel(root, d)`
-- takes a root element and the data an API v4 provider returns, and this mod IS
-- that provider - so the Animal Husbandry tab and this one render from one code
-- path and one data source, and cannot drift into disagreeing about a barn.
--
-- The panel's child NAMES are the contract. They are copied verbatim in the XML
-- for that reason; renaming one draws nothing and reports nothing.
function HerdInspectorPage:updateSummary()
    -- DRAWN BY AR'S OWN RENDERER (AnimalPanel), not DR's, since 2026-09-07. This page used to call
    -- SmartDistribution.drawHusbandryPanel, which meant the whole strip rendered NOTHING with DR
    -- uninstalled -- the panel is AR's own data on AR's own page and had no business needing it.
    -- AR's copy is used ALWAYS, with or without DR: a renderer exercised only in the rare
    -- configuration is one that rots unnoticed and fails the first time somebody needs it.
    local root = self.animalPanel
    if root == nil or AnimalPanel == nil or AnimalPanel.drawHusbandryPanel == nil then return end
    local onBarn = HerdInspectorPage.isBarnLayout(self:viewIndexSafe())
    local b = onBarn and (self.barns or {})[self.selectedBarn] or nil

    -- THE PANEL SHOWS ITSELF. drawHusbandryPanel calls setVisible(true) whenever
    -- it has data, so applyView hiding it first achieved nothing: this runs LAST
    -- and put it straight back on the groups view. Passing nil is that function's
    -- own contract for "hide", so the two are not fighting over one element.
    -- STRAIGHT TO OUR OWN PROVIDER. SD.husbandryPanelData was only ever DR's wrapper around this
    -- very function -- DR asks us for the data and hands it back to its renderer -- so going through
    -- DR to reach our own code was a round trip that also happened to require DR to exist.
    local data = nil
    if b ~= nil and b.placeable ~= nil then
        data = self:barnPanel(b.placeable)
    end
    -- THE PANEL FOLLOWS THIS PAGE'S PERIOD SELECTOR. The provider states profit per
    -- MONTH; `opts` is drawHusbandryPanel's own hook for a page that quotes rates in
    -- something else, so the headline cannot read "/ MO" while the tables beneath it
    -- read per year. DR's own Animal Husbandry tab passes nothing and stays monthly.
    local per = HerdInspectorPage.PERIODS[self:periodIndexSafe()]
    local opts = { profitScale = self:monthScale(),
                   profitLabel = l10n(per.profit, per.profitFallback) }
    -- nil hides the panel, which is drawHusbandryPanel's own contract for a barn
    -- that cannot answer - better than a strip of dashes claiming to be figures
    pcall(AnimalPanel.drawHusbandryPanel, root, data, opts)
    if self.panelHeader ~= nil and self.panelHeader.setVisible ~= nil then
        pcall(self.panelHeader.setVisible, self.panelHeader, onBarn)
    end
    self:updateFeedToggle(b)
end

---THE ADVANCED FEEDING SWITCH for the selected barn (author, 2026-09-14). Type tabs only (Pigs, Cows).
--
--   hidden   no DR, or AR's "Advanced animal feeder" is off (every barn is on DR's own
--            rules, so there is nothing to choose)
--   a note   DR installed but not feeding animals at all -- nothing feeds, whatever is set
--   button   "Advanced feeding: On / Off" for this barn
function HerdInspectorPage:updateFeedToggle(b)
    local btn, note = self.feedToggle, self.feedToggleNote
    local function vis(el, show)
        if el ~= nil and el.setVisible ~= nil then pcall(el.setVisible, el, show) end
    end
    local state = (AnimalFeedPolicy ~= nil and AnimalFeedPolicy.toggleState ~= nil)
                  and AnimalFeedPolicy.toggleState() or "HIDDEN"
    local pigs = HerdInspectorPage.isTypeView(self:viewIndexSafe()) and b ~= nil
    vis(note, pigs and state == "DR_OFF")
    vis(btn, pigs and state == "AVAILABLE")
    if btn ~= nil and pigs and state == "AVAILABLE" and btn.setText ~= nil then
        btn.arBarnUid = b.uid
        local on = AnimalFeedPolicy.enabled(b.uid)
        pcall(btn.setText, btn, on and l10n("ar_hi_feed_on", "Advanced feeding: On")
                                    or l10n("ar_hi_feed_off", "Advanced feeding: Off"))
    end
end

---Flip the selected barn's advanced feeding. Takes effect on DR's next hourly pass.
function HerdInspectorPage:onFeedToggle(...)
    if AnimalFeedPolicy == nil or AnimalFeedPolicy.toggleState() ~= "AVAILABLE" then return end
    local b = (self.barns or {})[self.selectedBarn]
    if b == nil or b.uid == nil then return end
    AnimalFeedPolicy.toggle(b.uid)
    self:updateFeedToggle(b)
end

-- ---------------------------------------------------------------------------
-- VIEWS
-- ---------------------------------------------------------------------------
function HerdInspectorPage:viewIndexSafe()
    local v = self.viewIndex
    if type(v) ~= "number" or v < 1 or v > HerdInspectorPage.VIEW_MAX then return HerdInspectorPage.VIEW_GROUPS end
    return v
end

---THE VIEW TABS. Named initViewOption still because every call site means "the
-- view control has changed, redraw it" -- what that control IS is this function's
-- business, not its callers'.
function HerdInspectorPage:initViewOption()
    if AnimalTabs == nil then return end
    if self.hostMode ~= nil and self.hostMode == HerdInspectorPage.MODE_OVERVIEW then return self:initOverviewStrip() end
    self:showViewSelector(false)
    -- ONLY THE VIEWS WITH SOMETHING TO SHOW (author, 2026-09-24), so slot N is the Nth
    -- VISIBLE view rather than a fixed one -- onTabN and stepPageTabBy both read the same
    -- list, which is what keeps a click, a key press and the highlight in agreement.
    local labels, active = {}, 0
    for i, v in ipairs(self:tabViews()) do
        local t = HerdInspectorPage.VIEW_TEXT[v]
        labels[i] = t ~= nil and l10n(t[1], t[2]) or tostring(v)
        if v == self:viewIndexSafe() then active = i end
    end
    AnimalTabs.render(self, labels, active)
end

-- ---- THE OVERVIEW PAGE ---------------------------------------------------------------------
---DR's Overview tabs, as copies from its API (v15). Empty when DR cannot answer, which leaves the
-- strip empty rather than wrong.
local function overviewTabs()
    local SD = HusbandryRedux ~= nil and HusbandryRedux.DR or nil
    if SD == nil or SD.API == nil or SD.API.overviewTabs == nil then return {} end
    local ok, t = pcall(SD.API.overviewTabs)
    return (ok and type(t) == "table") and t or {}
end

---Which Overview tab is ours. Found by OWNER, never assumed to be slot 2: another mod may
-- register an Overview tab too.
local function overviewOwnIndex(tabs)
    local me = (HusbandryRedux ~= nil and HusbandryRedux.MOD_NAME) or "FS25_Husbandry_Redux"
    for i, t in ipairs(tabs) do
        if t.owner == me then return i end
    end
    return nil
end

local function goOverviewTab(i)
    local SD = HusbandryRedux ~= nil and HusbandryRedux.DR or nil
    if SD == nil or SD.API == nil or SD.API.selectOverviewTab == nil then return false end
    return SD.API.selectOverviewTab(i) == true
end

---THE HEADER STRIP ON THE OVERVIEW PAGE IS THE OVERVIEW'S. The player reached this page from a
-- tab on DR's Overview, so the same strip has to be standing above it with our tab selected --
-- otherwise the tab they clicked would appear to have vanished, and there would be no way back
-- but the left list. The labels are DR's; the drawing is ours, since DR cannot paint into this
-- layout and this layout must not borrow DR's elements (31.2).
function HerdInspectorPage:initOverviewStrip()
    local tabs = overviewTabs()
    local labels = {}
    for i, t in ipairs(tabs) do labels[i] = t.label end
    AnimalTabs.render(self, labels, overviewOwnIndex(tabs) or 0)
    self:showViewSelector(true)
end

---THE ANIMALS / BREEDS SELECTOR. Two buttons in the row under the strip, wearing the same base
-- game tab profiles as the strip itself so the selected one reads the same way. Breeds is shown
-- only once the farm has a barn, the rule the tabs have always followed.
function HerdInspectorPage:showViewSelector(on)
    local views = on and self:tabViews() or {}
    local cur = self:viewIndexSafe()
    local slots = { HerdInspectorPage.VIEW_GROUPS, HerdInspectorPage.VIEW_BREEDS }
    for i, v in ipairs(slots) do
        local btn, bg = self["arViewBtn" .. i], self["arViewBg" .. i]
        local have = false
        for _, w in ipairs(views) do if w == v then have = true end end
        local live = have and v == cur
        for _, el in ipairs({ bg, btn }) do
            if el ~= nil then
                if el.setVisible ~= nil then el:setVisible(have) end
                if el.setSelected ~= nil then pcall(el.setSelected, el, live) end
            end
        end
        if have and btn ~= nil and btn.setText ~= nil then
            local t = HerdInspectorPage.VIEW_TEXT[v]
            btn:setText(l10n(t[1], t[2]))
        end
    end
end

function HerdInspectorPage:onViewAnimals() return self:selectView(HerdInspectorPage.VIEW_GROUPS) end
function HerdInspectorPage:onViewBreeds()
    for _, v in ipairs(self:tabViews()) do
        if v == HerdInspectorPage.VIEW_BREEDS then return self:selectView(v) end
    end
end

---A tab click. The two share one path because the only thing that differs is
-- which index, and the index is bounds-checked against the labels actually drawn.
function HerdInspectorPage:selectView(i)
    if i == nil or i == self:viewIndexSafe() then return end
    self.viewIndex = i
    self:initViewOption()
    self:applyView()
end

---A AND D STEP THE VIEW TABS, wrapping at both ends.
--
-- THE CONTRACT DISTRIBUTION REDUX'S MENU CALLS (its API v14): the menu asks the CURRENT page,
-- duck-typed, so this needs no registration and no version test -- an older DR simply never calls
-- it. AR's own menu calls the same method from its own key handler, so the keys behave identically
-- whichever menu the page is being shown in, which is the whole point of adding it.
--
-- Returns TRUE only when a tab actually moved. Returning false leaves the key unclaimed, so A and D
-- never become keys that silently do nothing somewhere else in the menu.
function HerdInspectorPage:stepPageTabBy(delta)
    if type(delta) ~= "number" or delta == 0 then return false end
    -- ON THE OVERVIEW PAGE A / D WALK THE OVERVIEW'S TABS, because that is the strip on screen;
    -- the Animals / Breeds selector is a control inside the tab, not a tab of its own.
    if self.hostMode ~= nil and self.hostMode == HerdInspectorPage.MODE_OVERVIEW then
        local tabs = overviewTabs()
        local n, cur = #tabs, overviewOwnIndex(tabs)
        if n < 2 or cur == nil then return false end
        local want = ((cur - 1 + delta) % n) + 1
        if want == cur then return false end
        return goOverviewTab(want)
    end
    -- THE VISIBLE TABS, not every view: A / D must never land on a tab the strip is not
    -- showing, which would leave the highlight on nothing.
    local views = self:tabViews()
    local n = #views
    if n < 2 then return false end
    local cur = 1
    for i, v in ipairs(views) do
        if v == self:viewIndexSafe() then cur = i; break end
    end
    local want = ((cur - 1 + delta) % n) + 1
    if want == cur then return false end
    self:selectView(views[want])
    return true
end

---The two arrow buttons. Same call the keys make, so a click and a key press cannot come to
-- disagree about what "next" means.
function HerdInspectorPage:onTabPrev() return self:stepPageTabBy(-1) end
function HerdInspectorPage:onTabNext() return self:stepPageTabBy(1) end

---A SLOT IS THE Nth VISIBLE VIEW, not a fixed one: which view sits in a slot depends on
-- which animals the farm keeps. A slot past the end of the list does nothing.
function HerdInspectorPage:onTabSlot(n)
    if self.hostMode ~= nil and self.hostMode == HerdInspectorPage.MODE_OVERVIEW then
        local tabs = overviewTabs()
        if tabs[n] == nil or n == overviewOwnIndex(tabs) then return end
        return goOverviewTab(n)
    end
    local v = self:tabViews()[n]
    if v == nil then return end
    return self:selectView(v)
end
function HerdInspectorPage:onTab1() return self:onTabSlot(1) end
function HerdInspectorPage:onTab2() return self:onTabSlot(2) end
function HerdInspectorPage:onTab3() return self:onTabSlot(3) end
function HerdInspectorPage:onTab4() return self:onTabSlot(4) end
function HerdInspectorPage:onTab5() return self:onTabSlot(5) end
function HerdInspectorPage:onTab6() return self:onTabSlot(6) end
function HerdInspectorPage:onTab7() return self:onTabSlot(7) end
function HerdInspectorPage:onTab8() return self:onTabSlot(8) end

-- `onViewChanged` LIVED HERE AND IS GONE with the selector it answered. Verified
-- callerless before deleting rather than assumed (6.27): the XML no longer
-- declares a viewOption, so nothing can raise it.

function HerdInspectorPage:periodIndexSafe()
    local v = self.periodIndex
    if type(v) ~= "number" or v < 1 or v > #HerdInspectorPage.PERIODS then
        return HerdInspectorPage.PERIOD_MONTH
    end
    return v
end

function HerdInspectorPage:initPeriodOption()
    local o = self.periodOption
    if o == nil then return end
    local texts = {}
    for _, e in ipairs(HerdInspectorPage.PERIODS) do
        texts[#texts + 1] = l10n(e.label, e.fallback)
    end
    if o.setTexts ~= nil then o:setTexts(texts) end
    if o.setState ~= nil then o:setState(self:periodIndexSafe()) end
end

---A PERIOD CHANGE IS A REPOPULATE, NOT A REBUILD. Nothing about the world moved;
-- only the unit the same figures are quoted in. Rebuilding would re-walk every
-- cluster and re-read every trough for no new information.
function HerdInspectorPage:onPeriodChanged(state)
    -- the same guard onViewChanged carries: MultiTextOption's onClick raise site is
    -- in the stripped part of the SDK source, so the argument list is not readable
    -- and a non-number would silently pin the page to its fallback period, which
    -- looks exactly like "the selector does nothing"
    local o = self.periodOption
    if type(state) ~= "number" and o ~= nil and o.getState ~= nil then state = o:getState() end
    if type(state) ~= "number" or state < 1 or state > #HerdInspectorPage.PERIODS then return end
    self.periodIndex = state
    for _, id in ipairs({ "groupList", "barnGroupList", "inputList", "madeList", "prodList", "breedList",
                        "pigBreedList", "pigGroupList" }) do
        if self[id] ~= nil then self[id]:reloadData() end
    end
    self:updateSummary()
end

function HerdInspectorPage:initFilterOption()
    local o = self.filterOption
    if o == nil then return end
    local texts = {}
    for _, t in ipairs(self.types or {}) do texts[#texts + 1] = t.name end
    if #texts == 0 then texts = { l10n("ar_hi_filter_all", "All animals") } end
    -- setTexts only when the list actually CHANGED: reassigning it on every
    -- refresh fights a mid-click, and this list is rebuilt on a timer (DR 5.7).
    local joined = table.concat(texts, "\1")
    if joined ~= self._filterTexts and o.setTexts ~= nil then
        o:setTexts(texts)
        self._filterTexts = joined
    end
    if o.setState ~= nil then pcall(o.setState, o, self.filterIndex or 1, true) end
end

function HerdInspectorPage:onFilterChanged(state)
    local o = self.filterOption
    if type(state) ~= "number" and o ~= nil and o.getState ~= nil then state = o:getState() end
    if type(state) ~= "number" then return end
    self.filterIndex = state
    local t = (self.types or {})[state]
    self.filterType = t ~= nil and t.index or nil
    self:rebuild()
    if self.groupList ~= nil then self.groupList:reloadData() end
end

---Is the Herd Adviser switched on? FAILS OPEN, so a build without AnimalSettings
-- shows everything it always did.
---Are the trading windows switched on? Same FAIL-OPEN rule as adviserOn, for the
-- in-row buttons that open them.
---PUT ONE ROW BUTTON JUST AFTER ANOTHER'S REAL WIDTH.
--
-- The buttons size themselves to their labels (ARRowButton), so a fixed x for the
-- second one would either leave a gap or, with a longer translation of the first,
-- overlap it. `position` and `size` are the same normalised units, so the maths is
-- in those units and never in px (a literal px in setPosition is about a screenful,
-- 5.81). setPosition, not move: it recomputes the anchor deltas first, so the new
-- position actually applies (DR 5.87c / 5.91b). Only when it moved, so a repopulate
-- costs nothing.
function HerdInspectorPage.placeAfter(cell, firstName, secondName)
    if cell == nil or cell.getAttribute == nil then return end
    local a, b = cell:getAttribute(firstName), cell:getAttribute(secondName)
    if a == nil or b == nil or b.setPosition == nil then return end
    if type(a.position) ~= "table" or type(a.size) ~= "table" or type(b.position) ~= "table" then return end
    local w = a.size[1]
    if type(w) ~= "number" or w <= 0 or type(a.position[1]) ~= "number" then return end
    local want = a.position[1] + w * 1.15            -- a gap of 15% of the first button's width
    if type(b.position[1]) ~= "number" or math.abs(b.position[1] - want) > 1e-6 then
        pcall(b.setPosition, b, want, b.position[2])
    end
end

function HerdInspectorPage.tradingOn()
    if AnimalSettings == nil or AnimalSettings.tradingEnabled == nil then return true end
    return AnimalSettings.tradingEnabled()
end
function HerdInspectorPage.autoTraderOn()
    if AnimalSettings == nil or AnimalSettings.autoTraderEnabled == nil then return true end
    return AnimalSettings.autoTraderEnabled()
end

function HerdInspectorPage.adviserOn()
    if AnimalSettings == nil or AnimalSettings.herdAdviserEnabled == nil then return true end
    return AnimalSettings.herdAdviserEnabled()
end


---Re-apply the view because a SETTING moved, not because the player changed view.
-- A setting that shows or hides a column changes the shape of a table, which a
-- repopulate cannot express -- the header is not part of the list.
function HerdInspectorPage.refreshView()
    for _, pg in ipairs(HerdInspectorPage.allPages()) do
        if pg.applyView ~= nil then
            pcall(pg.applyView, pg)
            local l = pg.activeList ~= nil and pg:activeList() or nil
            if l ~= nil and l.reloadData ~= nil then pcall(l.reloadData, l) end
        end
    end
end

---EVERY INSTANCE. There are two when DR hosts the Overview page, and a setting that moved has to
-- reach both -- refreshing only the one in `_page` would leave the other showing a removed column.
function HerdInspectorPage.allPages()
    if type(HerdInspectorPage._pages) == "table" and #HerdInspectorPage._pages > 0 then
        return HerdInspectorPage._pages
    end
    return { HerdInspectorPage._page }
end

---THE INSTANCE ON SCREEN, for a footer button shared by both. Falls back to `_page`.
function HerdInspectorPage.livePage()
    local menu = HerdInspectorPage._menu
    local cur = menu ~= nil and menu.currentPage or nil
    for _, pg in ipairs(HerdInspectorPage.allPages()) do
        if pg == cur then return pg end
    end
    return HerdInspectorPage._page
end

function HerdInspectorPage:activeList()
    if self:viewIndexSafe() == HerdInspectorPage.VIEW_BREEDS then return self.breedList end
    if HerdInspectorPage.isBarnLayout(self:viewIndexSafe()) then return self.barnList end
    return self.groupList
end

---THE HEADING NAMES WHAT IS ON SCREEN. The two views answer different questions --
-- one surveys every group on the farm, the other examines a single building -- so a
-- heading that reads "Herd Inspector" over a barn is describing the other view.
--
-- Set from applyView rather than from the selector callback, so it is right on the
-- first open too: applyView runs on every path that changes the view, the callback
-- only on the ones the player drives.
function HerdInspectorPage:updateTitle()
    local t = self.pageTitle
    if t == nil or t.setText == nil then return end
    -- viewIndexSafe, not the raw field: applyView below decides the BODY with it,
    -- and a heading resolved from a different value could name the other view.
    -- UNDER THE OVERVIEW THE HEADING IS THE OVERVIEW'S. The page stands in for one of that
    -- page's tabs, so a different title would read as having left it.
    if self.hostMode ~= nil and self.hostMode == HerdInspectorPage.MODE_OVERVIEW then
        t:setText(l10n("ar_hi_page_title_overview", "Overview"))
        return
    end
    local v = self:viewIndexSafe()
    local txt = HerdInspectorPage.VIEW_TEXT[v] or HerdInspectorPage.VIEW_TEXT[HerdInspectorPage.VIEW_GROUPS]
    t:setText(l10n(txt[3], txt[4]))
end

function HerdInspectorPage:applyView()
    self:updateTitle()
    if self.hostMode ~= nil and self.hostMode == HerdInspectorPage.MODE_OVERVIEW then self:showViewSelector(true) end
    local v = self:viewIndexSafe()
    local groups = (v == HerdInspectorPage.VIEW_GROUPS)
    local breeds = (v == HerdInspectorPage.VIEW_BREEDS)
    -- THE BARN LIST SERVES TWO VIEWS. Breeds belong to a barn, so that view needs
    -- the same left-hand chooser, but none of the BARN view's own panes.
    -- A TYPE VIEW IS THE BARN VIEW with a filtered list, so it takes the barn
    -- layout wholesale; the filter itself lives in rebuild().
    local barn = HerdInspectorPage.isBarnLayout(v)
    -- THE PIGS TAB SWAPS ONE TABLE FOR TWO: breeds above, animals below, in the
    -- same column the barn view's single animals table fills.
    -- ...and so does the COWS tab: every type view takes this layout.
    local pigs = HerdInspectorPage.isTypeView(v)
    local function vis(el, show)
        if el ~= nil and el.setVisible ~= nil then pcall(function() el:setVisible(show) end) end
    end
    -- THE WRAPPER, NOT THE LIST. Every list now sits in a GuiElement alongside its
    -- scrollbar (20.31), so hiding the list alone would leave the slider drawn
    -- beside nothing -- the same reason filterBox is toggled rather than the
    -- MultiTextOption inside it. Hiding the parent hides the children.
    vis(self.groupHeaderRow, groups)
    vis(self.groupListBox,   groups)
    -- the CONTAINER, not the option: hiding the MultiTextOption alone leaves its
    -- background box drawn behind nothing
    vis(self.filterBox,      groups)
    -- NOT on the Breeds view any more: it lists every breed on the farm (2026-09-29).
    vis(self.barnHeaderRow,     barn)
    vis(self.barnListBox,       barn)
    vis(self.breedHeaderRow,    breeds)
    vis(self.breedListBox,      breeds)
    -- the panel and its header are BOTH left to updateSummary, which runs after
    -- this and would overrule anything set here anyway
    
    vis(self.bgHeaderRow,       barn and not pigs)
    vis(self.barnGroupListBox,  barn and not pigs)
    vis(self.pigBreedHeaderRow, pigs)
    vis(self.pigBreedListBox,   pigs)
    vis(self.pigGroupHeaderRow, pigs)
    vis(self.pigGroupListBox,   pigs)
    vis(self.inputHeaderRow,    barn)
    vis(self.inputListBox,      barn)
    vis(self.madeHeaderRow,     barn)
    vis(self.madeListBox,       barn)
    vis(self.prodHeaderRow,     barn)
    vis(self.prodListBox,       barn)

    -- DR's paced refresh repopulates whatever is in here; a hidden pane listed
    -- would pay for cells nobody can see.
    if groups then
        self._realtimeLists = { "groupList" }
    elseif breeds then
        self._realtimeLists = { "breedList" }
    elseif pigs then
        self._realtimeLists = { "barnList", "pigBreedList", "pigGroupList", "inputList", "madeList", "prodList" }
    else
        self._realtimeLists = { "barnList", "barnGroupList", "inputList", "madeList", "prodList" }
    end

    self:applyButtonSet(breeds)
    self:rebuild()
    self:initFilterOption()
    local l = self:activeList()
    if l ~= nil then l:reloadData() end
    -- the panes that are NOT the active list still need reloading, or they keep
    -- whatever the previous barn left in them
    for _, id in ipairs({ "groupList", "barnGroupList", "inputList", "madeList", "prodList", "breedList",
                        "pigBreedList", "pigGroupList" }) do
        if self[id] ~= nil and self[id] ~= l then self[id]:reloadData() end
    end
    -- THE HIGHLIGHT MUST NAME THE SAME BARN AS THE PANES. Switching into or out of
    -- a type view changes which barn sits at each row, and a SmoothList keeps its
    -- own selected index across a reload -- so without this the list could
    -- highlight one barn while the panel and tables describe another (DR 5.77a).
    if barn and self.barnList ~= nil and #(self.barns or {}) > 0 then
        pcall(self.barnList.setSelectedItem, self.barnList, 1, self.selectedBarn, true)
    end
    self:updateSummary()
end

-- ---------------------------------------------------------------------------
-- FRAME
-- ---------------------------------------------------------------------------
function HerdInspectorPage:onGuiSetupFinished()
    HerdInspectorPage:superClass().onGuiSetupFinished(self)
    for _, id in ipairs(HerdInspectorPage.LIST_IDS) do
        local list = self[id]
        if list ~= nil then
            list:setDataSource(self)
            list:setDelegate(self)
        end
    end
end

---EVERY PAGE OPENS ON CYCLE (author's call, 2026-09-09), matching DR's tabs.
--
-- The selector kept whatever the player last chose for the life of the session, because
-- it is initialised once when the GUI is built. Opening the menu is the moment you want
-- "what is happening right now", so it resets to the shortest period and a deliberate
-- choice lasts as long as you are looking at it.
--
-- The WIDGET is re-synced with it: setting the index alone would leave the selector
-- reading MONTH while every figure under it, and the profit headline's own label,
-- reported per cycle.
function HerdInspectorPage:resetPeriodToCycle()
    self.periodIndex = 1
    local o = self.periodOption
    if o ~= nil and o.setState ~= nil then pcall(o.setState, o, 1) end
end

function HerdInspectorPage:onFrameOpen()
    HerdInspectorPage:superClass().onFrameOpen(self)
    self:resetPeriodToCycle()
    -- WHICH TABS EXIST is decided before the strip is drawn, and the view is moved onto one
    -- that does -- the first open has none chosen yet, and a view can have lost its last barn
    -- while the menu was shut.
    self:refreshPresence()
    -- THE OVERVIEW PAGE OPENS ON BREEDS (author, 2026-09-29; it was Animals from 2026-09-27), the
    -- same way every page opens on cycle: arriving is the moment to be shown the default, and a
    -- choice lasts while you look. A farm with no barn has no Breeds view, and ensureViewValid
    -- below moves it onto Animals.
    if self.hostMode ~= nil and self.hostMode == HerdInspectorPage.MODE_OVERVIEW then self.viewIndex = HerdInspectorPage.VIEW_BREEDS end
    self:ensureViewValid()
    self:initViewOption()
    self:initPeriodOption()
    self:applyView()
    self._tabsDirty = false
end

function HerdInspectorPage:getNumberOfItemsInSection(list, section)
    if list == self.groupList then return #(self.groupRows or {}) end
    if list == self.barnList then return #(self.barns or {}) end
    -- THE PIGS TAB'S TWO TABLES READ THE SAME ROWS as the barn view's animals
    -- table and the Breeds view: they are a different LAYOUT of one data set.
    if list == self.barnGroupList or list == self.pigGroupList then return #(self.barnGroupRows or {}) end
    if list == self.breedList or list == self.pigBreedList then return #(self.breedRows or {}) end
    if list == self.inputList then return #(self.inputRows or {}) end
    if list == self.madeList then return #(self.madeRows or {}) end
    if list == self.prodList then return #(self.prodRows or {}) end
    return 0
end

---WHERE A BREED'S EARNINGS COME FROM, in one short line.
--
-- The terms rather than the conclusion (28.8): the model prices RAW fill types and
-- cannot see what a farm does downstream, so a figure that is arithmetically right
-- can still be wrong for this player. Naming the products is what lets them argue
-- with it, and it is the reason this column exists at all.
--
-- BIGGEST FIRST AND CAPPED AT THREE: the column is 325px, and the tail of a list
-- of products is never the one being questioned.
function HerdInspectorPage:breedTermsText(r)
    if r == nil then return "-" end
    -- MADE BUT UNPRICEABLE IS NOT THE SAME AS EARNING NOTHING, and a dash would
    -- give the first answer when it means the second.
    if (r.earns == nil or next(r.earns) == nil) and (r.unpriced or 0) > 0 then
        return l10n("ar_hi_notPriced", "made, but not priceable")
    end
    if r.earns == nil then return "-" end
    local parts = {}
    for ft, v in pairs(r.earns) do parts[#parts + 1] = { ft = ft, v = v } end
    table.sort(parts, function(x, y)
        if x.v ~= y.v then return x.v > y.v end
        return tostring(x.ft) < tostring(y.ft)
    end)
    local bits, m = {}, g_fillTypeManager
    for i, e in ipairs(parts) do
        if i > 3 then break end
        local title = nil
        if m ~= nil and m.getFillTypeTitleByIndex ~= nil and type(e.ft) == "number" then
            local okT, v = pcall(m.getFillTypeTitleByIndex, m, e.ft)
            if okT and type(v) == "string" and v ~= "" then title = v end
        end
        bits[#bits + 1] = string.format("%s %s", title or tostring(e.ft), money(e.v))
    end
    if #bits == 0 then return "-" end
    return table.concat(bits, ", ")
end

---THE ARROWS. One callback is cloned into every row, so the only way to know which
-- breed was clicked is what populate left ON the element (DR 5.64) -- and the
-- raise site for a Button's onClick is in the stripped part of the SDK source, so
-- the varargs are SCANNED for the element carrying the field rather than a
-- position being assumed.
function HerdInspectorPage:clickedBreed(...)
    for i = 1, select("#", ...) do
        local e = select(i, ...)
        if type(e) == "table" and e.arBreed ~= nil then return e.arBreed, e.arBarnUid, e end
    end
    return nil, nil
end

function HerdInspectorPage:stepBreedPurpose(back, ...)
    if AnimalHerdPolicy == nil then return end
    local breed, uid, el = self:clickedBreed(...)
    if breed == nil or uid == nil then return end
    if el ~= nil and el.arToggle and AnimalHerdPolicy.togglePurpose ~= nil then
        -- THE PIGS TAB SHOWS A DEFAULT, so its arrows FLIP between the two answers
        -- rather than stepping the ring through UNSET, which would look identical
        -- to the default and read as a press that did nothing.
        AnimalHerdPolicy.togglePurpose(uid, breed)
    else
        -- BACKWARDS IS THE FORWARD RING WALKED, never a second hand-written order: a
        -- reverse list is free to drift the next time a state is added, and these
        -- cannot (DR 5.64 draws the same conclusion about the mode ring).
        local steps = back and (#AnimalHerdPolicy.RING - 1) or 1
        for _ = 1, steps do AnimalHerdPolicy.cyclePurpose(uid, breed) end
    end
    self:rebuild()
    if self.breedList ~= nil then self.breedList:reloadData() end
    if self.pigBreedList ~= nil then self.pigBreedList:reloadData() end
end

---SWAP THE FOOTER FOR THIS VIEW.
--
-- `setMenuButtonInfo` puts the set on the PAGE; the menu only re-reads it when it
-- updates the panel, so `updateButtonsPanel` has to be asked. Both are the base
-- game's own (TabbedMenuFrameElement / TabbedMenu, read from source) -- and
-- `getPageButtonInfo` calls `getHasCustomMenuButtons` first, which is true exactly
-- because a set was assigned at install.
--
-- ONLY WHEN IT CHANGES: this runs on every view switch, and re-adding the button
-- box rebuilds the footer, which is not something to do for a set already showing.
---Is a footer button switched OFF in AnimalSettings? Answered here rather than
-- read at the definition site, because a setting can move while this page is
-- open: the set has to be rebuilt on demand, not chosen once at install.
--
-- FAILS OPEN. With AnimalSettings absent (a load failure, an older build) every
-- button shows, which is the behaviour before the settings existed. A missing
-- settings file must not take features away.
local function buttonEnabled(kind)
    if AnimalSettings == nil then return true end
    if kind == "trade" then return AnimalSettings.tradingEnabled() end
    -- THE AUTO TRADER OWNS ONE BUTTON AGAIN. It used to own four, because the two
    -- RULES buttons configured constraints on the standing orders this setting
    -- deletes -- and those buttons are gone (39a), so the set it governs is back to
    -- the single window that opens a standing order.
    if kind == "schedule" then return AnimalSettings.autoTraderEnabled() end
    return true
end

---The footer set, with any switched-off entry left out.
-- BACK IS ALWAYS FIRST AND ALWAYS PRESENT: a page you cannot leave is worse than
-- a page with no buttons.
--
-- ONE SET FOR ALL THREE VIEWS, since 39a. The BREEDS view used to swap in a pair
-- of RULES buttons instead; author, 2026-09-10: *"remove the buy rule and sell
-- rule dialogues and button and replace them with Buy/Sell and Autotrader buttons
-- just like on the barn and animals tabs."* Trading is trading wherever the player
-- is standing, and the view already decides the SCOPE of the window that opens
-- (openTrade / openSchedule) rather than which button opens it.
local function buildButtonSet(noTrade)
    local b = HerdInspectorPage._buttons
    if b == nil then return nil end
    local out = { b.back }
    -- NOT ON THE PIGS TAB: Buy and Sell live in each animal row there (2026-09-13).
    -- STRICTLY true: an older caller handing in a view NAME must not strip the button.
    if buttonEnabled("trade") and noTrade ~= true then out[#out + 1] = b.trade end
    if buttonEnabled("schedule") then out[#out + 1] = b.schedule end
    return out
end

---`breeds` IS ACCEPTED AND IGNORED. Every caller already computes which view is
-- showing and the set no longer varies with it; keeping the parameter costs
-- nothing and keeps applyView / refreshButtons unchanged.
function HerdInspectorPage:applyButtonSet(breeds)
    if HerdInspectorPage._buttons == nil or self.setMenuButtonInfo == nil then return end
    -- THE SETTINGS ARE THE WHOLE IDENTITY OF THE SET now that the view is not.
    -- Keying the "nothing changed" test on anything less is what would leave a
    -- removed button on screen until the player switched views and back.
    -- ...plus whether this is the Pigs tab, whose Buy / Sell moved into the rows.
    local noTrade = (self.viewIndexSafe ~= nil and HerdInspectorPage.isTypeView(self:viewIndexSafe()))
    local sig = tostring(buttonEnabled("trade")) .. ":"
                .. tostring(buttonEnabled("schedule")) .. ":" .. tostring(noTrade)
    if self._buttonSet == sig then return end
    self._buttonSet = sig
    self:setMenuButtonInfo(buildButtonSet(noTrade))
    HerdInspectorPage.repaintFooter(self)
end

---Push this page's buttons into the MENU's footer -- but ONLY while this page is
-- the one on screen.
--
-- TabbedMenu:updateButtonsPanel(page) assigns THAT page's buttons unconditionally
-- (TabbedMenu.lua:618). It is harmless when called from a view switch, because the
-- herd page is showing by definition -- and it is not harmless at all when called
-- from AnimalSettings, which runs while the player is on the SETTINGS page. That
-- shipped: toggling Buy / Sell or the Auto Trader put BUY / SELL and AUTO TRADER
-- into the Settings page's own footer.
--
-- setMenuButtonInfo above is left UNCONDITIONAL, and that is the half that makes
-- this correct rather than merely quiet: the set is stored on the page either way,
-- so the footer is already right the moment the player navigates back. Only the
-- immediate repaint is withheld.
function HerdInspectorPage.repaintFooter(page)
    local menu = HerdInspectorPage._menu
    if menu == nil or menu.updateButtonsPanel == nil then return end
    if menu.currentPage ~= nil and menu.currentPage ~= page then return end
    pcall(menu.updateButtonsPanel, menu, page)
end

---Rebuild the footer of the live page because a setting moved. Called from
-- AnimalSettings; a no-op when the tab has never been opened.
function HerdInspectorPage.refreshButtons()
    for _, pg in ipairs(HerdInspectorPage.allPages()) do
        if pg.applyButtonSet ~= nil then
            pg._buttonSet = nil                   -- force it through the signature test
            pcall(pg.applyButtonSet, pg)
        end
    end
end

-- SELL RULES AND BUY RULES ARE GONE (39a), and the two handlers that opened them
-- with it. Sell rules were disconnected from the sale itself first (39): a sell
-- order takes the oldest animals in rank order and nothing else, so a window
-- configuring constraints on a decision nothing makes any more would have been a
-- setting the player could change with no effect -- worse than no window. Buy
-- rules never had an engine at all; that button only ever explained itself.
--
-- selectedBreedRow went with them: only openSellRules ever asked which breed row
-- was picked. The PURPOSE arrows act on their own row and read it themselves.

function HerdInspectorPage:onBreedNext(...) return self:stepBreedPurpose(false, ...) end
function HerdInspectorPage:onBreedPrev(...) return self:stepBreedPurpose(true, ...) end

-- ---------------------------------------------------------------------------
-- IN-ROW BUY / SELL / AUTO TRADER (the Pigs tab, 2026-09-13).
--
-- One callback is cloned into every row, so what a button acts on is what populate
-- left ON THE ELEMENT (DR 5.64), stored as a barn uid plus a cluster or a breed --
-- never a row index, because these lists re-enumerate on a timer. The varargs are
-- scanned for that element rather than a position being assumed, for the reason
-- clickedBreed gives.
function HerdInspectorPage:clickedRowButton(...)
    for i = 1, select("#", ...) do
        local e = select(i, ...)
        if type(e) == "table" and e.arBarnUid ~= nil then return e end
    end
    return nil
end

function HerdInspectorPage:barnByUid(uid)
    if uid == nil then return nil end
    for _, b in ipairs(self.barns or {}) do
        if b.uid == uid then return b end
    end
    return nil
end

---BUY: the barn's dealer catalogue, on the BUY tab. The group row it was pressed
-- on has no bearing on what the dealer sells, so nothing is preselected.
function HerdInspectorPage:onGroupBuy(...)
    if not HerdInspectorPage.tradingOn() then return end
    if AnimalTradeDialog == nil or AnimalTradeDialog.show == nil or AnimalTrade == nil then return end
    local e = self:clickedRowButton(...)
    local b = e ~= nil and self:barnByUid(e.arBarnUid) or nil
    if b == nil then return end
    AnimalTradeDialog.show({ b }, true, nil, AnimalTrade.MODE_BUY)
end

---SELL: the SELL tab with this very group selected and in view. Passed as the
-- CLUSTER OBJECT, the identity openTrade already relies on.
function HerdInspectorPage:onGroupSell(...)
    if not HerdInspectorPage.tradingOn() then return end
    if AnimalTradeDialog == nil or AnimalTradeDialog.show == nil or AnimalTrade == nil then return end
    local e = self:clickedRowButton(...)
    local b = e ~= nil and self:barnByUid(e.arBarnUid) or nil
    if b == nil then return end
    AnimalTradeDialog.show({ b }, true, e.arCluster, AnimalTrade.MODE_SELL)
end

---AUTO TRADER, narrowed to the breed whose row it was pressed on.
function HerdInspectorPage:onBreedTrader(...)
    if not HerdInspectorPage.autoTraderOn() then return end
    if AnimalBuyScheduleDialog == nil or AnimalBuyScheduleDialog.show == nil then return end
    local e = self:clickedRowButton(...)
    local b = e ~= nil and self:barnByUid(e.arBarnUid) or nil
    if b == nil or e.arBreed == nil then return end
    AnimalBuyScheduleDialog.show({ b }, true, nil, e.arBreed)
end

---A SINGLE click only selects. A DOUBLE click on the Breeds view opens that barn's page -- the
-- animal-type tab it belongs to, with the barn selected (author, 2026-09-29).
--
-- SmoothList has no double-click event, so it is built from onClick, which fires on EVERY click
-- including one on the row already selected (DR 6.29). Matched on the row's IDENTITY (barn + breed),
-- never its index: the list re-enumerates on a timer and rows can move between the two clicks
-- (DR 5.37).
HerdInspectorPage.DOUBLE_CLICK_SEC = 0.4
function HerdInspectorPage:onBreedClick(list, section, index)
    if list ~= self.breedList then return end
    local r = (self.breedRows or {})[index or 0]
    if r == nil or r.barnUid == nil then return end
    local now = (getTimeSec ~= nil) and getTimeSec() or nil
    if now == nil then return end
    local key = tostring(r.barnUid) .. "|" .. tostring(r.name)
    local last = self._lastBreedClick
    if last ~= nil and last.key == key and now - last.t <= HerdInspectorPage.DOUBLE_CLICK_SEC then
        self._lastBreedClick = nil
        self:openBarnPage(r.barnUid, r.barnType)
        return
    end
    self._lastBreedClick = { key = key, t = now }
end

---The animal-type view a barn of `typeName` sits on: the first named type that takes it, else Other.
function HerdInspectorPage.typeViewFor(typeName)
    for _, v in ipairs(HerdInspectorPage.TAB_ORDER) do
        if HerdInspectorPage.isTypeView(v) and HerdInspectorPage.viewTakesType(v, typeName) then return v end
    end
    return nil
end

---OPEN ONE BARN ON ITS ANIMAL-TYPE TAB. Under DR that tab lives on the OTHER instance (the Herd
-- Inspector's own left row, MODE_TYPES), so the menu goes there; standalone it is this same page, so
-- the view simply switches. The target opens through onFrameOpen, which re-resolves selectedUid to a
-- row and highlights it, so setting the uid and the view first is all it needs.
function HerdInspectorPage:openBarnPage(barnUid, typeName)
    local v = HerdInspectorPage.typeViewFor(typeName)
    if v == nil then return false end
    local target = self
    if self.hostMode == HerdInspectorPage.MODE_OVERVIEW then
        for _, pg in ipairs(HerdInspectorPage.allPages()) do
            if pg ~= self and pg.hostMode == HerdInspectorPage.MODE_TYPES then target = pg end
        end
        if target == self then return false end
    end
    target.selectedUid = barnUid
    if target == self then
        self:selectView(v)
        return true
    end
    target.viewIndex = v
    local menu = HerdInspectorPage._menu
    if menu == nil or menu.goToPage == nil then return false end
    return (pcall(menu.goToPage, menu, target))
end

-- WHY A BREED GOT ITS VERDICT. The engine hands back a code; the wording is ours,
-- because that module is pure. Mapped EXPLICITLY rather than built from the code,
-- so check_l10n_animal.py can see every key.
local ADVICE_REASON_KEY = {
    outputBeatsCalves = "ar_hi_why_outputBeats",
    calvesWorthMore   = "ar_hi_why_calvesWorth",
    noOutput          = "ar_hi_why_noOutput",
    nothingToWeigh    = "ar_hi_why_nothingToWeigh",
}

---THE VERDICT AND WHY, in one cell.
--
-- "Producers" on its own is a conclusion a player cannot argue with (28.8). The
-- reason is what makes it checkable against their own intention for the barn, and
-- noOutput says something quite different from calvesWorthMore though both read
-- "Breeders".
function HerdInspectorPage:adviceText(r)
    if r == nil then return "-" end

    -- A SELL ORDER WHERE THERE IS ONE TO GIVE, phrased the way an order is
    -- defined so it can be typed straight in rather than translated first
    -- (author, 2026-09-10). It comes FIRST because it is an instruction, while
    -- the verdict below it is a classification.
    --
    -- Y IS OMITTED WHERE NOTHING IS BREEDING. A cohort grown out and sold once
    -- has no cadence -- the author's pigs read "too young" at 4 months -- and
    -- inventing an interval would promise a repeat sale the herd cannot supply.
    if (r.sellNow or 0) > 0 then
        local x = r.sellNow
        if r.everyMonths ~= nil and r.startIn ~= nil then
            return string.format(l10n("ar_hi_order_every",
                "Sell %d every %d mo, from %d mo"), x, r.everyMonths, r.startIn)
        end
        if r.startIn ~= nil then
            return string.format(l10n("ar_hi_order_once", "Sell %d in %d mo"), x, r.startIn)
        end
        return string.format(l10n("ar_hi_order_now", "Sell %d now"), x)
    end

    if r.use == nil then return "-" end
    local word = (r.use == "NURSERY") and l10n("ar_hi_purpose_breeder", "Breeders")
                                      or  l10n("ar_hi_purpose_producer", "Producers")
    local key = ADVICE_REASON_KEY[r.reason or ""]
    if key == nil then return word end
    -- SHORTER NOW THAT THE FIGURES ARE BESIDE IT. The reason names WHICH side won;
    -- the two columns say by how much, which is what the sentence alone could not.
    return string.format(l10n("ar_hi_adviceWhy", "%s - %s"), word, l10n(key, ""))
end

---THE TYPE TABS' ADVICE CELL (Pigs 2026-09-14, Cows 2026-09-24). Exactly one of two answers:
--   "Keep animals"  a PRODUCER herd whose output earns more than selling its
--                   offspring (the slot verdict is not NURSERY), or a herd with
--                   no rotation to give (no price curve or breeding cycle)
--   "Sell A animals, every B months, starting in C months"  everything else: the
--                   ROTATING-HERD order (option A) -- A the cohort the pen holds per
--                   breeding cycle, B the cycle, C when the first sale falls due.
--   ON THE COWS TAB the cohort age is the best SALE age, not peak (rotationOf with the
--   building): a dairy herd whose milk outweighs its decline comes back `keep` and reads
--   "Keep animals"; a beef herd rotates near peak. Pigs never decline, so theirs is unchanged.
--   Not "one per breeder" (the first version): a sell order takes the oldest, who
--   ARE the breeders, and a full pen has no room for their births, so that advice
--   would have sold the whole herd.
---THE SALE ANSWER FOR ONE BREED: (text, due) or nil when it should simply be kept.
-- `due` is true when the sale is for NOW, which is what ranks it first in actionsFor.
-- The words are exactly the ones this table has always shown; pigAdviceText wraps it.
function HerdInspectorPage:saleAdvice(r)
    if r == nil or not r.held then return nil end
    local PRODUCER = (AnimalHerdPolicy ~= nil and AnimalHerdPolicy.PRODUCER) or "PRODUCER"
    local purpose = r.purposeShown or r.purpose
    -- COUNTS ARE PLURALISED WHOLE ("1 month", "4 months"), each from its own key, so a
    -- translation can inflect them however its language needs.
    local function count(n, one, oneFallback, many, manyFallback)
        if n == 1 then return string.format(l10n(one, oneFallback), n) end
        return string.format(l10n(many, manyFallback), n)
    end
    local function months(n)
        return count(n, "ar_hi_unit_month", "%d month", "ar_hi_unit_months", "%d months")
    end
    if purpose == PRODUCER and r.use ~= "NURSERY" then
        -- KEEP ONLY WHILE THEY PAY FOR THEMSELVES, feed included (author, 2026-09-24). The
        -- breed verdict that gets us here leaves feed out -- it cancels between adults and
        -- young stock in the same slot -- so it cannot say whether to keep the herd at all.
        -- producerSaleFor can. With no answer (no price curve, a collaborator missing) the
        -- old "Keep animals" stands rather than inventing a sale.
        local ps = r.prodSale
        if ps == nil or ps.keep then return nil end
        if ps.sellNow or (ps.monthsUntil or 0) <= 0 then
            return l10n("ar_hi_prod_sellNow", "Sell now - they cost more than they earn"), true
        end
        return string.format(l10n("ar_hi_prod_sellAt", "Sell at %s (in %s)"),
                             months(ps.bestAge), months(ps.monthsUntil)), false
    end
    -- THE ROTATING-HERD ORDER (option A), worked out in buildBreedRows
    local a, b, c = r.rotSell, r.rotEvery, r.rotStart
    if (a or 0) <= 0 or b == nil then return nil end
    c = c or 0
    local animals = count(a, "ar_hi_unit_animal", "%d animal", "ar_hi_unit_animals", "%d animals")
    local every = count(b, "ar_hi_unit_month", "%d month", "ar_hi_unit_months", "%d months")
    if c <= 0 then
        return string.format(l10n("ar_hi_pig_sellNow", "Sell %s, every %s, starting now"), animals, every), true
    end
    return string.format(l10n("ar_hi_pig_sell", "Sell %s, every %s, starting in %s"), animals, every,
                         count(c, "ar_hi_unit_month", "%d month", "ar_hi_unit_months", "%d months")), false
end

---The type tabs' old single-sentence advice, kept as a thin wrapper so its wording and its
-- harness checks stay exactly as they were.
function HerdInspectorPage:pigAdviceText(r)
    if r == nil or not r.held then return "-" end
    local t = self:saleAdvice(r)
    return t or l10n("ar_hi_pig_keep", "Keep animals")
end

-- ---- BREED ACTIONS (2026-09-28) ----------------------------------------------------------
-- Author's option A: ONE action per breed row, the most urgent, with "(+N more)" when there
-- are others, and every action listed when the cell is hovered. Three sources, in the order
-- the author agreed, then two lower ones that used to have columns of their own:
--   1 SALE DUE NOW     -- saleAdvice, per breed
--   2 LOSING MONEY     -- the barn's Herd Value advice when its tone is "bad"
--   3 FEED             -- the barn's feed advice when it is anything but "good"
--   4 SALE SCHEDULED   -- saleAdvice, due later
--   5 PURPOSE          -- the breed verdict, when it disagrees with the purpose in force
-- FEED AND PROFIT ARE BARN FACTS (one ration per pen, one profit forecast) and are shown on
-- EVERY breed of the barn, author's call: most barns hold a single breed anyway.
-- A breed the barn does not hold has nothing to act on and reads "-".
local ACTION_TONE = { sale = "bad", loss = "bad", later = "warn", purpose = "warn" }

---The barn's panel data, memoised briefly: the breed rows and the panel both need it on the
-- same refresh, and husbandryPanel walks the whole herd.
function HerdInspectorPage:barnPanel(placeable)
    if placeable == nil or HusbandryRedux == nil or HusbandryRedux.husbandryPanel == nil then return nil end
    local now = (getTimeSec ~= nil) and getTimeSec() or nil
    self._panelMemo = self._panelMemo or setmetatable({}, { __mode = "k" })
    local m = self._panelMemo[placeable]
    if m ~= nil and now ~= nil and m.t ~= nil and (now - m.t) < 1.0 then return m.d end
    local ok, d = pcall(HusbandryRedux.husbandryPanel, placeable)
    d = ok and d or nil
    self._panelMemo[placeable] = { t = now, d = d }
    return d
end

---The barn-level actions shared by every breed in it: { loss = {text,tone}|nil, feed = ... }.
function HerdInspectorPage.barnActions(panel)
    local out = {}
    if type(panel) ~= "table" then return out end
    local va = type(panel.value) == "table" and panel.value.advice or nil
    if type(va) == "table" and type(va.text) == "string" and va.tone == "bad" then
        out.loss = { text = va.text, tone = "bad" }
    end
    local fa = type(panel.feed) == "table" and panel.feed.advice or nil
    if type(fa) == "table" and type(fa.text) == "string" and fa.tone ~= "good" then
        out.feed = { text = fa.text, tone = (fa.tone == "bad") and "bad" or "warn" }
    end
    return out
end

---Every action for one breed row, most urgent first: { { kind, text, tone }, ... }.
function HerdInspectorPage:actionsFor(r)
    local list = {}
    if r == nil or not r.held then return list end
    local function add(kind, text, tone)
        if type(text) == "string" and text ~= "" and text ~= "-" then
            list[#list + 1] = { kind = kind, text = text, tone = tone or ACTION_TONE[kind] }
        end
    end
    local saleText, due = self:saleAdvice(r)
    local ba = r.barnActions or {}
    if saleText ~= nil and due then add("sale", saleText) end
    if ba.loss ~= nil then add("loss", ba.loss.text, ba.loss.tone) end
    if ba.feed ~= nil then add("feed", ba.feed.text, ba.feed.tone) end
    if saleText ~= nil and not due then add("later", saleText) end
    -- THE VERDICT ONLY WHEN IT DISAGREES with the purpose in force: agreeing with the player
    -- is not an action, and the As producer / As breeder columns carry the numbers either way.
    if r.use ~= nil and AnimalHerdPolicy ~= nil then
        local want = (r.use == "NURSERY") and AnimalHerdPolicy.BREEDER or AnimalHerdPolicy.PRODUCER
        local shown = r.purposeShown or r.purpose
        if shown ~= nil and want ~= shown then
            add("purpose", string.format(l10n("ar_act_purpose", "Better kept as %s"), self:purposeText(want)))
        end
    end
    return list
end

---The cell text for a row: the headline action with "(+N more)", or Keep, or "-".
-- Returns text, tone, and the full list (for the hover box).
function HerdInspectorPage:actionHeadline(r)
    if r == nil or not r.held then return "-", "mute", {} end
    local list = self:actionsFor(r)
    if #list == 0 then return l10n("ar_hi_pig_keep", "Keep animals"), nil, list end
    local text = list[1].text
    if #list > 1 then
        text = text .. " " .. string.format(l10n("ar_act_more", "(+%d more)"), #list - 1)
    end
    return text, list[1].tone, list
end

-- ---- THE HOVER BOX -----------------------------------------------------------------------
-- Husbandry Redux's own, because it must work without Distribution Redux. Immediate mode like
-- DR's (DR 5.108): an element carrying `arTipLines` answers a hover, and the page draws the box
-- in its draw(). The registry is WEAK-KEYED so a recycled list cell cannot keep a stale list,
-- and a hover only counts on an element that is visible all the way up, so a page that is not
-- on screen can never answer.
HerdInspectorPage._tipEls = setmetatable({}, { __mode = "k" })
HerdInspectorPage.TIP_DELAY = 0.25

function HerdInspectorPage.setTipLines(el, lines)
    if el == nil then return end
    if type(lines) ~= "table" or #lines == 0 then
        el.arTipLines = nil
        HerdInspectorPage._tipEls[el] = nil
        return
    end
    el.arTipLines = lines
    HerdInspectorPage._tipEls[el] = true
end

local function tipVisible(el)
    local e = el
    while e ~= nil do
        if e.visible == false then return false end
        e = e.parent
    end
    return true
end

function HerdInspectorPage.tipUnder(mx, my)
    if mx == nil or my == nil then return nil end
    for el in pairs(HerdInspectorPage._tipEls) do
        local p, z = el.absPosition, el.absSize
        if el.arTipLines ~= nil and p ~= nil and z ~= nil and tipVisible(el)
           and mx >= p[1] and mx <= p[1] + z[1] and my >= p[2] and my <= p[2] + z[2] then
            return el.arTipLines
        end
    end
    return nil
end

function HerdInspectorPage:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    self._mx, self._my = posX, posY
    return HerdInspectorPage:superClass().mouseEvent(self, posX, posY, isDown, isUp, button, eventUsed)
end

function HerdInspectorPage:update(dt)
    HerdInspectorPage:superClass().update(self, dt)
    local lines = HerdInspectorPage.tipUnder(self._mx, self._my)
    if lines == nil then self._tip = nil; return end
    if self._tip ~= nil and self._tip.lines == lines then
        self._tip.t = self._tip.t + (dt or 0) / 1000
    else
        self._tip = { lines = lines, t = 0 }
    end
end

function HerdInspectorPage:draw(...)
    HerdInspectorPage:superClass().draw(self, ...)
    local t = self._tip
    if t == nil or t.t < HerdInspectorPage.TIP_DELAY then return end
    pcall(HerdInspectorPage.renderTip, self._mx, self._my, t.lines)
end

---The breed action list is showing: the cut-text box stays out of its way (TextTip.lua).
function HerdInspectorPage:hasOwnTooltip() return self._tip ~= nil end

function HerdInspectorPage:onFrameClose()
    self._tip = nil
    HerdInspectorPage:superClass().onFrameClose(self)
end

---Black box, thin green border, one line per entry; nudged back inside the screen.
function HerdInspectorPage.renderTip(mx, my, lines)
    if renderText == nil or drawFilledRect == nil or mx == nil then return end
    if new2DLayer ~= nil then new2DLayer() end
    local size = (getCorrectTextSize ~= nil) and getCorrectTextSize(0.013) or 0.013
    local gap = size * 0.35
    local w = 0
    for _, l in ipairs(lines) do
        local lw = (getTextWidth ~= nil) and getTextWidth(size, l) or (#l * size * 0.55)
        if lw > w then w = lw end
    end
    local padX, padY = 0.008, 0.008
    local boxW = w + 2 * padX
    local boxH = #lines * size + (#lines - 1) * gap + 2 * padY
    local bx_, by_ = 2 * (g_pixelSizeX or 0.0005), 2 * (g_pixelSizeY or 0.0009)
    local bx, by = mx + 0.005, my + 0.013
    if bx + boxW + bx_ > 0.99 then bx = 0.99 - boxW - bx_ end
    if bx - bx_ < 0.01 then bx = 0.01 + bx_ end
    if by + boxH + by_ > 0.98 then by = my - boxH - 0.012 end
    if by - by_ < 0 then by = by_ end
    drawFilledRect(bx - bx_, by - by_, boxW + 2 * bx_, boxH + 2 * by_, 0.22323, 0.40724, 0.00368, 1)
    drawFilledRect(bx, by, boxW, boxH, 0, 0, 0, 1)
    setTextColor(1, 1, 1, 1)
    if RenderText ~= nil then setTextAlignment(RenderText.ALIGN_LEFT) end
    setTextBold(false)
    -- the FIRST line is at the TOP: screen y runs upward, so it is drawn highest
    for i, l in ipairs(lines) do
        local y = by + boxH - padY - i * size - (i - 1) * gap + size * 0.12
        renderText(bx + padX, y, size, l)
    end
end

---THE WORD FOR A PURPOSE, or a dash when nobody has said. Unset is a STATE and
-- never collapses into either answer (29.2).
function HerdInspectorPage:purposeText(p)
    if p == AnimalHerdPolicy.PRODUCER then return l10n("ar_hi_purpose_producer", "Producers") end
    if p == AnimalHerdPolicy.BREEDER  then return l10n("ar_hi_purpose_breeder",  "Breeders") end
    return "-"
end

---Show or hide a set of named cells together. Set on EVERY populate, because
-- SmoothList recycles cells and a hidden button would otherwise reappear on the next
-- row to use that slot (DR 5.7 / 5.57).
local function showCells(cell, names, on)
    if cell == nil or cell.getAttribute == nil then return end
    for _, n in ipairs(names) do
        local e = cell:getAttribute(n)
        if e ~= nil and e.setVisible ~= nil then e:setVisible(on == true) end
    end
end

function HerdInspectorPage:populateCellForItemInSection(list, section, index, cell)
    -- The Pigs tab's breed table carries a SUBSET of these cells (no earnings,
    -- keeps, calf or terms); setc and setIcon skip a cell the template lacks.
    if list == self.breedList or list == self.pigBreedList then
        local r = (self.breedRows or {})[index]
        if r == nil then return end
        setIcon(cell, "brIcon", (AnimalHerdData ~= nil and r.held)
                and AnimalHerdData.animalIconFile(r.subTypeIndex, r.age or 0) or nil)
        -- A BREED THIS BARN DOES NOT HOLD IS MUTED, not hidden: it is there so a
        -- purpose can be set before the animals arrive, and it should not read as
        -- part of the herd while it is empty.
        local tone = r.held and nil or "mute"
        local pig = (list == self.pigBreedList)
        setc(cell, "brName",    tostring(r.name), tone)
        setc(cell, "brBarn",    r.barnName or "-", "mute")   -- Breeds view only; absent on the type tabs
        setIcon(cell, "brBarnIcon", (AnimalHerdData ~= nil and r.barnPlaceable ~= nil)
                and AnimalHerdData.barnIconFile(r.barnPlaceable) or nil)
        setc(cell, "brCount",   r.held and string.format("%d", r.count or 0) or "-", tone)
        -- THE CURRENT PURPOSE, the same answer on both tables (2026-09-28): it is SET on
        -- the animal-type tabs now, and the Breeds view only reports it. So both show the
        -- effective purpose -- the default where nobody has chosen -- rather than the
        -- Breeds view keeping a dash for UNSET that no control there could change.
        local shown = r.purposeShown
        if shown == nil then shown = r.purpose end
        setc(cell, "brPurpose", self:purposeText(shown))
        -- THE ENGINE'S VERDICT IS ADVICE AND SITS IN ITS OWN COLUMN, so it can be
        -- told apart from what the player chose (29.2). It says nothing about a
        -- breed with no animals to judge.
        -- ONE ACTION, THE MOST URGENT, on both tables (2026-09-28), with every action in the
        -- hover box. Set on every populate: cells are recycled, so a stale list must be cleared.
        local aText, aTone, aList = self:actionHeadline(r)
        setc(cell, "brAdvice", aText, aTone)
        local adv = cell.getAttribute ~= nil and cell:getAttribute("brAdvice") or nil
        if adv ~= nil then
            local lines = nil
            if #aList > 1 then
                lines = {}
                for k, act in ipairs(aList) do lines[k] = string.format("%d. %s", k, act.text) end
            end
            HerdInspectorPage.setTipLines(adv, lines)
        end
        -- A ZERO THAT IS REALLY AN ABSENCE reads as a dash: nothing here could be
        -- priced, so "0" would claim a measurement nobody made (DR 5.46c).
        -- SCALED TO THE PERIOD SELECTOR, like every other rate on this page. The
        -- figure is computed per MONTH and the selector sits directly above this
        -- table, so a column ignoring it quotes a different period from the one the
        -- page says it is showing.
        local earnsText = "-"
        if r.earnsPerAnimal ~= nil and not (r.earnsPerAnimal == 0 and (r.unpriced or 0) > 0) then
            earnsText = money(scaled(r.earnsPerAnimal, self:monthScale()))
        end
        setc(cell, "brEarns",  earnsText, tone)

        -- THE PAIR THE VERDICT WAS ACTUALLY DECIDED ON, which the advice column
        -- asserts and had no numbers behind (author, 2026-09-02).
        --
        -- NEITHER OF THEM IS THE RAW SALE VALUE, and that is the reason both are
        -- here rather than just the calf. `slotVerdict` compares
        --   KEEPS  = econ.marginPerMonth: the output LESS bedding and less the
        --            value the animal loses each month as it ages, and
        --   CALF   = the newborn's price spread over one breeding cycle.
        -- Putting the calf beside the RAW figure would invite a comparison the
        -- engine never made, and where straw and drift are large the raw value can
        -- exceed the calf while the verdict still says breeders. Showing the pair
        -- is what makes the advice checkable instead of merely asserted.
        local k = self:monthScale()
        setc(cell, "brKeeps", r.adult   ~= nil and money(scaled(r.adult, k))   or "-", tone)
        setc(cell, "brCalf",  r.nursery ~= nil and money(scaled(r.nursery, k)) or "-", tone)
        setc(cell, "brTerms",  self:breedTermsText(r), "mute")

        -- WHICH ROW AN ARROW BELONGS TO, stashed on the ELEMENT. One callback is
        -- cloned into every row (DR 5.64), so the handler has no other way to know
        -- what it was clicked on -- and it is stored as the BREED NAME, never the
        -- row index, because this list re-enumerates on a timer and an index
        -- captured at populate can point at another breed by the time it is used.
        for _, n in ipairs({ "brPrev", "brNext" }) do
            local e = cell:getAttribute(n)
            if e ~= nil then e.arBreed, e.arBarnUid, e.arToggle = r.name, r.barnUid, pig end
        end
        -- AUTO TRADER FOR THIS BREED (Pigs tab only; the Breeds template has no such
        -- cell, so this is a no-op there).
        local tr = cell:getAttribute("brTrader")
        if tr ~= nil then tr.arBreed, tr.arBarnUid = r.name, r.barnUid end
        showCells(cell, { "brTrader" }, HerdInspectorPage.autoTraderOn())
        return
    end
    if list == self.groupList or list == self.barnGroupList or list == self.pigGroupList then
        local src = (list == self.groupList) and self.groupRows or self.barnGroupRows
        local r = (src or {})[index]
        if r == nil then return end
        setIcon(cell, "fillIcon", r.icon)
        setc(cell, "giAnimal", r.animal)
        setc(cell, "giBarn",   r.barn)                       -- absent on the barn view template
        setc(cell, "giCount",  string.format("%d", r.count or 0))
        setc(cell, "giAge",    string.format(l10n("ar_hi_fmt_months", "%d mo"), r.age or 0))
        local hp = r.healthPct or 0
        setc(cell, "giHealth", string.format("%d%%", hp), hp >= 75 and "good" or "warn")
        setc(cell, "giRepro",  r.repro, r.reproTone)
        setc(cell, "giEach",   money(r.each))
        -- SIGNED AND COLOURED: green gaining, red losing. A bare figure here
        -- would need a minus sign hunted for to be read at all.
        local chg = scaled(r.change, self:monthScale())
        if chg == nil then
            setc(cell, "giChange", "-", "mute")
        else
            local sign = chg >= 0 and "+" or ""
            setc(cell, "giChange", sign .. money(chg),
                 chg > 0.5 and "good" or (chg < -0.5 and "bad" or "mute"))
        end
        setc(cell, "giTotal",  money(r.total))
        -- BUY / SELL IN THE ROW (Pigs tab only; the other templates have no such
        -- cells). Each button carries the group it belongs to.
        for _, n in ipairs({ "giBuy", "giSell" }) do
            local e = cell.getAttribute ~= nil and cell:getAttribute(n) or nil
            if e ~= nil then e.arCluster, e.arBarnUid = r.cluster, r.barnUid end
        end
        showCells(cell, { "giBuy", "giSell" }, HerdInspectorPage.tradingOn())
        HerdInspectorPage.placeAfter(cell, "giBuy", "giSell")
        return
    end

    if list == self.barnList then
        local b = (self.barns or {})[index]
        if b == nil then return end
        -- COUNT and FOOD % were dropped from this list: the panel beside it carries
        -- both for the selected barn, and they were the reason the name had 170px.
        setIcon(cell, "assetIcon", AnimalHerdData.barnIconFile(b.placeable))
        setc(cell, "blName", b.name)
        return
    end

    if list == self.inputList then
        local r = (self.inputRows or {})[index]
        if r == nil then return end
        setIcon(cell, "fillIcon", AnimalHerdData.fillIconFile(r.fillType))
        setc(cell, "inProduct", ftTitle(r.fillType))
        setc(cell, "inGroup",   r.group, "mute")
        -- HELD IS THE PRODUCT'S OWN, so a zero here on a group that is otherwise
        -- met means the tier is being covered by one of its OTHER products
        -- "auto" rather than a dash or a zero: a barn with no water tank is not
        -- short of water, it is billed for it directly (PlaceableHusbandryWater
        -- forces automaticWaterSupply on when WATER is not a supported fill type).
        if r.autoSupply then
            setc(cell, "inHeld", l10n("ar_hi_auto", "auto"), "mute")
        else
            setc(cell, "inHeld",  r.held ~= nil and vol(r.held) or "-",
                 (r.held == nil and "mute") or ((r.held or 0) <= 0 and "warn" or nil))
        end
        -- HELD IS A STOCK and does not scale; everything below it is a RATE and does
        local k = self:hourScale()
        local needs, cost, actual = scaled(r.needs, k), scaled(r.cost, k), scaled(r.actual, k)
        setc(cell, "inNeeds", needs ~= nil and vol(needs) or "-", needs == nil and "mute" or nil)

        -- USED -- what is actually being EATEN this hour, which is the column the
        -- author asked for: "so the player can actually see what's being used".
        --
        -- AND IT IS WHERE GRAZING BECOMES VISIBLE. feedCostPerHour returns `eaten`
        -- and `charged` separately, and `charged = eaten x trough / available` --
        -- so on a grazing pen `eaten` is the full ration while `charged` is only
        -- the bought share. The grazed remainder is FREE and always was (the cost
        -- column has never billed it), but nothing on any screen said so, which is
        -- what made a correct profit figure look wrong. Coloured GOOD when part of
        -- it is grazed, so a free ration reads as a good thing rather than as a
        -- number that fails to add up against the cost beside it.
        local used = scaled(r.used, k)
        local grazed = nil
        if used ~= nil and r.charged ~= nil then
            local ch = scaled(r.charged, k) or 0
            if used - ch > 0.01 then grazed = used - ch end
        end
        setc(cell, "inUsed", used ~= nil and vol(used) or "-",
             (used == nil and "mute") or (grazed ~= nil and "good") or nil)

        setc(cell, "inCost",  cost ~= nil and money(cost) or "-", cost == nil and "mute" or nil)
        -- A REAL ZERO, not a dash: this product is genuinely costing nothing
        -- right now, which is different from not knowing what it costs.
        setc(cell, "inActual", actual ~= nil and money(actual) or "-",
             (actual == nil and "mute") or ((actual or 0) > 0 and "good" or "mute"))
        return
    end

    -- THE PRODUCED TABLE reads like the outputs table below it, because it IS an
    -- output -- of the robot, or of the meadow. Its VALUE column is what the feed
    -- would have cost to buy and is deliberately absent from the barn's running
    -- cost: the ingredients that made the mix are already charged in INPUTS, and
    -- grazing was never bought at all.
    if list == self.madeList then
        local r = (self.madeRows or {})[index]
        if r == nil then return end
        setIcon(cell, "fillIcon", AnimalHerdData.fillIconFile(r.product))
        setc(cell, "mdProduct", ftTitle(r.product))
        setc(cell, "mdGroup",   r.group, "mute")
        local k = self:hourScale()
        setc(cell, "mdHeld", r.held ~= nil and vol(r.held) or "-", r.held == nil and "mute" or nil)
        local rate, val = scaled(r.rate, k), scaled(r.value, k)
        setc(cell, "mdRate", vol(rate or 0), (rate or 0) <= 0 and "mute" or nil)
        setc(cell, "mdValue", val ~= nil and money(val) or "-", val == nil and "mute" or nil)
        return
    end

    if list == self.prodList then
        local r = (self.prodRows or {})[index]
        if r == nil then return end
        setIcon(cell, "fillIcon", AnimalHerdData.fillIconFile(r.product))
        setc(cell, "pdProduct", ftTitle(r.product))
        -- HELD IS A STOCK and does not scale with the period; RATE and VALUE do.
        -- No " / h" suffix on either: the period selector states the unit once for
        -- the whole page, and a cell claiming "/ h" beside a legend reading YEAR is
        -- a contradiction on screen.
        local k = self:hourScale()
        setc(cell, "pdHeld", r.held ~= nil and vol(r.held) or "-", r.held == nil and "mute" or nil)
        local rate, val = scaled(r.rate, k), scaled(r.value, k)
        setc(cell, "pdRate", vol(rate or 0), (rate or 0) <= 0 and "mute" or nil)
        setc(cell, "pdValue", val ~= nil and money(val) or "-", val == nil and "mute" or nil)
        return
    end
end

---SELECTION for the barn list; DRILL-THROUGH for the groups list.
-- The two are different gestures and SmoothList reports them differently: a click
-- on an ALREADY-SELECTED row changes no selection and raises no selection event
-- at all (DR 6.29), so a drill-through built on selection would refuse to open
-- the row the player is looking at. onListClick is raised from notifyClick
-- regardless, which is why the jump lives there.
function HerdInspectorPage:onListSelectionChanged(list, section, index)
    -- remembered so the trade dialog can default to the group the player is looking
    -- at; the groups list is otherwise selection-agnostic
    if list == self.groupList then self.groupRowIndex = index; return end
    -- REMEMBERED, because the two rules buttons act on the SELECTED breed and the
    -- list is otherwise selection-agnostic.
    if list == self.breedList or list == self.pigBreedList then self.breedRowIndex = index; return end
    if list ~= self.barnList then return end
    self.selectedBarn = index
    local b = (self.barns or {})[index]
    self.selectedUid = b ~= nil and b.uid or nil
    self:rebuild()
    -- IMMEDIATELY, not at the next paced tick. The page is repopulated on DR's own
    -- refresh interval, so a pane left out of this list still comes right -- seconds
    -- later, which reads as the click having been ignored.
    for _, id in ipairs(HerdInspectorPage.DETAIL_LISTS) do
        if self[id] ~= nil then self[id]:reloadData() end
    end
    self:updateSummary()
end

function HerdInspectorPage:onListClick(list, section, index)
    if list ~= self.groupList then return end
    local r = (self.groupRows or {})[index]
    if r == nil then return end
    -- BY UID, never by the index captured at populate: this table re-enumerates
    -- on a timer and rows can reorder between the click and the handler.
    self.selectedUid = r.barnUid
    self.selectedBarn = r.barnIndex
    -- IT NO LONGER JUMPS TO THE BARN VIEW. With the two views as TABS they are
    -- peers, so a click here selects which barn the other tab will show and
    -- nothing more -- the player moves between them by tab, which is the whole
    -- point of the change (2026-09-01). The selection is still applied to the
    -- barn list so switching tab lands on the row they picked.
    if self.barnList ~= nil then
        pcall(self.barnList.setSelectedItem, self.barnList, 1, self.selectedBarn, true)
    end
end

---OPEN THE BUY / SELL WINDOW, scoped to where the player is standing.
--
-- THE CONTEXT IS THE WHOLE POINT of this being ours rather than a shortcut to the
-- base game's screen:
--   * BARN or BREEDS view -> that barn alone, and the dialog hides its barn
--                    selector, because there is then nothing to choose;
--   * GROUPS view -> every barn, defaulted to the SELECTED ROW's barn and to that
--                    row's group, so the thing the player was looking at is already
--                    the thing the dialog is about.
--
-- The group is passed as the CLUSTER OBJECT, not a name or an index: two groups of
-- the same animal at different ages are routine, and a name match would land on
-- whichever came first (the identity rule 5.37 and DR 6.29 both rest on).
---IS EXACTLY ONE BARN IN VIEW? Both windows below scope themselves on this, and
-- it is TWO views, not one: BREEDS shares the barn list with BARN, because a
-- purpose is per (barn, breed) and the barn has to be chosen before the question
-- means anything. So a player trading from the breeds tab is trading at the barn
-- whose breeds they are reading, and the dialog hides its barn selector exactly as
-- it does on the barn tab. GROUPS is the only view that spans the farm.
--
-- WRITTEN ONCE rather than in both windows: they already had the same test with
-- the same reasoning in two comments, and 39a had to widen it in both.
function HerdInspectorPage:onSingleBarn()
    local v = self:viewIndexSafe()
    -- BREEDS SPANS THE FARM since 2026-09-29, so it trades like GROUPS: every barn, with the
    -- selected row's barn defaulted.
    return HerdInspectorPage.isBarnLayout(v)
end

---The barn uid of the row the player has selected on a farm-wide view (GROUPS or BREEDS), and
-- the cluster when that row is a group. nil when nothing is selected.
function HerdInspectorPage:selectedRowBarn()
    if self:viewIndexSafe() == HerdInspectorPage.VIEW_BREEDS then
        local r = (self.breedRows or {})[self.breedRowIndex or 0]
        return r ~= nil and r.barnUid or nil, nil
    end
    local r = (self.groupRows or {})[self.groupRowIndex or 0]
    if r == nil then return nil, nil end
    return r.barnUid, r.cluster
end

function HerdInspectorPage:openTrade()
    -- DEFENCE IN DEPTH. The button is the only way here, so this should be
    -- unreachable with trading off -- but a footer that has not been rebuilt yet
    -- is exactly the state a stale button lives in, and opening a dialog for a
    -- feature the player switched off is worse than a button that does nothing.
    if AnimalSettings ~= nil and not AnimalSettings.tradingEnabled() then return end
    if AnimalTradeDialog == nil or AnimalTradeDialog.show == nil then return end
    local onBarn = self:onSingleBarn()
    local list, cluster = self.barns or {}, nil

    if onBarn then
        local b = (self.barns or {})[self.selectedBarn]
        if b == nil then return end
        list = { b }
    else
        local rowUid, rowCluster = self:selectedRowBarn()
        if rowUid ~= nil then
            for i, b in ipairs(self.barns or {}) do
                if b.uid == rowUid then
                    -- reorder so the row's barn is the DEFAULT without removing the
                    -- others: the player may still want to trade elsewhere
                    list = {}
                    list[1] = b
                    for j, other in ipairs(self.barns) do
                        if j ~= i then list[#list + 1] = other end
                    end
                    break
                end
            end
            cluster = rowCluster
        end
    end
    AnimalTradeDialog.show(list, onBarn, cluster, AnimalTrade.MODE_SELL)
end

---THE STANDING-ORDER WINDOW, context sensitive the same way openTrade is: from the
-- BARN or BREEDS view that barn alone with the selector hidden, from GROUPS every
-- barn with the selected row's barn defaulted.
--
-- IT SHARES openTrade's CONTEXT RULE (onSingleBarn, so BARN and BREEDS alike)
-- BUT NOT ITS ROW PREFERENCE. A sell row names a
-- CLUSTER the farm already owns, which means nothing to a buy schedule -- the thing
-- being chosen there is a DEALER row, and offering a preselection derived from the
-- herd would point at the wrong list entirely.
function HerdInspectorPage:openSchedule()
    if AnimalSettings ~= nil and not AnimalSettings.autoTraderEnabled() then return end
    if AnimalBuyScheduleDialog == nil or AnimalBuyScheduleDialog.show == nil then return end
    local onBarn = self:onSingleBarn()
    local list = self.barns or {}

    if onBarn then
        local b = list[self.selectedBarn]
        if b == nil then return end
        list = { b }
    else
        local rowUid = self:selectedRowBarn()
        if rowUid ~= nil then
            for i, b in ipairs(self.barns or {}) do
                if b.uid == rowUid then
                    list = { b }
                    for j, other in ipairs(self.barns) do
                        if j ~= i then list[#list + 1] = other end
                    end
                    break
                end
            end
        end
    end
    AnimalBuyScheduleDialog.show(list, onBarn)
end

-- ---------------------------------------------------------------------------
-- INSTALL
-- ---------------------------------------------------------------------------
---Build the page class on whichever base is available, and hand it to whichever menu will host it.
--
-- TWO HOSTS, ONE PAGE. With DR installed the page extends DR's DistributionMenuPage and is added to
-- DR's menu, exactly as it always has been. Without DR it extends AR's own AnimalMenuPage and is
-- added to AR's own menu. The page's own code is identical either way -- it only ever calls
-- onGuiSetupFinished and onFrameOpen on its super, and both bases provide them.
function HerdInspectorPage.install(menu)
    local SD  = HusbandryRedux ~= nil and HusbandryRedux.DR or nil
    local env = HusbandryRedux ~= nil and HusbandryRedux.DR_ENV or nil

    -- PREFER DR'S BASE WHEN DR IS THERE. Not for its own sake, but because DR's menu hosts the page
    -- and a frame whose class does not match the menu's expectations is the kind of mismatch DR 5.66
    -- records killing a whole menu on every frame. One host, one base.
    local base = (env ~= nil) and env.DistributionMenuPage or nil
    if base == nil then base = AnimalMenuPage end
    if base == nil then return false, "no page base class available" end

    local standalone = (SD == nil or env == nil or menu == nil)
    if not standalone and (SD.API == nil or SD.API.loadMenuPage == nil or SD.API.addMenuPage == nil) then
        return false, "DR's menu API is older than v3"
    end

    local mt = Class(HerdInspectorPage, base)
    HerdInspectorPage.new = function(target, custom_mt)
        local self = base.new(target, custom_mt or mt)
        -- a DISTINCT pageName: addMenuPage appends, and two pages answering to
        -- one name is how a paging element and a tab strip end up disagreeing
        self.pageName = "HERDINSPECTOR_PAGE"
        self.barns, self.selectedBarn = {}, 1
        -- NO VIEW YET: ensureViewValid picks one on the first open -- the first ANIMAL tab,
        -- which carries the panel and the tables the retired Barn Inspector did, so a player
        -- still arrives where they can act rather than survey (the original reason).
        self.viewIndex, self.filterIndex = nil, 1
        return self
    end

    -- AR'S OWN PROFILES MUST BE IN g_gui BEFORE THE PAGE XML IS PARSED.
    --
    -- A LAYOUT NAMING A PROFILE THAT IS NOT LOADED DOES NOT ERROR: it falls back to
    -- a default with no positioning and no transparency (DR 5.64), which is a white
    -- block sprawling across the row rather than a 40px arrow. Reported from a
    -- screenshot 2026-09-02, and the tell was that the LEFT arrow drew correctly --
    -- it uses a base game profile, which is always there, while the right one uses
    -- ARRowArrowRight, which was not yet.
    --
    -- It used to be loaded by AnimalBuyScheduleDialog.register, which runs BELOW
    -- this: a dialog was simply the first thing that happened to need them. The
    -- call is guarded on HusbandryRedux._profilesLoaded, so both sites are safe and
    -- whichever runs first wins.
    if AnimalBuyScheduleDialog ~= nil and AnimalBuyScheduleDialog.loadProfiles ~= nil then
        pcall(AnimalBuyScheduleDialog.loadProfiles)
    end

    local page = HerdInspectorPage.new()
    local pageXml = HusbandryRedux.MOD_DIR .. "gui/HerdInspectorPage.xml"
    if standalone then
        -- THE SAME THING DR's loadMenuPage DOES, done here because there is no DR to do it.
        -- g_gui:loadGui with a frame instance registers it under `guiName` -- and that name has to
        -- match the FrameReference in AnimalMenu.xml exactly, or the paging element resolves nothing
        -- and the tab comes up blank with no error at all.
        if g_gui == nil then return false, "no g_gui" end
        local okL = pcall(g_gui.loadGui, g_gui, pageXml, "animalHerdInspectorPage", page, true)
        if not okL then return false, "page XML failed to load (standalone)" end
    elseif not SD.API.loadMenuPage(page, "herdInspectorPage", pageXml) then
        return false, "page XML failed to load"
    end

    -- BACK IS A STEP, NOT AN EXIT, while the barn view is up. DR's own back
    -- button calls menu:onClickBack, which closes the whole menu -- correct from
    -- the top view and wrong from a view the player drilled INTO. The original
    -- callback is kept and delegated to, so leaving the tab still behaves
    -- exactly as every other DR tab does.
    -- BACK IS A PLAIN EXIT AGAIN. 18.8 made it a STEP (barn view -> groups view)
    -- because the barn view was something the player had drilled INTO. With the
    -- two views as TABS they are peers, there is nothing to step back out of, and
    -- a BACK that behaved differently from every other DR tab would now be the
    -- surprise rather than the courtesy.
    -- STANDALONE BUILDS ITS OWN. DR hands us its menu's back button so the footer matches the menu
    -- hosting us; with no DR we make the same thing from the base game's own translated key, which
    -- is what DR's does internally anyway.
    local back = SD ~= nil and SD.API ~= nil and not standalone
        and SD.API.menuBackButton(menu)
        or { inputAction = InputAction.MENU_BACK,
             text = (g_i18n ~= nil and g_i18n:getText("button_back")) or "Back",
             callback = function() if g_gui ~= nil then g_gui:changeScreen(nil) end end,
             showWhenPaused = true }
    -- BUY / SELL, on every view. The dialog is registered here rather than at load
    -- because g_gui must exist and DR's profiles must already be in it -- this page
    -- has both by construction, being installed into DR's own menu.
    --
    -- AnimalRulesDialog IS NO LONGER REGISTERED (39a) and its sourceFile is out of
    -- modDesc, so the window does not load at all rather than loading and being
    -- unreachable. Its files are kept in the tree: the rules ENGINE they configured
    -- may come back as auto-sell, and 39 kept the stored `cfg` for save
    -- compatibility for the same reason.
    if AnimalTradeDialog ~= nil and AnimalTradeDialog.register ~= nil then
        pcall(AnimalTradeDialog.register)
    end
    if AnimalBuyScheduleDialog ~= nil and AnimalBuyScheduleDialog.register ~= nil then
        pcall(AnimalBuyScheduleDialog.register)
    end
    local trade = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = l10n("ar_hi_btn_trade", "Buy / Sell"),
        callback = function()
            local pg = HerdInspectorPage.livePage()
            if pg ~= nil then pg:openTrade() end
        end,
        showWhenPaused = true,
    }
    -- MENU_EXTRA_2 IS THE LAST SPARE FOOTER ACTION (DR 5.64: EXTRA_1 and EXTRA_2 are
    -- the only extras, and ACCEPT / ACTIVATE / BACK / CANCEL / PAGE_PREV / PAGE_NEXT
    -- are all taken). Anything after this needs a custom modDesc action.
    local schedule = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = l10n("ar_hi_btn_schedule", "Auto Trader"),
        callback = function()
            local pg = HerdInspectorPage.livePage()
            if pg ~= nil then pg:openSchedule() end
        end,
        showWhenPaused = true,
    }
    -- THREE DEFINITIONS, not a fixed set. Which of them show is decided in
    -- buildButtonSet, per call, because AnimalSettings can switch the trading pair
    -- off while this page is open -- and a set frozen at install could never learn
    -- that. The two RULES buttons that used to stand here for the BREEDS view are
    -- gone (39a); every view now carries this same pair.
    HerdInspectorPage._buttons = {
        back      = back,
        trade     = trade,
        schedule  = schedule,
    }
    HerdInspectorPage._menu = menu
    local buttons = buildButtonSet()
    -- TWO ICONS, BECAUSE THE TAB IS TWO VIEWS. The animals slice is the page's
    -- subject and carries the tab; the buildings slice -- DR's own Silos tab icon
    -- -- rides in the corner for the BARN view. It used to wear the STATISTICS
    -- icon, which was never a description of this page: it was chosen only so the
    -- second tab did not clash with the animals tab beside it, and that tab has
    -- been retired (20.28), so the icon that actually means "animals" is free.
    --
    -- badgeSliceId is OPTIONAL and needs DR API v7. An older DR ignores the extra
    -- argument entirely, so the tab simply carries the animals icon alone rather
    -- than failing to install -- which is why this is not gated on the version.
    -- STANDALONE: the page is declared in AnimalMenu.xml and the menu registers it itself, so there
    -- is nothing to ADD -- only the footer buttons to hand over. DR's addMenuPage exists because it
    -- has to splice a page into a menu that was already built; AR's menu is built around this page.
    -- NO BADGE either: the badge's whole purpose was to mark OUR tab inside DR's menu (DR 5.86).
    local ok = true
    if standalone then
        if page.setMenuButtonInfo ~= nil then page:setMenuButtonInfo(buttons) end
    else
        -- OUR OWN PICTURE (DR API v10), with the stock slice and badge still passed behind it.
        -- Both are handed over UNCONDITIONALLY and there is no version test: a DR that predates
        -- icon files ignores the 9th argument and shows the animals slice with the buildings
        -- badge exactly as before, while one that supports it draws the picture and suppresses
        -- the badge itself. The badge only ever existed because no single stock slice says
        -- "animals AND buildings"; the drawn icon says both on its own.
        --
        -- ABSOLUTE PATH, because GuiOverlay.resolveFilename does no mod-relative resolution
        -- (DR 5.80) -- MOD_DIR is where the mod actually is, zipped or not.
        ok = SD.API.addMenuPage(menu, page, nil, "gui.icon_ingameMenu_animals",
                                l10n("ar_hi_tab_title", "Herd Inspector"),
                                function() return true end,
                                buttons,
                                "gui.icon_construction_buildings",
                                (HusbandryRedux.MOD_DIR or "") .. "gui/icon_herdInspector.dds")
    end
    if not ok then return false, "addMenuPage refused" end

    HerdInspectorPage._page = page
    HerdInspectorPage._pages = { page }
    if not standalone then
        local okO, why = HerdInspectorPage.installOverviewPage(menu, SD, pageXml, buttons)
        if okO then
            page.hostMode = HerdInspectorPage.MODE_TYPES
        elseif HusbandryRedux ~= nil and HusbandryRedux.log ~= nil then
            HusbandryRedux.log("Animals / Breeds stay on the Herd Inspector: %s", tostring(why))
        end
    end
    return true
end

---THE OVERVIEW'S HUSBANDRY REDUX TAB, as a real page (DR API v15).
--
-- A SECOND INSTANCE OF THIS CLASS, from the same XML, in MODE_OVERVIEW. Not a new class: the
-- Animals and Breeds views are 2,600 lines of this one, and a copy is the 6.18 trap. The two
-- instances share nothing but the class -- each has its own element tree, lists and view.
--
-- REGISTERED WITH THE OVERVIEW BEFORE addMenuPage, so the page is never a left row of its own:
-- DR drops a page an Overview tab points at from the left list and shows it as the Overview's.
-- The registration REPLACES the placeholder tab HusbandryRedux registered at mission load (a
-- re-registration by the same mod replaces), so the tab keeps its slot.
--
-- ANY FAILURE UNDOES ITSELF and the Herd Inspector keeps every view, which is the layout before
-- this: an older DR, a refused page, or a load error all end with nothing lost.
function HerdInspectorPage.installOverviewPage(menu, SD, pageXml, buttons)
    if SD == nil or SD.API == nil or SD.API.selectOverviewTab == nil or SD.API.overviewTabs == nil
       or SD.API.registerOverviewTab == nil then
        return false, "DR's API is older than v15"
    end
    local page = HerdInspectorPage.new()
    page.pageName = "HERDINSPECTOR_OVERVIEW_PAGE"
    page.hostMode = HerdInspectorPage.MODE_OVERVIEW
    page.viewIndex = HerdInspectorPage.VIEW_BREEDS
    if not SD.API.loadMenuPage(page, "herdInspectorOverviewPage", pageXml) then
        return false, "overview page XML failed to load"
    end
    local label = l10n("ar_overview_tab", "HUSBANDRY REDUX")
    local okR, res = pcall(SD.API.registerOverviewTab, HusbandryRedux.MOD_NAME, label, { page = page })
    if not (okR and res) then return false, "registerOverviewTab refused the page" end
    local okA, added = pcall(SD.API.addMenuPage, menu, page, nil, "gui.icon_ingameMenu_statistics",
                             l10n("ar_hi_page_title_overview", "Overview"),
                             function() return true end, buttons)
    if not (okA and added) then
        -- PUT THE PLACEHOLDER BACK rather than leave a tab pointing at a page the menu refused.
        pcall(SD.API.registerOverviewTab, HusbandryRedux.MOD_NAME, label,
              { placeholder = l10n("ar_overview_placeholder", "Under Construction") })
        return false, "addMenuPage refused the overview page"
    end
    HerdInspectorPage._pages[#HerdInspectorPage._pages + 1] = page
    HerdInspectorPage._overviewPage = page
    return true
end
