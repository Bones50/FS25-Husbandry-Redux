-- ============================================================================
-- AnimalSellRules.lua  (Husbandry Redux)
--
-- WHAT TO SELL, AND WHY. Layer 1 of three: this decides, persistence stores the
-- player's thresholds, and the executor carries it out. Both of those drive THIS,
-- so it is written to be pure and testable -- it reads the world and returns a
-- plan, and mutates nothing.
--
-- EVERY RULE HERE RESTS ON A MEASURED FACT (CLAUDE.md 11):
--   * value  = curve(ageMonths) x (0.40 + 0.60 x health).  Confirmed to 0.00000
--     across seven health points, and the age curve reproduced to the cent.
--   * THERE IS NO SEASONAL PRICE. "Sell at peak" means peak AGE, never peak
--     month, so nothing here waits for a market.
--   * a breeding cluster produces ONE OFFSPRING PER ANIMAL and DOUBLES.
--   * both breeding gates are cliffs: below minAgeMonth or below
--     minHealthFactor (0.75) nothing happens AND the counter is not advanced,
--     so a gated herd is frozen, not losing progress.
--   * A FULL PEN IS THE ONLY THING THAT DESTROYS ANYTHING. Births beyond the
--     free slots are discarded and the gestation is spent with them. Underfeeding
--     merely pauses.
--
-- THE RULE THAT FALLS OUT OF THAT, and it is not the one you would guess:
-- headroom outranks price. Selling below peak costs the DIFFERENCE; letting a
-- full pen breed costs whole animals plus a whole cycle. So a headroom sale is
-- allowed to lose money, and a peak sale never is.
--
-- PURE. No mutation, no money, no events, no GUI. Give it a placeable and a
-- config and it returns a plan; the caller decides whether to show it or do it.
-- ============================================================================

AnimalSellRules = {}

-- Deliberately conservative, and AUTO IS OFF. This module can propose selling a
-- player's herd; nothing acts on that until it is explicitly switched on.
AnimalSellRules.DEFAULTS = {
    enabled         = false,   -- auto-sell. OFF until the player says otherwise.
    keepFreeSlots   = -1,      -- -1 = derive it: enough for next cycle's births
    sellAtPeak      = true,    -- sell an animal that will only lose value from here
    minHealthToSell = 0.75,    -- do not realise a herd at 46% of book value
    keepBreeders    = 0,       -- never take the herd below this many breeding animals
    headroomWorthIt = true,    -- a headroom sale must be worth more than it costs
    sellCalves      = false,   -- run the barn as a NURSERY: sell every newborn
}

-- HEADROOM CAN NEVER TAKE MORE THAN THIS FRACTION OF A HERD.
-- The arithmetic below already guarantees it (a breeder sold closes the gap by
-- two, so the requirement is at most half the herd), but the failure it guards
-- against is total -- a plan that empties a pen leaves no breeders, so the
-- headroom it bought is never used by anything. Asserted rather than assumed.
AnimalSellRules.HEADROOM_MAX_FRACTION = 0.5

AnimalSellRules.REASON_HEADROOM = "headroom"
AnimalSellRules.REASON_PEAK     = "peak"

-- THE THIRD REASON, and it exists because a slot has a THIRD use. Births with
-- nowhere to go are DISCARDED by the base game, so every rule here was written
-- around a pen that can only hold producers. Sell the newborn instead and the
-- slot becomes a NURSERY -- one sale per breeding cycle, forever, from an animal
-- that never matures and never produces. See AnimalEconomics.slotVerdict.
AnimalSellRules.REASON_CALF     = "calf"

-- THE EARNINGS TEST REFINES RULE 2, IT DOES NOT ADD A THIRD RULE.
-- "Past peak" alone says an animal will never be worth MORE than it is now. It
-- does not say holding it is a loss: a Holstein past peak still milks 150 L/day
-- for ever (14.4 -- no output curve declines) against 13.9/month of capital drift,
-- so selling it destroys a stream to avoid a much smaller decline. AnimalEconomics
-- answers which of the two is bigger, and a peak sale now has to clear that bar.
-- With the module absent or unable to price the output, the pre-earnings behaviour
-- stands unchanged -- an unpriceable animal is not an animal worth nothing.
AnimalSellRules.REASON_EARNINGS = "earnings"

-- ---------------------------------------------------------------------------
local function subTypeOf(sti)
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil or asys.getSubTypeByIndex == nil or sti == nil then return nil end
    local ok, st = pcall(asys.getSubTypeByIndex, asys, sti)
    if ok and type(st) == "table" then return st end
    return nil
end

local function priceOf(cl)
    if cl == nil or cl.getSellPrice == nil then return nil end
    local ok, v = pcall(cl.getSellPrice, cl)
    if ok and type(v) == "number" then return v end
    return nil
end

-- ---------------------------------------------------------------------------
-- THE PRICE CURVE, derived from the RUNNING GAME rather than from a table.
--
-- The shipped animals.xml carries every curve, but reading it at dev time is not
-- the same as knowing what THIS install is running: a map or a mod may replace
-- the definitions, and RealisticLivestock replaces the cluster class outright.
-- So the curve is measured, once per subtype, by asking a CLONE what it would be
-- worth at each age. That works for a modded animal nobody has ever seen.
--
-- CLONE ONLY, AND GATED. cluster:clone() is used exactly as arReproProbe uses
-- it, and for the same reason: a write to a live cluster would change the
-- player's herd. The gate proves the clone is independent before any sweep and
-- refuses everything if it is not -- a clone that forwards writes to the original
-- would silently age or re-price real animals.
local _curveCache = {}

function AnimalSellRules.cloneIsSafe(cl)
    if cl == nil or cl.clone == nil then return nil end
    local before = { n = cl.numAnimals, h = cl.health, a = cl.age }
    local ok, cp = pcall(cl.clone, cl)
    if not ok or type(cp) ~= "table" or cp == cl then return nil end

    -- THE CANARIES ARE DERIVED FROM THE CURRENT VALUES, never constants.
    -- With fixed canaries the gate has a blind spot that a harness found: a
    -- write-through clone leaves the ORIGINAL holding the canary values, so the
    -- NEXT call writes the same numbers, sees no change, and passes the very
    -- clone it just rejected. Offsetting from whatever the original holds now
    -- means the canary can never already be there.
    local wantAge, wantHealth = (before.a or 0) + 1000, (before.h or 0) + 1000
    pcall(function() cp.age, cp.health = wantAge, wantHealth end)
    if cp.age ~= wantAge or cp.health ~= wantHealth then return nil end   -- writes refused

    if cl.numAnimals ~= before.n or cl.health ~= before.h or cl.age ~= before.a then
        -- The write went THROUGH to the real cluster. Detecting that required
        -- making it happen, so put the original back before refusing: the gate
        -- must not itself be the thing that ages or re-prices a player's herd.
        pcall(function()
            cl.numAnimals, cl.health, cl.age = before.n, before.h, before.a
        end)
        return nil
    end
    return cp
end

---{ peakAge, priceAtPeak, priceAt(age), declines } for a subtype, cached.
-- Sampled at health 100 so the health term drops out and this is the raw curve.
function AnimalSellRules.priceCurve(cl)
    local sti = cl ~= nil and cl.subTypeIndex or nil
    if sti == nil then return nil end
    if _curveCache[sti] ~= nil then return _curveCache[sti] end

    local probe = AnimalSellRules.cloneIsSafe(cl)
    if probe == nil then return nil end

    local samples, peakAge, peakVal = {}, nil, nil
    for age = 0, 72, 3 do
        local c = nil
        local ok, cp = pcall(cl.clone, cl)
        if ok and type(cp) == "table" and cp ~= cl then c = cp end
        if c ~= nil then
            c.health, c.age = 100, age
            local p = priceOf(c)
            if p ~= nil then
                samples[#samples + 1] = { age = age, price = p }
                if peakVal == nil or p > peakVal then peakAge, peakVal = age, p end
            end
        end
    end
    if #samples < 2 then return nil end

    -- Does it DECLINE after the peak? Measured: only cows do. Asking the curve
    -- rather than the species means a modded animal answers for itself.
    local declines, worstAfter = false, peakVal
    for _, s in ipairs(samples) do
        if s.age > peakAge and s.price < worstAfter then
            worstAfter = s.price
            declines = true
        end
    end

    -- WHAT A DISCARDED BIRTH IS ACTUALLY WORTH. The headroom rule trades a
    -- producing adult for a slot a newborn will fill, and until now the newborn
    -- side of that trade had no number at all -- the rule simply asserted that a
    -- destroyed calf outranks everything. It is the first sample: age 0 at
    -- health 100, so it is the raw curve and the generous reading of the trade.
    local birthPrice = nil
    for _, sm in ipairs(samples) do
        if sm.age == 0 then birthPrice = sm.price; break end
    end
    if birthPrice == nil then birthPrice = samples[1].price end

    local curve = { samples = samples, peakAge = peakAge, peakPrice = peakVal,
                    declines = declines, lowestAfterPeak = worstAfter,
                    birthPrice = birthPrice }
    _curveCache[sti] = curve
    return curve
end

---Forget the measured curves. Called when the world changes under us.
function AnimalSellRules.clearCache()
    _curveCache = {}
end

-- ---------------------------------------------------------------------------
---Everything the rules need about one barn, read live and mutating nothing.
---THE BREEDING GATES, in the engine's own order: age first, then health.
--
-- EXTRACTED so the husbandry panel's profit roll-up asks the SAME question this
-- does. Births are the largest term in a breeding barn's monthly result, and a
-- second copy of "is this cluster breeding" is a second answer waiting to
-- disagree with the plan sitting on the next tab.
---Returns willBreed, tooYoung, unwell, cycleMonths.
function AnimalSellRules.breedingOf(st, ageMonths, healthPct)
    local minAge = st ~= nil and st.reproductionMinAgeMonth or nil
    local minH   = st ~= nil and st.reproductionMinHealth or nil
    local dur    = st ~= nil and st.reproductionDurationMonth or nil
    local age    = ageMonths or 0
    local hp     = healthPct or 0
    local tooYoung = (minAge ~= nil and age < minAge)
    local unwell   = (not tooYoung) and (minH ~= nil and (hp / 100) < minH)
    return (not tooYoung and not unwell), tooYoung, unwell, dur
end

function AnimalSellRules.assess(p)
    local out = { clusters = {}, animals = 0, capacity = 0, free = 0,
                  births = 0, breeders = 0, lost = 0, value = 0 }
    if p == nil or p.getClusters == nil then return out end

    local okC, clusters = pcall(p.getClusters, p)
    if not okC or type(clusters) ~= "table" then return out end

    local function num(fn, dflt)
        if p[fn] == nil then return dflt end
        local ok, v = pcall(p[fn], p)
        return (ok and type(v) == "number") and v or dflt
    end
    out.animals  = num("getNumOfAnimals", 0)
    out.capacity = num("getMaxNumOfAnimals", 0)
    out.free     = num("getNumOfFreeAnimalSlots", math.max(0, out.capacity - out.animals))

    local remaining = out.free
    for _, cl in pairs(clusters) do
        local n   = cl.numAnimals or 0
        local age = cl.age or 0
        local hp  = cl.health or 0
        local st  = subTypeOf(cl.subTypeIndex)
        local each = priceOf(cl)
        local curve = AnimalSellRules.priceCurve(cl)

        local willBreed, tooYoung, unwell, dur = AnimalSellRules.breedingOf(st, age, hp)

        -- periods until this cluster births, on the measured counter model
        local due = nil
        if willBreed and dur ~= nil and dur > 0 then
            due = math.max(1, math.ceil((100 - (cl.reproduction or 0)) / (100 / dur)))
        end

        -- PAST PEAK: worth less later than now, so holding it costs money. Only
        -- meaningful on a curve that actually declines.
        local pastPeak = false
        if curve ~= nil and curve.declines and age >= curve.peakAge then pastPeak = true end
        local atPeak = (curve ~= nil and age >= curve.peakAge)

        local lost = 0
        if willBreed then
            out.births   = out.births + n
            out.breeders = out.breeders + n
            lost = math.max(0, n - remaining)
            remaining = math.max(0, remaining - n)
            out.lost = out.lost + lost
        end
        out.value = out.value + (each or 0) * n

        -- THE EARNINGS PICTURE, per animal per month. Optional by construction:
        -- AnimalEconomics is a separate sourceFile and could be absent, and every
        -- consumer below treats a nil `econ` as "no information" rather than as
        -- zero -- so the rules degrade to exactly their pre-earnings behaviour.
        local econ = nil
        if AnimalEconomics ~= nil and AnimalEconomics.assessCluster ~= nil then
            local okE, e = pcall(AnimalEconomics.assessCluster, p, cl, st, curve)
            if okE and type(e) == "table" then econ = e end
        end
        local immature = nil
        if AnimalEconomics ~= nil and AnimalEconomics.monthsToMaturity ~= nil then
            local okM, m = pcall(AnimalEconomics.monthsToMaturity, st, age)
            if okM and type(m) == "number" then immature = m end
        end

        out.clusters[#out.clusters + 1] = {
            cluster = cl, subTypeIndex = cl.subTypeIndex,
            name = (st ~= nil and tostring(st.name) or "?"),
            count = n, age = age, healthPct = hp, each = each,
            total = (each ~= nil) and each * n or nil,
            willBreed = willBreed, tooYoung = tooYoung, unwell = unwell,
            cycleMonths = dur,        -- one birth per this many months, per breeder
            dueInMonths = due, lostIfFull = lost,
            atPeak = atPeak, pastPeak = pastPeak,
            peakAge = curve ~= nil and curve.peakAge or nil,
            declines = curve ~= nil and curve.declines or false,
            birthValue = curve ~= nil and curve.birthPrice or nil,
            econ = econ, monthsToMaturity = immature,
        }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- THE PLAN.
--
-- Two rules, and their PRECEDENCE is the whole design:
--
--   1. HEADROOM outranks everything, and is allowed to lose money. A full pen
--      destroys `numAnimals` offspring AND the whole gestation that made them,
--      every cycle, for as long as it stays full. Against that, selling a beast
--      a few months before its peak costs the difference and nothing else.
--
--   2. PEAK never loses money. An animal past the top of its curve is worth less
--      every month it is kept, so selling it is pure gain -- but only on a curve
--      that actually DECLINES, which measurement says is cows alone. On a flat
--      curve there is nothing to be early or late for and this rule stays silent.
--
-- The health floor suppresses (2) and NOT (1), which is the subtle part. Selling
-- a starving herd realises 46% of book value, so peak sales wait for feeding to
-- recover them. A headroom sale cannot wait: the calves are destroyed this cycle
-- whatever the price, so a low price is better than a total loss.
--
-- WHICH ANIMALS. Headroom takes from the clusters with the LEAST future in them
-- first -- past peak, then at peak, then oldest -- so the herd keeps the animals
-- that are still appreciating. Never below `keepBreeders`.
---`priceFn(cluster, n) -> net` is OPTIONAL and is how this stays pure while still quoting money the
-- player will actually receive. cluster:getSellPrice() is the GROSS: measured 2026-08-29, a sale of 7
-- cows quoted 604.50 each and realised 504.50 each -- a flat 100 per animal dealer fee (CLAUDE.md 13.5).
-- Costing a plan from the gross over-promises every figure on screen, so AnimalSellExecutor.priceFn
-- supplies the real one. With no function passed the gross is used and the module remains testable
-- with no controller, no world and no money in sight.
---Is a headroom sale on this cluster worth what it costs?
-- THE TRADE, written as the arithmetic actually is. Selling one adult for
-- headroom yields one calf that would otherwise have been discarded, and costs
-- that adult's saleable output for as long as the calf takes to reach its own
-- output cliff (14.4: milk at 12 months, eggs at 6 -- a CLIFF, not a ramp).
-- Book value cancels, because you end the horizon holding an animal either way.
-- So the entire comparison is
--
--        one newborn   >   the output forgone while it grows up
--
-- and on a dairy herd it is not close: a calf is worth a few hundred against a
-- year of milk. On a BEEF herd nothing is age-gated at all, `maturity` is nil,
-- and the sale proceeds exactly as it always did -- which is the case the
-- headroom rule was written for in the first place.
--
-- Until now the newborn side of this trade had NO NUMBER. The rule simply
-- asserted that a destroyed calf outranks everything, and so recommended
-- liquidating a herd earning 35,817/month to save calves nobody had priced.
--
-- CORRECTED 2026-08-30, ONE DAY AFTER IT SHIPPED, and the correction is the
-- left-hand term. It read `birthValue > maturityCost` -- the value of the CALF
-- against the wait. Write the bookkeeping out over the horizon and that is not
-- the trade:
--      KEEP : assets {adult A};        cash over `onset` = onset x adultOutput
--      SELL : assets {adult C, grown}; cash over `onset` = the SALE PROCEEDS
-- Both end holding exactly one adult, so the ASSETS cancel -- which means the
-- calf's own value cancels with them, because the calf IS the replacement. What
-- does not cancel is the money you were paid. So the comparison is the adult's
-- net sale price against the output forgone.
--
-- It agrees with the old form on all three of the author's barns (a Holstein
-- nets ~1,118 against 4,038 of milk; both say keep), so nothing that shipped was
-- wrong on this farm -- but the old form UNDER-SELLS in general: an expensive
-- animal with weak output (net 5,000, cost 600) reads "keep" on the calf's value
-- and "sell" on the truth.
--
-- The calf's value has a home, and it is the NURSERY comparison, where the calf
-- really is sold and really is the income.
--
-- Returns worth (true/false) and the data behind it -- or nil for NO VERDICT.
-- AN UNKNOWN VERDICT NEVER SUPPRESSES (15.2): with AnimalEconomics absent, or a
-- modded animal it cannot price, the pre-earnings behaviour has to stand, or
-- adding a module that cannot price something would silently stop selling it.
function AnimalSellRules.headroomVerdict(c, netEach)
    if c == nil then return nil end
    local m = (c.econ ~= nil) and c.econ.maturity or nil
    if m == nil or type(m.cost) ~= "number" then return nil end   -- nothing age-gated
    local proceeds = netEach
    if type(proceeds) ~= "number" then proceeds = c.each end      -- gross, if no net
    if type(proceeds) ~= "number" then return nil end             -- unpriceable
    return proceeds > m.cost,
           { name = c.name, proceeds = proceeds, birthValue = c.birthValue,
             cost = m.cost, months = m.months, perMonth = m.valuePerMonth }
end

---WHICH USE EARNS MORE ACROSS THE WHOLE BARN, weighted by HEADCOUNT.
-- Per-cluster because a barn can hold several subtypes, weighted because a
-- 1-animal cluster and a 250-animal one are not two equal opinions (15.6).
-- `feeEach` is subtracted from every calf's price; nil means "not known", and
-- the answer is then the pre-fee one.
function AnimalSellRules.slotUse(a, feeEach)
    if a == nil or AnimalEconomics == nil or AnimalEconomics.slotVerdict == nil then return nil end
    local adultSum, nurserySum, headcount = 0, 0, 0
    for _, c in ipairs(a.clusters or {}) do
        local margin = (c.econ ~= nil) and c.econ.marginPerMonth or nil
        local v = AnimalEconomics.slotVerdict(margin,
                      type(c.birthValue) == "number" and (c.birthValue - (feeEach or 0)) or nil,
                      c.cycleMonths)
        if v ~= nil and (c.count or 0) > 0 then
            adultSum   = adultSum   + v.adult   * c.count
            nurserySum = nurserySum + v.nursery * c.count
            headcount  = headcount  + c.count
        end
    end
    if headcount == 0 then return nil end
    -- cycleMonths = 1 so the already-per-month nursery figure passes straight
    -- through: ONE function decides `use`, here and per cluster alike.
    return AnimalEconomics.slotVerdict(adultSum / headcount, nurserySum / headcount, 1)
end

---THE VERDICT PER BREED, which `slotUse` computes and then averages away.
--
-- `slotUse` already asks `slotVerdict` about EVERY CLUSTER and then collapses the
-- lot into one headcount weighted answer for the barn. 15.6 justified that
-- weighting -- *"a 1-animal cluster and a 250-animal one are not two equal
-- opinions"* -- and it is right for a barn with one purpose. On a MIXED BARN it
-- produces a figure describing neither half: 20 dairy cows and 20 beef cows
-- average into a verdict that is true of nobody.
--
-- So the per-breed answer was being computed inside that loop and discarded. This
-- keeps it. Nothing here is a new model -- same `slotVerdict`, same weighting,
-- grouped one level finer.
--
-- WHY BREED IS A USABLE PROXY FOR PURPOSE, which is the whole point (28.7): a
-- subtype carries its OWN `output` table, and `assessCluster` prices it against
-- the BARN's `producibleOutputKeys`. So a beef breed that declares no milk scores
-- zero adult margin while a dairy breed beside it in the same building scores its
-- milk -- and a dairy breed in a barn with no milking spec scores zero too. Both
-- directions already work; they were simply averaged together before they could
-- be read.
--
-- WEIGHTED BY THE JUDGED HEAD, not the whole group, mirroring `slotUse`: a cluster
-- that could not be priced must not dilute the answer for the ones that could.
---Returns an array, biggest group first, each { subTypeIndex, name, count, total,
-- age, use, adult, nursery, margin } -- `use` nil where no verdict was possible.
function AnimalSellRules.slotUseByType(a, feeEach)
    local order = {}
    if a == nil or AnimalEconomics == nil or AnimalEconomics.slotVerdict == nil then return order end
    local byType = {}
    for _, c in ipairs(a.clusters or {}) do
        local n = c.count or 0
        if n > 0 then
            local g = byType[c.subTypeIndex]
            if g == nil then
                g = { subTypeIndex = c.subTypeIndex, name = c.name, count = 0, total = 0,
                      adultSum = 0, nurserySum = 0, judged = 0,
                      -- WHERE THE EARNINGS COME FROM, per product. `assessCluster`
                      -- has carried `econ.byFillType` from the first day and
                      -- nothing has ever read it -- the same shape as the per-breed
                      -- verdict this function exists to rescue.
                      --
                      -- IT IS THE TERMS, NOT THE CONCLUSION, that a player needs to
                      -- override a figure (28.8): "earns 940/mo" is unarguable,
                      -- while "milk 900, manure 40" says at once WHICH number is
                      -- wrong for a farm that digests its manure instead of selling
                      -- it. The model prices raw fill types and cannot see what
                      -- happens downstream, so this is where its blind spot becomes
                      -- visible rather than merely present.
                      earns = {}, earnHead = 0, earnsPerAnimal = nil,
                      -- WHAT A NEWBORN OF THIS BREED IS WORTH. A property of the
                      -- subtype's price curve, so identical across its clusters --
                      -- the first one that has it speaks for the breed.
                      birthValue = nil }
                byType[c.subTypeIndex] = g
                order[#order + 1] = g
            end
            g.count = g.count + n
            if g.birthValue == nil and type(c.birthValue) == "number" then
                g.birthValue = c.birthValue
            end
            g.total = g.total + (c.total or ((c.each or 0) * n))
            -- the YOUNGEST cluster's age, only so the row can pick a picture: the
            -- base game's own icon lookup is by (subtype, age).
            if g.age == nil or (c.age or 0) < g.age then g.age = c.age end

            -- PER ANIMAL PER MONTH, which is the basis `earnsPerMonth` and the
            -- verdict already use -- so the parts add up to the figure beside them
            -- instead of being a second quantity in different units.
            -- AN ENTRY IS A RECORD, NOT A NUMBER: `outputValuePerMonth` writes
            -- `{ litres, value, key }` per fill type, and `value` is nil where the
            -- product could not be priced. The first version tested
            -- `type(v) == "number"` and so matched NOTHING, leaving an empty
            -- breakdown behind a headcount that had already been incremented --
            -- which read on screen as every breed earning 0 from nowhere.
            if c.econ ~= nil and type(c.econ.byFillType) == "table" then
                for ft, e in pairs(c.econ.byFillType) do
                    if type(e) == "table" then
                        if type(e.value) == "number" then
                            g.earns[ft] = (g.earns[ft] or 0) + e.value * n
                        else
                            -- MADE BUT NOT PRICEABLE. Counted rather than dropped:
                            -- "earns nothing" and "nobody could put a price on it"
                            -- are different answers and the screen must not give
                            -- the first when it means the second.
                            g.unpriced = (g.unpriced or 0) + 1
                        end
                    end
                end
                g.earnHead = g.earnHead + n
            end

            local v = AnimalEconomics.slotVerdict(
                (c.econ ~= nil) and c.econ.marginPerMonth or nil,
                type(c.birthValue) == "number" and (c.birthValue - (feeEach or 0)) or nil,
                c.cycleMonths)
            if v ~= nil then
                g.adultSum   = g.adultSum + v.adult * n
                g.nurserySum = g.nurserySum + v.nursery * n
                g.judged     = g.judged + n
            end
        end
    end
    for _, g in ipairs(order) do
        -- back to a per-animal figure, over the head that actually contributed one
        if g.earnHead > 0 then
            local sum = 0
            for ft, v in pairs(g.earns) do
                g.earns[ft] = v / g.earnHead
                sum = sum + g.earns[ft]
            end
            g.earnsPerAnimal = sum
        else
            g.earns = nil
        end
        if g.judged > 0 then
            -- cycleMonths 1 so the already-per-month nursery figure passes straight
            -- through, exactly as slotUse does for the barn.
            local v = AnimalEconomics.slotVerdict(g.adultSum / g.judged, g.nurserySum / g.judged, 1)
            if v ~= nil then
                g.use, g.adult, g.nursery, g.margin = v.use, v.adult, v.nursery, v.margin
            end
        end
    end
    -- WHY EACH BREED GOT THE VERDICT IT DID. A CODE, never a sentence: this module
    -- is pure and does not know what language the player reads, and the harness
    -- asserts on codes rather than on wording -- the rule `notes` and `slotUseGap`
    -- already follow.
    for _, g in ipairs(order) do
        g.reason = AnimalSellRules.slotReason(g)
    end
    -- BIGGEST GROUP FIRST, then by name so the order is stable across passes --
    -- table.sort is not stable, and a list that reshuffles under the player is the
    -- 24.3 complaint about clusters all over again.
    table.sort(order, function(x, y)
        if x.count ~= y.count then return x.count > y.count end
        return tostring(x.name) < tostring(y.name)
    end)
    return order
end

---WHY A BREED GOT ITS VERDICT, in one code.
--
-- The verdict alone says WHICH, never WHY, and "Producers" with no reason beside
-- it is exactly the sort of conclusion 28.8 argued a player cannot push back on.
-- These are the four shapes the comparison actually takes.
--
-- `noOutput` IS THE ONE WORTH SEPARATING. A breed that makes nothing sellable is
-- pointed at breeding because it has no earnings to beat, which is a different
-- statement from one whose calves genuinely outvalue its output -- and it is the
-- pig and horse case (28.4).
function AnimalSellRules.slotReason(g)
    if g == nil or g.use == nil then return nil end
    local adult, nursery = g.adult or 0, g.nursery or 0
    if g.use == "NURSERY" then
        if adult <= 0 then return "noOutput" end
        return "calvesWorthMore"
    end
    -- ADULT with nothing on either side is not a judgement, it is an absence: the
    -- comparison was 0 against 0 and the tie fell to adults by default.
    if adult <= 0 and nursery <= 0 then return "nothingToWeigh" end
    return "outputBeatsCalves"
end

---WHY THERE IS NO PRODUCER VERSUS NURSERY VERDICT, when there is none.
--
-- `slotUse` returns nil for four different reasons and names none of them, so a
-- barn with no verdict is indistinguishable from one nobody asked about. That is
-- not a hypothetical gap: `slotVerdict` refuses a nil `adultPerMonth`, and a barn
-- whose animals have no PRICED monthly output -- a pig or horse pen, which makes
-- only manure -- is exactly the case that reaches it. Those are also the barns a
-- player would call "always breeders", so the one place the model is most likely
-- to fall silent is the one where its answer would be least surprising.
--
-- IT MIRRORS `slotUse`'s OWN LOOP, and must keep mirroring it: that function
-- decides it has an answer as soon as ONE cluster can be judged, so this one has
-- to give up as soon as one can. If they disagree, a barn reports both a verdict
-- and a reason for having none.
--
-- Returns nil when a verdict IS possible, else { code, name }. A CODE, never a
-- sentence -- this module is pure and does not know what language the player
-- reads, and the harness asserts on codes rather than on wording.
function AnimalSellRules.slotUseGap(a)
    if a == nil then return { code = "empty" } end
    local first = nil
    for _, c in ipairs(a.clusters or {}) do
        if (c.count or 0) > 0 then
            local margin = (c.econ ~= nil) and c.econ.marginPerMonth or nil
            local code = nil
            if type(margin) ~= "number" then code = "margin"
            elseif type(c.birthValue) ~= "number" then code = "birthValue"
            elseif type(c.cycleMonths) ~= "number" or c.cycleMonths <= 0 then code = "cycle" end
            if code == nil then return nil end        -- this one can be judged
            if first == nil then first = { code = code, name = c.name } end
        end
    end
    if first == nil then return { code = "empty" } end
    return first
end

---WHICH ANIMALS GO FIRST -- the one ordering, shared by every path that sells.
--
-- Extracted from `plan` 2026-09-10 so a standing ORDER and the rules engine
-- cannot disagree about which animal to take. A second copy of this comparator
-- is exactly the drift this project keeps paying for, and "sell oldest" is now
-- the ONLY thing a standing order is allowed to consult -- so it had better be
-- the same "oldest" the plan means.
--
-- EARNINGS RANK ABOVE AGE AND BELOW PEAK, which is the deliberate part. Peak
-- state is a fact about the price curve and is certain; earnings depend on prices
-- and on the barn's efficiency and can be unknown, so they refine the order
-- within a peak state rather than overriding it. Where earnings ARE known, the
-- lowest monthly margin goes first -- a better answer than "oldest" whenever a
-- barn holds two clusters of the same age doing different work, and identical to
-- it when they do not.
--
-- `table.sort` is not stable, so the name is the final tiebreak: a list that
-- reshuffles under the player is a list they cannot act on.
AnimalSellRules.REASON_ORDER = "order"

---A STANDING ORDER'S PLAN -- the count the player asked for, taken in rank order,
-- and NOTHING ELSE CONSULTED.
--
-- Author, 2026-09-10: *"I want no other sell order settings to impact the sale at
-- all other than the age ordering. So should be disconnected completely."*
--
-- WHY THIS CANNOT BE A PERMISSIVE `cfg`, which was the obvious first idea:
-- `plan` does not filter a list of candidates, it EMITS lines for four reasons --
-- calf, headroom, peak, earnings. With no reason firing there are no lines at
-- all, whatever the settings say, so an order for 20 would quietly sell nothing.
-- Loosening the rules could never produce "sell exactly 20"; only bypassing them
-- can. That is why this is a separate entry point rather than a configuration.
--
-- IT SHARES `rankClusters` WITH THE RULES ENGINE, deliberately: the one thing an
-- order IS allowed to consult had better mean the same "oldest" the rest of the
-- mod means.
--
-- THE ONE REFUSAL THAT REMAINS IS NOT A SETTING. A dealer fee is charged PER
-- ANIMAL (13.5) and on a cheap animal can exceed its price, so the sale realises
-- NEGATIVE money -- it destroys the animal and charges you for it. Refusing that
-- is not a rule the player switched on; it is the difference between selling and
-- burning. It is reported as a note so the refusal is visible rather than silent.
---Returns a plan in `AnimalSellRules.plan`'s own shape.
function AnimalSellRules.orderPlan(p, count, priceFn)
    local a = AnimalSellRules.assess(p)
    local plan = { lines = {}, total = 0, revenue = 0, assess = a, notes = {} }
    count = tonumber(count) or 0
    if a == nil or type(a.clusters) ~= "table" or #a.clusters == 0 or count <= 0 then
        return plan
    end

    local left = count
    local refused = nil
    for _, c in ipairs(AnimalSellRules.rankClusters(a)) do
        if left <= 0 then break end
        local n = math.min(left, c.count or 0)
        if n > 0 then
            local rev, realised = (c.each or 0) * n, false
            if priceFn ~= nil then
                local ok, v = pcall(priceFn, c.cluster, n)
                if ok and type(v) == "number" then rev, realised = v, true end
            end
            if realised and rev <= 0 then
                if refused == nil then
                    refused = { name = c.name, count = n, revenue = rev, each = c.each }
                end
            else
                plan.lines[#plan.lines + 1] = {
                    cluster = c.cluster, name = c.name, count = n,
                    reason = AnimalSellRules.REASON_ORDER,
                    each = c.each, revenue = rev, gross = (c.each or 0) * n,
                    age = c.age, healthPct = c.healthPct,
                }
                plan.total = plan.total + n
                plan.revenue = plan.revenue + rev
                left = left - n
            end
        end
    end

    -- SHORT IS REPORTED, NOT PADDED. A barn holding fewer animals than the order
    -- asks for sells what it has; saying so is the caller's job and `buildPlan`
    -- already does it.
    if refused ~= nil then
        plan.notes[#plan.notes + 1] = { kind = "refused", name = refused.name,
                                        count = refused.count, revenue = refused.revenue,
                                        each = refused.each }
    end
    return plan
end

function AnimalSellRules.rankClusters(a)
    local order = {}
    if a == nil or type(a.clusters) ~= "table" then return order end
    for _, c in ipairs(a.clusters) do order[#order + 1] = c end
    local function margin(c)
        return c.econ ~= nil and c.econ.marginPerMonth or nil
    end
    table.sort(order, function(x, y)
        if x.pastPeak ~= y.pastPeak then return x.pastPeak end       -- losing value now
        if x.atPeak ~= y.atPeak then return x.atPeak end             -- nothing left to gain
        local mx, my = margin(x), margin(y)
        if mx ~= nil and my ~= nil and mx ~= my then return mx < my end  -- earns least first
        if (x.age or 0) ~= (y.age or 0) then return (x.age or 0) > (y.age or 0) end  -- oldest first
        return tostring(x.name) < tostring(y.name)                   -- stable
    end)
    return order
end

function AnimalSellRules.plan(p, cfg, priceFn)
    cfg = cfg or {}
    -- Returns the money AND whether it is REALISED -- the game's own net, via
    -- getTargetPrice -- or the gross fallback. The caller has to know which:
    -- refusing a sale on a negative figure is only sound where the figure is
    -- the real one, and the gross can never be negative.
    local function priceOfN(c, n)
        if priceFn ~= nil then
            local ok, v = pcall(priceFn, c.cluster, n)
            if ok and type(v) == "number" then return v, true end
        end
        return (c.each or 0) * n, false
    end
    local function opt(k)
        local v = cfg[k]
        if v == nil then return AnimalSellRules.DEFAULTS[k] end
        return v
    end

    local a = AnimalSellRules.assess(p)
    local plan = { lines = {}, total = 0, revenue = 0, assess = a, notes = {} }
    if #a.clusters == 0 then return plan end

    -- Notes carry DATA, never a sentence. This module is pure and has no business
    -- knowing what language the player reads: the GUI formats and localises. It
    -- also keeps the harness asserting on figures rather than on wording.
    local function note(kind, data)
        data = data or {}
        data.kind = kind
        plan.notes[#plan.notes + 1] = data
    end

    -- health floor: a herd this sick is worth 0.40 + 0.60h of book. Feeding it
    -- first is worth more than any peak sale, so peak sales stand down.
    local herdH = 0
    do
        local sum, cnt = 0, 0
        for _, c in ipairs(a.clusters) do sum = sum + c.healthPct * c.count; cnt = cnt + c.count end
        if cnt > 0 then herdH = (sum / cnt) / 100 end
    end
    local floor = opt("minHealthToSell")
    local tooSickToSell = (type(floor) == "number" and herdH < floor)

    -- how many slots the barn must have free. -1 derives it from the measured
    -- 1:1 doubling: next cycle needs one slot per breeding animal.
    local rawWant = opt("keepFreeSlots")
    local derived = (type(rawWant) ~= "number" or rawWant < 0)
    local want = derived and a.births or rawWant
    local needed = math.max(0, want - a.free)

    -- never take the herd below the breeder floor
    local keep = opt("keepBreeders") or 0
    local breederRoom = math.max(0, a.breeders - keep)
    -- ONE budget for the whole plan: the nursery selldown, the headroom loop and
    -- the peak rule all draw on the same breeder floor, so it is declared here
    -- rather than inside any one of them.
    local budget = breederRoom

    -- ---- rank: least future first --------------------------------------
    -- EARNINGS RANK ABOVE AGE AND BELOW PEAK, which is the deliberate part. Peak
    -- state is a fact about the price curve and is certain; earnings depend on
    -- prices and on the barn's efficiency and can be unknown, so they refine the
    -- order within a peak state rather than overriding it. Where earnings ARE
    -- known, the lowest monthly margin goes first -- which is a better answer than
    -- "oldest" whenever a barn holds two clusters of the same age doing different
    -- work, and identical to it when they do not.
    local order = AnimalSellRules.rankClusters(a)

    -- A SALE THAT PAYS NOTHING IS NOT A SALE. 13.5 measured a dealer fee that is
    -- charged PER ANIMAL; on a cheap animal it can exceed the animal's own price,
    -- so the "revenue" goes NEGATIVE and the transaction destroys the animal and
    -- charges you for the privilege. Whether that happens turns on a fee model
    -- 13.5 could not resolve -- its own scaling test distinguishes per-animal
    -- from per-transaction but NOT a flat 100 from 16.54% of gross, and at a
    -- chicken's 25 those two differ by the SIGN of the answer.
    --
    -- This needs no answer to that question. It refuses only on the REALISED
    -- figure, so under a percentage fee it can never fire, and under a flat one
    -- it is exactly what stops a flock being sold at a loss.
    local refused = nil
    local function take(c, n, reason)
        if n <= 0 then return 0 end
        n = math.min(n, c.count)
        if n <= 0 then return 0 end
        local rev, realised = priceOfN(c, n)
        if realised and rev <= 0 then
            if refused == nil then
                refused = { name = c.name, count = n, revenue = rev, each = c.each }
            end
            return 0
        end
        plan.lines[#plan.lines + 1] = {
            cluster = c.cluster, name = c.name, count = n, reason = reason,
            each = c.each,            -- the GROSS per animal, as the game quotes it
            revenue = rev,            -- what the sale would actually realise
            gross = (c.each or 0) * n,
            age = c.age, healthPct = c.healthPct,
        }
        plan.total = plan.total + n
        plan.revenue = plan.revenue + rev
        return n
    end

    -- ---- 0. WHAT IS THIS BARN FOR? --------------------------------------
    -- A pen slot holds a producer, or it is kept free as a NURSERY: a calf is
    -- born into it each cycle and sold at once. Maximising over the whole pen
    -- collapses to ONE per-slot comparison and the capacity cancels out
    -- (AnimalEconomics.slotVerdict); the optimum is only ever FULL of adults or
    -- EXACTLY HALF, never between.
    --
    -- THE FEE IS ONLY PAID FOR WHEN IT COULD CHANGE THE ANSWER. A dealer fee can
    -- only ever REDUCE the nursery side, so a barn that says ADULT on the gross
    -- says ADULT on the net too and needs no price lookup at all -- which is
    -- every producing barn, and is what keeps `netPriceFn` lazy. Only a gross
    -- NURSERY verdict is re-tested against real money.
    local slot = AnimalSellRules.slotUse(a, nil)
    if slot ~= nil and slot.use == "NURSERY" and priceFn ~= nil then
        -- A newborn that does not exist cannot be quoted, so the calf is costed
        -- with an ADULT's own fee. Under a flat per-animal fee that is exact;
        -- under a percentage it over-charges a cheap calf and so UNDER-states
        -- the nursery -- the conservative direction for the aggressive answer.
        local feeEach = nil
        for _, c in ipairs(a.clusters) do
            if type(c.each) == "number" and c.each > 0 then
                local net, realised = priceOfN(c, 1)
                if realised then feeEach = math.max(0, c.each - net); break end
            end
        end
        if feeEach ~= nil then slot = AnimalSellRules.slotUse(a, feeEach) end
    end
    plan.slot = slot

    local nursery = (slot ~= nil and slot.use == "NURSERY")
    if nursery and not opt("sellCalves") then
        -- ADVISORY UNTIL SWITCHED ON. Halving a producing herd is a large and
        -- visible recommendation, so the model reports the finding and plans
        -- nothing. The player opts in per barn.
        local half = math.ceil((a.capacity or 0) / 2)
        note("nursery", { adult = slot.adult, nursery = slot.nursery,
                          perMonth = slot.margin * half, adults = half })
        nursery = false
    end

    if nursery then
        -- (a) THE HARVEST. An animal too young to breed is stock, not herd: it
        -- occupies a slot, produces nothing sellable, and is what this barn is
        -- being run to make.
        for _, c in ipairs(order) do
            if c.tooYoung then take(c, c.count, AnimalSellRules.REASON_CALF) end
        end
        -- (b) AND KEEP THE BREEDING HALF, so next cycle's calves have somewhere
        -- to be born. Above half, every extra adult is a slot its own calf
        -- cannot use.
        local target = math.ceil((a.capacity or 0) / 2)
        local adults = 0
        for _, c in ipairs(a.clusters) do
            if not c.tooYoung then adults = adults + (c.count or 0) end
        end
        local over = adults - target
        for _, c in ipairs(order) do
            if over <= 0 then break end
            if not c.tooYoung then
                local allowed = c.willBreed and math.min(over, budget) or over
                local took = take(c, allowed, AnimalSellRules.REASON_HEADROOM)
                over = over - took
                if c.willBreed then budget = budget - took end
            end
        end
    else

    -- ---- 1. HEADROOM ----------------------------------------------------
    -- THE GAP IS MEASURED IN SLOTS, AND A BREEDER CLOSES IT TWICE.
    -- Selling any animal frees a slot; selling a BREEDER also removes the birth
    -- it would have contributed, so it closes the gap by TWO. The old form asked
    -- for `births` animals outright -- which counts the slots the CURRENT herd
    -- needs while ignoring that selling shrinks the herd -- and so over-sold by
    -- exactly 2x everywhere. At a FULL pen it resolved to selling every animal
    -- in the barn, which is self-defeating: no breeders left means no births, so
    -- the headroom it bought is never used by anything.
    --
    -- Measured on the author's own barn (96/96 Holsteins, 96 births, 0 free):
    -- the old rule recommended 96, the corrected one 48 -- and 48 is not merely
    -- smaller, it lands exactly on the fixed point, 48 kept / 48 slots free /
    -- 48 calves. Same on the harness coop: 140 -> 70, again exact.
    --
    -- An EXPLICIT keepFreeSlots is an absolute free-slot target and is NOT tied
    -- to the herd size, so there a sale closes the gap by one however it breeds.
    local deficit = needed
    local hardCap = math.floor(a.animals * AnimalSellRules.HEADROOM_MAX_FRACTION)
    local bar = opt("headroomWorthIt")
    local declined = nil
    if deficit > 0 then
        for _, c in ipairs(order) do
            if deficit <= 0 or plan.total >= hardCap then break end
            local worth, why = nil, nil
            if bar then
                -- the trade is priced on what the SALE PAYS, so quote the net
                local netEach = priceOfN(c, 1)
                worth, why = AnimalSellRules.headroomVerdict(c, netEach)
            end
            if worth == false then
                -- The calf is worth less than the wait. Say so; sell nothing here.
                if declined == nil then declined = why end
            else
                local per = (derived and c.willBreed) and 2 or 1
                local allowed = math.ceil(deficit / per)
                if c.willBreed then allowed = math.min(allowed, budget) end
                allowed = math.min(allowed, hardCap - plan.total)
                local took = take(c, allowed, AnimalSellRules.REASON_HEADROOM)
                deficit = deficit - took * per
                if c.willBreed then budget = budget - took end
            end
        end
        -- WHY NOTHING (MORE) HAPPENED, naming the actual cause. `refused` gets no
        -- note here: the `unsellable` one at the end of the plan explains it, and
        -- blaming the breeder floor would name the wrong reason entirely.
        if deficit > 0 and declined ~= nil then
            note("breeding", declined)
        elseif deficit > 0 and refused == nil then
            note("blocked", { short = deficit, keepBreeders = keep })
        end

        -- THE COST OF THE SWAP, stated rather than hidden. A headroom sale trades a
        -- PRODUCING adult for a slot that a newborn will fill -- and 14.4 measured
        -- that saleable output is a CLIFF, so that newborn produces nothing for
        -- 6 months (eggs) or 12 (milk). The rule does not change: a full pen
        -- destroys whole animals and a whole gestation, which still outranks a
        -- maturity lag. But the player is told what the trade costs instead of
        -- being shown a sale that looks free.
        if #plan.lines > 0 then
            local worst, perMonth = nil, 0
            for _, ln in ipairs(plan.lines) do
                if ln.reason == AnimalSellRules.REASON_HEADROOM then
                    for _, c in ipairs(a.clusters) do
                        if c.cluster == ln.cluster and c.econ ~= nil and c.econ.maturity ~= nil then
                            local m = c.econ.maturity
                            if worst == nil or m.months > worst then worst = m.months end
                            perMonth = perMonth + (m.valuePerMonth or 0) * ln.count
                        end
                    end
                end
            end
            if worst ~= nil and worst > 0 then
                note("maturity", { months = worst, perMonth = perMonth,
                                   cost = perMonth * worst })
            end
        end
    end
    end     -- ...the ADULT branch of the nursery choice above

    -- ---- 2. PEAK --------------------------------------------------------
    if opt("sellAtPeak") then
        if tooSickToSell then
            note("held", { healthPct = math.floor(herdH * 100 + 0.5),
                           realisePct = math.floor((0.40 + 0.60 * herdH) * 100 + 0.5) })
        else
            local sold = {}
            for _, ln in ipairs(plan.lines) do sold[ln.cluster] = (sold[ln.cluster] or 0) + ln.count end
            for _, c in ipairs(order) do
                if c.pastPeak then
                    -- THE EARNINGS BAR. Past peak means it will never be worth
                    -- more; it does NOT mean holding it loses money. Sell only
                    -- where a month of earnings fails to cover a month of decline.
                    -- An unknown verdict does NOT suppress: with no economics the
                    -- old behaviour has to stand, or adding a module that cannot
                    -- price a modded animal would silently stop selling it.
                    local earns = (c.econ ~= nil) and c.econ.keep or nil
                    if earns == true then
                        note("earning", { name = c.name, count = c.count,
                                          margin = c.econ.marginPerMonth,
                                          earns = c.econ.earnsPerMonth,
                                          drift = c.econ.driftPerMonth })
                    else
                        local free = c.count - (sold[c.cluster] or 0)
                        local allowed = c.willBreed and math.min(free, budget) or free
                        local took = take(c, allowed, AnimalSellRules.REASON_PEAK)
                        if c.willBreed then budget = budget - took end
                    end
                end
            end
        end
    end

    if refused ~= nil then note("unsellable", refused) end
    if a.lost > 0 and needed <= 0 then note("info", { lost = a.lost }) end
    return plan
end

---One line per reason, for a UI that wants to say WHY rather than list clusters.
-- ---------------------------------------------------------------------------
-- THE PER-GROUP RECOMMENDATION.
--
-- Requested 2026-08-31: a column on the Herd Inspector's groups view saying what to
-- do with THIS group and why -- "Sell - old and losing value", "Keep - still
-- appreciating". The plan already decides what to SELL; this answers the other 90%
-- of the rows, which the plan is silent about because it has nothing to do to them.
--
-- IT RETURNS A CODE AND DATA, NEVER A SENTENCE. Same rule the plan's own `notes`
-- follow and for the same reason: this module is pure, has no business knowing what
-- language the player reads, and the harness must be able to assert on figures
-- rather than on wording. The GUI formats and localises.
--
-- PRECEDENCE, and every step of it is a rule that already existed somewhere:
--   1. THE PLAN WINS. If it has a line for this cluster, that is what will actually
--      happen, and a recommendation that disagreed with the plan on the next tab
--      would be a second opinion (18.16's failure, one screen over).
--   2. HEALTH BEFORE ECONOMICS. A herd below its own reproduction floor is not
--      breeding at all, and selling at 0.40 + 0.60h of book realises a fraction of
--      what feeding it first would (16.5). Feeding is the instruction.
--   3. NOT PRODUCING YET beats every value argument. A calf's whole case is the
--      cliff it has not reached (14.4), and "producing in 11 months" says more than
--      any figure about what it is worth today.
--   4. THEN THE CAPITAL RULE (15.1): keeping wins while a month of earnings beats a
--      month of decline. An APPRECIATING animal has no decline to beat, so it is a
--      keep on its own -- which is the commonest row on any farm and the one the
--      plan says nothing about.
--
-- NIL IS NOT ZERO, here as everywhere: an unpriceable animal yields UNKNOWN rather
-- than a confident verdict built on a missing term (15.6).
AnimalSellRules.REC_SELL, AnimalSellRules.REC_KEEP = "sell", "keep"
AnimalSellRules.REC_ACT, AnimalSellRules.REC_NONE  = "act", "none"

---Returns { action, code, data } for one assess cluster row.
--  action  sell | keep | act | none        -- what the player should DO
--  code    the specific reason, for the GUI to look up
--  data    the group's OWN figures, so the sentence can name them
function AnimalSellRules.recommendation(c, plan)
    if type(c) ~= "table" then return nil end
    local e = c.econ
    local n = c.count or 0

    -- 1. THE PLAN WINS -----------------------------------------------------
    for _, ln in ipairs((plan ~= nil and plan.lines) or {}) do
        if ln.cluster == c.cluster and (ln.count or 0) > 0 then
            local d = { count = ln.count, revenue = ln.revenue, each = ln.each }
            if ln.reason == AnimalSellRules.REASON_CALF then
                return { action = AnimalSellRules.REC_SELL, code = "calf", data = d }
            elseif ln.reason == AnimalSellRules.REASON_HEADROOM then
                d.lost = c.lostIfFull
                return { action = AnimalSellRules.REC_SELL, code = "headroom", data = d }
            elseif ln.reason == AnimalSellRules.REASON_PEAK then
                d.drift = (e ~= nil and e.driftPerMonth ~= nil) and e.driftPerMonth * n or nil
                return { action = AnimalSellRules.REC_SELL, code = "peak", data = d }
            end
            return { action = AnimalSellRules.REC_SELL, code = "plan", data = d }
        end
    end

    -- 2. HEALTH BEFORE ECONOMICS -------------------------------------------
    -- `unwell` is the engine's own reproduction gate, not a threshold invented
    -- here: assess computes it as health < subType.reproductionMinHealth.
    if c.unwell then
        return { action = AnimalSellRules.REC_ACT, code = "unwell",
                 data = { health = c.healthPct } }
    end

    -- 3. NOT PRODUCING YET --------------------------------------------------
    local months = c.monthsToMaturity
    if type(months) == "number" and months > 0 then
        return { action = AnimalSellRules.REC_KEEP, code = "young",
                 data = { months = months } }
    end
    -- too young to BREED is a weaker claim than too young to PRODUCE, so it only
    -- speaks when maturity could not be resolved
    if c.tooYoung then
        return { action = AnimalSellRules.REC_KEEP, code = "growing", data = {} }
    end

    -- 4. THE CAPITAL RULE ---------------------------------------------------
    if e == nil or e.driftPerMonth == nil then
        return { action = AnimalSellRules.REC_NONE, code = "unknown", data = {} }
    end
    local drift = e.driftPerMonth
    if drift < 0 then
        -- APPRECIATING: no decline to beat, so this is a keep on its own. The
        -- commonest row on any farm, and the one the plan is silent about.
        return { action = AnimalSellRules.REC_KEEP, code = "appreciating",
                 data = { gain = -drift * n } }
    end

    local earns = e.earnsPerMonth
    if earns == nil then
        return { action = AnimalSellRules.REC_NONE, code = "unknown", data = {} }
    end
    if drift > 0 then
        -- DECLINING. 15.2: past peak means it will never be worth MORE; it does
        -- NOT mean holding it loses money. Which is bigger decides the verdict.
        if earns > drift then
            return { action = AnimalSellRules.REC_KEEP, code = "outearns",
                     data = { margin = (earns - drift) * n, drift = drift * n } }
        end
        return { action = AnimalSellRules.REC_SELL, code = "declining",
                 data = { drift = drift * n, earns = earns * n } }
    end

    -- FLAT curve (chickens, pigs -- 11.3 measured that only cows decline). There is
    -- nothing to be early or late for, so the only question is whether it earns.
    if earns > 0 then
        return { action = AnimalSellRules.REC_KEEP, code = "steady",
                 data = { earns = earns * n } }
    end
    return { action = AnimalSellRules.REC_SELL, code = "unprofitable",
             data = { earns = earns * n } }
end

-- ---------------------------------------------------------------------------
function AnimalSellRules.summarise(plan)
    local by = {}
    for _, ln in ipairs(plan.lines or {}) do
        local e = by[ln.reason]
        if e == nil then e = { count = 0, revenue = 0 }; by[ln.reason] = e end
        e.count = e.count + ln.count
        e.revenue = e.revenue + (ln.revenue or 0)
    end
    return by
end
