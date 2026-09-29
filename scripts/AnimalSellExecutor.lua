-- ============================================================================
-- AnimalSellExecutor.lua  (Husbandry Redux)
--
-- LAYER 3 OF THREE. AnimalSellRules decides WHAT to sell and returns a plan;
-- this carries the plan out. It owns no policy: hand it a plan and it sells
-- exactly those lines, or reports why it could not.
--
-- IT DOES NOT IMPLEMENT A TRANSACTION. Every sale goes through the base game's
-- own dealer controller, so money, cluster removal, husbandry bookkeeping and
-- multiplayer replication are the game's -- not ours. The alternative was
-- cluster:changeNumAnimals(-n) plus addMoney, and every part of that which is
-- wrong loses the player animals or money SILENTLY. The whole API below was
-- measured rather than read: AnimalScreenDealerFarm.lua and AnimalCluster.lua
-- are absent from the shipped SDK source (CLAUDE.md 10.1, 13).
--
-- THE TWO FACTS THAT ARE THE OPPOSITE OF WHAT THE NAMES SUGGEST (13.2), and
-- both would have shipped as bugs if this had been written from the source:
--   * applyTARGET sells. applySource BUYS. The controller reports
--     source = "Animal Dealer" (Buy) and target = "Farm" (Sell).
--   * applyTarget(item, itemIndex, numAnimals) -- the MIDDLE argument is the
--     item's index in the target list, NOT a count.
-- ============================================================================

AnimalSellExecutor = {}

-- The five the GUI supplies. Measured by arSellDiff as the entire difference
-- between a headless controller and the one setController builds: without them
-- applyTarget dies at DealerFarm:131/136 with "attempt to call a nil value".
AnimalSellExecutor.CALLBACKS = {
    "actionTypeCallback", "animalsChangedCallback", "errorCallback",
    "sourceActionFinished", "targetActionFinished",
}

local function log(fmt, ...)
    if HusbandryRedux ~= nil and HusbandryRedux.warn ~= nil then
        HusbandryRedux.warn(fmt, ...)
    else
        local ok, m = pcall(string.format, fmt, ...)
        print("[AnimalSellExecutor] " .. (ok and m or tostring(fmt)))
    end
end

---Only the server may sell: this moves money. A client that ran it would either
-- desync or double-charge, and the base game's own shop is server-authoritative
-- for the same reason.
function AnimalSellExecutor.canRun()
    if g_currentMission == nil then return false end
    if g_currentMission.getIsServer == nil then return true end   -- singleplayer builds
    local ok, isServer = pcall(g_currentMission.getIsServer, g_currentMission)
    return ok and isServer == true
end

-- ---------------------------------------------------------------------------
---Build and wire a controller for one barn. Returns ctrl, items, report -- where
-- `report` is the live record the callbacks write into, so a caller can read
-- what the game said rather than inferring it from side effects.
--
-- A CONSTRUCTED CONTROLLER IS NOT AN OPENED ONE (13.3): straight after new() both
-- item lists are empty even on a barn holding a hundred animals, because the GUI's
-- open path is what builds them. init*Items has to be called explicitly.
function AnimalSellExecutor.open(husbandry)
    if husbandry == nil then return nil, nil, nil, "no husbandry" end
    if AnimalScreenDealerFarm == nil or AnimalScreenDealerFarm.new == nil then
        return nil, nil, nil, "AnimalScreenDealerFarm is not available in this build"
    end
    local ok, ctrl = pcall(AnimalScreenDealerFarm.new, husbandry, nil, true)
    if not ok or type(ctrl) ~= "table" then
        return nil, nil, nil, "controller could not be constructed: " .. tostring(ctrl)
    end
    for _, n in ipairs({ "initSourceItems", "initTargetItems", "initItems" }) do
        if type(ctrl[n]) == "function" then pcall(ctrl[n], ctrl) end
    end

    -- RECORDERS, NOT NO-OPS. targetActionFinished(err, msg) with a nil err is how
    -- the game says the sale went through and errorCallback is how it says no; with
    -- bare no-ops a silent success and a silent refusal are indistinguishable, which
    -- is not a state an automatic seller may ever be in.
    local report = { errors = {}, finished = false, message = nil }
    ctrl.actionTypeCallback     = function() end
    ctrl.animalsChangedCallback = function() end
    ctrl.sourceActionFinished   = function() end
    ctrl.errorCallback = function(_, msg)
        report.errors[#report.errors + 1] = tostring(msg)
    end
    ctrl.targetActionFinished = function(_, err, msg)
        -- the probe observed (err, msg) with err nil on success; the leading self is
        -- absent because these are plain fields, not methods, so accept both shapes
        if type(err) == "string" and msg == nil then err, msg = nil, err end
        report.finished = true
        report.message  = msg ~= nil and tostring(msg) or nil
        if err ~= nil then report.errors[#report.errors + 1] = tostring(err) end
    end

    local items = {}
    if type(ctrl.getTargetItems) == "function" then
        local okI, list = pcall(ctrl.getTargetItems, ctrl)
        if okI and type(list) == "table" then items = list end
    end
    return ctrl, items, report, nil
end

---The index of the item holding `cluster`, or nil.
-- Matched on the CLUSTER OBJECT first and the cluster id only as a fallback: the
-- id is stable within a barn but the object is exact, and applyTarget takes the
-- index, so picking the wrong row sells the wrong animals.
function AnimalSellExecutor.indexOf(items, cluster)
    if type(items) ~= "table" or cluster == nil then return nil end
    for i, it in ipairs(items) do
        if type(it.getCluster) == "function" then
            local ok, c = pcall(it.getCluster, it)
            if ok and c == cluster then return i end
        end
    end
    local wantId = nil
    if type(cluster.getClusterId) == "function" then
        local ok, v = pcall(cluster.getClusterId, cluster); if ok then wantId = v end
    end
    wantId = wantId or cluster.id
    if wantId == nil then return nil end
    for i, it in ipairs(items) do
        if type(it.getClusterId) == "function" then
            local ok, v = pcall(it.getClusterId, it)
            if ok and v == wantId then return i end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
---What `n` animals of this cluster would ACTUALLY realise, after the dealer's fee.
--
-- getTargetPrice(item, index, n) -> (ok, gross, fee, net), measured 13.5, and it is
-- READ-ONLY, so a plan can be costed exactly without selling anything. The fee is a
-- flat 100 PER ANIMAL (confirmed by scaling 1 -> 2 -> 7, not fitted from one point),
-- so the cluster's own getSellPrice -- which AnimalSellRules quotes -- is the GROSS
-- and over-states every projection.
function AnimalSellExecutor.netPrice(ctrl, items, cluster, n)
    if ctrl == nil or type(ctrl.getTargetPrice) ~= "function" then return nil end
    local i = AnimalSellExecutor.indexOf(items, cluster)
    if i == nil then return nil end
    local packed = { pcall(ctrl.getTargetPrice, ctrl, items[i], i, n or 1) }
    if not packed[1] then return nil end
    -- (ok, gross, fee, net). Taken by POSITION FROM THE END so a build returning a
    -- different arity still yields the net rather than silently quoting the gross.
    local net = packed[#packed]
    if type(net) ~= "number" then return nil end
    return net, packed[3], packed[4]
end

---A pricing function for AnimalSellRules.plan, closing over one barn's controller.
-- Lets the pure rules layer quote REALISED money without knowing anything about
-- controllers: it stays testable, and the figure on screen stops being a lie.
function AnimalSellExecutor.priceFn(husbandry)
    local ctrl, items = AnimalSellExecutor.open(husbandry)
    if ctrl == nil then return nil end
    return function(cluster, n)
        return AnimalSellExecutor.netPrice(ctrl, items, cluster, n)
    end
end

-- ---------------------------------------------------------------------------
---Carry out a plan. Returns { sold, revenue, lines = { {count, revenue, ok, why} } }.
--
-- THE ITEM LIST IS REBUILT BETWEEN LINES. Selling changes the clusters, so an index
-- taken before a sale may address a different row -- or nothing -- after it. This is
-- an hourly pass, not a hot path, so it re-opens rather than trying to keep a stale
-- list in step.
function AnimalSellExecutor.execute(husbandry, plan)
    local out = { sold = 0, revenue = 0, lines = {} }
    if not AnimalSellExecutor.canRun() then
        out.refused = "not the server"
        return out
    end
    if husbandry == nil or type(plan) ~= "table" or #(plan.lines or {}) == 0 then
        return out
    end

    for _, line in ipairs(plan.lines) do
        local n = math.floor(line.count or 0)
        local rec = { count = n, reason = line.reason, ok = false }
        if n > 0 and line.cluster ~= nil then
            local ctrl, items, report, err = AnimalSellExecutor.open(husbandry)
            if ctrl == nil then
                rec.why = err
            else
                local i = AnimalSellExecutor.indexOf(items, line.cluster)
                if i == nil then
                    -- not an error: an earlier line may have emptied this cluster, or
                    -- the herd changed between planning and selling
                    rec.why = "cluster is no longer on the barn"
                else
                    local expected = AnimalSellExecutor.netPrice(ctrl, items, line.cluster, n)
                    local okA, applyErr = pcall(ctrl.applyTarget, ctrl, items[i], i, n)
                    if not okA then
                        rec.why = tostring(applyErr)
                    elseif #report.errors > 0 then
                        rec.why = table.concat(report.errors, "; ")
                    elseif not report.finished then
                        -- the call returned cleanly and the game never confirmed. Treated as a
                        -- FAILURE rather than assumed: this is the one outcome that would
                        -- otherwise be reported as revenue that never arrived.
                        rec.why = "the game did not confirm the sale"
                    else
                        rec.ok = true
                        rec.revenue = expected
                        out.sold = out.sold + n
                        out.revenue = out.revenue + (expected or 0)
                    end
                end
            end
        else
            rec.why = "nothing to sell on this line"
        end
        out.lines[#out.lines + 1] = rec
    end

    if out.sold > 0 then
        log("auto-sell: %d animal(s) from %s for %s",
            out.sold,
            tostring(select(2, pcall(function() return husbandry:getName() end))),
            g_i18n ~= nil and g_i18n.formatMoney ~= nil
                and select(2, pcall(g_i18n.formatMoney, g_i18n, out.revenue, 0, true, true))
                or string.format("%.2f", out.revenue))
    end
    for _, r in ipairs(out.lines) do
        if not r.ok and r.why ~= nil then
            log("auto-sell: line of %d (%s) NOT sold: %s", r.count, tostring(r.reason), r.why)
        end
    end
    return out
end
