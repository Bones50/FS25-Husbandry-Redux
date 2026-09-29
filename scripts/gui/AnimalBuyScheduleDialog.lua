-- ============================================================================
-- AnimalBuyScheduleDialog.lua  (Husbandry Redux) -- THE AUTO TRADER
--
-- Three modes over one set of elements:
--   BUY ORDERS   buy N of a dealer row every E months for F months
--   SELL ORDERS  sell N of the herd every E months for F months, picked how
--   SELL RULES   the per-barn POLICY the AnimalSellRules engine already runs
--
-- WHY THREE. A timed order and a policy are different instruments. `plan()`
-- optimises the whole pen at once -- headroom picks the least valuable animal,
-- peak defers to the earnings test, the calf rule changes what a slot is FOR
-- (17.2) -- so the rules cannot be split into independent list rows. An order,
-- conversely, is exactly a row. Forcing either into the other's shape would have
-- been the wrong control set.
--
-- NOTHING HERE DECIDES ANYTHING. The catalogue, the prices, the plan, the guards
-- and the month arithmetic live in AnimalBuySchedule / AnimalSellSchedule /
-- AnimalSellPolicy / AnimalSellRules, harnessed at 145 + 80 + 140 checks. This
-- file chooses, displays and calls.
--
-- A SELL ORDER SELLS ON ITS SCHEDULE, like a buy order buys on its schedule
-- (AnimalSellSchedule.runDue, 2026-09-14).
--
-- ELEMENTS ARE SWAPPED BY VISIBILITY AND TEXT, never repositioned (DR 5.37).
-- The six right-hand slots are generic; `slotSpec` says what slot i means in the
-- current mode, and one handler per slot dispatches through it.
--
-- TWO LISTS SHARE ONE DELEGATE, so EVERY delegate method branches on `list` --
-- DR 5.77 records the second table moving the first one's index otherwise.
-- ============================================================================

AnimalBuyScheduleDialog = {}
local AnimalBuyScheduleDialog_mt = Class(AnimalBuyScheduleDialog, MessageDialog)

local MODE_BUY, MODE_SELL_ORDER, MODE_SELL_RULES = 1, 2, 3
AnimalBuyScheduleDialog.MODE_BUY        = MODE_BUY
AnimalBuyScheduleDialog.MODE_SELL_ORDER = MODE_SELL_ORDER
AnimalBuyScheduleDialog.MODE_SELL_RULES = MODE_SELL_RULES

-- THE FOUR CURATED RINGS ARE GONE -- COUNTS, EVERYS, FORS and STARTS, with the
-- `indexOfValue` helper that found a value in them. Every order field is typed
-- now (27.9), and each was dead: enumerated before deleting rather than assumed,
-- one declaration site apiece and nothing else (6.27).
AnimalBuyScheduleDialog.SLOTS  = 6

-- THE ENGINE'S REASON CODES, mapped explicitly. Building the key by concatenating
-- a prefix onto the code would hide every one of these from
-- check_l10n_animal.py, and a reason with no wording renders as a raw code. A NEW
-- reason in AnimalSellRules shows here as its bare code rather than as nothing,
-- which is the honest failure.
-- (The checker reads QUOTED literals, so a prefix written out in a comment would
-- itself register as a use -- which is why this paragraph does not write one.)
local REASON_KEY = {
    headroom = "ar_reason_headroom",
    peak     = "ar_reason_peak",
    calf     = "ar_reason_calf",
    earnings = "ar_reason_earnings",
    order    = "ar_reason_order",
}

-- WHAT EACH RULE DOES, in one sentence, shown when the player touches it. Mapped
-- explicitly for the same reason REASON_KEY is: a key built by concatenation is
-- invisible to check_l10n_animal.py.
local HELP_KEY = {
    sellAtPeak      = "ar_pol_help_sellAtPeak",
    keepFreeSlots   = "ar_pol_help_keepFreeSlots",
    headroomWorthIt = "ar_pol_help_headroomWorthIt",
    minHealthToSell = "ar_pol_help_minHealthToSell",
    keepBreeders    = "ar_pol_help_keepBreeders",
    sellCalves      = "ar_pol_help_sellCalves",
}

-- WHY A PLAN CAME BACK EMPTY. The engine emits notes as DATA carrying a `kind`
-- (its module is pure and does not know what language the player reads), so the
-- wording lives here.
local NOTE_KEY = {
    breeding  = "ar_note_breeding",
    blocked   = "ar_note_blocked",
    held      = "ar_note_held",
    unsellable = "ar_note_unsellable",
    nursery   = "ar_note_nursery",
}

local function l10n(key, fallback)
    if HusbandryRedux ~= nil and HusbandryRedux.l10n ~= nil then return HusbandryRedux.l10n(key, fallback) end
    return fallback
end

local function money(v)
    if v == nil then return "-" end
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, s = pcall(g_i18n.formatMoney, g_i18n, v, 0, true, true)
        if ok then return s end
    end
    return string.format("%d", math.floor(v + 0.5))
end

local function months(n)
    if n == 1 then return l10n("ar_bs_month1", "1 month") end
    return string.format(l10n("ar_bs_months", "%d months"), n)
end

local function setText(el, txt)
    if el ~= nil and el.setText ~= nil then el:setText(txt or "") end
end
local function setVisible(el, on)
    if el ~= nil and el.setVisible ~= nil then el:setVisible(on == true) end
end
---HOW FAR AN ORDER HAS GOT. An unbounded one has no denominator to print, and
-- `math.huge` formatted through "%d" is not something to let near a cell.
local function progressText(done, total, l10n)
    if total == math.huge then
        return string.format(l10n("ar_bs_progressOpen", "%d  ongoing"), done or 0)
    end
    return string.format(l10n("ar_bs_progress", "%d / %d"), done or 0, total or 0)
end

function AnimalBuyScheduleDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or AnimalBuyScheduleDialog_mt)
    self.barns, self.rowsA, self.rowsB = {}, {}, {}
    self.mode, self.barnIndex, self.aIndex, self.bIndex = MODE_BUY, 1, 1, 1
    -- EVERY ORDER FIELD IS A PICKER NOW, and a picker owns its own value -- so
    -- there is no index state here to drift out of step with it. `foreverOn` is
    -- the one order setting that is still a ring, because it is a state.
    self.pickers, self.foreverOn = {}, false
    return self
end

-- ---------------------------------------------------------------------------
-- EVERY NUMBER ON THE ORDER PAGES IS TYPED, NOT STEPPED (2026-09-02).
-- See TextPicker.lua.
--
-- The curated rings each carried the same apology in their own comment -- "a
-- player setting up a standing order wants 10 or 20, not twenty-three clicks to
-- reach 24" -- and the cost was that every value BETWEEN the entries was simply
-- unreachable: the counts ring stopped at 50 against a real cap of 100, and the
-- durations ring offered eleven of the 120 the record accepts. A typed field
-- answers that objection rather than lengthening the lists, so all four rings and
-- their lookup helper are deleted.
--
-- SLOT 4 IS STILL A RING, and deliberately: "keep going forever" is a STATE, not
-- a number, and 26.1 built it as a sentinel rather than a big number for exactly
-- that reason. Overloading a value of the count to mean it would have put two
-- kinds of answer in one field.
--
-- THE FIELDS START EMPTY ON EVERY OPEN, which is a real behaviour change: the
-- dialog used to open with 10 / 1 month / 12 already chosen, so Add worked
-- immediately. It now waits, and a nil from `num()` is what holds Add disabled
-- and the money block on dashes until every field is answered.
-- ---------------------------------------------------------------------------

---WHICH SLOT MEANS WHAT, on the two ORDER tabs. Named rather than written as bare
-- indices at a dozen call sites: the numbers are meaningless and a transposed
-- pair would be silent.
AnimalBuyScheduleDialog.SLOT_COUNT   = 1
AnimalBuyScheduleDialog.SLOT_EVERY   = 2
AnimalBuyScheduleDialog.SLOT_RUNS    = 3
AnimalBuyScheduleDialog.SLOT_FOREVER = 4
AnimalBuyScheduleDialog.SLOT_START   = 5

---THE COUNT'S CAP IS THE BARN'S, not the schedule's.
--
-- `MAX_COUNT` (100) is a sanity bound on the ORDER RECORD and predates this
-- control; `runOne` separately clamps each run to `freeSlots(p)`, which is at
-- most the barn's capacity. So on a 96 animal cow barn a count of 97..100
-- validates, saves and then silently under delivers for ever -- a number the
-- player can choose and the farm can never honour.
--
-- Free slots would be the WRONG bound here even though it is what the run uses:
-- an order is a standing instruction and the barn will have emptied and refilled
-- many times before it stops. CAPACITY is the stable ceiling no single run can
-- ever exceed, so it is the honest thing to offer.
--
-- FAILS OPEN to MAX_COUNT if the barn cannot answer, which is exactly the
-- behaviour before this existed.
function AnimalBuyScheduleDialog:countCap()
    local hard = AnimalBuySchedule.MAX_COUNT
    local _, p = self:barn()
    if p == nil or p.getMaxNumOfAnimals == nil then return hard end
    local ok, n = pcall(p.getMaxNumOfAnimals, p)
    if not ok or type(n) ~= "number" or n < 1 then return hard end
    return math.min(math.floor(n), hard)
end

---ONE PICKER PER SLOT, built on first use and then reconfigured by `applySlots`
-- from whatever that slot means in the current mode. The picker OWNS the value --
-- there is no second copy on the dialog to keep in step with it.
function AnimalBuyScheduleDialog:picker(i)
    if TextPicker == nil then return nil end
    self.pickers = self.pickers or {}
    local pk = self.pickers[i]
    if pk == nil then
        local inp = self["numInput" .. i]
        if inp == nil then return nil end        -- no numBox declared for this slot
        pk = TextPicker.new({
            name = "slot" .. i,
            -- A LIGHT REFRESH, not the whole dialog. A number moves the money block
            -- and the Add button and nothing else; a full refresh would reload both
            -- lists under the player for a keystroke.
            onChanged = function()
                self:applyMoney()
                self:applyButtons()
            end,
        })
        pk:attach(inp, self["numHint" .. i], self["numLeft" .. i], self["numRight" .. i])
        self.pickers[i] = pk
    end
    return pk
end

---What slot `i` currently holds, or nil when the player has not said yet. NIL IS
-- NOT ZERO and never becomes it: every caller tests for nil and shows a dash or
-- disables a button rather than quoting a figure nobody chose (DR 5.46c).
function AnimalBuyScheduleDialog:num(i)
    local pk = self.pickers ~= nil and self.pickers[i] or nil
    if pk == nil or pk.inert then return nil end
    return pk:get()
end

function AnimalBuyScheduleDialog:count() return self:num(AnimalBuyScheduleDialog.SLOT_COUNT) end
function AnimalBuyScheduleDialog:every() return self:num(AnimalBuyScheduleDialog.SLOT_EVERY) end
function AnimalBuyScheduleDialog:start() return self:num(AnimalBuyScheduleDialog.SLOT_START) end

---HOW LONG THE ORDER RUNS, in the units the RECORD stores.
--
-- THE CONTROL EDITS A RUN COUNT AND THE RECORD KEEPS MONTHS, converted here and
-- nowhere else. 23.8a already found these to be one quantity written two ways --
-- *"FOR 10 MONTHS IS HOW A PLAYER SAYS TEN PURCHASES ... the count is the honest
-- one"* -- and deleted the calendar deadline on that finding, but left the field
-- in months. Naming the control "Number of buys" finishes that argument.
--
-- `forMonths = runs x everyMonths` makes `totalRuns` (which is
-- `ceil(forMonths / every)`) return EXACTLY the number typed, so the two figures
-- can no longer disagree -- which is why the Purchases row could go.
--
-- CONVERTING HERE RATHER THAN CHANGING THE STORED FIELD is what makes this need
-- no migration and no version bump: every order already in a savegame keeps
-- precisely the meaning it has today.
function AnimalBuyScheduleDialog:forMonths()
    if self.foreverOn then return AnimalBuySchedule.FOREVER end
    local runs, every = self:num(AnimalBuyScheduleDialog.SLOT_RUNS), self:every()
    if runs == nil or every == nil then return nil end
    return runs * every
end

---`breed` (a subtype NAME, optional) narrows the dialog to that one breed: the
-- Pigs tab's per-breed Auto Trader button. nil opens it on the whole barn, as the
-- footer button always has.
function AnimalBuyScheduleDialog.show(barns, lockBarn, mode, breed)
    local d = AnimalBuyScheduleDialog._instance
    if d == nil then return false end
    d.barns = barns or {}
    d.lockBarn = lockBarn == true
    d.mode = mode or MODE_BUY
    d.breed = (type(breed) == "string" and breed ~= "") and breed or nil
    d._breedEv, d.breedNote = nil, nil
    d.barnIndex, d.aIndex, d.bIndex = 1, 1, 1
    d.notice = nil
    g_gui:showDialog("AnimalBuyScheduleDialog")
    return true
end

---BOUND IN onOpen, not only in onGuiSetupFinished (20.9): the setup hook is not a
-- reliable place for it on a dialog loaded through loadGui with a target, and with
-- no data source a list never asks for rows, which looks like four separate bugs.
function AnimalBuyScheduleDialog:onGuiSetupFinished()
    AnimalBuyScheduleDialog:superClass().onGuiSetupFinished(self)
    self:bindLists()
end

function AnimalBuyScheduleDialog:bindLists()
    for _, l in ipairs({ self.catList, self.schedList }) do
        if l ~= nil then l:setDataSource(self); l:setDelegate(self) end
    end
end

function AnimalBuyScheduleDialog:onOpen()
    AnimalBuyScheduleDialog:superClass().onOpen(self)
    self:bindLists()
    -- EMPTY ON EVERY OPEN, deliberately: the fields do not remember, so the grey
    -- prompt is what the player meets each time rather than a number from a
    -- previous visit that they never re-approved. Forever goes back to off with
    -- them, or a fresh order would silently inherit the last one's open ending.
    self.foreverOn = false
    for i = 1, AnimalBuyScheduleDialog.SLOTS do
        local pk = self:picker(i)
        if pk ~= nil then pk:reset() end
    end
    self:initSelectors()
    self:rebuild()
end

function AnimalBuyScheduleDialog:barn()
    local b = self.barns[self.barnIndex]
    return b, (b ~= nil and b.placeable or nil), (b ~= nil and b.uid or nil)
end

function AnimalBuyScheduleDialog:isSell() return self.mode ~= MODE_BUY end

-- ---------------------------------------------------------------------------
-- THE SLOTS. `slotSpec(i)` is the single place that says what slot i means in the
-- current mode: its label, the texts to show, which is current, and what to do
-- when it moves. Everything else about the right column is generic.
-- ---------------------------------------------------------------------------
function AnimalBuyScheduleDialog:slotSpec(i)
    local _, _, uid = self:barn()

    local function ring(list, field, label, fmt)
        local t = {}
        for k, v in ipairs(list) do t[k] = fmt(v) end
        return { label = label, texts = t, index = self[field],
                 set = function(s) if list[s] ~= nil then self[field] = s end end }
    end
    -- THE FOUR TYPED SLOTS. `kind` is what applySlots dispatches on; there are no
    -- `texts` because there is no list of values to show, and `min` / `max` are
    -- the bounds the field enforces and the out-of-range message quotes.
    --
    -- EVERY LABEL IS WORDED PER MODE, the way `everySlot` alone used to be. Naming
    -- the transaction means naming WHICH transaction, and "each buy" on the SELL
    -- ORDERS tab would be a plain lie about what the control does.
    local sell = self:isSell()
    local function countSlot()
        return { kind = "number", min = 1, max = self:countCap(),
                 label = sell and l10n("ar_bs_countSell", "How many animals each sale:")
                              or  l10n("ar_bs_count", "How many animals each buy:") }
    end
    local function everySlot()
        return { kind = "number", min = 1, max = AnimalBuySchedule.MAX_EVERY,
                 label = sell and l10n("ar_bs_everySell", "Months between sales:")
                              or  l10n("ar_bs_every", "Months between buys:") }
    end
    ---HOW MANY TIMES IT RUNS, not how long it lasts. See `forMonths()` for why the
    -- record still keeps months and this does not.
    --
    -- IT GOES INERT UNDER THE FOREVER SWITCH rather than merely being ignored: a
    -- live field beside a setting that overrides it is a control that looks like it
    -- should work. The typed number is KEPT, so switching Forever off gives it back
    -- instead of making the player enter it again.
    local function runsSlot()
        return { kind = "number", min = 1, max = AnimalBuySchedule.MAX_RUNS,
                 inert = self.foreverOn == true,
                 inertText = l10n("ar_bs_forever", "Forever"),
                 label = sell and l10n("ar_bs_forSell", "Number of Sales")
                              or  l10n("ar_bs_for", "Number of Buys") }
    end
    ---KEEP GOING FOREVER. A STATE, so a ring rather than a number -- 26.1 built
    -- FOREVER as a sentinel precisely because it is not a quantity, and giving one
    -- value of the count field that meaning would have put two kinds of answer in
    -- one box.
    local function foreverSlot()
        return { kind = "toggle",
                 label = sell and l10n("ar_bs_foreverSell", "Keep selling forever:")
                              or  l10n("ar_bs_foreverBuy", "Keep buying forever:"),
                 texts = { l10n("ar_pol_off", "Off"), l10n("ar_pol_on", "On") },
                 index = self.foreverOn and 2 or 1,
                 set   = function(st) self.foreverOn = (st == 2) end }
    end
    ---0 IS A LEGAL ANSWER HERE and means the next run, which is why this slot alone
    -- has a minimum of 0. It is exactly the case the control was written for: 0 is
    -- a real value, not an absence (DR 5.46c).
    local function startSlot()
        return { kind = "number", min = 0, max = AnimalBuySchedule.MAX_START,
                 label = sell and l10n("ar_bs_startInSell", "Months before selling starts:")
                              or  l10n("ar_bs_startIn", "Months before buying starts:") }
    end

    -- BOTH ORDER TABS HAVE THE SAME FIVE SLOTS IN THE SAME PLACES, differing only
    -- in wording -- so one table serves, and a slot cannot mean one thing on the
    -- buy tab and another on the sell tab (which is what `num()` assumes).
    if self.mode == MODE_BUY or self.mode == MODE_SELL_ORDER then
        if i == AnimalBuyScheduleDialog.SLOT_COUNT   then return countSlot() end
        if i == AnimalBuyScheduleDialog.SLOT_EVERY   then return everySlot() end
        if i == AnimalBuyScheduleDialog.SLOT_RUNS    then return runsSlot() end
        if i == AnimalBuyScheduleDialog.SLOT_FOREVER then return foreverSlot() end
        if i == AnimalBuyScheduleDialog.SLOT_START   then return startSlot() end
        return nil
    end

    -- SELL RULES: one slot per rule, editing the SELECTED ORDER's set. With no
    -- order selected there is nothing to edit, and the slots hide rather than
    -- stand against nothing.
    local order = self:rowA()
    local f = AnimalSellPolicy.FIELDS[i]
    if f == nil or order == nil then return nil end
    order.cfg = order.cfg or {}
    -- AN ORDINARY RING, exactly like COUNT or EVERY. It used to be handed a single
    -- text and any click was turned into one FORWARD step here, so the left arrow
    -- went forward too and the ring never wrapped (reported 2026-09-01). Handed the
    -- whole ring, the control does left, right and wrap itself.
    local values, texts, index = AnimalSellPolicy.options(order.cfg, f, l10n)
    return {
        label = l10n(f.l10n, f.key),
        texts = texts,
        index = index,
        set   = function(sel) if values[sel] ~= nil then order.cfg[f.key] = values[sel] end end,
    }
end

-- `policyValueText` MOVED to AnimalSellPolicy.valueText with the rest of the rule
-- metadata. Verified callerless here before deleting rather than assumed (6.27).

-- ---------------------------------------------------------------------------
---THE MODE TABS. Three peers, so tabs rather than a selector: a selector asks
-- the player to step THROUGH modes to reach one, which is the wrong gesture for
-- a set of three screens that have nothing to do with each other.
---SELL RULES IS HIDDEN (author, 2026-09-10): *"for now disable all the sell
-- rules and hide that tab. It should just be sell orders without rules ... later
-- on we'll look at auto sell as a separate feature."*
--
-- ONE FLAG, AND THE TAB'S CODE IS LEFT INTACT. Deleting the mode would take the
-- rules editor, its layout branches and its harness coverage with it, and the
-- feature is deferred rather than abandoned -- so this hides the door and keeps
-- the room. Flip it to true and the tab returns exactly as it was.
--
-- HIDING THE LABEL IS ENOUGH TO MAKE IT UNREACHABLE, not merely invisible:
-- `selectMode` resolves through `AnimalTabs.pick`, which returns nil for an index
-- with no label, so mode 3 cannot be selected by a tab, a key, or a stale index.
AnimalBuyScheduleDialog.SELL_RULES_ENABLED = false

function AnimalBuyScheduleDialog:modeLabels()
    local t = { l10n("ar_bs_modeBuy",  "BUY ORDERS"),
                l10n("ar_bs_modeSell", "SELL ORDERS") }
    if AnimalBuyScheduleDialog.SELL_RULES_ENABLED then
        t[#t + 1] = l10n("ar_bs_modeRules", "SELL RULES")
    end
    return t
end

---The mode, never past the last VISIBLE tab. A dialog is reused between opens
-- (DR 5.77a), so a mode set while the tab existed would otherwise survive being
-- hidden and strand the player on a screen with no way back to it.
function AnimalBuyScheduleDialog:modeSafe()
    local n = #self:modeLabels()
    if type(self.mode) ~= "number" or self.mode < 1 or self.mode > n then return 1 end
    return self.mode
end

function AnimalBuyScheduleDialog:initSelectors()
    self.mode = self:modeSafe()
    if AnimalTabs ~= nil then
        AnimalTabs.render(self, self:modeLabels(), self.mode)
    end
    local names = {}
    for _, b in ipairs(self.barns) do names[#names + 1] = tostring(b.name or "?") end
    if #names == 0 then names = { l10n("ar_bs_noBarn", "no barn") } end
    if self.barnOption ~= nil and self.barnOption.setTexts ~= nil then
        self.barnOption:setTexts(names)
        if self.barnOption.setState ~= nil then
            self.barnOption:setState(math.min(self.barnIndex, #names))
        end
    end
    -- HIDDEN, not disabled, when there is nothing to choose
    setVisible(self.barnBox, not self.lockBarn and #self.barns > 1)
end

function AnimalBuyScheduleDialog:applySlots()
    for i = 1, AnimalBuyScheduleDialog.SLOTS do
        local spec = self:slotSpec(i)
        local kind = (spec ~= nil) and (spec.kind or "ring") or nil
        setVisible(self["lblBox" .. i], spec ~= nil)
        -- THE THREE CONTROLS ARE MUTUALLY EXCLUSIVE and all three are set every
        -- pass. A slot that is a typed field in one mode and a ring in another must
        -- not leave either of the others standing behind it.
        setVisible(self["optBox" .. i], kind == "ring")
        setVisible(self["numBox" .. i], kind == "number")
        setVisible(self["togBox" .. i], kind == "toggle")
        if spec ~= nil then
            setText(self["lbl" .. i], spec.label)
            if kind == "number" then self:applyNumSlot(i, spec)
            elseif kind == "toggle" then
                local t = self["tog" .. i]
                if t ~= nil then
                    if t.setTexts ~= nil and spec.texts ~= nil then t:setTexts(spec.texts) end
                    -- setState WITHOUT forceEvent, so painting the switch cannot
                    -- fire the handler that painted it.
                    if t.setState ~= nil then pcall(t.setState, t, spec.index or 1) end
                end
            else
                local o = self["opt" .. i]
                if o ~= nil and o.setTexts ~= nil and spec.texts ~= nil then
                    o:setTexts(spec.texts)
                    if o.setState ~= nil then
                        pcall(o.setState, o, math.max(1, math.min(spec.index or 1, #spec.texts)))
                    end
                end
            end
        end
    end
end

---Point one picker at what its slot currently means.
--
-- THE BOUNDS ARE RE-READ EVERY PASS because they are not constants: the count's
-- cap is the SELECTED BARN's capacity, and the barn changes under the control.
-- Re-tested only when a bound actually MOVED -- this runs on every refresh, and
-- re-testing an unchanged range would fire onChanged on every keystroke.
--
-- A NUMBER MADE IMPOSSIBLE BY A NEW BOUND IS REFUSED OUT LOUD, with the message
-- naming the new range, rather than clamped to a figure the player never asked
-- for. That is `set()`'s own rule applied to a moving bound.
function AnimalBuyScheduleDialog:applyNumSlot(i, spec)
    local pk = self:picker(i)
    if pk == nil then return end
    local lo, hi = spec.min or 1, spec.max or 100
    pk.prompt     = l10n("ar_bs_numPrompt", "Enter number...")
    pk.outOfRange = string.format(
        l10n("ar_bs_numRange", "Number out of range (%d-%d)..."), lo, hi)
    if pk.min ~= lo or pk.max ~= hi then
        pk.min, pk.max = lo, hi
        if pk.value ~= nil and not TextPicker.inRange(pk.value, lo, hi) then pk:setBad() end
    end
    pk:setInert(spec.inert, spec.inertText)
    pk:render()
end

-- ---------------------------------------------------------------------------
function AnimalBuyScheduleDialog:rebuild()
    local b, p, uid = self:barn()
    self.rowsA, self.rowsB, self.loadError, self.plan = {}, {}, nil, nil

    if p ~= nil then
        if self.mode == MODE_BUY then
            local cat, err = AnimalBuySchedule.catalogue(p)
            self.rowsA, self.loadError = cat or {}, err
            if uid ~= nil then self.rowsB = AnimalBuySchedule.forBarn(uid) end
        else
            -- BOTH SELL MODES READ THE HERD THROUGH THE SAME `assess` THE RULES USE.
            -- Reading the clusters again here would be a second opinion about one
            -- herd (18.16).
            local okA, a = pcall(AnimalSellRules.assess, p)
            local groups = (okA and a ~= nil) and a.clusters or {}
            local orders = uid ~= nil and AnimalSellSchedule.forBarn(uid) or {}
            if self.mode == MODE_SELL_ORDER then
                -- BY BREED, NOT BY CLUSTER (28.7). A cluster is a (breed, age,
                -- health) triple that merges and splits between one month and the
                -- next, and its AGE and WORTH EACH say nothing a player can act on
                -- -- a breed spans many of both. What is actionable is how many of
                -- each BREED there are, and what a slot holding one earns most at.
                self.rowsA = (okA and a ~= nil) and AnimalSellRules.slotUseByType(a) or {}
                self.rowsB = orders
            else
                -- SELL RULES LISTS THE ORDERS, because a rule set belongs to one.
                -- It used to list the PLAN, which is why it read BLANK whenever the
                -- rules happened to want nothing at that moment -- reported
                -- 2026-09-01 as "the list is blank... it appeared when I first
                -- created the rule and disappeared when I switched tabs".
                self.rowsA = orders
            end
        end
    end
    -- ONE BREED, when the dialog was opened from a breed's own row. Applied BEFORE
    -- the indices are clamped, so a selection can never point past a list that
    -- just got shorter.
    self.breedNote = nil
    if self.breed ~= nil then self:filterToBreed() end
    self.aIndex = math.max(1, math.min(self.aIndex, math.max(1, #self.rowsA)))
    self.bIndex = math.max(1, math.min(self.bIndex, math.max(1, #self.rowsB)))
    -- PRICED AFTER THE INDEX SETTLES, so the money describes the order the player
    -- can actually see highlighted.
    self:reprice()
    self:refresh()
end

---NARROW BOTH LISTS TO self.breed.
--
-- BUY ORDERS: the dealer rows of that breed, and the standing buy orders for it --
-- matched by subtype where the order stored one, else by the TITLE of a dealer row
-- that matched, which is the order's own key (23.2).
--
-- SELL ORDERS: the breed's own row. The standing sell orders are NOT narrowed: an
-- order is not breed-scoped (AnimalSellSchedule.validate), so hiding some would
-- hide orders that do act on this breed.
--
-- IT REFUSES TO EMPTY THE CATALOGUE. If the dealer offers rows and none can be
-- tied to the breed, the whole catalogue stays and the note line says why: a list
-- silently emptied by an identification failure reads as "the dealer sells no
-- pigs", which is a different and wrong statement.
function AnimalBuyScheduleDialog:filterToBreed()
    local breed = self.breed
    if breed == nil then return end
    if self.mode == MODE_BUY then
        if self._breedEv == nil or self._breedEv.name ~= breed then
            self._breedEv = AnimalBuySchedule.breedEvidence(breed)
        end
        local keep, titles = {}, {}
        for _, c in ipairs(self.rowsA) do
            if AnimalBuySchedule.rowIsBreed(c, self._breedEv) then
                keep[#keep + 1] = c
                if c.title ~= nil then titles[c.title] = true end
            end
        end
        if #keep == 0 and #self.rowsA > 0 then
            self.breedNote = l10n("ar_bs_breedUnmatched",
                "Could not tell which dealer animals are this breed, so all are shown.")
            return
        end
        self.rowsA = keep
        local orders = {}
        for _, s in ipairs(self.rowsB) do
            if s.subType == breed or (s.subType == nil and s.title ~= nil and titles[s.title]) then
                orders[#orders + 1] = s
            end
        end
        self.rowsB = orders
    elseif self.mode == MODE_SELL_ORDER then
        local keep = {}
        for _, r in ipairs(self.rowsA) do
            if r.name == breed then keep[#keep + 1] = r end
        end
        self.rowsA = keep
    end
end

---WHAT THE SELECTED ORDER WOULD SELL RIGHT NOW.
--
-- IT IS ITS OWN FUNCTION BECAUSE THREE THINGS CHANGE THE ANSWER and only one of
-- them used to recompute it: opening the tab did (through `rebuild`), while
-- CHANGING A RULE and SELECTING ANOTHER ORDER both called `refresh` alone. So the
-- figure was frozen at whatever it was when the tab opened -- reported 2026-09-01
-- as *"I have tried all combinations of the settings but Animals is always at zero
-- and I cannot run the sell now cycle"*. Every one of those three now comes
-- through here.
function AnimalBuyScheduleDialog:reprice()
    self.plan = nil
    if self.mode ~= MODE_SELL_RULES then return end
    local _, p = self:barn()
    local sel = self:rowA()
    if p ~= nil and sel ~= nil then self.plan = AnimalSellPolicy.planFor(p, sel.cfg) end
end

function AnimalBuyScheduleDialog:rowA() return self.rowsA[self.aIndex] end
function AnimalBuyScheduleDialog:rowB() return self.rowsB[self.bIndex] end

---The order the SELL ORDERS controls currently describe. Used for BOTH the money
-- preview and Add, so the figure quoted and the thing created cannot differ.
function AnimalBuyScheduleDialog:draftSellOrder()
    local b, _, uid = self:barn()
    if uid == nil then return nil end
    return AnimalSellSchedule.validate({
        uid = uid, barnName = b ~= nil and b.name or "?",
        -- NIL UNTIL A NUMBER IS TYPED, and `validate` refuses it -- which is what
        -- disables Add and puts the money block on dashes, with no separate
        -- "has the player chosen yet" flag to keep in step.
        count = self:count(),
        everyMonths = self:every(),
        forMonths   = self:forMonths(),
        startIn     = self:start(),
        startMonth = 0,
    })
end

function AnimalBuyScheduleDialog:refresh()
    self._refreshing = true
    local b = self:barn()

    setText(self.dialogTextElement,
            b ~= nil and tostring(b.name or "") or l10n("ar_bs_noBarn", "no barn"))
    -- REDRAWN EVERY REFRESH, not only at open: the plate is a separate element
    -- from the button, so a mode change that did not repaint would leave the
    -- green block on the tab the player just left.
    if AnimalTabs ~= nil then AnimalTabs.render(self, self:modeLabels(), self.mode) end
    self:applyHeaders()
    self:applySlots()

    for _, l in ipairs({ self.catList, self.schedList }) do
        if l ~= nil and l.reloadData ~= nil then pcall(l.reloadData, l) end
    end
    if self.catList ~= nil and #self.rowsA > 0 then
        pcall(self.catList.setSelectedItem, self.catList, 1, self.aIndex, true)
    end
    if self.schedList ~= nil and #self.rowsB > 0 then
        pcall(self.schedList.setSelectedItem, self.schedList, 1, self.bIndex, true)
    end

    self:applyMoney()
    setText(self.noteText, self:note())
    self:applyButtons()
    self._refreshing = false
end

function AnimalBuyScheduleDialog:applyHeaders()
    local buy   = (self.mode == MODE_BUY)
    local rules = (self.mode == MODE_SELL_RULES)
    setText(self.hOrder, rules and l10n("ar_bs_hdrRules", "THE RULES")
                                or l10n("ar_bs_hdrOrder", "THE ORDER"))
    if buy then
        setText(self.hA1, l10n("ar_bs_colAnimal", "ANIMAL"))
        setText(self.hA2, l10n("ar_bs_colAge", "AGE"))
        setText(self.hA3, l10n("ar_bs_colPrice", "EACH"))
        setText(self.hA4, l10n("ar_bs_colRow", "CATALOGUE"))
    elseif self.mode == MODE_SELL_ORDER then
        setText(self.hA1, l10n("ar_bs_colBreed", "BREED"))
        setText(self.hA2, l10n("ar_bs_colHead", "ANIMALS"))
        setText(self.hA3, l10n("ar_bs_colEarnsAs", "EARNS MOST AS"))
        setText(self.hA4, l10n("ar_bs_colValueTotal", "TOTAL VALUE"))
    else
        -- the ORDERS, so the player picks which one's rules they are editing. Two
        -- columns only: the wide cell covers everything past the title, because
        -- the full rule set is what this tab is about.
        setText(self.hA1, l10n("ar_bs_colWhatSell", "STANDING SALE"))
        setText(self.hA2, l10n("ar_bs_colRules", "RULES"))
        setText(self.hA3, "")
        setText(self.hA4, "")
    end
    setText(self.hB1, buy and l10n("ar_bs_colWhat", "STANDING ORDER")
                           or l10n("ar_bs_colWhatSell", "STANDING SALE"))
    setText(self.hB2, l10n("ar_bs_colEvery", "EVERY"))
    setText(self.hB3, l10n("ar_bs_colProgress", "DONE"))
    -- SELL ORDERS SHOW WHEN THEY NEXT SELL, not a rule set (author, 2026-09-14): an
    -- order no longer carries rules, so the column that listed them is gone.
    setText(self.hB4, buy and l10n("ar_bs_colNext", "NEXT") or l10n("ar_bs_colNextSale", "NEXT SALE"))
    -- A POLICY IS NOT A LIST, so the lower table is absent in that mode rather
    -- than merely empty.
    setVisible(self.hdrB, not rules)
    setVisible(self.listB, not rules)
    -- THE SELECTED ORDER STAYS HIGHLIGHTED WHILE A RULE HAS FOCUS. Reported
    -- 2026-09-01: moving to a selector dropped the list's highlight, so the player
    -- lost sight of which order they were editing. `selectedWithoutFocus` defaults
    -- TRUE and was set false so two visible lists could not both claim a highlight
    -- (DR 6.29) -- but in RULES mode there is only ONE list, so there is nothing to
    -- be ambiguous with and the highlight should persist.
    --
    -- AND ON EVERY TAB (reported 2026-09-14): picking a breed and then clicking into
    -- one of the order fields un-highlighted the breed, because a list with this flag
    -- off CLEARS its selection on focus leave (SmoothListElement:onFocusLeave). The
    -- two lists here are not rivals for one button, which is what DR 6.29 guarded:
    -- the upper selection is what the order is being set up for and the lower one is
    -- what Pause and Remove act on -- so both stay visible.
    if self.catList ~= nil then self.catList.selectedWithoutFocus = true end
    if self.schedList ~= nil then self.schedList.selectedWithoutFocus = true end
end

-- WHY A CODE MAP AND NOT A BUILT KEY: check_l10n_animal.py reads QUOTED literals,
-- so a key assembled by concatenation is invisible to it and a missing one renders
-- as blank with nothing in the log. The same rule REASON_KEY and HELP_KEY follow.
local SLOT_GAP_KEY = {
    empty      = "ar_bs_slotGapEmpty",
    margin     = "ar_bs_slotGapMargin",
    birthValue = "ar_bs_slotGapBirth",
    cycle      = "ar_bs_slotGapCycle",
}

---WHAT THIS BARN'S SLOTS EARN MOST AT -- the engine's own answer, shown at last.
--
-- `AnimalSellRules.plan` has computed `plan.slot` on every run since 17, and it
-- surfaced ONLY as an advisory note in the single case where it said NURSERY and
-- `sellCalves` was off. The rest of the time the conclusion was worked out and
-- thrown away -- including every case where the player would most want to check it
-- against their own intention for the barn (2026-09-02).
--
-- IT IS DIAGNOSTIC BEFORE IT IS A FEATURE. Whether a purpose control is needed at
-- all turns on whether this already agrees with the player on their real barns, so
-- the cheapest next step was to show what it already concludes rather than to
-- build a second model beside it.
---Returns word, sentence. Either may be nil.
---WHERE A BREED'S EARNINGS ACTUALLY COME FROM.
--
-- The point of showing the TERMS rather than the conclusion (28.8): the model
-- prices raw fill types and cannot see what a farm does downstream, so a figure
-- that is arithmetically right can still be wrong for this player -- manure sold
-- is worth a fraction of manure digested. "Earns 940/mo" gives them nothing to
-- argue with; "milk 900, manure 40" names the term to override.
--
-- BIGGEST CONTRIBUTOR FIRST and capped, because the sentence shares a two-line
-- element with whatever else the dialog needs to say, and the tail of a list of
-- products is never the one being questioned.
function AnimalBuyScheduleDialog:breedTerms(r)
    if r == nil then return nil end
    if r.earns == nil or r.earnsPerAnimal == nil then
        -- NOT A BLANK: no priced output is the finding itself, and it is what a pig
        -- or horse pen is expected to report.
        return string.format(l10n("ar_bs_breedNoEarn",
            "%s: %d head. No priced monthly output, so a slot here earns only what the animal is worth."),
            tostring(r.name), r.count or 0)
    end
    local parts = {}
    for ft, v in pairs(r.earns) do parts[#parts + 1] = { ft = ft, v = v } end
    table.sort(parts, function(x, y)
        if x.v ~= y.v then return x.v > y.v end
        return tostring(x.ft) < tostring(y.ft)
    end)
    local bits, m = {}, g_fillTypeManager
    for i, e in ipairs(parts) do
        if i > 4 then break end
        local title = nil
        if m ~= nil and m.getFillTypeTitleByIndex ~= nil and type(e.ft) == "number" then
            local ok, v = pcall(m.getFillTypeTitleByIndex, m, e.ft)
            if ok and type(v) == "string" and v ~= "" then title = v end
        end
        bits[#bits + 1] = string.format("%s %s", title or tostring(e.ft), money(e.v))
    end
    return string.format(l10n("ar_bs_breedTerms",
        "%s: %d head, each earning %s/mo -- %s. A calf is worth %s."),
        tostring(r.name), r.count or 0, money(r.earnsPerAnimal),
        table.concat(bits, ", "),
        r.birthValue ~= nil and money(r.birthValue) or l10n("ar_bs_unpriced", "not priced"))
end

function AnimalBuyScheduleDialog:slotVerdict()
    local plan = self.plan
    if plan == nil then return nil, nil end
    local slot = plan.slot
    if slot ~= nil and slot.use ~= nil then
        local nursery = (slot.use == "NURSERY")
        local word = nursery and l10n("ar_bs_useNursery", "Nursery")
                             or  l10n("ar_bs_useAdult", "Producers")
        -- The two figures always read WINNER first, then the alternative, so the
        -- sentence cannot be misread as being about the loser.
        local a, b = slot.adult or 0, slot.nursery or 0
        if nursery then a, b = b, a end
        local key = nursery and "ar_bs_slotNursery" or "ar_bs_slotAdult"
        local dflt = nursery
            and "This barn earns most as a NURSERY: %s/mo, against %s/mo from producers."
            or  "This barn earns most from PRODUCERS: %s/mo, against %s/mo run as a nursery."
        return word, string.format(l10n(key, dflt), money(a), money(b))
    end

    -- NO VERDICT IS ITSELF THE FINDING, so it names its reason rather than showing
    -- a dash. A barn with no priced monthly output -- a pig or horse pen -- is the
    -- case predicted to land here.
    local gap = (AnimalSellRules ~= nil and AnimalSellRules.slotUseGap ~= nil)
                and AnimalSellRules.slotUseGap(plan.assess) or nil
    local why = (gap ~= nil) and l10n(SLOT_GAP_KEY[gap.code] or "", "") or ""
    if why == "" then why = tostring(gap ~= nil and gap.code or "?") end
    return nil, string.format(
        l10n("ar_bs_slotNone", "No producer / nursery verdict for this barn: %s"), why)
end

function AnimalBuyScheduleDialog:applyMoney()
    if self.mode == MODE_BUY then
        local row  = self:rowA()
        local runs = self:num(AnimalBuyScheduleDialog.SLOT_RUNS)
        if self.foreverOn then runs = math.huge end
        -- WRITTEN AS if/else, NOT `a and b or c`. This file has already been bitten
        -- by that collapse once (24.11, on a boolean); here the guard is that
        -- `count()` is legitimately nil until the player types, and a nil in the
        -- multiplication would throw inside a GUI populate.
        local n = self:count()
        local each = nil
        if row ~= nil and row.each ~= nil and n ~= nil then
            each = math.abs(row.each) * n
        end
        local open = (runs == math.huge)
        -- THE PURCHASES ROW IS GONE: the player now types the run count directly, so
        -- reporting it back is quoting their own input at them. Its row shows the
        -- one thing typing a COUNT takes away -- HOW LONG that many runs covers --
        -- which is exactly what the field used to ask for before 27.9 turned it
        -- round.
        self:applySpanRow()
        setText(self.lblEach,  l10n("ar_bs_lblEach", "Each time"))
        setText(self.valEach,  each ~= nil and money(each) or "-")
        setText(self.lblTotal, l10n("ar_bs_lblTotal", "Total commitment"))
        -- AN UNBOUNDED ORDER HAS NO TOTAL, and inventing one would be the single
        -- most misleading figure on the dialog.
        setText(self.valTotal,
                (each ~= nil and runs ~= nil and not open) and money(each * runs) or "-")
        return
    end
    if self.mode == MODE_SELL_ORDER then
        local _, p = self:barn()
        local s = self:draftSellOrder()
        local plan = (p ~= nil and s ~= nil) and AnimalSellSchedule.buildPlan(p, s) or nil
        local runs = s ~= nil and AnimalSellSchedule.totalRuns(s) or nil
        local each = plan ~= nil and plan.revenue or nil
        local open = (runs == math.huge)
        self:applySpanRow()
        setText(self.lblEach,  l10n("ar_bs_lblEach", "Each time"))
        setText(self.valEach,  each ~= nil and money(each) or "-")
        setText(self.lblTotal, l10n("ar_bs_lblExpected", "Total expected"))
        -- `runs` is tested as well as `each` although a nil `runs` implies a nil
        -- `each` today: the two now come from different places and a guard that
        -- only holds by implication is one edit away from a nil arithmetic throw
        -- inside a GUI populate, which shows as an empty page (5.44 / 5.57).
        setText(self.valTotal,
                (each ~= nil and runs ~= nil and not open) and money(each * runs) or "-")
        return
    end
    -- THE SELECTED ORDER'S NEXT RUN, capped at its own count -- the same figure
    -- "Sell now" would realise, so the button and the number cannot disagree.
    local order = self:rowA()
    local plan = self.plan
    if plan ~= nil and order ~= nil then plan = AnimalSellPolicy.capPlan(plan, order.count) end
    setText(self.lblRuns,  l10n("ar_bs_lblAnimals", "Animals"))
    setText(self.valRuns,  plan ~= nil and tostring(plan.total or 0) or "-")
    -- THE ROW WAS BLANK IN THIS MODE, which is what made it the right home for a
    -- figure that had nowhere to go.
    local word = self:slotVerdict()
    setText(self.lblEach,  l10n("ar_bs_lblUse", "Earns most as"))
    setText(self.valEach,  word or "-")
    setText(self.lblTotal, l10n("ar_bs_lblNow", "Revenue now"))
    setText(self.valTotal, plan ~= nil and money(plan.revenue or 0) or "-")
end

---HOW LONG THE ORDER COVERS, in the row the Purchases figure used to have.
--
-- Typing a RUN COUNT rather than a duration takes one fact away from the player,
-- and this is it: "12 buys every 3 months" is three years, and nothing else on the
-- screen would say so. It is the exact inverse of the field before 27.9, so the
-- information is not lost, only moved to where it is derived rather than entered.
--
-- A DASH UNTIL BOTH HALVES ARE ANSWERED. A span computed from a missing cadence
-- would be a confident wrong number, which is worse than no number (DR 5.46c).
function AnimalBuyScheduleDialog:applySpanRow()
    setText(self.lblRuns, l10n("ar_bs_lblSpan", "Runs over"))
    if self.foreverOn then
        setText(self.valRuns, l10n("ar_bs_ongoing", "ongoing"))
        return
    end
    local m = self:forMonths()
    setText(self.valRuns, m ~= nil and months(m) or "-")
end

---EVERY FIELD ANSWERED. `startIn` is deliberately NOT required: an empty one means
-- 0, which is "at the next run" and is what every order did before that field
-- existed, so leaving it blank is a real answer rather than an omission.
function AnimalBuyScheduleDialog:orderReady()
    return self:count() ~= nil and self:every() ~= nil and self:forMonths() ~= nil
end

function AnimalBuyScheduleDialog:applyButtons()
    local rules = (self.mode == MODE_SELL_RULES)
    local _, _, uid = self:barn()
    local can = self:canAct()

    -- PAUSE AND REMOVE ARE ORDER ACTIONS, so they live on the ORDER screens and
    -- nowhere else (author, 2026-09-01). SELL RULES is for editing one order's
    -- rules; its footer is Sell now and Close.
    setVisible(self.addButton, not rules)
    setVisible(self.removeButton, not rules)
    setVisible(self.pauseButton, not rules)
    setText(self.pauseButton, l10n("ar_bs_btnPause", "Pause / resume"))

    local target = self:rowB()
    -- BOTH ORDER MODES NOW NEED A COUNT before Add means anything. BUY tests it
    -- explicitly; SELL_ORDER gets it for free because `draftSellOrder` runs the
    -- schedule's own validate, which refuses a nil count. Two routes to one rule,
    -- and the sell one is the schedule's rule rather than a copy of it.
    local addOk  = can and ((self.mode == MODE_BUY and self:rowA() ~= nil and self:orderReady())
                            or (self.mode == MODE_SELL_ORDER and self:draftSellOrder() ~= nil))
    for el, on in pairs({ [self.addButton] = addOk, [self.removeButton] = target ~= nil,
                          [self.pauseButton] = target ~= nil }) do
        if el ~= nil and el.setDisabled ~= nil then pcall(el.setDisabled, el, not on) end
    end
end

---Whether anything can be committed here at all, and why not.
function AnimalBuyScheduleDialog:canAct()
    if AnimalTrade ~= nil and AnimalTrade.canTrade ~= nil then
        local can = AnimalTrade.canTrade()
        if not can then
            return false, l10n("ar_bs_client", "Only the host can set up automatic trading.")
        end
    end
    if self.mode == MODE_BUY and AnimalBuySchedule.dealerReplaced() then
        return false, l10n("ar_bs_standDown",
            "Automatic buying stands down while Realistic Livestock is running.")
    end
    return true
end

---THE NOTE LINE, plus the slot verdict on the rules tab.
--
-- APPENDED RATHER THAN COMPETING FOR THE LINE: every branch of `noteBase` returns
-- something the player needs more urgently than this, and the element carries two
-- lines of 1096px, so a second sentence fits beside any of them.
function AnimalBuyScheduleDialog:note()
    local base = self:noteBase()
    -- THE SELECTED BREED'S TERMS. This is the first thing that has ever read the
    -- upper list's selection on this tab -- it was decorative until now -- so
    -- picking a row finally does something, and what it does is explain the
    -- number beside it.
    if self.mode == MODE_SELL_ORDER then
        local terms = self:breedTerms(self:rowA())
        if terms == nil then return base end
        if base == nil or base == "" then return terms end
        return terms .. "  " .. base
    end
    if self.mode ~= MODE_SELL_RULES then return base end
    local _, sentence = self:slotVerdict()
    if sentence == nil then return base end
    if base == nil or base == "" then return sentence end
    return base .. "  " .. sentence
end

function AnimalBuyScheduleDialog:noteBase()
    if self.notice ~= nil then return self.notice end
    local _, why = self:canAct()
    if why ~= nil then return why end
    if self.breedNote ~= nil then return self.breedNote end

    if self.mode == MODE_BUY then
        if #self.rowsA == 0 then
            return l10n("ar_bs_empty", "The dealer is offering nothing for this barn.")
                .. (self.loadError ~= nil and ("  (" .. tostring(self.loadError) .. ")") or "")
        end
        return string.format(l10n("ar_bs_runsAt",
            "Runs at %02d:00, or during a sleep that passes it."), AnimalBuySchedule.RUN_HOUR)
    end

    -- BOTH SELL MODES SAY WHEN AN ORDER RUNS, the same way the buy side does: a sell
    -- order sells on its schedule (AnimalSellSchedule.runDue, 2026-09-14).
    local head = l10n("ar_bs_sellRunsAt",
        "Sells within the hour once due - set it for the month before births so they have room.")

    if self.mode == MODE_SELL_RULES then
        if #self.rowsA == 0 then
            return l10n("ar_bs_noOrders",
                "No standing sales on this barn yet - add one on the SELL ORDERS tab.")
        end
        if self:rowA() == nil then
            return l10n("ar_bs_pickOrder", "Select a standing sale to set its rules.")
        end
        local plan = self.plan
        if plan == nil then return head end
        if #(plan.lines or {}) == 0 then
            -- SAY WHY. The engine already worked it out and put it in the notes;
            -- reporting only "nothing to sell" was what made this unfixable from
            -- the screen (reported 2026-09-01, and every combination of the
            -- switches looked identical because none of them said anything).
            local why = nil
            for _, n in ipairs(plan.notes or {}) do
                local k = NOTE_KEY[n.kind]
                if k ~= nil and why == nil then why = l10n(k, tostring(n.kind)) end
            end
            return l10n("ar_bs_planNothing",
                "These rules would sell nothing on this barn right now.")
                .. (why ~= nil and ("  " .. why) or "") .. "  " .. head
        end
        local by = AnimalSellRules.summarise(plan)
        local bits = {}
        for reason, e in pairs(by) do
            bits[#bits + 1] = string.format("%d %s", e.count,
                              l10n(REASON_KEY[reason] or "", reason))
        end
        table.sort(bits)
        return table.concat(bits, ", ") .. ".  " .. head
    end

    local _, p = self:barn()
    local s = self:draftSellOrder()
    if p ~= nil and s ~= nil then
        local plan, why2 = AnimalSellSchedule.buildPlan(p, s)
        if plan == nil or why2 ~= nil then return tostring(why2) .. ".  " .. head end
    end
    return head
end

-- ---------------------------------------------------------------------------
-- THE LIST DELEGATE. Every method branches on `list` (DR 5.77).
-- ---------------------------------------------------------------------------
function AnimalBuyScheduleDialog:getNumberOfSections() return 1 end

function AnimalBuyScheduleDialog:getNumberOfItemsInSection(list)
    if list == self.schedList then return #self.rowsB end
    return #self.rowsA
end

function AnimalBuyScheduleDialog:populateCellForItemInSection(list, section, index, cell)
    -- ALL FOUR COLOURS, and ACTIVELY on every path. Cells are recycled by
    -- SmoothList, so a row that does not set its colour inherits the last one's --
    -- and TextElement:getColor prefers the selected and focused colours whenever
    -- the row is in those states, so writing only `textColor` is discarded on
    -- whichever row is highlighted (DR 5.77b, 16.6).
    local function tone(e, muted)
        if e == nil or e.setTextColor == nil then return end
        local r, g, b = 1, 1, 1
        if muted then r, g, b = 0.59, 0.61, 0.64 end
        pcall(e.setTextColor, e, r, g, b, 1)
        for _, setter in ipairs({ "setTextSelectedColor", "setTextFocusedColor",
                                  "setTextFocusedSelectedColor" }) do
            if type(e[setter]) == "function" then pcall(e[setter], e, r, g, b, 1) end
        end
    end
    local function set(n, t, muted)
        local e = cell:getAttribute(n)
        if e ~= nil and e.setText ~= nil then e:setText(t or "") end
        tone(e, muted)
    end

    if list == self.schedList then
        local s = self.rowsB[index]
        if s == nil then return end
        -- A PAUSED ORDER READS AS INACTIVE AT A GLANCE: it says so, and the whole
        -- row is muted. The state used to live in the NEXT column, which the rules
        -- summary took over, leaving the Pause button with nothing on screen to
        -- show for itself (reported 2026-09-01).
        local off = (s.enabled == false)
        if self.mode == MODE_BUY then
            set("sWhat", string.format("%d x %s%s", s.count, tostring(s.title),
                off and l10n("ar_bs_pausedTag", "  (paused)") or ""), off)
            set("sProgress", progressText(s.runsDone, AnimalBuySchedule.totalRuns(s), l10n), off)
            set("sNext", self:nextText(s), off)
        else
            -- the order's TITLE already carries the paused marker, so both lists
            -- get it from one place
            set("sWhat", AnimalBuyScheduleDialog.orderTitle(s, l10n), off)
            set("sProgress", progressText(s.runsDone, AnimalSellSchedule.totalRuns(s), l10n), off)
            -- WHEN IT NEXT SELLS, in months -- the same countdown the buy orders show
            -- ("in 3 months", "starts in 2 months", "due now", or why the last run
            -- sold nothing)
            set("sNext", self:nextText(s), off)
        end
        set("sEvery", months(s.everyMonths), off)
        return
    end

    local r = self.rowsA[index]
    if r == nil then return end
    local icon = cell:getAttribute("catIcon")
    if icon ~= nil then
        -- ACTIVELY HIDDEN with no file: SmoothList recycles cells and
        -- setImageFilename on a missing file leaves the PREVIOUS texture standing,
        -- so a row with no picture would wear the last row's (18.17).
        local f = nil
        if self.mode == MODE_SELL_RULES then
            f = nil                       -- an ORDER has no animal to picture
        elseif self.mode == MODE_BUY then
            f = r.row ~= nil and r.row.icon or nil
        elseif AnimalHerdData ~= nil and AnimalHerdData.animalIconFile ~= nil then
            local okI, v = pcall(AnimalHerdData.animalIconFile, r.subTypeIndex, r.age or 0)
            if okI then f = v end
        end
        if f ~= nil and icon.setImageFilename ~= nil then
            icon:setImageFilename(f)
            setVisible(icon, true)
        else
            setVisible(icon, false)
        end
    end

    -- THE WIDE CELL COVERS catAge / catEach / catRowNo, so exactly one of the two
    -- arrangements is visible at a time or the text overlaps.
    local wide = (self.mode == MODE_SELL_RULES)
    for _, n in ipairs({ "catAge", "catEach", "catRowNo" }) do
        local e = cell:getAttribute(n)
        if e ~= nil and e.setVisible ~= nil then e:setVisible(not wide) end
    end
    local wcell = cell:getAttribute("catWide")
    if wcell ~= nil and wcell.setVisible ~= nil then wcell:setVisible(wide) end

    if self.mode == MODE_BUY then
        set("catName",  r.title)
        set("catAge",   r.ageText or "-")
        set("catEach",  r.each ~= nil and money(math.abs(r.each)) or "-")
        set("catRowNo", string.format(l10n("ar_bs_rowNo", "row %d"), r.index or 0))
    elseif self.mode == MODE_SELL_ORDER then
        -- THE CELL NAMES ARE SLOTS, NOT MEANINGS -- four generic text columns the
        -- header names per mode, which is why AGE can carry a headcount here.
        set("catName",  r.name)
        set("catAge",   tostring(r.count or 0))
        if r.use == nil then
            -- NO VERDICT IS A FINDING, not a blank: the reason is on the note line.
            set("catEach", "-", true)
        else
            set("catEach", r.use == "NURSERY" and l10n("ar_bs_useNursery", "Nursery")
                                              or  l10n("ar_bs_useAdult", "Producers"))
        end
        set("catRowNo", r.total ~= nil and money(r.total) or "-")
    else
        -- the ORDERS, with the FULL rule set in the wide cell. It used to use the
        -- short summary in a 138px column, so changing a constraint changed
        -- nothing the player could see on the very list they were editing from
        -- (reported 2026-09-01).
        local off = (r.enabled == false)
        set("catName", AnimalBuyScheduleDialog.orderTitle(r, l10n), off)
        set("catWide", AnimalSellPolicy.summary(r.cfg, l10n, true), off)
    end
end

---AN ORDER'S TITLE. Reported 2026-09-01: two orders both read "Sell 2", because
-- the label was the COUNT and nothing else -- so two orders of the same size were
-- indistinguishable, and none of them said what was being sold.
--
-- The id makes it unique; the animal name says what it draws from. The name is the
-- BARN'S ANIMAL TYPE rather than a breed, because an order is not breed-scoped:
-- its rules pick across the whole herd, so naming one breed would be a lie on any
-- barn holding two.
function AnimalBuyScheduleDialog.orderTitle(s, l10n)
    local t
    if s.animalName ~= nil and s.animalName ~= "" then
        t = string.format(l10n("ar_bs_orderTitle", "#%d  Sell %d %s"),
                          s.id or 0, s.count or 0, s.animalName)
    else
        t = string.format(l10n("ar_bs_orderTitleBare", "#%d  Sell %d"), s.id or 0, s.count or 0)
    end
    -- PAUSED RIDES ON THE TITLE, so both lists say so from one place. It used to
    -- live in the NEXT column, which the rules summary took over -- leaving the
    -- Pause button with nothing on screen to show for itself (reported
    -- 2026-09-01).
    if s.enabled == false then
        t = string.format(l10n("ar_bs_titlePaused", "%s  (paused)"), t)
    end
    return t
end


function AnimalBuyScheduleDialog:nextText(s)
    if not s.enabled then return l10n("ar_bs_paused", "paused") end
    local fin = (self.mode == MODE_BUY) and AnimalBuySchedule.isFinished(s)
                                         or AnimalSellSchedule.isFinished(s)
    if fin then return l10n("ar_bs_done", "done") end
    local month = AnimalBuySchedule.currentMonth()
    -- THE LAST FAILURE OUTRANKS THE COUNTDOWN: a barn that was full at 08:00 is
    -- the one thing the player needs told.
    if s.note ~= nil and s.note ~= "" then return tostring(s.note) end
    if month == nil then return "-" end
    local d = s.nextMonth - month
    if d <= 0 then return l10n("ar_bs_due", "due now") end
    -- BEFORE THE FIRST RUN this is a START DELAY, not a gap between runs, and
    -- saying so is the difference between "it is waiting" and "it is broken".
    if (s.runsDone or 0) == 0 and (s.startIn or 0) > 0 then
        return string.format(l10n("ar_bs_startsIn", "starts in %s"), months(d))
    end
    return string.format(l10n("ar_bs_waiting", "in %s"), months(d))
end

---The selected index for ONE list. The callback ARGUMENT wins where there is one;
-- the element is read only when there is not (20.19) -- onSelectionChanged is
-- raised BEFORE the list's own selectedIndex moves.
function AnimalBuyScheduleDialog:pickIndexFor(list, n, arg)
    if type(arg) == "number" and arg >= 1 and arg <= n then return arg end
    if list ~= nil then
        local si = list.selectedIndex
        if type(si) == "number" and si >= 1 and si <= n then return si end
    end
    return nil
end

function AnimalBuyScheduleDialog:onCatChanged(list, section, index)
    if self._refreshing then return end
    self.aIndex = self:pickIndexFor(self.catList, #self.rowsA, index) or self.aIndex
    self.notice = nil
    self:reprice()
    self:refresh()
end

---RAISED FROM notifyClick, AFTER the selection is applied (DR 6.29) -- which is
-- also what catches a click on an ALREADY selected row, which raises no selection
-- event at all.
function AnimalBuyScheduleDialog:onCatClicked()
    if self._refreshing then return end
    self.aIndex = self:pickIndexFor(self.catList, #self.rowsA) or self.aIndex
    self.notice = nil
    self:reprice()
    self:refresh()
end

function AnimalBuyScheduleDialog:onSchedChanged(list, section, index)
    if self._refreshing then return end
    self.bIndex = self:pickIndexFor(self.schedList, #self.rowsB, index) or self.bIndex
    self:refresh()
end

function AnimalBuyScheduleDialog:onSchedClicked()
    if self._refreshing then return end
    self.bIndex = self:pickIndexFor(self.schedList, #self.rowsB) or self.bIndex
    self:refresh()
end

-- ---------------------------------------------------------------------------
-- CONTROLS
-- ---------------------------------------------------------------------------
local function stateOf(opt, state)
    if type(state) == "number" then return state end
    if opt ~= nil and opt.getState ~= nil then
        local ok, s = pcall(opt.getState, opt)
        if ok then return s end
    end
    return nil
end

function AnimalBuyScheduleDialog:onSlot(i, state)
    if self._refreshing then return end
    local spec = self:slotSpec(i)
    if spec == nil then return end
    -- GUARDED, because `set` is OPTIONAL: a number slot's spec has none, so an
    -- unguarded call here is a nil call inside a GUI callback -- which aborts the
    -- render half way and shows as a screen of blank controls, a symptom nothing
    -- like its cause (5.44 / 5.57). It says so rather than failing silently,
    -- because a slot reaching the wrong handler is a wiring fault worth naming.
    local sel = stateOf(self["opt" .. i], state)
    if sel ~= nil then
        if spec.set == nil then
            print(string.format("[HusbandryRedux] slot %d (%s) has no setter but was clicked as a ring",
                                i, tostring(spec.kind or "ring")))
            return
        end
        spec.set(sel)
    end
    -- WHAT THIS RULE DOES, in words, the moment it is touched. These settings are
    -- not self-explanatory from a two-word label and there is nowhere else on the
    -- dialog to say so.
    self.notice = nil
    if self.mode == MODE_SELL_RULES then
        local f = AnimalSellPolicy.FIELDS[i]
        if f ~= nil then self.notice = l10n(HELP_KEY[f.key] or "", "") end
        self:reprice()
    end
    self:refresh()
end

-- ---------------------------------------------------------------------------
-- THE TEXT PICKER'S FIVE WIRES, GENERATED PER SLOT rather than hand written six
-- times. Every one is a single call into TextPicker, which owns the parse, the
-- range test, the wrap and the prompt -- this dialog holds no number logic at all.
--
-- `Digit` is the ONLY one that must return a value: TextInputElement treats a
-- false from onIsUnicodeAllowed as "reject this character", and Utils.getNoNil
-- makes anything else mean "allow", so a handler that quietly returned nothing
-- would let letters straight in.
-- ---------------------------------------------------------------------------
---AN ON / OFF SWITCH. It has its OWN handler rather than sharing `onSlot`, so the
-- ring path and the switch path cannot be confused for one another -- and so a
-- number slot can never route into a setter that does not exist.
function AnimalBuyScheduleDialog:onToggle(i, state)
    if self._refreshing then return end
    local spec = self:slotSpec(i)
    if spec == nil or spec.set == nil then return end
    local st = state
    if type(st) ~= "number" then
        local t = self["tog" .. i]
        if t ~= nil and t.getState ~= nil then
            local ok, v = pcall(t.getState, t)
            if ok then st = v end
        end
    end
    if type(st) ~= "number" then return end
    spec.set(st)
    self.notice = nil
    self:refresh()
end

---A NUMBER IS COMMITTED BY ENTER, OR BY LEAVING THE FIELD.
--
-- Requested 2026-09-02: *"enter a number and click enter OR enter a number and
-- lose focus"*, after typing into three fields in turn left one of them blank and
-- deaf to the keyboard.
--
-- `enterWhenClickOutside` already commits on a click elsewhere, so the VALUE was
-- never the problem -- the ORDER was. GuiElement:mouseEvent visits children in
-- REVERSE, so clicking DOWN the page reaches the newly clicked field BEFORE the
-- one being left: the new field captures, and only then does the old one release.
--
-- THAT ORDER MATTERS BECAUSE THE CAPTURE FLAG IS NOT PER FIELD.
-- `TextInputElement.inputContextActive` is a single STATIC shared by every text
-- input in the game, and `setCaptureInput` reverts the whole input context when a
-- field releases while it is set. The base game knows: its own comments name
-- "another text element may previously have been active when this one has been
-- activated by click" and "avoid double reverts when switching from one text input
-- to another". Its guard works when the old field releases first and not when it
-- releases second -- which is precisely the direction a player fills a form in.
--
-- SO THE RELEASE IS MOVED IN FRONT OF THE CLICK. On mouse DOWN, before the event
-- reaches any element, any field holding the keyboard that the cursor is not over
-- is committed and released. The clicked field then captures with nothing stale
-- left to revert it, and the ordering stops mattering at all.
--
-- IT DOES NOT DEPEND ON THAT DIAGNOSIS BEING RIGHT. Whatever the cause, "commit
-- and release the field being left, before anything else happens" is the behaviour
-- that was asked for, and it is strictly more deterministic than relying on which
-- child the engine visits first.
function AnimalBuyScheduleDialog:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if isDown and button == Input.MOUSE_BUTTON_LEFT and self.pickers ~= nil then
        for _, pk in pairs(self.pickers) do
            local inp = pk.input
            if inp ~= nil and inp.isCapturingInput == true and inp.absPosition ~= nil then
                local over = GuiUtils.checkOverlayOverlap(posX, posY,
                                 inp.absPosition[1], inp.absPosition[2],
                                 inp.size[1], inp.size[2])
                -- COMMITTED, not discarded: clicking away from a number you have
                -- typed means you meant it. releaseAndCommit is the same call the
                -- arrows already use for the same situation.
                if not over then pk:releaseAndCommit() end
            end
        end
    end
    return AnimalBuyScheduleDialog:superClass().mouseEvent(self, posX, posY, isDown, isUp, button, eventUsed)
end

function AnimalBuyScheduleDialog:onNumDigit(i, unicode)
    local pk = self.pickers ~= nil and self.pickers[i] or nil
    if pk == nil then return true end
    return pk:allow(unicode)
end

function AnimalBuyScheduleDialog:onNumChanged(i)
    local pk = self.pickers ~= nil and self.pickers[i] or nil
    if pk ~= nil then pk:changed() end
end

function AnimalBuyScheduleDialog:onNumEnter(i)
    local pk = self.pickers ~= nil and self.pickers[i] or nil
    if pk == nil then return end
    pk:enter()
    -- SAY SO WHEN IT WAS REFUSED. The grey prompt in the box states the rule, but
    -- the note line is where this dialog explains itself, and a player watching the
    -- money block go blank deserves the reason next to it.
    self.notice = pk.bad and pk.outOfRange or nil
    self:refresh()
end

function AnimalBuyScheduleDialog:onNumEsc(i)
    local pk = self.pickers ~= nil and self.pickers[i] or nil
    if pk ~= nil then pk:escape() end
end

---An arrow. It steps by ONE and wraps, and from an empty field the right arrow
-- lands on the minimum while the left lands on the maximum -- so either arrow
-- gives a usable number without typing.
function AnimalBuyScheduleDialog:onNumStep(i, dir)
    local pk = self:picker(i)
    if pk == nil then return end
    pk:step(dir)
    self.notice = nil
    self:refresh()
end

-- The XML names one handler per slot, so bind them here rather than writing
-- thirty near-identical stubs. Generated AFTER the five above exist, or the
-- closures would capture nils.
for i = 1, AnimalBuyScheduleDialog.SLOTS do
    local n = i
    AnimalBuyScheduleDialog["onNum" .. n .. "Digit"]   = function(self, u) return self:onNumDigit(n, u) end
    AnimalBuyScheduleDialog["onNum" .. n .. "Changed"] = function(self) return self:onNumChanged(n) end
    AnimalBuyScheduleDialog["onNum" .. n .. "Enter"]   = function(self) return self:onNumEnter(n) end
    AnimalBuyScheduleDialog["onNum" .. n .. "Esc"]     = function(self) return self:onNumEsc(n) end
    AnimalBuyScheduleDialog["onNum" .. n .. "Left"]    = function(self) return self:onNumStep(n, -1) end
    AnimalBuyScheduleDialog["onNum" .. n .. "Right"]   = function(self) return self:onNumStep(n, 1) end
    AnimalBuyScheduleDialog["onTog" .. n]              = function(self, st) return self:onToggle(n, st) end
end

function AnimalBuyScheduleDialog:onOpt1(s) return self:onSlot(1, s) end
function AnimalBuyScheduleDialog:onOpt2(s) return self:onSlot(2, s) end
function AnimalBuyScheduleDialog:onOpt3(s) return self:onSlot(3, s) end
function AnimalBuyScheduleDialog:onOpt4(s) return self:onSlot(4, s) end
function AnimalBuyScheduleDialog:onOpt5(s) return self:onSlot(5, s) end
function AnimalBuyScheduleDialog:onOpt6(s) return self:onSlot(6, s) end

---A TAB CLICK. Bounds-checked against the labels actually drawn, so a click on a
-- slot this window does not use can never select a mode it does not have.
function AnimalBuyScheduleDialog:selectMode(i)
    local m = AnimalTabs ~= nil and AnimalTabs.pick(self:modeLabels(), i) or nil
    if m == nil or m == self.mode then return end
    self.mode, self.aIndex, self.bIndex = m, 1, 1
    self.notice = nil
    self:rebuild()
end

function AnimalBuyScheduleDialog:onTab1() return self:selectMode(1) end
function AnimalBuyScheduleDialog:onTab2() return self:selectMode(2) end
function AnimalBuyScheduleDialog:onTab3() return self:selectMode(3) end

function AnimalBuyScheduleDialog:onBarnChanged(state)
    local s = stateOf(self.barnOption, state)
    if s == nil or self.barns[s] == nil then return end
    self.barnIndex, self.aIndex, self.bIndex = s, 1, 1
    self.notice = nil
    self:rebuild()
end

-- ---------------------------------------------------------------------------
function AnimalBuyScheduleDialog:onAdd()
    local b, _, uid = self:barn()
    if b == nil then return end
    local can, why = self:canAct()
    if not can then self.notice = why; self:refresh(); return end

    if self.mode == MODE_BUY then
        local c = self:rowA()
        if c == nil then return end
        local rec, err = AnimalBuySchedule.add({
            uid = uid, barnName = b.name,
            itemIndex = c.index, title = c.title, price = c.each, subType = c.subType,
            count = self:count(),
            everyMonths = self:every(),
            forMonths   = self:forMonths(),
            startIn     = self:start(),
        })
        if rec == nil then
            self.notice = string.format(l10n("ar_bs_refused", "Refused: %s"), tostring(err))
        else
            self.notice = string.format(l10n("ar_bs_added", "Added: %d x %s, %s"),
                                        rec.count, tostring(rec.title), months(rec.everyMonths))
            self.bIndex = #AnimalBuySchedule.forBarn(uid)
        end
    elseif self.mode == MODE_SELL_ORDER then
        local d = self:draftSellOrder()
        if d == nil then return end
        local _, tn = AnimalHerdData.animalTypeOf(select(2, self:barn()))
        local rec, err = AnimalSellSchedule.add({
            uid = uid, barnName = b.name, animalName = tn,
            count = d.count, everyMonths = d.everyMonths, forMonths = d.forMonths,
            startIn = d.startIn,
        })
        if rec == nil then
            self.notice = string.format(l10n("ar_bs_refused", "Refused: %s"), tostring(err))
        else
            self.notice = string.format(l10n("ar_bs_addedSell", "Added: sell %d, %s. Set its rules on the SELL RULES tab."),
                                        rec.count, months(rec.everyMonths))
            self.bIndex = #AnimalSellSchedule.forBarn(uid)
        end
    end
    self:rebuild()
end

---THE SELECTED ORDER for Pause and Remove. Always the LOWER list, because those
-- two buttons only exist on the screens that show it.
function AnimalBuyScheduleDialog:selectedOrder()
    return self:rowB()
end

function AnimalBuyScheduleDialog:onRemove()
    local s = self:selectedOrder()
    if s == nil then return end
    if self.mode == MODE_BUY then
        AnimalBuySchedule.remove(s.id)
        self.notice = string.format(l10n("ar_bs_removed", "Removed: %d x %s"),
                                    s.count, tostring(s.title))
    else
        AnimalSellSchedule.remove(s.id)
        self.notice = string.format(l10n("ar_bs_removedSell", "Removed: sell %d"), s.count)
    end
    self.bIndex = 1
    self:rebuild()
end

---PAUSE, NOT DELETE, on an order; the AUTO switch in rules mode. An instruction
-- stopped for a season should come back with its progress intact -- 5.48's ruling
-- about modes, applied to schedules.
function AnimalBuyScheduleDialog:onPause()
    local s = self:selectedOrder()
    if s == nil then return end
    s.enabled = not s.enabled
    self.notice = nil
    self:rebuild()
end

-- "SELL NOW" IS GONE (author, 2026-09-02): *"Sell now should not even be an
-- option. I was going to remove it anyway."* It was the ONE thing that ever moved
-- an animal by hand from this dialog; orders sell on their schedule instead.
--
-- The rules it ran are moving to the BARN-BREED (28.9) and will govern sales from
-- there, so a button that ran one order's private rule set once had no future
-- shape to grow into.

function AnimalBuyScheduleDialog:onClickBack()
    self:close()
    return true
end

---AR'S OWN PROFILES, loaded once before any layout that names them. Guarded on
-- HusbandryRedux rather than on this file, because a second dialog wanting the same
-- profiles must not load them again -- and because the flag then survives this
-- dialog being re-registered.
--
-- A LAYOUT NAMING A PROFILE THAT WAS NEVER LOADED DOES NOT ERROR: it falls back
-- to a default with no positioning at all (DR 5.64), so the control would render
-- somewhere unrelated and look like a geometry bug. Hence "before", not "near".
function AnimalBuyScheduleDialog.loadProfiles()
    if HusbandryRedux == nil or HusbandryRedux._profilesLoaded then return end
    if g_gui == nil or g_gui.loadProfiles == nil then return end
    local ok, err = pcall(g_gui.loadProfiles, g_gui, HusbandryRedux.MOD_DIR .. "gui/AnimalProfiles.xml")
    HusbandryRedux._profilesLoaded = true
    if not ok and HusbandryRedux.warn ~= nil then
        HusbandryRedux.warn("GUI profiles failed to load: %s", tostring(err))
    end
end

function AnimalBuyScheduleDialog.register()
    if AnimalBuyScheduleDialog._instance ~= nil then return true end
    if g_gui == nil or HusbandryRedux == nil then return false end
    AnimalBuyScheduleDialog.loadProfiles()
    local d = AnimalBuyScheduleDialog.new()
    g_gui:loadGui(HusbandryRedux.MOD_DIR .. "gui/AnimalBuyScheduleDialog.xml",
                  "AnimalBuyScheduleDialog", d)
    AnimalBuyScheduleDialog._instance = d
    return true
end

-- FULL TEXT ON HOVER for any cell the layout cut short (TextTip.lua, 2026-09-29).
if TextTip ~= nil and TextTip.install ~= nil then TextTip.install(AnimalBuyScheduleDialog) end
