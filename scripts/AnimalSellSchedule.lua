-- ============================================================================
-- AnimalSellSchedule.lua -- "sell 5 animals every month for 10 months".
--
-- The SELL side's standing ORDER, and the mirror of AnimalBuySchedule: a
-- quantity on a cadence with an end. It shares that module's month arithmetic
-- wholesale rather than restating it, so the calendar bug 23.8a fixed cannot
-- come back on this side by omission.
--
-- ---------------------------------------------------------------------------
-- IT IS NOT THE SAME KIND OF THING AS THE SELL RULES, and that is the whole
-- reason it is a separate module and a separate screen.
--
--   an ORDER  is TIME-triggered: a count, a cadence, an end. Nothing about the
--             farm decides it, and the player says exactly how much leaves.
--   a POLICY  is CONDITION-triggered: continuous, unbounded, and jointly
--             optimised over the whole pen (AnimalSellPolicy, §17.2).
--
-- Forcing a policy into count/every/for would have been the wrong shape; so
-- would expressing an order as a rule.
--
-- ---------------------------------------------------------------------------
-- AN ORDER DOES NOT SAY WHICH ANIMALS -- ITS RULES DO. The first build gave it a
-- pick rule (oldest / cheapest / ...) beside a policy that already chose, and
-- better; the author named it as a double-up and it is gone (AnimalSellPolicy's
-- header carries the reasoning). An order is HOW MANY, HOW OFTEN, HOW LONG.
--
-- SO A RULE SET TRAVELS ON THE ORDER, in `cfg`, and is persisted with it. Its
-- keys are `AnimalSellRules.DEFAULTS` keys and nothing else; an absent key means
-- "the engine's default", which is exactly what `plan`'s own `opt()` does.
--
-- THE GUARDS COME WITH IT. `minHealthToSell` and `keepBreeders` are part of the
-- same rule set rather than a separate barn-level thing, so everything governing
-- one order is in one place and visible on one screen.
--
-- AN ORDER SELLS ON ITS SCHEDULE (author, 2026-09-14): *"If a sell order is created
-- it IS automatic selling, on a schedule."* The only two ways animals leave are Sell
-- (now) and the Auto Trader (a buy or sell order, fulfilled when due). runDue below is
-- driven EVERY HOUR from AnimalBuySchedule:onHourChanged, so a due order sells within
-- the hour and ahead of the births at the start of the next month, and stands down
-- with the Auto Trader setting, exactly as the buy side does.
-- ============================================================================

AnimalSellSchedule = {}

AnimalSellSchedule.MAX_COUNT = 100

---The orderings offered. `key` is what is persisted, so these strings are stable
-- identifiers and not display text -- the GUI localises them.
AnimalSellSchedule.orders = {}
AnimalSellSchedule._nextId = 1

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

-- ---------------------------------------------------------------------------
-- THE MODEL. Cadence, window and progress are AnimalBuySchedule's, called rather
-- than copied: two implementations of one calendar is how they come to disagree,
-- and that side is harnessed at 145 checks including the bug 23.8a fixed.
-- ---------------------------------------------------------------------------
function AnimalSellSchedule.totalRuns(s)
    if AnimalSellSchedule.isAge(s) then return math.huge end
    return AnimalBuySchedule.totalRuns(s)
end
function AnimalSellSchedule.isFinished(s)
    if AnimalSellSchedule.isAge(s) then return false end
    return AnimalBuySchedule.isFinished(s)
end
function AnimalSellSchedule.isForever(s)
    if AnimalSellSchedule.isAge(s) then return true end
    return AnimalBuySchedule.isForever(s)
end
---AN AGE ORDER IS ALWAYS DUE while it is enabled: it has no calendar, it watches the
-- breed and sells whatever has reached the age, every hour the driver runs.
function AnimalSellSchedule.isDue(s, month)
    if AnimalSellSchedule.isAge(s) then return s.enabled ~= false end
    return AnimalBuySchedule.isDue(s, month)
end
function AnimalSellSchedule.currentMonth() return AnimalBuySchedule.currentMonth() end

-- ---------------------------------------------------------------------------
-- THE AGE ORDER (2026-10-19, author's spec): "sell animals once they reach a certain
-- age", an OR beside the schedule. One BREED in one barn, one age in months, and it
-- runs until the player removes it. No guards: it is completely player driven, so
-- it sells every animal of the breed at or past the age, whatever it fetches.
--
-- WHILE IT IS ACTIVE IT OWNS THE BREED IN THAT BARN: nothing else may trade it there
-- -- not a schedule sell order, not a buy order, not Buy / Sell by hand. A PAUSED age
-- order is not active and releases the breed. `ageLock` is the one question every
-- other trade path asks.
-- ---------------------------------------------------------------------------
AnimalSellSchedule.KIND_AGE = "age"
AnimalSellSchedule.MAX_AGE  = 600

function AnimalSellSchedule.isAge(s)
    return type(s) == "table" and s.kind == AnimalSellSchedule.KIND_AGE
end

---The ACTIVE age order holding `breed` in barn `uid`, or nil.
function AnimalSellSchedule.ageLock(uid, breed)
    if type(uid) ~= "string" or type(breed) ~= "string" then return nil end
    for _, s in ipairs(AnimalSellSchedule.orders) do
        if AnimalSellSchedule.isAge(s) and s.enabled ~= false and s.uid == uid and s.breed == breed then
            return s
        end
    end
    return nil
end

---The age order on `breed` in barn `uid`, ACTIVE OR PAUSED, or nil.
function AnimalSellSchedule.ageOrderFor(uid, breed)
    for _, s in ipairs(AnimalSellSchedule.orders) do
        if AnimalSellSchedule.isAge(s) and s.uid == uid and s.breed == breed then return s end
    end
    return nil
end

---Every breed an active age order holds in barn `uid`, as a set. Empty when none.
function AnimalSellSchedule.lockedBreeds(uid)
    local out = {}
    for _, s in ipairs(AnimalSellSchedule.orders) do
        if AnimalSellSchedule.isAge(s) and s.enabled ~= false and s.uid == uid and type(s.breed) == "string" then
            out[s.breed] = s
        end
    end
    return out
end

---The age order a BUY of this dealer row would collide with, or nil. A dealer row
-- may not name its subtype (23.2), so where it does not, the breed is recognised the
-- way the per-breed Auto Trader already recognises it (breedEvidence / rowIsBreed).
-- `c` is a catalogue entry ({ subType, row, title }) or a raw trade row.
function AnimalSellSchedule.buyLock(uid, c)
    local locks = AnimalSellSchedule.lockedBreeds(uid)
    if next(locks) == nil or type(c) ~= "table" then return nil end
    local entry = c
    if c.row == nil and c.item ~= nil then
        entry = { row = c, title = c.name,
                  subType = AnimalBuySchedule ~= nil and AnimalBuySchedule.subTypeNameOf ~= nil
                            and AnimalBuySchedule.subTypeNameOf(c) or nil }
    end
    if entry.subType ~= nil then return locks[entry.subType] end
    if AnimalBuySchedule == nil or AnimalBuySchedule.breedEvidence == nil then return nil end
    AnimalSellSchedule._evCache = AnimalSellSchedule._evCache or {}
    for breed, s in pairs(locks) do
        local ev = AnimalSellSchedule._evCache[breed]
        if ev == nil then
            ev = AnimalBuySchedule.breedEvidence(breed)
            AnimalSellSchedule._evCache[breed] = ev
        end
        if AnimalBuySchedule.rowIsBreed(entry, ev) then return s end
    end
    return nil
end

---What an age order would sell from barn `p` right now: every cluster of its breed
-- at or past the age, oldest first, whole clusters. No refusal of any kind.
function AnimalSellSchedule.agePlan(p, s, priceFn)
    local plan = { lines = {}, total = 0, revenue = 0, notes = {} }
    if p == nil or not AnimalSellSchedule.isAge(s) or AnimalSellRules == nil then return plan end
    local okA, a = pcall(AnimalSellRules.assess, p)
    if not okA or a == nil then return plan end
    plan.assess = a
    local pick = {}
    for _, c in ipairs(a.clusters or {}) do
        if c.name == s.breed and (c.count or 0) > 0 and (c.age or 0) >= s.ageMonths then
            pick[#pick + 1] = c
        end
    end
    table.sort(pick, function(x, y)
        if (x.age or 0) ~= (y.age or 0) then return (x.age or 0) > (y.age or 0) end
        return (x.healthPct or 0) < (y.healthPct or 0)
    end)
    for _, c in ipairs(pick) do
        local n = c.count
        local rev = (c.each or 0) * n
        if priceFn ~= nil then
            local ok, v = pcall(priceFn, c.cluster, n)
            if ok and type(v) == "number" then rev = v end
        end
        plan.lines[#plan.lines + 1] = {
            cluster = c.cluster, name = c.name, count = n,
            reason = AnimalSellRules.REASON_ORDER,
            each = c.each, revenue = rev, gross = (c.each or 0) * n,
            age = c.age, healthPct = c.healthPct,
        }
        plan.total = plan.total + n
        plan.revenue = plan.revenue + rev
    end
    return plan
end

---Book a run that actually sold something. Same rule as the buy side: a run that
-- sold NOTHING does not consume an occurrence, so a month in which every animal
-- was below the health floor is retried rather than silently spent.
function AnimalSellSchedule.recordRun(s, sold, revenue)
    if type(sold) ~= "number" or sold <= 0 then return false end
    s.runsDone = s.runsDone + 1
    s.sold     = s.sold + sold
    s.revenue  = s.revenue + math.abs(revenue or 0)
    -- an age order has no calendar to advance
    if not AnimalSellSchedule.isAge(s) then
        s.nextMonth = s.nextMonth + math.max(1, s.everyMonths)
    end
    return true
end

---The age order's half of validate: a barn, a breed, an age. Everything the schedule
-- fields mean is filled with an inert value so code reading them cannot throw.
function AnimalSellSchedule._validateAge(f, int)
    local breed = f.breed
    if type(breed) ~= "string" or breed == "" then return nil, "no breed" end
    local age = int(f.ageMonths)
    if age == nil or age < 1 or age > AnimalSellSchedule.MAX_AGE then
        return nil, string.format("age must be 1..%d months", AnimalSellSchedule.MAX_AGE)
    end
    return {
        id = f.id, kind = AnimalSellSchedule.KIND_AGE, uid = f.uid,
        barnName   = type(f.barnName) == "string" and f.barnName or "?",
        animalName = (type(f.animalName) == "string" and f.animalName ~= "") and f.animalName or nil,
        breed = breed, ageMonths = age,
        cfg = {}, count = 0, everyMonths = 1, forMonths = AnimalBuySchedule.FOREVER,
        startMonth = int(f.startMonth) or 0, startIn = 0, nextMonth = 0,
        runsDone = int(f.runsDone) or 0, sold = int(f.sold) or 0,
        revenue  = tonumber(f.revenue) or 0,
        enabled  = f.enabled ~= false,
        note     = type(f.note) == "string" and f.note or "",
    }
end

function AnimalSellSchedule.validate(f)
    if type(f) ~= "table" then return nil, "no fields" end
    local function int(v) v = tonumber(v); if v == nil then return nil end; return math.floor(v) end

    local uid = f.uid
    if type(uid) ~= "string" or uid == "" then return nil, "no barn" end
    if f.kind == AnimalSellSchedule.KIND_AGE then return AnimalSellSchedule._validateAge(f, int) end
    local count = int(f.count)
    local every = int(f.everyMonths)
    local forM  = int(f.forMonths)
    if count == nil or count < 1 or count > AnimalSellSchedule.MAX_COUNT then
        return nil, string.format("count must be 1..%d", AnimalSellSchedule.MAX_COUNT)
    end
    if every == nil or every < 1 or every > AnimalBuySchedule.MAX_EVERY then
        return nil, string.format("interval must be 1..%d months", AnimalBuySchedule.MAX_EVERY)
    end
    -- THE SAME TWO RULES AS THE BUY SIDE, and they are the BUY SIDE's constants
    -- rather than a second copy: 23.8a's calendar bug came from one side having
    -- its own arithmetic, and duration is arithmetic.
    -- THE BUY SIDE'S BOUND, called rather than copied -- 23.8a's calendar bug came
    -- from one side having its own arithmetic, and this is arithmetic. It is on the
    -- RUN COUNT now, not the months: `forMonths` is `runs x everyMonths` (27.9).
    if forM ~= AnimalBuySchedule.FOREVER then
        if forM == nil or forM < 1 then
            return nil, "duration must be at least 1 month, or forever"
        end
        local runs = AnimalBuySchedule.totalRuns({ forMonths = forM, everyMonths = every })
        if runs > AnimalBuySchedule.MAX_RUNS then
            return nil, string.format("at most %d runs", AnimalBuySchedule.MAX_RUNS)
        end
    end
    local startIn = int(f.startIn) or 0
    if startIn < 0 or startIn > AnimalBuySchedule.MAX_START then
        return nil, string.format("start delay must be 0..%d months", AnimalBuySchedule.MAX_START)
    end
    -- ONLY REAL RULE KEYS SURVIVE. A cfg is player-facing state that also reaches
    -- the engine, so anything the engine would ignore is dropped here rather than
    -- stored and silently disregarded.
    local cfg = {}
    if type(f.cfg) == "table" and AnimalSellPolicy ~= nil then
        for _, fl in ipairs(AnimalSellPolicy.FIELDS) do
            if f.cfg[fl.key] ~= nil then cfg[fl.key] = f.cfg[fl.key] end
        end
    end

    local start = int(f.startMonth) or 0
    return {
        id          = f.id,
        uid         = uid,
        barnName    = type(f.barnName) == "string" and f.barnName or "?",
        -- WHAT THE BARN HOLDS, for the row title. The barn's animal TYPE, not a
        -- breed: an order is not breed-scoped, so naming one breed would be a lie
        -- on any barn holding two.
        animalName  = (type(f.animalName) == "string" and f.animalName ~= "") and f.animalName or nil,
        -- THE ONE BREED IT SELLS (2026-10-19). nil only on an order saved before breeds
        -- were recorded, which keeps selling across the barn as it always did.
        breed       = (type(f.breed) == "string" and f.breed ~= "") and f.breed or nil,
        cfg         = cfg,
        count       = count,
        everyMonths = every,
        forMonths   = forM,
        startMonth  = start,
        startIn     = startIn,
        -- the delay is applied ONCE, here; `nextMonth` is the persisted truth
        nextMonth   = int(f.nextMonth) or (start + startIn),
        runsDone    = int(f.runsDone) or 0,
        sold        = int(f.sold) or 0,
        revenue     = tonumber(f.revenue) or 0,
        enabled     = f.enabled ~= false,
        note        = type(f.note) == "string" and f.note or "",
        finishedMonth = int(f.finishedMonth),
    }
end

function AnimalSellSchedule.describe(s)
    if not AnimalSellSchedule.isAge(s) and s.breed ~= nil then
        local runs = AnimalSellSchedule.totalRuns(s)
        return string.format("#%s %s: sell %d %s every %d mo -- %d/%s runs, %d sold%s",
            tostring(s.id), tostring(s.barnName), s.count, tostring(s.breed), s.everyMonths,
            s.runsDone, runs == math.huge and "*" or tostring(runs), s.sold,
            s.enabled and "" or " [PAUSED]")
    end
    if AnimalSellSchedule.isAge(s) then
        return string.format("#%s %s: sell every %s at %d months -- %d sold%s",
            tostring(s.id), tostring(s.barnName), tostring(s.breed), s.ageMonths, s.sold,
            s.enabled and "" or " [PAUSED]")
    end
    local runs = AnimalSellSchedule.totalRuns(s)
    return string.format("#%s %s: sell %d every %d mo, %s%s -- %d/%s runs, %d sold%s",
        tostring(s.id), tostring(s.barnName), s.count, s.everyMonths,
        AnimalSellSchedule.isForever(s) and "forever" or string.format("for %d mo", s.forMonths),
        (s.startIn or 0) > 0 and string.format(", starting in %d mo", s.startIn) or "",
        s.runsDone, runs == math.huge and "*" or tostring(runs), s.sold,
        s.enabled and "" or " [PAUSED]")
end

function AnimalSellSchedule.add(fields)
    if type(fields) == "table" and fields.startMonth == nil then
        fields.startMonth = AnimalSellSchedule.currentMonth() or 0
    end
    local rec, why = AnimalSellSchedule.validate(fields)
    if rec == nil then return nil, why end
    -- ONE AGE ORDER PER BREED PER BARN, paused or not: two would be two owners of
    -- one breed the moment the paused one was resumed
    if AnimalSellSchedule.isAge(rec) and AnimalSellSchedule.ageOrderFor(rec.uid, rec.breed) ~= nil then
        return nil, "this breed already has an age order in this barn"
    end
    if rec.id == nil then
        rec.id = AnimalSellSchedule._nextId
        AnimalSellSchedule._nextId = AnimalSellSchedule._nextId + 1
    end
    AnimalSellSchedule.orders[#AnimalSellSchedule.orders + 1] = rec
    return rec
end

function AnimalSellSchedule.remove(id)
    id = tonumber(id)
    for i, s in ipairs(AnimalSellSchedule.orders) do
        if s.id == id then table.remove(AnimalSellSchedule.orders, i); return true end
    end
    return false
end

function AnimalSellSchedule.byId(id)
    id = tonumber(id)
    for _, s in ipairs(AnimalSellSchedule.orders) do if s.id == id then return s end end
    return nil
end

function AnimalSellSchedule.forBarn(uid)
    local out = {}
    for _, s in ipairs(AnimalSellSchedule.orders) do
        if s.uid == uid then out[#out + 1] = s end
    end
    return out
end

---A completed order lingers one month then clears, exactly as a buy order does.
function AnimalSellSchedule.pruneFinished(month)
    if type(month) ~= "number" then return 0 end
    local removed = 0
    for i = #AnimalSellSchedule.orders, 1, -1 do
        local s = AnimalSellSchedule.orders[i]
        if s ~= nil and AnimalSellSchedule.isFinished(s) then
            if s.finishedMonth == nil then
                s.finishedMonth = month
            elseif month > s.finishedMonth then
                table.remove(AnimalSellSchedule.orders, i)
                removed = removed + 1
                warn("sell order #%s finished (%d sold) and has been cleared",
                     tostring(s.id), s.sold)
            end
        end
    end
    return removed
end

-- ---------------------------------------------------------------------------
-- BUILDING THE PLAN
-- ---------------------------------------------------------------------------
---Turn an order into the plan shape `AnimalSellExecutor.execute` eats.
--
-- IT RUNS THE RULES ENGINE AND TAKES THE TOP `count`. That is the whole of it
-- now: `AnimalSellRules.plan` decides which animals qualify AND in what order --
-- headroom before peak, least valuable first -- so the order takes the first N of
-- that sequence rather than picking for itself. Selecting again here is precisely
-- the double-up the pick rule was (see AnimalSellPolicy's header).
--
-- THE GUARDS COME FROM THE SAME RULE SET, so a herd below the health floor stands
-- the order down and the breeder floor caps it, without this module restating
-- either -- `plan` already applies both.
---Returns plan, note. `note` is non-nil when the order was trimmed or refused.
---AN ORDER IS THE INSTRUCTION. Nothing else is consulted.
--
-- Author, 2026-09-10: *"no other sell order settings to impact the sale at all
-- other than the age ordering. So should be disconnected completely."*
--
-- THE RULES ENGINE IS NO LONGER ON THIS PATH. It emits lines for four REASONS
-- (calf / headroom / peak / earnings) rather than filtering a candidate list, so
-- with no reason firing it returned nothing however the settings were set -- an
-- order for 20 sold 0, and no combination of switches could fix it because none
-- of them was the cause. `orderPlan` takes the count in rank order instead.
--
-- `s.cfg` is DELIBERATELY IGNORED rather than deleted: existing saved orders
-- carry one, and dropping the field would make this version unable to read them.
-- It is dead weight, not a dependency.
function AnimalSellSchedule.buildPlan(p, s)
    if p == nil or s == nil or AnimalSellRules == nil
       or AnimalSellRules.orderPlan == nil then return nil, "no sell engine" end

    local priceFn = nil
    if AnimalSellExecutor ~= nil and AnimalSellExecutor.priceFn ~= nil then
        local okF, fn = pcall(AnimalSellExecutor.priceFn, p)
        if okF then priceFn = fn end
    end

    if AnimalSellSchedule.isAge(s) then
        local okG, gplan = pcall(AnimalSellSchedule.agePlan, p, s, priceFn)
        if not okG or type(gplan) ~= "table" then return nil, "the sale could not be planned" end
        if gplan.total == 0 then
            return nil, string.format("no %s at %d months or older", tostring(s.breed), s.ageMonths)
        end
        return gplan, nil
    end

    -- A BREED AN AGE ORDER HOLDS IN THIS BARN IS NOT THIS ORDER'S TO SELL
    local skip = AnimalSellSchedule.lockedBreeds(s.uid)
    if next(skip) == nil then skip = nil end
    local okP, plan = pcall(AnimalSellRules.orderPlan, p, s.count, priceFn, skip, s.breed)
    if not okP or type(plan) ~= "table" then return nil, "the sale could not be planned" end
    if plan.total == 0 and plan.skipped ~= nil and plan.skipped > 0 then
        if s.breed ~= nil then
            return nil, string.format("%s is held by an age order", tostring(s.breed))
        end
        return nil, "every animal left here is held by an age order"
    end
    if plan.total == 0 and s.breed ~= nil then
        return nil, string.format("no %s in this barn", tostring(s.breed))
    end
    if plan.total == 0 then
        -- A REAL DISTINCTION, and the screen needs both: an empty barn is not the
        -- same as a barn whose every animal would sell at a loss.
        for _, n in ipairs(plan.notes or {}) do
            if n.kind == "refused" then
                return nil, "every animal would sell for less than the dealer fee"
            end
        end
        return nil, "this barn has no animals to sell"
    end

    local note = nil
    if plan.total < s.count then
        note = string.format("%d of %d available", plan.total, s.count)
    end
    return plan, note
end

---Run one order now. Returns sold, revenue, note.
-- Gated on the Auto Trader setting HERE, on the unit of work, so every caller
-- inherits it.
function AnimalSellSchedule.runOne(s)
    if AnimalSettings ~= nil and not AnimalSettings.autoTraderEnabled() then return 0, 0, "the auto trader is switched off" end
    if AnimalSellExecutor == nil or AnimalSellExecutor.canRun == nil
       or not AnimalSellExecutor.canRun() then
        return 0, 0, "cannot sell here"
    end
    local p = HusbandryRedux.barnByUid(s.uid)      -- with or without DR (2026-11-25)
    if p == nil then return 0, 0, "barn not found" end

    local plan, note = AnimalSellSchedule.buildPlan(p, s)
    if plan == nil then return 0, 0, tostring(note) end

    local res = AnimalSellExecutor.execute(p, plan)
    if res == nil then return 0, 0, "the executor answered nothing" end
    if res.refused ~= nil then return 0, 0, tostring(res.refused) end
    if (res.sold or 0) == 0 then
        local why = nil
        for _, ln in ipairs(res.lines or {}) do if ln.why ~= nil then why = ln.why end end
        return 0, 0, why or "nothing was sold"
    end
    return res.sold, res.revenue or 0, note
end

---THE DRIVER'S PASS: every order due this month, oldest-created first. The mirror of
-- AnimalBuySchedule.runDue, and its rules: a run that sold NOTHING does not use up an
-- occurrence and is retried at the next trigger with the reason logged; a completed
-- order lingers a month and clears.
function AnimalSellSchedule.runDue()
    if AnimalSettings ~= nil and not AnimalSettings.autoTraderEnabled() then return 0 end
    local month = AnimalSellSchedule.currentMonth()
    if month == nil then
        warn("sell orders idle: the environment does not report a day")
        return 0
    end
    local ran = 0
    for i = 1, #AnimalSellSchedule.orders do
        local s = AnimalSellSchedule.orders[i]
        if s ~= nil and AnimalSellSchedule.isDue(s, month) then
            local sold, revenue, note = AnimalSellSchedule.runOne(s)
            s.note = note or ""
            if AnimalSellSchedule.recordRun(s, sold, revenue) then
                ran = ran + 1
                -- UNCONDITIONAL: animals left the farm without the player pressing anything
                local runs = AnimalSellSchedule.totalRuns(s)
                warn("sell order #%s: sold %d animal(s) from %s for %s (run %d/%s)%s",
                     tostring(s.id), sold, tostring(s.barnName),
                     tostring(math.floor((revenue or 0) + 0.5)), s.runsDone,
                     runs == math.huge and "forever" or tostring(runs),
                     note ~= nil and (" -- " .. note) or "")
            elseif AnimalSellSchedule.isAge(s) then
                -- an age order is checked every hour and normally has nothing of
                -- age yet: that is its resting state, not a failure worth a line
            elseif s.note ~= s._loggedNote then
                -- a repeated blocker would otherwise print every game day. Per ORDER:
                -- one shared "last note" flips between two orders and prints both
                -- every time.
                s._loggedNote = s.note
                warn("sell order #%s sold nothing: %s", tostring(s.id), tostring(s.note))
            end
        end
    end
    AnimalSellSchedule.pruneFinished(month)
    return ran
end

-- ---------------------------------------------------------------------------
-- PERSISTENCE
local function saveSection(xml, key)
    setXMLInt(xml, key .. "#nextId", AnimalSellSchedule._nextId)
    for i, s in ipairs(AnimalSellSchedule.orders) do
        local k = string.format("%s.order(%d)", key, i - 1)
        setXMLInt(xml,    k .. "#id",          s.id)
        setXMLString(xml, k .. "#uid",         s.uid)
        setXMLString(xml, k .. "#barnName",    s.barnName)
        if s.animalName ~= nil then setXMLString(xml, k .. "#animalName", s.animalName) end
        -- THE RULE SET, one attribute per field it actually holds. A field left
        -- unset writes nothing, so an order on pure defaults stays on them even if
        -- the engine's defaults ever move.
        for _, fl in ipairs(AnimalSellPolicy.FIELDS) do
            local v = s.cfg ~= nil and s.cfg[fl.key] or nil
            if v ~= nil then
                if fl.kind == "bool" then setXMLBool(xml, k .. ".rule#" .. fl.key, v == true)
                elseif fl.kind == "pct" then setXMLFloat(xml, k .. ".rule#" .. fl.key, v)
                else setXMLInt(xml, k .. ".rule#" .. fl.key, v) end
            end
        end
        if AnimalSellSchedule.isAge(s) then
            setXMLString(xml, k .. "#kind",      s.kind)
            setXMLInt(xml,    k .. "#ageMonths", s.ageMonths)
        end
        if s.breed ~= nil then setXMLString(xml, k .. "#breed", s.breed) end
        setXMLInt(xml,    k .. "#count",       s.count)
        setXMLInt(xml,    k .. "#everyMonths", s.everyMonths)
        setXMLInt(xml,    k .. "#forMonths",   s.forMonths)
        setXMLInt(xml,    k .. "#startMonth",  s.startMonth)
        if (s.startIn or 0) > 0 then setXMLInt(xml, k .. "#startIn", s.startIn) end
        setXMLInt(xml,    k .. "#nextMonth",   s.nextMonth)
        setXMLInt(xml,    k .. "#runsDone",    s.runsDone)
        setXMLInt(xml,    k .. "#sold",        s.sold)
        setXMLFloat(xml,  k .. "#revenue",     s.revenue)
        setXMLBool(xml,   k .. "#enabled",     s.enabled)
        if s.finishedMonth ~= nil then setXMLInt(xml, k .. "#finishedMonth", s.finishedMonth) end
    end
end

---One order's rule set out of the document. A FIELD rather than a local so it is
-- reachable from loadSection wherever that ends up in the file -- a local
-- declared below its use is a nil global and `luac -p` passes it (1.4).
function AnimalSellSchedule._readRules(xml, k)
    local cfg = {}
    if xml == nil or AnimalSellPolicy == nil then return cfg end
    for _, fl in ipairs(AnimalSellPolicy.FIELDS) do
        local v
        if fl.kind == "bool" then v = getXMLBool(xml, k .. ".rule#" .. fl.key)
        elseif fl.kind == "pct" then v = getXMLFloat(xml, k .. ".rule#" .. fl.key)
        else v = getXMLInt(xml, k .. ".rule#" .. fl.key) end
        if v ~= nil then cfg[fl.key] = v end
    end
    return cfg
end

local function loadSection(xml, key)
    AnimalSellSchedule.orders = {}
    AnimalSellSchedule._nextId = 1
    if xml == nil then return end
    local nid = getXMLInt(xml, key .. "#nextId")
    if nid ~= nil then AnimalSellSchedule._nextId = nid end

    local i, maxId = 0, 0
    while true do
        local k = string.format("%s.order(%d)", key, i)
        if not hasXMLProperty(xml, k) then break end
        local rec, why = AnimalSellSchedule.validate({
            id          = getXMLInt(xml,    k .. "#id"),
            uid         = getXMLString(xml, k .. "#uid"),
            barnName    = getXMLString(xml, k .. "#barnName"),
            animalName  = getXMLString(xml, k .. "#animalName"),
            kind        = getXMLString(xml, k .. "#kind"),
            breed       = getXMLString(xml, k .. "#breed"),
            ageMonths   = getXMLInt(xml,    k .. "#ageMonths"),
            cfg         = AnimalSellSchedule._readRules(xml, k),
            count       = getXMLInt(xml,    k .. "#count"),
            everyMonths = getXMLInt(xml,    k .. "#everyMonths"),
            forMonths   = getXMLInt(xml,    k .. "#forMonths"),
            startMonth  = getXMLInt(xml,    k .. "#startMonth"),
            startIn     = getXMLInt(xml,    k .. "#startIn"),
            nextMonth   = getXMLInt(xml,    k .. "#nextMonth"),
            runsDone    = getXMLInt(xml,    k .. "#runsDone"),
            sold        = getXMLInt(xml,    k .. "#sold"),
            revenue     = getXMLFloat(xml,  k .. "#revenue"),
            enabled     = getXMLBool(xml,   k .. "#enabled"),
            finishedMonth = getXMLInt(xml,  k .. "#finishedMonth"),
        })
        if rec ~= nil then
            if rec.id == nil then rec.id = AnimalSellSchedule._nextId + i end
            AnimalSellSchedule.orders[#AnimalSellSchedule.orders + 1] = rec
            if rec.id > maxId then maxId = rec.id end
        else
            warn("sell order %d dropped on load: %s", i, tostring(why))
        end
        i = i + 1
    end
    if AnimalSellSchedule._nextId <= maxId then AnimalSellSchedule._nextId = maxId + 1 end
    if #AnimalSellSchedule.orders > 0 then
        dbg("%d sell order(s) restored", #AnimalSellSchedule.orders)
    end
end

if AnimalPersist ~= nil and AnimalPersist.register ~= nil then
    AnimalPersist.register("sellOrders", saveSection, loadSection)
end
