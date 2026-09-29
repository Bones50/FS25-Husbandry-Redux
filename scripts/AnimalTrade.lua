-- ============================================================================
-- AnimalTrade.lua  (Husbandry Redux)
--
-- QUOTING AND COMMITTING one animal purchase or sale, through the base game's own
-- dealer controller. No money handling, no cluster surgery, no event of our own --
-- the transaction is the game's, exactly as AnimalSellExecutor's is (13.1).
--
-- WHAT IS MEASURED AND WHAT IS READ, because the two halves of this file do not
-- rest on the same evidence and a reader has to know which is which:
--
--   SELL  -- MEASURED IN GAME (13, six probe runs). applyTARGET sells,
--            `applyTarget(item, itemIndex, numAnimals)`, and
--            `getTargetPrice(item, index, n)` returns (ok, gross, fee, net) with a
--            flat 100/animal dealer fee confirmed by scaling. The net matched the
--            money actually received to the cent.
--
--   BUY   -- READ FROM TWO INDEPENDENT MODS, never measured here. The vanilla
--            class is absent from the SDK source (10.1), but:
--              * FS25_RealisticLivestockRM ships its own AnimalScreenDealerFarm and
--                overwrites `applySource(superFunc, animalTypeIndex, animalIndex)`,
--                indexing `self.sourceItems[animalTypeIndex][itemIndex]`;
--              * FS25_Fed_Produktions_Pack SUBCLASSES the vanilla trailer
--                controller with `applySource(animalTypeIndex, animalIndex,
--                numItems)` and reads `self.sourceItems[animalTypeIndex][animalIndex]`
--                before delegating to `superClass().applySource`.
--            Two mods that must both match vanilla to work at all, agreeing on the
--            argument order AND on the 2D shape of sourceItems. That is strong, and
--            it is still not a measurement.
--
-- SO THE SOURCE SIDE SELF-VALIDATES BEFORE IT SPENDS ANYTHING. `catalogue` walks
-- exactly the structure those two describe and prices every row through
-- `getSourcePrice`. If the shape were wrong the list comes up EMPTY and the dialog
-- says so -- there is no path on which a wrong reading silently spends money,
-- because the only thing the player can commit is a row that already quoted.
--
-- 13.2's LESSON IS WHY THAT MATTERS: the names are misleading (applyTARGET sells)
-- and the argument order is not what it looks like. That cost six runs to
-- establish for the sell side, and it is exactly the mistake a symmetric guess
-- would repeat here.
--
-- SERVER ONLY. It moves money.
-- ============================================================================

AnimalTrade = {}

AnimalTrade.MODE_SELL, AnimalTrade.MODE_BUY = 1, 2

local function log(fmt, ...)
    if HusbandryRedux ~= nil and HusbandryRedux.warn ~= nil then
        HusbandryRedux.warn("[trade] " .. fmt, ...)
    end
end

---Is a transaction possible at all here? Nothing in this module runs on a client:
-- the base game's controller moves money, and a client issuing it would either
-- desync or be refused. The dialog asks this first and says so rather than
-- offering a button that cannot work.
function AnimalTrade.canTrade()
    if AnimalScreenDealerFarm == nil or AnimalScreenDealerFarm.new == nil then
        return false, "noController"
    end
    if g_currentMission ~= nil and g_currentMission.getIsServer ~= nil then
        local ok, isServer = pcall(g_currentMission.getIsServer, g_currentMission)
        if ok and isServer == false then return false, "client" end
    end
    return true
end

---A controller with both item lists built and the five callbacks wired.
-- Delegates to AnimalSellExecutor.open so there is ONE place that knows a
-- constructed controller is not an opened one (13.3) and what the callbacks mean.
-- That function returns the TARGET items; the source list is read here.
function AnimalTrade.open(husbandry)
    if AnimalSellExecutor == nil or AnimalSellExecutor.open == nil then
        return nil, nil, nil, nil, "AnimalSellExecutor is not available"
    end
    local ctrl, targetItems, report, err = AnimalSellExecutor.open(husbandry)
    if ctrl == nil then return nil, nil, nil, nil, err end

    -- sourceActionFinished is the BUY side's completion callback, and
    -- AnimalSellExecutor wires it as a no-op because it only ever sells. A buy that
    -- returns cleanly and never confirms must not read as success (13.4).
    ctrl.sourceActionFinished = function(_, e, msg)
        if type(e) == "string" and msg == nil then e, msg = nil, e end
        report.finished = true
        report.message  = msg ~= nil and tostring(msg) or nil
        if e ~= nil then report.errors[#report.errors + 1] = tostring(e) end
    end

    -- THE FIELD, NOT THE ACCESSOR -- and this is what four passes of guessing missed.
    --
    -- MEASURED by arTradeDump 2026-08-31, and the two lines sat next to each other:
    --     AFTER init: sourceItems=1
    --     getSourceItems -> table (0)
    -- `initSourceItems` DOES populate `ctrl.sourceItems`; it is `getSourceItems()`
    -- that answers empty, because the list is keyed by ANIMAL TYPE
    -- (`getSourceAnimalTypes -> table (1)`) and the accessor evidently wants to be
    -- told which -- the 2D shape both mods described, reached through the wrong door.
    --
    -- Every earlier attempt read the accessor, saw nothing, and concluded the
    -- catalogue did not exist -- so it went looking for a way to BUILD one. The
    -- catalogue was there the whole time.
    local srcItems = {}
    if type(ctrl.sourceItems) == "table" and next(ctrl.sourceItems) ~= nil then
        srcItems = ctrl.sourceItems
    elseif type(ctrl.getSourceItems) == "function" then
        local okS, list = pcall(ctrl.getSourceItems, ctrl)
        if okS and type(list) == "table" then srcItems = list end
    end
    return ctrl, targetItems, srcItems, report, nil
end

-- ---------------------------------------------------------------------------
-- SELLING
-- ---------------------------------------------------------------------------
---What the barn's clusters are worth, as ROWS the dialog can list.
--
-- PRICED THROUGH getTargetPrice, never through cluster:getSellPrice. 13.5 measured
-- the difference: the cluster reports the GROSS and the dealer takes a flat 100 an
-- animal, so a screen quoting the cluster over-states every sale. The read is
-- free -- getTargetPrice changes nothing.
---Returns rows, err. Each row: { index, cluster, name, count, age, health,
-- eachNet, eachGross, eachFee }.
function AnimalTrade.sellRows(husbandry)
    local ctrl, items, _, _, err = AnimalTrade.open(husbandry)
    if ctrl == nil then return {}, err end
    local rows = {}
    for i, it in ipairs(items or {}) do
        local cl = nil
        if type(it.getCluster) == "function" then
            local okC, c = pcall(it.getCluster, it); if okC then cl = c end
        end
        local n = (cl ~= nil and cl.numAnimals) or 1
        local gross, fee, net = AnimalTrade._priceOf(ctrl, "getTargetPrice", it, i, 1)
        local name = "?"
        if cl ~= nil and cl.subTypeIndex ~= nil and AnimalHerdData ~= nil then
            local st = AnimalHerdData.subTypeOf(cl.subTypeIndex)
            if st ~= nil and st.name ~= nil then name = tostring(st.name) end
        end
        rows[#rows + 1] = {
            index = i, item = it, cluster = cl, name = name,
            icon = AnimalTrade._iconFor(it, cl ~= nil and cl.subTypeIndex or nil,
                                        cl ~= nil and cl.age or nil),
            count = n, age = cl ~= nil and cl.age or nil,
            health = cl ~= nil and cl.health or nil,
            subTypeIndex = cl ~= nil and cl.subTypeIndex or nil,
            eachGross = gross, eachFee = fee, eachNet = net,
        }
    end
    return rows, nil
end

-- ---------------------------------------------------------------------------
-- BUYING
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- THE DEALER'S CATALOGUE, WHEN THE CONTROLLER WILL NOT BUILD IT ITSELF.
--
-- MEASURED 2026-08-31, from the diagnostic the previous build shipped:
--     getSourceItems -> table, keys=0, numeric-table keys=0, priced rows=0
-- EMPTY, not misshapen. The structure both mods describe was right; vanilla's
-- `initSourceItems` simply builds nothing on a headless DealerFarm, while the
-- TARGET side of the same controller populates perfectly (the sell list works).
-- That is 13.3 one step further: a constructed controller is not an opened one, and
-- calling init*Items is not always enough to make it one.
--
-- THE EMPTY REPORT IS WHAT MADE THIS CHEAP. `keys=0` ruled out the whole reading of
-- the 2D shape in one line and pointed at the one thing left. 5.63: an empty probe
-- is evidence too.
--
-- WHERE THE CATALOGUE ACTUALLY COMES FROM, read from RealisticLivestock's own
-- AnimalScreenDealerTrailer:initSourceItems (a reimplementation of the vanilla one):
--     animalSystem:getSaleAnimalsByTypeIndex(animalTypeIndex)  -- the animals
--     AnimalItemNew.new(animal)                                -- wrapped per item
-- The wrapper is RL's OWN class, so the vanilla name is unknown -- which is why the
-- class is DISCOVERED at runtime rather than named here.
--
-- NOTHING IS TRUSTED. Every item built this way is priced through the controller's
-- own `getSourcePrice` and dropped if it will not quote, so a wrong guess at the
-- wrapper yields an EMPTY list and not a mis-aimed purchase. That is the same
-- guarantee the original buy path had, and it is the reason this can be attempted
-- at all rather than probed for another round.

---Every global whose name looks like the dealer's item wrapper, best first.
-- Discovered rather than named: RL replaces the vanilla class with its own
-- `AnimalItemNew`, so the shipped name cannot be read from any source available
-- here -- but whatever it is, it is a global with a `new` that takes an animal.
function AnimalTrade._itemClasses()
    local out, seen = {}, {}
    local function add(n, v) if not seen[n] then seen[n] = true; out[#out + 1] = { name = n, cls = v } end end

    -- the plausible names first, so a build that has one does not depend on the order
    -- `pairs` happens to walk the globals in
    for _, n in ipairs({ "AnimalItemStock", "AnimalItem", "AnimalItemNew" }) do
        local v = rawget(_G, n)
        if type(v) == "table" and type(v.new) == "function" then add(n, v) end
    end

    -- THEN BY SHAPE, because the NAME GUESS FAILED: measured 2026-08-31,
    -- `no AnimalItem-like global with a new()` -- so whatever vanilla calls its
    -- dealer item, it is not spelled that way.
    --
    -- The signature is distinctive and comes from RL's own item, which must match
    -- vanilla's to substitute for it: `getPrice` and `getTranportationFee`. THE TYPO
    -- IS THE FINGERPRINT -- "Tranportation" is the base game's own misspelling, so a
    -- table carrying it is almost certainly the class we are looking for rather than
    -- something that merely happens to have a price.
    for k, v in pairs(_G) do
        if type(k) == "string" and type(v) == "table" and type(v.new) == "function"
           and (type(v.getTranportationFee) == "function"
                or type(v.getTransportationFee) == "function"
                or (type(v.getPrice) == "function" and type(v.getCluster) == "function")) then
            add(k, v)
        end
    end

    -- last, the loose name match this started as
    for k, v in pairs(_G) do
        if type(k) == "string" and k:find("AnimalItem")
           and type(v) == "table" and type(v.new) == "function" then add(k, v) end
    end
    return out
end

---The animal type indices this husbandry can hold.
function AnimalTrade._typeIndicesFor(husbandry)
    local out = {}
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil or husbandry == nil then return out end

    -- the barn's OWN type first: a cow barn must not be offered chickens, and the
    -- husbandry knows which it is
    local spec = husbandry.spec_husbandryAnimals
    if spec ~= nil and spec.animalTypeIndex ~= nil then
        out[#out + 1] = spec.animalTypeIndex
        return out
    end
    if AnimalHerdData ~= nil and AnimalHerdData.animalTypeOf ~= nil then
        local ok, idx = pcall(AnimalHerdData.animalTypeOf, husbandry)
        if ok and type(idx) == "number" then out[#out + 1] = idx; return out end
    end
    -- nothing said: offer every type the barn will accept, and let the price check
    -- drop the rest
    if asys.getTypes ~= nil then
        local ok, types = pcall(asys.getTypes, asys)
        if ok and type(types) == "table" then
            for _, t in pairs(types) do
                local ti = type(t) == "table" and t.typeIndex or t
                if type(ti) == "number" then
                    local supported = true
                    if husbandry.getSupportsAnimalType ~= nil then
                        local okS, v = pcall(husbandry.getSupportsAnimalType, husbandry, ti)
                        if okS then supported = (v == true) end
                    end
                    if supported then out[#out + 1] = ti end
                end
            end
        end
    end
    return out
end

---Fill `ctrl.sourceItems` from the game's own sale animals. Returns how many items
-- were built, and a one-line account of what was seen -- which is what turns a
-- failure here into a fixable report rather than another blank screen.
---THE ACCESSOR THAT LISTS THE DEALER'S ANIMALS FOR ONE TYPE, discovered rather than
-- named.
--
-- MEASURED 2026-08-31: `animalSystem has no getSaleAnimalsByTypeIndex`. That name is
-- RealisticLivestock's, and RL is not what is running here -- so the vanilla name is
-- something else, and it is readable NOWHERE: AnimalSystem.lua is absent from the
-- SDK source entirely (not stripped -- absent), and a sweep of every installed mod
-- for `animalSystem:<method>` turns up no base-game call that lists sale animals.
--
-- So it is looked for by NAME across the plausible spellings, and then by SHAPE:
-- any method whose name mentions sale or shop or dealer and which answers a table
-- when handed a type index. A method that returns nothing useful is simply not the
-- one, and trying it costs a pcall.
--
-- IF NONE ANSWERS, the report NAMES EVERY METHOD the object actually has. That is
-- the one thing that turns a third blank screen into a fix: this API cannot be read
-- from any source available here, so the object itself has to be asked (8.1's rule
-- -- an absence in the SDK source proves nothing, and the fallback is to probe).
function AnimalTrade._saleAnimalsFor(asys, typeIndex)
    if asys == nil or typeIndex == nil then return nil end
    AnimalTrade._saleFn = AnimalTrade._saleFn or false
    local function try(name)
        local fn = asys[name]
        if type(fn) ~= "function" then return nil end
        local ok, list = pcall(fn, asys, typeIndex)
        if ok and type(list) == "table" then return list, name end
        return nil
    end
    if type(AnimalTrade._saleFn) == "string" then
        local l = try(AnimalTrade._saleFn)
        if l ~= nil then return l, AnimalTrade._saleFn end
    end
    for _, n in ipairs({ "getSaleAnimalsByTypeIndex", "getSaleAnimals", "getShopAnimals",
                         "getAnimalsToBuy", "getDealerAnimals", "getSaleItems",
                         "getAnimalsByTypeIndex", "getSaleAnimalsByType" }) do
        local l, used = try(n)
        if l ~= nil and next(l) ~= nil then AnimalTrade._saleFn = used; return l, used end
    end
    -- by SHAPE, since the name could not be guessed
    for k, v in pairs(asys) do
        if type(k) == "string" and type(v) == "function"
           and (k:lower():find("sale") or k:lower():find("shop") or k:lower():find("dealer")) then
            local l, used = try(k)
            if l ~= nil and next(l) ~= nil then AnimalTrade._saleFn = used; return l, used end
        end
    end
    return nil
end

---Every method name on the animal system, for the report. Bounded, sorted, so the
-- line is readable and cannot flood the log.
function AnimalTrade._methodNames(o)
    local out = {}
    for k, v in pairs(o or {}) do
        if type(k) == "string" and type(v) == "function" then out[#out + 1] = k end
    end
    table.sort(out)
    if #out > 70 then
        local cut = {}
        for i = 1, 70 do cut[i] = out[i] end
        cut[71] = "..."
        out = cut
    end
    return table.concat(out, ",")
end

function AnimalTrade._fillSourceItems(ctrl, husbandry)
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil then return 0, "no animalSystem" end
    local classes = AnimalTrade._itemClasses()
    if #classes == 0 then
        -- NAME THE CANDIDATES RATHER THAN THE ABSENCE. Three attempts at this have
        -- each been answered by a report that said only "not found", and each cost a
        -- round trip to ask the same question again. This lists every global that
        -- looks remotely like a constructible item, so the next run either works or
        -- names the class outright.
        local cands = {}
        for k, v in pairs(_G) do
            if type(k) == "string" and type(v) == "table" and type(v.new) == "function"
               and (k:lower():find("item") or k:lower():find("animal")) then
                cands[#cands + 1] = k
            end
        end
        table.sort(cands)
        if #cands > 40 then local c = {} for i = 1, 40 do c[i] = cands[i] end c[41] = "..." ; cands = c end
        return 0, string.format("no dealer-item class found; constructible candidates: [%s]",
                                table.concat(cands, ","))
    end

    local types = AnimalTrade._typeIndicesFor(husbandry)
    if #types == 0 then return 0, "no animal type resolved for this barn" end

    local built, animals, names = 0, 0, {}
    for _, c in ipairs(classes) do names[#names + 1] = c.name end
    ctrl.sourceItems = type(ctrl.sourceItems) == "table" and ctrl.sourceItems or {}

    local usedFn = nil
    for _, ti in ipairs(types) do
        local list, used = AnimalTrade._saleAnimalsFor(asys, ti)
        usedFn = used or usedFn
        if type(list) == "table" then
            for _, animal in pairs(list) do
                animals = animals + 1
                -- FIRST CLASS THAT YIELDS A PRICEABLE ITEM WINS, and nothing else
                -- is kept: an item the controller will not quote is an item the
                -- player must never be able to commit.
                for _, c in ipairs(classes) do
                    local okI, item = pcall(c.cls.new, animal)
                    if okI and type(item) == "table" then
                        ctrl.sourceItems[ti] = ctrl.sourceItems[ti] or {}
                        table.insert(ctrl.sourceItems[ti], item)
                        local g = AnimalTrade._priceOf(ctrl, "getSourcePrice", ti,
                                                       #ctrl.sourceItems[ti], 1)
                        if g ~= nil then built = built + 1; break end
                        -- it would not quote: take it straight back out
                        table.remove(ctrl.sourceItems[ti])
                    end
                end
            end
        end
    end
    if built == 0 and animals == 0 then
        -- NAME WHAT THE OBJECT ACTUALLY HAS. This API is readable nowhere, so the
        -- object is the only thing that can answer, and a report that merely says
        -- "not found" costs another round trip to say the same thing again.
        return 0, string.format("no sale-animal accessor found; animalSystem methods: %s",
                                AnimalTrade._methodNames(asys))
    end
    return built, string.format("fn=%s types=%d saleAnimals=%d classes=[%s] built=%d",
                                tostring(usedFn or "?"), #types, animals,
                                table.concat(names, ","), built)
end

---The dealer's catalogue for this barn, as rows the dialog can list.
--
-- `sourceItems` IS TWO-DIMENSIONAL -- [animalTypeIndex][itemIndex] -- which is the
-- one structural fact both mods agree on and the reason the flat `getSourceItems()`
-- shape the sell side uses does not apply. Read defensively: a list that is flat
-- after all still yields rows, and a shape that is neither yields none, which the
-- dialog reports rather than guessing past.
---Returns rows, err. Each row: { typeIndex, index, item, name, age,
-- eachNet, eachGross, eachFee }.
function AnimalTrade.buyRows(husbandry)
    local ctrl, _, src, _, err = AnimalTrade.open(husbandry)
    if ctrl == nil then return {}, err end
    local rows = {}

    -- THE CONTROLLER'S OWN LIST FIRST, and it is measured to be empty on a headless
    -- DealerFarm (see _fillSourceItems). Built here only when it gives us nothing, so
    -- a build where init*Items DOES work is untouched by any of this.
    local filled, account = nil, nil
    if next(src or {}) == nil then
        filled, account = AnimalTrade._fillSourceItems(ctrl, husbandry)
        if (filled or 0) > 0 then src = ctrl.sourceItems end
    end

    local function addRow(typeIndex, idx, it)
        if type(it) ~= "table" then return end
        local gross, fee, net = AnimalTrade._priceOf(ctrl, "getSourcePrice", typeIndex, idx, 1, it)
        -- A ROW THAT CANNOT BE PRICED IS NOT OFFERED. The whole safety of the buy
        -- path is that nothing reaches the commit button without having quoted
        -- through the game's own function first.
        if gross == nil and net == nil then return end
        local a = it.animal or it.cluster
        local name, age, sti = "?", nil, nil
        if type(a) == "table" then
            sti = a.subTypeIndex
            age = a.age
            if a.name ~= nil then name = tostring(a.name) end
        end
        -- ITS OWN TITLE FIRST. arTradeDump showed the items carrying `title` as a
        -- plain field (fields=cluster,infos,title,visual), which is what the base
        -- screen itself displays -- better than a subtype name we reconstruct.
        if type(it.title) == "string" and it.title ~= "" then name = it.title end
        -- AND ITS OWN AGE TEXT, from the same place. The dealer's animals reported no
        -- `age` field and the column read "-" on every row, while the three price
        -- tiers per breed are plainly ages. `infos` is the list the base screen
        -- renders beside each item, so the age is in there ALREADY FORMATTED -- and
        -- taking it verbatim means this dialog and that screen cannot disagree.
        local ageText = AnimalTrade._infoValue(it, "age")
        if name == "?" and sti ~= nil and AnimalHerdData ~= nil then
            local st = AnimalHerdData.subTypeOf(sti)
            if st ~= nil and st.name ~= nil then name = tostring(st.name) end
        end
        rows[#rows + 1] = {
            typeIndex = typeIndex, index = idx, item = it, name = name,
            icon = AnimalTrade._iconFor(it, sti, age),
            age = age, ageText = ageText, subTypeIndex = sti,
            eachGross = gross, eachFee = fee, eachNet = net,
        }
    end

    local sawKeys, sawTables, sawPriced = 0, 0, 0
    for k, v in pairs(src or {}) do
        sawKeys = sawKeys + 1
        if type(v) == "table" and type(k) == "number" then
            sawTables = sawTables + 1
            -- a LIST of items under an animal type index (the documented shape)...
            local looksNested = false
            for i2, it in ipairs(v) do
                if type(it) == "table" then looksNested = true; addRow(k, i2, it) end
            end
            -- ...or a flat list of items, which is what the sell side returns
            if not looksNested then addRow(1, k, v) end
        end
    end
    sawPriced = #rows

    -- AN EMPTY CATALOGUE SAYS WHY, ONCE, UNCONDITIONALLY.
    --
    -- The buy side is the half that was never measured (see the header), so the one
    -- outcome that must not be silent is "no rows" -- an empty list is exactly what
    -- a wrong reading of the structure looks like, and it is indistinguishable on
    -- screen from a dealer with nothing to offer. This prints the three facts that
    -- tell those apart: how many keys the source list had, how many of them were
    -- tables under a numeric key, and how many survived pricing.
    --
    -- A PRINT, NOT log(): 5.63's rule. A diagnostic a player has to be talked
    -- through enabling produces no data, and this is the one we would otherwise have
    -- to ask for a second time. It fires ONCE per session per barn.
    if sawPriced == 0 then
        AnimalTrade._toldEmpty = AnimalTrade._toldEmpty or {}
        local key = tostring(husbandry)
        if not AnimalTrade._toldEmpty[key] then
            AnimalTrade._toldEmpty[key] = true
            print(string.format(
                "[HusbandryRedux buy] no catalogue: getSourceItems -> %s, keys=%d, "
                .. "numeric-table keys=%d, priced rows=0; build attempt: %s",
                type(src), sawKeys, sawTables, tostring(account or "not attempted")))
        end
    end
    return rows, nil
end

-- ---------------------------------------------------------------------------
---THE PICTURE FOR ONE TRADE ROW.
--
-- THE ITEM CARRIES ITS OWN `visual`, which is the thing the icon is derived from in
-- the first place: arTradeDump listed `fields=cluster,infos,title,visual` on a dealer
-- item, and `AnimalHerdData.animalIconFile` gets to the same place the long way round
-- by asking `animalSystem:getVisualByAge(subTypeIndex, age)`. On the SELL side that
-- lookup works because the row has a subTypeIndex; on the BUY side the dealer's
-- animals report none -- the same absence that left the AGE column reading "-" -- so
-- the lookup had nothing to ask with and every buy row came up blank.
--
-- Reading the item's own visual is also the SHORTER answer: no index to resolve and
-- no age to guess, and it is the same picture the base screen shows for that row.
--
-- EVERY CANDIDATE GOES THROUGH DR's iconFileUsable, not a second copy of that logic.
-- 5.71 measured four productions declaring the base game's blank placeholder tile and
-- rendering as solid white squares: a DECLARED image is not a PRESENT one.
function AnimalTrade._iconFor(item, subTypeIndex, age)
    if AnimalHerdData == nil then return nil end

    -- THE ITEM'S OWN VISUAL FIRST, then whatever it nests one under.
    --
    -- BUILT WITH APPENDS, NOT A TABLE CONSTRUCTOR. Written as
    -- `ipairs({ item.visual, item.animal.visual, item.cluster.visual })` the list has
    -- a NIL HOLE whenever an earlier candidate is absent, and ipairs STOPS at the
    -- first hole -- so with no `item.visual` the other two were unreachable, which is
    -- exactly the case this function exists for. Caught by the harness, not in game.
    if AnimalHerdData.iconFromStore ~= nil and type(item) == "table" then
        local cands = {}
        local function add(v) if type(v) == "table" then cands[#cands + 1] = v end end
        add(item.visual)
        if type(item.animal) == "table" then add(item.animal.visual) end
        if type(item.cluster) == "table" then add(item.cluster.visual) end
        for _, v in ipairs(cands) do
            local ok, f = pcall(AnimalHerdData.iconFromStore, v.store)
            if ok and type(f) == "string" and f ~= "" then return f end
        end
    end

    -- the long way round, for a row whose item carries no visual of its own
    if AnimalHerdData.animalIconFile ~= nil and subTypeIndex ~= nil then
        local ok, f = pcall(AnimalHerdData.animalIconFile, subTypeIndex, age or 0)
        if ok and type(f) == "string" and f ~= "" then return f end
    end
    return nil
end

---One value out of an item's `infos` list, by what its title says.
--
-- `infos` is what the base game's own animal screen renders beside each item -- a
-- list of { title, value } -- so a value taken from it is the string that screen
-- shows, already formatted and already localised. Matched on the game's OWN label
-- for the field where there is one (`ui_age`), falling back to the English word,
-- because a player running the game in German has German titles in that list.
function AnimalTrade._infoValue(item, which)
    local infos = type(item) == "table" and item.infos or nil
    if type(infos) ~= "table" then return nil end
    local want = {}
    if which == "age" then
        want[#want + 1] = "age"
        if g_i18n ~= nil and g_i18n.getText ~= nil then
            local ok, t = pcall(g_i18n.getText, g_i18n, "ui_age")
            if ok and type(t) == "string" and t ~= "" then want[#want + 1] = t:lower() end
        end
    end
    for _, e in pairs(infos) do
        if type(e) == "table" then
            local t = e.title or e.text or e.name
            if type(t) == "string" then
                local lt = t:lower()
                for _, w in ipairs(want) do
                    if lt:find(w, 1, true) then
                        local v = e.value or e.valueText or e.text
                        if v ~= nil then return tostring(v) end
                    end
                end
            end
        end
    end
    return nil
end

---The whole price tuple for `n` animals, from either side.
--
-- TAKE THE WHOLE TUPLE. 13.5: capturing only the first return gave a bare `true`
-- for four runs -- a price function answering `true` is answering a different
-- question. The shape is (ok, gross, fee, net); anything else yields nils rather
-- than a number of unknown meaning.
--
-- The FEE IS RETURNED SIGNED AS THE GAME SIGNS IT (negative on a sale) and the
-- caller decides how to read it; inventing a sign here is how a screen comes to
-- disagree with the money that actually moves.
function AnimalTrade._priceOf(ctrl, fnName, a, b, n, item)
    local fn = ctrl ~= nil and ctrl[fnName] or nil
    if type(fn) ~= "function" then return nil, nil, nil end
    local ok, r1, r2, r3, r4 = pcall(fn, ctrl, a, b, n)
    if not ok then return nil, nil, nil end
    -- (ok, gross, fee, net)
    if type(r1) == "boolean" and type(r2) == "number" then return r2, r3, r4 end
    -- some builds may answer without the leading boolean
    if type(r1) == "number" then return r1, r2, r3 end
    return nil, nil, nil
end

---RE-RESOLVE A SELL ROW AGAINST THE CONTROLLER THAT IS ABOUT TO BE USED.
--
-- Reported 2026-08-31: the money never appeared, whatever the amount was set to.
-- `sellRows` opens a controller and builds rows holding ITS item objects; `quote`
-- and `commit` then open a FRESH one -- they must, because selling changes the
-- clusters and a held list indexes a herd that no longer exists (the reason
-- AnimalSellExecutor rebuilds between plan lines). Handing the old controller's item
-- to the new one's getTargetPrice is asking a stranger about someone else's list.
--
-- MATCHED ON THE CLUSTER, not the index: indices shift as groups are sold, and
-- AnimalSellExecutor.indexOf already exists to answer exactly this -- on the cluster
-- OBJECT first and its id only as a fallback, because picking the wrong row here
-- sells the wrong animals.
--
-- THE HARNESS COULD NOT HAVE CAUGHT THIS as it was written: its mock validated the
-- INDEX and ignored the item, so a stale item passed silently. It validates identity
-- now, which is what makes the fix a fix rather than a guess.
function AnimalTrade._resolveSell(ctrl, items, row)
    if row == nil then return nil, nil end
    if row.cluster ~= nil and AnimalSellExecutor ~= nil and AnimalSellExecutor.indexOf ~= nil then
        local i = AnimalSellExecutor.indexOf(items, row.cluster)
        if i ~= nil and items[i] ~= nil then return items[i], i end
    end
    -- no cluster to match on: fall back to the position it was listed at
    local i = row.index
    if i ~= nil and items[i] ~= nil then return items[i], i end
    return nil, nil
end

---Quote a whole transaction. `n` animals of `row`.
--
-- IT ASKS THE GAME FOR n, it does not multiply the single-animal price. 13.5's
-- table scales linearly today, but a dealer that ever discounts a batch would make
-- a multiplied quote a lie at the moment the player commits -- and the quote is
-- what they are agreeing to.
---Returns { gross, fee, net } or nil.
function AnimalTrade.quote(husbandry, mode, row, n)
    if row == nil or type(n) ~= "number" or n < 1 then return nil end
    local ctrl, items, _, _, err = AnimalTrade.open(husbandry)
    if ctrl == nil then return nil, err end
    local gross, fee, net
    if mode == AnimalTrade.MODE_BUY then
        gross, fee, net = AnimalTrade._priceOf(ctrl, "getSourcePrice", row.typeIndex, row.index, n, row.item)
    else
        local item, idx = AnimalTrade._resolveSell(ctrl, items, row)
        if item == nil then return nil, "rowGone" end
        gross, fee, net = AnimalTrade._priceOf(ctrl, "getTargetPrice", item, idx, n)
    end
    if gross == nil and net == nil then return nil, "unpriced" end
    return { gross = gross, fee = fee, net = net }
end

---COMMIT. Returns ok, message.
--
-- The controller is opened FRESH: selling changes the clusters, so an item list
-- held across a transaction indexes a herd that no longer exists (the reason
-- AnimalSellExecutor rebuilds between plan lines).
--
-- A CALL THAT RETURNS CLEANLY BUT NEVER CONFIRMS IS A FAILURE, not a success.
-- `*ActionFinished` with a nil error is how the game says it went through; without
-- treating silence as failure, a refusal is logged as money that never arrived.
function AnimalTrade.commit(husbandry, mode, row, n)
    local can, why = AnimalTrade.canTrade()
    if not can then return false, why end
    if row == nil or type(n) ~= "number" or n < 1 then return false, "badRequest" end

    local ctrl, items, _, report, err = AnimalTrade.open(husbandry)
    if ctrl == nil then return false, err or "noController" end

    local ok, res
    if mode == AnimalTrade.MODE_BUY then
        if type(ctrl.applySource) ~= "function" then return false, "noBuy" end
        ok, res = pcall(ctrl.applySource, ctrl, row.typeIndex, row.index, n)
    else
        if type(ctrl.applyTarget) ~= "function" then return false, "noSell" end
        -- the SAME re-resolution the quote uses, for the same reason: this is a
        -- different controller from the one that listed the row
        local item, idx = AnimalTrade._resolveSell(ctrl, items, row)
        if item == nil then return false, "rowGone" end
        ok, res = pcall(ctrl.applyTarget, ctrl, item, idx, n)
    end
    if not ok then
        log("commit threw: %s", tostring(res))
        return false, "threw"
    end
    if #report.errors > 0 then return false, report.errors[1] end
    if not report.finished then return false, "noConfirmation" end
    return true, report.message
end

-- ---------------------------------------------------------------------------
-- THE COMPREHENSIVE TRADE PROBE  --  `arTradeDump`
--
-- Author's call after four incremental attempts at the buy path: each instrument
-- answered exactly the one question it was built for and revealed the next
--   1. is the sourceItems SHAPE right?        -> right, but keys=0
--   2. why is it empty?                       -> initSourceItems builds nothing
--   3. where do the animals come from?        -> not getSaleAnimalsByTypeIndex
--   4. what wraps them?                       -> no AnimalItem-like global
-- Four round trips to learn four facts that ONE dump would have given at once.
--
-- THE RULE THIS EXISTS TO ENFORCE: when an API is readable NOWHERE, probe it WIDE
-- the first time. AnimalScreenDealerFarm and AnimalSystem are both ABSENT from the
-- SDK source -- not stripped, absent -- so the live object is the only thing that
-- can answer, and narrowing the question before knowing the shape of the answer is
-- what turned one unknown into four.
--
-- READ-ONLY. It constructs a controller, calls the init methods and READS. Nothing
-- is bought, nothing is sold, no money moves.
function AnimalTrade.dump()
    local function out(fmt, ...)
        local ok, line = pcall(string.format, fmt, ...)
        print("[arTradeDump] " .. (ok and line or tostring(fmt)))
    end
    local function names(o, filter)
        local t = {}
        for k, v in pairs(o or {}) do
            if type(k) == "string" and (filter == nil or filter(k, v)) then t[#t + 1] = k end
        end
        table.sort(t)
        if #t > 80 then local c = {} for i = 1, 80 do c[i] = t[i] end c[81] = "..."; t = c end
        return table.concat(t, ",")
    end

    -- 1. the barn -----------------------------------------------------------
    local barns = (AnimalHerdData ~= nil and AnimalHerdData.enumerate ~= nil)
                  and AnimalHerdData.enumerate() or {}
    out("barns=%d", #barns)
    local b = barns[1]
    if b == nil or b.placeable == nil then out("NO BARN -- nothing to probe"); return end
    local p = b.placeable
    out("barn='%s' animals=%s free=%s", tostring(b.name), tostring(b.animals), tostring(b.free))

    -- 2. the animal system: EVERY method, because the accessor is unnamed --------
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    out("animalSystem=%s", type(asys))
    if asys ~= nil then
        out("  functions: %s", names(asys, function(_, v) return type(v) == "function" end))
        out("  fields:    %s", names(asys, function(_, v) return type(v) ~= "function" end))
    end

    -- 3. the controller, before and AFTER the init calls -------------------------
    if AnimalScreenDealerFarm == nil or AnimalScreenDealerFarm.new == nil then
        out("AnimalScreenDealerFarm is ABSENT"); return
    end
    local ok, c = pcall(AnimalScreenDealerFarm.new, p, nil, true)
    if not ok or type(c) ~= "table" then out("new() refused: %s", tostring(c)); return end
    out("controller built; functions: %s", names(c, function(_, v) return type(v) == "function" end))
    out("  fields: %s", names(c, function(_, v) return type(v) ~= "function" end))

    local function count(t)
        if type(t) ~= "table" then return -1 end
        local n = 0; for _ in pairs(t) do n = n + 1 end; return n
    end
    out("  BEFORE init: sourceItems=%d targetItems=%d",
        count(c.sourceItems), count(c.targetItems))
    for _, n in ipairs({ "initSourceItems", "initTargetItems", "initItems" }) do
        if type(c[n]) == "function" then
            local okI, e = pcall(c[n], c)
            out("  %s -> %s", n, okI and "ok" or ("THREW: " .. tostring(e)))
        else
            out("  %s ABSENT", n)
        end
    end
    out("  AFTER  init: sourceItems=%d targetItems=%d",
        count(c.sourceItems), count(c.targetItems))

    -- what the accessors answer, as opposed to what the fields hold
    for _, n in ipairs({ "getSourceItems", "getTargetItems", "getSourceAnimalTypes" }) do
        if type(c[n]) == "function" then
            local okG, v = pcall(c[n], c)
            out("  %s -> %s (%d)", n, type(v), count(v))
        end
    end

    -- 4. ONE target item, dissected: the SELL side works, so this is the shape a
    --    SOURCE item almost certainly shares -- and it names the fields to look for
    local ti = c.getTargetItems ~= nil and select(2, pcall(c.getTargetItems, c)) or nil
    if type(ti) == "table" and ti[1] ~= nil then
        local it = ti[1]
        out("target item[1]: functions=%s", names(it, function(_, v) return type(v) == "function" end))
        out("  fields=%s", names(it, function(_, v) return type(v) ~= "function" end))
        local mt = getmetatable(it)
        out("  metatable=%s __index=%s", type(mt), type(mt) ~= "nil" and type(mt.__index) or "n/a")
        if type(mt) == "table" and type(mt.__index) == "table" then
            out("  class methods=%s", names(mt.__index, function(_, v) return type(v) == "function" end))
        end
    end

    -- 5. every global that could BE the item class ------------------------------
    -- matched by SHAPE, because four passes have shown the name is not guessable.
    -- getTranportationFee is the base game's own misspelling and is the fingerprint.
    local cands = {}
    for k, v in pairs(_G) do
        if type(k) == "string" and type(v) == "table" then
            local why = nil
            if type(v.getTranportationFee) == "function" then why = "getTranportationFee"
            elseif type(v.getTransportationFee) == "function" then why = "getTransportationFee"
            elseif type(v.getPrice) == "function" and type(v.new) == "function" then why = "getPrice+new"
            elseif k:find("AnimalItem") then why = "name" end
            if why ~= nil then cands[#cands + 1] = k .. "(" .. why .. ")" end
        end
    end
    table.sort(cands)
    out("item-class candidates: %s", #cands > 0 and table.concat(cands, ",") or "NONE")

    -- 6. anything that looks like the dealer's stock, wherever it lives ----------
    for _, holder in ipairs({ { "g_currentMission", g_currentMission },
                              { "animalSystem", asys } }) do
        local o = holder[2]
        if type(o) == "table" then
            local hits = {}
            for k, v in pairs(o) do
                if type(k) == "string" then
                    local lk = k:lower()
                    if lk:find("sale") or lk:find("shop") or lk:find("dealer") then
                        hits[#hits + 1] = k .. "=" .. type(v)
                    end
                end
            end
            table.sort(hits)
            out("%s sale/shop/dealer keys: %s", holder[1],
                #hits > 0 and table.concat(hits, ",") or "none")
        end
    end
    out("done")
end

function AnimalTrade.installConsole()
    if addConsoleCommand == nil then return false end
    addConsoleCommand("arTradeDump",
        "Dump the animal dealer controller and animal system, read-only",
        "dump", AnimalTrade)
    return true
end
