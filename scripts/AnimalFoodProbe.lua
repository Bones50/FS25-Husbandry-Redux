-- ============================================================================
-- AnimalFoodProbe.lua  (Husbandry Redux)  -- TEMPORARY DEV PROBE
--
-- Measures what the base game's AnimalFoodSystem:consumeFood actually rewards,
-- because it cannot be READ: AnimalFoodSystem is NOT in the shipped SDK source
-- (the only references anywhere are PlaceableHusbandryFood and MixerWagon), so
-- the mix -> production-factor curve is unreadable and has to be measured.
--
-- WHY IT MATTERS. PlaceableHusbandryFood:updateFeeding does:
--
--     factor = factor * animalFoodSystem:consumeFood(animalTypeIndex,
--                  litersPerHour * timeAdjustment, self, consumedFood)
--     for fillTypeIndex, delta in pairs(consumedFood) do
--         self:removeFood(delta, fillTypeIndex)
--     end
--
-- so production is SCALED by how well the trough matches the food groups, and
-- the base game renders each group's productionWeight as a PERCENTAGE of the mix
-- ("%s (%d%%)"). Distribution Redux instead treats productionWeight as a QUALITY
-- RANK and fills best-first. If the factor rewards a MIX, DR is suppressing
-- animal output on every multi-group feeder.
--
-- WHY SWEEPING IS SAFE. consumeFood does NOT remove food -- it fills the
-- `consumedFood` table and returns the factor, and the CALLER applies the
-- removal. So calling it never feeds anything and never consumes stock. The only
-- state touched is the barn's own fillLevels table, snapshotted and restored on
-- EVERY path including a throw (the sdStressBig rule).
--
-- A REAL barn is used rather than a duck-typed mock (the sdStress approach)
-- because consumeFood's body is unreadable: we cannot know which fields or
-- methods it touches, so a mock could silently answer a different question.
-- Borrowing a real barn guarantees the environment is exactly what the game uses.
--
-- Usage (needs game.xml <development><controls>true):
--     arFoodProbe                  -- first husbandry with a food spec
--     arFoodProbe <name fragment>  -- first barn whose name contains this
--     arFoodProbe <frag> <liters>  -- override the demand used per sample
--
-- REMOVE once the feed model is settled.
-- ============================================================================

AnimalFoodProbe = {}

local TOTAL_FOOD = 10000    -- litres placed in the trough per sample, capped to capacity
local DEMAND     = 100      -- litres asked for. Kept well under TOTAL so AVAILABILITY is
                            -- never the limiter and the only thing varying is the MIX.

-- ---------------------------------------------------------------------------
local function ftName(ft)
    if ft == nil then return "nil" end
    local m = g_fillTypeManager
    if m ~= nil and m.getFillTypeNameByIndex ~= nil then
        local ok, n = pcall(m.getFillTypeNameByIndex, m, ft)
        if ok and n ~= nil then return tostring(n) end
    end
    return "ft" .. tostring(ft)
end

local function pad(s, n)
    s = tostring(s)
    while #s < n do s = s .. " " end
    return s
end

local function out(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[arFoodProbe] " .. (ok and msg or tostring(fmt)))
end

-- ---------------------------------------------------------------------------
-- Every husbandry with a food spec, optionally filtered by a name fragment.
function AnimalFoodProbe.findBarns(fragment)
    local found = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return found end
    for _, p in ipairs(ps.placeables) do
        if p.spec_husbandryFood ~= nil then
            local name = "?"
            local okN, n = pcall(function() return p:getName() end)
            if okN and n ~= nil then name = tostring(n) end
            if fragment == nil or fragment == ""
               or string.find(string.lower(name), string.lower(fragment), 1, true) ~= nil then
                found[#found + 1] = { placeable = p, name = name }
            end
        end
    end
    return found
end

function AnimalFoodProbe.animalTypeIndexOf(p)
    local spec = p.spec_husbandryFood
    local ati = spec ~= nil and spec.animalTypeIndex or nil
    if ati == nil and p.getAnimalTypeIndex ~= nil then
        local ok, a = pcall(p.getAnimalTypeIndex, p)
        if ok then ati = a end
    end
    return ati
end

-- ---------------------------------------------------------------------------
-- The DECLARED target: each group's weight, plus a representative fill type to
-- stand for that group in a synthetic mix.
function AnimalFoodProbe.describeGroups(ati, supported)
    local afs = g_currentMission ~= nil and g_currentMission.animalFoodSystem or nil
    if afs == nil or afs.getAnimalFood == nil then return nil, "no animalFoodSystem" end
    local okF, food = pcall(afs.getAnimalFood, afs, ati)
    if not okF or food == nil or food.groups == nil then return nil, "getAnimalFood returned nothing" end

    local groups = {}
    for _, grp in pairs(food.groups) do
        local fts, rep = {}, nil
        for _, ft in pairs(grp.fillTypes or {}) do
            fts[#fts + 1] = ft
            if rep == nil and (supported == nil or supported[ft] ~= nil) then rep = ft end
        end
        groups[#groups + 1] = {
            title  = tostring(grp.title or "?"),
            weight = grp.productionWeight or 0,
            fts    = fts,
            rep    = rep,
        }
    end
    table.sort(groups, function(a, b) return a.weight > b.weight end)
    return groups
end

function AnimalFoodProbe.mixturesFor(ati)
    local afs = g_currentMission ~= nil and g_currentMission.animalFoodSystem or nil
    if afs == nil or afs.getMixturesByAnimalTypeIndex == nil then return {} end
    local ok, mix = pcall(afs.getMixturesByAnimalTypeIndex, afs, ati)
    if not ok or mix == nil then return {} end
    return mix
end

-- ---------------------------------------------------------------------------
---Measure the factor for one synthetic trough mix. `mix` is ft -> litres.
-- Returns factor, consumedTable, errText
function AnimalFoodProbe.sample(p, ati, mix, demand)
    local spec = p.spec_husbandryFood
    if spec == nil or spec.fillLevels == nil then return nil, nil, "no fillLevels" end
    local afs = g_currentMission ~= nil and g_currentMission.animalFoodSystem or nil
    if afs == nil or afs.consumeFood == nil then return nil, nil, "no consumeFood" end

    -- snapshot the real trough
    local snap = {}
    for ft, lvl in pairs(spec.fillLevels) do snap[ft] = lvl end

    -- apply the synthetic mix
    for ft in pairs(spec.fillLevels) do spec.fillLevels[ft] = 0 end
    for ft, litres in pairs(mix) do spec.fillLevels[ft] = litres end

    local consumed = {}
    local okC, factorOrErr = pcall(afs.consumeFood, afs, ati, demand, p, consumed)

    -- restore on EVERY path, including a throw
    for ft in pairs(spec.fillLevels) do spec.fillLevels[ft] = nil end
    for ft, lvl in pairs(snap) do spec.fillLevels[ft] = lvl end

    if not okC then return nil, nil, tostring(factorOrErr) end
    return factorOrErr, consumed, nil
end

local function consumedText(consumed)
    if consumed == nil then return "" end
    local parts = {}
    for ft, d in pairs(consumed) do
        if d ~= nil and d > 0.0001 then
            parts[#parts + 1] = string.format("%s %.1f", ftName(ft), d)
        end
    end
    if #parts == 0 then return "(nothing)" end
    table.sort(parts)
    return table.concat(parts, ", ")
end

-- ---------------------------------------------------------------------------
---Probe ONE barn.
function AnimalFoodProbe.probeBarn(barn, demand)
    local p    = barn.placeable
    local spec = p.spec_husbandryFood

    out("=====================================================================")
    out("barn: %s", barn.name)

    local ati = AnimalFoodProbe.animalTypeIndexOf(p)
    if ati == nil then
        out("could not resolve animalTypeIndex -- cannot probe this barn.")
        return
    end

    local capacity = spec.capacity or 0
    local total    = TOTAL_FOOD
    if capacity > 0 and capacity < total then total = capacity end

    out("animalTypeIndex=%s  capacity=%s  litersPerHour=%.2f  demand=%.1f  trough total=%.0f",
        tostring(ati), tostring(capacity), spec.litersPerHour or 0, demand, total)

    local supported, nSupported = spec.supportedFillTypes or {}, 0
    for _ in pairs(supported) do nSupported = nSupported + 1 end
    out("supported food types: %d", nSupported)

    -- ---- the DECLARED target --------------------------------------------
    local groups, why = AnimalFoodProbe.describeGroups(ati, supported)
    if groups == nil then
        out("could not read food groups: %s", tostring(why))
        return
    end

    out("---------------------------------------------------------------------")
    out("DECLARED FOOD GROUPS (the base game renders productionWeight as a %% of the mix)")
    local wsum = 0
    for _, g in ipairs(groups) do
        wsum = wsum + g.weight
        local names = {}
        for _, ft in ipairs(g.fts) do names[#names + 1] = ftName(ft) end
        out("  %s weight=%.3f (%3d%%)  rep=%s  fillTypes: %s",
            pad(g.title, 18), g.weight, math.floor(g.weight * 100 + 0.5),
            ftName(g.rep), table.concat(names, " "))
    end
    if math.abs(wsum - 1.0) < 0.02 then
        out("  weights sum to %.3f  <- a RATIO: the target is a MIX, not a single best food", wsum)
    else
        out("  weights sum to %.3f  <- does NOT sum to 1; interpret with care", wsum)
    end

    -- A single group cannot be mis-mixed: there is nothing to trade off, so
    -- best-first and the declared ratio are the SAME instruction. Say so, or a
    -- 1.0000 / 1.0000 result reads as evidence when it is just a degenerate case.
    if #groups < 2 then
        out("  ONLY ONE GROUP -- this animal type is trivially unaffected by fill order.")
        out("  The mix question can only be answered by a MULTI-GROUP animal (cow / pig / sheep / horse).")
    end

    local mixes = AnimalFoodProbe.mixturesFor(ati)
    if #mixes > 0 then
        local names = {}
        for _, ft in ipairs(mixes) do names[#names + 1] = ftName(ft) end
        out("  mixtures (complete rations): %s", table.concat(names, " "))
    else
        out("  mixtures (complete rations): none for this animal type")
    end

    -- ---- what Distribution Redux would do today --------------------------
    local SD = HusbandryRedux ~= nil and HusbandryRedux.DR or nil
    if SD ~= nil and SD._foodQualityMap ~= nil then
        local okQ, qmap = pcall(SD._foodQualityMap, p)
        if okQ and qmap ~= nil then
            local best, bestQ = nil, -1
            for ft, q in pairs(qmap) do
                if supported[ft] ~= nil and q > bestQ then best, bestQ = ft, q end
            end
            if best ~= nil then
                out("  Distribution Redux fills BEST-FIRST, i.e. all of: %s (weight %.3f)",
                    ftName(best), bestQ)
            end
        end
    end

    -- ---- build the sweep --------------------------------------------------
    local samples = {}
    local function addSample(label, mix) samples[#samples + 1] = { label = label, mix = mix } end

    addSample("EMPTY trough", {})

    for _, g in ipairs(groups) do
        if g.rep ~= nil then
            addSample(string.format("100%% %s", ftName(g.rep)), { [g.rep] = total })
        end
    end

    local declared, declaredOk = {}, true
    for _, g in ipairs(groups) do
        if g.rep == nil then
            declaredOk = false
        elseif g.weight > 0 then
            declared[g.rep] = (declared[g.rep] or 0) + total * g.weight
        end
    end
    if declaredOk and next(declared) ~= nil then
        addSample("DECLARED RATIO", declared)
    end

    -- blends between "all in the top group" (what DR does) and the declared ratio
    local top = groups[1]
    if declaredOk and top ~= nil and top.rep ~= nil and #groups > 1 then
        local steps = { 0.25, 0.50, 0.75 }
        for _, f in ipairs(steps) do
            local mix = {}
            for ft, litres in pairs(declared) do mix[ft] = litres * f end
            mix[top.rep] = (mix[top.rep] or 0) + total * (1 - f)
            addSample(string.format("%d%% toward declared", math.floor(f * 100 + 0.5)), mix)
        end
    end

    -- WITHIN one group: are its fill types interchangeable? The Grain group is
    -- WHEAT BARLEY SORGHUM, and if all three score the same then DR's per-fill-type
    -- preference is meaningless inside a group and only the GROUP SPLIT matters --
    -- which decides how granular the replacement model actually needs to be.
    if top ~= nil then
        local alt = nil
        for _, ft in ipairs(top.fts) do
            if ft ~= top.rep and supported[ft] ~= nil then alt = ft; break end
        end
        if alt ~= nil then
            addSample(string.format("100%% %s (same group)", ftName(alt)), { [alt] = total })
        end
    end

    for _, ft in ipairs(mixes) do
        if supported[ft] ~= nil then
            addSample(string.format("100%% %s (mixture)", ftName(ft)), { [ft] = total })
        end
    end

    -- ---- measure ----------------------------------------------------------
    out("---------------------------------------------------------------------")
    out("MEASURED FACTOR (trough total fixed at %.0f L, demand %.1f L, so only the MIX varies)",
        total, demand)
    out("  %s %s %s", pad("mix", 26), pad("factor", 10), "consumeFood took")
    for _, s in ipairs(samples) do
        local factor, consumed, err = AnimalFoodProbe.sample(p, ati, s.mix, demand)
        if err ~= nil then
            out("  %s %s ERROR: %s", pad(s.label, 26), pad("-", 10), err)
        else
            out("  %s %s %s", pad(s.label, 26),
                pad(string.format("%.4f", factor or -1), 10), consumedText(consumed))
        end
    end

    out("---------------------------------------------------------------------")
    if #groups >= 2 then
        out("HOW TO READ IT: if DECLARED RATIO scores HIGHER than '100%% <top group>',")
        out("filling best-first is wrong and Distribution Redux is losing production.")
    else
        out("Single group: nothing to conclude from this barn (see the note above).")
    end
    out("=====================================================================")
end

---With no name fragment, probe ONE barn per ANIMAL TYPE.
-- Probing "the first barn" was the first version and it was a poor default: it
-- landed on a chicken pasture, which has a single food group and therefore cannot
-- show the effect at all. One barn per animal type covers every distinct food
-- model on the farm in a single run, which is what the question actually needs.
function AnimalFoodProbe.run(fragment, demandArg)
    local demand = tonumber(demandArg) or DEMAND

    local barns = AnimalFoodProbe.findBarns(fragment)
    if #barns == 0 then
        out("no husbandry with a food spec found%s.",
            (fragment ~= nil and fragment ~= "") and (" matching '" .. tostring(fragment) .. "'") or "")
        return
    end

    if fragment ~= nil and fragment ~= "" then
        out("'%s' matched %d barn(s); probing the first.", tostring(fragment), #barns)
        AnimalFoodProbe.probeBarn(barns[1], demand)
        return
    end

    -- one representative barn per animal type
    local seen, chosen = {}, {}
    for _, b in ipairs(barns) do
        local ati = AnimalFoodProbe.animalTypeIndexOf(b.placeable)
        local key = ati ~= nil and ati or ("?" .. b.name)
        if seen[key] == nil then
            seen[key] = true
            chosen[#chosen + 1] = b
        end
    end

    out("%d barn(s) on the farm, %d distinct animal type(s). Probing one of each.",
        #barns, #chosen)
    for _, b in ipairs(chosen) do
        AnimalFoodProbe.probeBarn(b, demand)
    end
    out("all animal types probed. The MULTI-GROUP ones are the ones that answer the question.")
end

-- ============================================================================
-- arFeedPartial -- is the production factor PRESENCE-based or QUANTITY-based?
--
-- THE QUESTION. Everything measured so far had each food group either absent or
-- stocked well past its share, and the factor came out as the sum of the weights
-- of the groups PRESENT. What happens in between -- 100 L of soybean when the
-- pigs want 6,800 -- was never tested, and the two answers lead to very
-- different advice:
--
--   PRESENCE-BASED  a trickle of each group is enough, and the practical rule is
--                   just "get something from every group into every barn".
--   QUANTITY-BASED  each group must supply its full share every hour, and DR's
--                   sourcing has to keep pace or the factor sags.
--
-- HOW IT MEASURES. Every group is stocked far past its need, then ONE group is
-- swept from empty up to twice its hourly requirement while the others are held
-- constant -- so any movement in the factor is attributable to that group alone.
--
-- The sweep is in multiples of the group's HOURLY NEED (demand x its eat share),
-- not of the trough, because "enough" can only mean "enough for what will be
-- eaten this hour". Demand is the barn's real litersPerHour where it has one.
--
-- Single-group animals (sheep, chicken) are skipped: with one group the answer is
-- the trivial "food or no food".
--
-- Usage: arFeedPartial [name fragment]
-- ============================================================================

-- Multiples of the group's hourly need. 0 and the 1 L token are the two that
-- decide the question; the rest map whatever shape lies between them.
local PARTIAL_MULT  = { 0, -1, 0.25, 0.5, 1.0, 2.0 }    -- -1 means "literally 1 L"
local PARTIAL_LABEL = { "0 L", "1 L", "25%", "50%", "100%", "200%" }

local function sweepBarn(p, ati, name)
    local spec = p.spec_husbandryFood
    local model = AnimalFeedModel.read(ati, spec.supportedFillTypes)
    if model == nil or #model.groups < 2 then return false end

    out("=================================================================")
    out("%s   (%s, %d groups)", name, model.consumptionType, #model.groups)

    local demand = AnimalFeedModel.demandPerHour(p)
    if demand <= 0 then demand = 100 end

    local eatSum = 0
    for _, g in ipairs(model.groups) do
        if g.rep ~= nil then eatSum = eatSum + g.eat end
    end
    if eatSum <= 0 then
        out("  no usable groups in this building")
        return true
    end

    -- baseline: every group stocked far past anything it could eat this hour
    local BIG = math.max(demand * 50, 10000)
    local base = {}
    for _, g in ipairs(model.groups) do
        if g.rep ~= nil then base[g.rep] = BIG * g.eat / eatSum end
    end
    local fullF = select(1, AnimalFeedModel.measureFactor(p, ati, base, demand))
    out("  demand %.2f L/h; all groups stocked far past need -> factor %s",
        demand, fullF ~= nil and string.format("%.4f", fullF) or "?")

    local row = string.format("  %-20s", "group / stock")
    for _, lbl in ipairs(PARTIAL_LABEL) do row = row .. string.format(" %8s", lbl) end
    out("%s", row)

    for _, g in ipairs(model.groups) do
        if g.rep ~= nil then
            -- SERIAL tiers are ALTERNATIVES: one tier feeds the whole herd, so its
            -- need is the full demand. The first run split it by eat share and
            -- labelled 182.3 L "100%" for a cow that really needs 729 -- the sweep
            -- data was still valid (it swept absolute litres) but the columns lied.
            local need
            if model.consumptionType == "SERIAL" then
                need = demand
            else
                need = demand * g.eat / eatSum
            end
            local line = string.format("  %-20s", g.title)
            for i = 1, #PARTIAL_LABEL do
                local mult = PARTIAL_MULT[i]
                local litres = (mult < 0) and 1 or (need * mult)
                local mix = {}
                for ft, v in pairs(base) do mix[ft] = v end
                mix[g.rep] = litres
                local f = select(1, AnimalFeedModel.measureFactor(p, ati, mix, demand))
                line = line .. string.format(" %8s",
                    f ~= nil and string.format("%.4f", f) or "?")
            end
            out("%s   (needs %.1f L/h of %s)", line, need, ftName(g.rep))
        end
    end

    out("  READ IT: if the 1 L column already matches the 200%% column, the factor is")
    out("  PRESENCE-based and a trickle of each group is enough. If it climbs across")
    out("  the row, it is QUANTITY-based and every group must be kept to its share.")
    return true
end

function AnimalFoodProbe.runPartial(fragment)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then out("no placeableSystem"); return end
    if AnimalFeedModel == nil then out("AnimalFeedModel is not loaded"); return end

    local seen, reported = {}, 0
    for _, p in ipairs(ps.placeables) do
        if p.spec_husbandryFood ~= nil then
            local name = "?"
            local okN, nm = pcall(function() return p:getName() end)
            if okN and nm ~= nil then name = tostring(nm) end
            local matches = fragment == nil or fragment == ""
                or string.find(string.lower(name), string.lower(fragment), 1, true) ~= nil
            local ati = AnimalFeedModel.animalTypeIndexOf(p)
            if matches and ati ~= nil and seen[ati] == nil then
                seen[ati] = true
                if sweepBarn(p, ati, name) then reported = reported + 1 end
            end
        end
    end

    out("=================================================================")
    if reported == 0 then
        out("no multi-group animal type found%s; a single-group animal cannot answer this.",
            (fragment ~= nil and fragment ~= "") and (" matching '" .. tostring(fragment) .. "'") or "")
    else
        out("%d multi-group animal type(s) swept.", reported)
    end
end

function AnimalFoodProbe:consoleCommandPartial(fragment)
    local ok, err = pcall(AnimalFoodProbe.runPartial, fragment)
    if not ok then return "arFeedPartial failed: " .. tostring(err) end
    return "arFeedPartial done -- see log.txt"
end

-- ============================================================================
-- arMenuProbe -- how DR's menu actually places its pages.
--
-- PagingElement is ~64% stripped in the shipped source: addPage and
-- getPageIdByElement are both missing, so the contract for adding a page at
-- runtime has to be inferred from two readable call sites. Inferring it wrongly
-- is what broke DR's menu once and mislaid the Animals tab twice.
--
-- So: stop reasoning, dump what the game demonstrably does. For every page the
-- menu holds this prints the geometry the framework gave it, whether the paging
-- element can resolve it, and how ours compares. A page that renders in the wrong
-- place differs from a working one in exactly one of these numbers.
--
-- Usage: arMenuProbe
-- ============================================================================
local function xy(t)
    if type(t) ~= "table" then return "?" end
    return string.format("%.4f, %.4f", t[1] or -1, t[2] or -1)
end

function AnimalFoodProbe.runMenuProbe()
    local SD = HusbandryRedux ~= nil and HusbandryRedux.DR or nil
    local menu = SD ~= nil and SD._menu or nil
    if menu == nil then out("DR's menu is not registered"); return end
    local pe = menu.pagingElement
    out("=================================================================")
    out("pagingElement: %s", tostring(pe))
    if pe ~= nil then
        out("  position %s   size %s", xy(pe.position), xy(pe.size))
        out("  absPosition %s   absSize %s", xy(pe.absPosition), xy(pe.absSize))
        out("  #pages=%s  currentPageIndex=%s",
            tostring(pe.pages ~= nil and #pe.pages or "?"), tostring(pe.currentPageIndex))
        out("  methods: addPage=%s getPageIdByElement=%s addElement=%s",
            type(pe.addPage), type(pe.getPageIdByElement), type(pe.addElement))
    end

    out("--- pageFrames (what TabbedMenu registered) ---")
    for i, f in ipairs(menu.pageFrames or {}) do
        local id = nil
        if pe ~= nil and pe.getPageIdByElement ~= nil then
            local okI, v = pcall(pe.getPageIdByElement, pe, f); id = okI and v or "ERR"
        end
        local root = f.elements ~= nil and f.elements[1] or nil
        out("  [%d] %s", i, tostring(f.name or f.pageName or f))
        out("        pos %s  size %s", xy(f.position), xy(f.size))
        out("        abs %s  absSize %s", xy(f.absPosition), xy(f.absSize))
        local resolves = "n/a"
        if pe ~= nil and id ~= nil and id ~= "ERR" and pe.getPageById ~= nil then
            local okR, entry = pcall(pe.getPageById, pe, id)
            resolves = tostring(okR and entry ~= nil)
        end
        out("        pagingId=%s  resolves=%s  visible=%s",
            tostring(id), resolves, tostring(f.visible))
        if root ~= nil then
            out("        root: pos %s  size %s  abs %s", xy(root.position), xy(root.size),
                xy(root.absPosition))
        end
    end

    out("--- pagingElement.pages (what the paging element knows) ---")
    for i, pg in ipairs((pe ~= nil and pe.pages) or {}) do
        out("  [%d] id=%s  title=%s  disabled=%s  element=%s",
            i, tostring(pg.id), tostring(pg.title), tostring(pg.disabled), tostring(pg.element))
    end
    out("=================================================================")
end

function AnimalFoodProbe:consoleCommandMenu()
    local ok, err = pcall(AnimalFoodProbe.runMenuProbe)
    if not ok then return "arMenuProbe failed: " .. tostring(err) end
    return "arMenuProbe done -- see log.txt"
end

-- ============================================================================
-- arAvailFood -- what does getAvailableFood() actually return?
--
-- THE QUESTION. A husbandry's food is read here from
-- spec_husbandryFood.fillLevels, which is the TROUGH. But
-- PlaceableHusbandryMeadow overrides getAvailableFood / removeFood /
-- getFoodInfos, so a grazing barn has food that never appears there: a cow barn
-- was seen reading every group at 0 L while the engine scored it 0.40, the Grass
-- tier, from the pasture.
--
-- getAvailableFood is therefore the AUTHORITATIVE source and fillLevels is a
-- subset of it. Switching to it would fix the grazing blind spot and might stop
-- DR hauling grass to a barn already eating enough of it.
--
-- WHY THIS IS A SHAPE PROBE AND NOT A FIX. Both implementations are STRIPPED from
-- the shipped SDK source -- registered in PlaceableHusbandryFood, overridden in
-- PlaceableHusbandryMeadow, readable in neither -- so the return shape is
-- unknown. Guessing at stripped internals is what cost three rounds on the menu
-- tab (CLAUDE.md 2.4), so this reports what comes back rather than assuming a
-- ft -> litres map.
--
-- It tries the no-argument form and a per-fill-type form, prints the type and
-- structure of whatever returns, and DIFFS it against fillLevels -- because the
-- difference IS the grazing contribution, which is the number we actually want.
--
-- Usage: arAvailFood [name fragment]
-- ============================================================================
local function describe(v, depth)
    depth = depth or 0
    local t = type(v)
    if t ~= "table" then return t .. "(" .. tostring(v) .. ")" end
    if depth > 1 then return "table{...}" end
    local n, sample = 0, {}
    for k, val in pairs(v) do
        n = n + 1
        if n <= 4 then
            sample[#sample + 1] = string.format("[%s(%s)]=%s",
                tostring(k), type(k), describe(val, depth + 1))
        end
    end
    return string.format("table{%d entr%s: %s}", n, n == 1 and "y" or "ies",
        table.concat(sample, ", "))
end

function AnimalFoodProbe.runAvailFood(fragment)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then out("no placeableSystem"); return end

    local seen, n = {}, 0
    for _, p in ipairs(ps.placeables) do
        local spec = p.spec_husbandryFood
        if spec ~= nil then
            local name = "?"
            local okN, nm = pcall(function() return p:getName() end)
            if okN and nm ~= nil then name = tostring(nm) end
            local matches = fragment == nil or fragment == ""
                or string.find(string.lower(name), string.lower(fragment), 1, true) ~= nil
            local ati = AnimalFeedModel ~= nil and AnimalFeedModel.animalTypeIndexOf(p) or nil
            local key = ati or name

            if matches and seen[key] == nil then
                seen[key] = true
                n = n + 1
                out("=================================================================")
                out("%s   grazes=%s   getAvailableFood=%s",
                    name, tostring(p.spec_husbandryMeadow ~= nil), type(p.getAvailableFood))

                -- what the TROUGH says
                local troughTotal, troughParts = 0, {}
                for ft, lvl in pairs(spec.fillLevels or {}) do
                    if (lvl or 0) > 0 then
                        troughTotal = troughTotal + lvl
                        troughParts[#troughParts + 1] = string.format("%s %.1f", ftName(ft), lvl)
                    end
                end
                table.sort(troughParts)
                out("  fillLevels      total %.1f L : %s", troughTotal,
                    #troughParts > 0 and table.concat(troughParts, ", ") or "(empty)")

                if p.getAvailableFood ~= nil then
                    -- no-argument form
                    local ok, a, b = pcall(p.getAvailableFood, p)
                    if ok then
                        out("  getAvailableFood()      -> %s", describe(a))
                        if b ~= nil then out("      second return         -> %s", describe(b)) end
                        -- If it IS a ft -> litres map, the DIFF against the trough is
                        -- exactly what grazing supplies. Printed either way; a wrong
                        -- guess just prints nothing useful rather than misleading.
                        if type(a) == "table" then
                            local diffs = {}
                            for k, v in pairs(a) do
                                if type(k) == "number" and type(v) == "number" then
                                    local d = v - (spec.fillLevels[k] or 0)
                                    if math.abs(d) > 0.01 then
                                        diffs[#diffs + 1] = string.format("%s %+.1f", ftName(k), d)
                                    end
                                end
                            end
                            table.sort(diffs)
                            out("      minus fillLevels      -> %s",
                                #diffs > 0 and table.concat(diffs, ", ")
                                or "(identical, so nothing is being grazed right now)")
                        end
                    else
                        out("  getAvailableFood()      -> THREW: %s", tostring(a))
                    end

                    -- per-fill-type form, in case it takes one
                    local probeFt = nil
                    for ft in pairs(spec.supportedFillTypes or {}) do probeFt = ft; break end
                    if probeFt ~= nil then
                        local ok2, r2 = pcall(p.getAvailableFood, p, probeFt)
                        out("  getAvailableFood(%s) -> %s", ftName(probeFt),
                            ok2 and describe(r2) or ("THREW: " .. tostring(r2)))
                    end
                end

                -- getFoodInfos is the other meadow override and is what the base
                -- game's own UI reads, so it may already carry the merged picture.
                if p.getFoodInfos ~= nil then
                    local ok3, infos = pcall(p.getFoodInfos, p)
                    out("  getFoodInfos()          -> %s", ok3 and describe(infos)
                        or ("THREW: " .. tostring(infos)))
                end

                -- The condition panel's data source. Six specs contribute, and a
                -- modded husbandry may add its own entries, so the shape is worth
                -- seeing rather than assuming.
                if p.getConditionInfos ~= nil then
                    local ok4, conds = pcall(p.getConditionInfos, p)
                    if ok4 and type(conds) == "table" then
                        out("  getConditionInfos()     -> %d entr%s", #conds,
                            #conds == 1 and "y" or "ies")
                        for i, c in ipairs(conds) do
                            out("      [%d] %s", i, describe(c))
                        end
                    else
                        out("  getConditionInfos()     -> %s",
                            ok4 and describe(conds) or ("THREW: " .. tostring(conds)))
                    end
                end
                if p.getGlobalProductionFactor ~= nil and p.getProductionFactor ~= nil then
                    local okG, gf = pcall(p.getGlobalProductionFactor, p)
                    local okP, pf = pcall(p.getProductionFactor, p)
                    out("  productionFactor=%s  globalProductionFactor=%s  productivity=%s",
                        okP and tostring(pf) or "?", okG and tostring(gf) or "?",
                        (okG and okP and type(gf) == "number" and type(pf) == "number")
                            and string.format("%.4f", gf * pf) or "?")
                end
            end
        end
    end
    out("=================================================================")
    out("%d husbandr%s reported. Compare a GRAZING barn against a non-grazing one:",
        n, n == 1 and "y" or "ies")
    out("the difference between them is what the meadow contributes.")
end

function AnimalFoodProbe:consoleCommandAvail(fragment)
    local ok, err = pcall(AnimalFoodProbe.runAvailFood, fragment)
    if not ok then return "arAvailFood failed: " .. tostring(err) end
    return "arAvailFood done -- see log.txt"
end

-- ---------------------------------------------------------------------------
function AnimalFoodProbe.register()
    if addConsoleCommand == nil then return false end
    if AnimalFoodProbe._registered then return true end
    addConsoleCommand("arFoodProbe", "Measure the animal food mix -> production factor curve",
        "consoleCommand", AnimalFoodProbe)
    addConsoleCommand("arFeedPartial", "Is the food factor presence-based or quantity-based?",
        "consoleCommandPartial", AnimalFoodProbe)
    addConsoleCommand("arMenuProbe", "Dump how DR's menu places its pages",
        "consoleCommandMenu", AnimalFoodProbe)
    addConsoleCommand("arAvailFood", "What does getAvailableFood() actually return?",
        "consoleCommandAvail", AnimalFoodProbe)
    addConsoleCommand("arTradeProbe", "Do the base game's animal trade classes exist at runtime?",
        "consoleCommandTrade", AnimalFoodProbe)
    addConsoleCommand("arTradeOpen", "Open the game's own animal screen for a barn (no trailer)",
        "consoleCommandTradeOpen", AnimalFoodProbe)
    addConsoleCommand("arReproProbe", "Reproduction yield + the health/age price terms (clone-only)",
        "consoleCommandRepro", AnimalFoodProbe)
    addConsoleCommand("arHealthProbe", "What food factor SUSTAINS what health? (clone-only)",
        "consoleCommandHealth", AnimalFoodProbe)
    addConsoleCommand("arSellProbe", "Can a mod sell animals headlessly? (dry run; add 'go' to try one)",
        "consoleCommandSell", AnimalFoodProbe)
    addConsoleCommand("arSellDiff", "What does the GUI set on a sell controller that we do not?",
        "consoleCommandSellDiff", AnimalFoodProbe)
    addConsoleCommand("arOutputCurve", "Does output depend on animal AGE? (read only, no clones)",
        "consoleCommandOutputCurve", AnimalFoodProbe)
    AnimalFoodProbe._registered = true
    return true
end

function AnimalFoodProbe:consoleCommand(fragment, demand)
    local ok, err = pcall(AnimalFoodProbe.run, fragment, demand)
    if not ok then return "arFoodProbe failed: " .. tostring(err) end
    return "arFoodProbe done -- see log.txt"
end

-- ============================================================================
-- arTradeProbe / arTradeOpen   -- TEMPORARY DEV PROBE
--
-- WHAT IT ANSWERS. The base game's animal BUY/SELL path cannot be read:
-- gui/AnimalScreen.lua is 78% blank in the shipped SDK source (8 surviving
-- functions, none of them the transaction), its controller classes are absent
-- from the tree entirely, and there is no AnimalBuyEvent / AnimalSellEvent file
-- anywhere in it. Per the project rule, an ABSENCE in that source proves
-- nothing, so this asks the running game instead.
--
-- WHY WE EXPECT THEM TO EXIST. FS25_RealisticLivestockRM overwrites them:
--     AnimalScreenDealerFarm.initTargetItems = Utils.overwrittenFunction(
--         AnimalScreenDealerFarm.initTargetItems, RL_..initTargetItems)
--     AnimalScreen.setController = Utils.overwrittenFunction(
--         AnimalScreen.setController, RealisticLivestock_AnimalScreen.setController)
-- You cannot overwrite what does not exist. That names the doors; this probe
-- checks they open. RL is GPL v3 and NOTHING is taken from it: only the fact
-- that a given base-game symbol exists, which is then verified here.
--
-- THE CAVEAT THAT MATTERS MOST, AND IT IS PRINTED FIRST. A mod's override of a
-- base-game class lands in the SHARED global table, so with RealisticLivestock
-- installed every method list below is RL's, not the base game's. The probe
-- reports whether RL is active before anything else. RUN IT TWICE, once with RL
-- enabled and once with it disabled, or the answer is about RL.
--
-- READ-ONLY. arTradeProbe buys nothing, sells nothing, moves no animal and
-- touches no money: it reads names, levels and prices. The one side-effecting
-- half is deliberately a SEPARATE command (arTradeOpen), which opens the base
-- game's own screen and nothing more.
--
-- Usage (needs game.xml development controls true):
--     arTradeProbe                 : context + globals + first 3 barns
--     arTradeProbe <name fragment> : only barns whose name contains this
--     arTradeOpen  <name fragment> : open the game's screen for that barn
--     arTradeOpen  <frag> move     : as a farm-to-farm move, not a dealer buy
--
-- REMOVE with the other probes before release (open item 4).
-- ============================================================================

local function tout(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[arTrade] " .. (ok and msg or tostring(fmt)))
end

-- Every one of these is ABSENT from the shipped SDK source. Their presence at
-- runtime is the whole question.
local TRADE_GLOBALS = {
    "AnimalScreen", "AnimalScreenBase",
    "AnimalScreenDealer", "AnimalScreenDealerFarm", "AnimalScreenDealerTrailer",
    "AnimalScreenTrailer", "AnimalScreenTrailerFarm", "AnimalScreenMoveFarm",
    "AnimalItem", "AnimalItemStock",
    "AnimalBuyEvent", "AnimalSellEvent", "AnimalMoveEvent", "AnimalUnloadEvent",
}

-- Tested by NAME as well as enumerated. DR 6.12 found a class whose metatable is
-- PROTECTED (getmetatable returns a decoy with no __index while the methods
-- resolve perfectly), so an empty enumeration is not evidence of an empty class.
local CLUSTER_METHODS = {
    "getAge", "getNumAnimals", "getSubTypeIndex", "getSellPrice", "addInfos",
    "clone", "changeNumAnimals", "getSupportsMerging", "setName",
    "updateHealth", "updateReproduction",
}
local HUSB_METHODS = {
    "getClusters", "getCluster", "getClusterById", "addCluster", "addAnimals",
    "getNumOfAnimals", "getMaxNumOfAnimals", "getNumOfFreeAnimalSlots",
    "getSupportsAnimalSubType", "getAnimalTypeIndex", "getAnimalInfos",
    "getAnimalDescription", "getClusterSystem",
}
local ANIMALSYS_METHODS = {
    "getSaleAnimalsByTypeIndex", "getSubTypeByIndex", "getVisualByAge",
    "getTypeByIndex", "getSubTypeIndexByName", "getAnimalsByType",
}

-- ---------------------------------------------------------------------------
local function fnNamesOf(t)
    local names = {}
    if type(t) ~= "table" then return names end
    local ok = pcall(function()
        for k, v in pairs(t) do
            if type(k) == "string" and type(v) == "function" then names[#names + 1] = k end
        end
    end)
    if not ok then return {} end
    table.sort(names)
    return names
end

-- Which of `wanted` actually RESOLVE on obj. Indexing goes through the metatable,
-- so this sees a method that enumeration cannot.
local function resolvable(obj, wanted)
    local yes, no = {}, {}
    for _, n in ipairs(wanted) do
        local ok, v = pcall(function() return obj[n] end)
        if ok and type(v) == "function" then
            yes[#yes + 1] = n
        else
            no[#no + 1] = n
        end
    end
    return yes, no
end

local function joinList(t, max)
    if #t == 0 then return "(none)" end
    local n = math.min(#t, max or 999)
    local parts = {}
    for i = 1, n do parts[#parts + 1] = tostring(t[i]) end
    local s = table.concat(parts, ", ")
    if #t > n then s = s .. string.format(", ...(+%d more)", #t - n) end
    return s
end

local function callNum(obj, name)
    if obj == nil or obj[name] == nil then return nil end
    local ok, v = pcall(obj[name], obj)
    if ok and type(v) == "number" then return v end
    return nil
end

local function countPairs(t)
    local n = 0
    if type(t) ~= "table" then return 0 end
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------------
local function ownerFarmOf(p)
    if p == nil or p.getOwnerFarmId == nil then return nil end
    local ok, f = pcall(p.getOwnerFarmId, p)
    if ok and type(f) == "number" then return f end
    return nil
end

-- The LOCAL player's farm, or nil. 0 is SPECTATOR, not a farm (DR 5.47), and the
-- caller treats nil as "no preference", so a dedicated server loses the ordering
-- rather than matching nothing.
local function playerFarmId()
    if g_currentMission == nil or g_currentMission.getFarmId == nil then return nil end
    local ok, f = pcall(g_currentMission.getFarmId, g_currentMission)
    if not ok or type(f) ~= "number" or f == 0 then return nil end
    return f
end

-- ---------------------------------------------------------------------------
-- Husbandries with an ANIMALS spec. Deliberately UNSCOPED by farm: a probe that
-- hides rows cannot tell you a row was hidden, so ownership is reported per barn
-- instead and a map-owned pen is visible AS map-owned.
local function findAnimalBarns(fragment)
    local found = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil or ps.placeables == nil then return found end
    for _, p in ipairs(ps.placeables) do
        if p.spec_husbandryAnimals ~= nil then
            local name = "?"
            local okN, n = pcall(function() return p:getName() end)
            if okN and n ~= nil then name = tostring(n) end
            if fragment == nil or fragment == ""
               or string.find(string.lower(name), string.lower(fragment), 1, true) ~= nil then
                found[#found + 1] = { placeable = p, name = name,
                                      count = callNum(p, "getNumOfAnimals") or 0,
                                      farm  = ownerFarmOf(p) }
            end
        end
    end

    -- ORDER MATTERS, and the first version got it wrong. Placeable order put three
    -- EMPTY chicken sheds first (two of them map-owned), so the default run printed
    -- "clusters: 0" three times and answered nothing about clusters at all. An empty
    -- barn is a valid row and a useless SAMPLE. So: the player's own farm first, then
    -- most animals first, then by name so the order is stable between runs.
    local myFarm = playerFarmId()
    table.sort(found, function(a, b)
        local am = (myFarm ~= nil and a.farm == myFarm) and 1 or 0
        local bm = (myFarm ~= nil and b.farm == myFarm) and 1 or 0
        if am ~= bm then return am > bm end
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    return found
end

-- ---------------------------------------------------------------------------
-- Is RealisticLivestock live? By GLOBALS, not by zip name: RL ships as both
-- FS25_RealisticLivestockRM and FS25_RealisticLivestock, so the name is not a
-- reliable test (AR CLAUDE.md 5).
local function realisticLivestockActive()
    local hits = {}
    local names = { "RealisticLivestock", "RLSettings", "RLModBridge",
                    "RLConstants", "RmLogging" }
    for _, g in ipairs(names) do
        local ok, v = pcall(function() return _G[g] end)
        if ok and v ~= nil then hits[#hits + 1] = g end
    end
    local mods = {}
    if g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
        local okM, list = pcall(g_modManager.getActiveMods, g_modManager)
        if okM and type(list) == "table" then
            for _, mod in pairs(list) do
                local n = type(mod) == "table" and mod.modName or nil
                if type(n) == "string" and string.find(string.lower(n), "livestock", 1, true) then
                    mods[#mods + 1] = n
                end
            end
        end
    end
    return #hits > 0, hits, mods
end

-- ---------------------------------------------------------------------------
function AnimalFoodProbe.dumpTradeContext()
    tout("================= arTradeProbe =================")
    tout("CONTEXT")
    local rlOn, rlGlobals, rlMods = realisticLivestockActive()
    if rlOn or #rlMods > 0 then
        tout("  *** RealisticLivestock IS ACTIVE (globals: %s | mods: %s)",
             joinList(rlGlobals, 9), joinList(rlMods, 9))
        tout("  *** RL overwrites these classes IN THE SHARED GLOBAL TABLE, so every")
        tout("  *** method list below may be RL's and not the base game's.")
        tout("  *** Run this again with RL DISABLED to see the base game.")
    else
        tout("  RealisticLivestock not detected: what follows should be the BASE GAME.")
    end
    local farmId = "?"
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        local okF, f = pcall(g_currentMission.getFarmId, g_currentMission)
        if okF then farmId = tostring(f) end
    end
    tout("  isServer=%s  isClient=%s  farmId=%s",
         tostring(g_server ~= nil), tostring(g_client ~= nil), farmId)
end

function AnimalFoodProbe.dumpTradeGlobals()
    tout("")
    tout("GLOBALS: present at runtime? (all are absent from the shipped SDK source)")
    local missing = 0
    for _, name in ipairs(TRADE_GLOBALS) do
        local ok, v = pcall(function() return _G[name] end)
        if not ok then v = nil end
        if v == nil then
            missing = missing + 1
            tout("  %s  MISSING", pad(name, 26))
        else
            local fns = fnNamesOf(v)
            tout("  %s  %s, %d function(s)", pad(name, 26), type(v), #fns)
            tout("        %s", joinList(fns, 14))
        end
    end
    tout("  -> %d of %d missing", missing, #TRADE_GLOBALS)

    tout("")
    tout("g_animalScreen")
    if g_animalScreen == nil then
        tout("  MISSING: the screen singleton does not exist, so arTradeOpen cannot work")
    else
        local yes, no = resolvable(g_animalScreen, { "setController", "show", "onOpen", "onClose" })
        tout("  present. resolves: %s", joinList(yes, 9))
        if #no > 0 then tout("  does NOT resolve: %s", joinList(no, 9)) end
        tout("  controller currently: %s", tostring(g_animalScreen.controller))
    end

    tout("")
    tout("animalSystem")
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil then
        tout("  MISSING")
    else
        local yes, no = resolvable(asys, ANIMALSYS_METHODS)
        tout("  resolves: %s", joinList(yes, 9))
        if #no > 0 then tout("  does NOT resolve: %s", joinList(no, 9)) end
    end
end

-- ---------------------------------------------------------------------------
-- One barn: what the Animals view and the Trade view would each have to read.
function AnimalFoodProbe.dumpTradeBarn(p, name)
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil

    local ownerFarm = "?"
    local okO, of = pcall(function() return p:getOwnerFarmId() end)
    if okO then ownerFarm = tostring(of) end

    local ati = nil
    if p.getAnimalTypeIndex ~= nil then
        local okA, a = pcall(p.getAnimalTypeIndex, p)
        if okA then ati = a end
    end

    tout("")
    tout("BARN  %s   farm=%s  animalTypeIndex=%s", name, ownerFarm, tostring(ati))

    local hy, hn = resolvable(p, HUSB_METHODS)
    if #hn > 0 then tout("  husbandry does NOT resolve: %s", joinList(hn, 14)) end

    tout("  animals=%s / max=%s   freeSlots=%s",
         tostring(callNum(p, "getNumOfAnimals")),
         tostring(callNum(p, "getMaxNumOfAnimals")),
         tostring(callNum(p, "getNumOfFreeAnimalSlots")))

    -- CLUSTERS: the per-animal view's rows.
    local clusters = nil
    if p.getClusters ~= nil then
        local okC, c = pcall(p.getClusters, p)
        if okC then clusters = c end
    end
    if type(clusters) ~= "table" then
        tout("  getClusters returned %s: no per-animal rows available here", type(clusters))
        return
    end

    local total = countPairs(clusters)
    tout("  clusters: %d", total)

    local shown = 0
    for _, cl in pairs(clusters) do
        shown = shown + 1
        if shown > 5 then
            tout("    ...(%d more clusters not shown)", total - 5)
            break
        end

        if shown == 1 then
            local cy, cn = resolvable(cl, CLUSTER_METHODS)
            tout("    cluster methods resolving: %s", joinList(cy, 14))
            if #cn > 0 then tout("    cluster methods MISSING:   %s", joinList(cn, 14)) end
            local enumerated = fnNamesOf(cl)
            local mt = getmetatable(cl)
            if #enumerated == 0 and #cy > 0 then
                tout("    NOTE metatable is protected or indirect (enumeration empty, methods resolve);")
                tout("         getmetatable -> %s, __index -> %s", type(mt),
                     type(mt) == "table" and type(mt.__index) or "n/a")
            end
        end

        local function num(m)
            local ok, v = pcall(function() return cl[m](cl) end)
            if ok and v ~= nil then return tostring(v) end
            return "?"
        end

        local sti = cl.subTypeIndex
        local stName = "?"
        if asys ~= nil and asys.getSubTypeByIndex ~= nil and sti ~= nil then
            local okS, st = pcall(asys.getSubTypeByIndex, asys, sti)
            if okS and type(st) == "table" then
                stName = tostring(st.name or st.fillTypeIndex or "?")
                if shown == 1 then
                    local keys = {}
                    for k in pairs(st) do keys[#keys + 1] = tostring(k) end
                    table.sort(keys)
                    tout("    subType fields: %s", joinList(keys, 12))
                end
            end
        end
        tout("    #%d subType=%s(%s) n=%s age=%s health=%s sellPrice=%s",
             shown, tostring(sti), stName, num("getNumAnimals"), num("getAge"),
             tostring(cl.health), num("getSellPrice"))

        -- The base game's OWN per-animal info list. If this works, the Animals
        -- view's detail rows are nearly free: same shape as getConditionInfos,
        -- which this tab already renders.
        if shown == 1 then
            local infos = nil
            if p.getAnimalInfos ~= nil then
                local okI, t = pcall(p.getAnimalInfos, p, cl)
                if okI then infos = t end
            end
            if type(infos) ~= "table" and cl.addInfos ~= nil then
                infos = {}
                pcall(cl.addInfos, cl, infos)
            end
            if type(infos) == "table" then
                tout("    getAnimalInfos -> %d entr%s", #infos, (#infos == 1) and "y" or "ies")
                for i, e in ipairs(infos) do
                    if type(e) == "table" then
                        tout("      [%d] title=%s  value=%s  ratio=%s", i,
                             tostring(e.title), tostring(e.value), tostring(e.ratio))
                    else
                        tout("      [%d] %s", i, tostring(e))
                    end
                end
            else
                tout("    getAnimalInfos / addInfos produced nothing")
            end
        end
    end

    -- WHAT COULD BE BOUGHT INTO THIS BARN. This is the Trade view's source list,
    -- and the one thing that decides whether it can show offers and prices
    -- without opening the game's own screen.
    if asys ~= nil and asys.getSaleAnimalsByTypeIndex ~= nil and ati ~= nil then
        local okS, sale = pcall(asys.getSaleAnimalsByTypeIndex, asys, ati)
        if okS and type(sale) == "table" then
            local sn = countPairs(sale)
            tout("  getSaleAnimalsByTypeIndex(%s) -> %d offer(s)", tostring(ati), sn)
            local i = 0
            for _, item in pairs(sale) do
                i = i + 1
                if i > 5 then
                    tout("    ...(%d more)", sn - 5)
                    break
                end
                if type(item) == "table" then
                    if i == 1 then
                        local keys = {}
                        for k in pairs(item) do keys[#keys + 1] = tostring(k) end
                        table.sort(keys)
                        tout("    offer fields: %s", joinList(keys, 12))
                    end
                    tout("    offer[%d] subTypeIndex=%s age=%s numAnimals=%s price=%s",
                         i, tostring(item.subTypeIndex), tostring(item.age),
                         tostring(item.numAnimals), tostring(item.price or item.buyPrice))
                else
                    tout("    offer[%d] is a %s, not a table", i, type(item))
                end
            end
        else
            tout("  getSaleAnimalsByTypeIndex failed or did not return a table")
        end
    end
end

-- ---------------------------------------------------------------------------
function AnimalFoodProbe.runTradeProbe(fragment)
    AnimalFoodProbe.dumpTradeContext()
    AnimalFoodProbe.dumpTradeGlobals()

    local barns = findAnimalBarns(fragment)
    local suffix = ""
    if fragment ~= nil and fragment ~= "" then suffix = " matching '" .. fragment .. "'" end
    tout("")
    tout("BARNS: %d husbandr%s with an animals spec%s",
         #barns, (#barns == 1) and "y" or "ies", suffix)
    if #barns == 0 then
        tout("  none. An EMPTY list is evidence too: either this save has no animal")
        tout("  husbandry, or spec_husbandryAnimals is not the field to look under.")
    end

    -- The full inventory FIRST, before any detail. Three empty sheds in a row is
    -- otherwise indistinguishable from "this farm has no animals".
    for i, b in ipairs(barns) do
        tout("  %2d. %s  farm=%s  animals=%d", i, pad(b.name, 34),
             tostring(b.farm), b.count)
    end

    local limit = #barns
    if fragment == nil or fragment == "" then limit = math.min(#barns, 3) end
    for i = 1, limit do
        AnimalFoodProbe.dumpTradeBarn(barns[i].placeable, barns[i].name)
    end
    if limit < #barns then
        tout("")
        tout("(%d more barn(s) not shown: pass a name fragment to target one)", #barns - limit)
    end

    tout("")
    tout("READ-ONLY: nothing was bought, sold, moved or paid for.")
    tout("Next: arTradeOpen <fragment> to see which controller the game picks for a barn.")
    tout("================================================")
end

-- ---------------------------------------------------------------------------
-- The one side-effecting half, kept as its own command so it cannot fire by
-- accident. It opens the base game's OWN screen (the same call the animal
-- loading trigger makes, AnimalLoadingTrigger.lua:243) and reports which
-- controller class the game chose. That is what decides whether Husbandry Redux's
-- Trade view can be "rules plus a button" rather than a reimplemented
-- transaction.
--
-- setController is pcall'd and showGui runs ONLY if it succeeded: a half-set
-- controller followed by a shown screen is how you get a GUI throwing on every
-- frame (AR CLAUDE.md 2.3, and DR's addMenuPage learned it the hard way).
function AnimalFoodProbe.runTradeOpen(fragment, mode)
    local isDealer = true
    if mode ~= nil and string.lower(tostring(mode)) == "move" then isDealer = false end

    tout("================= arTradeOpen =================")

    if g_animalScreen == nil then
        tout("g_animalScreen is nil: cannot open. Nothing was changed.")
        return
    end
    if g_animalScreen.setController == nil then
        tout("g_animalScreen has no setController: cannot open. Nothing was changed.")
        return
    end

    local barns = findAnimalBarns(fragment)
    local suffix = ""
    if fragment ~= nil and fragment ~= "" then suffix = " for '" .. fragment .. "'" end
    tout("%d matching barn(s)%s", #barns, suffix)
    if #barns == 0 then
        tout("nothing to open. Pass a name fragment matching one of your barns.")
        return
    end

    local barn, name = barns[1].placeable, barns[1].name
    tout("opening for '%s' with trailer=nil, isDealer=%s", name, tostring(isDealer))
    tout("  (a nil trailer is the question: does the game pick a *Farm controller?)")

    local ok, err = pcall(function()
        g_animalScreen:setController(barn, nil, isDealer)
    end)
    if not ok then
        tout("setController THREW: %s", tostring(err))
        tout("The screen was NOT shown. Nothing is half-open.")
        return
    end

    local ctrl = g_animalScreen.controller
    tout("setController ok. controller = %s", tostring(ctrl))
    if type(ctrl) == "table" then
        local mt = getmetatable(ctrl)
        tout("  controller metatable: %s", tostring(mt))
        tout("  controller functions: %s", joinList(fnNamesOf(ctrl), 14))
        tout("  husbandry=%s trailer=%s isDealer=%s",
             tostring(ctrl.husbandry), tostring(ctrl.trailer), tostring(ctrl.isDealer))
        -- Which class is it? The FIRST version compared mt.__index against each
        -- global and reported "not identified" on a perfectly ordinary controller.
        -- That was the DR 6.12 shape again, and this probe had already printed the
        -- evidence three screens earlier: getmetatable -> table, __index -> nil. A
        -- protected metatable defeats identity comparison exactly as it defeats
        -- enumeration, so the test has to go through the class chain instead.
        local named = false
        if type(ctrl.isa) == "function" then
            for _, gname in ipairs(TRADE_GLOBALS) do
                local okG, g = pcall(function() return _G[gname] end)
                if okG and type(g) == "table" then
                    local okI, yes = pcall(ctrl.isa, ctrl, g)
                    if okI and yes == true then
                        tout("  -> isa(%s) = TRUE", gname)
                        named = true
                    end
                end
            end
            if not named then tout("  -> isa() said no to every known class") end
        else
            tout("  -> no isa() on the controller; cannot walk the class chain")
        end

        -- Fingerprint fallback: which class-distinguishing methods RESOLVE. This
        -- works whatever the metatable does, and it is what the Trade view would
        -- actually call, so it is the more useful answer of the two anyway.
        local cy, cn = resolvable(ctrl, {
            "applySource", "applyTarget", "applySourceBulk", "applyTargetBulk",
            "getSourceItems", "getTargetItems", "getSourcePrice", "getTargetPrice",
            "getSourceName", "getTargetName", "getSourceActionText", "getTargetActionText",
            "getMaxNumAnimals", "getSourceMaxNumAnimals", "getTargetMaxNumAnimals",
        })
        tout("  controller RESOLVES: %s", joinList(cy, 15))
        if #cn > 0 then tout("  controller lacks:    %s", joinList(cn, 15)) end
        if type(ctrl.getSourceName) == "function" then
            local okN, sn = pcall(ctrl.getSourceName, ctrl)
            local okT, tn = pcall(ctrl.getTargetName, ctrl)
            tout("  source='%s'  target='%s'  (which way round the screen is pointing)",
                 okN and tostring(sn) or "?", okT and tostring(tn) or "?")
        end
    end

    if g_gui ~= nil and g_gui.showGui ~= nil then
        local okS, errS = pcall(g_gui.showGui, g_gui, "AnimalScreen")
        if okS then
            tout("showGui('AnimalScreen') -> ok")
            tout("Press Back to close. Nothing has been bought or sold.")
        else
            tout("showGui('AnimalScreen') -> FAILED: %s", tostring(errS))
        end
    else
        tout("g_gui:showGui unavailable: controller was set but no screen shown.")
    end
    tout("==============================================")
end

function AnimalFoodProbe:consoleCommandTrade(fragment)
    local ok, err = pcall(AnimalFoodProbe.runTradeProbe, fragment)
    if not ok then return "arTradeProbe failed: " .. tostring(err) end
    return "arTradeProbe done -- see log.txt"
end

function AnimalFoodProbe:consoleCommandTradeOpen(fragment, mode)
    local ok, err = pcall(AnimalFoodProbe.runTradeOpen, fragment, mode)
    if not ok then return "arTradeOpen failed: " .. tostring(err) end
    return "arTradeOpen done -- see log.txt"
end

-- ============================================================================
-- arReproProbe   -- TEMPORARY DEV PROBE
--
-- TWO QUESTIONS LEFT OPEN BY §11:
--   1. How many offspring does cluster:updateReproduction() yield, and does it
--      scale with headcount? That figure is what the whole slot-economics rule
--      turns on, and the function is stripped from the SDK source.
--   2. The health term in sellPrice = curve(age) * (0.40 + 0.60 * health) was
--      solved from THREE points against TWO unknowns. One mid-health sample
--      closes it.
--
-- WHY THIS ONE IS DANGEROUS, AND WHAT IS DONE ABOUT IT.
-- updateReproduction() SPENDS THE GESTATION TIMER -- PlaceableHusbandryAnimals
-- :onPeriodChanged calls it and only THEN clamps the birth count to free slots,
-- which is exactly how a full pen loses both the calf and the months that made
-- it (§11.5). Calling it on a live cluster would destroy real breeding progress
-- on the player's farm.
--
-- So NOTHING here touches a live cluster. Every measurement runs on a CLONE
-- (cluster:clone(), confirmed to resolve in §10.5), and before a single clone is
-- used the probe PROVES the clone is independent: it snapshots the original's
-- fields, mutates the clone hard, re-reads the original and diffs. If ANY field
-- moved, the whole probe aborts and says so. A shallow clone sharing a table
-- would otherwise corrupt the herd silently, and the damage would not surface
-- until the next period change.
--
-- The sweeps are also RATIO-based where they can be. Sweeping health and
-- dividing by the price at health 100 measures the health term without needing
-- the price curve at all, so the result cannot be contaminated by a wrong curve.
-- Sweeping age at fixed health then measures the curve itself, which
-- independently cross-checks the XML read in §11.3.
--
-- Usage (needs game.xml development controls true):
--     arReproProbe                 : the biggest owned barn
--     arReproProbe <name fragment> : that barn
--
-- READ-ONLY with respect to the save. REMOVE with the other probes.
-- ============================================================================

local function rout(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[arRepro] " .. (ok and msg or tostring(fmt)))
end

-- Instance FIELDS, not methods. Enumeration works here even though it fails for
-- methods: the methods live behind the protected metatable (§10.5), the fields
-- sit on the object itself. This is what reveals the reproduction timer's name.
local function scalarFields(cl)
    local out = {}
    if type(cl) ~= "table" then return out end
    pcall(function()
        for k, v in pairs(cl) do
            local t = type(v)
            if type(k) == "string" and (t == "number" or t == "boolean" or t == "string") then
                out[k] = v
            end
        end
    end)
    return out
end

local function sortedKeys(t)
    local ks = {}
    for k in pairs(t) do ks[#ks + 1] = k end
    table.sort(ks)
    return ks
end

local function diffFields(before, after)
    local moved = {}
    for _, k in ipairs(sortedKeys(before)) do
        if after[k] ~= before[k] then
            moved[#moved + 1] = string.format("%s: %s -> %s", k,
                tostring(before[k]), tostring(after[k]))
        end
    end
    for _, k in ipairs(sortedKeys(after)) do
        if before[k] == nil then
            moved[#moved + 1] = string.format("%s: (absent) -> %s", k, tostring(after[k]))
        end
    end
    return moved
end

local function priceOf(cl)
    if cl == nil or cl.getSellPrice == nil then return nil end
    local ok, v = pcall(cl.getSellPrice, cl)
    if ok and type(v) == "number" then return v end
    return nil
end

-- ---------------------------------------------------------------------------
-- THE GATE. Everything below refuses to run unless this returns true.
--
-- It does not merely check that clone() returned something: it mutates the clone
-- and proves the ORIGINAL did not move. That is the only test that distinguishes
-- a real copy from a shallow one sharing sub-tables, and a shallow one would
-- corrupt the player's herd invisibly.
function AnimalFoodProbe.cloneIsSafe(cl)
    if cl == nil or cl.clone == nil then
        rout("  clone() is not available on this cluster -- ABORTING every sweep.")
        return false, nil
    end

    local before = scalarFields(cl)
    local okC, cp = pcall(cl.clone, cl)
    if not okC or type(cp) ~= "table" then
        rout("  clone() failed or returned %s -- ABORTING.", type(okC and cp or nil))
        return false, nil
    end
    if cp == cl then
        rout("  clone() returned THE SAME TABLE -- ABORTING (it is not a copy).")
        return false, nil
    end

    -- Mutate the clone as hard as anything below will.
    --
    -- THE CANARIES ARE DERIVED, NEVER CONSTANT. With fixed values this gate has a
    -- blind spot, found by tools/sellrules.lua against the twin of this function:
    -- a write-through clone leaves the ORIGINAL holding the canaries, so a SECOND
    -- call writes the same numbers, sees nothing move, and passes the very clone
    -- it just rejected. Offsetting from what the original holds now means the
    -- canary can never already be there.
    local CANARY_N = (cl.numAnimals or 0) + 1000
    local CANARY_H = (cl.health or 0) + 1000
    local CANARY_A = (cl.age or 0) + 1000
    pcall(function()
        cp.numAnimals = CANARY_N
        cp.health = CANARY_H
        cp.age = CANARY_A
    end)

    local took = (cp.numAnimals == CANARY_N) and (cp.health == CANARY_H) and (cp.age == CANARY_A)
    if not took then
        rout("  the clone did not accept a write (numAnimals=%s health=%s age=%s)",
             tostring(cp.numAnimals), tostring(cp.health), tostring(cp.age))
        rout("  ABORTING: cannot sweep what cannot be set.")
        return false, nil
    end

    local moved = diffFields(before, scalarFields(cl))
    if #moved > 0 then
        rout("  *** THE ORIGINAL CLUSTER MOVED WHEN THE CLONE WAS WRITTEN:")
        for _, m in ipairs(moved) do rout("        %s", m) end
        rout("  *** clone() is SHALLOW. ABORTING before anything is damaged.")
        -- Detecting it required making it happen, so put the herd back. The gate
        -- must not itself be what ages or re-prices a player's animals.
        local repaired = 0
        for k, v in pairs(before) do
            if cl[k] ~= v then
                local okR = pcall(function() cl[k] = v end)
                if okR and cl[k] == v then repaired = repaired + 1 end
            end
        end
        rout("  *** restored %d field(s) on the live cluster.", repaired)
        return false, nil
    end

    rout("  clone() verified independent: the clone took %d/%d writes and the", 3, 3)
    rout("  original did not move on any of %d scalar field(s).", #sortedKeys(before))
    return true, cp
end

-- A fresh clone per sample. updateReproduction() spends internal timer state, so
-- reusing one clone across samples would measure the timer, not the yield.
local function freshClone(cl)
    local ok, cp = pcall(cl.clone, cl)
    if ok and type(cp) == "table" and cp ~= cl then return cp end
    return nil
end

-- ---------------------------------------------------------------------------
-- The cluster's own fields. This is what names the reproduction timer, which is
-- the thing §11.5 could describe but not read.
function AnimalFoodProbe.dumpClusterFields(cl)
    local f = scalarFields(cl)
    local ks = sortedKeys(f)
    rout("  cluster fields (%d):", #ks)
    local line = ""
    for i, k in ipairs(ks) do
        line = line .. string.format("%s=%s  ", k, tostring(f[k]))
        if i % 4 == 0 then rout("    %s", line); line = "" end
    end
    if line ~= "" then rout("    %s", line) end
end

-- The subType's runtime config. §11.4 could only read the HORSE numbers out of
-- the XML (increase 10/h, decrease 25/h, threshold 0.45); every other type uses
-- engine defaults that are only visible here.
function AnimalFoodProbe.dumpSubTypeConfig(sti)
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil or asys.getSubTypeByIndex == nil or sti == nil then return end
    local okS, st = pcall(asys.getSubTypeByIndex, asys, sti)
    if not okS or type(st) ~= "table" then return end

    rout("  subType %s (index %s)", tostring(st.name), tostring(sti))
    rout("    health:  increase/h=%s  decrease/h=%s  threshold=%s",
         tostring(st.healthIncreaseHour), tostring(st.healthDecreaseHour),
         tostring(st.healthThresholdFactor))
    rout("    repro:   minAgeMonth=%s  durationMonth=%s  minHealth=%s",
         tostring(st.reproductionMinAgeMonth), tostring(st.reproductionDurationMonth),
         tostring(st.reproductionMinHealth))
    rout("    price:   buyPrice=%s  (a curve object, not a scalar, if this reads 'table')",
         tostring(st.buyPrice))
end

-- ---------------------------------------------------------------------------
-- HEALTH TERM, measured as a RATIO so it needs no price curve.
-- price(h) / price(100) should be (0.40 + 0.60h) / 1.00 exactly.
function AnimalFoodProbe.sweepHealth(cl)
    rout("")
    rout("HEALTH TERM  (ratio against health 100, so the price CURVE cancels out)")
    local ref = freshClone(cl)
    if ref == nil then rout("  no clone; skipped"); return end
    ref.health = 100
    local base = priceOf(ref)
    if base == nil or base <= 0 then
        rout("  price at health 100 is %s -- cannot form ratios; skipped", tostring(base))
        return
    end
    rout("  price at health 100 = %.4f   (age %s)", base, tostring(ref.age))
    rout("  %6s %14s %10s %10s %8s", "health", "price", "ratio", "predicted", "delta")
    local worst = 0
    for _, h in ipairs({ 0, 10, 25, 50, 75, 90, 100 }) do
        local c = freshClone(cl)
        if c ~= nil then
            c.health = h
            local p = priceOf(c)
            if p ~= nil then
                local ratio = p / base
                local pred  = 0.40 + 0.60 * (h / 100)
                local d     = ratio - pred
                if math.abs(d) > worst then worst = math.abs(d) end
                rout("  %6d %14.4f %10.4f %10.4f %8.4f", h, p, ratio, pred, d)
            end
        end
    end
    rout("  worst deviation from 0.40 + 0.60h: %.5f  -> %s", worst,
         worst < 0.0005 and "CONFIRMED" or "THE MODEL IS WRONG, read the ratios above")
end

-- AGE CURVE, measured at fixed health. Independently reproduces the sellPrice
-- keys read out of the SDK XML in §11.3 -- if these disagree, the XML is not
-- what the running game is using (a map or a mod may replace it).
function AnimalFoodProbe.sweepAge(cl)
    rout("")
    rout("AGE CURVE  (health pinned at 100, so this IS the raw sellPrice curve)")
    rout("  %6s %14s %12s", "age mo", "price", "d/month")
    local prev, prevAge = nil, nil
    for _, a in ipairs({ 0, 3, 6, 9, 12, 18, 24, 30, 36, 42, 48, 60, 72 }) do
        local c = freshClone(cl)
        if c ~= nil then
            c.health = 100
            c.age = a
            local p = priceOf(c)
            if p ~= nil then
                local slope = ""
                if prev ~= nil and a > prevAge then
                    slope = string.format("%+.1f", (p - prev) / (a - prevAge))
                end
                rout("  %6d %14.2f %12s", a, p, slope)
                prev, prevAge = p, a
            end
        end
    end
    rout("  a NEGATIVE d/month is the decline after peak -- expected for COW only (§11.3)")
end

-- ---------------------------------------------------------------------------
-- REPRODUCTION YIELD. The open question, and the one with a side effect.
--
-- Each sample uses its OWN fresh clone: updateReproduction() spends internal
-- timer state, so reusing one clone would measure the timer rather than the
-- yield. The clone's fields are dumped before and after the FIRST call so the
-- timer field identifies itself by being the thing that moved.
function AnimalFoodProbe.sweepReproduction(cl)
    rout("")
    rout("REPRODUCTION YIELD")
    if cl.updateReproduction == nil then
        rout("  updateReproduction is NOT on this cluster.")
        rout("  Expected under RealisticLivestock, which replaces reproduction (§10.5).")
        return
    end

    -- What does one call actually change? Name the timer.
    local c0 = freshClone(cl)
    if c0 == nil then rout("  no clone; skipped"); return end
    local b4 = scalarFields(c0)
    local okR, yield0 = pcall(c0.updateReproduction, c0)
    if not okR then
        rout("  updateReproduction THREW: %s", tostring(yield0))
        return
    end
    local moved = diffFields(b4, scalarFields(c0))
    rout("  one call on a clone of the real cluster (n=%s age=%s health=%s repro=%s) -> %s",
         tostring(b4.numAnimals), tostring(b4.age), tostring(b4.health),
         tostring(b4.reproduction), tostring(yield0))
    if (b4.numAnimals or 0) == 0 then
        rout("  NOTE clone() copies IDENTITY (subtype, age, health, reproduction) but")
        rout("  zeroes numAnimals, so this first call was bound to yield 0. The sweeps")
        rout("  below set the headcount explicitly.")
    end
    if #moved > 0 then
        rout("  it changed these fields (this NAMES the gestation timer):")
        for _, m in ipairs(moved) do rout("        %s", m) end
    else
        rout("  it changed NO scalar field -- the timer is not a scalar on the cluster.")
    end

    -- Does yield scale with headcount?
    rout("")
    rout("  vs HEADCOUNT (age and health held at the real cluster's values)")
    rout("  %10s %10s", "numAnimals", "yield")
    for _, n in ipairs({ 1, 5, 10, 25, 50, 100, 205, 500 }) do
        local c = freshClone(cl)
        if c ~= nil then
            c.numAnimals = n
            local ok, y = pcall(c.updateReproduction, c)
            rout("  %10d %10s", n, ok and tostring(y) or "threw")
        end
    end

    -- Does the 0.75 health gate actually bite? §11.4 reads minHealthFactor=0.75
    -- from the XML, but the GATE lives in this stripped function.
    rout("")
    rout("  vs HEALTH  (headcount pinned at 100; the XML says nothing breeds below 0.75)")
    rout("  %8s %10s", "health", "yield")
    for _, h in ipairs({ 0, 25, 50, 70, 74, 75, 76, 90, 100 }) do
        local c = freshClone(cl)
        if c ~= nil then
            c.numAnimals = 100
            c.health = h
            local ok, y = pcall(c.updateReproduction, c)
            rout("  %8d %10s", h, ok and tostring(y) or "threw")
        end
    end

    -- And the minimum breeding age.
    rout("")
    rout("  vs AGE  (headcount 100, health 100)")
    rout("  %8s %10s", "age mo", "yield")
    for _, a in ipairs({ 0, 3, 6, 8, 12, 18, 22, 24, 36, 48 }) do
        local c = freshClone(cl)
        if c ~= nil then
            c.numAnimals = 100
            c.health = 100
            c.age = a
            local ok, y = pcall(c.updateReproduction, c)
            rout("  %8d %10s", a, ok and tostring(y) or "threw")
        end
    end

    rout("")
    rout("  READ IT CAREFULLY: a column of zeros may mean the gate bit, OR that the")
    rout("  gestation timer on this cluster is simply not due. Compare against the")
    rout("  first single call above, and against a barn whose animals are older.")
end

-- ---------------------------------------------------------------------------
-- THE COUNTER, and the question the first run raised.
--
-- The first run named the gestation timer: the cluster carries `reproduction`,
-- and one call took it 50 -> 0 while yielding one offspring PER ANIMAL. With
-- durationMonth=2 for chickens the reading is that each period adds
-- 100/durationMonth, and at 100 the whole cluster births and resets.
--
-- But every clone inherits reproduction=50, so that sweep held the counter
-- CONSTANT and could not see whether yield depends on it. This sets it directly.
--
-- The second question matters more. When a gate bites -- health below 0.75, or
-- under age -- is the accumulated progress CONSUMED anyway? That is exactly the
-- shape of the full-pen bug in §11.5, where updateReproduction() spends the
-- timer and the clamp discards the result afterwards. If an underfed herd also
-- burns its counter, then poor feeding does not merely pause breeding, it
-- destroys the progress permanently, and that changes what a sell rule should
-- advise.
function AnimalFoodProbe.sweepReproCounter(cl)
    if cl == nil or cl.updateReproduction == nil then return end

    rout("")
    rout("GESTATION COUNTER  (n=100, health=100, age=12; only `reproduction` varies)")
    rout("  %8s %10s %14s", "repro in", "yield", "repro after")
    for _, r in ipairs({ 0, 25, 49, 50, 51, 75, 99, 100 }) do
        local c = freshClone(cl)
        if c ~= nil then
            c.numAnimals, c.health, c.age, c.reproduction = 100, 100, 12, r
            local ok, y = pcall(c.updateReproduction, c)
            rout("  %8d %10s %14s", r, ok and tostring(y) or "threw", tostring(c.reproduction))
        end
    end
    rout("  if yield is 100 only at the top of the range, the counter is progress toward")
    rout("  a birth; if it is 100 throughout, the counter gates nothing.")

    rout("")
    rout("IS PROGRESS BURNED WHEN A GATE BITES?  (repro in = 50 every time)")
    rout("  This is the §11.5 shape: does the call SPEND the timer even when it")
    rout("  yields nothing? If it does, underfeeding destroys progress permanently.")
    rout("  %-28s %8s %14s", "case", "yield", "repro after")
    local cases = {
        { "control: healthy, mature",   100, 100, 12 },
        { "health 50 (below the gate)", 100,  50, 12 },
        { "health 10 (your pastures)",  100,  10, 12 },
        { "age 3 (below minAge 6)",     100, 100,  3 },
        { "one animal only",              1, 100, 12 },
    }
    for _, cs in ipairs(cases) do
        local c = freshClone(cl)
        if c ~= nil then
            c.numAnimals, c.health, c.age, c.reproduction = cs[2], cs[3], cs[4], 50
            local ok, y = pcall(c.updateReproduction, c)
            rout("  %-28s %8s %14s", cs[1], ok and tostring(y) or "threw",
                 tostring(c.reproduction))
        end
    end
    rout("  'repro after' = 50 means the progress SURVIVED the refusal.")
    rout("  Anything lower means it was spent for nothing -- a second silent loss")
    rout("  beside the full-pen one, and a much better reason to fix the feeding.")
end

-- ---------------------------------------------------------------------------
function AnimalFoodProbe.runReproProbe(fragment)
    rout("================= arReproProbe =================")

    local rlOn, rlG, rlM = realisticLivestockActive()
    if rlOn or #rlM > 0 then
        rout("  *** RealisticLivestock IS ACTIVE (%s). It replaces the cluster class",
             joinList(rlM, 4))
        rout("  *** outright, so every figure below is RL's model, not the base game's.")
    else
        rout("  RealisticLivestock not detected: this is the BASE GAME.")
    end

    local barns = findAnimalBarns(fragment)
    if #barns == 0 then
        rout("  no husbandry matched. Nothing was touched.")
        return
    end

    -- findAnimalBarns already sorts owned-first then by headcount, so [1] is the
    -- most populated barn on the player's own farm (§10.8).
    local barn, name = barns[1].placeable, barns[1].name
    rout("  barn: %s  (farm=%s, %d animals)", name, tostring(barns[1].farm), barns[1].count)

    local clusters = nil
    if barn.getClusters ~= nil then
        local okC, c = pcall(barn.getClusters, barn)
        if okC then clusters = c end
    end
    if type(clusters) ~= "table" or countPairs(clusters) == 0 then
        rout("  it has no clusters. Pass a fragment naming a barn that holds animals.")
        return
    end

    local cl = nil
    for _, c in pairs(clusters) do cl = c; break end

    rout("")
    rout("SAFETY GATE  (nothing below runs unless clone() is proven independent)")
    local safe = AnimalFoodProbe.cloneIsSafe(cl)
    if not safe then
        rout("")
        rout("  ABORTED. No sweep was run and NO LIVE CLUSTER WAS TOUCHED.")
        rout("================================================")
        return
    end

    rout("")
    AnimalFoodProbe.dumpClusterFields(cl)
    rout("")
    AnimalFoodProbe.dumpSubTypeConfig(cl.subTypeIndex)

    AnimalFoodProbe.sweepHealth(cl)
    AnimalFoodProbe.sweepAge(cl)
    AnimalFoodProbe.sweepReproduction(cl)
    AnimalFoodProbe.sweepReproCounter(cl)

    -- Prove it again at the END. The gate tested one clone before the sweeps; this
    -- tests that ~40 clones and several hundred writes later the real cluster is
    -- still exactly as it was. A leak that only appears under repetition would
    -- otherwise pass the gate and still cost the player their herd.
    rout("")
    rout("FINAL CHECK  (the live cluster, after every sweep)")
    local now = scalarFields(cl)
    local ok = true
    for _, k in ipairs(sortedKeys(now)) do
        if k == "numAnimals" or k == "health" or k == "age" then
            rout("    %s = %s", k, tostring(now[k]))
        end
    end
    rout("    compare against the 'cluster fields' dump above: numAnimals, health and")
    rout("    age must be IDENTICAL. If any moved, a clone leaked and it is a bug in")
    rout("    THIS PROBE, not in the game.")
    if ok then rout("") end
    rout("  Nothing was bought, sold, bred or aged. The save is untouched.")
    rout("================================================")
end

function AnimalFoodProbe:consoleCommandRepro(fragment)
    local ok, err = pcall(AnimalFoodProbe.runReproProbe, fragment)
    if not ok then return "arReproProbe failed: " .. tostring(err) end
    return "arReproProbe done -- see log.txt"
end

-- ============================================================================
-- arHealthProbe -- WHAT FOOD FACTOR SUSTAINS WHAT HEALTH?
--
--   arHealthProbe                 : the biggest owned barn
--   arHealthProbe <name fragment> : that barn
--
-- WHY THIS EXISTS. The adviser cannot recommend a feed mix without knowing what
-- health that mix HOLDS, and that is the one number the model has never had.
-- 11.9 sampled the three constants (increase/h, decrease/h, thresholdFactor)
-- but NOT THE SHAPE of the update, and the two candidate shapes give opposite
-- advice:
--
--   FLAT    health moves a fixed +increase / -decrease every hour, so it has no
--           intermediate resting point at all: at or above the threshold it
--           walks to 100 and stays there, below it it walks to 0. Health is then
--           FREE above the threshold and the whole recommendation collapses to
--           "buy the cheapest mix that clears it".
--   SCALED  the step shrinks as the factor approaches the threshold, so health
--           settles part way and every mix has its own sustained health. The
--           recommendation must then trade health against feed cost.
--
-- 32.10 assumed SCALED ("does hay at 0.80 hold health at 100 or let it settle
-- at 85") without testing it. A fixed +10/-25 cannot produce 85, so the question
-- as posed presumes its own answer. This settles it by measurement.
--
-- IT ALSO MEASURES THE THRESHOLD, which is only declared for horses: 11.9 read
-- chicken 0.2 against the horses' 0.45 and nothing else has been sampled. The
-- sign flip in sweep A gives it for whatever barn this is pointed at.
--
-- AnimalCluster is REFERENCED in ~10 places in the shipped source and DEFINED
-- nowhere, and nothing under data/ declares a health element outside the horses
-- -- so neither the shape nor the non-horse defaults can be read. This is the
-- only instrument available.
--
-- READ-ONLY with respect to the save: every sample is a throwaway clone, behind
-- the same gate arReproProbe uses. REMOVE with the other probes.
-- ============================================================================

local function hout(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[arHealth] " .. (ok and msg or tostring(fmt)))
end

-- One hour of the game's own health update, on a clone that is thrown away.
--
-- THE HEADCOUNT IS ALWAYS RESTORED FIRST. clone() copies identity but zeroes
-- numAnimals (11.9), and an empty cluster is exactly the thing a caller in the
-- base game would skip -- so a sweep that forgot this could measure "no
-- movement" and report a flat model when it had simply handed the game nothing
-- to update.
local function healthStep(cl, startHealth, f, head)
    local c = freshClone(cl)
    if c == nil or c.updateHealth == nil then return nil end
    c.numAnimals = (head ~= nil and head > 0) and head or 10
    c.health = startHealth
    local ok = pcall(c.updateHealth, c, f)
    if not ok then return nil end
    return c.health
end

-- The same call repeated on ONE clone, which is what makes it a trajectory
-- rather than N independent first steps.
local function healthTrajectory(cl, startHealth, f, hours, head)
    local c = freshClone(cl)
    if c == nil or c.updateHealth == nil then return nil end
    c.numAnimals = (head ~= nil and head > 0) and head or 10
    c.health = startHealth
    local path = { c.health }
    for _ = 1, hours do
        local ok = pcall(c.updateHealth, c, f)
        if not ok then return path end
        path[#path + 1] = c.health
    end
    return path
end

-- ---------------------------------------------------------------------------
-- SWEEP A -- the shape, and the threshold.
--
-- Start health is 50 so a single step can move either way without meeting a
-- bound: with the known +10 / -25 constants nothing clamps, and any sample that
-- DOES land exactly on 0 or 100 is excluded from the uniformity test rather than
-- being allowed to masquerade as a smaller step.
-- The subType's own health constants, so sweep A can CHECK ITS MEASUREMENT
-- against them instead of merely printing both and leaving the reader to
-- compare. Returns nil outside a running game, where the fit is simply skipped.
function AnimalFoodProbe.healthConsts(sti)
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil or asys.getSubTypeByIndex == nil or sti == nil then return nil end
    local okS, st = pcall(asys.getSubTypeByIndex, asys, sti)
    if not okS or type(st) ~= "table" then return nil end
    local inc, dec, thr = st.healthIncreaseHour, st.healthDecreaseHour, st.healthThresholdFactor
    if type(inc) ~= "number" or type(dec) ~= "number" or type(thr) ~= "number" then return nil end
    return inc, dec, thr, tostring(st.name)
end

function AnimalFoodProbe.sweepHealthRate(cl, head)
    local START_H = 50
    local FS = { 0.00, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30,
                 0.35, 0.40, 0.45, 0.50, 0.60, 0.80, 1.00 }

    hout("")
    hout("SWEEP A -- STEP SIZE vs FOOD FACTOR   (one hour, health starts at %d)", START_H)
    hout("  %8s %10s %10s %9s", "food f", "before", "after 1h", "delta")

    local pts = {}
    local ups, downs = {}, {}
    local moved, samples = 0, 0

    for _, f in ipairs(FS) do
        local after = healthStep(cl, START_H, f, head)
        if after == nil then
            hout("  %8.2f %10d %10s %9s", f, START_H, "-", "call failed")
        else
            samples = samples + 1
            local d = after - START_H
            if d ~= 0 then moved = moved + 1 end
            hout("  %8.2f %10d %10.2f %+9.2f", f, START_H, after, d)

            local clamped = (after <= 0) or (after >= 100)
            pts[#pts + 1] = { f = f, d = d, clamped = clamped }
            if d > 0 then
                if not clamped then ups[#ups + 1] = d end
            elseif d < 0 then
                if not clamped then downs[#downs + 1] = -d end
            end
        end
    end

    -- A DIAGNOSTIC THAT SAYS NOTHING IS EVIDENCE, AND IT MUST NOT READ AS A
    -- FINDING. Zero movement across every factor means the call is not doing what
    -- this probe assumes -- a different signature, a guard we have not met -- and
    -- reporting that as "the model is flat at zero" would be a wrong answer
    -- delivered with confidence.
    if samples == 0 then
        hout("")
        hout("  *** updateHealth() could not be called at all. Nothing was measured.")
        hout("  *** This is NOT a finding about the model -- see the dump above for")
        hout("  *** what the cluster actually exposes.")
        return nil, "UNCALLABLE"
    end
    if moved == 0 then
        hout("")
        hout("  *** health did not move at ANY food factor, on %d samples.", samples)
        hout("  *** The call ran, so the signature is probably right and something")
        hout("  *** ELSE gates it. Do NOT read this as a flat model.")
        return nil, "NO MOVEMENT"
    end

    local function uniform(t)
        if #t < 2 then return true, (t[1] or 0), (t[1] or 0) end
        local lo, hi = t[1], t[1]
        for _, v in ipairs(t) do
            if v < lo then lo = v end
            if v > hi then hi = v end
        end
        return (hi - lo) < 0.01, lo, hi
    end

    local upFlat, upLo, upHi = uniform(ups)
    local dnFlat, dnLo, dnHi = uniform(downs)

    hout("")
    if #ups > 0 then
        hout("  rises: %d sample(s), %.2f .. %.2f per hour", #ups, upLo, upHi)
    else
        hout("  rises: none -- no food factor tested held health up")
    end
    if #downs > 0 then
        hout("  falls: %d sample(s), %.2f .. %.2f per hour", #downs, dnLo, dnHi)
    else
        hout("  falls: none -- no food factor tested let health down")
    end

    -- THE VERDICT IS ABOUT THE RATE, AND ONLY THE RATE.
    --
    -- An earlier version had SCALED also assert "health settles part way and each
    -- mix sustains its own health". THAT DOES NOT FOLLOW and the first real run
    -- disproved it: the base game's step is scaled in the FOOD FACTOR and flat in
    -- HEALTH, so health does not settle at all -- it climbs at a constant rate to
    -- 100, and only the TIME TO GET THERE varies. Whether health settles is
    -- SWEEP C's question, because settling requires the step to depend on health.
    local verdict
    if #ups == 0 or #downs == 0 then
        verdict = "ONE-SIDED"
        hout("  every sample moved the same way: the sweep never crossed the threshold.")
        hout("  Widen FS -- the shape cannot be judged from only one side of it.")
    elseif upFlat and dnFlat then
        verdict = "FLAT"
        hout("  VERDICT: FLAT rate. The step does not vary with the food factor, so")
        hout("  every factor on one side moves health at the same speed.")
        hout("  Health is FREE above the threshold -- the recommendation is simply")
        hout("  'the cheapest mix that clears it'. Sweep C confirms the destination.")
    else
        verdict = "SCALED"
        hout("  VERDICT: SCALED rate. The step VARIES with the food factor, so a")
        hout("  richer mix moves health FASTER. That alone does NOT mean health")
        hout("  settles part way -- it settles only if the step also depends on")
        hout("  CURRENT health, which is sweep C. Read C before concluding.")
    end

    -- THE THRESHOLD IS THE SIGN CHANGE, NOT THE FIRST RISE.
    --
    -- The first version took the first f with delta > 0 and reported 0.30 for a
    -- subtype that declares 0.20 -- because the engine FLOORS the result, so the
    -- 0.625/h increment at f=0.25 truncates to zero and reads as "no rise". That
    -- overstated the threshold on every species. The sign change is the real
    -- boundary and it reproduces the declared value exactly.
    local thr, lastNeg = nil, nil
    for _, p in ipairs(pts) do
        if p.d >= 0 then
            if thr == nil then thr = p.f end
        elseif thr == nil then
            lastNeg = p.f
        end
    end

    if thr ~= nil then
        hout("")
        hout("  THRESHOLD (sign change): health stopped falling at f = %.2f", thr)
        if lastNeg ~= nil then
            hout("  and was still falling at %.2f, so it lies in (%.2f .. %.2f].",
                 lastNeg, lastNeg, thr)
        end
    end

    -- THE DEAD ZONE, and it is the finding with the sharpest consequence.
    --
    -- Between the threshold and the factor whose FLOORED increment first reaches
    -- 1, health neither decays nor recovers -- it freezes exactly where it is. A
    -- herd parked below the 0.75 breeding gate in that band never breeds again
    -- and never heals, while the barn shows no decline at all.
    local dzLo, dzHi = nil, nil
    for _, p in ipairs(pts) do
        if p.d == 0 then
            if dzLo == nil then dzLo = p.f end
            dzHi = p.f
        elseif p.d > 0 and dzLo ~= nil then
            break
        end
    end
    local firstRise = nil
    for _, p in ipairs(pts) do
        if p.d > 0 then firstRise = p.f; break end
    end
    if dzLo ~= nil and firstRise ~= nil and dzHi < firstRise then
        hout("")
        hout("  *** DEAD ZONE: f = %.2f .. %.2f moves health by ZERO per hour.", dzLo, dzHi)
        hout("  *** It neither decays nor recovers -- it FREEZES where it is, and")
        hout("  *** recovery only begins at f = %.2f. A herd stranded below the 0.75", firstRise)
        hout("  *** breeding gate in this band never breeds and never heals, while")
        hout("  *** the barn shows no decline to warn anyone.")
    end

    -- MODEL FIT. Two figures for one quantity must agree (5.27 / 5.28), so the
    -- measurement is checked against the subType's own constants rather than
    -- printed beside them and left to the reader.
    local inc, dec, dthr, sname = AnimalFoodProbe.healthConsts(cl.subTypeIndex)
    if inc ~= nil then
        hout("")
        hout("  MODEL FIT vs the declared constants (inc=%s dec=%s thr=%s)",
             tostring(inc), tostring(dec), tostring(dthr))
        local miss, worst, worstAt = 0, 0, nil
        for _, p in ipairs(pts) do
            if not p.clamped then
                local rate
                if p.f >= dthr then rate = inc * (p.f - dthr) / (1 - dthr)
                else                rate = -dec * (1 - p.f / dthr) end
                local pred = math.floor(START_H + rate) - START_H
                local e = math.abs(pred - p.d)
                if e > 0 then
                    miss = miss + 1
                    if e > worst then worst = e; worstAt = p.f end
                end
            end
        end
        if miss == 0 then
            hout("  CONFIRMED: floor(health + rate) reproduces all %d sample(s) exactly,", #pts)
            hout("  where rate = inc*(f-thr)/(1-thr) above the threshold and")
            hout("  -dec*(1-f/thr) below it. The flooring is what creates the dead zone.")
        else
            hout("  MISMATCH on %d of %d sample(s), worst %d at f=%.2f.",
                 miss, #pts, worst, worstAt or -1)
            hout("  This subtype does NOT follow the shared model -- something other")
            hout("  than the food factor is moving its health (horses carry dirt and")
            hout("  riding terms). Its feed advice cannot be derived from food alone.")
        end
    end

    return thr, verdict
end

-- ---------------------------------------------------------------------------
-- SWEEP B -- where it actually ends up, over a full day.
--
-- Sweep A gives the first step; this gives the resting point, which is the thing
-- the adviser needs. The factors are chosen AROUND the measured threshold rather
-- than fixed, so the two rows either side of it are always present whatever
-- species this is pointed at.
function AnimalFoodProbe.sweepHealthSettle(cl, thr, head)
    local HOURS = 24
    hout("")
    hout("SWEEP B -- WHERE HEALTH SETTLES   (%d hours on one clone, from 50)", HOURS)

    local FS = {}
    if thr ~= nil then
        for _, f in ipairs({ thr - 0.10, thr - 0.05, thr, thr + 0.05, thr + 0.20, 1.00 }) do
            if f >= 0 and f <= 1 then FS[#FS + 1] = f end
        end
    else
        FS = { 0.00, 0.20, 0.40, 0.60, 0.80, 1.00 }
    end

    hout("  %8s %8s %8s %8s %8s  %s", "food f", "h+1", "h+4", "h+12", "h+24", "reading")
    for _, f in ipairs(FS) do
        local path = healthTrajectory(cl, 50, f, HOURS, head)
        if path == nil then
            hout("  %8.2f  -- trajectory unavailable", f)
        else
            local function at(i) return path[i + 1] or path[#path] end
            local final = path[#path]
            local reading
            if final >= 99.99 then
                reading = "-> 100 (sustains full health)"
            elseif final <= 0.01 then
                reading = "-> 0 (collapses)"
            elseif math.abs(final - at(12)) < 0.01 then
                reading = string.format("settles at %.1f", final)
            else
                reading = string.format("still moving at %.1f", final)
            end
            hout("  %8.2f %8.1f %8.1f %8.1f %8.1f  %s", f, at(1), at(4), at(12), at(24), reading)
        end
    end
    hout("  A row that reaches 100 or 0 and stops is the FLAT model. A row that")
    hout("  stops somewhere in between is a genuine equilibrium and the adviser")
    hout("  has to model it.")
end

-- ---------------------------------------------------------------------------
-- SWEEP C -- does the step depend on CURRENT health?
--
-- The remaining way health could settle without the step varying by food factor:
-- an asymptotic approach, where the step shrinks as health nears its target. That
-- would read as FLAT in sweep A (which holds health at 50 throughout) and still
-- produce intermediate resting points, so sweep A alone cannot rule it out.
function AnimalFoodProbe.sweepHealthStart(cl, thr, head)
    hout("")
    hout("SWEEP C -- STEP SIZE vs CURRENT HEALTH   (one hour each)")

    local above = (thr ~= nil) and math.min(1.0, thr + 0.20) or 1.00
    local below = (thr ~= nil) and math.max(0.0, thr - 0.10) or 0.00
    local varies = false

    for _, pair in ipairs({ { above, "ABOVE threshold" }, { below, "BELOW threshold" } }) do
        local f, label = pair[1], pair[2]
        hout("  f = %.2f  (%s)", f, label)
        hout("    %8s %10s %9s", "health", "after 1h", "delta")
        local seen = {}
        for _, h in ipairs({ 20, 40, 60, 80 }) do
            local after = healthStep(cl, h, f, head)
            if after ~= nil then
                local d = after - h
                local bound = (after <= 0 or after >= 100) and "  (clamped)" or ""
                hout("    %8d %10.2f %+9.2f%s", h, after, d, bound)
                if bound == "" then seen[#seen + 1] = d end
            end
        end
        if #seen >= 2 then
            local lo, hi = seen[1], seen[1]
            for _, v in ipairs(seen) do
                if v < lo then lo = v end
                if v > hi then hi = v end
            end
            if (hi - lo) < 0.01 then
                hout("    constant across health -- no asymptote on this side.")
            else
                hout("    VARIES with health (%.2f .. %.2f) -- the approach is", lo, hi)
                hout("    asymptotic, so health settles even if sweep A read FLAT.")
                if label == "ABOVE threshold" then varies = true end
            end
        end
    end

    -- THE DESTINATION, which is what the adviser actually needs and which sweep A
    -- cannot answer. A step that varies with the FOOD FACTOR only changes how
    -- FAST health moves; it takes a step that varies with CURRENT HEALTH to make
    -- it stop anywhere short of a bound.
    hout("")
    if varies then
        hout("  DESTINATION: health SETTLES part way. Each mix sustains its own")
        hout("  level, so the adviser has to trade health against feed cost and")
        hout("  sweep B's settle column is the model it must carry.")
    else
        hout("  DESTINATION: health SATURATES. The step is independent of current")
        hout("  health, so above the threshold it climbs at a constant rate until")
        hout("  it reaches 100 and stops -- it never rests in between. A richer mix")
        hout("  buys SPEED, not a higher resting health, so health is free above the")
        hout("  threshold given time and the real trade is time-to-recover vs cost.")
    end
end

-- ---------------------------------------------------------------------------
function AnimalFoodProbe.runHealthProbe(fragment)
    hout("================= arHealthProbe =================")

    local rlOn, rlG, rlM = realisticLivestockActive()
    if rlOn or #rlM > 0 then
        hout("  *** RealisticLivestock IS ACTIVE (%s). It replaces the cluster class",
             joinList(rlM, 4))
        hout("  *** outright, so every figure below is RL's model, not the base game's.")
    else
        hout("  RealisticLivestock not detected: this is the BASE GAME.")
    end

    local barns = findAnimalBarns(fragment)
    if #barns == 0 then
        hout("  no husbandry matched. Nothing was touched.")
        return
    end

    local barn, name = barns[1].placeable, barns[1].name
    hout("  barn: %s  (farm=%s, %d animals)", name, tostring(barns[1].farm), barns[1].count)

    local clusters = nil
    if barn.getClusters ~= nil then
        local okC, c = pcall(barn.getClusters, barn)
        if okC then clusters = c end
    end
    if type(clusters) ~= "table" or countPairs(clusters) == 0 then
        hout("  it has no clusters. Pass a fragment naming a barn that holds animals.")
        return
    end

    local cl = nil
    for _, c in pairs(clusters) do cl = c; break end

    hout("")
    hout("SAFETY GATE  (nothing below runs unless clone() is proven independent)")
    local safe = AnimalFoodProbe.cloneIsSafe(cl)
    if not safe then
        hout("")
        hout("  ABORTED. No sweep was run and NO LIVE CLUSTER WAS TOUCHED.")
        hout("=================================================")
        return
    end

    local baseline = scalarFields(cl)
    local head = cl.numAnimals

    -- THE METHOD IS CHECKED BEFORE ANY SWEEP, and its absence is reported as an
    -- absence. Methods sit behind the protected metatable so they cannot be
    -- enumerated (10.5), but they ARE reachable by name -- so a nil here means
    -- the name is wrong, not that the object is opaque.
    hout("")
    if cl.updateHealth == nil then
        hout("  updateHealth is NOT present on this cluster.")
        hout("  Every sweep below needs it, so there is nothing to measure. The name")
        hout("  comes from PlaceableHusbandryAnimals.lua:598 (cluster:updateHealth")
        hout("  (foodFactor)); if that no longer holds, find the current name before")
        hout("  guessing at a replacement.")
        hout("=================================================")
        return
    end
    hout("  updateHealth is present. Calling it as cluster:updateHealth(foodFactor),")
    hout("  which is the form PlaceableHusbandryAnimals.lua:598 uses.")

    hout("")
    AnimalFoodProbe.dumpSubTypeConfig(cl.subTypeIndex)
    hout("  (the three health fields above are what 11.9 sampled; the sweeps below")
    hout("   measure the SHAPE those constants are used in, which it did not.)")

    local thr, verdict = AnimalFoodProbe.sweepHealthRate(cl, head)
    if verdict ~= "UNCALLABLE" and verdict ~= "NO MOVEMENT" then
        AnimalFoodProbe.sweepHealthSettle(cl, thr, head)
        AnimalFoodProbe.sweepHealthStart(cl, thr, head)
    end

    -- The gate tested ONE clone before the sweeps. This tests that ~60 clones and
    -- several hundred writes later the live cluster is still exactly as it was: a
    -- leak that only shows under repetition would pass the gate and still cost the
    -- player their herd.
    hout("")
    hout("FINAL CHECK  (the live cluster, after every sweep)")
    local now = scalarFields(cl)
    local moved = diffFields(baseline, now)
    if #moved == 0 then
        hout("    numAnimals=%s health=%s age=%s -- IDENTICAL to the pre-sweep read.",
             tostring(now.numAnimals), tostring(now.health), tostring(now.age))
        hout("  Nothing was bought, sold, bred, fed or aged. The save is untouched.")
    else
        hout("  *** THE LIVE CLUSTER MOVED. This is a bug in THIS PROBE, not the game:")
        for _, m in ipairs(moved) do hout("        %s", m) end
    end
    hout("=================================================")
end

function AnimalFoodProbe:consoleCommandHealth(fragment)
    local ok, err = pcall(AnimalFoodProbe.runHealthProbe, fragment)
    if not ok then return "arHealthProbe failed: " .. tostring(err) end
    return "arHealthProbe done -- see log.txt"
end
-- ============================================================================
-- arSellProbe -- CAN A MOD SELL ANIMALS WITHOUT REIMPLEMENTING THE TRANSACTION?
--
--   arSellProbe <barn fragment>        DRY RUN. Sells nothing. Reports the
--                                      controller, which way it points, the
--                                      items on each side and their prices.
--   arSellProbe <barn fragment> go     Attempts to sell ONE animal, measuring
--                                      money and headcount either side of it.
--
-- WHY THIS EXISTS. PlaceableHusbandryAnimals registers addCluster / addAnimals
-- and NO remove or sell, the cluster-system classes are absent from the shipped
-- SDK source entirely, and AnimalSellEvent's constructor cannot be read. So the
-- executor has exactly two options and only one of them is safe:
--
--   (a) hand-roll it -- cluster:changeNumAnimals(-n) plus addMoney plus dirty
--       flags plus MP sync. That reimplements the base game's own transaction,
--       and every part of it that is wrong loses the player animals or money
--       SILENTLY.
--   (b) drive the base game's OWN controller with no GUI attached. CLAUDE.md
--       10.6 already confirmed in game that setController(husbandry, nil, true)
--       gives a working per-barn SELL screen, so the transaction demonstrably
--       works; the only question is whether it can be reached headlessly.
--
-- This probe answers (b), and it is written to answer it WITHOUT betting the
-- player's herd on the answer: the default run mutates nothing at all.
--
-- THE THING IT MUST NOT ASSUME: which side is which. "Source" and "target" are
-- the screen's two columns, not "sell" and "buy" -- applySource may well be the
-- BUY path. That is why every run prints getSourceName / getTargetName and the
-- item count on each side BEFORE anything is applied.
--
-- Method presence is tested BY NAME through indexing, never pairs(): these
-- classes wear a protected metatable (10.5 / DR 6.12), so an empty enumeration
-- is not evidence of an empty object.
--
-- REMOVE with the other probes before release.
-- ============================================================================

local function sout(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[arSell] " .. (ok and msg or tostring(fmt)))
end

local CTRL_METHODS = {
    "getSourceItems", "getTargetItems", "getSourcePrice", "getTargetPrice",
    "getSourceName", "getTargetName", "getSourceActionText", "getTargetActionText",
    "applySource", "applyTarget", "applySourceBulk", "applyTargetBulk",
    "getMaxNumAnimals", "getSourceMaxNumAnimals", "getTargetMaxNumAnimals",
    "onAnimalsChanged", "validateSourceItem", "canApplySource",
    -- run 1: both item lists came back empty on a barn with 96 animals, so the list-building
    -- methods matter as much as the apply ones
    "initSourceItems", "initTargetItems", "initItems", "onOpen", "update", "refreshItems",
}

local ITEM_METHODS = {
    "getNumAnimals", "getSubTypeIndex", "getPrice", "getSellPrice", "getName",
    "getAge", "getHealth", "getCluster", "getClusterId", "getSupportsMerging",
}

---Which of `names` resolve on `o`. Indexing only -- see the protected-metatable note.
local function resolves(o, names)
    local yes, no = {}, {}
    for _, n in ipairs(names) do
        local ok, v = pcall(function() return o[n] end)
        if ok and type(v) == "function" then yes[#yes + 1] = n else no[#no + 1] = n end
    end
    return yes, no
end

local function joined(t, max)
    if #t == 0 then return "(none)" end
    local out = {}
    for i = 1, math.min(#t, max or 12) do out[i] = t[i] end
    if #t > (max or 12) then out[#out + 1] = string.format("... +%d", #t - (max or 12)) end
    return table.concat(out, ", ")
end

local function farmMoney(farmId)
    local fm = g_farmManager
    if fm ~= nil and fm.getFarmById ~= nil and farmId ~= nil then
        local ok, f = pcall(fm.getFarmById, fm, farmId)
        if ok and f ~= nil and f.money ~= nil then return f.money end
    end
    if g_currentMission ~= nil and g_currentMission.getMoney ~= nil then
        local ok, m = pcall(g_currentMission.getMoney, g_currentMission)
        if ok then return m end
    end
    return nil
end

---Describe one trade item without assuming anything about its shape.
local function describeItem(it, i)
    if type(it) ~= "table" then
        sout("    [%d] not a table (%s)", i, type(it)); return
    end
    local yes = resolves(it, ITEM_METHODS)
    local bits = {}
    for _, n in ipairs({ "getNumAnimals", "getAge", "getHealth", "getSubTypeIndex" }) do
        local okF, v = pcall(function() return it[n] end)
        if okF and type(v) == "function" then
            local ok2, r = pcall(v, it)
            if ok2 then bits[#bits + 1] = string.format("%s=%s", n:gsub("^get", ""), tostring(r)) end
        end
    end
    -- plain fields too: an item may carry data rather than accessors
    for _, k in ipairs({ "numAnimals", "subTypeIndex", "age", "health", "price", "name" }) do
        local okF, v = pcall(function() return it[k] end)
        if okF and v ~= nil and type(v) ~= "function" and type(v) ~= "table" then
            bits[#bits + 1] = string.format(".%s=%s", k, tostring(v))
        end
    end
    sout("    [%d] %s", i, #bits > 0 and table.concat(bits, "  ") or "(no readable fields)")
    sout("        resolves: %s", joined(yes, 10))
end

---Build a controller for this barn WITHOUT showing a GUI, trying each known route.
local function buildController(husb)
    -- route 1: the class directly. This is the one that matters -- it is what an
    -- executor would use, with no screen involved at all.
    if AnimalScreenDealerFarm ~= nil and AnimalScreenDealerFarm.new ~= nil then
        local ok, c = pcall(AnimalScreenDealerFarm.new, husb, nil, true)
        if ok and type(c) == "table" then return c, "AnimalScreenDealerFarm.new(husb, nil, true)" end
        local ok2, c2 = pcall(AnimalScreenDealerFarm.new, husb)
        if ok2 and type(c2) == "table" then return c2, "AnimalScreenDealerFarm.new(husb)" end
        sout("  AnimalScreenDealerFarm.new refused: %s", tostring(c))
    end
    -- route 2: let the screen build it, then borrow it without calling showGui.
    -- 10.6 confirmed setController works; this asks whether the controller alone
    -- is usable when the GUI is never shown.
    if g_animalScreen ~= nil and g_animalScreen.setController ~= nil then
        local ok = pcall(g_animalScreen.setController, g_animalScreen, husb, nil, true)
        if ok then
            for _, k in ipairs({ "controller", "animalController", "screenController" }) do
                local okF, v = pcall(function() return g_animalScreen[k] end)
                if okF and type(v) == "table" then
                    return v, "g_animalScreen:setController(...) -> ." .. k
                end
            end
            sout("  setController ran but no controller field was found on g_animalScreen")
        end
    end
    return nil, nil
end

function AnimalFoodProbe.runSell(fragment, mode, countArg, arg3Arg)
    local doIt = (mode ~= nil and tostring(mode):lower() == "go")
    -- applyTarget(item, N, X) SOLD ONE COW. Two things that run could not separate, because this
    -- farm is farm 1 and the winning shape was {item, 1, 1}:
    --   * is argument 2 the COUNT?   sell 2 and see whether the herd drops by 2
    --   * is argument 3 the FARM ID? pass a farm that does not exist and see if it still sells
    -- Both are answered by making them settable rather than by reasoning about them.
    local sellN = tonumber(countArg) or 1
    local arg3 = tonumber(arg3Arg)
    sout("count=%d  arg3=%s", sellN, arg3 ~= nil and tostring(arg3) or "(sweep)")
    sout("=== arSellProbe  (%s) ===", doIt and "LIVE -- will try to sell ONE animal"
                                            or "dry run -- nothing will be sold")

    -- 10.8: sample deliberately, and say what was sampled. Ordered by the player's
    -- own farm and then by headcount, so an empty map-owned shed is never the case
    -- the probe reports on.
    local myFarm = g_currentMission ~= nil and g_currentMission:getFarmId() or nil
    local barns = AnimalFoodProbe.findBarns(fragment)
    local rows = {}
    for _, b in ipairs(barns) do
        local p = b.placeable
        if p.getNumOfAnimals ~= nil then
            local okO, of = pcall(function() return p:getOwnerFarmId() end)
            local okN, n = pcall(p.getNumOfAnimals, p)
            rows[#rows + 1] = { p = p, name = b.name, n = (okN and n) or 0,
                                farm = okO and of or nil }
        end
    end
    table.sort(rows, function(a, b)
        local am = (a.farm == myFarm) and 1 or 0
        local bm = (b.farm == myFarm) and 1 or 0
        if am ~= bm then return am > bm end
        return a.n > b.n
    end)
    sout("barns found: %d   (player farm = %s)", #rows, tostring(myFarm))
    for i, r in ipairs(rows) do
        sout("  %d. %-38s farm=%-4s animals=%d", i, r.name, tostring(r.farm), r.n)
    end
    local pick = rows[1]
    if pick == nil or pick.n <= 0 then
        sout("no barn with animals matched '%s' -- nothing to probe", tostring(fragment))
        return
    end
    sout("probing: %s (%d animals, farm %s)", pick.name, pick.n, tostring(pick.farm))

    local husb = pick.p
    local ctrl, how = buildController(husb)
    if ctrl == nil then
        sout("NO CONTROLLER COULD BE BUILT. The headless route is not available and the")
        sout("executor would have to hand-roll the transaction -- report this line.")
        return
    end
    sout("controller built via %s", how)

    -- RUN 1 RETURNED "SOURCE items: 0 / TARGET items: 0" ON A BARN HOLDING 96 COWS. The controller
    -- constructs, but constructing is not opening: the GUI's own open path populates the two
    -- columns, and nothing had. The method names were already in front of us -- this file's own
    -- notes record RL overwriting AnimalScreenDealerFarm.initTargetItems -- so the lists are built
    -- by init*Items and a headless caller has to invoke them itself.
    local inited = {}
    for _, n in ipairs({ "initSourceItems", "initTargetItems", "initItems", "onOpen", "update" }) do
        local okF, f = pcall(function() return ctrl[n] end)
        if okF and type(f) == "function" then
            local ok, err = pcall(f, ctrl)
            inited[#inited + 1] = string.format("%s%s", n, ok and "" or "(threw: " .. tostring(err) .. ")")
        end
    end
    sout("  init calls: %s", #inited > 0 and table.concat(inited, ", ") or "(none resolved)")

    local yes, no = resolves(ctrl, CTRL_METHODS)
    sout("  resolves: %s", joined(yes, 18))
    sout("  lacks   : %s", joined(no, 18))

    -- WHICH WAY IS IT POINTING? source/target are the screen's two columns, and
    -- assuming source == sell is exactly the mistake this line exists to prevent.
    for _, pair in ipairs({ { "getSourceName", "source" }, { "getTargetName", "target" },
                            { "getSourceActionText", "source action" },
                            { "getTargetActionText", "target action" } }) do
        local okF, f = pcall(function() return ctrl[pair[1]] end)
        if okF and type(f) == "function" then
            local ok2, v = pcall(f, ctrl)
            sout("  %-14s = %s", pair[2], ok2 and tostring(v) or "?")
        end
    end

    local function dumpSide(getter, label)
        local okF, f = pcall(function() return ctrl[getter] end)
        if not okF or type(f) ~= "function" then sout("  %s: no %s", label, getter); return nil end
        local ok, items = pcall(f, ctrl)
        if not ok or type(items) ~= "table" then
            sout("  %s: %s returned %s", label, getter, ok and type(items) or "an error")
            return nil
        end
        sout("  %s items: %d", label, #items)
        for i = 1, math.min(#items, 4) do describeItem(items[i], i) end
        return items
    end
    local srcItems = dumpSide("getSourceItems", "SOURCE")
    local tgtItems = dumpSide("getTargetItems", "TARGET")

    -- price, asked both ways round for the first item we have
    for _, pair in ipairs({ { "getSourcePrice", srcItems }, { "getTargetPrice", tgtItems } }) do
        local getter, items = pair[1], pair[2]
        if items ~= nil and items[1] ~= nil then
            local okF, f = pcall(function() return ctrl[getter] end)
            if okF and type(f) == "function" then
                for _, args in ipairs({ { items[1], 1 }, { items[1] }, { 1, 1 } }) do
                    local ok, v = pcall(f, ctrl, unpack(args))
                    if ok then
                        sout("  %s(%d args) = %s", getter, #args, tostring(v))
                        break
                    end
                end
            end
        end
    end

    if not doIt then
        local items = tgtItems
        if items ~= nil and items[1] ~= nil then
            local okF, f = pcall(function() return ctrl.getTargetPrice end)
            if okF and type(f) == "function" then
                for _, n in ipairs({ 1, 2, 7 }) do
                    local packed = { pcall(f, ctrl, items[1], 1, n) }
                    local bits = {}
                    for i = 2, #packed do bits[#bits + 1] = tostring(packed[i]) end
                    sout("  getTargetPrice(item, 1, %d) -> %s%s", n,
                         packed[1] and "" or "ERROR ",
                         #bits > 0 and table.concat(bits, ", ") or "(nothing)")
                end
            end
            local okP, q = pcall(function() return items[1]:getPrice() end)
            sout("  item:getPrice() = %s   (the QUOTED figure; the realised one was 100 less each)",
                 okP and tostring(q) or "?")
        end
        sout("dry run complete. Re-run with 'go' to attempt ONE sale:  arSellProbe %s go",
             tostring(fragment or ""))
        return
    end

    -- ---- the live attempt ----------------------------------------------------
    -- ONE animal, and only from a barn that will still have animals afterwards.
    if pick.n <= sellN then
        sout("REFUSING to sell %d: the barn holds %d and the probe will not empty a pen", sellN, pick.n)
        return
    end
    -- MEASURED IN RUN 1, and it is the opposite of the natural reading:
    --     source = "Animal Dealer"  action "Buy"
    --     target = "Farm (96 / 96)" action "Sell"
    -- So applyTARGET is the sell path and applySource would BUY. This is exactly why the first
    -- run printed both names before touching anything -- an executor built on the assumption that
    -- "source" means "the animals I am selling" would have spent money instead of earning it.
    local items = tgtItems
    local side = "Target"
    if items == nil or #items == 0 then
        sout("  target side is empty; falling back to source (this would BUY -- refusing)")
        sout("  NOTHING APPLIED. Fix the init step first.")
        return
    end
    if items == nil or #items == 0 then
        sout("no items on either side -- nothing to apply")
        return
    end

    local moneyBefore = farmMoney(pick.farm)
    local countBefore = pick.n
    sout("BEFORE: animals=%d  money=%s  (applying to the %s side)",
         countBefore, tostring(moneyBefore), side)

    -- ---- WIRE THE FIVE CALLBACKS THE GUI SUPPLIES -------------------------------------------
    -- arSellDiff measured the difference between a headless controller and the one the game builds
    -- through setController: A had 7 own fields, B had 12, and the five extra are all functions.
    -- They are exactly what DealerFarm:131/136 was trying to call.
    --
    -- Supplied here as RECORDERS rather than no-ops: what the controller passes back is the only
    -- report we get on whether the sale actually completed, and errorCallback in particular is how
    -- the game says no. A silent success and a silent refusal look identical without them.

    local fired = {}
    local function recorder(name)
        return function(...)
            local n = select("#", ...)
            local bits = {}
            for i = 1, math.min(n, 4) do
                local v = select(i, ...)
                bits[#bits + 1] = type(v) == "table" and "table" or tostring(v)
            end
            fired[#fired + 1] = string.format("%s(%s)", name, table.concat(bits, ","))
            sout("  >> %s(%s)", name, table.concat(bits, ","))
        end
    end
    for _, cbName in ipairs({ "actionTypeCallback", "animalsChangedCallback", "errorCallback",
                             "sourceActionFinished", "targetActionFinished" }) do
        ctrl[cbName] = recorder(cbName)
    end
    sout("  wired 5 callbacks the GUI supplies (measured by arSellDiff)")

    -- WHAT RUN 2's ERRORS NARROWED IT TO, before guessing any further shapes:
    --   applyTarget(item)          -> DealerFarm:123 indexes NIL with 'getPrice'
    --   applyTarget(item, 1)       -> gets PAST that, into AnimalCluster:278, "mul on number and nil"
    --   applyTarget(item, 1, true) -> same line, "mul on number and boolean"
    -- So argument 3 is a NUMBER that is multiplied, and some price is nil. Both files are absent
    -- from the SDK source (10.1), so the remaining unknown is measured, not read: ask the item and
    -- the controller for the price directly and then feed it back in.
    local price, numAnimals = nil, nil
    for _, n in ipairs({ "getPrice", "getNumAnimals", "getClusterId", "getSubTypeIndex" }) do
        local okF, f = pcall(function() return items[1][n] end)
        if okF and type(f) == "function" then
            local ok, v = pcall(f, items[1])
            sout("  item:%s() = %s%s", n, tostring(v), ok and "" or "  (threw)")
            if n == "getPrice" and ok and type(v) == "number" then price = v end
            if n == "getNumAnimals" and ok and type(v) == "number" then numAnimals = v end
        end
    end
    do  -- does the item still carry its cluster? line 278 lives in AnimalCluster
        local okF, f = pcall(function() return items[1].getCluster end)
        if okF and type(f) == "function" then
            local ok, cl = pcall(f, items[1])
            sout("  item:getCluster() = %s", ok and type(cl) or "threw")
            if ok and type(cl) == "table" then
                for _, n in ipairs({ "getSellPrice", "getNumAnimals", "getAge" }) do
                    local ok2, g = pcall(function() return cl[n] end)
                    if ok2 and type(g) == "function" then
                        local ok3, v = pcall(g, cl)
                        sout("    cluster:%s() = %s", n, ok3 and tostring(v) or "threw")
                    end
                end
            end
        end
    end
    -- THE SIGNATURE IS applyTarget(item, itemIndex, numAnimals) -- measured, and the opposite of
    -- what the positions suggest: arg2 = 2 failed on a one-item list, while arg3 = 7 sold SEVEN.
    -- getTargetPrice takes the same shape, and it returned a bare `true` earlier because only the
    -- FIRST return value was captured. A price function that answers true is answering a different
    -- question, so take the whole tuple.
    --
    -- THIS IS READ-ONLY, so it runs in the DRY RUN as well: the realised price can be measured
    -- without selling anything, which is what the plan's revenue estimate needs. The item quotes
    -- 604.50 and the sale realised 504.50 EACH (confirmed by scaling 1 -> 7), so costing a plan
    -- from getSellPrice over-promises by 100 an animal.
    local pf = nil
    do
        local okF, f = pcall(function() return ctrl.getTargetPrice end)
        if okF and type(f) == "function" then pf = f end
    end
    if pf ~= nil and items ~= nil and items[1] ~= nil then
        for _, n in ipairs({ 1, 2, 7 }) do
            local packed = { pcall(pf, ctrl, items[1], 1, n) }
            if packed[1] then
                local bits = {}
                for i = 2, #packed do bits[#bits + 1] = tostring(packed[i]) end
                sout("  getTargetPrice(item, 1, %d) -> %s", n,
                     #bits > 0 and table.concat(bits, ", ") or "(no return values)")
            else
                sout("  getTargetPrice(item, 1, %d) -> %s", n, tostring(packed[2]))
            end
        end
    end

    local applied, via = false, nil
    -- run 1: applySourceBulk / applyTargetBulk do NOT exist on this controller. Only the singular
    -- forms resolve, so a multi-line plan is applied one call at a time.
    for _, name in ipairs({ "apply" .. side }) do
        local okF, f = pcall(function() return ctrl[name] end)
        if okF and type(f) == "function" then
            -- the signature cannot be read, so try the plausible shapes and let the
            -- ERROR TEXT name the expected arguments when they are wrong
            local shapes
            if arg3 ~= nil then
                shapes = { { items[1], sellN, arg3 } }
            else
            shapes = {
                { items[1], 1, 1 },                 -- arg3 as a plain number: the shape the errors point at
                { items[1], 1, price },             -- ...or the price the item just reported
                { items[1], price, 1 },
                { items[1], 1, pick.farm },         -- ...or a farmId
                { items[1], 1, 1, pick.farm },
                { items[1], numAnimals, 1 },
                { 1, items[1] },                    -- reversed, in case count comes first
                { items[1], 1 },                    -- the run-2 shape, kept so the log stays comparable
            }
            end
            for _, args in ipairs(shapes) do
                local holed = false
                for i = 1, #args do if args[i] == nil then holed = true end end
                if holed then
                    sout("  %s: skipping a shape with a nil in it (unpack would truncate the call)", name)
                else
                    local ok, err = pcall(f, ctrl, unpack(args))
                    if ok then
                        applied, via = true, string.format("%s(%d args)", name, #args)
                        break
                    end
                    local desc = {}
                    for i = 1, #args do desc[i] = type(args[i]) end
                    sout("  %s(%s) -> %s", name, table.concat(desc, ","), tostring(err))
                end
            end
        end
        if applied then break end
    end

    if #fired > 0 then
        sout("callbacks fired: %s", table.concat(fired, "  "))
    else
        sout("callbacks fired: (none) -- the controller never reported back")
    end
    if not applied then
        sout("NO APPLY CALL SUCCEEDED -- see the errors above; they usually name the arguments")
        return
    end
    sout("applied via %s", via)

    local okN, countAfter = pcall(husb.getNumOfAnimals, husb)
    local moneyAfter = farmMoney(pick.farm)
    sout("AFTER : animals=%s  money=%s", okN and tostring(countAfter) or "?", tostring(moneyAfter))
    if okN and type(countAfter) == "number" then
        local dN = countBefore - countAfter
        if dN > 0 and moneyBefore ~= nil and moneyAfter ~= nil then
            local got = moneyAfter - moneyBefore
            sout("ECONOMICS: sold %d for %.2f = %.2f each; the item quoted %.2f each (delta %.2f each, %.2f total)",
                 dN, got, got / dN, price or -1, (price or 0) - got / dN, (price or 0) * dN - got)
        end
        sout("VERDICT: headcount %+d, money %s",
             countAfter - countBefore,
             (moneyBefore ~= nil and moneyAfter ~= nil)
                 and string.format("%+.2f", moneyAfter - moneyBefore) or "?")
        if countAfter < countBefore and moneyAfter ~= nil and moneyBefore ~= nil
           and moneyAfter > moneyBefore then
            sout("=> HEADLESS SELL WORKS. The executor can drive this controller directly.")
        elseif countAfter < countBefore then
            sout("=> animals left but the money did not move: this call is a MOVE/REMOVE, not a sale.")
        else
            sout("=> the call returned cleanly and changed nothing. Wrong side, or it needs the GUI.")
        end
    end
end

function AnimalFoodProbe:consoleCommandSell(fragment, mode, countArg, arg3Arg)
    local ok, err = pcall(AnimalFoodProbe.runSell, fragment, mode, countArg, arg3Arg)
    if not ok then return "arSellProbe failed: " .. tostring(err) end
    return "arSellProbe done -- see log.txt"
end

-- ============================================================================
-- arSellDiff -- WHAT DOES THE GUI SET THAT A HEADLESS CONTROLLER LACKS?
--
--   arSellDiff <barn fragment>
--
-- Run 3 established that the argument list is no longer the problem. With a
-- plausible count, applyTarget reaches AnimalScreenDealerFarm lines 131 / 136 and
-- then "attempts to call a nil value" -- it is reaching for state that a
-- constructed-but-never-opened controller does not have. getTargetPrice fails the
-- same way at :165.
--
-- So this stops permuting arguments and asks the only question left: build a
-- controller the way the WORKING path does (g_animalScreen:setController, which
-- 10.6 confirmed in game) and compare it, field by field, against one built
-- directly. Whatever is a FUNCTION on the working one and nil on ours is what
-- those lines are calling.
--
-- Neither controller is applied to anything. This probe sells nothing and mutates
-- nothing; it does not even show a GUI.
--
-- METHOD NOTE: these classes wear a protected metatable (10.5), so pairs() may
-- report nothing at all. Enumeration is attempted AND a candidate name list is
-- probed by INDEXING, because indexing is the access that works. A name missing
-- from the enumeration is not evidence of a missing field.
-- ============================================================================

local function dout(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[arSellDiff] " .. (ok and msg or tostring(fmt)))
end

-- Everything the GUI plausibly hands a controller. Probed by name, not guessed at
-- from an enumeration that a protected metatable would leave empty.
local FIELD_CANDIDATES = {
    "screen", "gui", "owner", "delegate", "target", "source", "dealer",
    "farm", "farmId", "husbandry", "trailer", "animalScreen", "list",
    "sourceItems", "targetItems", "items", "isDealer", "mode", "direction",
    "onAnimalsChangedCallback", "callback", "updateCallback", "onApply",
    "onBuy", "onSell", "onApplyCallback", "errorCallback", "confirmCallback",
    "numAnimals", "selectedItem", "selectedIndex", "maxNumAnimals",
}

local function ownFields(o)
    local names, n = {}, 0
    pcall(function()
        for k, v in pairs(o) do
            n = n + 1
            if type(k) == "string" then names[k] = type(v) end
        end
    end)
    return names, n
end

---type of o[name], by indexing -- the access that survives a protected metatable
local function slot(o, name)
    local ok, v = pcall(function() return o[name] end)
    if not ok then return "?" end
    if v == nil then return nil end
    return type(v)
end

function AnimalFoodProbe.runSellDiff(fragment)
    dout("=== arSellDiff -- nothing is sold, nothing is shown ===")

    local myFarm = g_currentMission ~= nil and g_currentMission:getFarmId() or nil
    local best, bestN = nil, -1
    for _, b in ipairs(AnimalFoodProbe.findBarns(fragment)) do
        local p = b.placeable
        if p.getNumOfAnimals ~= nil then
            local okO, of = pcall(function() return p:getOwnerFarmId() end)
            local okN, n = pcall(p.getNumOfAnimals, p)
            n = (okN and n) or 0
            if (not okO or of == myFarm) and n > bestN then best, bestN = p, n end
        end
    end
    if best == nil then dout("no barn matched '%s'", tostring(fragment)); return end
    local nm = select(2, pcall(function() return best:getName() end))
    dout("barn: %s (%d animals)", tostring(nm), bestN)

    -- ---- A: the headless route we have been using --------------------------
    local A = nil
    if AnimalScreenDealerFarm ~= nil and AnimalScreenDealerFarm.new ~= nil then
        local ok, c = pcall(AnimalScreenDealerFarm.new, best, nil, true)
        if ok and type(c) == "table" then A = c end
    end
    if A == nil then dout("could not construct a headless controller at all"); return end
    for _, n in ipairs({ "initSourceItems", "initTargetItems", "initItems" }) do
        local okF, f = pcall(function() return A[n] end)
        if okF and type(f) == "function" then pcall(f, A) end
    end
    dout("A = AnimalScreenDealerFarm.new(husb, nil, true) + init*  -- built")

    -- ---- B: the route the game itself uses ---------------------------------
    -- 10.6 confirmed setController + showGui gives a WORKING sell screen. showGui
    -- is deliberately NOT called; if the difference turns out to be something only
    -- showGui sets, that is itself the answer.
    local B, whereB = nil, nil
    if g_animalScreen ~= nil and g_animalScreen.setController ~= nil then
        local ok, err = pcall(g_animalScreen.setController, g_animalScreen, best, nil, true)
        dout("B: setController -> %s", ok and "ok" or tostring(err))
        if ok then
            -- named guesses first, then a sweep of g_animalScreen for anything
            -- carrying applyTarget -- the controller identifies itself by what it can do
            for _, k in ipairs({ "controller", "animalController", "screenController", "ctrl" }) do
                if slot(g_animalScreen, k) == "table" then B, whereB = g_animalScreen[k], k; break end
            end
            if B == nil then
                local names = ownFields(g_animalScreen)
                for k, t in pairs(names) do
                    if t == "table" then
                        local cand = g_animalScreen[k]
                        if slot(cand, "applyTarget") == "function" then B, whereB = cand, k; break end
                    end
                end
            end
        end
    end
    if B == nil then
        dout("NO controller could be found on g_animalScreen after setController.")
        dout("=> the GUI keeps it somewhere this probe cannot see, OR only showGui builds it.")
        dout("   Dumping g_animalScreen's own fields so the next run knows where to look:")
        local names, n = ownFields(g_animalScreen or {})
        dout("   enumerated %d field(s)", n)
        for k, t in pairs(names) do dout("     .%s : %s", k, t) end
        return
    end
    dout("B found at g_animalScreen.%s", whereB)
    dout("A == B ? %s", tostring(A == B))

    -- ---- the diff ----------------------------------------------------------
    local aNames, aN = ownFields(A)
    local bNames, bN = ownFields(B)
    dout("enumerated own fields: A=%d  B=%d  (0 means a protected metatable, not an empty object)", aN, bN)

    local seen = {}
    for k in pairs(aNames) do seen[k] = true end
    for k in pairs(bNames) do seen[k] = true end
    for _, k in ipairs(FIELD_CANDIDATES) do seen[k] = true end

    local sorted = {}
    for k in pairs(seen) do sorted[#sorted + 1] = k end
    table.sort(sorted)

    local missing, differ = {}, {}
    for _, k in ipairs(sorted) do
        local ta, tb = slot(A, k), slot(B, k)
        if ta ~= tb then
            local line = string.format("%s: A=%s  B=%s", k, tostring(ta), tostring(tb))
            if ta == nil and tb ~= nil then missing[#missing + 1] = line
            else differ[#differ + 1] = line end
        end
    end

    dout("--- PRESENT ON B, ABSENT ON A  (this is the answer if anything is here) ---")
    if #missing == 0 then dout("   (nothing)") end
    for _, l in ipairs(missing) do dout("   %s", l) end
    dout("--- present on both but a different type ---")
    if #differ == 0 then dout("   (nothing)") end
    for _, l in ipairs(differ) do dout("   %s", l) end

    -- Does B actually work where A did not? The decisive check, and still read-only:
    -- getTargetPrice fails on A at :165 in exactly the way applyTarget fails at 131/136.
    for _, pair in ipairs({ { "A", A }, { "B", B } }) do
        local label, c = pair[1], pair[2]
        local okF, f = pcall(function() return c.getTargetItems end)
        local cnt = "?"
        if okF and type(f) == "function" then
            local ok, items = pcall(f, c)
            cnt = (ok and type(items) == "table") and tostring(#items) or "err"
            if ok and type(items) == "table" and items[1] ~= nil then
                local okP, pf = pcall(function() return c.getTargetPrice end)
                if okP and type(pf) == "function" then
                    local ok2, v = pcall(pf, c, items[1], 1)
                    dout("%s: getTargetPrice(item,1) -> %s", label, tostring(v))
                end
            end
        end
        dout("%s: getTargetItems -> %s item(s)", label, cnt)
    end
end

function AnimalFoodProbe:consoleCommandSellDiff(fragment)
    local ok, err = pcall(AnimalFoodProbe.runSellDiff, fragment)
    if not ok then return "arSellDiff failed: " .. tostring(err) end
    return "arSellDiff done -- see log.txt"
end

-- ============================================================================
-- arOutputCurve   -- TEMPORARY DEV PROBE
--
-- WHAT IT ANSWERS. CLAUDE.md 14.4 asked whether base FS25 gates animal output by
-- AGE, and predicted it does not. THE SOURCE SAYS IT DOES, and the prediction was
-- wrong. Every output spec computes its rate the same way, and all four files
-- measure COMPLETE (19-24% blank), so this is read, not inferred:
--
--     local age             = cluster:getAge()
--     local litersPerAnimal = <curve>:get(age)
--     local litersPerDay    = litersPerAnimal * cluster:getNumAnimals()
--     spec.litersPerHour    = spec.litersPerHour + (litersPerDay / 24)
--
--   PlaceableHusbandryMilk:onHusbandryAnimalsUpdate          subType.output.milk.curve
--   PlaceableHusbandryPallets:onHusbandryAnimalsUpdate       subType.output.pallets.curve
--   PlaceableHusbandryLiquidManure:onHusbandryAnimalsUpdate  subType.output.liquidManure
--   PlaceableHusbandryStraw:onHusbandryAnimalsUpdate         subType.output.manure
--                                                     AND    subType.input.straw
--
-- So output is not a maturity THRESHOLD, it is a curve -- the same shape as the
-- price curve -- and STRAW INTAKE is age-curved too, so a young animal is cheaper
-- to bed as well as less productive.
--
-- SO WHY PROBE AT ALL. Three things reading cannot settle:
--
--   1. THE CURVE SHAPES IN *THIS* INSTALL. A map or a mod may replace the subtype
--      definitions, so a dev-time read of animals.xml is not knowledge of what is
--      running -- the same argument AnimalSellRules.priceCurve makes for sampling
--      the price curve live rather than tabulating it.
--   2. THE INTERFACE. AnimCurve.lua is 93% BLANK (1 surviving function) in the
--      shipped SDK source, so curve:get(age) cannot be read and its behaviour off
--      the end of the defined range is unknown. CLAUDE.md 8.1: an absence there
--      proves nothing, so fall back to a probe.
--   3. THE TWO SHAPES OF subType.output. milk and pallets are TABLES carrying a
--      .curve and a .fillType; liquidManure, manure and straw ARE the curve.
--      Assuming one shape yields nil on the other SILENTLY -- so this walks the
--      tables and asks each value what it is rather than hardcoding either.
--
-- IT REPRODUCES THE ENGINE'S OWN ARITHMETIC AND COMPARES (DR 5.54c). Predicting
-- spec.litersPerHour from the curves and checking it against the live field is
-- what turns "I read the source and think this is the mechanism" into a
-- confirmation. A probe that does not compute what the code computes can
-- eliminate hypotheses without ever confirming one.
--
-- READ ONLY, AND NO CLONES. The curve hangs off the SUBTYPE, not the cluster, and
-- get() is a lookup the base game already performs every hour -- so unlike the
-- price sweep this needs no clone gate and touches no cluster. Nothing here can
-- age, re-price or re-count a single animal.
--
-- Usage (needs game.xml development controls true):
--     arOutputCurve                  -- every husbandry holding animals
--     arOutputCurve <name fragment>  -- barns whose name contains this
--
-- REMOVE once the earnings model is settled.
-- ============================================================================

local function oc(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[arOutputCurve] " .. (ok and msg or tostring(fmt)))
end

---A curve, whatever shape it was declared in. Returns curve, fillType, shape.
-- The shape is REPORTED so a modded subtype declaring a third form names itself
-- instead of being silently skipped.
function AnimalFoodProbe.asCurve(v)
    if type(v) ~= "table" then return nil, nil, "not a table" end
    if type(v.get) == "function" then return v, nil, "bare curve" end
    if type(v.curve) == "table" and type(v.curve.get) == "function" then
        return v.curve, v.fillType, "wrapper (.curve/.fillType)"
    end
    return nil, nil, "table with no get() and no .curve"
end

---Sample one curve across age. Fine at the young end, because WHERE OUTPUT
-- STARTS is the whole maturity question; coarse after, where it only plateaus.
function AnimalFoodProbe.sampleCurve(curve)
    local ages = {}
    for a = 0, 24 do ages[#ages + 1] = a end
    for a = 27, 72, 3 do ages[#ages + 1] = a end

    local s, peakAge, peakVal, onset = {}, nil, nil, nil
    for _, a in ipairs(ages) do
        local ok, v = pcall(curve.get, curve, a)
        if ok and type(v) == "number" then
            s[#s + 1] = { age = a, v = v }
            if v > 0 and onset == nil then onset = a end
            if peakVal == nil or v > peakVal then peakAge, peakVal = a, v end
        end
    end
    if #s < 2 then return nil end

    local declines, lowAfter = false, peakVal
    for _, e in ipairs(s) do
        if e.age > peakAge and e.v < lowAfter then lowAfter, declines = e.v, true end
    end
    local flat = true
    for _, e in ipairs(s) do
        if math.abs(e.v - s[1].v) > 1e-6 then flat = false; break end
    end

    return { samples = s, onsetAge = onset, peakAge = peakAge, peakVal = peakVal,
             declines = declines, lowestAfterPeak = lowAfter, flat = flat }
end

function AnimalFoodProbe.printCurve(c, ftName)
    if c == nil then oc("    (could not sample)"); return end
    if ftName ~= nil then oc("    fill type: %s", tostring(ftName)) end

    if c.flat then
        oc("    FLAT at %.4f per animal per day -- age does not affect this output",
            c.samples[1].v)
    else
        oc("    onset age %s   peak %.4f at age %d   %s",
            c.onsetAge ~= nil and tostring(c.onsetAge) or "NEVER (zero at every sampled age)",
            c.peakVal, c.peakAge,
            c.declines and string.format("DECLINES to %.4f", c.lowestAfterPeak)
                        or "no decline after peak")
    end

    -- The young end in full: this is the maturity lag, if there is one.
    local line = "    by age: "
    for _, e in ipairs(c.samples) do
        if e.age <= 24 then line = line .. string.format("%d=%.3f ", e.age, e.v) end
    end
    oc("%s", line)
end

function AnimalFoodProbe.runOutputCurve(fragment)
    oc("=== output vs age, read only ===")
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if ps == nil or asys == nil then oc("no mission yet"); return end

    local seenSubType = {}
    local barns = 0

    for _, p in ipairs(ps.placeables) do
        if p.spec_husbandryAnimals ~= nil then
            local name = "?"
            local okN, n = pcall(function() return p:getName() end)
            if okN and n ~= nil then name = tostring(n) end

            if fragment == nil or fragment == ""
               or string.find(string.lower(name), string.lower(fragment), 1, true) ~= nil then
                barns = barns + 1
                local okC, clusters = pcall(p.getClusters, p)
                if not okC or type(clusters) ~= "table" then clusters = {} end

                oc("")
                oc("---------------------------------------------------------------")
                oc("BARN %s   clusters=%d", name, #clusters)

                -- predicted litersPerHour, accumulated exactly as the engine does
                local predMilk, predPallet = {}, {}
                local predSlurry, predStrawIn, predManure = 0, 0, 0

                for _, cl in ipairs(clusters) do
                    local sti = cl.subTypeIndex
                    local okS, st = pcall(asys.getSubTypeByIndex, asys, sti)
                    if not okS then st = nil end
                    local age, cnt = cl.age or 0, cl.numAnimals or 0
                    oc("  cluster: %s  age=%s months  n=%d  health=%s",
                        st ~= nil and tostring(st.name) or ("subtype " .. tostring(sti)),
                        tostring(age), cnt, tostring(cl.health))

                    if st ~= nil then
                        local function acc(v)
                            local curve, ft = AnimalFoodProbe.asCurve(v)
                            if curve == nil then return nil, nil end
                            local ok, per = pcall(curve.get, curve, age)
                            if not ok or type(per) ~= "number" then return nil, ft end
                            return per * cnt / 24, ft
                        end

                        local o = st.output or {}
                        local i = st.input or {}
                        local v, ft

                        v, ft = acc(o.milk)
                        if v ~= nil then predMilk[ft or 0] = (predMilk[ft or 0] or 0) + v end
                        v, ft = acc(o.pallets)
                        if v ~= nil then predPallet[ft or 0] = (predPallet[ft or 0] or 0) + v end
                        v = acc(o.liquidManure); if v ~= nil then predSlurry  = predSlurry  + v end
                        v = acc(o.manure);       if v ~= nil then predManure  = predManure  + v end
                        v = acc(i.straw);        if v ~= nil then predStrawIn = predStrawIn + v end

                        -- one full curve dump per SUBTYPE, not per cluster
                        if not seenSubType[sti] then
                            seenSubType[sti] = true
                            oc("  --- curves for %s (sampled once) ---", tostring(st.name))
                            local kinds = {
                                { "output.milk",         o.milk },
                                { "output.pallets",      o.pallets },
                                { "output.liquidManure", o.liquidManure },
                                { "output.manure",       o.manure },
                                { "input.straw",         i.straw },
                            }
                            for _, k in ipairs(kinds) do
                                if k[2] ~= nil then
                                    local curve, ftIdx, shape = AnimalFoodProbe.asCurve(k[2])
                                    if curve == nil then
                                        oc("  %s: UNRECOGNISED SHAPE (%s)", k[1], shape)
                                    else
                                        local ftn = nil
                                        if ftIdx ~= nil and g_fillTypeManager ~= nil then
                                            local okF, f = pcall(g_fillTypeManager.getFillTypeByIndex,
                                                                 g_fillTypeManager, ftIdx)
                                            if okF and f ~= nil then ftn = f.title or f.name end
                                        end
                                        oc("  %s  [%s]", k[1], shape)
                                        AnimalFoodProbe.printCurve(AnimalFoodProbe.sampleCurve(curve), ftn)
                                    end
                                end
                            end
                            -- Every OTHER output key, so a modded output nobody has
                            -- named here is visible rather than invisible.
                            local extra = {}
                            for key in pairs(o) do
                                if key ~= "milk" and key ~= "pallets"
                                   and key ~= "liquidManure" and key ~= "manure" then
                                    extra[#extra + 1] = tostring(key)
                                end
                            end
                            if #extra > 0 then
                                oc("  OTHER output keys present: %s", table.concat(extra, ", "))
                            end
                        end
                    end
                end

                -- ---- THE CONFIRMATION: predicted vs the barn's own field -----
                oc("  --- predicted litersPerHour vs the live spec ---")
                local function cmp(label, pred, actual)
                    if actual == nil then
                        oc("    %-26s predicted %10.4f   (no live field to compare)", label, pred)
                        return
                    end
                    local d = math.abs(pred - actual)
                    oc("    %-26s predicted %10.4f   actual %10.4f   %s",
                        label, pred, actual,
                        d < 0.0001 and "MATCH" or string.format("DIFF %.4f", d))
                end

                local sm = p.spec_husbandryMilk
                if sm ~= nil and type(sm.litersPerHour) == "table" then
                    for ft, v in pairs(predMilk) do
                        cmp("milk ft=" .. tostring(ft), v, sm.litersPerHour[ft])
                    end
                    for ft, v in pairs(sm.litersPerHour) do
                        if predMilk[ft] == nil then
                            cmp("milk ft=" .. tostring(ft) .. " unpredicted", 0, v)
                        end
                    end
                end

                local sp = p.spec_husbandryPallets
                if sp ~= nil and type(sp.litersPerHour) == "table" then
                    for ft, v in pairs(predPallet) do
                        cmp("pallets ft=" .. tostring(ft), v, sp.litersPerHour[ft])
                    end
                    for ft, v in pairs(sp.litersPerHour) do
                        if predPallet[ft] == nil then
                            cmp("pallets ft=" .. tostring(ft) .. " unpredicted", 0, v)
                        end
                    end
                end

                local sl = p.spec_husbandryLiquidManure
                if sl ~= nil then cmp("liquidManure", predSlurry, sl.litersPerHour) end

                local ss = p.spec_husbandryStraw
                if ss ~= nil then
                    cmp("straw IN", predStrawIn, ss.inputLitersPerHour)
                    cmp("manure OUT", predManure, ss.outputLitersPerHour)
                end
            end
        end
    end

    if barns == 0 then oc("no husbandry matched '%s'", tostring(fragment)) end
    oc("=== done ===")
end

function AnimalFoodProbe:consoleCommandOutputCurve(fragment)
    local ok, err = pcall(AnimalFoodProbe.runOutputCurve, fragment)
    if not ok then return "arOutputCurve failed: " .. tostring(err) end
    return "arOutputCurve done -- see log.txt"
end
