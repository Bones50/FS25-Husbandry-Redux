-- ============================================================================
-- AnimalAlerts -- a once-off notification when a barn slips (author, 2026-09-14)
--
-- The feed adviser recommends the CHEAPEST ration that holds health at 100%, with
-- no safety margin: a ration that only just clears the 0.28 floor is one empty silo
-- away from frozen or falling health. The author's answer is to tell the player the
-- moment it matters rather than overfeed every barn against the chance:
--
--   * health drops from 100% to anything lower
--   * profit goes from zero-or-better to a loss
--
-- ONCE PER CHANGE, NEVER EVERY HOUR. Each barn remembers whether it was last seen
-- healthy and profitable; a message fires only on the step from yes to no, and the
-- alert re-arms only when the barn gets back to 100% / back into profit. A barn that
-- is already below 100% or at a loss when the game loads says nothing -- that is not
-- a change, and a wall of messages on every load is exactly the spam to avoid.
--
-- NEW ANIMALS DO NOT COUNT (author, 2026-09-14). Buying pigs that arrive below 100%
-- drags the herd's average down without anything having gone wrong, so the health
-- alert is judged PER ANIMAL GROUP (cluster), by the cluster's own id: it fires only when
-- a group that was at 100% an hour ago is now below it. Bought or newborn animals were
-- never at 100% in this barn, so they cannot trigger it -- until they have reached 100%
-- themselves and then fall. Clusters only merge when breed, age AND health all match
-- (AR CLAUDE.md), so a purchase can never pull an existing group's health down.
--
-- SESSION ONLY. The memory is not saved: after a load every barn is seeded from its
-- first reading, silently.
--
-- CLIENT SIDE. A notification is a screen message, so this runs where there is a
-- screen, for the local player's own barns (AnimalHerdData.enumerate scopes that).
-- A dedicated server has nobody to show it to and skips the pass.
-- ============================================================================

AnimalAlerts = AnimalAlerts or {}

-- health that counts as full; kept equal to the adviser's so "at 100%" means one thing
AnimalAlerts.HEALTH_FULL = 0.995

-- uid -> { healthFull = bool|nil, profitable = bool|nil }
AnimalAlerts.state = {}

local function L(key, fallback)
    if HusbandryRedux ~= nil and HusbandryRedux.l10n ~= nil then return HusbandryRedux.l10n(key, fallback) end
    return fallback
end

---THE DECISION, pure so the harness can drive it. `health` is 0..1 and `profit` the
-- barn's current profit per month; either may be nil, and a nil reading changes nothing
-- (unknown is not "dropped"). `groups`, when given, is the barn's clusters as
-- { { id, health (0..1) }, ... } and replaces the herd average for the health alert.
---Returns a list of { kind = "HEALTH" | "LOSS" } for the changes worth a message.
function AnimalAlerts.observe(uid, health, profit, groups)
    local out = {}
    if uid == nil then return out end
    local st = AnimalAlerts.state[uid]
    if st == nil then
        st = {}
        AnimalAlerts.state[uid] = st
    end

    local full = (AnimalAdvisor ~= nil and AnimalAdvisor.HEALTH_FULL) or AnimalAlerts.HEALTH_FULL
    if type(groups) == "table" then
        -- per group: which were at 100% last hour, and which of those have fallen since
        local seeded = st.fullIds ~= nil
        local fullNow, droppedNow, lowest = {}, {}, nil
        for _, g in ipairs(groups) do
            if g.id ~= nil and type(g.health) == "number" then
                if g.health >= full then
                    fullNow[g.id] = true
                elseif seeded and (st.fullIds[g.id] or (st.dropped ~= nil and st.dropped[g.id])) then
                    -- fell from 100% this hour, or still down from an earlier fall
                    droppedNow[g.id] = true
                    if lowest == nil or g.health < lowest then lowest = g.health end
                end
            end
        end
        local wasDown = st.dropped ~= nil and next(st.dropped) ~= nil
        -- the message quotes the group that fell, not the herd average new animals drag down
        if seeded and not wasDown and next(droppedNow) ~= nil then
            out[#out + 1] = { kind = "HEALTH", health = lowest }
        end
        st.fullIds, st.dropped = fullNow, droppedNow
    elseif type(health) == "number" then
        local now = health >= full
        if st.healthFull == true and not now then out[#out + 1] = { kind = "HEALTH" } end
        st.healthFull = now
    end
    if type(profit) == "number" then
        local now = profit >= 0
        if st.profitable == true and not now then out[#out + 1] = { kind = "LOSS" } end
        st.profitable = now
    end
    return out
end

---The text for one alert.
function AnimalAlerts.text(kind, barnName, health)
    local name = tostring(barnName or "?")
    if kind == "HEALTH" then
        local pct = type(health) == "number" and math.floor(health * 100 + 0.5) or 0
        return string.format(L("ar_alert_health", "%s: animal health has dropped to %d%%"), name, pct)
    end
    return string.format(L("ar_alert_loss", "%s: now running at a loss"), name)
end

local function notify(text)
    local m = g_currentMission
    if m == nil or m.addIngameNotification == nil then return end
    local kind = (FSBaseMission ~= nil and FSBaseMission.INGAME_NOTIFICATION_CRITICAL) or nil
    pcall(m.addIngameNotification, m, kind, text)
end

-- getIsClient is false only on a dedicated server -- the base game's own test for
-- "is there a player here" (FarmlandManager.lua:573).
local function hasScreen()
    local m = g_currentMission
    if m ~= nil and m.getIsClient ~= nil then
        local ok, c = pcall(m.getIsClient, m)
        if ok and c == false then return false end
    end
    return true
end

---The barn's clusters as { id, health 0..1 }, or nil when they cannot be read (the
-- herd average is then used instead).
function AnimalAlerts.groupsOf(placeable)
    if placeable == nil or placeable.getClusters == nil then return nil end
    local ok, clusters = pcall(placeable.getClusters, placeable)
    if not ok or type(clusters) ~= "table" then return nil end
    local out = {}
    for _, cl in pairs(clusters) do
        local id = nil
        if type(cl.getClusterId) == "function" then
            local okI, v = pcall(cl.getClusterId, cl); if okI then id = v end
        end
        if id == nil then id = cl.id end
        if id == nil then return nil end
        if (cl.numAnimals or 0) > 0 then
            out[#out + 1] = { id = id, health = (cl.health or 0) / 100 }
        end
    end
    return out
end

---One pass over the player's barns.
function AnimalAlerts.run()
    if not hasScreen() then return 0 end
    if AnimalSettings ~= nil and AnimalSettings.herdAdviserEnabled ~= nil
       and not AnimalSettings.herdAdviserEnabled() then
        return 0
    end
    if AnimalHerdData == nil or AnimalHerdData.enumerate == nil
       or HusbandryRedux == nil or HusbandryRedux.husbandryPanel == nil then
        return 0
    end
    local sent = 0
    local okE, barns = pcall(AnimalHerdData.enumerate)
    if not okE or type(barns) ~= "table" then return 0 end
    for _, b in ipairs(barns) do
        local okP, d = pcall(HusbandryRedux.husbandryPanel, b.placeable)
        if okP and type(d) == "table" then
            local health = d.herd ~= nil and d.herd.health or nil
            local profit = d.profit ~= nil and d.profit.perMonth or nil
            local groups = AnimalAlerts.groupsOf(b.placeable)
            for _, a in ipairs(AnimalAlerts.observe(b.uid, health, profit, groups)) do
                notify(AnimalAlerts.text(a.kind, b.name, a.health or health))
                sent = sent + 1
            end
        end
    end
    return sent
end

function AnimalAlerts:onHourChanged()
    local ok, err = pcall(AnimalAlerts.run)
    if not ok and HusbandryRedux ~= nil and HusbandryRedux.warn ~= nil then
        HusbandryRedux.warn("barn alerts pass failed: %s", tostring(err))
    end
end

function AnimalAlerts.install()
    if g_messageCenter == nil or MessageType == nil or MessageType.HOUR_CHANGED == nil then return false end
    -- the mod chunk re-runs per mission load: unsubscribe first, and forget the last
    -- save's barns so nothing carries across
    pcall(g_messageCenter.unsubscribe, g_messageCenter, MessageType.HOUR_CHANGED, AnimalAlerts)
    AnimalAlerts.state = {}
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, AnimalAlerts.onHourChanged, AnimalAlerts)
    return true
end

if Mission00 ~= nil and Mission00.loadMission00Finished ~= nil and Utils ~= nil then
    Mission00.loadMission00Finished = Utils.appendedFunction(
        Mission00.loadMission00Finished,
        function() pcall(AnimalAlerts.install) end)
end
