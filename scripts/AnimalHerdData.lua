-- ============================================================================
-- AnimalHerdData.lua  (Husbandry Redux) -- the barn reader
--
-- MOVED OUT OF THE ORIGINAL PAGE, not copied, when a second tab wanted the same
-- picture of a barn -- its food factor, its groups, its herd. Husbandry Redux had
-- already been bitten once by keeping two copies of a display helper (DR 5.69,
-- which promoted setStorageBar out of a GUI file for exactly this reason, after
-- the duplicated version caused three regressions).
--
-- THE SECOND TAB IS NOW THE ONLY TAB (20.28) and this is still a MODULE rather
-- than a page method. That is what made the retirement a deletion instead of a
-- salvage: the data layer never lived in the page that was removed, so nothing
-- had to be rescued out of it.
--
-- Everything here is READ-ONLY on the game. AnimalFeedModel.measureFactor
-- snapshots and restores fillLevels on every path, so measuring a barn's factor
-- does not feed it.
-- ============================================================================

AnimalHerdData = {}

---Headcount-weighted herd health, 0..1. WEIGHTED, because a barn of 200 healthy
-- animals and 10 starving ones is not "half sick" -- and the breeding gate is
-- per CLUSTER, so an unweighted mean would misreport both.
function AnimalHerdData.herdHealthFactor(clusters)
    if type(clusters) ~= "table" then return nil end
    local sum, counted = 0, 0
    for _, c in ipairs(clusters) do
        local n = c.numAnimals or 0
        sum = sum + (c.health or 0) * n
        counted = counted + n
    end
    if counted <= 0 then return nil end
    return (sum / counted) / 100
end

local function l10n(key, fallback)
    if HusbandryRedux ~= nil and HusbandryRedux.l10n ~= nil then return HusbandryRedux.l10n(key, fallback) end
    return fallback
end

local function ftName(ft)
    local m = g_fillTypeManager
    if m ~= nil and m.getFillTypeNameByIndex ~= nil then
        local ok, n = pcall(m.getFillTypeNameByIndex, m, ft)
        if ok and n ~= nil then return tostring(n) end
    end
    return "?"
end

function AnimalHerdData.readBarn(p)
    local spec = p.spec_husbandryFood
    if spec == nil or AnimalFeedModel == nil then return nil end

    local name = "?"
    local okN, n = pcall(function() return p:getName() end)
    if okN and n ~= nil then name = tostring(n) end

    local ati = AnimalFeedModel.animalTypeIndexOf(p)
    if ati == nil then return nil end
    local model = AnimalFeedModel.read(ati, spec.supportedFillTypes)

    -- The barn's REAL appetite. Measuring at anything else misreports a healthy
    -- trough as starved, which an earlier version of the console probe did.
    local demand = AnimalFeedModel.demandPerHour(p)
    local hasAnimals = demand > 0

    -- WHAT THE ANIMALS CAN EAT, not merely what has been delivered. A grazing barn
    -- has meadow grass that never reaches the trough (measured: a cow barn holding
    -- only hay and silage still reported 828 L of grass available), and showing 0
    -- against an engine factor of 0.40 was the contradiction that exposed it.
    local everyFt = {}
    if model ~= nil then
        for _, g in ipairs(model.groups) do
            for _, ft in ipairs(g.fts) do everyFt[#everyFt + 1] = ft end
        end
    end
    local trough, held = AnimalFeedModel.availableOf(p, everyFt)
    -- THE TROUGH MAP, not just its total. `trough` above is AVAILABILITY (pool + meadow,
    -- via getAvailableFood) despite its name; the two have to be kept apart now that the
    -- PRODUCED table separates what the barn grew from what the farm delivered. The
    -- grazed share of a product is availability MINUS trough, which is the same
    -- arithmetic feedCostPerHour already does to avoid charging for pasture.
    local troughMap, delivered = AnimalFeedModel.troughOf(p)
    local engine, modelF = nil, nil
    if model ~= nil and hasAnimals then
        engine = select(1, AnimalFeedModel.measureFactor(p, ati, trough, demand))
        modelF = AnimalFeedModel.factorOf(model, trough, demand)
    end

    local groups = {}
    if model ~= nil then
        local eatSum = 0
        for _, g in ipairs(model.groups) do eatSum = eatSum + g.eat end
        for _, g in ipairs(model.groups) do
            local gHeld = 0
            for _, ft in ipairs(g.fts) do gHeld = gHeld + (trough[ft] or 0) end
            -- SERIAL: one tier feeds the whole herd, so its need is the full demand.
            -- PARALLEL: each group supplies its eat share.
            local need = 0
            if hasAnimals then
                if model.consumptionType == "SERIAL" then need = demand
                elseif eatSum > 0 then need = demand * g.eat / eatSum end
            end
            local met = 1
            if need > 0 then met = math.min(1, gHeld / need) end
            local names = {}
            for _, ft in ipairs(g.fts) do
                if spec.supportedFillTypes == nil or spec.supportedFillTypes[ft] ~= nil then
                    names[#names + 1] = ftName(ft)
                end
            end
            groups[#groups + 1] = {
                title = g.title, need = need, held = gHeld, met = met,
                contributes = g.production * met, max = g.production,
                fts = g.fts,      -- the PRODUCTS that satisfy this group
                accepts = table.concat(names, ", "),
            }
        end
    end

    -- ---- PRODUCTIVITY, the base game's own headline -------------------------
    -- productivity = globalProductionFactor x productionFactor, exactly as
    -- PlaceableHusbandryAnimals:getConditionInfos computes it. This is NOT the
    -- food factor: food is one input to it, so a barn can be perfectly fed and
    -- still be at 60% for a reason nothing else on this tab would show.
    --
    -- The base game HIDES this for horses and pigs (they do not produce
    -- continuously), so it is flagged rather than silently presented as
    -- meaningful for them.
    local prod = nil
    if p.getGlobalProductionFactor ~= nil and p.getProductionFactor ~= nil then
        local okG, gf = pcall(p.getGlobalProductionFactor, p)
        local okP, pf = pcall(p.getProductionFactor, p)
        if okG and okP and type(gf) == "number" and type(pf) == "number" then
            prod = gf * pf
        end
    end
    local prodApplies = true
    if AnimalType ~= nil and ati ~= nil then
        prodApplies = (ati ~= AnimalType.HORSE and ati ~= AnimalType.PIG)
    end

    -- ---- HERD: how many, and how healthy ------------------------------------
    local numAnimals, maxAnimals, health = nil, nil, nil
    if p.getNumOfAnimals ~= nil then
        local okN, v = pcall(p.getNumOfAnimals, p); if okN then numAnimals = v end
    end
    if p.getMaxNumOfAnimals ~= nil then
        local okM, v = pcall(p.getMaxNumOfAnimals, p); if okM then maxAnimals = v end
    end
    if p.getClusters ~= nil then
        local okC, clusters = pcall(p.getClusters, p)
        if okC and type(clusters) == "table" and #clusters > 0 then
            health = AnimalHerdData.herdHealthFactor(clusters)
        end
    end

    -- ---- THE GAME'S OWN CONDITION LIST --------------------------------------
    -- One call gives water, bedding, output stores and productivity, already
    -- titled and normalised, from six specs at once. Rendered generically, so an
    -- entry this mod has never heard of (a modded husbandry's own) still shows.
    local conditions = {}
    if p.getConditionInfos ~= nil then
        local okI, infos = pcall(p.getConditionInfos, p)
        if okI and type(infos) == "table" then
            for _, i in ipairs(infos) do
                if type(i) == "table" then
                    conditions[#conditions + 1] = {
                        title = tostring(i.title or "?"),
                        value = tonumber(i.value),
                        valueText = i.valueText,
                        ratio = tonumber(i.ratio),
                        -- invertedBar means a HIGH reading is the bad one, which is
                        -- how a backing-up output store is expressed
                        inverted = i.invertedBar == true,
                    }
                end
            end
        end
    end

    local SD = HusbandryRedux ~= nil and HusbandryRedux.DR or nil
    local uid = (SD ~= nil and SD.assetUid ~= nil) and SD.assetUid(p) or tostring(p)

    -- A MEADOW IS A FOOD SOURCE THE TROUGH DOES NOT SHOW. PlaceableHusbandryMeadow
    -- overrides getAvailableFood / removeFood / getFoodInfos, so grazed grass
    -- reaches consumeFood without ever passing through spec_husbandryFood
    -- .fillLevels. That is why a cow barn can read every group at 0 L and still
    -- score 0.40: the herd is eating the pasture, and 0.40 is the Grass tier.
    -- Reported rather than hidden -- the numbers are right, they just are not the
    -- whole story, and a contradiction on screen is worse than a caveat.
    -- A MEADOW IS NOT NECESSARILY GRAZEABLE: a cosmetic paddock declares one with no
    -- <fruitType>, leaving spec.fruitTypeInfos empty. Measured across the base game plus
    -- every installed mod: 37 cosmetic against 70 grazeable (DR 5.75 / 5.85).
    local grazes = AnimalFeedModel.grazeableOf(p)

    -- FEEDING ROBOT. A robot barn keeps its ingredients in per-fill-type bunkers and
    -- only ever puts the MIXED product in the trough, so without these three the barn
    -- reads as holding nothing but TMR and the whole ration is costed against a product
    -- the farm never bought.
    local robotBunkers = AnimalFeedModel.robotBunkersOf(p)
    local hasRobot = next(robotBunkers) ~= nil
    local mixedFt = hasRobot and AnimalFeedModel.mixedFillTypeOf(p) or nil
    local ingredientRates = hasRobot and AnimalFeedModel.robotIngredientRates(p, demand) or {}

    return { placeable = p, uid = uid, name = name, model = model, demand = demand,
             trough = trough,  -- ft -> litres AVAILABLE (pool + meadow), so a pane can go per PRODUCT
             troughMap = troughMap,          -- ft -> litres DELIVERED (the pool alone)
             hasRobot = hasRobot, robotBunkers = robotBunkers,
             mixedFt = mixedFt, ingredientRates = ingredientRates,
             -- SERIAL means ONE tier feeds the whole herd (a cow's TMR / Silage /
             -- Hay / Grass are alternatives); PARALLEL means every group
             -- contributes. Which it is decides what is actually being EATEN.
             serial = (model ~= nil and model.consumptionType == "SERIAL"),
             hasAnimals = hasAnimals, held = held, delivered = delivered,
             engine = engine, modelF = modelF, grazes = grazes, groups = groups,
             prod = prod, prodApplies = prodApplies, numAnimals = numAnimals,
             maxAnimals = maxAnimals, health = health, conditions = conditions }
end

-- ---------------------------------------------------------------------------
-- OWNERSHIP, AR'S OWN. These existed only on DR until the mod went standalone,
-- and every one of the gates below was written to fail OPEN when DR was missing
-- -- correct while DR was always installed, because the fallback could then only
-- fire in a broken state. The moment DR became OPTIONAL that fallback became the
-- PRIMARY path, and "fail open" means "no ownership filter at all": a standalone
-- player saw every husbandry on the map, including map-owned pens they do not
-- have. Reported in game as three chicken pastures where the farm owns one.
--
-- THE GENERAL SHAPE, worth remembering: a fallback written for a can't-happen
-- case becomes the common path the day the dependency it guards turns optional.

---The local player's farm, or nil when it cannot be resolved.
--
-- 0 IS SPECTATOR AND IS NOT A FARM (DR 5.47). It is a real number, so a `~= nil`
-- test hands it back happily and it then matches no building at all -- which on a
-- dedicated server silently empties the list. Callers read nil as "no preference"
-- and show everything, which is the safe direction for a display.
function AnimalHerdData.playerFarmId()
    local m = g_currentMission
    if m == nil then return nil end
    local f
    if m.getFarmId ~= nil then
        local ok, r = pcall(m.getFarmId, m)
        if ok and type(r) == "number" then f = r end
    end
    if f == nil and m.player ~= nil then f = m.player.farmId end
    if f == nil and g_localPlayer ~= nil then f = g_localPlayer.farmId end
    if f == nil then f = m.playerFarmId end
    if type(f) ~= "number" or f == 0 then return nil end
    return f
end

---The owner farm of a placeable, or nil. Method first, then the field.
function AnimalHerdData.ownerFarmId(p)
    if p == nil then return nil end
    if p.getOwnerFarmId ~= nil then
        local ok, f = pcall(p.getOwnerFarmId, p)
        if ok and f ~= nil then return f end
    end
    return p.ownerFarmId
end

---May `farmId` use this barn?
--
-- DR's `_farmCanUse` additionally allows PUBLIC MAP STORAGE, which any farm may
-- use because it is nobody's (DR 5.63) -- deliberately NOT ported, because that
-- rule is gated on `spec_silo` and so can never fire for a husbandry. For this
-- class of building the two are equivalent, which is what lets DR's own answer be
-- preferred when it is there without the two ever disagreeing.
function AnimalHerdData.farmCanUse(p, farmId)
    if farmId == nil then return true end       -- unknown farm: fail open
    local of = AnimalHerdData.ownerFarmId(p)
    return of == nil or of == farmId
end


---Order a list by the name the player SEES, in their own language.
--
-- `table.sort` on strings compares BYTES, so an accented or non-Latin name sorts outside the
-- alphabet being read -- and every barn name here comes from the player or from a translation.
-- Distribution Redux carries a collation table for exactly this, so it is used WHEN PRESENT.
--
-- CAPABILITY, NOT PRESENCE, and the fallback is deliberate rather than defensive (31.3): with no
-- DR this degrades to the byte order it has always used, which is a cosmetic difference in a
-- list that is still sorted. That is why this borrows rather than porting DistributionSort --
-- unlike the GUI profiles (31.2) or the panel (31.4), nothing here fails SILENTLY or looks
-- broken without it.
--
-- Reached through DR_ENV, not SmartDistribution: DistributionSort is a global in DR's own
-- environment and is not hung off that table.
function AnimalHerdData.sortByName(list, nameOf, idOf)
    if type(list) ~= "table" or #list < 2 then return list end
    nameOf = nameOf or function(e) return e.name end
    idOf   = idOf   or function(e) return e.uid end

    local env = HusbandryRedux ~= nil and HusbandryRedux.DR_ENV or nil
    local DS  = (type(env) == "table") and env.DistributionSort or nil
    if DS ~= nil and DS.less ~= nil then
        local ok = pcall(table.sort, list, function(a, b)
            return DS.less(nameOf(a), idOf(a), nameOf(b), idOf(b))
        end)
        if ok then return list end
    end

    -- Byte order, with the id as a stable second key so two identically named barns cannot swap
    -- places between rebuilds (table.sort is not stable).
    table.sort(list, function(a, b)
        local na, nb = tostring(nameOf(a) or ""), tostring(nameOf(b) or "")
        if na ~= nb then return na < nb end
        return tostring(idOf(a) or "") < tostring(idOf(b) or "")
    end)
    return list
end


-- ---------------------------------------------------------------------------
---Every husbandry THIS FARM manages, read and named. Moved here for the same
-- reason readBarn was: both tabs must list the same buildings, and two copies of
-- an enrolment rule is two chances to disagree about which barns exist.
--
-- TWO DIFFERENT QUESTIONS, and only one of them may fail open:
--   isAssetEnrolled  participation, and DR's Animal Husbandry class toggle. A DR
--                    SETTING, so with no DR there is nothing to be excluded by and
--                    true is the right answer. Fails open, correctly.
--   ownership        NOT DR's question. AR now answers it itself when DR is absent
--                    (see farmCanUse above) instead of skipping the test, which is
--                    what listed every map-owned pen on a standalone install.
-- DR's answer is PREFERRED when DR is there, so both mods installed shows exactly
-- the set DR manages and the two can never drift; the two agree for husbandries in
-- any case, since DR's extra map-storage branch needs a spec_silo.
function AnimalHerdData.enumerate()
    local barns = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return barns end

    local SD = HusbandryRedux ~= nil and HusbandryRedux.DR or nil

    -- IF/ELSE, NOT `a and b or c`, on both of these. DR's _farmCanUse legitimately
    -- returns FALSE for a building this farm does not own, and the collapsing form
    -- would then fall through to AR's own test and ask the question twice -- the
    -- trap this pair of codebases has been bitten by more than once (DR 5.44 /
    -- 5.46c), and here it would silently restore the very bug being fixed.
    local myFarm
    if SD ~= nil and SD._playerFarmId ~= nil then
        myFarm = SD._playerFarmId()
    else
        myFarm = AnimalHerdData.playerFarmId()
    end

    -- ONE ROW PER PLACEABLE. Guarding on identity rather than trusting the list:
    -- a building appearing twice would be a counting fault, and showing it twice
    -- is exactly what gets mistaken for the farm really having two of them.
    local seen = {}
    for _, p in ipairs(ps.placeables) do
        if p.spec_husbandryFood ~= nil and seen[p] == nil then
            local enrolled = SD == nil or SD.isAssetEnrolled == nil or SD.isAssetEnrolled(p)
            local usable
            if SD ~= nil and SD._farmCanUse ~= nil then
                usable = SD._farmCanUse(p, myFarm)
            else
                usable = AnimalHerdData.farmCanUse(p, myFarm)
            end
            if enrolled and usable then
                seen[p] = true
                local b = AnimalHerdData.readBarn(p)
                if b ~= nil then barns[#barns + 1] = b end
            end
        end
    end

    -- DUPLICATE NAMES get a " (n)" suffix, DR's convention (5.7), numbered by
    -- uniqueId rather than list position so a building keeps its number as others
    -- are built or demolished around it.
    local byName = {}
    for _, b in ipairs(barns) do
        local g = byName[b.name]
        if g == nil then g = {}; byName[b.name] = g end
        g[#g + 1] = b
    end
    for name, group in pairs(byName) do
        if #group > 1 then
            table.sort(group, function(x, y) return tostring(x.uid) < tostring(y.uid) end)
            for i, b in ipairs(group) do b.name = string.format("%s (%d)", name, i) end
        end
    end

    AnimalHerdData.sortByName(barns)
    return barns
end

-- ---------------------------------------------------------------------------
---The picture the BUY / SELL screen shows for this breed at this age.
--
-- `animalSystem:getVisualByAge(subTypeIndex, age)` is what the base game itself
-- uses to pick an animal's appearance -- PlaceableHusbandryAnimals, Rideable and
-- LivestockTrailer all call it -- and the visual carries a `.store` item. So the
-- icon is AGE-AWARE for free: a calf and a cow are different pictures, which is
-- what makes it worth showing beside a group at all.
--
-- VERIFIED, NOT TRUSTED. Every candidate goes through DR's own
-- `iconFileUsable`, which checks the file exists AND rejects the base game's
-- blank placeholder tile - 5.71 measured four productions declaring
-- `store_empty.png` and rendering as a solid white square. A declared image is
-- not a present one.
---THE PICTURE OUT OF A VISUAL'S `store` TABLE, wherever that visual came from.
--
-- Split out because a visual is reachable two ways: the animal system resolves one
-- from a (subTypeIndex, age) pair, and a DEALER ITEM carries its own. Both end at the
-- same store table, so the key order and the usability check belong in ONE place --
-- otherwise the two lists agree about a picture only by coincidence.
--
-- 5.71 is why each candidate is verified rather than taken: four Montana productions
-- DECLARE the base game's blank placeholder tile and rendered as solid white squares.
function AnimalHerdData.iconFromStore(st)
    if type(st) ~= "table" then return nil end
    local SD = HusbandryRedux ~= nil and HusbandryRedux.DR or nil
    local usable = (SD ~= nil and SD.iconFileUsable) or function(f) return f ~= nil end
    for _, key in ipairs({ "imageFilename", "imageFilenameSmall", "iconFilename" }) do
        local f = st[key]
        if type(f) == "string" and f ~= "" then
            local okU, good = pcall(usable, f)
            if okU and good then return f end
        end
    end
    return nil
end

function AnimalHerdData.animalIconFile(subTypeIndex, ageMonths)
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil or asys.getVisualByAge == nil or subTypeIndex == nil then return nil end
    local ok, visual = pcall(asys.getVisualByAge, asys, subTypeIndex, ageMonths or 0)
    if not ok or type(visual) ~= "table" then return nil end
    return AnimalHerdData.iconFromStore(visual.store)
end

---The BUILDING picture, through DR's own ordered chain rather than a second copy
-- of it. 5.71: a DECLARED image is not a PRESENT one -- four Montana productions
-- name the base game's blank placeholder tile and rendered as solid white squares
-- -- so the resolver walks customImageFilename -> store image -> production point
-- -> product icon and verifies each with textureFileExists. Reusing it means this
-- list and DR's own building lists can never disagree about a barn's picture.
function AnimalHerdData.barnIconFile(p)
    local SD = HusbandryRedux ~= nil and HusbandryRedux.DR or nil
    if SD == nil or SD.assetIconFile == nil or p == nil then return nil end
    local ok, f = pcall(SD.assetIconFile, p)
    if ok and type(f) == "string" and f ~= "" then return f end
    return nil
end

---The HUD icon for a fill type, the same field DR reads for its own fill icons.
function AnimalHerdData.fillIconFile(ft)
    local m = g_fillTypeManager
    if m == nil or ft == nil or m.getFillTypeByIndex == nil then return nil end
    local ok, def = pcall(m.getFillTypeByIndex, m, ft)
    if not ok or type(def) ~= "table" then return nil end
    return def.hudOverlayFilename or def.hudOverlayFilenameSmall
end

-- ---------------------------------------------------------------------------
---The subtype record behind a cluster's INDEX.
--
-- `AnimalSellRules.assess` puts `subTypeIndex` on every cluster record and NOT
-- the subtype itself, so anything wanting the output curves has to resolve it.
-- Reading `c.subType` off that record silently yields nil, which is how the
-- production pane came up empty on every barn and L/DAY read a dash on every
-- group -- one cause, two symptoms, and neither of them errors.
function AnimalHerdData.subTypeOf(subTypeIndex)
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil or asys.getSubTypeByIndex == nil or subTypeIndex == nil then return nil end
    local ok, st = pcall(asys.getSubTypeByIndex, asys, subTypeIndex)
    if ok and type(st) == "table" then return st end
    return nil
end

---The animal TYPE a barn holds (COW, SHEEP...), which is one level above the
-- subtype a cluster carries. `spec.animalTypeIndex` is set by the base game's own
-- load from `spec.animalType.typeIndex`, so it is the building's declaration
-- rather than anything inferred from what happens to be standing in it -- an
-- empty barn still knows what it is for.
---Returns index, display name -- or nil, nil where the spec does not answer.
function AnimalHerdData.animalTypeOf(p)
    local spec = p ~= nil and p.spec_husbandryAnimals or nil
    local idx = spec ~= nil and spec.animalTypeIndex or nil
    if idx == nil and spec ~= nil and type(spec.animalType) == "table" then
        idx = spec.animalType.typeIndex
    end
    if idx == nil then return nil, nil end

    -- The type's own name where the build exposes one; the barn's declared type
    -- table is tried first because it is already in hand.
    local nm = nil
    if type(spec.animalType) == "table" then
        nm = spec.animalType.name or spec.animalType.typeName
    end
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if nm == nil and asys ~= nil and asys.getTypeByIndex ~= nil then
        local ok, t = pcall(asys.getTypeByIndex, asys, idx)
        if ok and type(t) == "table" then nm = t.name or t.typeName end
    end
    return idx, nm ~= nil and tostring(nm) or nil
end

-- ---------------------------------------------------------------------------
---What one animal of this subtype produces per DAY at this age, per output.
-- Reads the same declaration AnimalEconomics does, so the two cannot disagree
-- about a curve: 14.4 measured every output as age-curved, and matched the live
-- `spec.litersPerHour` on 17 rows of 17.
--
-- MILK AND EGGS ARE A CLIFF (nothing, then the full rate); MANURE, SLURRY AND
-- STRAW RAMP FROM BIRTH. So a young group reports a real, honest zero for milk
-- while still making manure -- which is the distinction no current screen draws.
local OUTPUTS = { { key = "milk", cliff = true }, { key = "pallets", cliff = true },
                  { key = "liquidManure" }, { key = "manure" } }

---`allowed` is an AnimalEconomics.producibleOutputKeys set, or nil to keep every
-- declared output. AN ANIMAL'S DECLARATION IS NOT A BUILDING'S CAPABILITY: a cow
-- declares output.liquidManure wherever it stands, but a barn with no
-- <liquidManure> block has no slurry spec and never makes a drop of it.
function AnimalHerdData.outputRates(subType, ageMonths, allowed)
    local out = {}
    if type(subType) ~= "table" or AnimalEconomics == nil then return out end
    local o = subType.output or {}
    for _, spec in ipairs(OUTPUTS) do
        local decl = o[spec.key]
        if allowed ~= nil and allowed[spec.key] ~= true then decl = nil end
        if decl ~= nil then
            local perDay = AnimalEconomics.perAnimalPerDay(decl, ageMonths or 0)
            if perDay ~= nil then
                -- MILK AND PALLETS name their fill type; MANURE, SLURRY AND STRAW
                -- do not -- their declaration IS the curve (15.6's two shapes), so
                -- curveOf returns nil for the type and the row rendered as "?".
                -- fillTypeForKey exists for exactly this and was simply not used.
                local _, ft = AnimalEconomics.curveOf(decl)
                if ft == nil and AnimalEconomics.fillTypeForKey ~= nil then
                    ft = AnimalEconomics.fillTypeForKey(spec.key)
                end
                out[#out + 1] = { key = spec.key, perDay = perDay, fillType = ft,
                                  cliff = spec.cliff == true }
            end
        end
    end
    return out
end

-- `AnimalHerdData.inputRates` LIVED HERE AND IS GONE. It listed everything in
-- subType.input, food included, and only avoided double-counting the ration
-- because `food` resolves no fill type and fell through a guard meant for
-- something else. AnimalEconomics.declaredInputRates replaces it and excludes food
-- BY NAME, which is the difference between an accident and a rule -- and it is the
-- same rate source the costing uses, so a table and a total cannot disagree.

---Litres per animal per day of ONE output key, or nil when it is not declared.
function AnimalHerdData.ratePerAnimal(subType, ageMonths, key, allowed)
    for _, r in ipairs(AnimalHerdData.outputRates(subType, ageMonths, allowed)) do
        if r.key == key then return r.perDay, r.fillType end
    end
    return nil, nil
end


---How much of `ft` this husbandry is holding. THE STANDALONE ANSWER; DR's assetHeld is preferred
-- wherever it is available (see HerdInspectorPage:buildProductionRows).
--
-- WHY THIS IS AN APPROXIMATION AND SAYS SO. DR's assetHeld is exact because DR does the bookkeeping:
-- for a pallet-spawning pen it folds the pad and the pending queue into one figure (DR 5.21), and
-- while DR is running it OWNS spec_husbandryPallets.fillLevels and writes the full stock there
-- (DR 5.32) rather than vanilla's litres-on-pallets. Reading the specs from outside can reach the
-- same numbers but cannot reproduce that ownership, so the two may differ slightly for a pallet
-- output while DR is installed -- which is exactly why DR's figure wins when it exists.
--
-- THREE SOURCES, IN THE ORDER A PRODUCT CAN LIVE IN THEM:
--   * husbandryFood  -- per fill type since DR 5.68 established fillLevels is keyed BY TYPE and not
--                       a barn total. Feed rather than output, but the caller does not know that.
--   * husbandryPallets -- fillLevels (what is on pallets) PLUS pendingLiters (the internal queue a
--                       pen fills before releasing a whole pallet). Both, because a pen's stock is
--                       pad + queue and reporting either alone reads as half the product vanishing.
--   * the placeable's own storages -- milk and slurry, which are Storage-backed and in neither spec.
--
-- Returns nil, never 0, when nothing can answer: the column then shows blank rather than asserting
-- that a barn holds nothing, which is a different and much stronger claim.
function AnimalHerdData.heldOf(placeable, ft)
    if placeable == nil or ft == nil then return nil end
    local total, found = 0, false

    local fs = placeable.spec_husbandryFood
    if fs ~= nil and type(fs.fillLevels) == "table" and fs.fillLevels[ft] ~= nil then
        total = total + (fs.fillLevels[ft] or 0); found = true
    end

    local ps = placeable.spec_husbandryPallets
    if ps ~= nil then
        if type(ps.fillLevels) == "table" and ps.fillLevels[ft] ~= nil then
            total = total + (ps.fillLevels[ft] or 0); found = true
        end
        if type(ps.pendingLiters) == "table" and ps.pendingLiters[ft] ~= nil then
            total = total + (ps.pendingLiters[ft] or 0); found = true
        end
    end

    -- Storage-backed outputs (milk, liquid manure). getAllStorages is DR's helper and we have no
    -- equivalent, so read the specs that actually carry a storage and dedupe on identity: the same
    -- Storage object is reachable from more than one spec, and summing it twice would double the
    -- figure (DR 5.77 records exactly that on a pass-through store).
    local seen = {}
    for _, key in ipairs({ "spec_husbandryMilk", "spec_husbandryLiquidManure", "spec_silo" }) do
        local spec = placeable[key]
        local list = spec ~= nil and (spec.storages or (spec.storage ~= nil and { spec.storage } or nil)) or nil
        for _, st in ipairs(list or {}) do
            if st ~= nil and not seen[st] and type(st.fillLevels) == "table" and st.fillLevels[ft] ~= nil then
                seen[st] = true
                total = total + (st.fillLevels[ft] or 0); found = true
            end
        end
    end

    if not found then return nil end
    return total
end
