-- ============================================================================
-- AnimalEconomics.lua  (Husbandry Redux)
--
-- WHAT AN ANIMAL IS WORTH KEEPING. Selling a laying hen or a milking cow forfeits
-- a STREAM of income, so the decision is an investment comparison and not a price
-- comparison. This module answers that comparison and nothing else: it reads the
-- world and returns figures. No mutation, no money, no events, no GUI.
--
-- EVERY TERM RESTS ON A MEASURED FACT (CLAUDE.md 14.4, arOutputCurve, 17/17 rows
-- matching the live spec):
--
--   * OUTPUT IS AGE-CURVED. Not a maturity threshold -- a curve, read per subtype:
--         litersPerDay = curve:get(ageMonths) * numAnimals
--     and saleable output is a CLIFF (milk 0 until 12 months then 150/day; eggs 0
--     until 6 then 5/day) while manure and STRAW INTAKE are linear RAMPS from
--     birth. So a young animal produces nothing sellable for 6-12 months while
--     already making manure and eating.
--   * NO OUTPUT CURVE DECLINES. Only the PRICE curve does, and measurement says
--     cows alone (11.3). An old Holstein milks at full rate for ever while losing
--     capital value every month -- which is the entire "sell at peak" case.
--   * spec.litersPerHour IS POTENTIAL, NOT DELIVERY. The health/food term is
--     applied later in updateOutput as productionFactor * globalProductionFactor.
--     A barn at health 0 still reports the full rate. Contribution therefore MUST
--     carry that factor or a starving barn rates identically to a thriving one
--     (the 8.2 "two figures for one quantity" trap, measured on the author's own
--     save where a health-0 cow barn reported 312.5 L/h of milk).
--
-- THE DECISION RULE, and it needs no NPV and no discount rate:
--
--     keep  <=>  earnings/month  >  capital decline/month
--
--   Sell now and you hold S(age) in cash. Keep a month and you hold a month of
--   earnings plus an animal worth S(age+1). So keeping wins exactly when the
--   month's earnings exceed what the month costs you in book value. That is the
--   whole comparison -- no rate anybody can reason about, which is what 14.3 asked
--   for. On a FLAT price curve the decline is zero and any positive earner is a
--   keep, which is why chickens and pigs never show up here and cows do.
--
-- REPLACEMENT IS NOT FREE, and this is what the maturity cliff buys us. Selling an
-- adult to make room for a newborn forfeits the whole run-up to the cliff --
-- 6 months of eggs, 12 months of milk -- so `maturityCost` prices that, and the
-- headroom rule can weigh a slot against a year of production instead of assuming
-- the replacement starts earning on day one.
--
-- PURE, AND SAFE. Curves hang off the SUBTYPE, not the cluster, and :get() is a
-- lookup the base game performs every hour -- so unlike the price sweep this needs
-- no clone and touches no animal. Every world read is pcall'd and every missing
-- input yields nil rather than a zero: a figure we cannot compute must not be
-- presented as "nothing", or the UI states a fact it does not have.
-- ============================================================================

AnimalEconomics = {}

-- Output kinds, and the SHAPE each is declared in. milk and pallets are tables
-- carrying .curve and .fillType; liquidManure, manure and straw ARE the curve.
-- Hardcoding either shape yields nil on the other SILENTLY, so `curveOf` asks.
AnimalEconomics.OUTPUT_KEYS = { "milk", "pallets", "liquidManure", "manure" }

-- ---------------------------------------------------------------------------
---A curve out of either declared shape. Returns curve, fillTypeIndex.
-- A third form returns nil rather than being guessed at.
function AnimalEconomics.curveOf(v)
    if type(v) ~= "table" then return nil, nil end
    if type(v.get) == "function" then return v, nil end
    if type(v.curve) == "table" and type(v.curve.get) == "function" then
        return v.curve, v.fillType
    end
    return nil, nil
end

---Litres per animal per day at an age, or nil if the curve will not answer.
function AnimalEconomics.perAnimalPerDay(v, ageMonths)
    local curve = AnimalEconomics.curveOf(v)
    if curve == nil then return nil end
    local ok, litres = pcall(curve.get, curve, ageMonths or 0)
    if not ok or type(litres) ~= "number" then return nil end
    return litres
end

-- ---------------------------------------------------------------------------
---Days in one in-game month. A "month" is a PERIOD: 11.9 measured the
-- reproduction counter advancing once per period, and ages are stated in months.
-- Defaults to 1, the base game's own default, when the environment is unreadable.
function AnimalEconomics.daysPerMonth()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local d = env ~= nil and env.daysPerPeriod or nil
    if type(d) ~= "number" or d < 1 then return 1 end
    return d
end

---Price per litre, through the same accessor DR uses for every sale it books.
-- Returns nil, never 0, when it cannot be resolved: a product we cannot price is
-- not a product worth nothing.
function AnimalEconomics.pricePerLitre(fillTypeIndex)
    if fillTypeIndex == nil then return nil end
    local econ = g_currentMission ~= nil and g_currentMission.economyManager or nil
    if econ == nil or econ.getPricePerLiter == nil then return nil end
    local ok, p = pcall(econ.getPricePerLiter, econ, fillTypeIndex)
    if not ok or type(p) ~= "number" then return nil end
    return p
end

---The fill type's OWN declared price, which is a different number from the economy
-- price and is what a few base-game code paths bill directly. Returns nil, never 0.
function AnimalEconomics.basePricePerLitre(fillTypeIndex)
    if fillTypeIndex == nil then return nil end
    local m = g_fillTypeManager
    if m == nil or m.getFillTypeByIndex == nil then return nil end
    local ok, def = pcall(m.getFillTypeByIndex, m, fillTypeIndex)
    if not ok or type(def) ~= "table" then return nil end
    local v = def.pricePerLiter
    if type(v) ~= "number" then return nil end
    return v
end

---The barn's own efficiency, as updateOutput applies it: potential x this = real.
-- Both terms, because they answer different questions and both bite -- foodFactor
-- is this hour's ration, globalProductionFactor the hysteresis built up from many
-- hours of it. Missing reads default to 1 so an unreadable barn is costed at its
-- potential rather than silently at zero.
function AnimalEconomics.efficiency(p)
    local spec = p ~= nil and p.spec_husbandry or nil
    if spec == nil then return 1, 1, 1 end
    local gpf = type(spec.globalProductionFactor) == "number" and spec.globalProductionFactor or 1
    local pf  = type(spec.productionFactor) == "number" and spec.productionFactor or 1
    return gpf * pf, gpf, pf
end

-- ---------------------------------------------------------------------------
-- THE OUTPUT SIDE.
--
-- Value per animal per MONTH at a given age, at this barn's efficiency. Manure and
-- slurry are included and are NOT noise: they ramp from birth, so on a young
-- animal they are the only thing it produces at all, and leaving them out would
-- make a calf look like a pure cost.
--
-- STRAW IS SUBTRACTED HERE, not in the feed term. It is declared as subType.input
-- and is age-curved exactly like the outputs, so it belongs with them: a calf both
-- earns less AND beds cheaper, and pricing one without the other overstates the
-- case for selling it.
---Returns { value, gross, strawCost, byFillType = { [ft] = {litres, value} } } or nil.
---WHAT THIS BUILDING CAN ACTUALLY PRODUCE, as a set of output keys.
--
-- AN ANIMAL'S DECLARATION IS NOT A BUILDING'S CAPABILITY. Every output key is read
-- by exactly ONE specialization, and if the placeable does not carry that spec the
-- product is never made at all -- the code that would make it does not run:
--     milk         -> PlaceableHusbandryMilk
--     liquidManure -> PlaceableHusbandryLiquidManure
--     manure       -> PlaceableHusbandryStraw   (it is the straw spec's outputFillType)
--     pallets      -> PlaceableHusbandryPallets
-- Verified by grep across the whole shipped source: one reader each, no overlap.
--
-- REPORTED 2026-08-31: the base Cow Barn (large) listed SLURRY at 2 L/h. COW_ANGUS
-- declares output.liquidManure, so the animal is willing -- but specialCowStable has
-- no <liquidManure> block, so the barn has no slurry spec and can never make a drop.
-- It was not merely a wrong row: outputValuePerMonth counted those litres, so the
-- PROFIT figure was crediting a product the building is physically unable to make.
--
-- nil `p` returns nil, meaning "no opinion" -- every caller then keeps the animal's
-- full declaration, which is the pre-existing behaviour.
function AnimalEconomics.producibleOutputKeys(p)
    if p == nil then return nil end
    return {
        milk         = p.spec_husbandryMilk ~= nil,
        liquidManure = p.spec_husbandryLiquidManure ~= nil,
        manure       = p.spec_husbandryStraw ~= nil,
        pallets      = p.spec_husbandryPallets ~= nil,
    }
end

---`allowed` is a producibleOutputKeys set, or nil to keep every declared output.
function AnimalEconomics.outputValuePerMonth(subType, ageMonths, efficiency, allowed)
    if type(subType) ~= "table" then return nil end
    local days = AnimalEconomics.daysPerMonth()
    local eff = type(efficiency) == "number" and efficiency or 1

    local out = { value = 0, gross = 0, strawCost = 0, byFillType = {}, priced = 0, unpriced = 0 }
    local o = subType.output or {}

    for _, key in ipairs(AnimalEconomics.OUTPUT_KEYS) do
        local decl = o[key]
        -- a product the BUILDING has no spec for is never made, whatever the animal
        -- declares, so it must not be valued either
        if allowed ~= nil and allowed[key] ~= true then decl = nil end
        if decl ~= nil then
            local _, ftFromWrapper = AnimalEconomics.curveOf(decl)
            local perDay = AnimalEconomics.perAnimalPerDay(decl, ageMonths)
            if perDay ~= nil and perDay > 0 then
                -- A bare curve declares no fill type of its own; the KEY names it.
                local ft = ftFromWrapper
                if ft == nil then ft = AnimalEconomics.fillTypeForKey(key) end
                local litres = perDay * days * eff
                local price = AnimalEconomics.pricePerLitre(ft)
                -- INDEXED BY `ft or key`, NEVER by a bare `ft`. An unresolvable
                -- fill type is nil, and a nil table index is a hard throw -- which
                -- from a GUI populate aborts the page mid-render and shows an
                -- EMPTY list, a symptom nothing like its cause (DR 5.44 / 5.57).
                local slot = ft or key
                if price ~= nil then
                    local v = litres * price
                    out.gross = out.gross + v
                    out.value = out.value + v
                    out.priced = out.priced + 1
                    out.byFillType[slot] = { litres = litres, value = v, key = key }
                else
                    out.unpriced = out.unpriced + 1
                    out.byFillType[slot] = { litres = litres, value = nil, key = key }
                end
            end
        end
    end

    local strawPerDay = AnimalEconomics.perAnimalPerDay((subType.input or {}).straw, ageMonths)
    if strawPerDay ~= nil and strawPerDay > 0 then
        -- Bedding is consumed whatever the barn's production efficiency, so it is
        -- NOT scaled by eff: a barn producing nothing is still using straw.
        local ft = AnimalEconomics.fillTypeForKey("straw")
        local price = AnimalEconomics.pricePerLitre(ft)
        if price ~= nil then
            out.strawCost = strawPerDay * days * price
            out.value = out.value - out.strawCost
        end
    end

    return out
end

---A fill type index for an output declared as a bare curve, which names no fill
-- type of its own. Resolved by NAME through the manager rather than tabulated, so
-- an install that renumbers its fill types still answers correctly.
local KEY_TO_FILLTYPE = {
    liquidManure = "LIQUIDMANURE",
    manure       = "MANURE",
    straw        = "STRAW",
    -- WATER IS A DECLARED INPUT AND WAS SIMPLY NEVER LISTED. PlaceableHusbandryWater
    -- reads subType.input.water on exactly the same age curve straw uses, and with
    -- automaticWaterSupply the base game BILLS for it outright
    -- (addMoney(-price, ... MoneyType.PURCHASE_WATER)). So it is a real cost, on a
    -- curve we already know how to read, and leaving it out understated every barn.
    water        = "WATER",
}
function AnimalEconomics.fillTypeForKey(key)
    local name = KEY_TO_FILLTYPE[key]
    if name == nil then return nil end
    local ftm = g_fillTypeManager
    if ftm == nil or ftm.getFillTypeIndexByName == nil then return nil end
    local ok, idx = pcall(ftm.getFillTypeIndexByName, ftm, name)
    if not ok or type(idx) ~= "number" then return nil end
    return idx
end

-- ---------------------------------------------------------------------------
-- THE INPUT SIDE.
--
-- Everything the barn TAKES IN, at today's prices, and it comes from two sources
-- that cannot be merged: FOOD is per GROUP and its cost depends on WHICH product
-- satisfies the tier (TMR and grass are the same litres at wildly different
-- money), while STRAW and WATER are per SUBTYPE on their own age curves.
--
-- `food` IS DELIBERATELY EXCLUDED from the declared-input walk. subType.input has
-- exactly three keys -- food, straw, water (read from PlaceableHusbandryFood /
-- Straw / Water, all three complete in the SDK source) -- and `food` is the same
-- litres the group machinery below already prices. Counting both would double the
-- largest cost on the barn.
local DECLARED_INPUT_SKIP = { food = true }

---The subtype behind a cluster's INDEX. Resolved here rather than through
-- AnimalHerdData so the dependency stays one-way: that module reads this one.
function AnimalEconomics._subTypeOf(subTypeIndex)
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil or asys.getSubTypeByIndex == nil or subTypeIndex == nil then return nil end
    local ok, st = pcall(asys.getSubTypeByIndex, asys, subTypeIndex)
    if ok and type(st) == "table" then return st end
    return nil
end

---What one animal's non-food inputs cost per MONTH at this age. Straw and water,
-- on the same curves the engine sums in onHusbandryAnimalsUpdate, so this and
-- spec.inputLitersPerHour / spec.litersPerHour agree by construction rather than
-- by a second model -- and unlike those specs it is computed rather than read, so
-- it answers on a multiplayer client where the server-side sums may be zero.
--
-- NOT SCALED BY EFFICIENCY, exactly as 15.4 has straw: bedding and water are
-- consumed whatever the barn produces, which is what makes a starving barn a NET
-- COST rather than merely a zero.
---Returns { total, byFillType = { [ft] = { litres, cost } }, unpriced } or nil.
---`placeable` is OPTIONAL and only decides whether WATER is billed. Without it
-- water is FREE, which is the right default for a PER-ANIMAL figure: the question
-- "what does one cow cost" has no barn attached, and water is unsellable so its
-- opportunity cost is zero either way. Pass the barn where the automatic-supply
-- debit matters, and this agrees with declaredInputCostPerHour by construction
-- rather than by a second model.
function AnimalEconomics.declaredInputCostPerMonth(subType, ageMonths, placeable)
    if type(subType) ~= "table" then return nil end
    local days = AnimalEconomics.daysPerMonth()
    local out = { total = 0, byFillType = {}, unpriced = 0 }
    local waterAuto = false
    if placeable ~= nil then
        local ws = placeable.spec_husbandryWater
        waterAuto = (ws ~= nil and ws.automaticWaterSupply == true)
    end
    for _, r in ipairs(AnimalEconomics.declaredInputRates(subType, ageMonths)) do
        local price
        if r.key == "water" then
            if waterAuto then
                price = AnimalEconomics.basePricePerLitre(r.fillType)
                if price == nil then price = AnimalEconomics.pricePerLitre(r.fillType) end
            else
                price = 0        -- free: unsellable, and drawn at no cost
            end
        else
            price = AnimalEconomics.pricePerLitre(r.fillType)
        end
        local litres = r.perDay * days
        -- `ft or key` as the index, never a bare ft: a nil table index is a hard
        -- throw, and from a GUI populate that aborts the page mid-render and shows
        -- an EMPTY list (15.6, DR 5.44 / 5.57)
        local slot = r.fillType or r.key
        if price ~= nil then
            local c = litres * price
            out.total = out.total + c
            out.byFillType[slot] = { litres = litres, cost = c, key = r.key }
        else
            out.unpriced = out.unpriced + 1
            out.byFillType[slot] = { litres = litres, cost = nil, key = r.key }
        end
    end
    return out
end

-- NOTE ON WHAT THIS IS FOR. It is the per-animal POTENTIAL -- what one animal would
-- consume if the barn had it -- and is the right question for a per-animal model.
-- The BARN's bill is declaredInputCostPerHour below, which gates the same rates on
-- what is actually there. Do not use this one to compute a barn total: that is the
-- -31 vs -24 disagreement it caused once already.

---The non-food inputs one animal consumes per DAY at this age, with the fill type
-- each resolves to. ONE rate source for both the per-animal cost below and the
-- barn-level bill beneath it, so the table and the profit line cannot quote
-- different litres for the same straw.
function AnimalEconomics.declaredInputRates(subType, ageMonths)
    local out = {}
    if type(subType) ~= "table" then return out end
    for key, decl in pairs(subType.input or {}) do
        if not DECLARED_INPUT_SKIP[key] then
            local perDay = AnimalEconomics.perAnimalPerDay(decl, ageMonths or 0)
            if perDay ~= nil and perDay > 0 then
                out[#out + 1] = { key = key, fillType = AnimalEconomics.fillTypeForKey(key),
                                  perDay = perDay }
            end
        end
    end
    table.sort(out, function(a, b) return tostring(a.key) < tostring(b.key) end)
    return out
end

---IS THIS INPUT ACTUALLY AVAILABLE TO BE CONSUMED, and how much of it.
--
-- Returns litres held and an `auto` flag. nil litres means UNLIMITED -- either the
-- base game supplies it automatically, or we cannot tell, and the fail direction is
-- deliberate: charging in full is the figure that shipped before this gate, while
-- reporting a free ration is a silently flattering error (the same argument
-- feedCostPerHour's own fallback carries).
--
-- WATER MAY BE BILLED WITHOUT EVER BEING STORED. PlaceableHusbandryWater:
-- updateFeeding calls addMoney(-price, ..., MoneyType.PURCHASE_WATER) outright when
-- `automaticWaterSupply` is set -- and onLoad FORCES that flag on for any husbandry
-- that does not support WATER as a fill type at all. So a barn with no water tank
-- is not drinking for free; it is paying by direct debit, and its stock reads 0
-- because there is nothing to store it in.
function AnimalEconomics.declaredInputAvailable(p, key, fillTypeIndex)
    if key == "water" then
        local ws = p ~= nil and p.spec_husbandryWater or nil
        if ws ~= nil and ws.automaticWaterSupply == true then return nil, true end
    end
    if p == nil or p.getHusbandryFillLevel == nil or fillTypeIndex == nil then return nil, false end
    local ok, lvl = pcall(p.getHusbandryFillLevel, p, fillTypeIndex)
    if ok and type(lvl) == "number" then return math.max(0, lvl), false end
    return nil, false
end

---THE BARN'S NON-FOOD INPUT BILL, per hour, at today's prices.
--
-- The twin of feedCostPerHour and gated the same way -- what is actually being
-- CONSUMED, never what the animals would eat if it were there. The two had to be
-- reconciled: the profit line was charging straw and water unconditionally while
-- the inputs table showed both at zero, so a barn read -31 in one place and -24 in
-- the other for the same hour. Reported 2026-08-31.
--
-- The table's zero was the WORSE of the two errors and the reason it went
-- unnoticed: it came from `trough[ft]`, which only ever holds FOOD fill types, so
-- straw and water resolved nil and read as "using nothing" on every barn ever
-- shown. A permanent false zero, and the "-" in its HELD column was the tell.
--
-- `rows` are assess rows (count, age, subTypeIndex) -- the same shape summarise
-- takes, so the caller passes what it already holds.
---Returns { perHour, byFillType = { [ft] = { key, rate, consumed, held, auto, cost } },
-- unpriced } or nil.
function AnimalEconomics.declaredInputCostPerHour(p, rows)
    if type(rows) ~= "table" then return nil end
    local acc = {}
    for _, e in ipairs(rows) do
        local n = e.count or 0
        local st = e.subType
        if st == nil then st = AnimalEconomics._subTypeOf(e.subTypeIndex) end
        if n > 0 and st ~= nil then
            for _, r in ipairs(AnimalEconomics.declaredInputRates(st, e.age)) do
                -- `ft or key` as the index, never a bare ft: a nil table index is a
                -- hard throw, and from a GUI populate that aborts the page
                -- mid-render (15.6, DR 5.44 / 5.57)
                local slot = r.fillType or r.key
                local a = acc[slot]
                if a == nil then a = { key = r.key, fillType = r.fillType, rate = 0 }; acc[slot] = a end
                a.rate = a.rate + r.perDay * n / 24        -- per animal per DAY -> barn per HOUR
            end
        end
    end

    local out = { perHour = 0, byFillType = {}, unpriced = 0 }
    for slot, a in pairs(acc) do
        local held, auto = AnimalEconomics.declaredInputAvailable(p, a.key, a.fillType)
        -- over ONE hour the barn can consume at most what it is holding
        local consumed = (held == nil) and a.rate or math.min(a.rate, held)
        -- AUTOMATIC WATER IS BILLED BY A FORMULA WE CAN READ, so use it rather than
        -- the economy price. PlaceableHusbandryWater:updateFeeding charges
        -- `delta * fillType.pricePerLiter` -- the fill type's BASE declaration, not
        -- economyManager:getPricePerLiter -- so pricing it any other way quotes a
        -- number the player is not actually being charged. Every other input here
        -- is bought at a trigger, and FillTrigger uses the economy price, which is
        -- why that stays the default.
        --
        -- WATER IS FREE UNLESS THE GAME IS ACTUALLY BILLING FOR IT.
        --
        -- Author's ruling 2026-09-10: water cannot be sold -- maps_fillTypes.xml
        -- declares WATER `showOnPriceTable="false"` -- and it is drawn from a
        -- source that costs nothing, so its OPPORTUNITY COST IS ZERO and pricing
        -- it at the economy rate charged the barn for something the player could
        -- never have realised. That is the cash-vs-economic confusion this module
        -- already carries a note about, and water is the one input where the
        -- economic price is unambiguously wrong.
        --
        -- THE ONE EXCEPTION IS REAL CASH, NOT AN OPPORTUNITY COST. With
        -- `automaticWaterSupply` the base game DEBITS THE BALANCE outright
        -- (PlaceableHusbandryWater:updateFeeding -> addMoney(-price, ...,
        -- MoneyType.PURCHASE_WATER)), and it has its own finance category, so the
        -- player can see it. Dropping that would make this profit figure disagree
        -- with the bank, which is the opposite of the fix being asked for. It is
        -- also NOT a small number: a cow drinks 140 L/day at 0.1/L, so 96 cows on
        -- automatic supply are billed ~1,344 a day against a hay bill of ~5,300.
        --
        -- Note `onLoad` FORCES automaticWaterSupply on for any husbandry that does
        -- not support WATER as a fill type, so the billed case is common, not an
        -- edge. A barn with a real water tank pays nothing.
        local price = nil
        if a.key == "water" then
            -- 0, NOT nil. nil means "cannot be priced" and would flag the barn's
            -- total as unknown; this is a known and exact ZERO (5.46c -- in this
            -- codebase 0 is a real value and must never be conflated with absent).
            -- if/else, never `auto and price or 0`: that collapsing form is what
            -- 5.44 and 5.46c both record being bitten by, and writing it directly
            -- under a comment about 0-vs-nil would be asking for it.
            if auto then
                -- BILLED. Prefer the game's own formula; fall back to the economy
                -- price; and if neither resolves leave it NIL so the barn reports
                -- an unknown total. NOT 0 -- the player is being charged something
                -- we merely cannot quantify, and zero would be the silently
                -- flattering error this module's own fail-direction note warns of.
                price = AnimalEconomics.basePricePerLitre(a.fillType)
                if price == nil then price = AnimalEconomics.pricePerLitre(a.fillType) end
            else
                price = 0          -- free: unsellable, drawn at no cost
            end
        else
            if auto then price = AnimalEconomics.basePricePerLitre(a.fillType) end
            if price == nil then price = AnimalEconomics.pricePerLitre(a.fillType) end
        end
        local cost = nil
        if price ~= nil then
            cost = consumed * price
            out.perHour = out.perHour + cost
        elseif consumed > 0 then
            -- only what is actually being CHARGED can make the total unknown
            out.unpriced = out.unpriced + 1
        end
        out.byFillType[slot] = { key = a.key, fillType = a.fillType, rate = a.rate,
                                 consumed = consumed, held = held, auto = auto, cost = cost }
    end
    return out
end



---WHAT THE BARN IS ACTUALLY EATING, per hour, at today's prices.
--
-- THE TIER RULE IS NOT A NEW ONE. SERIAL means the best tier actually PRESENT
-- feeds the whole herd; PARALLEL means every group with stock contributes. That is
-- the same rule the husbandry panel names its active tier by and the same one the
-- inputs table reads -- which is why it lives HERE and all three call it. Taking a
-- second opinion is how a table and the panel above it come to disagree about
-- which tier is live (18.16), and how a profit figure comes to disagree with the
-- cost column it is computed from.
--
-- GRAZED GRASS IS FREE, and that is the correction this function exists to carry.
-- getAvailableFood returns trough PLUS meadow (measured: a cow barn holding only
-- hay and silage still reported 828 L of grass available), so charging market price
-- against availability bills the farm for a pasture it already owns -- and a barn
-- feeding entirely off its meadow, every group reading 0 L in the trough, would
-- have been charged in full for eating nothing it bought. Litres are therefore
-- charged in PROPORTION TO THE TROUGH's share of what is available, which is exact
-- at both ends (all trough -> full charge, all meadow -> nothing) and the only
-- defensible reading in between, since the engine does not say which it draws
-- first.
--
--   p       the husbandry placeable
--   model   AnimalFeedModel.read(...) for this barn
--   avail   ft -> litres AVAILABLE (trough + meadow), what sets the tier
--   demand  litres per hour, the barn's real appetite
---Returns { perHour, byFillType = { [ft] = { eaten, charged, cost } }, unpriced,
-- activeTitle } or nil.
function AnimalEconomics.feedCostPerHour(p, model, avail, demand)
    if type(model) ~= "table" or type(model.groups) ~= "table" then return nil end
    avail = type(avail) == "table" and avail or {}
    demand = type(demand) == "number" and demand or 0

    -- THE TROUGH ALONE -- what the farm actually delivered and paid for.
    --
    -- IT FALLS BACK TO `avail`, NOT TO AN EMPTY TABLE, and the direction matters:
    -- with no trough reading every litre would be treated as grazed and the barn
    -- would report a FREE ration, which inflates profit and reads as though the
    -- feed were costing nothing. Falling back to availability charges for
    -- everything, which is exactly the behaviour that shipped before the grazing
    -- correction -- an over-statement we already lived with, rather than a
    -- silently flattering one. An EMPTY table that troughOf genuinely returned is
    -- a real answer ("nothing delivered") and is charged as zero.
    local delivered = nil
    if AnimalFeedModel ~= nil and AnimalFeedModel.troughOf ~= nil then
        local ok, t = pcall(AnimalFeedModel.troughOf, p)
        if ok and type(t) == "table" then delivered = t end
    end
    if delivered == nil then delivered = avail end

    local serial = model.consumptionType == "SERIAL"
    local eatSum = 0
    for _, g in ipairs(model.groups) do eatSum = eatSum + (g.eat or 0) end

    -- WHICH TIER IS LIVE, decided on AVAILABILITY rather than on the trough: meadow
    -- grass genuinely sets the food factor even though it costs nothing.
    local active, activeShare = nil, -1
    if serial then
        for _, g in ipairs(model.groups) do
            local held = 0
            for _, ft in ipairs(g.fts or {}) do held = held + (avail[ft] or 0) end
            if held > 0 and (g.production or 0) > activeShare then
                active, activeShare = g, (g.production or 0)
            end
        end
    end

    local out = { perHour = 0, byFillType = {}, unpriced = 0,
                  activeTitle = active ~= nil and active.title or nil }
    for _, g in ipairs(model.groups) do
        local availHeld, troughHeld = 0, 0
        for _, ft in ipairs(g.fts or {}) do
            availHeld  = availHeld  + (avail[ft] or 0)
            troughHeld = troughHeld + (delivered[ft] or 0)
        end
        local need = 0
        if demand > 0 then
            if serial then need = demand
            elseif eatSum > 0 then need = demand * (g.eat or 0) / eatSum end
        end
        -- never more than it holds, and nothing at all if a better tier covers the herd
        local feeding = (not serial) or (g == active)
        local eaten = feeding and math.min(need, availHeld) or 0
        local charged = 0
        if eaten > 0 and availHeld > 0 then charged = eaten * troughHeld / availHeld end

        for _, ft in ipairs(g.fts or {}) do
            local price = AnimalEconomics.pricePerLitre(ft)
            -- WITHIN a tier the eaten litres split by what is HELD of each product,
            -- on the TROUGH figures because those are the litres being charged for
            local mine = 0
            if charged > 0 and troughHeld > 0 then
                mine = charged * (delivered[ft] or 0) / troughHeld
            end
            local ate = 0
            if eaten > 0 and availHeld > 0 then ate = eaten * (avail[ft] or 0) / availHeld end
            local e = out.byFillType[ft]
            if e == nil then
                e = { eaten = 0, charged = 0, cost = price ~= nil and 0 or nil }
                out.byFillType[ft] = e
            end
            -- a product can appear in more than one tier, so accumulate
            e.eaten = e.eaten + ate
            e.charged = e.charged + mine
            if price ~= nil then
                e.cost = (e.cost or 0) + mine * price
                out.perHour = out.perHour + mine * price
            elseif mine > 0 then
                -- `unpriced` IS THE TRUST FLAG ON THE TOTAL, so it counts only what
                -- is actually being CHARGED. Counting every unpriceable product the
                -- barn merely SUPPORTS would blank the profit on a cow barn eating
                -- nothing but silage because some tier lists a product with no
                -- market price -- a term worth zero litres cannot make a total
                -- unknown. The per-product `cost` is still nil either way, which is
                -- what the inputs column reads.
                out.unpriced = out.unpriced + 1
            end
        end
    end

    -- ---- FEEDING ROBOT: CHARGE THE INGREDIENTS, NOT THE MIX ------------------
    --
    -- Reported 2026-09-09. A robot barn mixes silage, straw, hay and mineral feed
    -- from its own bunkers into TMR and puts only the TMR in the trough -- so the
    -- loop above, which reads the trough, charged the ENTIRE ration against a
    -- product the farm has never bought a litre of, while the four it actually
    -- bought contributed nothing. Mineral feed did not appear anywhere at all: it
    -- is in no cow food group and no declared subtype input, so no row could exist
    -- for it on any table, and at 1.20/L against silage at 0.121 it is by far the
    -- most expensive thing in the mix.
    --
    -- THE MIX IS NOT FREE, IT IS ALREADY PAID FOR -- one step earlier, as
    -- ingredients. So its cost moves rather than vanishing, and the total stays
    -- honest. What changes is WHERE it lands, which is what makes the inputs table
    -- describe money the farm actually spends.
    --
    -- RATES COME OFF WHAT WAS EATEN, not off demand: the robot mixes what the herd
    -- consumes, so a barn eating half its demand is buying half the ingredients.
    -- That also keeps this column meaning what COST NOW means everywhere else.
    local mixedFt = (AnimalFeedModel ~= nil and AnimalFeedModel.mixedFillTypeOf ~= nil)
        and AnimalFeedModel.mixedFillTypeOf(p) or nil
    local mixEntry = mixedFt ~= nil and out.byFillType[mixedFt] or nil
    if mixEntry ~= nil then
        local mixedEaten = mixEntry.eaten or 0
        if mixEntry.cost ~= nil then out.perHour = out.perHour - mixEntry.cost end
        mixEntry.cost = 0                     -- produced here; the ingredients carry it
        mixEntry.produced = true              -- the PRODUCED table reads this
        out.producedFillType = mixedFt

        -- ASK THE RECIPE, NOT THE RATES. Empty rates have TWO causes and only one of
        -- them is an unknown: the recipe genuinely would not read, or the barn simply
        -- is not eating (an empty pool between mixes, or no animals). Testing the
        -- rates conflated them, and because HusbandryRedux.lua blanks the ENTIRE profit
        -- block on any unpriced term, a robot barn caught between batches reported no
        -- profit at all. Reported 2026-09-09, straight after the first build.
        --
        -- A barn eating nothing has a perfectly well known feed cost, and it is ZERO.
        -- Only an unreadable recipe is an unknown, and only that raises the flag.
        local rec = (AnimalFeedModel.robotRecipeOf ~= nil)
            and AnimalFeedModel.robotRecipeOf(p) or nil
        local rates = {}
        if rec == nil then
            out.recipeUnreadable = true
            out.unpriced = out.unpriced + 1
        elseif mixedEaten > 0 and AnimalFeedModel.robotIngredientRates ~= nil then
            rates = AnimalFeedModel.robotIngredientRates(p, mixedEaten)
        end
        for ft, litres in pairs(rates) do
            local price = AnimalEconomics.pricePerLitre(ft)
            local e = out.byFillType[ft]
            if e == nil then
                e = { eaten = 0, charged = 0, cost = price ~= nil and 0 or nil }
                out.byFillType[ft] = e
            end
            e.ingredient = true
            e.eaten = (e.eaten or 0) + litres
            e.charged = (e.charged or 0) + litres      -- a bunker is always delivered, never grazed
            if price ~= nil then
                e.cost = (e.cost or 0) + litres * price
                out.perHour = out.perHour + litres * price
            elseif litres > 0 then
                out.unpriced = out.unpriced + 1
            end
        end
    end

    -- ---- COMPLETE RATIONS: CHARGE THE MIX, NOT THE CROPS IT BECAME ---------
    --
    -- 2026-09-14. Pig food is split into its crops the moment it reaches the
    -- trough (AnimalFeedModel.MixLedger), so the loop above charged it as maize,
    -- wheat, soybean and potato at CROP prices -- about a third of what the farm
    -- paid. The ledger knows what share of each crop came from a mixture, so that
    -- share of the charged litres moves from the crop to the mixture, at the
    -- mixture's price. The robot pass above is the same move in the other
    -- direction: there the mix was charged and the ingredients were bought.
    --
    -- Only CHARGED litres move: a mixture is always a delivery, never grazing, and
    -- the shares are shares of the trough.
    local ML = AnimalFeedModel ~= nil and AnimalFeedModel.MixLedger or nil
    if ML ~= nil and ML.sharesOf ~= nil then
        local mixes = {}
        for ft, e in pairs(out.byFillType) do
            local shares = ML.sharesOf(p, ft)
            for mixFt, s in pairs(shares) do
                local part = (e.charged or 0) * s
                if part > 0 then
                    local cropPrice = AnimalEconomics.pricePerLitre(ft)
                    if cropPrice ~= nil and e.cost ~= nil then
                        e.cost = e.cost - part * cropPrice
                        out.perHour = out.perHour - part * cropPrice
                    end
                    e.fromMix = (e.fromMix or 0) + part
                    local m = mixes[mixFt]
                    if m == nil then m = { litres = 0, byIngredient = {} }; mixes[mixFt] = m end
                    m.litres = m.litres + part
                    m.byIngredient[ft] = (m.byIngredient[ft] or 0) + part
                end
            end
        end
        for mixFt, m in pairs(mixes) do
            local price = AnimalEconomics.pricePerLitre(mixFt)
            local e = out.byFillType[mixFt]
            if e == nil then
                e = { eaten = 0, charged = 0, cost = price ~= nil and 0 or nil }
                out.byFillType[mixFt] = e
            end
            e.mixture = true
            e.eaten = (e.eaten or 0) + m.litres
            e.charged = (e.charged or 0) + m.litres
            e.ingredients = m.byIngredient
            if price ~= nil then
                e.cost = (e.cost or 0) + m.litres * price
                out.perHour = out.perHour + m.litres * price
            else
                out.unpriced = out.unpriced + 1
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- THE CAPITAL SIDE.
--
-- How much book value one animal loses per month at its current age, taken as a
-- LOCAL slope off the measured price curve rather than a species constant -- so a
-- modded animal answers for itself and a curve that is flat here and falls later
-- is read correctly at both ages.
--
-- AnimalSellRules.priceCurve samples every 3 months, so the slope is read across
-- the bracketing samples and divided back to a month. A POSITIVE return means the
-- animal is still appreciating.
--
-- THE CURVE IS SAMPLED AT HEALTH 100, AND THE ANIMAL IS NOT. priceCurve sets
-- `c.health, c.age = 100, age` on every clone, deliberately -- it is measuring the
-- age curve, and a herd's health must not change the shape of it. But the SLOPE it
-- yields is therefore a full-health slope, while everything it is displayed beside
-- -- HERD VALUE, GROUP VALUE, `each` -- is the real `getSellPrice`, which is
-- `curve(age) x (0.40 + 0.60 x health)` (11.1, confirmed to the cent). Reported
-- unscaled it is the value change of an animal the player does not own.
--
-- CAUGHT FROM A SCREENSHOT 2026-08-31: 20 Angus calves at 7% health, GROUP VALUE
-- 2,033 EUR, VALUE +/- MO reading +2,308 -- a herd more than doubling in a month.
-- The curve is genuinely steep at that age, but 0.40 + 0.60 x 0.07 = 0.442, so the
-- figure was over-stated by 1/0.442 = 2.26x. It is EXACT at full health, which is
-- why it had gone unnoticed: only an unhealthy barn shows it.
--
-- `healthPct` is 0..100 (a cluster's own scale) and is OPTIONAL: passing nothing
-- returns the raw full-health slope, which is what the curve itself describes.
---Returns decline per month (positive = losing value), or nil if unknown.
function AnimalEconomics.capitalDriftPerMonth(curve, ageMonths, healthPct)
    if type(curve) ~= "table" or type(curve.samples) ~= "table" then return nil end
    local s = curve.samples
    if #s < 2 then return nil end
    local age = ageMonths or 0

    local before, after = nil, nil
    for _, e in ipairs(s) do
        if e.age <= age then before = e end
        if after == nil and e.age > age then after = e end
    end
    -- Past the end of the sampled range the curve has plateaued or is still
    -- falling at its last measured rate; use the final pair rather than inventing
    -- a value or returning nil, which would read as "no information".
    if after == nil then before, after = s[#s - 1], s[#s] end
    if before == nil or after == nil or after.age == before.age then return nil end

    local perMonth = (before.price - after.price) / (after.age - before.age)
    -- 11.1's own formula, applied to the SLOPE because it applies to both prices
    -- the slope is a difference of: h x (a - b) == (h x a) - (h x b).
    if type(healthPct) == "number" then
        perMonth = perMonth * (0.40 + 0.60 * math.max(0, math.min(100, healthPct)) / 100)
    end
    return perMonth
end

-- ---------------------------------------------------------------------------
-- THE MATURITY COST.
--
-- What a replacement forfeits before it earns anything. Selling an adult to free a
-- slot is only a gain if the animal that fills it starts producing -- and 14.4
-- measured that saleable output is a CLIFF, so a newborn produces nothing sellable
-- for 6 months (eggs) or 12 (milk).
--
-- Costed as the value of the months BELOW the cliff, at the adult's rate: what the
-- slot would have earned had it held a productive animal instead. Manure and straw
-- are excluded deliberately -- a newborn makes manure from day one, so those terms
-- do not differ between keeping and replacing and would cancel.
-- The onset is a property of the SUBTYPE and never moves, while this is reached
-- once per cluster per UI refresh -- so the forward scan is memoised and the rest
-- is arithmetic. Weak keys, so a subtype table going away takes its entry with it.
local _onsetCache = setmetatable({}, { __mode = "k" })

---The first age at which a declared output is non-zero, or nil if it never is.
function AnimalEconomics.onsetAge(decl)
    if type(decl) ~= "table" then return nil end
    local hit = _onsetCache[decl]
    if hit ~= nil then
        if hit == false then return nil end
        return hit
    end
    local first = nil
    for a = 0, 48 do
        local v = AnimalEconomics.perAnimalPerDay(decl, a)
        if v ~= nil and v > 0 then first = a; break end
    end
    _onsetCache[decl] = (first ~= nil) and first or false
    return first
end

---Returns { months, valuePerMonth, cost } or nil when nothing is age-gated.
---`allowed` is a producibleOutputKeys set, or nil to keep every declared output.
function AnimalEconomics.maturityCost(subType, adultAgeMonths, efficiency, allowed)
    if type(subType) ~= "table" then return nil end
    local days = AnimalEconomics.daysPerMonth()
    local eff = type(efficiency) == "number" and efficiency or 1
    local o = subType.output or {}

    local onset, perMonth = nil, 0
    for _, key in ipairs({ "milk", "pallets" }) do        -- the saleable, cliffed outputs
        local decl = o[key]
        if decl ~= nil then
            local _, ft = AnimalEconomics.curveOf(decl)
            local first = AnimalEconomics.onsetAge(decl)
            if first ~= nil and first > 0 then
                if onset == nil or first > onset then onset = first end
                local adult = AnimalEconomics.perAnimalPerDay(decl, adultAgeMonths or first)
                local price = AnimalEconomics.pricePerLitre(ft)
                if adult ~= nil and price ~= nil then
                    perMonth = perMonth + adult * days * eff * price
                end
            end
        end
    end

    if onset == nil then return nil end                   -- nothing is age-gated here
    return { months = onset, valuePerMonth = perMonth, cost = perMonth * onset }
end

---THE TWO STEADY STATES A SLOT CAN BE IN, priced per slot per month.
--
-- A pen slot can hold a producing ADULT, or it can be kept free as a NURSERY --
-- a calf is born into it each cycle and sold at once, so it never matures and
-- never produces. That second use did not exist in the model at all: births with
-- nowhere to go were simply DISCARDED, and every rule was written around that.
--
--      adult   = margin per month          (output net of straw, less capital decline)
--      nursery = calfNet / cycleMonths     (one sale per breeding cycle, forever)
--
-- MAXIMISING OVER THE WHOLE PEN COLLAPSES TO THIS ONE COMPARISON, which is why
-- it is worth stating as a per-slot value rather than as a barn-level search.
-- Income is `A*adult + min(A, C-A)*nursery` -- the min is the breeding constraint,
-- since a nursery slot produces nothing without an adult to fill it. Maximising
-- over A gives, for EVERY barn:
--
--      income(C)    = C * adult                    (full of adults)
--      income(C/2)  = (C/2) * (adult + nursery)    (half and half)
--      half wins   <=>  (adult + nursery)/2 > adult  <=>  nursery > adult
--
-- so the optimum is only ever FULL or EXACTLY HALF, never between (verified by
-- brute force over 20,000 random barns: 0 exceptions), and CAPACITY CANCELS
-- ENTIRELY -- the answer is a property of the ANIMAL and the barn's efficiency,
-- not of how big the pen is.
--
-- NOT MODELLED, deliberately: growing an animal to adulthood and selling IT (a
-- fattening operation, income `net/onset` per slot per month). It is a real third
-- regime and it is the beef case, but it interacts with the breeding constraint
-- differently -- the slot is immature for `onset` months and cannot breed -- so it
-- wants its own pass rather than a term bolted onto this one.
--
-- Returns { adult, nursery, use, margin } or NIL where either side is unknown.
-- Nil is never zero (15.6): an animal we cannot price is not one worth nothing,
-- and a verdict with a missing term is no verdict.
function AnimalEconomics.slotVerdict(adultPerMonth, calfNet, cycleMonths)
    if type(adultPerMonth) ~= "number" then return nil end
    if type(calfNet) ~= "number" then return nil end
    if type(cycleMonths) ~= "number" or cycleMonths <= 0 then return nil end

    local nursery = calfNet / cycleMonths
    -- A calf that costs money to sell is not income. Under a flat per-animal
    -- dealer fee a cheap newborn nets NEGATIVE (13.5), and a nursery built on
    -- that would pay to give its offspring away.
    if nursery < 0 then nursery = 0 end

    return {
        adult   = adultPerMonth,
        nursery = nursery,
        use     = (nursery > adultPerMonth) and "NURSERY" or "ADULT",
        margin  = nursery - adultPerMonth,
    }
end

---Is this cluster still short of its own output cliff? A calf or a chick earns
-- nothing sellable yet, which is a fact the UI must state plainly rather than
-- letting it read as a barn producing nothing.
---Returns monthsToGo, onsetAge -- or nil when nothing is age-gated or it is grown.
function AnimalEconomics.monthsToMaturity(subType, ageMonths)
    if type(subType) ~= "table" then return nil end
    local o = subType.output or {}
    local worst = nil
    for _, key in ipairs({ "milk", "pallets" }) do
        local first = AnimalEconomics.onsetAge(o[key])
        if first ~= nil and first > (ageMonths or 0) then
            if worst == nil or first > worst then worst = first end
        end
    end
    if worst == nil then return nil end
    return worst - (ageMonths or 0), worst
end

-- ---------------------------------------------------------------------------
-- THE VERDICT, per cluster.
--
-- `curve` is an AnimalSellRules.priceCurve for this subtype, passed in rather than
-- resolved here: it costs a clone sweep, the caller already holds one, and this
-- module stays free of anything that touches a cluster.
---Returns a table of figures, all per ANIMAL per month, plus the keep/sell verdict.
function AnimalEconomics.assessCluster(p, cl, subType, curve)
    local age = cl ~= nil and cl.age or 0
    local eff = AnimalEconomics.efficiency(p)

    local o = AnimalEconomics.outputValuePerMonth(subType, age, eff,
                                                 AnimalEconomics.producibleOutputKeys(p))
    -- health-scaled, so this figure and the `each` / GROUP VALUE it sits beside are
    -- the same animal's money rather than two different animals'
    local drift = AnimalEconomics.capitalDriftPerMonth(curve, age, cl ~= nil and cl.health or nil)

    local r = {
        age = age,
        efficiency = eff,
        earnsPerMonth = o ~= nil and o.value or nil,       -- net of straw
        grossPerMonth = o ~= nil and o.gross or nil,
        strawPerMonth = o ~= nil and o.strawCost or nil,
        byFillType = o ~= nil and o.byFillType or nil,
        unpriced = o ~= nil and o.unpriced or 0,
        driftPerMonth = drift,
        maturity = AnimalEconomics.maturityCost(subType, age, eff,
                                                AnimalEconomics.producibleOutputKeys(p)),
    }
    -- NO DECLARED-INPUT TERM HERE, deliberately. It was carried per cluster and
    -- rolled up by summarise, which meant the barn's straw and water were charged
    -- whether or not the barn held any -- while the inputs table beside it showed
    -- both at zero. The bill is now declaredInputCostPerHour, which asks the
    -- BUILDING what is there, and a per-cluster figure could not.

    -- THE RULE. Keeping wins while a month of earnings beats a month of decline.
    -- Both terms must be KNOWN: with either missing the honest answer is "no
    -- verdict", never a default that reads as advice.
    if r.earnsPerMonth ~= nil and drift ~= nil then
        r.marginPerMonth = r.earnsPerMonth - math.max(0, drift)
        r.keep = r.marginPerMonth > 0
    end

    -- MONTHS UNTIL THAT FLIPS. Only meaningful where the animal is still short of
    -- a cliff -- once it is producing and the curve has plateaued, the margin does
    -- not move again and the answer is "never", which is a keep, not a countdown.
    if r.keep == false then r.sellNow = true end

    return r
end

---Roll a barn's clusters into one verdict. Weighted by HEADCOUNT, because a
-- 1-animal cluster and a 250-animal one are not two equal opinions -- the horse
-- barn on the author's save is 16 clusters of 1, and an unweighted mean would let
-- it outvote a 250-bird coop.
-- `knownDrift` and `gain` EXIST FOR THE DISPLAY, and they are not decoration.
-- `drift` alone cannot tell three states apart -- a herd still APPRECIATING, a herd
-- whose price curve could not be sampled, and a genuine zero all read as 0 -- so a
-- caller gating on `drift > 0` silently renders "unknown" and "nothing" as the same
-- blank space. That is the nil-is-not-zero discipline (§15.6) thrown away at the
-- last step, and it shipped once: the Trade view showed a herd earning 9,946/month
-- with no verdict beside it and no way to tell whether the model was quiet or dead.
--   knownDrift = headcount whose drift is KNOWN. Zero means no verdict is possible.
--   gain       = headcount-weighted APPRECIATION, the mirror of `drift`, so a herd
--                gaining value can say so instead of reporting a bare zero.
function AnimalEconomics.summarise(rows)
    local out = { animals = 0, earns = 0, drift = 0, gain = 0,
                  margin = 0, known = 0, knownDrift = 0,
                  -- THE PROFIT TERMS. Accumulated here rather than in a second
                  -- walk because this is already the one place a barn's clusters
                  -- are weighted by HEADCOUNT, and two roll-ups over one row set
                  -- is two chances to weight them differently.
                  gross = 0, knownGross = 0,
                  breeders = 0, knownBirths = 0,
                  births = 0, birthValue = 0, birthValueLost = 0, birthsLost = 0,
                  capital = 0 }
    local sawGross, sawBirth = false, false
    for _, e in ipairs(rows or {}) do
        local n = e.count or 0
        out.animals = out.animals + n
        if e.econ ~= nil and e.econ.earnsPerMonth ~= nil then
            out.earns = out.earns + e.econ.earnsPerMonth * n
            out.known = out.known + n
            local d = e.econ.driftPerMonth
            if d ~= nil then
                out.knownDrift = out.knownDrift + n
                -- A NEGATIVE drift is appreciation, and must never be added as a
                -- gain against the decline: the rule is "earnings must beat the
                -- DECLINE", and an appreciating animal has none.
                out.drift = out.drift + math.max(0, d) * n
                out.gain  = out.gain  + math.max(0, -d) * n
            end
        end
        -- GROSS AND INPUTS ARE ACCUMULATED INDEPENDENTLY of earnsPerMonth: a
        -- cluster can have a priced output and an unpriceable straw, and folding
        -- them under one `known` would throw away which half is missing.
        if e.econ ~= nil and e.econ.grossPerMonth ~= nil then
            out.gross = out.gross + e.econ.grossPerMonth * n
            out.knownGross = out.knownGross + n
            sawGross = true
        end
        -- BIRTHS. One offspring per breeder per cycle (11.9, measured -- the herd
        -- doubles), so a cluster of n breeders on a `cycleMonths` cycle adds
        -- n / cycleMonths animals a month. `lostIfFull` is what a pen at capacity
        -- destroys of that, carried but NOT subtracted.
        if e.willBreed and (e.cycleMonths or 0) > 0 then
            out.breeders = out.breeders + n
            local perMonth = n / e.cycleMonths
            out.births = out.births + perMonth
            if e.birthValue ~= nil then
                out.knownBirths = out.knownBirths + n
                out.birthValue = out.birthValue + perMonth * e.birthValue
                local lost = (e.lostIfFull or 0) / e.cycleMonths
                out.birthValueLost = out.birthValueLost + lost * e.birthValue
                -- THE COUNT, not just the value: it is the size of the cull that would
                -- make room for them, and therefore what the sale FEE is charged on.
                out.birthsLost = (out.birthsLost or 0) + lost
                sawBirth = true
            end
        end
    end
    -- NIL IS NOT ZERO. A row set that produced no priced output at all reports
    -- nil, not 0 -- otherwise "cannot be priced" and "earns nothing" render as
    -- the same figure, which is the exact bug 15.7 shipped once.
    if not sawGross then out.gross = nil end
    if not sawBirth and out.breeders > 0 then out.birthValue = nil; out.birthValueLost = nil end
    -- THE NET CAPITAL MOVEMENT, signed the way a reader expects: POSITIVE means
    -- the herd is getting more valuable. `drift` and `gain` are each clamped
    -- non-negative and only one is ever non-zero per cluster, so this is exact.
    if out.knownDrift > 0 then out.capital = out.gain - out.drift else out.capital = nil end
    if out.known == 0 then return out end
    out.margin = out.earns - out.drift
    return out
end

-- ---------------------------------------------------------------------------
-- THE PROFIT.
--
-- Requested 2026-08-31, and stated by the author as the whole definition:
--
--     profit = increase in animal value
--            + value of produced outputs   (at current market value)
--            - cost of inputs              (at current market value)
--
-- PER MONTH, because that is the only period the capital term has: the price
-- curve is sampled every three months and the whole earnings model is already
-- stated per month (15.1). An hourly profit would have to divide a capital slope
-- nobody measured hourly.
--
-- IT IS NOT `earnsPerMonth`, AND THE DIFFERENCE IS THE POINT. That figure is the
-- SELL VERDICT's input -- output less BEDDING only, deliberately, because 15.9
-- parked feed pricing as a separate term and because a verdict must not move when
-- a trough is topped up. This is the BARN's operating result, so it carries the
-- feed as well and adds the capital side the verdict compares against rather than
-- includes. The two answer different questions and neither is derived from the
-- other; `outputs` here is `grossPerMonth` (straw-free) and the bedding arrives
-- once, in `inputs`, so nothing is counted twice.
--
-- INCREASE IN ANIMAL VALUE HAS TWO PARTS, and the author's call is that both
-- count: the herd AGEING up or down its price curve, and the calves BORN into it.
-- On a breeding herd the second dominates -- 11.9 measured the herd doubling --
-- so a profit figure without it understates a working barn by an order of
-- magnitude.
--
-- BIRTHS ARE GROSS, and `birthValueLost` is returned beside them rather than
-- subtracted (author's call, offered both ways). 11.11 measured that a FULL PEN
-- destroys those calves permanently, so on a barn at capacity the gross figure is
-- optimistic by exactly that field -- which is why it is carried rather than
-- discarded, and why a caller that wants the net number needs no second model.
---Compose the barn's monthly result from a summarise() roll-up and its feed cost.
-- `feedPerMonth` and `declaredPerMonth` may each be nil, which is UNKNOWN and not
-- zero: a barn whose ration or whose bedding cannot be priced has no profit figure,
-- it does not have a free one. Both are passed IN rather than read off `sum`,
-- because both are properties of the BUILDING (what it is holding) and not of the
-- clusters standing in it.
---What it costs to REALISE an animal, over and above losing the animal.
--
-- MEASURED IN GAME (13.5) and confirmed by scaling rather than assumed from one
-- point: a flat 100 PER ANIMAL, not a percentage -- at the price sampled, a
-- percentage would have been indistinguishable from 16.54%, which is exactly why
-- it was checked at 1, 2 and 7 head. `cluster:getSellPrice()` is GROSS, so every
-- projected revenue is over-stated by this much until it is taken off.
AnimalEconomics.SALE_FEE_PER_ANIMAL = 100

---Returns { perMonth, outputs, inputs, ageing, births, birthValueLost, complete }
-- or nil when there is nothing to report.
function AnimalEconomics.barnProfit(sum, feedPerMonth, declaredPerMonth)
    if type(sum) ~= "table" or (sum.animals or 0) <= 0 then return nil end

    local outputs = sum.gross
    local declared = declaredPerMonth
    local ageing = sum.capital
    local births = sum.birthValue

    local inputs = nil
    if declared ~= nil and feedPerMonth ~= nil then inputs = declared + feedPerMonth end

    -- A VERDICT WITH A MISSING TERM IS NO VERDICT (15.6). Every term is reported
    -- separately so the caller can say WHICH one is missing, but the headline is
    -- nil unless all four are known -- a profit quoted without its feed cost, or
    -- without the capital side, is not a smaller profit, it is a different figure
    -- wearing the same label.
    local complete = outputs ~= nil and inputs ~= nil and ageing ~= nil and births ~= nil
                     and (sum.knownGross or 0) >= (sum.animals or 0)
                     and (sum.knownDrift or 0) >= (sum.animals or 0)
                     and (sum.knownBirths or 0) >= (sum.breeders or 0)

    -- ---- TWO FIGURES, AND THE POINT IS THAT THEY CONVERGE --------------------
    --
    -- Author's design, 2026-09-09. The barn was reporting ONE number and it was the
    -- optimistic one: births counted GROSS while a full pen destroys every calf
    -- (11.5 -- and it destroys the gestation that made them too, silently). On a
    -- 96/96 barn of Angus that is 9.6 calves a month at 230, so the headline was
    -- 2,208/month better than reality and said nothing about the fact.
    --
    --   CURRENT      what this barn earns if you change nothing. Births NET of what
    --                the pen destroys -- zero while it is full.
    --   PROSPECTIVE  what it earns if you keep room for them. Births GROSS, less the
    --                sale fee on the animals sold to make that room.
    --
    -- THEY MEET WHEN THE ACTION IS TAKEN, and that is the property worth having: the
    -- fee is charged on exactly the births that would otherwise die, so making room
    -- drives birthValueLost to zero and the fee to zero IN THE SAME STEP. Sell enough
    -- and the two figures become equal -- not approximately, identically. A harness
    -- pins that, because a convergence that holds by luck is worth nothing.
    --
    -- NEITHER IS A CASH FIGURE. Feed is charged at market value, so both answer
    -- "does this herd beat selling the feed", not "what did my balance do" -- a farm
    -- growing its own silage can read negative here and still be making money. That
    -- distinction is the label's job, not this function's.
    local birthsNet = nil
    if births ~= nil then birthsNet = births - (sum.birthValueLost or 0) end
    local cullFee = (sum.birthsLost or 0) * AnimalEconomics.SALE_FEE_PER_ANIMAL

    local total, prospective = nil, nil
    if complete then
        total       = outputs - inputs + ageing + (birthsNet or 0)
        prospective = outputs - inputs + ageing + (births or 0) - cullFee
    end

    return { perMonth = total, perMonthProspective = prospective,
             outputs = outputs, inputs = inputs,
             feed = feedPerMonth, declaredInput = declared,
             ageing = ageing, births = birthsNet, birthsGross = births,
             cullFee = cullFee, birthsLost = sum.birthsLost,
             birthValueLost = sum.birthValueLost, complete = complete }
end
