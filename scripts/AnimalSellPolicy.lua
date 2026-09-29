-- ============================================================================
-- AnimalSellPolicy.lua -- THE RULES THAT DECIDE WHICH ANIMALS, per sell order.
--
-- ---------------------------------------------------------------------------
-- IT WAS PER BARN AND IS NOW PER ORDER (author, 2026-09-01), and the reason is a
-- double-up worth recording:
--
--   *"Sell order shouldn't have which animals, this is a rule and should be set
--    on the sell rule for that order otherwise it is a double up."*
--
-- The first build gave a timed order its own PICK RULE -- oldest / youngest /
-- cheapest / dearest -- alongside a barn-level policy that ALSO decides which
-- animals to take, and does it better: headroom already picks the least valuable
-- animal because that is optimal, and peak already picks what has peaked. Two
-- mechanisms answering one question, and the cruder one was the one in front of
-- the player.
--
-- So an ORDER now says only HOW MANY, HOW OFTEN and FOR HOW LONG. Its RULES say
-- which animals qualify, and the engine orders them. The pick selector is gone.
--
-- ---------------------------------------------------------------------------
-- THIS MODULE OWNS NO STATE ANY MORE. It was a per-barn store with its own
-- savegame section; a rule set now travels ON the order it belongs to and is
-- persisted with it (AnimalSellSchedule). What is left is the FIELD METADATA,
-- the stepping, the wording and the two calls that run a rule set -- which is
-- what every surface actually needed from it.
--
-- IT STILL ADDS NO RULES. Every field is a key of `AnimalSellRules.DEFAULTS`,
-- and the harness asserts that BIJECTION in both directions, so a switch cannot
-- be offered that the engine ignores nor a key hidden that it honours.
--
-- Sell orders now run on their schedule (AnimalSellSchedule.runDue, 2026-09-14).
-- ============================================================================

AnimalSellPolicy = {}

---THE FIELDS, in the order the panel shows them. `kind` drives the control and
-- `l10n` is STORED rather than composed from `key` -- a runtime-built key is
-- invisible to check_l10n_animal.py, and a missing one renders as a raw
-- "$l10n_..." with nothing in the log (5.60).
AnimalSellPolicy.FIELDS = {
    { key = "sellAtPeak",      kind = "bool",  l10n = "ar_pol_sellAtPeak" },
    { key = "keepFreeSlots",   kind = "slots", l10n = "ar_pol_keepFreeSlots",
      values = { -1, 0, 1, 2, 3, 4, 5, 6, 8, 10 } },
    { key = "headroomWorthIt", kind = "bool",  l10n = "ar_pol_headroomWorthIt" },
    { key = "minHealthToSell", kind = "pct",   l10n = "ar_pol_minHealthToSell",
      values = { 0, 0.5, 0.6, 0.7, 0.75, 0.8, 0.9 } },
    { key = "keepBreeders",    kind = "count", l10n = "ar_pol_keepBreeders",
      values = { 0, 2, 4, 6, 8, 10, 15, 20, 30 } },
    { key = "sellCalves",      kind = "bool",  l10n = "ar_pol_sellCalves" },
}


local function warn(fmt, ...)
    if HusbandryRedux ~= nil and HusbandryRedux.warn ~= nil then return HusbandryRedux.warn(fmt, ...) end
    local ok, msg = pcall(string.format, fmt, ...)
    print("[HusbandryRedux] " .. (ok and msg or tostring(fmt)))
end

function AnimalSellPolicy.fieldOf(key)
    for _, f in ipairs(AnimalSellPolicy.FIELDS) do if f.key == key then return f end end
    return nil
end

---The value a rule set holds for one field, falling back to the ENGINE's own
-- default -- so an unset key and a key set to its default behave identically,
-- which is what `plan`'s own `opt()` already does.
-- WRITTEN AS if/else, NEVER `a and b or c`. Half these values are BOOLEANS, so
-- the collapsing form turns an explicit `false` into nil and hands back the
-- engine's default instead -- a rule switched OFF would silently read as ON. DR
-- 5.44 and 5.46c record the same trap on `0`; this file has it on `false`, and
-- the harness caught it on the first run.
function AnimalSellPolicy.value(cfg, key)
    local v
    if type(cfg) == "table" then v = cfg[key] end
    if v == nil then return AnimalSellRules.DEFAULTS[key] end
    return v
end

---A rule's FULL RING: every value it can take, the words for each, and which is
-- current.
--
-- IT REPLACED A `step` FUNCTION, and the reason is a bug the author reported:
-- *"there is no looping back to the start and pressing the left arrow increases
-- the loop selection instead of decreasing it"*. The control was being handed a
-- single text -- the current value -- and any click was turned into one forward
-- step by the dialog, so LEFT went forward, RIGHT went forward, and the ring's own
-- wrapping never came into it.
--
-- Handed the whole ring, `MultiTextOptionElement` does all of it natively: left
-- decrements, right increments, `wrap` wraps, and `onClick` reports the new index.
-- A rule slot is now an ordinary selector like COUNT or EVERY, with no special
-- case in the dialog at all.
---Returns values, texts, index.
function AnimalSellPolicy.options(cfg, f, l10n)
    if f == nil then return {}, {}, 1 end
    local cur = AnimalSellPolicy.value(cfg, f.key)

    -- A BOOLEAN IS A TWO-VALUE RING. Off first so the ring reads false -> true,
    -- which is the order every other field goes in.
    local values = f.values
    if f.kind == "bool" then values = { false, true } end
    values = values or {}

    local texts, index = {}, 1
    for i, v in ipairs(values) do
        texts[i] = AnimalSellPolicy.textFor(f, v, l10n)
        if v == cur then index = i end
    end
    return values, texts, index
end

---The words for ONE VALUE of a rule. `l10n` is handed in so this module stays
-- free of any GUI dependency.
function AnimalSellPolicy.textFor(f, v, l10n)
    if f.kind == "bool" then
        return v == true and l10n("ar_pol_on", "On") or l10n("ar_pol_off", "Off")
    end
    if f.kind == "pct" then
        if v == 0 then return l10n("ar_pol_noFloor", "No floor") end
        return string.format(l10n("ar_pol_pct", "%d%% health"), math.floor(v * 100 + 0.5))
    end
    if f.kind == "slots" and v == -1 then
        return l10n("ar_pol_autoSlots", "Automatic (next births)")
    end
    if v == 0 then return l10n("ar_pol_noFloor", "No floor") end
    return tostring(v)
end

---The words for whatever a rule set currently holds.
function AnimalSellPolicy.valueText(cfg, f, l10n)
    return AnimalSellPolicy.textFor(f, AnimalSellPolicy.value(cfg, f.key), l10n)
end

---A one-line summary of which rules are ACTIVE, for the orders list.
--
-- ONLY THE TRIGGERS ARE NAMED -- what makes an animal a candidate. The health
-- floor and the breeder floor are CONSTRAINTS: they never cause a sale, they only
-- prevent one, so listing them beside the triggers would read as three reasons to
-- sell where there is one.
---`full` also names any CONSTRAINT that has been moved off its default. A
-- constraint at its default adds nothing to a summary -- it is what every order
-- does -- while one the player has changed is exactly what they will want to see
-- without opening the panel.
function AnimalSellPolicy.summary(cfg, l10n, full)
    local bits = {}
    if AnimalSellPolicy.value(cfg, "sellAtPeak") == true then
        bits[#bits + 1] = l10n("ar_pol_sum_peak", "Peak")
    end
    -- keepFreeSlots 0 means "keep no slots free", i.e. the headroom rule is OFF.
    -- -1 (derive it from next cycle's births) and any positive number are both on.
    if AnimalSellPolicy.value(cfg, "keepFreeSlots") ~= 0 then
        bits[#bits + 1] = l10n("ar_pol_sum_births", "Births")
    end
    if AnimalSellPolicy.value(cfg, "sellCalves") == true then
        bits[#bits + 1] = l10n("ar_pol_sum_nursery", "Nursery")
    end
    if #bits == 0 then bits[#bits + 1] = l10n("ar_pol_sum_none", "no rules") end
    if full then
        for _, f in ipairs(AnimalSellPolicy.FIELDS) do
            if f.kind == "pct" or f.kind == "count" or f.key == "headroomWorthIt" then
                local v = AnimalSellPolicy.value(cfg, f.key)
                if v ~= AnimalSellRules.DEFAULTS[f.key] then
                    bits[#bits + 1] = AnimalSellPolicy.textFor(f, v, l10n)
                end
            end
        end
    end
    return table.concat(bits, ", ")
end

-- ---------------------------------------------------------------------------
---What one rule set would do to this barn right now.
--
-- PRICED THROUGH THE EXECUTOR'S OWN priceFn, so the revenue is the REALISED net
-- rather than the gross. §14.1 records shipping that wrong once:
-- `cluster:getSellPrice()` is the gross and the dealer takes a flat 100 an animal.
function AnimalSellPolicy.planFor(p, cfg)
    if p == nil or AnimalSellRules == nil or AnimalSellRules.plan == nil then return nil end
    local priceFn = nil
    if AnimalSellExecutor ~= nil and AnimalSellExecutor.priceFn ~= nil then
        local okF, fn = pcall(AnimalSellExecutor.priceFn, p)
        if okF then priceFn = fn end
    end
    local ok, plan = pcall(AnimalSellRules.plan, p, cfg or {}, priceFn)
    if not ok then return nil, tostring(plan) end
    return plan
end

---Trim a plan to at most `limit` animals, KEEPING THE ENGINE'S OWN ORDER.
--
-- THE ORDER IS THE POINT, and it is what replaced the pick selector. `plan` has
-- already decided which animals are worth selling and in what sequence -- the
-- headroom loop before the peak rule, least valuable first -- so an order that
-- wants five takes the first five of THAT, not five of its own choosing.
function AnimalSellPolicy.capPlan(plan, limit)
    if plan == nil then return nil end
    local out = { lines = {}, total = 0, revenue = 0, assess = plan.assess, notes = plan.notes }
    local left = limit
    for _, ln in ipairs(plan.lines or {}) do
        if left <= 0 then break end
        local n = math.min(left, ln.count or 0)
        if n > 0 then
            local each = (ln.count or 0) > 0 and (ln.revenue or 0) / ln.count or 0
            local copy = {}
            for k, v in pairs(ln) do copy[k] = v end
            copy.count   = n
            copy.revenue = each * n
            copy.gross   = (ln.each or 0) * n
            out.lines[#out.lines + 1] = copy
            out.total   = out.total + n
            out.revenue = out.revenue + copy.revenue
            left = left - n
        end
    end
    return out
end

---Run a rule set ONCE, now, capped at `limit` animals where one is given. The
-- player's explicit press; never a timer.
function AnimalSellPolicy.sellNow(p, cfg, limit)
    if AnimalSellExecutor == nil or AnimalSellExecutor.execute == nil then
        return nil, "the sell executor is not available"
    end
    local plan, err = AnimalSellPolicy.planFor(p, cfg)
    if plan == nil then return nil, err or "no plan" end
    if #(plan.lines or {}) == 0 then return nil, "the rules would sell nothing right now" end
    if type(limit) == "number" and limit > 0 then
        plan = AnimalSellPolicy.capPlan(plan, limit)
        if #(plan.lines or {}) == 0 then return nil, "nothing to sell" end
    end
    local res = AnimalSellExecutor.execute(p, plan)
    if res ~= nil and res.refused ~= nil then return nil, res.refused end
    if res ~= nil and (res.sold or 0) > 0 then
        -- UNCONDITIONAL. Money moved; that belongs in a default log.
        warn("sell now: %d animal(s) sold from %s for %d",
             res.sold, tostring(select(2, pcall(function() return p:getName() end))),
             math.floor((res.revenue or 0) + 0.5))
    end
    return res
end
