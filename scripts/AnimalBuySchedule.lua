-- ============================================================================
-- AnimalBuySchedule.lua -- "buy 10 cows every month for 10 months".
--
-- Requested 2026-09-01. A per-barn standing order: N animals of one breed at one
-- age tier, every E months, for F months. It fires at 08:00 game time, server
-- side, and commits through AnimalTrade -- the same measured path the Buy / Sell
-- window uses, so there is one buy in this mod rather than two.
--
-- ---------------------------------------------------------------------------
-- THREE THINGS THE INVESTIGATION SETTLED, and each removed work rather than
-- adding it.
--
-- 1. ANIMAL PRICES DO NOT MOVE WITH THE CLOCK, so there is no "buy at the new
--    day's price" problem and no need to offset the trigger past a rollover.
--    `sdk/xmlDoku/character/animals.xml` declares <buyPrice>, <sellPrice> and
--    <transportPrice> as AGE-keyed curves and nothing else: across the whole
--    file there is not one season, period, priceFactor, marketFactor or random
--    token, and the only "month" in 369 uses is `ageMonth`. The dealer's
--    catalogue is likewise a FIXED declared set -- the <visual> entries carrying
--    canBeBought="true" -- so cows offer ages 0/6/18, pigs 0/3, sheep and goats
--    0/3/8, horses and roosters 0, chickens 0/6, and those never rotate. Two
--    supporting facts: there is no animal-dealer state anywhere in a savegame
--    (sales.xml is the used-VEHICLE dealer, with timeLeft in days), and nothing
--    routes animal prices through economyManager. AR 11.2 measured the same
--    thing from the other end -- a chicken read exactly 25.00, the raw curve
--    maximum, with no multiplier of any kind.
--
-- 2. "LAST SLEEP CYCLE **OR** 08:00" IS ONE TRIGGER, NOT TWO. Hours tick
--    individually through a sleep fast-forward (DR 4.3 / 5.30 -- many hourly
--    passes inside one frame), so hour 8 is reached whether the player sleeps
--    past it, wakes before it, or never sleeps at all. No sleep detection is
--    needed, which is just as well: g_sleepManager exists as a global but its
--    class is absent from the SDK source entirely.
--
-- 3. "EVERY X MONTHS" IS PERIODS, NOT DAYS. `daysPerPeriod` is a save setting
--    and the author's own savegame2 has it at 1, so a day-based implementation
--    would test perfectly clean there and be wrong for everyone running longer
--    months. The month counter is derived from `currentMonotonicDay`, which is
--    monotonic and therefore survives the 1..12 period wrap that
--    `currentPeriod` does not.
--
-- ---------------------------------------------------------------------------
-- HOW A CATALOGUE ROW IS NAMED, and the first attempt that could not work.
--
-- THE FIRST VERSION KEYED ON THE SUBTYPE NAME PLUS AN AGE-TIER ORDINAL, and it
-- listed NOTHING in game. The reason was already written down in this mod, in
-- `AnimalTrade._iconFor`'s own header: *"on the SELL side that lookup works
-- because the row has a subTypeIndex; on the BUY side the dealer's animals
-- report none -- the same absence that left the AGE column reading '-'."* So the
-- key was built on the one field a buy row provably does not carry, and every
-- row was filtered out. It was knowable by reading and it was not read.
--
-- WHAT A BUY ROW ACTUALLY HAS is what `arTradeDump` measured on a dealer item:
-- `fields=cluster,infos,title,visual`, plus the position the controller lists it
-- at and the price its own `getSourcePrice` quotes. So the key is
-- **POSITION + TITLE + PRICE**, and the row is resolved by agreement between
-- them rather than by any one of them:
--
--   1. the position, corroborated by the title OR the price   -- the normal case
--   2. failing that, a UNIQUE title match     -- the catalogue moved under us
--   3. failing that, a UNIQUE price match     -- the game's language changed
--   4. otherwise REFUSE and say so
--
-- The three are chosen because they fail INDEPENDENTLY. A mod set changing moves
-- positions and can change prices; a language change rewrites every title and
-- touches no price; neither alone can satisfy two of the three. Position on its
-- own would be exactly the "plausible value in the wrong slot" AR 13.2 records,
-- which bought seven animals when one was asked for -- and this spends money
-- unattended, once a month, with nobody watching.
--
-- The subtype name is still stored WHEN IT CAN BE RESOLVED (some builds and mods
-- do expose it), purely as extra corroboration and for the display. Nothing
-- depends on it.
--
-- A KEY THAT WILL NOT RESOLVE SUSPENDS THE SCHEDULE AND SAYS SO. It never falls
-- through to a neighbouring row.
-- ============================================================================

AnimalBuySchedule = {}

-- 08:00. Reached during a sleep fast-forward as well as in real time (see 2).
AnimalBuySchedule.RUN_HOUR = 8

AnimalBuySchedule.MAX_COUNT  = 100
AnimalBuySchedule.MAX_EVERY  = 12
AnimalBuySchedule.MAX_FOR    = 120
---HOW MANY TIMES an order may run. The dialog now asks for a RUN COUNT rather
-- than a duration (27.9), and `forMonths` is stored as `runs x everyMonths` -- so
-- the old 120 MONTH bound would have refused 12 buys at a yearly cadence, which is
-- 12 runs and perfectly reasonable. The bound therefore moved onto the quantity
-- the player actually states.
AnimalBuySchedule.MAX_RUNS   = 120

---AN ORDER THAT NEVER ENDS. A sentinel in `forMonths` rather than a separate
-- boolean, because "how long does it run for" is ONE question and two fields
-- answering it is two things that can disagree. Negative so it can never collide
-- with a real duration, and so an older build reading it refuses the order at
-- validation rather than running it for minus one month.
AnimalBuySchedule.FOREVER = -1

---How long a first run may be deferred. 0 is "start at the next 08:00".
AnimalBuySchedule.MAX_START = 120

AnimalBuySchedule.schedules = {}      -- array of records; see newRecord
AnimalBuySchedule._nextId   = 1
AnimalBuySchedule._lastNote = nil

local function warn(fmt, ...)
    if HusbandryRedux ~= nil and HusbandryRedux.warn ~= nil then return HusbandryRedux.warn(fmt, ...) end
    local ok, msg = pcall(string.format, fmt, ...)
    print("[HusbandryRedux] " .. (ok and msg or tostring(fmt)))
end
local function dbg(fmt, ...)
    if HusbandryRedux ~= nil and HusbandryRedux.log ~= nil then return HusbandryRedux.log(fmt, ...) end
end

-- ---------------------------------------------------------------------------
-- THE PURE MODEL. No game state is touched below this line until `currentMonth`,
-- which is the only impure function in the block -- everything else takes the
-- month as an argument so the harness can drive a decade of schedule in a
-- millisecond.
-- ---------------------------------------------------------------------------

---A monotonic month number. Only DIFFERENCES matter, so the origin is arbitrary.
function AnimalBuySchedule.monthOf(monotonicDay, daysPerPeriod)
    if type(monotonicDay) ~= "number" then return nil end
    local dpp = daysPerPeriod
    if type(dpp) ~= "number" or dpp < 1 then dpp = 1 end
    return math.floor((monotonicDay - 1) / dpp)
end

---The live month, or nil where the environment cannot answer.
--
-- `currentMonotonicDay` is preferred over `currentDay` because it does not reset
-- at a year boundary; the savegame carries both (environment.xml) and
-- AbstractMission.lua reads the monotonic one for exactly this reason.
function AnimalBuySchedule.currentMonth()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env == nil then return nil end
    local day = env.currentMonotonicDay
    if type(day) ~= "number" then day = env.currentDay end
    return AnimalBuySchedule.monthOf(day, env.daysPerPeriod)
end

---How many purchases a schedule makes in total.
--
-- CEIL, not floor: with `every` = 3 and `for` = 10 the runs land on months
-- 0, 3, 6 and 9 -- four of them, all inside the ten-month window. Floor would
-- silently drop the last one.
function AnimalBuySchedule.totalRuns(s)
    if (s.forMonths or 1) == AnimalBuySchedule.FOREVER then return math.huge end
    local every = math.max(1, s.everyMonths or 1)
    return math.max(1, math.ceil((s.forMonths or 1) / every))
end

---Whether an order runs until the player stops it.
function AnimalBuySchedule.isForever(s)
    return (s.forMonths or 1) == AnimalBuySchedule.FOREVER
end

---AN ORDER IS OVER WHEN IT HAS MADE ITS PURCHASES. There is no calendar deadline,
-- and there used to be one.
--
-- REPORTED IN GAME 2026-09-01 from a screenshot: "1 x Brown-Swiss" showed **0 / 1**
-- and "2 x Holstein" showed **1 / 2**, both already marked done. Every order was
-- losing exactly one purchase.
--
-- The window ran `startMonth + forMonths` from the month the order was CREATED, but
-- the first run can only land at the next 08:00 -- and at daysPerPeriod = 1, which
-- is what the author's saves use, that is ALREADY THE NEXT MONTH. So the order lost
-- its first occurrence to a window that had started counting before it could act,
-- and then expired one short. Simulated against the shipped rule, both reported
-- figures reproduce exactly, which is what identified this rather than merely
-- fitting it.
--
-- "FOR 10 MONTHS" IS HOW A PLAYER SAYS "TEN PURCHASES", not a deadline -- it is
-- already how `totalRuns` reads it. Two expressions of one quantity, and they
-- disagreed (§8.2). The count is the honest one, so the calendar test is gone.
--
-- The window was insurance against an order that can never buy living forever. That
-- is the wrong trade: losing a purchase the player asked for is worse than an order
-- sitting visible with "the barn is full" against it, which they can pause or
-- remove. 5.48's ruling -- world state may not quietly cancel an instruction.
function AnimalBuySchedule.isFinished(s)
    return s.runsDone >= AnimalBuySchedule.totalRuns(s)
end

function AnimalBuySchedule.isDue(s, month)
    if not s.enabled then return false end
    if type(month) ~= "number" then return false end
    if AnimalBuySchedule.isFinished(s) then return false end
    return month >= s.nextMonth
end

---Book a run that actually bought something.
--
-- A RUN THAT BOUGHT NOTHING DOES NOT CONSUME AN OCCURRENCE. A full pen or an
-- empty wallet on the day would otherwise burn that month silently and the
-- player would never learn why; instead it is retried at the next trigger and
-- the reason is logged. Such an order stays VISIBLE with its reason against it
-- rather than quietly expiring (23.8a removed the calendar deadline that used to
-- end it); pausing or removing it is the player's call, not the world's.
--
-- `nextMonth` advances by the INTERVAL rather than being reset to "now + every",
-- so the cadence stays anchored to the start month even after a long sleep.
function AnimalBuySchedule.recordRun(s, bought, spent)
    if type(bought) ~= "number" or bought <= 0 then return false end
    s.runsDone  = s.runsDone + 1
    s.bought    = s.bought + bought
    s.spent     = s.spent + math.abs(spent or 0)
    s.nextMonth = s.nextMonth + math.max(1, s.everyMonths)
    return true
end

---Range-check and normalise the fields a caller supplies.
---Returns a record, or nil plus a reason.
function AnimalBuySchedule.validate(f)
    if type(f) ~= "table" then return nil, "no fields" end
    local function int(v) v = tonumber(v); if v == nil then return nil end; return math.floor(v) end

    local uid = f.uid
    if type(uid) ~= "string" or uid == "" then return nil, "no barn" end
    -- THE TITLE IS THE ONE PART OF THE KEY THAT CANNOT BE ABSENT. Position alone
    -- would let a shifted catalogue buy a different animal, and price alone is
    -- shared by two breeds often enough to be no key at all.
    local title = f.title
    if type(title) ~= "string" or title == "" then return nil, "no animal chosen" end

    local itemIndex = int(f.itemIndex)
    if itemIndex == nil or itemIndex < 1 then return nil, "no catalogue position" end
    local count = int(f.count)
    local every = int(f.everyMonths)
    local forM  = int(f.forMonths)
    if count == nil or count < 1 or count > AnimalBuySchedule.MAX_COUNT then
        return nil, string.format("count must be 1..%d", AnimalBuySchedule.MAX_COUNT)
    end
    if every == nil or every < 1 or every > AnimalBuySchedule.MAX_EVERY then
        return nil, string.format("interval must be 1..%d months", AnimalBuySchedule.MAX_EVERY)
    end
    -- BOUNDED ON THE RUN COUNT, not on the months. `forMonths` is now `runs x
    -- everyMonths`, so 12 buys a year apart is 144 months and would have failed a
    -- 120 MONTH test while being an entirely ordinary order. `totalRuns` is the
    -- authority on what a record means, so it is what gets bounded -- one figure,
    -- checked where it is defined (8.2).
    if forM ~= AnimalBuySchedule.FOREVER then
        if forM == nil or forM < 1 then
            return nil, "duration must be at least 1 month, or forever"
        end
        local runs = AnimalBuySchedule.totalRuns({ forMonths = forM, everyMonths = every })
        if runs > AnimalBuySchedule.MAX_RUNS then
            return nil, string.format("at most %d runs", AnimalBuySchedule.MAX_RUNS)
        end
    end
    -- HOW LONG BEFORE THE FIRST RUN. 0 means the next 08:00.
    local startIn = int(f.startIn) or 0
    if startIn < 0 or startIn > AnimalBuySchedule.MAX_START then
        return nil, string.format("start delay must be 0..%d months", AnimalBuySchedule.MAX_START)
    end

    local start = int(f.startMonth) or 0
    return {
        id          = f.id,
        uid         = uid,
        barnName    = type(f.barnName) == "string" and f.barnName or "?",
        -- the key: position, title, price. See the file header for why all three.
        itemIndex   = itemIndex,
        title       = title,
        price       = tonumber(f.price),
        -- corroboration only, where the build exposes it. Nothing depends on it.
        subType     = type(f.subType) == "string" and f.subType or nil,
        count       = count,
        everyMonths = every,
        forMonths   = forM,
        startMonth  = start,
        startIn     = startIn,
        -- THE DELAY IS APPLIED ONCE, HERE. `nextMonth` is the truth about when the
        -- next run is due and it is persisted, so a saved order carries its own
        -- answer and `startIn` is only ever read again for the display. On LOAD
        -- nextMonth is supplied and this expression is not reached.
        nextMonth   = int(f.nextMonth) or (start + startIn),
        runsDone    = int(f.runsDone) or 0,
        -- stamped by pruneFinished, not computed; nil until the order completes
        finishedMonth = int(f.finishedMonth),
        bought      = int(f.bought) or 0,
        spent       = tonumber(f.spent) or 0,
        enabled     = f.enabled ~= false,
        note        = type(f.note) == "string" and f.note or "",
    }
end

function AnimalBuySchedule.describe(s)
    local runs = AnimalBuySchedule.totalRuns(s)
    return string.format("#%s %s: %d x %s (row %d) every %d mo, %s%s -- %d/%s runs, %d bought%s",
        tostring(s.id), tostring(s.barnName), s.count, tostring(s.title), s.itemIndex,
        s.everyMonths,
        AnimalBuySchedule.isForever(s) and "forever" or string.format("for %d mo", s.forMonths),
        (s.startIn or 0) > 0 and string.format(", starting in %d mo", s.startIn) or "",
        s.runsDone, runs == math.huge and "*" or tostring(runs), s.bought,
        s.enabled and "" or " [PAUSED]")
end

-- ---------------------------------------------------------------------------
-- THE STORE
-- ---------------------------------------------------------------------------
---Arm a new schedule. A caller that does not say when it starts gets NOW, so the
-- first purchase lands at the next 08:00 rather than at some arbitrary epoch --
-- and `validate` keeps its own 0 default, because the LOADER passes the stored
-- month explicitly and must never be given today's.
function AnimalBuySchedule.add(fields)
    if type(fields) == "table" and fields.startMonth == nil then
        fields.startMonth = AnimalBuySchedule.currentMonth() or 0
    end
    local rec, why = AnimalBuySchedule.validate(fields)
    if rec == nil then return nil, why end
    if rec.id == nil then
        rec.id = AnimalBuySchedule._nextId
        AnimalBuySchedule._nextId = AnimalBuySchedule._nextId + 1
    end
    AnimalBuySchedule.schedules[#AnimalBuySchedule.schedules + 1] = rec
    return rec
end

function AnimalBuySchedule.remove(id)
    id = tonumber(id)
    for i, s in ipairs(AnimalBuySchedule.schedules) do
        if s.id == id then table.remove(AnimalBuySchedule.schedules, i); return true end
    end
    return false
end

function AnimalBuySchedule.byId(id)
    id = tonumber(id)
    for _, s in ipairs(AnimalBuySchedule.schedules) do
        if s.id == id then return s end
    end
    return nil
end

function AnimalBuySchedule.forBarn(uid)
    local out = {}
    for _, s in ipairs(AnimalBuySchedule.schedules) do
        if s.uid == uid then out[#out + 1] = s end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- PERSISTENCE. Registered as a section of AnimalPersist, which owns the file.
--
-- BOTH HALVES ARE UNCONDITIONAL. The loader replaces the table whether or not
-- there is anything to read, because the mod chunk re-runs on every mission load
-- and file-scope state survives it -- a loader that returned early on an absent
-- section would show one savegame's schedules on another savegame's barns.
-- ---------------------------------------------------------------------------
local function saveSection(xml, key)
    setXMLInt(xml, key .. "#nextId", AnimalBuySchedule._nextId)
    for i, s in ipairs(AnimalBuySchedule.schedules) do
        local k = string.format("%s.schedule(%d)", key, i - 1)
        setXMLInt(xml,    k .. "#id",          s.id)
        setXMLString(xml, k .. "#uid",         s.uid)
        setXMLString(xml, k .. "#barnName",    s.barnName)
        -- the three-part key; see the file header
        setXMLInt(xml,    k .. "#itemIndex",   s.itemIndex)
        setXMLString(xml, k .. "#title",       s.title)
        if s.price ~= nil then setXMLFloat(xml, k .. "#price", s.price) end
        if s.subType ~= nil then setXMLString(xml, k .. "#subType", s.subType) end
        setXMLInt(xml,    k .. "#count",       s.count)
        setXMLInt(xml,    k .. "#everyMonths", s.everyMonths)
        setXMLInt(xml,    k .. "#forMonths",   s.forMonths)
        setXMLInt(xml,    k .. "#startMonth",  s.startMonth)
        if (s.startIn or 0) > 0 then setXMLInt(xml, k .. "#startIn", s.startIn) end
        setXMLInt(xml,    k .. "#nextMonth",   s.nextMonth)
        setXMLInt(xml,    k .. "#runsDone",    s.runsDone)
        if s.finishedMonth ~= nil then setXMLInt(xml, k .. "#finishedMonth", s.finishedMonth) end
        setXMLInt(xml,    k .. "#bought",      s.bought)
        setXMLFloat(xml,  k .. "#spent",       s.spent)
        setXMLBool(xml,   k .. "#enabled",     s.enabled)
    end
end

local function loadSection(xml, key)
    AnimalBuySchedule.schedules = {}
    AnimalBuySchedule._nextId   = 1
    if xml == nil then return end

    local nid = getXMLInt(xml, key .. "#nextId")
    if nid ~= nil then AnimalBuySchedule._nextId = nid end

    local i, maxId = 0, 0
    while true do
        local k = string.format("%s.schedule(%d)", key, i)
        if not hasXMLProperty(xml, k) then break end
        local rec, why = AnimalBuySchedule.validate({
            id          = getXMLInt(xml,    k .. "#id"),
            uid         = getXMLString(xml, k .. "#uid"),
            barnName    = getXMLString(xml, k .. "#barnName"),
            itemIndex   = getXMLInt(xml,    k .. "#itemIndex"),
            title       = getXMLString(xml, k .. "#title"),
            price       = getXMLFloat(xml,  k .. "#price"),
            subType     = getXMLString(xml, k .. "#subType"),
            count       = getXMLInt(xml,    k .. "#count"),
            everyMonths = getXMLInt(xml,    k .. "#everyMonths"),
            forMonths   = getXMLInt(xml,    k .. "#forMonths"),
            startMonth  = getXMLInt(xml,    k .. "#startMonth"),
            startIn     = getXMLInt(xml,    k .. "#startIn"),
            nextMonth   = getXMLInt(xml,    k .. "#nextMonth"),
            runsDone    = getXMLInt(xml,    k .. "#runsDone"),
            finishedMonth = getXMLInt(xml,  k .. "#finishedMonth"),
            bought      = getXMLInt(xml,    k .. "#bought"),
            spent       = getXMLFloat(xml,  k .. "#spent"),
            enabled     = getXMLBool(xml,   k .. "#enabled"),
        })
        -- A ROW THAT WILL NOT VALIDATE IS DROPPED AND NAMED. Keeping a malformed
        -- schedule would mean an unattended buyer running on values nothing
        -- checked; silently dropping it would mean a standing order that simply
        -- stopped one day with no explanation.
        if rec ~= nil then
            if rec.id == nil then rec.id = AnimalBuySchedule._nextId + i end
            AnimalBuySchedule.schedules[#AnimalBuySchedule.schedules + 1] = rec
            if rec.id > maxId then maxId = rec.id end
        else
            warn("buy schedule %d dropped on load: %s", i, tostring(why))
        end
        i = i + 1
    end
    if AnimalBuySchedule._nextId <= maxId then AnimalBuySchedule._nextId = maxId + 1 end
    if #AnimalBuySchedule.schedules > 0 then
        dbg("%d buy schedule(s) restored", #AnimalBuySchedule.schedules)
    end
end

if AnimalPersist ~= nil and AnimalPersist.register ~= nil then
    AnimalPersist.register("buySchedules", saveSection, loadSection)
end

-- ---------------------------------------------------------------------------
-- THE CATALOGUE, and resolving a stored key back to a row
-- ---------------------------------------------------------------------------

---REALISTIC LIVESTOCK REPLACES THE DEALER, so a schedule stands down under it.
--
-- Detected STRUCTURALLY first, because that is a measurement rather than a
-- string: AR 20.16 established that `getSaleAnimalsByTypeIndex` is RL's name and
-- that the vanilla animal system does not have it. RL also generates its stock
-- rather than offering the fixed declared tiers, so the tier ordinal this
-- schedule is keyed on means nothing there, and its dealer sells one animal at a
-- time. Standing down fails safe; guessing would spend money on the wrong animal.
--
-- **`AnimalItemNew` IS NOT A TEST FOR IT, AND WAS TRIED AS ONE.** The first build
-- stood down on a completely vanilla farm, reporting *"AnimalItemNew is present"*,
-- and the log settled it in one line: RealisticLivestock was `Available mod:` but
-- never `Load mod:` -- present on disk, not running. So the global belongs to the
-- BASE GAME; RL merely overwrites it wholesale.
--
-- That also answers an open question in 20.14: the vanilla dealer-item wrapper
-- this mod hunted across four passes IS `AnimalItemNew`. 20.23's `_G` scan could
-- not find it because it looked for a table carrying `getPrice`, and the class
-- wears a protected metatable (10.5) so its methods are not enumerable -- the name
-- was reachable the whole time, the methods never were.
--
-- The lesson: **"this mod's code is on disk" is not "this mod is changing
-- behaviour".** Both tests below ask whether it is RUNNING.
function AnimalBuySchedule.dealerReplaced()
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys ~= nil and type(asys.getSaleAnimalsByTypeIndex) == "function" then
        return true, "the animal system exposes getSaleAnimalsByTypeIndex"
    end
    -- Secondary, and DR 5.82's pattern: g_modIsLoaded is keyed by folder name and
    -- answers about a mod that is LOADED, which is the question -- a mod sitting
    -- unticked in the folder changes nothing.
    if g_modIsLoaded ~= nil then
        local ok, loaded = pcall(g_modIsLoaded, "FS25_RealisticLivestockRM")
        if ok and loaded then return true, "FS25_RealisticLivestockRM is loaded" end
    end
    return false
end

---The subtype NAME behind a buy row, where the build exposes one at all.
--
-- OPTIONAL BY DESIGN. `AnimalTrade._iconFor` records the measurement that made the
-- first version of this file list nothing: *"on the BUY side the dealer's animals
-- report none"*. So this is corroboration and display, never the key -- but it is
-- tried through both shapes, because 10.5 measured clusters wearing a PROTECTED
-- metatable, where a plain field read answers nil while the method resolves.
function AnimalBuySchedule.subTypeNameOf(r)
    if r == nil or AnimalHerdData == nil then return nil end
    local function nameOf(idx)
        if type(idx) ~= "number" then return nil end
        local st = AnimalHerdData.subTypeOf(idx)
        return (st ~= nil and type(st.name) == "string") and st.name or nil
    end
    local n = nameOf(r.subTypeIndex)
    if n ~= nil then return n end
    local it = r.item
    if type(it) ~= "table" then return nil end
    for _, o in ipairs({ it, it.animal, it.cluster }) do
        if type(o) == "table" then
            n = nameOf(o.subTypeIndex)
            if n ~= nil then return n end
            if type(o.getSubTypeIndex) == "function" then
                local ok, idx = pcall(o.getSubTypeIndex, o)
                if ok then
                    n = nameOf(idx)
                    if n ~= nil then return n end
                end
            end
        end
    end
    return nil
end

---THE EVIDENCE THAT A DEALER ROW IS ONE BREED (2026-09-13: the auto trader opened
-- from a single breed's row).
--
-- A dealer row carries NO subtype index (23.2), so a breed cannot simply be
-- looked up on it. This collects what the breed looks like -- its visuals and
-- pictures at every age -- once, so rowIsBreed can compare each row cheaply.
function AnimalBuySchedule.breedEvidence(breed)
    local ev = { name = breed, visuals = {}, icons = {} }
    if type(breed) ~= "string" or breed == "" or AnimalHerdData == nil then return ev end
    local idx = nil
    for i = 1, 200 do
        local st = AnimalHerdData.subTypeOf(i)
        if st ~= nil and st.name == breed then idx = i; break end
    end
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if idx == nil or asys == nil or asys.getVisualByAge == nil then return ev end
    for age = 0, 120 do
        local ok, v = pcall(asys.getVisualByAge, asys, idx, age)
        if ok and type(v) == "table" and not ev.visuals[v] then
            ev.visuals[v] = true
            if AnimalHerdData.iconFromStore ~= nil then
                local okF, f = pcall(AnimalHerdData.iconFromStore, v.store)
                if okF and type(f) == "string" and f ~= "" then ev.icons[f] = true end
            end
        end
    end
    return ev
end

---IS THIS CATALOGUE ROW OF THE BREED `ev` DESCRIBES? Strongest evidence first:
--   1. the row's subtype NAME, where subTypeNameOf resolved one -- authoritative,
--      so a row naming a DIFFERENT breed is refused outright;
--   2. its VISUAL, by identity with one of the breed's own;
--   3. its PICTURE FILE, against the breed's pictures.
function AnimalBuySchedule.rowIsBreed(c, ev)
    if type(c) ~= "table" or type(ev) ~= "table" then return false end
    if c.subType ~= nil then return c.subType == ev.name end
    local r = c.row
    if type(r) ~= "table" then return false end
    local it = r.item
    if type(it) == "table" then
        -- appended, not a table constructor: a nil hole would stop ipairs early
        local cands = {}
        if type(it.visual) == "table" then cands[#cands + 1] = it.visual end
        if type(it.animal) == "table" and type(it.animal.visual) == "table" then cands[#cands + 1] = it.animal.visual end
        if type(it.cluster) == "table" and type(it.cluster.visual) == "table" then cands[#cands + 1] = it.cluster.visual end
        for _, v in ipairs(cands) do
            if ev.visuals[v] then return true end
        end
    end
    if type(r.icon) == "string" and ev.icons[r.icon] then return true end
    return false
end

---Every buyable row for a barn, in the dealer's own order.
---Returns a list of { index, title, ageText, each, subType, row }, and an error.
--
-- SORTED BY THE DEALER'S INDEX, which is the order the catalogue is declared in
-- and therefore the order the stored position refers to. Sorting by anything else
-- would make the position mean something different from what was saved.
function AnimalBuySchedule.catalogue(husbandry)
    local rows, err = AnimalTrade.buyRows(husbandry)
    if rows == nil or #rows == 0 then
        return {}, err or "the dealer offered nothing"
    end
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            index   = r.index,
            title   = r.name,
            ageText = r.ageText,
            each    = r.eachNet or r.eachGross,
            subType = AnimalBuySchedule.subTypeNameOf(r),
            row     = r,
        }
    end
    table.sort(out, function(a, b) return (a.index or 0) < (b.index or 0) end)
    return out, nil
end

---The catalogue row a stored key names, or nil plus a reason.
--
-- `spec` is a schedule record, or any table carrying itemIndex / title / price.
-- Returns row, nil, note -- where a non-nil NOTE means the row was found by a
-- fallback rather than where it was expected, which is worth logging.
--
-- THE THREE PARTS FAIL INDEPENDENTLY, which is the whole reason there are three:
-- a changed mod set moves positions and may change prices; a changed game
-- language rewrites every title and touches no price. Neither can satisfy two.
function AnimalBuySchedule.resolveRow(husbandry, spec)
    if type(spec) ~= "table" then return nil, "no key" end
    local cat, err = AnimalBuySchedule.catalogue(husbandry)
    if #cat == 0 then return nil, err or "the dealer offered nothing" end

    local function samePrice(c)
        if type(spec.price) ~= "number" or type(c.each) ~= "number" then return false end
        return math.abs(math.abs(c.each) - math.abs(spec.price)) < 0.5
    end
    local function unique(pred)
        local hit, n = nil, 0
        for _, c in ipairs(cat) do
            if pred(c) then hit = c; n = n + 1 end
        end
        if n == 1 then return hit end
        return nil
    end

    -- 1. where it was, and still recognisable. The normal path.
    for _, c in ipairs(cat) do
        if c.index == spec.itemIndex and (c.title == spec.title or samePrice(c)) then
            return c.row, nil, nil
        end
    end
    -- 2. the same animal, somewhere else in the list
    local byTitle = unique(function(c) return c.title == spec.title end)
    if byTitle ~= nil then
        return byTitle.row, nil,
               string.format("moved to row %d", byTitle.index or 0)
    end
    -- 3. the title is unrecognisable but exactly one row still costs what it cost
    local byPrice = unique(samePrice)
    if byPrice ~= nil then
        return byPrice.row, nil,
               string.format("matched on price at row %d", byPrice.index or 0)
    end
    return nil, string.format("the dealer no longer offers '%s'", tostring(spec.title))
end
-- ---------------------------------------------------------------------------
-- EXECUTION
-- ---------------------------------------------------------------------------

---How many animals will actually fit. nil where the barn does not say.
--
-- FREE SLOTS, NOT `getSourceMaxNumAnimals`. The controller has that method and
-- it would be the game's own answer, but its argument list cannot be read
-- anywhere -- RL's override takes (superFunc, _) and the vanilla body is absent
-- from the SDK source -- and AR 13.2 is the standing reminder of what a guessed
-- argument slot costs when money is moving. `numAnimals` / `maxAnimals` come
-- from readBarn, which AR already trusts everywhere else.
--
-- It matters rather than being a nicety: `applySource` validates the WHOLE
-- request, so asking for ten into a barn with three free slots is refused
-- outright and buys nothing at all.
function AnimalBuySchedule.freeSlots(husbandry)
    local b = AnimalHerdData.readBarn(husbandry)
    if b == nil then return nil end
    if type(b.maxAnimals) ~= "number" or type(b.numAnimals) ~= "number" then return nil end
    return math.max(0, b.maxAnimals - b.numAnimals)
end

---Run ONE schedule now. Returns bought, spent, note.
--
-- Nothing here re-implements a check the game already makes: `applySource`
-- validates the request and reports through the error callback, which
-- AnimalTrade.commit already turns into a failure -- including the silent case,
-- where a call returns cleanly and never confirms (AR 20.4).
function AnimalBuySchedule.runOne(s)
    local can, why = AnimalTrade.canTrade()
    if not can then return 0, 0, "cannot trade: " .. tostring(why) end

    local replaced, rwhy = AnimalBuySchedule.dealerReplaced()
    if replaced then return 0, 0, "stood down: " .. tostring(rwhy) end

    local SD = HusbandryRedux ~= nil and HusbandryRedux.DR or nil
    local p  = (SD ~= nil and SD.placeableByUid ~= nil) and SD.placeableByUid(s.uid) or nil
    if p == nil then return 0, 0, "barn not found" end

    local row, rerr, moved = AnimalBuySchedule.resolveRow(p, s)
    if row == nil then return 0, 0, tostring(rerr) end
    -- The row was found somewhere other than where it was saved. Worth saying, and
    -- worth RE-ANCHORING to, so the fallback is not paid for on every future run.
    if moved ~= nil then
        warn("buy schedule #%s: '%s' %s", tostring(s.id), tostring(s.title), moved)
        s.itemIndex = row.index or s.itemIndex
    end

    local want = s.count
    local free = AnimalBuySchedule.freeSlots(p)
    if free ~= nil then
        if free <= 0 then return 0, 0, "the barn is full" end
        if free < want then want = free end
    end

    local q = AnimalTrade.quote(p, AnimalTrade.MODE_BUY, row, want)
    local each = q ~= nil and (q.net or q.gross) or nil

    local ok, msg = AnimalTrade.commit(p, AnimalTrade.MODE_BUY, row, want)
    if ok then
        return want, math.abs(each or 0), nil
    end

    -- ONE BATCH FAILED. Fall back to buying singly ONLY on an explicit refusal,
    -- never on silence: "noConfirmation" is the one outcome that might mean the
    -- purchase happened without saying so, and retrying that would double-buy.
    if msg == "noConfirmation" or want <= 1 then
        return 0, 0, "refused: " .. tostring(msg)
    end
    local got, spent = 0, 0
    for _ = 1, want do
        local r2 = AnimalBuySchedule.resolveRow(p, s)
        if r2 == nil then break end
        local q1 = AnimalTrade.quote(p, AnimalTrade.MODE_BUY, r2, 1)
        local ok1 = AnimalTrade.commit(p, AnimalTrade.MODE_BUY, r2, 1)
        if not ok1 then break end
        got   = got + 1
        spent = spent + math.abs((q1 ~= nil and (q1.net or q1.gross)) or 0)
    end
    if got == 0 then return 0, 0, "refused: " .. tostring(msg) end
    return got, spent, string.format("batch refused (%s); bought %d singly", tostring(msg), got)
end

---A COMPLETED ORDER LINGERS FOR ONE MONTH, THEN GOES.
--
-- Author's call: an order that has finished should read "done" for a month so the
-- player sees it completed, and then leave the list and the savegame rather than
-- accumulating forever.
--
-- `finishedMonth` is STAMPED rather than computed, and stamped LAZILY, which is what
-- makes it need no migration: an order already complete in an existing save has no
-- stamp, gets one on the next pass, and goes a month later. Computing it from
-- `startMonth + forMonths` would reintroduce exactly the calendar the fix above
-- removed.
--
-- BACKWARD ITERATION, because it removes as it goes. Forward with table.remove skips
-- the element after each removal.
function AnimalBuySchedule.pruneFinished(month)
    if type(month) ~= "number" then return 0 end
    local removed = 0
    for i = #AnimalBuySchedule.schedules, 1, -1 do
        local s = AnimalBuySchedule.schedules[i]
        if s ~= nil and AnimalBuySchedule.isFinished(s) then
            if s.finishedMonth == nil then
                s.finishedMonth = month
            elseif month > s.finishedMonth then
                table.remove(AnimalBuySchedule.schedules, i)
                removed = removed + 1
                warn("buy schedule #%s finished (%d x %s bought) and has been cleared",
                     tostring(s.id), s.bought, tostring(s.title))
            end
        end
    end
    return removed
end

---Every schedule that is due this month. Server side; called from the hour tick.
function AnimalBuySchedule.runDue()
    -- THE AUTO TRADER SWITCH REACHES THE RUNNER, not just the buttons. Hiding the
    -- UI while standing orders went on spending money would be the worst version
    -- of this setting -- and it became reachable the moment the default turned
    -- OFF, because a save older than the settings adopts that default with its
    -- orders intact rather than deleted.
    --
    -- HERE RATHER THAN AT THE SUBSCRIPTION, so the switch takes effect on the next
    -- hour instead of needing a reload, and so nothing has to unsubscribe and
    -- resubscribe from HOUR_CHANGED.
    if AnimalSettings ~= nil and not AnimalSettings.autoTraderEnabled() then return 0 end
    local month = AnimalBuySchedule.currentMonth()
    if month == nil then
        warn("buy schedules idle: the environment does not report a day")
        return 0
    end
    local ran = 0
    -- Indexed rather than ipairs: a schedule finishing is left in place (the
    -- player should see that it completed), so nothing mutates the list here --
    -- but a future auto-prune would, and iterating by index is what makes that
    -- safe to add.
    for i = 1, #AnimalBuySchedule.schedules do
        local s = AnimalBuySchedule.schedules[i]
        if s ~= nil and AnimalBuySchedule.isDue(s, month) then
            local bought, spent, note = AnimalBuySchedule.runOne(s)
            s.note = note or ""
            if AnimalBuySchedule.recordRun(s, bought, spent) then
                ran = ran + 1
                -- UNCONDITIONAL. Money moved without the player pressing anything;
                -- that belongs in a default log, not behind a debug flag.
                warn("buy schedule #%s: bought %d x %s at %s for %s (run %d/%d)%s",
                     tostring(s.id), bought, tostring(s.title), tostring(s.barnName),
                     tostring(math.floor(spent + 0.5)), s.runsDone,
                     AnimalBuySchedule.totalRuns(s),
                     note ~= nil and (" -- " .. note) or "")
            else
                -- A repeated blocker would otherwise print every game day.
                if s.note ~= AnimalBuySchedule._lastNote then
                    AnimalBuySchedule._lastNote = s.note
                    warn("buy schedule #%s bought nothing: %s", tostring(s.id), tostring(s.note))
                end
            end
        end
    end
    AnimalBuySchedule.pruneFinished(month)
    return ran
end

-- ---------------------------------------------------------------------------
-- THE DRIVER
--
-- AR had no clock of its own before this -- not one messageCenter subscription
-- anywhere in the mod. HOUR_CHANGED publishes the hour (Placeable.lua:1585) and
-- is what ProductionChainManager runs on, so it is the established seam.
-- ---------------------------------------------------------------------------
function AnimalBuySchedule:onHourChanged(hour)
    -- SERVER ONLY. This moves money; AnimalTrade.canTrade refuses on a client
    -- anyway, but returning here keeps a client from even reading the world.
    if g_currentMission ~= nil and g_currentMission.getIsServer ~= nil then
        local okS, isServer = pcall(g_currentMission.getIsServer, g_currentMission)
        if okS and isServer == false then return end
    end

    -- The deferred-load retry lives here so the mod has ONE clock (a dedicated
    -- server cannot resolve its savegame folder at loadMission00Finished).
    if AnimalPersist ~= nil and AnimalPersist.retryIfPending ~= nil then
        pcall(AnimalPersist.retryIfPending)
    end

    if type(hour) ~= "number" then
        local env = g_currentMission ~= nil and g_currentMission.environment or nil
        hour = env ~= nil and env.currentHour or nil
    end
    -- SELL ORDERS EVERY HOUR (author, 2026-09-14), ahead of the buy orders' daily hour.
    -- Births land the moment a new month begins (onPeriodChanged), so a sale that
    -- waited for 08:00 could fall AFTER the births it was meant to make room for --
    -- and on a one-day month an order set after 08:00 would not run until the next
    -- month had already started. Hourly, a due order runs within the hour. It cannot
    -- sell twice: a run that sold books the next due month.
    if AnimalSellSchedule ~= nil and AnimalSellSchedule.runDue ~= nil
       and #(AnimalSellSchedule.orders or {}) > 0 then
        local okS, errS = pcall(AnimalSellSchedule.runDue)
        if not okS then warn("sell order pass failed: %s", tostring(errS)) end
    end

    if hour ~= AnimalBuySchedule.RUN_HOUR then return end
    if #AnimalBuySchedule.schedules == 0 then return end
    local ok, err = pcall(AnimalBuySchedule.runDue)
    if not ok then warn("buy schedule pass failed: %s", tostring(err)) end
end

function AnimalBuySchedule.install()
    if g_messageCenter == nil or MessageType == nil or MessageType.HOUR_CHANGED == nil then
        warn("buy schedules disabled: HOUR_CHANGED is unavailable")
        return false
    end
    -- Unsubscribe first: the mod chunk re-runs per mission load, and a second
    -- subscription for the same target would run the pass twice an hour.
    pcall(g_messageCenter.unsubscribe, g_messageCenter, MessageType.HOUR_CHANGED, AnimalBuySchedule)
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED,
                              AnimalBuySchedule.onHourChanged, AnimalBuySchedule)
    dbg("buy schedule driver installed (hour %d)", AnimalBuySchedule.RUN_HOUR)
    return true
end

if Mission00 ~= nil and Mission00.loadMission00Finished ~= nil then
    Mission00.loadMission00Finished = Utils.appendedFunction(
        Mission00.loadMission00Finished,
        function() pcall(AnimalBuySchedule.install) end)
end

-- ---------------------------------------------------------------------------
-- DEV CONSOLE -- TEMPORARY, and it is how this engine gets confirmed in game
-- BEFORE the dialog exists. The schedule window is the player's surface; these
-- are scaffolding, and they go on AR 22's strip list. Requires
-- game.xml <development><controls>true.
-- ---------------------------------------------------------------------------
local function say(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    print(ok and line or tostring(fmt))
end

local function barnAt(n)
    local barns = AnimalHerdData.enumerate()
    n = tonumber(n)
    if n == nil or barns[n] == nil then
        say("arBuy: pick a barn 1..%d --", #barns)
        for i, b in ipairs(barns) do say("  %d  %s", i, tostring(b.name)) end
        return nil
    end
    return barns[n]
end

---AN EMPTY CATALOGUE NAMES ITS OWN CAUSE.
--
-- The first build listed nothing and the message could not say whether
-- `buyRows` had returned no rows or whether this function had filtered them all
-- out -- which is the difference between a dealer problem and a bug of ours, and
-- it cost a round trip. `buyRows` prints its own three-fact line when it yields
-- nothing (see AnimalTrade), so anything reported HERE means rows existed and
-- something downstream dropped them.
function AnimalBuySchedule:cmdCatalogue(n)
    local b = barnAt(n)
    if b == nil then return end
    local raw = AnimalTrade.buyRows(b.placeable)
    local cat, err = AnimalBuySchedule.catalogue(b.placeable)
    if #cat == 0 then
        say("arBuyCat: nothing offered -- buyRows gave %d row(s), catalogue kept 0 (%s)",
            #(raw or {}), tostring(err))
        return
    end
    say("arBuyCat: %s -- %d row(s). The ROW NUMBER is what a schedule stores.", b.name, #cat)
    for _, c in ipairs(cat) do
        say("  row %-3d %-26s %-10s %-9s %s",
            c.index or 0, tostring(c.title), tostring(c.ageText),
            c.each ~= nil and string.format("%d", math.abs(c.each)) or "?",
            c.subType ~= nil and ("[" .. c.subType .. "]") or "")
    end
end

function AnimalBuySchedule:cmdAdd(n, rowNum, count, every, forM)
    local b = barnAt(n)
    if b == nil then return end
    if rowNum == nil or count == nil then
        say("arBuyAdd <barn> <row> <count> <everyMonths> <forMonths>")
        say("  e.g. arBuyAdd %s 3 10 1 10  -- 10 of row 3, every month, for 10 months", tostring(n))
        say("  run arBuyCat %s for the row numbers", tostring(n))
        return
    end
    -- RESOLVED AND PRICED BEFORE IT IS STORED. A schedule naming a row the dealer
    -- will not quote is one that can only ever fail at 08:00, once a month, quietly.
    local cat = AnimalBuySchedule.catalogue(b.placeable)
    local want, pick = tonumber(rowNum), nil
    for _, c in ipairs(cat) do if c.index == want then pick = c end end
    if pick == nil then
        say("arBuyAdd refused: no row %s -- run arBuyCat %s", tostring(rowNum), tostring(n))
        return
    end

    local rec, err = AnimalBuySchedule.add({
        uid = b.uid, barnName = b.name,
        itemIndex = pick.index, title = pick.title, price = pick.each,
        subType = pick.subType,
        count = count, everyMonths = every, forMonths = forM,
    })
    if rec == nil then say("arBuyAdd refused: %s", tostring(err)); return end
    say("arBuyAdd: %s", AnimalBuySchedule.describe(rec))
    say("  first run at %02d:00, month %d", AnimalBuySchedule.RUN_HOUR, rec.nextMonth)
end

function AnimalBuySchedule:cmdList()
    local month = AnimalBuySchedule.currentMonth()
    say("arBuyList: month %s, %d schedule(s)", tostring(month), #AnimalBuySchedule.schedules)
    for _, s in ipairs(AnimalBuySchedule.schedules) do
        say("  %s", AnimalBuySchedule.describe(s))
        say("      next month %d, %s%s", s.nextMonth,
            AnimalBuySchedule.isDue(s, month) and "DUE NOW" or "waiting",
            (s.note ~= nil and s.note ~= "") and (" -- " .. s.note) or "")
    end
end

function AnimalBuySchedule:cmdDel(id)
    say(AnimalBuySchedule.remove(id) and "arBuyDel: removed #%s" or "arBuyDel: no schedule #%s",
        tostring(id))
end

---Force the pass now, ignoring the hour. With an id, forces that ONE schedule
-- even if it is not due -- which is what makes a ten-month standing order
-- testable without sleeping through ten months.
function AnimalBuySchedule:cmdRun(id)
    if id ~= nil then
        local s = AnimalBuySchedule.byId(id)
        if s == nil then say("arBuyRun: no schedule #%s", tostring(id)); return end
        local bought, spent, note = AnimalBuySchedule.runOne(s)
        AnimalBuySchedule.recordRun(s, bought, spent)
        say("arBuyRun #%s: bought %d, spent %d%s", tostring(id), bought,
            math.floor(spent + 0.5), note ~= nil and (" -- " .. note) or "")
        return
    end
    say("arBuyRun: %d schedule(s) ran", AnimalBuySchedule.runDue())
end

-- THE COLON FORM ON EVERY cmd* ABOVE IS LOAD-BEARING. addConsoleCommand with a
-- target calls target[name](target, ...), so the target arrives as argument ONE
-- -- a dot-form `cmdDel(id)` would be handed the module table where it expected
-- an id. AnimalFeedModel.Console:consoleCommand is the established shape here.
function AnimalBuySchedule.installConsole()
    if addConsoleCommand == nil then return false end
    -- The mod chunk re-runs on every mission load; register once.
    if AnimalBuySchedule._consoleDone then return true end
    AnimalBuySchedule._consoleDone = true
    addConsoleCommand("arBuyCat",  "List a barn's buyable rows with their tier numbers",
                      "cmdCatalogue", AnimalBuySchedule)
    addConsoleCommand("arBuyAdd",  "Add a buy schedule: <barn> <row> <count> <every> <for>",
                      "cmdAdd", AnimalBuySchedule)
    addConsoleCommand("arBuyList", "List the buy schedules", "cmdList", AnimalBuySchedule)
    addConsoleCommand("arBuyDel",  "Remove a buy schedule by id", "cmdDel", AnimalBuySchedule)
    addConsoleCommand("arBuyRun",  "Run due buy schedules now, or force one by id",
                      "cmdRun", AnimalBuySchedule)
    return true
end

-- Off for release: see HusbandryRedux.DEV_CONSOLE.
if HusbandryRedux ~= nil and HusbandryRedux.DEV_CONSOLE then AnimalBuySchedule.installConsole() end
