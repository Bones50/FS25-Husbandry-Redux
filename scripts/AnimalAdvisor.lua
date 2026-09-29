-- ============================================================================
-- AnimalAdvisor.lua  (Husbandry Redux)
--
-- THE TWO ADVISERS: what to FEED, and what to SELL -- per barn, per breed, and
-- in the barn-breed's own PURPOSE (PRODUCER or BREEDER, AnimalHerdPolicy).
--
-- Requested 2026-09-10: *"a feed adviser (optimal food for maximum profit) and a
-- herd adviser (how many and when to sell to maximise profit). These should
-- operate in 2 modes production/breeding for each breed in each barn."*
--
-- AND IT IS EXPLICITLY NOT A MAXIMISER: *"What we are trying to achieve is not
-- maxing out health, reproduction and birth rates ... what's the OPTIMAL health,
-- reproduction and birth rate to maximise value while minimising cost."* The
-- adviser this replaces always pushed toward food factor 1.0; this one prices
-- each option and names the most profitable.
--
-- ---------------------------------------------------------------------------
-- WHY THIS IS A RANKING AND NOT AN OPTIMISER, which is the whole design.
--
-- Everything below rests on the model read from source in 33b and measured in
-- 33a, and three facts collapse the problem:
--
--   1. `productionFactor` IS `foodFactor` (PlaceableHusbandry:514) and it
--      MULTIPLIES output directly, so OUTPUT IS LINEAR IN f and never saturates.
--   2. HEALTH SATURATES. Above the threshold health climbs to 100 whatever the
--      factor; a richer mix buys SPEED, not a higher resting health. So health
--      does not trade against cost at all -- it is a FLOOR, not a term.
--   3. A SERIAL animal's f is capped by the best tier PRESENT, so its achievable
--      factors are a handful of discrete values, not a continuum.
--
-- Both sides are therefore linear in f and the option set is tiny: the answer is
-- "price each tier and pick the best", which is exact, explainable, and cannot
-- wander the way a solver can.
--
-- ---------------------------------------------------------------------------
-- IT RETURNS DATA, NOT SENTENCES.
--
-- Every entry point returns numbers plus a `code`, and HusbandryRedux turns the code
-- into the text the panel prints. HusbandryRedux's own note explains why the PANEL
-- gets text (DR has no vocabulary for food groups), but that is a property of the
-- boundary to DR, not of this module -- and a module that returned prose could not
-- be harnessed on its arithmetic, which is the only thing here worth checking.
--
-- PURE. It reads a resolved `ctx` and mutates nothing, exactly as AnimalSellRules
-- is written, so the harness drives the real functions with no game attached.
-- ============================================================================

AnimalAdvisor = {}

-- THE FEED FLOOR, and it is 0.28 rather than the declared 0.2 for a measured
-- reason (33a). The engine FLOORS the health step, so between the threshold and
-- the factor whose increment first reaches 1.0/h health neither decays NOR
-- recovers -- it freezes. A herd parked below the 0.75 breeding gate in that band
-- never breeds again and never heals, and the barn shows no decline to warn
-- anyone. Advising 0.20 would aim straight at it.
AnimalAdvisor.FEED_FLOOR = 0.28

-- Below this the herd is actively losing health, not merely stalled.
AnimalAdvisor.DECAY_BELOW = 0.20

-- The GPF threshold is a BARN property (`husbandry.production#threshold`,
-- default 0.25) and output is zero below it. Kept separate from the health floor
-- because they are different numbers owned by different things.
AnimalAdvisor.OUTPUT_FLOOR = 0.25

-- Health at or above this breeds; below it, nothing does (11.4, a hard cliff).
AnimalAdvisor.BREED_HEALTH = 0.75

-- MET_TARGET, the same 99% the Overview paints green at: a rounding-level miss is
-- not a call to action (DR 5.7).
AnimalAdvisor.MET_TARGET = 0.99

AnimalAdvisor.PRODUCER = "PRODUCER"
AnimalAdvisor.BREEDER  = "BREEDER"

-- HEALTH THAT COUNTS AS FULL for the feeding rule (author, 2026-09-14): below it the
-- herd is fed the FULL ration to recover as fast as possible; at it, the cheapest
-- ration that holds health. Health is whole points, so this is "100%" with no
-- rounding cliff.
AnimalAdvisor.HEALTH_FULL = 0.995

-- A PARALLEL animal's group combinations are all tried, up to this many groups
-- (2^n - 1 rations). Pigs have 4; a modded animal with more falls back to the single
-- groups and the full ration rather than an explosion of candidates.
AnimalAdvisor.MAX_SUBSET_GROUPS = 6

-- ---------------------------------------------------------------------------
local function num(v, dflt)
    if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then return v end
    return dflt
end

---The barn-breed's purpose, defaulting to BREEDER.
--
-- BREEDER IS THE SAFE DEFAULT, deliberately: it treats the feed floor as HARD, so
-- an unconfigured barn is never advised into the band that stops it breeding. A
-- PRODUCER default would let the adviser recommend starving a herd the player
-- actually breeds from.
function AnimalAdvisor.purposeOf(ctx)
    local p = ctx ~= nil and ctx.purpose or nil
    if p == AnimalAdvisor.PRODUCER then return AnimalAdvisor.PRODUCER end
    return AnimalAdvisor.BREEDER
end

-- ===========================================================================
-- THE FEED ADVISER
-- ===========================================================================

---The candidate rations worth pricing.
--
-- SERIAL (cows): one candidate per TIER. Only the best tier present counts, so
-- feeding two tiers at once buys nothing the better one did not already give --
-- there is no combination to search, just a list.
--
-- PARALLEL (pigs, chickens, horses): each group contributes `production x met`
-- INDEPENDENTLY and additively, so the optimum is decided group by group -- take
-- group g iff its share is worth more than it costs. That is generated here as
-- one candidate; the all-groups and single-group sets ride along so the ranking
-- shows the player what the alternatives were rather than only the winner.
---Returns a list of { key, title, allowed = {ft,...}, groups = {g,...} }.
function AnimalAdvisor.candidates(ctx)
    local model = (type(ctx) == "table" and ctx.model) or ctx
    if type(model) ~= "table" or type(model.groups) ~= "table" then return {} end
    local serial = (model.consumptionType == "SERIAL")
    local priceOf = (type(ctx) == "table" and ctx.pricePerLitre) or nil
    local titleOf = (type(ctx) == "table" and ctx.fillTypeTitle) or nil
    local out = {}

    -- WITHIN A GROUP, THE CHEAPEST PRODUCT STRICTLY DOMINATES.
    --
    -- Members of one group carry the SAME `production` weight and the same `eat`
    -- rate, so they contribute an identical food factor -- identical health,
    -- identical output -- and differ only in price. Reported 2026-09-10 against a
    -- SHEEP pen: sheep have ONE group holding both GRASS_WINDROW and
    -- DRYGRASS_WINDROW, so grass and hay are the same 1.0 factor and grass is
    -- cheaper. Generating one candidate per GROUP could never see that, and the
    -- adviser reported "best ration already" over a cheaper equivalent.
    --
    -- This is 33b's "hay strictly dominates silage" one level down: that was
    -- across GROUPS for a cow, this is within ONE group for a sheep.
    -- WHAT THE FARM CAN ACTUALLY DELIVER (2026-09-14). `ctx.stockOf(ft)` answers litres
    -- DR could bring this barn; a member is IN STOCK when that covers at least an hour of
    -- what its group eats. Without it (no DR, or a DR too old to say) every member counts
    -- as in stock, which is the behaviour before this existed. An unanswerable reading is
    -- likewise treated as in stock: unknown is not "none".
    local stockOf = (type(ctx) == "table" and ctx.stockOf) or nil
    local demandH = (type(ctx) == "table" and num(ctx.demandPerHour, 0)) or 0
    local eatAll = 0
    for _, g in ipairs(model.groups) do eatAll = eatAll + num(g.eat, 0) end
    local function inStock(g, ft)
        if stockOf == nil then return true end
        local okS, l = pcall(stockOf, ft)
        if not okS or type(l) ~= "number" then return true end
        local need = serial and demandH or ((eatAll > 0) and demandH * num(g.eat, 0) / eatAll or 0)
        if need <= 0 then return l > 0 end
        return l >= need
    end

    local pick, stocked = {}, {}
    for _, g in ipairs(model.groups) do
        -- the cheapest member IN STOCK, else the cheapest member at all
        local bestFt, bestP, anyFt, anyP = nil, nil, nil, nil
        for _, ft in ipairs(g.fts or {}) do
            local pr = (priceOf ~= nil) and priceOf(ft) or nil
            if pr ~= nil and (anyP == nil or pr < anyP) then anyFt, anyP = ft, pr end
            if inStock(g, ft) then
                stocked[g] = true
                if pr ~= nil and (bestP == nil or pr < bestP) then bestFt, bestP = ft, pr end
            end
        end
        -- an unpriceable group falls back to its first member rather than being
        -- dropped: "cannot be priced" is not "cannot be fed"
        pick[g] = bestFt or anyFt or (g.fts ~= nil and g.fts[1]) or nil
    end

    local function add(key, groups)
        local allowed = {}
        for _, g in ipairs(groups) do
            local ft = pick[g]
            if ft ~= nil then allowed[#allowed + 1] = ft end
        end
        if #allowed == 0 then return end
        -- NAME THE PRODUCT, not the group, for a single-group ration: "Grass" is
        -- an instruction and "Grass group" is a category. Falls back to the group
        -- title where the product cannot be named.
        -- A COMBINED ration has no single product to name, and a nil title
        -- rendered as "?" on the panel (seen in the probe on a horse and a pig).
        -- The group list is the honest name for it.
        local label = nil
        if #groups > 1 then
            local names = {}
            for _, g in ipairs(groups) do names[#names + 1] = tostring(g.title or "?") end
            label = table.concat(names, " + ")
        end
        if #groups == 1 then
            local ft = pick[groups[1]]
            if titleOf ~= nil and ft ~= nil then
                local okT, t = pcall(titleOf, ft)
                if okT and type(t) == "string" and t ~= "" then label = t end
            end
            if label == nil then label = groups[1].title end
        end
        -- THE PRODUCTS, NAMED, for advice that tells the player what to buy:
        -- "Corn + Barley + Red Beet" rather than the group titles.
        local products = {}
        if titleOf ~= nil then
            for _, g in ipairs(groups) do
                local ft = pick[g]
                if ft ~= nil then
                    local okT, t = pcall(titleOf, ft)
                    if okT and type(t) == "string" and t ~= "" then products[#products + 1] = t end
                end
            end
        end
        -- THE FOOD GROUPS, NAMED, for the feed recommendation (author, 2026-09-14):
        -- "Grain + Root crops" says what to provide without tying the player to one
        -- product of each group.
        local groupNames, available = {}, true
        for _, g in ipairs(groups) do
            groupNames[#groupNames + 1] = tostring(g.title or g.key or "?")
            if not stocked[g] then available = false end
        end
        out[#out + 1] = { key = key, title = label, allowed = allowed,
                          groups = groups, fillType = (#groups == 1) and pick[groups[1]] or nil,
                          groupTitle = table.concat(groupNames, " + "),
                          available = available,
                          productTitle = (#products == #groups and #products > 0)
                                         and table.concat(products, " + ") or label }
    end

    for _, g in ipairs(model.groups) do
        add("tier:" .. tostring(g.title or g.key or "?"), { g })
    end

    if not serial and #model.groups > 1 then
        add("all", model.groups)
    end

    -- EVERY OTHER COMBINATION of a PARALLEL animal's groups (2026-09-14). Singles and
    -- the full set above left out exactly the rations that pay best -- for a pig,
    -- everything EXCEPT protein -- so the adviser could never name them.
    local n = #model.groups
    if not serial and n > 2 and n <= AnimalAdvisor.MAX_SUBSET_GROUPS then
        for mask = 1, (2 ^ n) - 2 do
            local groups, m, size = {}, mask, 0
            for i = 1, n do
                if m % 2 == 1 then groups[#groups + 1] = model.groups[i]; size = size + 1 end
                m = math.floor(m / 2)
            end
            if size >= 2 and size <= n - 1 then
                local titles = {}
                for _, g in ipairs(groups) do titles[#titles + 1] = tostring(g.title or g.key or "?") end
                add("set:" .. table.concat(titles, "+"), groups)
            end
        end
    end

    -- THE RATION THEY ARE ACTUALLY ON, priced as its own option.
    --
    -- Candidates use each group's CHEAPEST member, so a player feeding a dearer
    -- product of the same group has nothing to be compared against -- and with no
    -- current option the adviser cannot tell "already best" from "switch", and
    -- defaults to saying it is fine. That is the sheep case in reverse: grass is
    -- the only candidate, so a pen on HAY looked optimal.
    local curFt = (type(ctx) == "table") and ctx.currentFillType or nil
    if curFt ~= nil then
        local already = false
        for _, c in ipairs(out) do
            if c.fillType == curFt then already = true; break end
        end
        if not already then
            for _, g in ipairs(model.groups) do
                for _, ft in ipairs(g.fts or {}) do
                    if ft == curFt then
                        local label = nil
                        if titleOf ~= nil then
                            local okT, t = pcall(titleOf, ft)
                            if okT and type(t) == "string" and t ~= "" then label = t end
                        end
                        out[#out + 1] = { key = "current:" .. tostring(ft),
                                          title = label or g.title, allowed = { ft },
                                          groups = { g }, fillType = ft, isCurrent = true,
                                          available = true }
                        break
                    end
                end
            end
        end
    end
    return out, serial
end

---Price one ration.
--
-- `f` comes from the REAL `AnimalFeedModel.factorOf` against a trough this
-- candidate would produce, so it cannot disagree with the bar on the panel. The
-- cost is computed here rather than through `feedCostPerHour`, which reads the
-- barn's ACTUAL trough (`troughOf`) and so answers about today rather than about
-- a hypothetical -- the one thing an adviser has to be able to ask.
---Returns { key, title, f, costPerMonth, valuePerMonth, profitPerMonth, litres,
-- viable, unpriced } or nil.
function AnimalAdvisor.evaluate(ctx, cand)
    if type(ctx) ~= "table" or type(cand) ~= "table" then return nil end
    local model  = ctx.model
    local demand = num(ctx.demandPerHour, 0)
    if type(model) ~= "table" or demand <= 0 then return nil end

    local plan = ctx.planWithin(model, demand, cand.allowed)
    if type(plan) ~= "table" then return nil end
    local mix = ctx.entriesToMix(plan)
    if type(mix) ~= "table" then return nil end

    local f = num(ctx.factorOf(model, mix, demand), 0)

    -- WHAT IS EATEN, NOT WHAT IS DELIVERED (2026-09-14). planWithin spreads the whole
    -- demand over the groups a ration contains, so a ration of corn alone was costed as
    -- though the pigs ate a full demand of corn. A PARALLEL animal eats each group at
    -- its own share of demand and no more, whatever else is in the trough, so a partial
    -- ration was overpriced by 1 / (its eat share) and the full ration always looked
    -- cheapest. A SERIAL animal's single tier does feed the whole demand, so its plan's
    -- litres were already right.
    local serial = model.consumptionType == "SERIAL"
    local eaten = mix
    if not serial and type(cand.groups) == "table" then
        local eatAll = 0
        for _, g in ipairs(model.groups) do eatAll = eatAll + num(g.eat, 0) end
        if eatAll > 0 then
            eaten = {}
            for _, g in ipairs(cand.groups) do
                local ft = nil
                for _, a in ipairs(cand.allowed or {}) do
                    for _, member in ipairs(g.fts or {}) do
                        if member == a then ft = a end
                    end
                end
                if ft ~= nil then eaten[ft] = (eaten[ft] or 0) + demand * num(g.eat, 0) / eatAll end
            end
        end
    end

    -- COST. Litres per hour at each product's own price, scaled to a month so it
    -- sits beside outputValuePerMonth without either being rebased.
    --
    -- KNOWN LIMIT: THIS DOES NOT MODEL GRAZING. It prices the ration as though
    -- every litre were DELIVERED, while `AnimalEconomics.feedCostPerHour` charges
    -- a grazing barn only for the trough's share of what is available -- so on a
    -- pen feeding off its meadow this OVERSTATES the cost and can under-call the
    -- profitability verdict. `AnimalFeedModel.grazeableOf` answers only yes/no,
    -- not WHICH products the meadow supplies, so the discount cannot be derived
    -- without guessing and is deliberately not attempted here.
    -- It does not affect the RANKING: the overstatement applies to whichever
    -- tier the meadow would serve, and the meadow serves the grass tier a barn
    -- would already be choosing on price.
    local hoursPerMonth = 24 * num(ctx.daysPerMonth, 1)
    local costHour, litres, unpriced = 0, 0, 0
    for ft, l in pairs(eaten) do
        l = num(l, 0)
        litres = litres + l
        local price = ctx.pricePerLitre(ft)
        if price == nil then
            if l > 0 then unpriced = unpriced + 1 end
        else
            costHour = costHour + l * price
        end
    end

    -- VALUE. outputValuePerMonth takes an EFFICIENCY multiplier, and in the steady
    -- state GPF saturates at 1.0 (33b) so the multiplier IS f. That is the whole
    -- reason this comparison is honest: both columns are per month at the same
    -- factor, from the module that already prices outputs.
    local value = 0
    for _, r in ipairs(ctx.rows or {}) do
        local n = num(r.count, 0)
        if n > 0 and r.subType ~= nil then
            -- `.value`, NOT `.total` -- there is no such field, and reading one
            -- returned nil, which `num(nil, 0)` turned into a silent ZERO. Every
            -- ration was then valued at nothing, so every barn read "outputs do
            -- not cover feed" AND the ranking collapsed to "cheapest wins" --
            -- which looked plausible, which is why it shipped. Reported by the
            -- author against a sheep pen the profit table showed in profit.
            --
            -- `.value` is gross output LESS the straw bill, which is the right
            -- basis here: straw is a real cost and does not vary with the ration,
            -- so it cannot move the ranking but does decide profitability.
            local v = ctx.outputValuePerMonth(r.subType, r.age, f)
            if type(v) == "table" then v = v.value end
            value = value + num(v, 0) * n
        end
    end

    local cost = costHour * hoursPerMonth
    return {
        key = cand.key, title = cand.title, f = f, isCurrent = cand.isCurrent,
        -- carried through so the caller can name the PRODUCT it should provide,
        -- which for a single-group ration is the whole instruction
        fillType = cand.fillType,
        litres = litres,
        costPerMonth = cost, valuePerMonth = value,
        profitPerMonth = value - cost,
        viable = (f >= AnimalAdvisor.FEED_FLOOR),
        groups = cand.groups,
        productTitle = cand.productTitle or cand.title,
        groupTitle = cand.groupTitle or cand.title,
        -- every group has a member the farm can deliver (true when stock is unknown)
        available = cand.available ~= false,
        unpriced = unpriced,
    }
end

---THE RATION TO FEED NOW (author, 2026-09-14): the full ration while health is below
-- 100%, then the most profitable ration that holds it.
--
--   RECOVER   health below HEALTH_FULL. The highest-factor ration, cheapest where two
--             tie -- health recovers fastest at a full ration (33a: +10/h against +1/h
--             at the floor), and until it is full every animal sells for less.
--   MAINTAIN  health at 100%. Health no longer needs the extra food (above the floor it
--             holds at 100 whatever the factor), so the ration is the most profitable one
--             at or above the floor: output value minus feed cost. For a pig whose output
--             is only manure that is simply the cheapest ration above 0.28; for a cow in
--             milk the output can pay for a fuller ration, and the ranking says so.
--
-- THE CHEAPEST ONE THE FARM CAN DELIVER (author, 2026-09-14). The options are ranked
-- and the first whose every group is IN STOCK wins: if grain and root crops are not on
-- the farm, the next cheapest combination above the floor that is -- corn alone, say --
-- rather than asking DR for crops it cannot find and falling back to pig food. With
-- nothing above the floor in stock, the full ration is fed (its plan carries the
-- complete ration as the last resort).
--
-- NO SAFETY MARGIN, by the author's call (2026-09-14). A ration that only just clears
-- the floor is one empty silo away from frozen or falling health; that risk is covered
-- by AnimalAlerts instead, which tells the player the moment health drops from 100%,
-- and by this rule itself -- health below 100% puts the barn straight back on RECOVER.
-- With nothing at or above the floor MAINTAIN feeds the full ration.
---Returns option, phase ("RECOVER" / "MAINTAIN"), feedOptions result -- or nil.
function AnimalAdvisor.targetRation(ctx, health)
    local r = AnimalAdvisor.feedOptions(ctx)
    if r == nil then return nil end
    local full = nil
    for _, o in ipairs(r.options) do
        if not o.isCurrent then
            if full == nil or o.f > full.f + 1e-9
               or (math.abs(o.f - full.f) <= 1e-9 and o.costPerMonth < full.costPerMonth) then
                full = o
            end
        end
    end
    if type(health) ~= "number" or health < AnimalAdvisor.HEALTH_FULL then
        return full, "RECOVER", r
    end
    local best = nil
    for _, o in ipairs(r.options) do
        if o.viable and o.available and not o.isCurrent then
            if best == nil or o.profitPerMonth > best.profitPerMonth + 1e-6
               or (math.abs(o.profitPerMonth - best.profitPerMonth) <= 1e-6
                   and o.costPerMonth < best.costPerMonth) then
                best = o
            end
        end
    end
    return best or full, "MAINTAIN", r
end

---Rank every ration and pick one.
--
-- THE FLOOR IS APPLIED BEFORE THE RANKING, NOT AS A TIE-BREAK, and it is the
-- mode's only real influence on the feed decision:
--
--   BREEDER  the floor is HARD. Below it health cannot recover, so the herd stops
--            breeding -- and a herd that doubles is worth far more than the feed
--            saved, whatever the output arithmetic says.
--   PRODUCER the floor still binds, because health below it erodes the capital
--            the animals represent. But if NOTHING is profitable that is worth
--            saying outright rather than dressing a loss up as a recommendation.
--
-- Above the floor the objective is identical in both modes, and that is a finding
-- rather than an omission: health saturates, so the herd-value and breeding terms
-- do not vary with f and cannot move the argmax. Only the FLOOR differs.
---Returns { options = {...}, best, floorBlocked, allUnprofitable, purpose } or nil.
function AnimalAdvisor.feedOptions(ctx)
    if type(ctx) ~= "table" or type(ctx.model) ~= "table" then return nil end
    -- the CTX, not the model: candidates need prices to pick the cheapest
    -- member of each group (a sheep's grass vs hay).
    local cands = AnimalAdvisor.candidates(ctx)
    if #cands == 0 then return nil end

    local opts = {}
    for _, c in ipairs(cands) do
        local e = AnimalAdvisor.evaluate(ctx, c)
        if e ~= nil then opts[#opts + 1] = e end
    end
    if #opts == 0 then return nil end

    -- profit DESC, then factor DESC as a stable tie-break: where two rations earn
    -- the same the healthier one is the better advice, and a tie broken on a table
    -- address is the non-determinism DR 5.89 records.
    table.sort(opts, function(a, b)
        if math.abs(a.profitPerMonth - b.profitPerMonth) > 1e-6 then
            return a.profitPerMonth > b.profitPerMonth
        end
        if math.abs(a.f - b.f) > 1e-9 then return a.f > b.f end
        return tostring(a.key) < tostring(b.key)
    end)

    local viable = {}
    for _, o in ipairs(opts) do if o.viable then viable[#viable + 1] = o end end

    local best = viable[1] or opts[1]
    return {
        options = opts,
        best = best,
        floorBlocked = (#viable == 0),
        allUnprofitable = (best ~= nil and best.profitPerMonth <= 0),
        purpose = AnimalAdvisor.purposeOf(ctx),
    }
end

---THE FEED ADVICE.
--
-- `code` is what the caller renders; every field beside it is the arithmetic that
-- produced it, so the panel can show the number and the harness can check it.
---Returns { code, tone, best, current, options, deltaPerMonth } or nil.
function AnimalAdvisor.feedAdvice(ctx)
    local r = AnimalAdvisor.feedOptions(ctx)
    if r == nil then return nil end
    local cur = num(ctx.factor, nil)
    local best = r.best
    local purpose = r.purpose

    -- NOTHING CLEARS THE FLOOR. The barn cannot reach a factor that lets health
    -- recover at all, which is a different problem from an unprofitable one and
    -- must not be reported as a ration choice.
    if r.floorBlocked then
        return { code = "FLOOR_UNREACHABLE", tone = "bad", best = best,
                 current = cur, options = r.options, floor = AnimalAdvisor.FEED_FLOOR }
    end

    -- THE DEAD ZONE, named explicitly because nothing else on any screen says it:
    -- the barn is holding health exactly where it is, for ever.
    if cur ~= nil and cur >= AnimalAdvisor.DECAY_BELOW and cur < AnimalAdvisor.FEED_FLOOR then
        return { code = "DEAD_ZONE", tone = "bad", best = best, current = cur,
                 options = r.options, floor = AnimalAdvisor.FEED_FLOOR,
                 deltaPerMonth = best.profitPerMonth }
    end
    if cur ~= nil and cur < AnimalAdvisor.DECAY_BELOW then
        return { code = "DECAYING", tone = "bad", best = best, current = cur,
                 options = r.options, floor = AnimalAdvisor.FEED_FLOOR,
                 deltaPerMonth = best.profitPerMonth }
    end

    -- EVERY RATION LOSES MONEY. For a producer that is the answer; for a breeder
    -- the herd is still appreciating and breeding, so the feed bill is not the
    -- whole story and the advice says which is cheapest rather than "stop".
    if r.allUnprofitable then
        local code = (purpose == AnimalAdvisor.PRODUCER) and "UNPROFITABLE" or "BREEDER_SUBSIDY"
        return { code = code, tone = "warn", best = best, current = cur,
                 options = r.options, deltaPerMonth = best.profitPerMonth }
    end

    -- LIKE FOR LIKE, WHICH THE FIRST VERSION WAS NOT.
    --
    -- It compared the barn's MEASURED bill against a HYPOTHETICAL ration price,
    -- and those are different quantities: the measured one is grazing-aware and
    -- the hypothetical one is not, so a pen eating mostly off its meadow beat
    -- every purchasable option by construction and was ALWAYS "optimal". Proved
    -- by probe on a sheep pen -- measured 39.88/mo against a 186.50 grass ration,
    -- because 79% of the ration was grazed. The verdict was right there by luck
    -- (it was already on grass) and would have HIDDEN a real saving on a pen
    -- grazing while topping up with something dearer.
    --
    -- So: rank hypothetical against hypothetical, and use the measured bill only
    -- to scale what a switch is actually WORTH -- you only save on the share you
    -- are buying.
    local curFt = ctx.currentFillType
    local curOpt = nil
    if curFt ~= nil then
        for _, o in ipairs(r.options) do
            if o.fillType == curFt then curOpt = o; break end
        end
    end
    if curOpt == nil and cur ~= nil then
        -- no product named: fall back to the priced option nearest today's factor
        for _, o in ipairs(r.options) do
            if math.abs(o.f - cur) < 0.02 and
               (curOpt == nil or o.profitPerMonth > curOpt.profitPerMonth) then
                curOpt = o
            end
        end
    end

    -- ALREADY ON THE BEST RATION. Compared on PROFIT between two rations priced
    -- the same way -- not on FACTOR, which cannot separate a sheep's grass from
    -- its hay (both 1.0), and not against the measured bill, which cannot be
    -- beaten by anything you buy.
    if curOpt ~= nil and best ~= nil and
       (curOpt == best or curOpt.profitPerMonth >= best.profitPerMonth - 0.01) then
        return { code = "OPTIMAL", tone = "good", best = best, current = cur,
                 options = r.options, deltaPerMonth = 0, currentOption = curOpt }
    end

    -- WHAT THE SWITCH IS WORTH. The sticker difference, scaled by the share of
    -- the ration actually PURCHASED: a pen grazing 79% of its feed saves 21% of
    -- the difference, and quoting the full figure would overstate it fourfold.
    local delta = nil
    if curOpt ~= nil and best ~= nil then
        delta = best.profitPerMonth - curOpt.profitPerMonth
        local measured = num(ctx.currentCostPerMonth, nil)
        if measured ~= nil and curOpt.costPerMonth > 0 then
            local bought = measured / curOpt.costPerMonth
            if bought < 0 then bought = 0 elseif bought > 1 then bought = 1 end
            delta = delta * bought
        end
    end

    return { code = "SWITCH", tone = "warn", best = best, current = cur,
             options = r.options, deltaPerMonth = delta }
end

-- THE HERD ADVISER (herdAdvice) AND saleAdvice ARE GONE (2026-09-24). Neither had a caller: the
-- panel's herd line is nextBirthsAdvice, and the per-breed sale answer is the type tabs' rotation
-- (HusbandryRedux.rotationOf -> sellAgesFor -> saleAge below). saleAge is the part that earned its
-- keep and it stays.

-- ===========================================================================
-- WHEN TO SELL -- the sale-age search
--
-- Adapted from FS25_AnimalPlanner (35), whose objective is right and better than
-- the PAST_PEAK test this replaces: maximise
--
--     sale price at age A  +  net operating profit earned between now and A
--
-- so an animal that EARNS while it appreciates is held longer than the price
-- curve alone would say, and one that earns nothing is sold at its peak. Reading
-- it was what showed our own adviser was answering a smaller question.
--
-- TWO CORRECTIONS IT NEEDS, and both change the answer rather than tidying it:
--
--   1. PRICE THROUGH HEALTH. AnimalPlanner prices off the RAW age curve; the
--      realisable price is `curve(age) x (0.40 + 0.60 x health)` (11.1, confirmed
--      to 0.00000). On a herd at health 0 that is 2.5x optimistic -- and it is
--      not merely a display error, because the same figure drives its ranking.
--      Here it also produces the single most valuable thing this search says:
--      SELLING A SICK HERD NOW REALISES 40% OF BOOK, so "feed first, sell next
--      month" is usually worth thousands and falls straight out of the
--      arithmetic rather than having to be special-cased.
--
--   2. NO PEAK CAP. AnimalPlanner searches only as far as the price peak
--      (`lastAge = max(age, peakAge)`), so anything past it is always "sell now".
--      That is safe only if output falls with age, and 33c measured that NO
--      output curve declines in ANY of the 24 subtypes while price decays just
--      ~21/month (dairy) to ~42/month (beef). A Holstein giving 150 L/day earns
--      far more than that, so keeping it is correct and their model cannot say
--      so. This searches until holding stops paying, which may be never -- and
--      "never" is reported as such rather than as an age.
-- ===========================================================================

-- Far past every base curve's last keyframe (60 months) so the plateau is
-- reached and the "keep indefinitely" case is detected rather than truncated.
AnimalAdvisor.SALE_HORIZON = 120

---The realisable fraction of book value at a given health. 11.1's formula.
function AnimalAdvisor.realise(health)
    local h = num(health, 1)
    if h < 0 then h = 0 elseif h > 1 then h = 1 end
    return 0.40 + 0.60 * h
end

---Book price at an arbitrary age, interpolated from a sampled curve.
--
-- PAST THE LAST SAMPLE IT PLATEAUS, which is not a guess: 33c read all 24
-- subtypes and every curve flattens after its final keyframe -- the six cow
-- declines are all expressed WITHIN the sampled range. Extrapolating the last
-- slope instead would invent a decline that does not exist.
function AnimalAdvisor.priceFromCurve(curve, age)
    if type(curve) ~= "table" or type(curve.samples) ~= "table" then return nil end
    local s = curve.samples
    if #s == 0 then return nil end
    age = num(age, 0)
    if age <= s[1].age then return s[1].price end
    for i = 2, #s do
        if age <= s[i].age then
            local a, b = s[i - 1], s[i]
            if b.age == a.age then return b.price end
            return a.price + (b.price - a.price) * ((age - a.age) / (b.age - a.age))
        end
    end
    return s[#s].price
end

---THE SEARCH, for one cluster.
--
--   ctx.priceAt(age)      book price at full health
--   ctx.netPerMonth(age)  operating profit for ONE animal at that age, per month
--                         (output value less feed and the declared inputs)
--   ctx.healthNow         0..1 -- what the herd would realise if sold today
--   ctx.healthKept        0..1 -- what it will be if kept and fed; defaults to 1
--
-- `healthKept` defaults to FULL because health saturates for any ration above the
-- floor (33a) -- so a herd that is being fed at all recovers to 100 within hours,
-- and pricing its future at today's sick value would recommend panic-selling a
-- herd that is already on the mend.
---Returns { sellNow, bestAge, monthsUntilSale, valueNow, valueAtBest, gain,
-- operatingUntil, keepIndefinitely } or nil.
function AnimalAdvisor.saleAge(ctx, row)
    if type(ctx) ~= "table" or type(row) ~= "table" then return nil end
    if type(ctx.priceAt) ~= "function" then return nil end
    local age = num(row.age, nil)
    if age == nil then return nil end

    local bookNow = ctx.priceAt(age)
    if bookNow == nil then return nil end

    local rNow  = AnimalAdvisor.realise(ctx.healthNow)
    local rKept = AnimalAdvisor.realise(num(ctx.healthKept, 1))
    local horizon = math.floor(num(ctx.horizonMonths, AnimalAdvisor.SALE_HORIZON))

    local valueNow = bookNow * rNow
    local best = { age = age, total = valueNow, price = valueNow, operating = 0 }

    local cum = 0
    for A = age + 1, horizon do
        -- the month just LIVED, so the rate is the one for the age it was at
        local net = 0
        if type(ctx.netPerMonth) == "function" then net = num(ctx.netPerMonth(A - 1), 0) end
        cum = cum + net

        local book = ctx.priceAt(A)
        if book ~= nil then
            local price = book * rKept
            local total = price + cum
            -- a strict improvement, so a plateau does not walk the answer out to
            -- the horizon one indistinguishable month at a time
            if total > best.total + 0.01 then
                best = { age = A, total = total, price = price, operating = cum }
            end
        end
    end

    local n = num(row.count, 1)
    return {
        sellNow = (best.age <= age),
        bestAge = best.age,
        monthsUntilSale = math.max(0, best.age - age),
        valueNow = valueNow * n,
        valueAtBest = best.price * n,
        operatingUntil = best.operating * n,
        gain = (best.total - valueNow) * n,
        -- THE ANSWER ANIMALPLANNER CANNOT GIVE: holding still pays at the far end
        -- of the search, so there is no sale age -- the animal earns more than it
        -- decays and should be kept.
        keepIndefinitely = (best.age >= horizon),
        count = n,
    }
end

-- ===========================================================================
-- BINDING TO THE REAL MODULES
--
-- The core above takes every collaborator through `ctx` so the harness can drive
-- it with no game attached. This is the one place that knows the real names, so
-- a caller writes `AnimalAdvisor.bind{ ... }` and nothing else has to.
--
-- IT FILLS ONLY WHAT IS MISSING, so a caller (or a test) can override any single
-- collaborator without having to supply the rest.
-- ===========================================================================
function AnimalAdvisor.bind(ctx)
    ctx = type(ctx) == "table" and ctx or {}

    if ctx.planWithin == nil and AnimalFeedModel ~= nil then
        ctx.planWithin = function(m, l, a) return AnimalFeedModel.planWithin(m, l, a) end
    end
    if ctx.entriesToMix == nil and AnimalFeedModel ~= nil then
        ctx.entriesToMix = function(e) return AnimalFeedModel.entriesToMix(e) end
    end
    if ctx.factorOf == nil and AnimalFeedModel ~= nil then
        ctx.factorOf = function(m, t, d) return AnimalFeedModel.factorOf(m, t, d) end
    end
    -- Product NAMES, so the advice can say "Grass" rather than name its group.
    if ctx.fillTypeTitle == nil then
        local m = g_fillTypeManager
        if m ~= nil and m.getFillTypeTitleByIndex ~= nil then
            ctx.fillTypeTitle = function(ft)
                local ok, t = pcall(m.getFillTypeTitleByIndex, m, ft)
                if ok and type(t) == "string" and t ~= "" then return t end
                return nil
            end
        end
    end

    if ctx.pricePerLitre == nil and AnimalEconomics ~= nil then
        ctx.pricePerLitre = function(ft) return AnimalEconomics.pricePerLitre(ft) end
    end
    if ctx.outputValuePerMonth == nil and AnimalEconomics ~= nil then
        ctx.outputValuePerMonth = function(st, age, eff)
            return AnimalEconomics.outputValuePerMonth(st, age, eff)
        end
    end
    -- THE PRICE CURVE comes from AnimalSellRules, which already samples it per
    -- subtype at health 100 and CACHES it -- so this cannot disagree with the
    -- Animals tab, and costs nothing after the first call. It needs a live
    -- cluster to clone, which is why the caller passes one.
    if ctx.priceAt == nil and AnimalSellRules ~= nil and ctx.cluster ~= nil then
        local okC, curve = pcall(AnimalSellRules.priceCurve, ctx.cluster)
        if okC and type(curve) == "table" then
            ctx.curve = curve
            ctx.priceAt = function(age) return AnimalAdvisor.priceFromCurve(curve, age) end
        end
    end

    -- WHAT ONE ANIMAL EARNS, NET, AT A GIVEN AGE -- and it must be AGE-CURVED,
    -- not a flat current rate. Output, straw and water are all on age curves
    -- (14.4 / 15.4), so a calf earns nothing and eats anyway; holding it is only
    -- worth it because it APPRECIATES. A constant rate would value a calf as
    -- though it were already milking and recommend keeping the wrong animals.
    --
    -- The feed share is passed in per animal rather than recomputed, so it is the
    -- same ration the feed adviser just priced.
    if ctx.netPerMonth == nil and AnimalEconomics ~= nil and ctx.subType ~= nil then
        local st, pl = ctx.subType, ctx.placeable
        local eff  = num(ctx.efficiency, 1)
        local feed = num(ctx.feedPerAnimalMonth, 0)
        ctx.netPerMonth = function(age)
            -- `.gross` HERE, `.value` IN evaluate -- and the difference is not a
            -- slip. `.value` is gross LESS the straw bill; `declaredInputCostPerMonth`
            -- below supplies straw AND water itself, so taking `.value` here would
            -- charge straw TWICE. (`.total` on that one IS the right field -- it is
            -- the field that function actually returns.)
            local v = AnimalEconomics.outputValuePerMonth(st, age, eff)
            if type(v) == "table" then v = v.gross end
            local c = AnimalEconomics.declaredInputCostPerMonth(st, age, pl)
            local cost = (type(c) == "table" and num(c.total, 0)) or 0
            return num(v, 0) - cost - feed
        end
    end

    if ctx.daysPerMonth == nil and AnimalEconomics ~= nil then
        local ok, d = pcall(AnimalEconomics.daysPerMonth)
        ctx.daysPerMonth = (ok and type(d) == "number") and d or 1
    end

    -- THE PURPOSE COMES FROM THE POLICY the player already set, never from a
    -- guess here: AnimalHerdPolicy owns that choice per (barn, breed) and this
    -- module must not develop a second opinion about it.
    if ctx.purpose == nil and AnimalHerdPolicy ~= nil
       and ctx.uid ~= nil and ctx.breed ~= nil then
        local ok, p = pcall(AnimalHerdPolicy.purposeOf, ctx.uid, ctx.breed)
        if ok then ctx.purpose = p end
    end
    return ctx
end

---EVERY COLLABORATOR RESOLVED? A ctx short of one produces nil rather than a
-- wrong number, and this says which is missing so that failure names itself
-- instead of showing as an empty advice line.
function AnimalAdvisor.missing(ctx)
    local need = { "planWithin", "entriesToMix", "factorOf", "pricePerLitre",
                   "outputValuePerMonth" }
    local out = {}
    for _, k in ipairs(need) do
        if type(ctx) ~= "table" or type(ctx[k]) ~= "function" then out[#out + 1] = k end
    end
    return out
end
