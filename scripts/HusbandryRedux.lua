-- ============================================================================
-- HusbandryRedux.lua  (Husbandry Redux)
--
-- Bootstrap and the single point where this mod reaches Distribution Redux.
--
-- HOW CROSS-MOD ACCESS WORKS, because it is not obvious and it is easy to get
-- wrong in a way that only fails on someone else's machine:
--
--   Every mod's Lua environment is published as a table in the SHARED global
--   environment, keyed by the mod's ZIP / FOLDER NAME. So Distribution Redux's
--   own globals are reachable from here as:
--
--       FS25_Distribution_Redux.SmartDistribution
--
--   This is the same mechanism Courseplay uses to reach AutoDrive
--   (Courseplay.lua: "self.autoDrive = FS25_AutoDrive and FS25_AutoDrive.AutoDrive").
--
-- TWO RULES FOLLOW FROM THAT, and both are load-bearing:
--
--   1. RESOLVE LATE, NEVER AT FILE SCOPE. Mod load order is not guaranteed, so
--      at chunk load DR's table may not exist yet. Courseplay resolves in
--      loadMap for exactly this reason; we resolve on
--      Mission00.loadMission00Finished, which is also where DR installs itself.
--
--   2. THE KEY IS THE FILE NAME, NOT THE MOD. If a player renames the DR zip,
--      the global moves with it. The direct lookup is tried first (the normal
--      case, one table read) and a scan of the active mods is the fallback.
--
-- This mod is a HARD DEPENDENCY on Distribution Redux: with DR absent it logs
-- once and disables itself rather than erroring per-frame.
-- ============================================================================

HusbandryRedux = {}

HusbandryRedux.MOD_NAME = g_currentModName or "FS25_Husbandry_Redux"
HusbandryRedux.MOD_DIR  = g_currentModDirectory or ""
HusbandryRedux.VERSION  = "0.0.0.3"

---THE DEV CONSOLE IS OFF FOR RELEASE (2026-09-29, DR 6.13c's rule). Every `ar*` console command --
-- the probes, arTradeDump, arFeedPlan and the arBuy* schedule commands, some of which sell or buy
-- animals -- is registered only when this is true, and nothing announces them in the log otherwise.
-- The command bodies are kept: set this true and rebuild to get them back for diagnosis.
HusbandryRedux.DEV_CONSOLE = false

-- The mod we integrate with, and the API version that can host ALL of Animal
-- Redux's UI: the Herd Inspector page (v3), the settings tab (v8) and the User
-- Guide tab (v9).
--
-- IT IS ADVISORY, AND DELIBERATELY SO. Not one decision in this file is made on
-- it -- every feature tests for the FUNCTION it needs (drIntegrationGaps,
-- AnimalSettings.capabilityOk), because a version number cannot answer "can DR do
-- this": Distribution Redux carried the string 1.1.0.1 from 2026-08-16 to
-- 2026-09-07 while its API went from v1 to v9, so two players both running
-- "DR 1.1.0.1" have completely different capabilities. What the number is FOR is
-- telling a player what to update TO, which a capability test cannot express.
HusbandryRedux.DR_MOD_NAME = "FS25_Distribution_Redux"
HusbandryRedux.DR_MIN_API  = 9

HusbandryRedux.debug = false

-- ---------------------------------------------------------------------------
-- LOCALISATION
--
-- Declared HERE, at the top, because other files call it during GUI setup and a
-- reference below its definition resolves to a nil global -- which `luac -p`
-- does NOT catch (it parses fine and throws only when reached, mid-populate,
-- showing as an empty page). Same trap DR hit twice (CLAUDE.md 5.44 / 5.57).
--
-- THE NAMESPACE ARGUMENT IS NOT OPTIONAL. Lua has no customEnvironment of its
-- own, so `g_i18n:getText(key)` without MOD_NAME misses into the BASE GAME's
-- table and silently falls back for ever -- which looks exactly like "l10n is
-- not working" with nothing in the log. XML is different: `$l10n_key` in
-- gui/*.xml resolves against this mod automatically, because the engine sets
-- customEnvironment from the file's own path.
--
-- EVERYTHING DEGRADES TO THE SHIPPED ENGLISH. A missing key, a partial
-- translation, an unparseable language file or an l10n system not yet up all
-- yield `fallback` -- never a raw key on screen. That is what makes accepting
-- partial community translations safe.
--
-- CONVENTIONS (see translations/translation_en.xml for the full list):
--   * every key is prefixed `ar_`
--   * NEVER translate an internal enum, a table key, or anything compared
--     against a literal. Translate only what is DISPLAYED. DR shipped a bug of
--     exactly this shape (role tags used as sort keys, CLAUDE.md 6.14).
--   * NEVER translate log output. A player pasting log.txt into a bug report
--     needs it in English, and so do we.
--   * build sentences with FORMAT STRINGS, never concatenation -- word order
--     differs by language.
--   * separate whole-sentence singular and plural keys; do not manufacture a
--     singular by trimming an "s".
function HusbandryRedux.l10n(key, fallback)
    if key == nil then return fallback end
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n.getText ~= nil then
        local ok, has = pcall(g_i18n.hasText, g_i18n, key, HusbandryRedux.MOD_NAME)
        if ok and has then
            local ok2, text = pcall(g_i18n.getText, g_i18n, key, HusbandryRedux.MOD_NAME)
            -- "" is a real miss, not a translation choosing to say nothing.
            if ok2 and text ~= nil and text ~= "" then return text end
        end
    end
    return fallback
end

-- Resolved on mission load. nil until then, and nil for ever if DR is absent.
HusbandryRedux.DR = nil            -- DR's SmartDistribution table
HusbandryRedux.enabled = false

-- ---------------------------------------------------------------------------
function HusbandryRedux.log(fmt, ...)
    if not HusbandryRedux.debug then return end
    local ok, msg = pcall(string.format, fmt, ...)
    print("[HusbandryRedux] " .. (ok and msg or tostring(fmt)))
end

-- Unconditional: a player cannot be talked through enabling a debug flag, so
-- anything that stops the mod working has to say so in a default log.
function HusbandryRedux.warn(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[HusbandryRedux] " .. (ok and msg or tostring(fmt)))
end

-- ---------------------------------------------------------------------------
-- The true global table. Referencing a mod's global by name directly (as
-- Courseplay does) works, but a lookup BY NAME needs the table itself.
local function globalEnv()
    local ok, env = pcall(getfenv, 0)
    if ok and type(env) == "table" then return env end
    return nil
end

-- Does this table look like Distribution Redux's environment?
local function looksLikeDR(env)
    return type(env) == "table"
       and type(env.SmartDistribution) == "table"
end

---Find DR's SmartDistribution table, or nil.
-- Direct lookup first (the normal case). If the player renamed the zip, fall
-- back to scanning the active mods for one whose environment carries
-- SmartDistribution -- the same list AutoDrive reads for its own name check.
function HusbandryRedux.resolveDistributionRedux()
    local G = globalEnv()
    if G == nil then return nil, "could not reach the global environment" end

    local direct = G[HusbandryRedux.DR_MOD_NAME]
    if looksLikeDR(direct) then
        return direct.SmartDistribution, HusbandryRedux.DR_MOD_NAME, direct
    end

    if g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
        local okMods, mods = pcall(g_modManager.getActiveMods, g_modManager)
        if okMods and type(mods) == "table" then
            for _, mod in pairs(mods) do
                local name = type(mod) == "table" and mod.modName or nil
                if type(name) == "string" and name ~= HusbandryRedux.MOD_NAME then
                    local env = G[name]
                    if looksLikeDR(env) then
                        return env.SmartDistribution, name, env
                    end
                end
            end
        end
    end

    return nil, "not found"
end

---Report DR's API version, and whether it reaches DR_MIN_API. A DR that publishes
-- no VERSION at all reads as 0 and the caller decides -- this never refuses to run.
-- The boolean is for MESSAGES only; behaviour is gated on capabilities (see
-- DR_MIN_API's note above).
function HusbandryRedux.checkApiVersion(SD)
    local api = SD ~= nil and SD.API or nil
    local version = (type(api) == "table" and tonumber(api.VERSION)) or 0
    return version, version >= HusbandryRedux.DR_MIN_API
end

-- ---------------------------------------------------------------------------
---The feed planner Distribution Redux calls, once per husbandry per hourly pass.
--
-- Contract (DR API v1): return { [fillTypeIndex] = litres } to take over this
-- building's food pool for this pass, or NIL to decline and leave DR's own
-- best-quality-first logic in place.
--
-- IT MUST BE CHEAP AND IT MUST NOT THROW. DR pcalls it and strikes out a planner
-- that throws three times, which would silently hand every husbandry on the farm
-- back to DR for the rest of the session -- so anything unexpected DECLINES
-- rather than errors.
--
-- DECLINING IS THE SAFE ANSWER and is used wherever the model cannot speak with
-- authority: no food data, an animal type we could not read, or no group with a
-- product DR is willing to deliver. DR's own behaviour is correct for SERIAL
-- animals anyway, so a decline is never a regression.
function HusbandryRedux.feedPlanner(placeable, allowedFillTypes, poolNeed)
    -- THE "Advanced Animal Feeder" SWITCH, and it DECLINES rather than
    -- unregistering. DR's own contract says a planner returning nil leaves DR's
    -- behaviour in place, and feedPlanFor treats that identically to an empty
    -- registry -- so this is the documented off switch rather than a second
    -- mechanism, it costs one comparison per husbandry per hour, and it takes
    -- effect on the very next pass with no registry churn and no re-registration
    -- ordering to get wrong.
    if AnimalSettings ~= nil and not AnimalSettings.advancedFeederEnabled() then return nil end
    if AnimalFeedModel == nil or placeable == nil then return nil end
    -- THE PER-BARN SWITCH (Pigs tab, 2026-09-14): a barn the player switched off goes
    -- back to DR's own feed rules by the same decline.
    if AnimalFeedPolicy ~= nil and AnimalFeedPolicy.enabled ~= nil then
        local SD = HusbandryRedux.DR
        local uid = (SD ~= nil and SD.assetUid ~= nil) and SD.assetUid(placeable) or nil
        if uid ~= nil and not AnimalFeedPolicy.enabled(uid) then return nil end
    end
    local spec = placeable.spec_husbandryFood
    if spec == nil then return nil end

    local ati = AnimalFeedModel.animalTypeIndexOf(placeable)
    if ati == nil then return nil end

    -- Read LIVE every pass, never cached: Animalic (or a map) can replace the
    -- whole food definition, and caching would pin us to whatever was loaded
    -- first. The read is a couple of table walks over a handful of groups.
    local model = AnimalFeedModel.read(ati, spec.supportedFillTypes)
    if model == nil then return nil end

    -- THE TARGET RATION FIRST (author, 2026-09-14): full while health is below 100%, the
    -- cheapest ration that holds it once it is there, cheapest products first. If it
    -- cannot be worked out (nothing priceable, no herd yet) the old every-group plan
    -- stands, so a barn is never left unfed by an adviser that could not decide.
    local plan = nil
    local okT, target = pcall(HusbandryRedux.targetFeedPlan, placeable, model, allowedFillTypes, poolNeed)
    if okT and type(target) == "table" and next(target) ~= nil then plan = target end
    if plan == nil then plan = AnimalFeedModel.planWithin(model, poolNeed, allowedFillTypes) end
    if next(plan) == nil then return nil end
    return plan
end

---WHAT THE FARM CAN DELIVER TO THIS BARN, per fill type: what DR could bring (API v12)
-- plus what is already in the trough. nil without a DR that can answer, which leaves the
-- adviser treating every crop as in stock -- its behaviour before this existed.
--
-- CACHED PER BARN PER IN-GAME HOUR: inside DR's hourly pass the source list is not
-- memoised, so the planner and the panel asking per crop would otherwise walk the whole
-- map once per crop per barn.
HusbandryRedux._stock = { stamp = nil, byUid = {} }
function HusbandryRedux.stockFnFor(placeable)
    local SD = HusbandryRedux.DR
    local api = SD ~= nil and SD.API or nil
    if placeable == nil or api == nil or api.deliverableLitres == nil then return nil end
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local stamp = env ~= nil and ((env.currentDay or 0) * 24 + (env.currentHour or 0)) or nil
    local C = HusbandryRedux._stock
    if stamp == nil or C.stamp ~= stamp then C.stamp, C.byUid = stamp, {} end
    local uid = (SD.assetUid ~= nil) and SD.assetUid(placeable) or tostring(placeable)
    local mine = C.byUid[uid]
    if mine == nil then mine = {}; C.byUid[uid] = mine end
    local fs = placeable.spec_husbandryFood
    return function(ft)
        local v = mine[ft]
        if v == nil then
            local d = api.deliverableLitres(placeable, ft)
            if type(d) ~= "number" then return nil end
            local trough = (fs ~= nil and fs.fillLevels ~= nil and fs.fillLevels[ft]) or 0
            v = d + trough
            mine[ft] = v
        end
        return v
    end
end

---THE PLAN FOR THE TARGET RATION, or nil when it cannot be decided.
--
-- DR API v11 is what lets the ranking stand: an older DR ignores `ordered` and ranks by
-- food quality, which would put pig food FIRST -- so without v11 the complete ration is
-- left out of the request altogether rather than handed to a DR that would pick it.
function HusbandryRedux.targetFeedPlan(placeable, model, allowed, poolNeed)
    if AnimalAdvisor == nil or AnimalAdvisor.targetRation == nil
       or AnimalFeedModel == nil or AnimalFeedModel.rankedPlan == nil then
        return nil
    end
    local clusters = nil
    if placeable.getClusters ~= nil then
        local ok, c = pcall(placeable.getClusters, placeable)
        if ok and type(c) == "table" then clusters = c end
    end
    if clusters == nil or #clusters == 0 then return nil end
    local health = nil
    if AnimalHerdData ~= nil and AnimalHerdData.herdHealthFactor ~= nil then
        local ok, h = pcall(AnimalHerdData.herdHealthFactor, clusters)
        if ok and type(h) == "number" then health = h end
    end
    local rows = {}
    for _, cl in ipairs(clusters) do
        local st = nil
        if AnimalEconomics ~= nil and AnimalEconomics._subTypeOf ~= nil then
            local ok, v = pcall(AnimalEconomics._subTypeOf, cl.subTypeIndex)
            if ok and type(v) == "table" then st = v end
        end
        rows[#rows + 1] = { count = cl.numAnimals or 0, age = cl.age, subType = st,
                            subTypeIndex = cl.subTypeIndex }
    end
    local demand = AnimalFeedModel.demandPerHour(placeable)
    if type(demand) ~= "number" or demand <= 0 then return nil end
    local ctx = AnimalAdvisor.bind{ model = model, demandPerHour = demand, rows = rows,
                                    stockOf = HusbandryRedux.stockFnFor(placeable) }
    local target = AnimalAdvisor.targetRation(ctx, health)
    if type(target) ~= "table" or type(target.groups) ~= "table" then return nil end
    local DRapi = HusbandryRedux.DR ~= nil and HusbandryRedux.DR.API or nil
    local v11 = DRapi ~= nil and type(DRapi.VERSION) == "number" and DRapi.VERSION >= 11
    return AnimalFeedModel.rankedPlan(model, poolNeed, allowed, {
        groups = target.groups, priceOf = ctx.pricePerLitre, rations = v11, ordered = v11,
    })
end

-- ---------------------------------------------------------------------------
---The husbandry panel Distribution Redux draws between the INCOMING and OUTGOING
-- tables on its Animal Husbandry tab (DR API v4).
--
-- Contract: return { herd = {...}, value = {...}, feed = {...} } for this barn, or
-- NIL to leave the strip empty. DR validates every field and draws; this decides
-- nothing about layout and supplies no colours -- deliberately, because a provider
-- that could place elements could break DR's page for everyone.
--
-- IT MUST NOT THROW. DR pcalls it and strikes the provider out after three throws,
-- which would blank the panel for the rest of the session, so every read here is
-- guarded and anything unexpected simply omits that field.
--
-- IT IS A SUMMARY, NOT THE TAB. Per-animal detail (ages, next birth, per-cluster
-- value), the auto-sell rules and the full condition list stay on the Animals tab,
-- which is where a player goes to ACT. This is what they need at a glance while
-- looking at what the barn is being fed.
-- ---------------------------------------------------------------------------
-- THE TWO PANEL ADVICE LINES.
--
-- Requested 2026-08-31: one under the feed graphic ("Food factor at 100%, no action
-- required" / "Provide root crops to raise productivity") and one beside ANIMALS
-- x / x ("No action" / "Sell 4 to make room for new births").
--
-- THEY ARE SENT AS TEXT, not as a code, and that is the one place this provider
-- departs from the code-and-data rule the rest of the mod follows. The reason is
-- ownership: DR draws the panel but the advice is entirely OUR domain -- which food
-- groups an animal type has, what a full pen destroys -- and DR has no vocabulary
-- for either. `feed.activeTitle` set that precedent in v4: the provider names the
-- tier, DR prints it. What DR keeps is the LAYOUT and the palette, which is the
-- split that matters.
--
-- The TONE is a word, not a colour: DR owns the palette and maps it (5.81).

---Up to three product names for a group, so the advice can say WHAT to provide.
-- Three because the line is 480px at 11px and the group title and verb come first;
-- a pig's root-crop group alone lists five.
function HusbandryRedux.groupProductNames(g, limit)
    local names, seen = {}, {}
    local m = g_fillTypeManager
    for _, ft in ipairs((g ~= nil and g.fts) or {}) do
        if #names >= (limit or 3) then break end
        local t = nil
        if m ~= nil and m.getFillTypeTitleByIndex ~= nil then
            local ok, v = pcall(m.getFillTypeTitleByIndex, m, ft)
            if ok and type(v) == "string" and v ~= "" then t = v end
        end
        if t ~= nil and not seen[t] then seen[t] = true; names[#names + 1] = t end
    end
    return names
end

---WHAT TO FEED THIS BARN NEXT.
--
-- SERIAL and PARALLEL need different advice because they are different mechanics
-- (3.5, measured). A COW's groups are quality TIERS and alternatives -- only the
-- best one PRESENT counts -- so the advice is "move up a tier". A PIG's are
-- PARALLEL and each contributes `production x met`, so the advice is "the group
-- you are missing most".
--
-- `groups` are the panel's own group records plus `fts`; `serial` and `factor` as
-- the panel computed them, so this cannot disagree with the bar above it.
---Returns { text, tone } or nil when there is nothing to say.
--
-- HEALTH AND PRODUCTIVITY ONLY (author, 2026-09-14): this line says what to feed to
-- keep the herd at its best, and nothing about money. The ration that PAYS best is
-- the Herd Value line's business now. The optimum is a food factor of 100%:
-- productivity is linear in the factor (33b), and health recovers fastest there.
--
-- URGENCY FROM THE MEASURED HEALTH MODEL (33a): below DECAY_BELOW health is
-- FALLING, between that and FEED_FLOOR it is FROZEN (rounding swallows the gain),
-- and above it health still rises, only more slowly than at a full ration. `health`
-- is the herd's 0..1 factor, optional; with it below full the line says the
-- missing food is what is holding recovery back.
function HusbandryRedux.feedAdvice(groups, serial, factor, grazes, health)
    if type(groups) ~= "table" or #groups == 0 or type(factor) ~= "number" then return nil end
    local L = HusbandryRedux.l10n
    local met = (AnimalAdvisor ~= nil and AnimalAdvisor.MET_TARGET) or 0.99

    if factor >= met then
        if type(health) == "number" and health < ((AnimalAdvisor ~= nil and AnimalAdvisor.HEALTH_FULL) or 0.995) then
            return { text = L("ar_adv_feed_recovering", "Full ration - health recovering to 100%"),
                     tone = "good" }
        end
        return { text = L("ar_adv_feed_optimal", "Food 100% - health and productivity at their best"),
                 tone = "good" }
    end

    -- WHAT IS MISSING, biggest loss first
    local missing = {}
    if serial then
        -- the best tier the barn could be on, and the best it IS on
        local best, active = nil, nil
        for _, g in ipairs(groups) do
            if best == nil or (g.share or 0) > (best.share or 0) then best = g end
            if (g.held or 0) > 0 and (active == nil or (g.share or 0) > (active.share or 0)) then
                active = g
            end
        end
        local want = nil
        if best ~= nil and (active == nil or best ~= active) then want = best
        else want = active end
        if want ~= nil then missing[1] = want end
    else
        -- PARALLEL: every group short of its need, ordered by `share x (1 - met)`,
        -- which is literally the factor each one is costing
        for _, g in ipairs(groups) do
            local miss = (g.share or 0) * (1 - (g.met or 0))
            if miss > 1e-9 then missing[#missing + 1] = { g = g, miss = miss } end
        end
        table.sort(missing, function(x, y) return x.miss > y.miss end)
        for i, m in ipairs(missing) do missing[i] = m.g end
    end

    if #missing == 0 then
        if grazes then
            return { text = L("ar_adv_feed_grazing", "Grazing - the meadow is feeding them"),
                     tone = "good" }
        end
        return nil
    end

    -- A PEN WITH FOOD GROUPS names every missing GROUP and nothing else (author,
    -- 2026-09-14): "Add Grain, Protein and Root crops". The inputs table beside the
    -- panel already lists each group's products, so naming them here only crowds
    -- the line. A pen with a single group has no categories to speak of, so it keeps
    -- the products: "Add Grain (Wheat, Barley)".
    local what
    if #groups > 1 then
        local titles = {}
        for _, g in ipairs(missing) do titles[#titles + 1] = tostring(g.title or "?") end
        if #titles == 1 then
            what = titles[1]
        else
            what = string.format(L("ar_adv_feed_listAnd", "%s and %s"),
                                 table.concat(titles, ", ", 1, #titles - 1), titles[#titles])
        end
    else
        local first = missing[1]
        local names = HusbandryRedux.groupProductNames(first)
        what = first.title or "?"
        if #names > 0 then what = string.format("%s (%s)", what, table.concat(names, ", ")) end
    end

    local decay = (AnimalAdvisor ~= nil and AnimalAdvisor.DECAY_BELOW) or 0.20
    local floor = (AnimalAdvisor ~= nil and AnimalAdvisor.FEED_FLOOR) or 0.28
    if factor < decay then
        return { text = string.format(L("ar_adv_feed_falling", "Health is falling - add %s now"), what),
                 tone = "bad" }
    end
    if factor < floor then
        return { text = string.format(L("ar_adv_feed_frozen", "Health is frozen - add %s"), what),
                 tone = "bad" }
    end
    if type(health) == "number" and health < 0.995 then
        return { text = string.format(
            L("ar_adv_feed_recover", "Add %s to restore health and productivity"), what), tone = "warn" }
    end
    return { text = string.format(L("ar_adv_feed_full", "Add %s for full productivity"), what),
             tone = "warn" }
end

---A signed money figure, short enough for a 480px line at 11px.
local function money(v)
    if type(v) ~= "number" then return "?" end
    local s = string.format("%d", math.floor(math.abs(v) + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return ((v < 0) and "-" or "+") .. out
end

---Exposed as a field so the herd renderer shares it -- a second copy is how two
-- lines on one panel come to format money differently.
--
-- DECLARED AFTER `money`, and that is not cosmetic: a field defined ABOVE the
-- local would resolve `money` as a nil GLOBAL at call time, and `luac -p` passes
-- it clean (5.44 / 5.57). I wrote it the wrong way round first.
function HusbandryRedux.moneyText(v) return money(v) end

---THE FEED ADVICE, rendered from AnimalAdvisor's code.
--
-- The adviser returns numbers and a CODE; this is the only place that turns one
-- into a sentence, so the arithmetic stays harnessable and the wording stays in
-- one place. Same split the panel already uses for `activeTitle`.
--
-- IT NAMES THE MONEY WHEREVER IT HAS IT. "Switch to Hay" is a preference;
-- "Switch to Hay: +1,331/mo" is an argument, and it is the whole reason the
-- adviser was rebuilt around profit rather than around food factor.
function HusbandryRedux.advisorFeedText(adv)
    if type(adv) ~= "table" or adv.code == nil then return nil end
    local L = HusbandryRedux.l10n
    local best = adv.best
    local name = (best ~= nil and best.title) or "?"
    local c = adv.code

    if c == "OPTIMAL" then
        -- NAME IT. "Best ration already" is what the author reported as unclear:
        -- it agrees with the player's own conclusion without saying so, which
        -- reads as though it disagreed. The arithmetic was right; the sentence
        -- was not saying what it had worked out.
        if name ~= "?" then
            return { text = string.format(
                L("ar_adv_feed_best_named", "Best ration already: %s"), name), tone = "good" }
        end
        return { text = L("ar_adv_feed_best", "Best ration already - no action needed"),
                 tone = "good" }
    end
    if c == "SWITCH" then
        if adv.deltaPerMonth ~= nil and adv.deltaPerMonth > 0 then
            return { text = string.format(
                L("ar_adv_feed_switch_gain", "Switch to %s: %s / mo"),
                name, money(adv.deltaPerMonth)), tone = "warn" }
        end
        return { text = string.format(L("ar_adv_feed_switch", "Switch to %s"), name),
                 tone = "warn" }
    end
    if c == "DEAD_ZONE" then
        -- 33a. The band nothing else on any screen names: health neither decays
        -- nor recovers, so a herd below the breeding gate is stuck for ever.
        return { text = string.format(
            L("ar_adv_feed_deadzone", "Food too thin - health FROZEN. Feed %s"), name),
            tone = "bad" }
    end
    if c == "DECAYING" then
        return { text = string.format(
            L("ar_adv_feed_decay", "Health is FALLING - feed %s now"), name), tone = "bad" }
    end
    if c == "FLOOR_UNREACHABLE" then
        return { text = L("ar_adv_feed_nofloor",
            "No ration here can restore health - check the trough"), tone = "bad" }
    end
    if c == "UNPROFITABLE" then
        -- A producer's herd that cannot pay for its own feed at ANY tier is a
        -- decision, not a ration choice, and saying "feed more" would be wrong.
        return { text = string.format(
            L("ar_adv_feed_noprofit", "Feed costs more than the output at every tier (%s / mo)"),
            money(adv.deltaPerMonth or 0)), tone = "warn" }
    end
    if c == "BREEDER_SUBSIDY" then
        -- The same arithmetic, but a breeding herd is paid in calves and stock
        -- value, which this line deliberately does not pretend to price.
        return { text = string.format(
            L("ar_adv_feed_subsidy", "Outputs do not cover feed - cheapest is %s"), name),
            tone = "warn" }
    end
    return nil
end

---WHETHER TO SELL TO MAKE ROOM FOR BIRTHS.
--
-- 11.11 measured what a full pen costs: it destroys `numAnimals` offspring AND the
-- gestation that made them, permanently, every cycle. That is the single most
-- expensive thing a herd can be doing, and nothing else on this panel says it.
--
-- THE PLAN IS THE AUTHORITY, not a second calculation. If it wants a headroom sale
-- it says how many; if it has looked and declined, the pen is losing births and the
-- trade is not worth it, which is a different message and an honest one.
---Returns { text, tone } or nil.
function HusbandryRedux.birthAdvice(a, plan)
    if type(a) ~= "table" then return nil end
    local L = HusbandryRedux.l10n

    local n = 0
    for _, ln in ipairs((plan ~= nil and plan.lines) or {}) do
        if ln.reason == AnimalSellRules.REASON_HEADROOM then n = n + (ln.count or 0) end
    end
    if n > 0 then
        -- PER BARN, so it keeps its own wording: a sell order is per (barn, BREED).
        return { text = string.format(L("ar_adv_birth_sell", "Sell %d to free slots for births"), n),
                 tone = "warn" }
    end

    local lost = a.lost or 0
    if lost > 0 then
        -- the plan looked and declined: the slots are worth less than the animals
        -- that would have to go, so the honest advice is to build, not to sell
        return { text = string.format(L("ar_adv_birth_lost", "%d births lost - pen is full"), lost),
                 tone = "bad" }
    end

    local free = a.free or 0
    if free > 0 and (a.breeders or 0) > 0 then
        return { text = string.format(L("ar_adv_birth_room", "No action - %d slots for births"), free),
                 tone = "good" }
    end
    if (a.breeders or 0) == 0 then
        return { text = L("ar_adv_birth_none", "No action - nothing is breeding"), tone = "good" }
    end
    return { text = L("ar_adv_birth_ok", "No action"), tone = "good" }
end

---THE NEXT BIRTH EVENT: when it lands, how many are due, how many a full pen destroys.
--
-- The soonest-due BREEDING cohort sets it, since that is when the next births land
-- (a cohort due later cannot be born first), and every cohort due that same month
-- lands with it. Births beyond the free slots are destroyed, gestation and all (11.5).
---Returns months, births, lost -- or nil when nothing is due to breed.
function HusbandryRedux.nextBirths(a)
    if type(a) ~= "table" then return nil end
    local soonest, births = nil, 0
    for _, c in ipairs(a.clusters or {}) do
        if c.willBreed and type(c.dueInMonths) == "number" then
            if soonest == nil or c.dueInMonths < soonest then
                soonest, births = c.dueInMonths, (c.count or 0)
            elseif c.dueInMonths == soonest then
                births = births + (c.count or 0)
            end
        end
    end
    if soonest == nil then return nil end
    return soonest, births, math.max(0, births - (a.free or 0))
end

---THE HERD LINE: only whether the next births will fit (author, 2026-09-14).
-- Orange when some will be lost, green otherwise. Nothing due to breed counts as
-- room, because there is nothing to lose.
function HusbandryRedux.nextBirthsAdvice(a)
    if type(a) ~= "table" then return nil end
    local L = HusbandryRedux.l10n
    local months, _, lost = HusbandryRedux.nextBirths(a)
    if months ~= nil and lost > 0 then
        return { text = string.format(L("ar_adv_birth_loseNext", "%d births lost in %d mo - no room"),
                                      lost, months), tone = "warn" }
    end
    return { text = L("ar_adv_birth_sufficient", "Sufficient room for new births"), tone = "good" }
end

---THE BEST SALE AGE, per breed, for breeds whose value DECLINES with age (the Cows tab,
-- author, 2026-09-24).
--
-- WHY THIS EXISTS. rotationOf sells each cohort at its PEAK-VALUE age, which is right for
-- pigs, sheep and chickens: their price curve plateaus, so peak is simply when growth stops.
-- Only cows decline after peak (11.3), and a dairy cow keeps milking while she does -- 36
-- measured a Holstein's milk at far more than her ~14/month decline. Selling her at peak is
-- exactly the mistake AnimalAdvisor.saleAge was written to avoid, so for a declining curve the
-- rotation asks that search instead.
--
-- THE SEARCH RUNS FROM BIRTH (age 0), not from the herd's current age: the rotation is a
-- standing answer about WHEN EACH COHORT SHOULD GO, and the objective saleAge maximises --
-- sale price at age A plus everything earned until A -- is that question asked of a newborn.
--
-- GATED ON `declines`, NOT ON THE TYPE NAME. A curve that never falls gains nothing from the
-- search's extra term, so every non-cow breed returns nothing here and rotationOf behaves
-- exactly as it did (pigs byte-identical). Modded declining breeds get the same treatment.
--
-- Returns breed name -> { age = best sale age, keep = true when holding still pays at the
-- search horizon }, or nil when nothing declines or the collaborators are missing.
-- MEMOISED per barn for SELL_AGE_MEMO_SEC of real time: the tab and the panel both ask on
-- every refresh, and each answer walks 120 months per breed.
HusbandryRedux.SELL_AGE_MEMO_SEC = 5
HusbandryRedux._sellAgeMemo = setmetatable({}, { __mode = "k" })

---WHAT THE SALE-AGE SEARCH NEEDS FROM THE BARN: the ration per head per month and the
-- barn's efficiency. Shared by sellAgesFor and producerSaleFor so the two answers cannot be
-- priced against different costs.
--
-- FEED IS THE BARN'S MEASURED RATION SPLIT PER HEAD (feedCostPerHour, as the panel bills
-- it). A calf eats less than a cow, so this slightly over-charges the young months; it errs
-- towards SELLING, which is the safe side of an advice line.
function HusbandryRedux.saleInputsFor(placeable, a)
    local feedPA = 0
    local animals = tonumber(a ~= nil and a.animals or 0) or 0
    if animals > 0 and AnimalFeedModel ~= nil and AnimalEconomics ~= nil
       and AnimalEconomics.feedCostPerHour ~= nil and placeable ~= nil
       and placeable.spec_husbandryFood ~= nil then
        local ok, perHour = pcall(function()
            local ati = AnimalFeedModel.animalTypeIndexOf(placeable)
            if ati == nil then return nil end
            local model = AnimalFeedModel.read(ati, placeable.spec_husbandryFood.supportedFillTypes)
            if model == nil then return nil end
            local every = {}
            for _, g in ipairs(model.groups) do
                for _, ft in ipairs(g.fts) do every[#every + 1] = ft end
            end
            local avail = AnimalFeedModel.availableOf(placeable, every)
            local fc = AnimalEconomics.feedCostPerHour(placeable, model, avail,
                                                       AnimalFeedModel.demandPerHour(placeable))
            return (type(fc) == "table") and fc.perHour or nil
        end)
        if ok and type(perHour) == "number" then
            local dpm = 1
            if AnimalEconomics.daysPerMonth ~= nil then
                local okD, d = pcall(AnimalEconomics.daysPerMonth)
                if okD and type(d) == "number" then dpm = d end
            end
            feedPA = perHour * 24 * dpm / animals
        end
    end
    local eff = 1
    if AnimalEconomics ~= nil and AnimalEconomics.efficiency ~= nil then
        local okE, e = pcall(AnimalEconomics.efficiency, placeable)
        if okE and type(e) == "number" then eff = e end
    end
    return feedPA, eff
end

---ONE SALE-AGE ANSWER for one cluster, from `age`. nil when anything it needs is missing.
function HusbandryRedux.saleAgeOfCluster(placeable, c, feedPA, eff, age, healthNow, count)
    if AnimalAdvisor == nil or AnimalAdvisor.saleAge == nil or AnimalAdvisor.bind == nil
       or AnimalEconomics == nil or AnimalEconomics._subTypeOf == nil or c == nil or c.cluster == nil then
        return nil
    end
    local okS, st = pcall(AnimalEconomics._subTypeOf, c.subTypeIndex)
    if not okS or type(st) ~= "table" then return nil end
    local okB, ctx = pcall(AnimalAdvisor.bind, {
        cluster = c.cluster, subType = st, placeable = placeable,
        efficiency = eff, feedPerAnimalMonth = feedPA,
        healthNow = healthNow or 1, healthKept = 1,
    })
    if not okB or type(ctx) ~= "table" then return nil end
    local okA, sa = pcall(AnimalAdvisor.saleAge, ctx, { age = age or 0, count = count or 1 })
    if okA and type(sa) == "table" and type(sa.bestAge) == "number" then return sa end
    return nil
end

function HusbandryRedux.sellAgesFor(placeable, a)
    if placeable == nil or type(a) ~= "table" or AnimalAdvisor == nil
       or AnimalAdvisor.saleAge == nil or AnimalAdvisor.bind == nil or AnimalEconomics == nil then
        return nil
    end
    local rep = {}
    for _, c in ipairs(a.clusters or {}) do
        if c.declines == true and c.name ~= nil and c.cluster ~= nil and rep[c.name] == nil then
            rep[c.name] = c
        end
    end
    if next(rep) == nil then return nil end

    local now = (getTimeSec ~= nil) and getTimeSec() or nil
    local memo = HusbandryRedux._sellAgeMemo[placeable]
    if memo ~= nil and now ~= nil and (now - memo.t) < HusbandryRedux.SELL_AGE_MEMO_SEC then
        return memo.v
    end

    local feedPA, eff = HusbandryRedux.saleInputsFor(placeable, a)
    local out = {}
    for name, c in pairs(rep) do
        local sa = HusbandryRedux.saleAgeOfCluster(placeable, c, feedPA, eff, 0, 1, 1)
        if sa ~= nil then
            out[name] = { age = sa.bestAge, keep = (sa.keepIndefinitely == true) }
        end
    end
    if now ~= nil then HusbandryRedux._sellAgeMemo[placeable] = { t = now, v = out } end
    return out
end

---SHOULD A PRODUCER HERD BE KEPT AT ALL? (author, 2026-09-24)
--
-- The type tabs' "Keep animals" used to rest on the breed verdict alone -- adults against
-- young stock, which weighs output (net of straw) and value decline but NOT FEED, because
-- feed cancels when both options fill the same slot. It does not cancel when the question
-- is whether to keep the animal at all, so a pig herd past its 24-month peak, eating and
-- producing little but manure, read "Keep animals" while losing money every month.
--
-- THIS ASKS THE SALE-AGE SEARCH FOR EVERY BREED -- no `declines` gate, unlike sellAgesFor --
-- and FROM THE HERD'S CURRENT AGE, because it is about the animals in the barn now rather
-- than a standing rotation. The OLDEST cluster of a breed answers for it: it is the one
-- whose sale falls due first, and the one past any peak. Priced at its CURRENT health, so
-- a sick herd is told to wait (feeding first is worth more than selling at 40% of book).
--
-- Returns breed name -> { keep, sellNow, bestAge, monthsUntil }, or nil. Memoised like
-- sellAgesFor and for the same reason.
HusbandryRedux._producerSaleMemo = setmetatable({}, { __mode = "k" })

function HusbandryRedux.producerSaleFor(placeable, a)
    if placeable == nil or type(a) ~= "table" or AnimalAdvisor == nil
       or AnimalAdvisor.saleAge == nil or AnimalAdvisor.bind == nil or AnimalEconomics == nil then
        return nil
    end
    local oldest, count = {}, {}
    for _, c in ipairs(a.clusters or {}) do
        if c.name ~= nil and c.cluster ~= nil then
            count[c.name] = (count[c.name] or 0) + (c.count or 0)
            local o = oldest[c.name]
            if o == nil or (c.age or 0) > (o.age or 0) then oldest[c.name] = c end
        end
    end
    if next(oldest) == nil then return nil end

    local now = (getTimeSec ~= nil) and getTimeSec() or nil
    local memo = HusbandryRedux._producerSaleMemo[placeable]
    if memo ~= nil and now ~= nil and (now - memo.t) < HusbandryRedux.SELL_AGE_MEMO_SEC then
        return memo.v
    end

    local feedPA, eff = HusbandryRedux.saleInputsFor(placeable, a)
    local out = {}
    for name, c in pairs(oldest) do
        local hp = tonumber(c.healthPct)
        local sa = HusbandryRedux.saleAgeOfCluster(placeable, c, feedPA, eff, c.age or 0,
                                                    (hp ~= nil) and (hp / 100) or 1, count[name])
        if sa ~= nil then
            out[name] = { keep = (sa.keepIndefinitely == true), sellNow = (sa.sellNow == true),
                          bestAge = sa.bestAge, monthsUntil = sa.monthsUntilSale }
        end
    end
    if now ~= nil then HusbandryRedux._producerSaleMemo[placeable] = { t = now, v = out } end
    return out
end

---THE ROTATING-HERD GUIDANCE for a barn's assessment: breed name -> { sell, cycle, start,
-- count, peakAge, ... }. Moved here from the Herd Inspector so the Pigs tab's Advice
-- column and the panel's sell order note use one set of figures.
--
-- `placeable` IS OPTIONAL. Given one, a breed whose value DECLINES (cows) rotates at its
-- best SALE age from sellAgesFor rather than at peak, and a breed the search says to keep
-- carries `keep = true` and no sell order. Without it -- and for every non-declining breed
-- with it -- this is exactly the peak-age rotation it always was.
function HusbandryRedux.rotationOf(a, placeable)
    -- A ROTATING HERD, SOLD AT PEAK AGE (author, 2026-09-14, option A).
    --
    -- Every animal breeds from its minimum age and is sold when it reaches peak value,
    -- which is also what a sell order does: it takes the animals past or at peak first,
    -- then the oldest. So the herd settles into one cohort per breeding cycle, each
    -- living from birth to peak age:
    --   cohorts   L = ceil(peakAge / cycle)        (pigs: 24 / 4 = 6)
    --   per cycle A = floor(pen share / L)         (a 50-head pigsty: 8)
    -- and A is sold every cycle -- the cohort that reaches peak, or while the herd is
    -- still settling the oldest -- so A newborns have room. Each new cohort needs only A
    -- slots however many breeders there are, so this never sells the herd away.
    --
    -- WHEN TO START: if the next births fit the free slots, when the oldest reach peak
    -- age; otherwise the month before those births, or they would be destroyed (11.5). The next births come from the soonest-due breeding cohort, or, for a herd
    -- still too young, when its oldest reach breeding age and complete one cycle.
    local capacity = (a ~= nil and tonumber(a.capacity)) or 0
    local animals = (a ~= nil and tonumber(a.animals)) or 0
    local free = (a ~= nil and tonumber(a.free)) or 0
    local rot = {}
    for _, c in ipairs((a ~= nil and a.clusters) or {}) do
        if c.name ~= nil then
            local e = rot[c.name]
            if e == nil then e = { count = 0 }; rot[c.name] = e end
            e.count = e.count + (c.count or 0)
            if type(c.peakAge) == "number" and (e.peakAge == nil or c.peakAge < e.peakAge) then
                e.peakAge = c.peakAge
            end
            if type(c.cycleMonths) == "number" and c.cycleMonths > 0 then e.cycle = c.cycleMonths end
            if type(c.age) == "number" and (e.oldest == nil or c.age > e.oldest) then e.oldest = c.age end
            local birth = nil
            if c.willBreed then e.breeders = (e.breeders or 0) + (c.count or 0) end
            if c.tooYoung then e.young = (e.young or 0) + (c.count or 0) end
            if c.willBreed and type(c.dueInMonths) == "number" then
                birth = c.dueInMonths
            elseif c.tooYoung and type(c.cycleMonths) == "number" then
                local st = (AnimalHerdData ~= nil and AnimalHerdData.subTypeOf ~= nil)
                           and AnimalHerdData.subTypeOf(c.subTypeIndex) or nil
                local minAge = st ~= nil and tonumber(st.reproductionMinAgeMonth) or nil
                if minAge ~= nil then birth = math.max(0, minAge - (c.age or 0)) + c.cycleMonths end
            end
            if birth ~= nil and (e.nextBirth == nil or birth < e.nextBirth) then e.nextBirth = birth end
        end
    end
    local ages = (placeable ~= nil) and HusbandryRedux.sellAgesFor(placeable, a) or nil
    for name, e in pairs(rot) do
        -- THE AGE A COHORT IS SOLD AT: peak, unless the sale-age search says otherwise
        local sellAge = e.peakAge
        local o = (ages ~= nil) and ages[name] or nil
        if o ~= nil then
            if o.keep then
                e.keep, sellAge = true, nil
            elseif type(o.age) == "number" and o.age > 0 then
                e.sellAge, sellAge = o.age, o.age
            end
        end
        if sellAge ~= nil and e.cycle ~= nil and sellAge > 0 and capacity > 0 then
            local cohorts = math.max(1, math.ceil(sellAge / e.cycle))
            local share = capacity
            if animals > 0 then share = capacity * e.count / animals end
            local per = math.max(1, math.floor(share / cohorts))
            -- the next births fit the free slots: the first sale waits for the oldest
            -- to reach peak; they do not: it falls due the month before they land
            local due = e.breeders or 0
            if due <= 0 then due = e.young or 0 end
            local start = nil
            if e.nextBirth ~= nil and free < due then
                start = math.max(0, e.nextBirth - 1)
            else
                start = math.max(0, sellAge - (e.oldest or 0))
            end
            if start ~= nil then e.sell, e.start = per, start end
        end
    end
    return rot
end

---A SELL ORDER THAT RUNS BEFORE THE BIRTHS (author, 2026-09-14), appended under the
-- "births lost" line so the player knows not all of those births will be lost.
-- Births land the moment a new month begins; a sell order runs within the hour of
-- its due month starting -- so an order counts only if it falls due in an EARLIER
-- month than the births. The soonest such order is named. nil when nothing is being
-- lost, when no order runs in time, or when the Auto Trader is off (orders stand
-- down then).
-- IN LINE WITH THE GUIDANCE (second return) when the order sells exactly what the Pigs
-- tab advises -- the barn's advised animals per cycle, summed over its breeds, on the
-- advised cycle. The panel then shows the whole line green: the loss is being handled.
---Returns the note text and whether the order matches the guidance, or nil.
function HusbandryRedux.saleBeforeBirthsNote(a, uid, placeable)
    if type(a) ~= "table" or uid == nil or AnimalSellSchedule == nil
       or AnimalSellSchedule.forBarn == nil or AnimalBuySchedule == nil then
        return nil
    end
    if AnimalSettings ~= nil and AnimalSettings.autoTraderEnabled ~= nil
       and not AnimalSettings.autoTraderEnabled() then
        return nil
    end
    local months, _, lost = HusbandryRedux.nextBirths(a)
    if months == nil or (lost or 0) <= 0 then return nil end
    local now = AnimalBuySchedule.currentMonth()
    if type(now) ~= "number" then return nil end
    local best = nil
    for _, s in ipairs(AnimalSellSchedule.forBarn(uid) or {}) do
        if s.enabled ~= false and not AnimalSellSchedule.isFinished(s) and type(s.nextMonth) == "number" then
            local d = math.max(0, s.nextMonth - now)
            if d < months and (best == nil or d < best.d) then best = { d = d, s = s } end
        end
    end
    if best == nil then return nil end
    local n = best.s.count or 0
    if type(a.animals) == "number" and a.animals < n then n = a.animals end
    if n <= 0 then return nil end

    local advised, cycle = 0, nil
    for _, e in pairs(HusbandryRedux.rotationOf(a, placeable) or {}) do
        if e.sell ~= nil then
            advised = advised + e.sell
            if cycle == nil or (e.cycle or cycle) < cycle then cycle = e.cycle end
        end
    end
    local inLine = advised > 0 and cycle ~= nil
                   and best.s.count == advised and best.s.everyMonths == cycle

    local L = HusbandryRedux.l10n
    if best.d == 0 then
        return string.format(L("ar_adv_birth_saleNow", "Selling %d now"), n), inLine
    end
    return string.format(L("ar_adv_birth_saleIn", "Selling %d in %d mo"), n, best.d), inLine
end

---THE HERD VALUE LINE: is the barn making or losing money, and if losing, the fix that
-- recovers the most (author, 2026-09-14).
--
-- The profit is the panel's own CURRENT figure (AnimalEconomics.barnProfit), so this
-- line and the profit block beside it cannot disagree about the sign.
--
-- HEALTH FIRST, then THE BIGGER OF THE TWO MONEY LEVERS. A barn losing money is losing it
-- to costs, and destroyed births only ever take a gain away -- so "make room for births"
-- is not the answer just because a birth will be lost. The two levers are compared in
-- money per month:
--   feedSaving  the measured feed bill less the target ration's cost -- what switching
--               feed saves (pig food is charged at its own price, so a barn living on it
--               shows a large saving)
--   birthsGain  prospective profit less current: what making room for the births is worth
-- Then an incomplete ration, low productivity, animals past peak, and the plain fact.
--
-- `ctx` = { profit, health, productivity, prodApplies, factor, lostNext, pastPeak,
--           feedSaving, switchTitle, birthsGain, outputs }
HusbandryRedux.VALUE_LEVER_MIN = 1       -- a lever worth less than this per month is not advice

function HusbandryRedux.valueAdvice(ctx)
    if type(ctx) ~= "table" or type(ctx.profit) ~= "table" then return nil end
    local per = ctx.profit.perMonth
    if type(per) ~= "number" then return nil end
    local L = HusbandryRedux.l10n
    if per >= 0 then
        return { text = L("ar_adv_value_gain", "Running at a profit"), tone = "good" }
    end
    local function loss(key, fallback, arg)
        local t = L(key, fallback)
        if arg ~= nil then t = string.format(t, arg) end
        return { text = t, tone = "bad" }
    end
    local gate = (AnimalAdvisor ~= nil and AnimalAdvisor.BREED_HEALTH) or 0.75
    if type(ctx.health) == "number" and ctx.health < gate then
        return loss("ar_adv_value_loss_health", "Loss - feed a full ration to restore health")
    end

    local minLever = HusbandryRedux.VALUE_LEVER_MIN
    local feed = (type(ctx.feedSaving) == "number" and ctx.switchTitle ~= nil) and ctx.feedSaving or 0
    local births = 0
    if (ctx.lostNext or 0) > 0 and type(ctx.birthsGain) == "number" then births = ctx.birthsGain end
    if feed >= minLever and feed >= births then
        return loss("ar_adv_value_loss_switch", "Loss - switch to %s feed to reduce input cost", ctx.switchTitle)
    end
    if births >= minLever then
        return loss("ar_adv_value_loss_births", "Loss - sell animals to make room for births")
    end

    local met = (AnimalAdvisor ~= nil and AnimalAdvisor.MET_TARGET) or 0.99
    if type(ctx.factor) == "number" and ctx.factor < met and (ctx.outputs or 0) > 0 then
        return loss("ar_adv_value_loss_ration", "Loss - complete the ration to raise output")
    end
    if ctx.prodApplies ~= false and type(ctx.productivity) == "number" and ctx.productivity < 0.9 then
        return loss("ar_adv_value_loss_productivity", "Loss - improve productivity to sell more output")
    end
    if ctx.pastPeak then
        return loss("ar_adv_value_loss_pastPeak", "Loss - sell animals past peak value")
    end
    return loss("ar_adv_value_loss", "Loss - feed costs more than the herd earns")
end

---THE FEED LINE, once the target ration is known (author, 2026-09-14).
--
-- RECOVER leaves the line to feedAdvice, which already says what is missing from a full
-- ration. MAINTAIN says whether the trough is richer than it needs to be, short of the
-- ration that holds health, or right on it. A trough below the health floor also stays
-- with feedAdvice, whose falling / frozen warning outranks a saving.
---Returns { text, tone } or nil to leave the line as it is.
function HusbandryRedux.maintainFeedText(target, phase, factor)
    if phase ~= "MAINTAIN" or type(target) ~= "table" or type(target.f) ~= "number"
       or type(factor) ~= "number" then
        return nil
    end
    local floor = (AnimalAdvisor ~= nil and AnimalAdvisor.FEED_FLOOR) or 0.28
    if factor < floor then return nil end
    local L = HusbandryRedux.l10n
    -- the FOOD GROUPS, not the products (author, 2026-09-14)
    local name = target.groupTitle or target.productTitle or target.title or "?"
    if factor > target.f + 0.02 then
        return { text = string.format(L("ar_adv_feed_maintainCheaper",
            "Health 100%% - feed %s to hold it for less cost"), name), tone = "warn" }
    end
    if factor < target.f - 0.02 then
        return { text = string.format(L("ar_adv_feed_maintainAdd",
            "Feed %s to hold health at 100%%"), name), tone = "warn" }
    end
    return { text = string.format(L("ar_adv_feed_maintainOk",
        "Health 100%% - %s holds it at the lowest cost"), name), tone = "good" }
end

-- ---------------------------------------------------------------------------
function HusbandryRedux.husbandryPanel(placeable)
    if placeable == nil or AnimalFeedModel == nil then return nil end
    if placeable.spec_husbandryFood == nil then return nil end
    local out = {}
    -- Carried from the feed block to the profit block below, where the cluster
    -- rows the economic adviser needs finally exist.
    local advisorBits = nil
    -- The target ration (full while recovering, cheapest that holds health once at 100%)
    -- and the barn's measured feed bill, kept for the FEED and HERD VALUE lines.
    local advisorTarget, advisorPhase, advisorNowCost = nil, nil, nil

    -- ---- herd ---------------------------------------------------------------
    local clusters = nil
    if placeable.getClusters ~= nil then
        local ok, c = pcall(placeable.getClusters, placeable)
        if ok and type(c) == "table" then clusters = c end
    end
    local herd = {}
    local ati0 = AnimalFeedModel.animalTypeIndexOf(placeable)
    if placeable.getNumOfAnimals ~= nil then
        local ok, v = pcall(placeable.getNumOfAnimals, placeable); if ok then herd.count = v end
    end
    if placeable.getMaxNumOfAnimals ~= nil then
        local ok, v = pcall(placeable.getMaxNumOfAnimals, placeable); if ok then herd.max = v end
    end
    if clusters ~= nil and AnimalHerdData ~= nil and AnimalHerdData.herdHealthFactor ~= nil then
        -- animal-WEIGHTED mean, already 0..1; a cluster of 40 must not count the
        -- same as a cluster of 1
        --
        -- Asked of AnimalHerdData DIRECTLY. It used to go through a delegate on
        -- HusbandryReduxPage that did nothing but forward here, which is what let the
        -- old page be retired without moving any logic -- but a GUI page was never
        -- the right thing for a data module to ask.
        local ok, h = pcall(AnimalHerdData.herdHealthFactor, clusters)
        if ok then herd.health = h end
    end
    -- PRODUCTIVITY, the base game's own headline: globalProductionFactor x
    -- productionFactor, exactly as PlaceableHusbandryAnimals:getConditionInfos
    -- computes it. NOT the food factor -- food is one input to it, so a barn can be
    -- perfectly fed and still sit at 15%, which is precisely the case this bar
    -- exists to show.
    if placeable.getGlobalProductionFactor ~= nil and placeable.getProductionFactor ~= nil then
        local okG, gf = pcall(placeable.getGlobalProductionFactor, placeable)
        local okP, pf = pcall(placeable.getProductionFactor, placeable)
        if okG and okP and type(gf) == "number" and type(pf) == "number" then
            herd.productivity = gf * pf
        end
    end
    -- the base game HIDES this for horses and pigs (they do not produce continuously),
    -- so it is flagged rather than presented as a confident zero
    if AnimalType ~= nil and ati0 ~= nil then
        herd.prodApplies = (ati0 ~= AnimalType.HORSE and ati0 ~= AnimalType.PIG)
    end
    out.herd = herd

    -- ---- value --------------------------------------------------------------
    -- CURRENT is what the herd would fetch right now; POTENTIAL is what the same
    -- animals would fetch at PEAK AGE and full health. Both terms are exact rather
    -- than modelled: sellPrice = curve(ageMonths) x (0.40 + 0.60 x health), measured
    -- to the cent on three animals at two health levels, and AnimalSellRules.priceCurve
    -- already samples each subtype's curve once and caches its peak.
    --
    -- getSellPrice is PER ANIMAL, so both terms multiply by the cluster count.
    if clusters ~= nil and #clusters > 0 then
        local cur, pot, pastPeak, sawCurve = 0, 0, false, false
        for _, cl in pairs(clusters) do
            local n = cl.numAnimals or 0
            if n > 0 then
                local each = nil
                if cl.getSellPrice ~= nil then
                    local ok, v = pcall(cl.getSellPrice, cl)
                    if ok and type(v) == "number" then each = v end
                end
                if each ~= nil then cur = cur + each * n end

                local curve = nil
                if AnimalSellRules ~= nil and AnimalSellRules.priceCurve ~= nil then
                    local ok, c = pcall(AnimalSellRules.priceCurve, cl)
                    if ok then curve = c end
                end
                if curve ~= nil and type(curve.peakPrice) == "number" then
                    pot = pot + curve.peakPrice * n
                    sawCurve = true
                    -- ONLY COWS DECLINE (measured), and the curve is asked rather than
                    -- the species so a modded animal answers for itself. Past peak the
                    -- value falls every month and holding gains nothing, which is a
                    -- different message from "feed them better".
                    if curve.declines and curve.peakAge ~= nil and (cl.age or 0) > curve.peakAge then
                        pastPeak = true
                    end
                elseif each ~= nil then
                    -- no curve for this subtype: fall back to the HEALTH ceiling alone,
                    -- so the bar still means something rather than the whole barn
                    -- dropping out because one cluster could not be sampled
                    local hf = 0.40 + 0.60 * ((cl.health or 0) / 100)
                    if hf > 0 then pot = pot + (each / hf) * n end
                end
            end
        end
        if cur > 0 or pot > 0 then
            out.value = { current = cur, potential = pot, pastPeak = pastPeak }
        end
        -- sawCurve is deliberately unused beyond documenting intent: a mixed barn where
        -- some subtypes sampled and others did not still reports a coherent total.
    end

    -- ---- feed ---------------------------------------------------------------
    -- HOISTED so the profit block below can reach them: the ration is the barn's
    -- largest running cost and it is resolved exactly once, here, rather than a
    -- second time from a second read of the trough.
    local feedModel, feedAvail, feedDemand = nil, nil, nil
    local ati = AnimalFeedModel.animalTypeIndexOf(placeable)
    if ati ~= nil then
        local spec = placeable.spec_husbandryFood
        local model = AnimalFeedModel.read(ati, spec.supportedFillTypes)
        if model ~= nil then
            local demand = AnimalFeedModel.demandPerHour(placeable)
            local everyFt = {}
            for _, g in ipairs(model.groups) do
                for _, ft in ipairs(g.fts) do everyFt[#everyFt + 1] = ft end
            end
            local trough = AnimalFeedModel.availableOf(placeable, everyFt)
            feedModel, feedAvail, feedDemand = model, trough, demand

            -- factorOf, NEVER measureFactor. measureFactor is a DESTRUCTIVE probe: it zeroes the
            -- barn's real spec.fillLevels, substitutes a mix, calls animalFoodSystem:consumeFood --
            -- which actually feeds the herd -- and then restores the levels. That is exactly right
            -- for a console probe run on demand, and exactly wrong on a menu populate that runs on
            -- every selection AND on the page's timed refresh: it would drive the engine's own
            -- consumption path several times a second for as long as the tab is open.
            --
            -- factorOf is pure arithmetic over the same trough and needs no such trick, and it is
            -- not a lesser answer: its best-first weighted average was measured against the engine
            -- with arFeedPartial and reproduces it (3.6), including the partial-forage case a
            -- max-of-tiers model gets wrong.
            local factor = nil
            if demand > 0 then
                local ok, f = pcall(AnimalFeedModel.factorOf, model, trough, demand)
                if ok and type(f) == "number" then factor = f end
            end

            local serial = model.consumptionType == "SERIAL"
            local eatSum = 0
            for _, g in ipairs(model.groups) do eatSum = eatSum + g.eat end

            local groups, active, activeShare = {}, nil, -1
            for i, g in ipairs(model.groups) do
                local held = 0
                for _, ft in ipairs(g.fts) do held = held + (trough[ft] or 0) end
                local need = 0
                if demand > 0 then
                    if serial then need = demand
                    elseif eatSum > 0 then need = demand * g.eat / eatSum end
                end
                local met = 1
                if need > 0 then met = math.min(1, held / need) end
                groups[#groups + 1] = {
                    -- `fts` is for feedAdvice, which needs the PRODUCTS to name them.
                    -- DR's sanitiser drops it, so the contract is unchanged.
                    title = g.title, share = g.production, met = met,
                    held = held, need = need, colourIndex = i, fts = g.fts,
                }
                -- SERIAL: the ACTIVE tier is the best one actually present, which is
                -- the single thing that sets the factor. Named on the panel so the
                -- bar says which tier you are on rather than only how high it is.
                if serial and held > 0 and g.production > activeShare then
                    active, activeShare = g.title, g.production
                end
            end

            out.feed = {
                factor = factor, serial = serial, activeTitle = active,
                -- a meadow feeds outside the trough, so every group can read 0 L while
                -- the factor is well above zero; DR says so on the panel rather than
                -- leaving the contradiction on screen
                grazes = placeable.spec_husbandryMeadow ~= nil,
                groups = groups,
            }
            -- WHAT TO FEED NEXT, from the same groups the bar above it draws, so the
            -- sentence and the bar cannot disagree about which tier is short.
            --
            -- OMITTED, NOT BLANKED, when the Herd Adviser is off. DR's panel renderer
            -- already blanks the line for a nil advice table, so simply not filling it
            -- IS the suppression and DR needs no change at all. It also means the
            -- advice is never COMPUTED, which is the other half of the point --
            -- feedAdvice walks every group to decide what to say.
            --
            -- ASSIGNED AFTER THE CONSTRUCTOR rather than as a conditional field.
            -- `cond and f() or nil` would be correct here by luck, because f returns
            -- a table or nil and nil is the wanted fallback either way -- but this
            -- codebase has been bitten twice by that collapse (DR 5.44 / 5.46c) and
            -- an if is not worth arguing about. It also reads the same way as the
            -- herd advice below, which is the other half of this switch.
            if AnimalSettings == nil or AnimalSettings.herdAdviserEnabled() then
                out.feed.advice = HusbandryRedux.feedAdvice(groups, serial, factor,
                                                         placeable.spec_husbandryMeadow ~= nil,
                                                         out.herd ~= nil and out.herd.health or nil)
                -- STASHED FOR THE ECONOMIC ADVISER, which needs the cluster rows and
                -- so cannot run until the plan block below has them. `model`,
                -- `demand` and `factor` are locals of THIS block and would be out of
                -- scope down there; carrying them is cheaper and safer than reading
                -- the feed model a second time and risking two answers.
                -- `trough` here is AnimalFeedModel.availableOf -- trough PLUS the
                -- meadow -- which is exactly the `avail` feedCostPerHour wants.
                -- The local's name is the misleading part, not the value.
                advisorBits = { model = model, demandPerHour = demand, factor = factor,
                                avail = trough }
            end
        end
    end

    -- ---- profit --------------------------------------------------------------
    -- WHAT THE BARN MAKES, per month:
    --     increase in animal value + outputs sold - inputs bought
    --
    -- EVERY TERM COMES FROM SOMEWHERE THAT ALREADY OWNS IT, and none is
    -- recomputed here. AnimalSellRules.assess supplies the per-cluster picture
    -- (output value, straw and water, the price-curve drift, the breeding gates
    -- and what a newborn is worth); AnimalEconomics.summarise weights it by
    -- HEADCOUNT; AnimalEconomics.feedCostPerHour prices the ration off the same
    -- tier rule this panel names its active group by. The composition is
    -- AnimalEconomics.barnProfit and nothing about it lives in this file.
    --
    -- WHY assess RATHER THAN THE VALUE LOOP ABOVE: births need the free-slot
    -- allocation that decides which calves a full pen destroys, and that rule
    -- belongs to the plan. Rebuilding it here to save one walk of the clusters is
    -- how the panel and the Animals tab come to disagree about the same barn.
    if AnimalSellRules ~= nil and AnimalSellRules.plan ~= nil
       and AnimalEconomics ~= nil and AnimalEconomics.barnProfit ~= nil then
        -- PLAN, NOT assess -- and it costs no more, because plan calls assess itself
        -- and hands it back. It is also what makes the birth advice below agree with
        -- the Animals tab instead of being a second opinion about one pen.
        local okA, pl = pcall(AnimalSellRules.plan, placeable)
        local a = (okA and type(pl) == "table") and pl.assess or nil
        if type(a) == "table" and type(a.clusters) == "table" then
            if out.herd ~= nil and (AnimalSettings == nil or AnimalSettings.herdAdviserEnabled()) then
                -- ONLY THE NEXT BIRTHS (author, 2026-09-14). The sale-age and health
                -- overrides that used to replace this line no longer do.
                out.herd.advice = HusbandryRedux.nextBirthsAdvice(a)
                -- a sell order due before those births, on the line below
                if out.herd.advice ~= nil and out.herd.advice.tone == "warn" then
                    local SDu = HusbandryRedux.DR
                    local barnUid = (SDu ~= nil and SDu.assetUid ~= nil) and SDu.assetUid(placeable)
                                    or tostring(placeable)
                    local okN, note, inLine = pcall(HusbandryRedux.saleBeforeBirthsNote, a, barnUid, placeable)
                    if okN and note ~= nil then
                        -- an order that follows the guidance is handling the loss: green
                        if inLine then out.herd.advice.tone = "good" end
                        out.herd.advice.text = out.herd.advice.text .. "\n" .. note
                    end
                end

                -- THE ECONOMIC ADVISERS (AnimalAdvisor), which could not run in the
                -- feed block because they need these cluster rows.
                --
                -- BOTH ARE OVERRIDES, NOT REPLACEMENTS, and they only speak when
                -- they have something the existing line does not:
                --   * the FEED line becomes the profit-ranked ration instead of
                --     "provide X to raise productivity" -- the whole point of the
                --     rewrite, since the old line always pushed toward factor 1.0
                --     whether or not the extra feed paid for itself;
                --   * the HERD line is left to birthAdvice except where health is
                --     below the breeding gate, which birthAdvice can only report as
                --     "nothing is breeding" (recommend.lua's first rule -- one herd
                --     must not get two opinions).
                --
                -- ANY FAILURE LEAVES THE EXISTING LINES EXACTLY AS THEY WERE. The
                -- adviser is additive by construction: it is pcall'd, it returns nil
                -- rather than guessing when a collaborator is missing, and nothing
                -- is assigned unless a rendered table comes back.
                if AnimalAdvisor ~= nil and advisorBits ~= nil then
                    -- THE HEADCOUNT IS SUMMED FROM THE ROWS rather than read off a
                    -- field of `assess`: these are the rows the adviser prices, so
                    -- summing them cannot disagree with what it charged for.
                    -- ASSESS ROWS CARRY `subTypeIndex` AND `name`, NOT `subType`.
                    -- Reading `cl.subType` gave nil, so outputValuePerMonth returned
                    -- nil on its first line and every ration was valued at ZERO --
                    -- which read as "outputs do not cover feed" on EVERY pen, and
                    -- left the breed nil so the PRODUCER/BREEDER purpose never
                    -- resolved either. One wrong field, three broken things.
                    -- Reported 2026-09-10; see 36b.
                    local rows, head, top, topN = {}, 0, nil, -1
                    local topCluster, topSubType = nil, nil
                    for _, cl in ipairs(a.clusters) do
                        local n = cl.count or 0
                        local st = nil
                        if AnimalEconomics ~= nil and AnimalEconomics._subTypeOf ~= nil then
                            local okS, v = pcall(AnimalEconomics._subTypeOf, cl.subTypeIndex)
                            if okS and type(v) == "table" then st = v end
                        end
                        rows[#rows + 1] = { count = n, age = cl.age,
                                            subType = st,
                                            subTypeIndex = cl.subTypeIndex }
                        head = head + n
                        if n > topN then topCluster = cl.cluster end
                        -- THE PANEL HAS ONE LINE AND A BARN MAY HOLD SEVERAL BREEDS,
                        -- so the purpose is looked up for the DOMINANT one. The
                        -- per-breed answer lives on the Herd Inspector, which has a
                        -- row each; inventing a blended purpose here would be a
                        -- third opinion neither screen holds.
                        -- `cl.name` is the breed, already resolved by assess.
                        if n > topN and cl.name ~= nil then
                            top, topN, topSubType = cl.name, n, st
                        end
                    end

                    -- The uid exactly as AnimalHerdData resolves it (:184), so the
                    -- policy this reads is the one the player set on that screen.
                    -- `HusbandryRedux.DR`, NOT a bare `SD`: that name is a parameter
                    -- in one function and a local in another, and is not in scope
                    -- here -- it would read as a nil global and fall silently back
                    -- to an ADDRESS, which can never match the stored policy key
                    -- (the 5.44 shape, and luac cannot see it).
                    local DR = HusbandryRedux.DR
                    local uid = (DR ~= nil and DR.assetUid ~= nil)
                                and DR.assetUid(placeable) or tostring(placeable)

                    -- THE BARN'S MEASURED FEED BILL, so "am I already on the best
                    -- ration" is judged against what the trough ACTUALLY costs --
                    -- which on a grazing pen is a fraction of the hypothetical
                    -- price, because feedCostPerHour charges only the trough's
                    -- share of what is available.
                    local nowCost = nil
                    if AnimalEconomics ~= nil and AnimalEconomics.feedCostPerHour ~= nil
                       and advisorBits.model ~= nil then
                        local okC, fc = pcall(AnimalEconomics.feedCostPerHour, placeable,
                                              advisorBits.model, advisorBits.avail,
                                              advisorBits.demandPerHour)
                        if okC and type(fc) == "table" and type(fc.perHour) == "number" then
                            local dpm = 1
                            if AnimalEconomics.daysPerMonth ~= nil then
                                local okD, d = pcall(AnimalEconomics.daysPerMonth)
                                if okD and type(d) == "number" then dpm = d end
                            end
                            nowCost = fc.perHour * 24 * dpm
                        end
                    end

                    -- WHICH PRODUCT IS ACTUALLY IN THE TROUGH -- the dearest of
                    -- the model's own products that the barn is holding, since
                    -- that is the one a switch would replace. Without it the
                    -- adviser has to guess the current ration from the FACTOR,
                    -- which cannot tell a sheep's grass from its hay.
                    local curFt = nil
                    do
                        local held, av = -1, advisorBits.avail or {}
                        for _, g in ipairs((advisorBits.model or {}).groups or {}) do
                            for _, ft in ipairs(g.fts or {}) do
                                local l = av[ft]
                                if type(l) == "number" and l > 0 and l > held then
                                    held, curFt = l, ft
                                end
                            end
                        end
                    end

                    local ctx = AnimalAdvisor.bind{
                        model = advisorBits.model,
                        demandPerHour = advisorBits.demandPerHour,
                        factor = advisorBits.factor,
                        currentCostPerMonth = nowCost,
                        currentFillType = curFt,
                        rows = rows, uid = uid, breed = top,
                        -- the same stock the planner ranks by, so the advice names the
                        -- ration DR is actually being asked for
                        stockOf = HusbandryRedux.stockFnFor(placeable),
                    }
                    -- NO LONGER THE FEED LINE (2026-09-14): the feed line follows the
                    -- TARGET RATION instead -- the same rule the planner feeds by.
                    advisorNowCost = nowCost
                    local okTR, tgt, phase = pcall(AnimalAdvisor.targetRation, ctx,
                                                   out.herd ~= nil and out.herd.health or nil)
                    if okTR and type(tgt) == "table" then
                        advisorTarget, advisorPhase = tgt, phase
                        local t = HusbandryRedux.maintainFeedText(tgt, phase,
                            out.feed ~= nil and out.feed.factor or nil)
                        if t ~= nil and out.feed ~= nil then out.feed.advice = t end
                    end

                    -- THE SALE-AGE HERD ADVISER NO LONGER WRITES THE HERD LINE
                    -- (2026-09-14): that line states only whether the next births fit,
                    -- and the breed list carries the per-breed sell order instead.
                end
            end
            local okS, sum = pcall(AnimalEconomics.summarise, a.clusters)
            if okS and type(sum) == "table" then
                -- NIL, NOT ZERO, when the ration cannot be priced: a barn whose
                -- feed has no market value does not have a free one.
                local feedPerMonth = nil
                if feedModel ~= nil and AnimalEconomics.feedCostPerHour ~= nil then
                    local okF, fc = pcall(AnimalEconomics.feedCostPerHour,
                                          placeable, feedModel, feedAvail, feedDemand)
                    if okF and type(fc) == "table" and (fc.unpriced or 0) == 0 then
                        local days = AnimalEconomics.daysPerMonth()
                        feedPerMonth = fc.perHour * 24 * days
                    end
                end
                -- THE BEDDING AND WATER BILL IS THE BUILDING'S, NOT THE CLUSTERS'.
                -- It used to be rolled up per animal, which charged straw whether or
                -- not the barn held any -- and the inputs table beside this showed
                -- the same straw at zero, so one hour read -31 here and -24 there.
                -- Both now come from the same availability-gated function.
                local declPerMonth = nil
                if AnimalEconomics.declaredInputCostPerHour ~= nil then
                    local okD, dc = pcall(AnimalEconomics.declaredInputCostPerHour,
                                          placeable, a.clusters)
                    if okD and type(dc) == "table" and (dc.unpriced or 0) == 0 then
                        declPerMonth = dc.perHour * 24 * AnimalEconomics.daysPerMonth()
                    end
                end
                local okP, pr = pcall(AnimalEconomics.barnProfit, sum, feedPerMonth, declPerMonth)
                if okP and type(pr) == "table" then out.profit = pr end

                -- THE HERD VALUE LINE: profit or loss, and for a loss the best fix.
                if out.profit ~= nil and (AnimalSettings == nil or AnimalSettings.herdAdviserEnabled()) then
                    local _, _, lostNext = HusbandryRedux.nextBirths(a)
                    -- WHAT A SWITCH TO THE TARGET RATION SAVES: the barn's measured bill
                    -- (pig food charged at its own price, AnimalFeedModel.MixLedger) less
                    -- what the target ration costs.
                    local feedSaving, switchTitle = nil, nil
                    if advisorTarget ~= nil and type(advisorNowCost) == "number"
                       and type(advisorTarget.costPerMonth) == "number" then
                        feedSaving = advisorNowCost - advisorTarget.costPerMonth
                        switchTitle = advisorTarget.groupTitle or advisorTarget.productTitle
                    end
                    local birthsGain = nil
                    if type(out.profit.perMonthProspective) == "number" and type(out.profit.perMonth) == "number" then
                        birthsGain = out.profit.perMonthProspective - out.profit.perMonth
                    end
                    local okV, va = pcall(HusbandryRedux.valueAdvice, {
                        profit = out.profit,
                        health = herd.health, productivity = herd.productivity,
                        prodApplies = herd.prodApplies,
                        factor = out.feed ~= nil and out.feed.factor or nil,
                        lostNext = lostNext,
                        pastPeak = out.value ~= nil and out.value.pastPeak or false,
                        feedSaving = feedSaving, switchTitle = switchTitle,
                        birthsGain = birthsGain,
                        outputs = out.profit.outputs,
                    })
                    if okV and va ~= nil then
                        out.value = out.value or {}
                        out.value.advice = va
                    end
                end
            end
        end
    end

    if out.herd == nil and out.value == nil and out.feed == nil and out.profit == nil then
        return nil
    end
    return out
end

-- ---------------------------------------------------------------------------
function HusbandryRedux.onMissionLoaded()
    local SD, whereOrWhy, env = HusbandryRedux.resolveDistributionRedux()

    -- NO DR IS NOT A FAILURE ANY MORE. This used to set enabled = false and RETURN, which is what
    -- made every bit of the standalone work unreachable: modDesc's <dependencies> stopped the mod
    -- loading at all, and once that was removed THIS stopped it running. Three layers of one
    -- assumption, each hiding the next -- and only the last of them left a line in the log.
    --
    -- `enabled` is true either way now. It means "this mod is running", NOT "DR is present": the
    -- things that genuinely need DR ask about DR (or better, about the CAPABILITY they need) at the
    -- point of use -- AnimalSettings.capabilityOk and HusbandryRedux.canUseDRMenu.
    HusbandryRedux.DR = SD
    HusbandryRedux.DR_ENV = env          -- DR's whole environment; the GUI page needs
                                      -- DistributionMenuPage, which is not on SmartDistribution.
                                      -- Both are nil when running standalone, which is fine:
                                      -- HerdInspectorPage falls back to AnimalMenuPage.
    HusbandryRedux.enabled = true

    local apiVersion, apiOk = 0, false
    if SD == nil then
        HusbandryRedux.warn("v%s running STANDALONE -- Distribution Redux not found (%s). Feed planning "
            .. "and performance logging need it and are off; everything else works.",
            HusbandryRedux.VERSION, tostring(whereOrWhy))
    else
        apiVersion, apiOk = HusbandryRedux.checkApiVersion(SD)
        HusbandryRedux.warn("v%s linked to Distribution Redux (global '%s', API v%d%s)",
            HusbandryRedux.VERSION, tostring(whereOrWhy), apiVersion,
            apiOk and "" or string.format("; this mod wants v%d+", HusbandryRedux.DR_MIN_API))

        -- DR IS THERE BUT TOO OLD TO HOST THE UI. Said once, plainly, and it names the
        -- missing calls so a report identifies the DR build rather than only its version
        -- string -- which cannot be trusted to (see DR_MIN_API). Nothing is disabled by
        -- this: AR builds its own menu instead and every feature still runs.
        local gaps = HusbandryRedux.drIntegrationGaps()
        if gaps ~= nil and #gaps > 0 then
            HusbandryRedux.warn("Distribution Redux is too old to host Husbandry Redux's screens "
                .. "(API v%d, this mod wants v%d+; missing: %s). Husbandry Redux will use its OWN "
                .. "menu instead -- nothing is lost, and updating Distribution Redux puts the "
                .. "screens back into its menu.",
                apiVersion, HusbandryRedux.DR_MIN_API, table.concat(gaps, ", "))
        end
    end

    -- L10N SELF-TEST. There is no UI yet, so nothing else would reveal a broken
    -- translation chain until the first screen is built -- and by then the cause
    -- (file not packed, wrong filenamePrefix, missing namespace argument) is
    -- tangled up with whatever else that screen does. This resolves one known
    -- key and reports the answer, so the chain is proven end to end before it
    -- carries anything. Costs one table lookup at load.
    local probe = HusbandryRedux.l10n("ar_l10n_selftest", "FALLBACK")
    if probe == "ok" then
        HusbandryRedux.log("l10n OK (translations/translation_en.xml resolved against '%s')",
            HusbandryRedux.MOD_NAME)
    else
        HusbandryRedux.warn("l10n NOT RESOLVING (got '%s'): every string will show its English "
            .. "fallback. Check that translations/ is in the deploy allowlist and that "
            .. "modDesc declares <l10n filenamePrefix=\"translations/translation\"/>.",
            tostring(probe))
    end

    -- TEMPORARY dev probe (arFoodProbe). Registration is separate from the link
    -- itself so a probe failure can never stop the mod loading. Console commands
    -- need game.xml <development><controls>true, so this is unreachable in a
    -- normal install; it still announces itself, because a probe nobody knows
    -- about is a probe nobody runs.
    if HusbandryRedux.DEV_CONSOLE and AnimalFoodProbe ~= nil and AnimalFoodProbe.register ~= nil then
        local okP, registered = pcall(AnimalFoodProbe.register)
        if okP and registered then
            HusbandryRedux.log("dev probes available: arFoodProbe, arFeedPartial, arTradeProbe, arReproProbe, arSellProbe")
        end
    end

    -- THE COMPREHENSIVE TRADE DUMP. Its own registration, not folded into
    -- AnimalFoodProbe, because it exists for one open question (the buy path) and
    -- should be removable the moment that question is closed.
    if HusbandryRedux.DEV_CONSOLE and AnimalTrade ~= nil and AnimalTrade.installConsole ~= nil then
        local okT, reg = pcall(AnimalTrade.installConsole)
        if okT and reg then HusbandryRedux.log("dev probe available: arTradeDump") end
    end

    -- The feed model's own verifier. Registered separately from the probe so
    -- either can be removed without disturbing the other.
    if HusbandryRedux.DEV_CONSOLE and AnimalFeedModel ~= nil and AnimalFeedModel.Console ~= nil then
        local okF, registered = pcall(AnimalFeedModel.Console.register)
        if okF and registered then
            HusbandryRedux.log("dev probe available: arFeedPlan [name fragment]")
        end
    end

    -- ---- FEED PLANNING -----------------------------------------------------
    -- Registered only when DR publishes an API we understand. Without it the mod
    -- still loads and the probes still work; DR simply keeps its own feed logic.
    -- ---- FROM HERE, ONLY WHAT DR CAN HOST ------------------------------------------------------
    -- Each of these registers AR's data or UI INTO DR. With no DR there is nothing to register into,
    -- and the matching feature reports itself off through AnimalSettings.capabilityOk rather than
    -- looking available and quietly doing nothing.
    -- ON THE CALL, NOT ON apiOk. This read `SD ~= nil and apiOk and ...` while
    -- DR_MIN_API was 1, so the version half never bit. Raising it to 9 would have
    -- switched feed planning OFF for every DR older than v9 -- although
    -- registerFeedPlanner has existed since v1 and works perfectly there. The
    -- panel below already had this right; the planner did not.
    if SD ~= nil and SD.API ~= nil and SD.API.registerFeedPlanner ~= nil then
        local okR = pcall(SD.API.registerFeedPlanner, HusbandryRedux.MOD_NAME, HusbandryRedux.feedPlanner)
        HusbandryRedux.feedPlanningActive = okR and true or false
        if okR then
            HusbandryRedux.log("feed planning ACTIVE (Distribution Redux API v%d)", apiVersion)
        else
            HusbandryRedux.warn("feed planner could not be registered; DR keeps its own feed logic")
        end
    elseif SD == nil then
        HusbandryRedux.feedPlanningActive = false      -- standalone: nothing to plan FOR; said so above
    else
        HusbandryRedux.feedPlanningActive = false
        HusbandryRedux.warn("Distribution Redux exposes no feed planner API (found v%d) -- "
            .. "feed planning is INACTIVE and DR keeps its own logic", apiVersion)
    end

    -- ---- THE HUSBANDRY PANEL (DR API v4) ------------------------------------
    -- Registered separately from the feed planner and from the tab: each is an
    -- independent capability, and a DR that is too old for one may still take the
    -- others. Gated on the CALL existing rather than on the version number, so a
    -- DR that adds it in a later build still works without a bump here.
    if SD ~= nil and SD.API ~= nil and SD.API.registerHusbandryPanel ~= nil then
        local okP = pcall(SD.API.registerHusbandryPanel, HusbandryRedux.MOD_NAME,
                          HusbandryRedux.husbandryPanel)
        HusbandryRedux.panelActive = okP and true or false
        if okP then
            HusbandryRedux.log("husbandry panel ACTIVE, embedded in the Animal Husbandry tab")
        else
            HusbandryRedux.warn("husbandry panel could not be registered")
        end
    elseif SD == nil then
        -- The panel still DRAWS on our own page: AnimalPanel is ours now. What is inactive is the
        -- copy DR embeds in ITS Animal Husbandry tab, and there is no such tab without DR.
        HusbandryRedux.panelActive = false
    else
        HusbandryRedux.panelActive = false
        HusbandryRedux.warn("Distribution Redux has no husbandry panel API (needs v4+, found v%d)",
            apiVersion)
    end

    -- ---- THE SETTINGS TAB (DR API v8) ---------------------------------------
    -- Registered here rather than from the menu-ready callback, because the
    -- SETTINGS page is DR's own and already exists: this only adds a row to DR's
    -- tab registry, which the page reads on every open. Doing it now means the
    -- saved values are applied by AnimalPersist a moment later and the first open
    -- already shows them.
    --
    -- GATED ON canUseDRMenu, or a DR with v8 but not v9 would take the settings tab
    -- while the guide fell back to AR's own menu -- one screen in two places, and a
    -- settings page in a different menu from the guide it belongs beside.
    if HusbandryRedux.canUseDRMenu() and AnimalSettings ~= nil and AnimalSettings.install ~= nil then
        HusbandryRedux.settingsTabActive = AnimalSettings.install(SD) and true or false
    else
        HusbandryRedux.settingsTabActive = false      -- it lives on AR's own menu instead
    end

    -- ---- THE USER GUIDE TAB (DR API v9) -------------------------------------
    -- Same timing and the same reason as the settings tab above: the guide PAGE is
    -- DR's and already exists, so this only adds a row to DR's tab registry, which
    -- the page reads on every open.
    if HusbandryRedux.canUseDRMenu() and AnimalHelp ~= nil and AnimalHelp.install ~= nil then
        HusbandryRedux.helpTabActive = AnimalHelp.install(SD) and true or false
    else
        HusbandryRedux.helpTabActive = false          -- it lives on AR's own menu instead
    end

    -- ---- THE OVERVIEW TAB (DR API v13) --------------------------------------
    -- A PLACEHOLDER, deliberately. DR's Overview is the whole-network figures table and AR's
    -- equivalent view is not built yet, so this claims the slot beside it and says so. The
    -- caption is AR's own string: DR cannot resolve another mod's l10n namespace, so a tab
    -- that supplied none would simply show an empty page rather than DR inventing words for
    -- it under AR's name.
    --
    -- Gated on the CALL existing rather than on a version number, the rule every other
    -- surface here follows: a DR too old to have it simply shows no AR overview tab, and
    -- nothing else about the mod changes.
    if HusbandryRedux.canUseDRMenu() and SD ~= nil and SD.API ~= nil
       and SD.API.registerOverviewTab ~= nil then
        local ok, res = pcall(SD.API.registerOverviewTab, "FS25_Husbandry_Redux",
            HusbandryRedux.l10n("ar_overview_tab", "HUSBANDRY REDUX"),
            { placeholder = HusbandryRedux.l10n("ar_overview_placeholder", "Under Construction") })
        HusbandryRedux.overviewTabActive = (ok and res) and true or false
    else
        HusbandryRedux.overviewTabActive = false
    end

    -- ---- THE TAB -------------------------------------------------------------
    -- Deferred to DR's menu-ready callback rather than added here, because DR
    -- builds its menu LATER in this very same hook: mods load alphabetically, so
    -- Husbandry Redux appended to loadMission00Finished first and runs first. At
    -- this moment SmartDistribution._menu does not exist yet.
    --
    -- THERE WERE TWO TABS UNTIL 2026-08-31. HusbandryReduxPage ran beside this one
    -- deliberately -- "the comparison between them IS the acceptance test, so the
    -- old one has to keep working until it is deliberately removed" -- and it has
    -- now been removed on that basis, coverage checked column by column (20.28).
    -- ONE OR THE OTHER, NEVER BOTH. DR's menu hosts the page when DR can; otherwise AR builds its
    -- own. Registering into both would put the same page in two menus and give a player two ways to
    -- reach one screen, which the author ruled out when this split was designed.
    if HusbandryRedux.canUseDRMenu() then
        SD.API.onMenuReady(HusbandryRedux.MOD_NAME, function(menu)
            local ok, why = HerdInspectorPage.install(menu)
            if ok then
                HusbandryRedux.log("Herd Inspector tab added to the Distribution Redux menu")
            else
                HusbandryRedux.warn("Herd Inspector tab NOT added: %s", tostring(why))
            end
        end)
    elseif HusbandryRedux.installStandaloneMenu() then
        -- the key hook is already in place from mod load; building the menu is what arms it
    else
        HusbandryRedux.warn("no menu available: DR cannot host a page and the standalone menu failed")
    end

    -- Features attach from here. Nothing yet -- this build only proves the link.
end

-- ---------------------------------------------------------------------------
-- STANDALONE: AR's OWN MENU
--
-- Built when Distribution Redux cannot host AR's screens: it is absent, OR it is too old to take
-- all three of them (drIntegrationGaps). With a current DR none of this runs and a player with
-- both mods sees no change whatever.
--
-- THE GATE IS THE CAPABILITY, NOT DR'S MERE PRESENCE, and the set has to be the WHOLE UI. It first
-- asked only "can DR host a page", which left a real hole: a DR from between API v3 and v7 took the
-- Herd Inspector and had nowhere to put the settings or the guide, so those two were reachable from
-- NOWHERE -- DR was present, so the own-menu fallback was skipped, and DR could not take them. The
-- question that actually matters is "can anything host ALL of my screens".
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- RESOLUTION-AWARE LAYOUT (ported from DR 6.15)
--
-- Needed the moment AR grew its own menu. DR's API.loadMenuPage wraps every page load in this, so
-- while AR was hosted by DR its pages were widened for free; loading them ourselves is what exposed
-- it. Reported on a 3441x1440 screen: the whole page squeezed into the left ~78% of the width with
-- dead space beside it.
--
-- WHAT IS ACTUALLY HAPPENING, because "px" in a GUI xml is misleading: it is not a display pixel, it
-- is a fraction of a 1920-wide REFERENCE. The engine aspect-scales the whole layout into a 16:9 box
-- and pillarboxes it, so on an ultrawide g_aspectScaleX is about 0.744 and a third of the screen
-- goes unused. This does NOT defeat that scaling -- doing so would stretch every icon -- it widens
-- the DESIGN units so the result fills the screen AFTER scaling.
--
-- ON 16:9 g_aspectScaleX IS EXACTLY 1, the factor is 1, and nothing changes: byte-identical by
-- construction rather than by testing. The >= 1 guard also covers 16:10 and anything narrower, where
-- the reciprocal would SHRINK the tables instead.
--
-- INSTALLED ONLY IN THE STANDALONE PATH. With DR present its hook is already on these globals and
-- AR's pages load through DR's loadMenuPage, so a second hook would apply the factor TWICE.
-- `_layoutScaling` is true only while AR's own page files load and is cleared on every path, so a
-- load error cannot leave it widening the base game's menus for the rest of the session.
HusbandryRedux.LAYOUT_TARGET_WIDTH = 0.84    -- fraction of SCREEN width the widest table should occupy
HusbandryRedux.LAYOUT_DESIGN_WIDTH = 1480    -- AR's widest table in design px (HerdInspector: 1464 + margin)
HusbandryRedux._layoutScaling = false

-- IMAGES MUST NOT WIDEN: their proportions are the point. DR 5.80 records a picture rendering at the
-- wrong aspect purely because a new Bitmap had not been added to this list. The names are AR's own
-- elements; the profiles are the stock selector arrows and header badge, whose art is atlas-sampled
-- and garbles outright when resized (DR 5.64).
HusbandryRedux.LAYOUT_KEEP_ASPECT_NAMES = {
    assetIcon = true, fillIcon = true, brIcon = true, catIcon = true, brBarnIcon = true,
}
HusbandryRedux.LAYOUT_KEEP_ASPECT_PROFILES = {
    fs25_menuHeaderIcon = true, fs25_menuHeaderIconBg = true,
    fs25_multiTextOptionLeft = true, fs25_multiTextOptionRight = true,
}

function HusbandryRedux.layoutScaleX()
    local target = HusbandryRedux.LAYOUT_TARGET_WIDTH or 0
    if target <= 0 then return 1 end
    local a = g_aspectScaleX
    if type(a) ~= "number" or a <= 0 or a >= 1 then return 1 end
    local refW = (type(g_referenceScreenWidth) == "number" and g_referenceScreenWidth > 0)
                 and g_referenceScreenWidth or 1920
    local base = ((HusbandryRedux.LAYOUT_DESIGN_WIDTH or 1480) / refW) * a
    if base <= 0 then return 1 end
    return math.max(1, target / base)
end

function HusbandryRedux.installLayoutWidening()
    if HusbandryRedux._layoutHooked then return end
    if GuiUtils == nil or GuiElement == nil then return end
    HusbandryRedux._layoutHooked = true

    -- POSITIONS: scale every ODD index (the x of each x/y pair). Always safe -- moving an element
    -- cannot distort it, so icons travel with the layout instead of being left behind by it.
    local origScreen = GuiUtils.getNormalizedScreenValues
    GuiUtils.getNormalizedScreenValues = function(...)
        local v = origScreen(...)
        if HusbandryRedux._layoutScaling and type(v) == "table" then
            local f = HusbandryRedux.layoutScaleX()
            if f > 1 then
                for i = 1, #v, 2 do
                    if type(v[i]) == "number" then v[i] = v[i] * f end
                end
            end
        end
        return v
    end

    -- WIDTHS: hooked here rather than in getNormalizedValue because only here is the ELEMENT in
    -- hand, and the decision is per element. textSize resolves through a different function and is
    -- therefore untouched -- columns widen while the text stays the same size, which is the point.
    local origResolve = GuiElement.resolveSizeString
    GuiElement.resolveSizeString = function(self, ...)
        origResolve(self, ...)
        if not HusbandryRedux._layoutScaling then return end
        local f = HusbandryRedux.layoutScaleX()
        if f <= 1 then return end
        if self.name ~= nil and HusbandryRedux.LAYOUT_KEEP_ASPECT_NAMES[self.name] then return end
        if self.profile ~= nil and HusbandryRedux.LAYOUT_KEEP_ASPECT_PROFILES[self.profile] then return end
        -- A PERCENTAGE WIDTH RESOLVES FROM THE PARENT, which is already widened; scaling it again
        -- compounds down the tree (100% in a 100% row in a widened list comes out about 2.4x).
        local xStr = self.widthStr
        if xStr == nil and type(self.sizeStr) == "string" then
            local sp = self.sizeStr:find(" ")
            xStr = (sp ~= nil) and self.sizeStr:sub(1, sp - 1) or self.sizeStr
        end
        if type(xStr) == "string" and xStr:find("%%") ~= nil then return end
        if type(self.size) == "table" and type(self.size[1]) == "number" then
            self.size[1] = self.size[1] * f
            if self.updateAnchorDeltas ~= nil then self:updateAnchorDeltas() end
        end
    end
end

---What Distribution Redux would need to host ALL of Husbandry Redux's UI, and which
-- of it is missing. Returns a (possibly empty) list of names, or NIL when there is
-- no DR at all -- standalone is a supported mode, not a gap, and an empty list
-- would otherwise mean both "nothing missing" and "nothing to be missing from".
--
-- IT IS ALL OR NOTHING BY DESIGN. AR's pages go to DR's menu or to AR's own, never
-- half each: registering the settings tab on DR's page while the guide lived on
-- AR's menu would put one screen in two places, which the author ruled out when
-- this split was designed.
--
-- THE THREE PIECES AND WHAT THEY COST IF ABSENT:
--   onMenuReady/loadMenuPage/addMenuPage (v3)  the Herd Inspector page itself
--   registerSettingsTab (v8)                   AR's settings
--   registerHelpTab (v9)                       AR's User Guide
-- Before this list existed the gate asked only for the v3 group, so a DR between
-- v3 and v7 took the page and then had nowhere to put the other two -- and AR's
-- settings and guide were reachable from NOWHERE. Reported as the question "what
-- happens if a player updates Husbandry Redux but not Distribution Redux?".
--
-- The feed planner and the husbandry panel are NOT here: each registers INTO DR
-- independently and reports itself off through capabilityOk, so a DR too old for
-- one of them can still host the menu perfectly well.
HusbandryRedux.DR_UI_CALLS = { "onMenuReady", "loadMenuPage", "addMenuPage",
                            "registerSettingsTab", "registerHelpTab" }

function HusbandryRedux.drIntegrationGaps()
    local SD = HusbandryRedux.DR
    if SD == nil then return nil end                  -- standalone: not applicable
    local gaps = {}
    local env = HusbandryRedux.DR_ENV
    if env == nil or env.DistributionMenuPage == nil then
        gaps[#gaps + 1] = "DistributionMenuPage"
    end
    local api = SD.API
    for _, fn in ipairs(HusbandryRedux.DR_UI_CALLS) do
        if api == nil or api[fn] == nil then gaps[#gaps + 1] = "API." .. fn end
    end
    return gaps
end

---Can Distribution Redux host AR's whole UI? Capability, never the version number.
function HusbandryRedux.canUseDRMenu()
    local gaps = HusbandryRedux.drIntegrationGaps()
    return gaps ~= nil and #gaps == 0
end

function HusbandryRedux.installStandaloneMenu()
    if HusbandryRedux._standaloneMenu ~= nil then return true end
    if g_gui == nil or TabbedMenu == nil or AnimalMenu == nil then
        HusbandryRedux.warn("standalone menu: g_gui/TabbedMenu/AnimalMenu missing")
        return false
    end
    local dir = HusbandryRedux.MOD_DIR or ""
    local ok, err = pcall(function()
        -- PROFILES FIRST, ALWAYS. A layout naming a profile that has not been loaded does not error;
        -- it falls back to a default with NO positioning (27.5), so the page would render scattered
        -- with nothing in the log to say why. Loading them before any loadGui is the whole guard.
        if HusbandryRedux.loadProfiles ~= nil then HusbandryRedux.loadProfiles() end

        -- WIDEN WHILE OUR OWN PAGE FILES LOAD, and only then. DR does the same around its own page
        -- loads; with DR present we never reach here, so the two hooks can never both apply.
        HusbandryRedux.installLayoutWidening()
        HusbandryRedux._layoutScaling = (HusbandryRedux.layoutScaleX() > 1)

        -- The PAGE registers itself: HerdInspectorPage.install with no menu takes the standalone
        -- branch and loadGui's under the name AnimalMenu.xml's FrameReference expects.
        local okPage, why = HerdInspectorPage.install(nil)
        if not okPage then error("page: " .. tostring(why), 0) end

        -- The two simple pages: construct, then load their XML under the name AnimalMenu.xml's
        -- FrameReference expects. Inside the same widening window as the Herd Inspector, since they
        -- are table layout too.
        if AnimalSettingsPage ~= nil then
            HusbandryRedux._settingsPage = AnimalSettingsPage.new()
            g_gui:loadGui(dir .. "gui/AnimalSettingsPage.xml", "animalSettingsPage",
                          HusbandryRedux._settingsPage, true)
        end
        if AnimalHelpPage ~= nil then
            HusbandryRedux._helpPage = AnimalHelpPage.new()
            g_gui:loadGui(dir .. "gui/AnimalHelpPage.xml", "animalHelpPage",
                          HusbandryRedux._helpPage, true)
        end

        -- THE MENU XML IS CHROME AND IS NOT WIDENED. DR 6.15 excludes its own menu file for exactly
        -- this reason: the tab strip and footer bar are not table layout, and widening them stretched
        -- the tab icons and ate the width the content wanted.
        HusbandryRedux._layoutScaling = false
        HusbandryRedux._standaloneMenu = AnimalMenu.new()
        g_gui:loadGui(dir .. "gui/AnimalMenu.xml", "AnimalMenu", HusbandryRedux._standaloneMenu)
    end)
    -- CLEARED ON EVERY PATH. Left set by a failure, it would go on widening the base game's own
    -- menus for the rest of the session -- a bug that would look nothing like its cause.
    HusbandryRedux._layoutScaling = false
    if not ok then
        HusbandryRedux._standaloneMenu = nil
        HusbandryRedux.warn("standalone menu failed to build: %s", tostring(err))
        return false
    end
    -- NOT ONLY "DR is absent" any more: a DR too old to host the whole UI lands here too,
    -- and a log line asserting DR is missing would send a reader looking for the wrong thing.
    print(string.format("[HusbandryRedux] own menu built (%s)",
        HusbandryRedux.DR == nil and "Distribution Redux not present"
                              or "Distribution Redux too old to host it"))
    return true
end

---Open AR's own menu. A no-op unless the standalone menu was actually built.
function HusbandryRedux.openStandaloneMenu()
    if HusbandryRedux._standaloneMenu == nil or g_gui == nil then return end
    g_gui:showGui("AnimalMenu")
end

-- THE KEY: KEY_backslash, the SAME key DR uses, declared in modDesc so a player who uninstalls DR
-- keeps the muscle memory rather than learning a second key for the same job.
--
-- REGISTERED ONLY WHEN WE OWN THE MENU. The action is declared unconditionally (modDesc is static)
-- but no handler is attached while DR is present, so DR keeps the key and there is no question of
-- both mods answering one press.
-- INSTALLED AT FILE SCOPE (see the call at the bottom), NOT from onMissionLoaded, and that ordering
-- is the difference between the key working and doing nothing at all. This APPENDS to
-- PlayerInputComponent.registerActionEvents, so it only ever takes effect the next time that runs --
-- and by mission-load-finished the player's input context may already have been built, in which case
-- an appended hook is simply never called. DR installs its own the same way for the same reason.
--
-- Hooking early is free because the HANDLER is gated instead: it returns immediately unless the
-- standalone menu was actually built, so with DR installed this is an empty function call on a
-- context rebuild and DR keeps the key to itself.
function HusbandryRedux.registerMenuInput()
    if HusbandryRedux._inputInstalled then return end
    if PlayerInputComponent == nil or PlayerInputComponent.registerActionEvents == nil then
        HusbandryRedux.warn("menu key NOT registered: PlayerInputComponent.registerActionEvents missing")
        return
    end
    HusbandryRedux._inputInstalled = true

    PlayerInputComponent.registerActionEvents = Utils.appendedFunction(
        PlayerInputComponent.registerActionEvents,
        function(self, ...)
            if HusbandryRedux._standaloneMenu == nil then return end
            -- OWNER ONLY. In multiplayer this runs for every player component; without the test each
            -- client would register the key against somebody else's player as well as its own.
            if self == nil or self.player == nil or not self.player.isOwner then return end
            if g_inputBinding == nil or InputAction == nil then
                print("[HusbandryRedux] input: g_inputBinding/InputAction missing")
                return
            end
            if InputAction.ANIMALREDUX_OPEN_MANAGER == nil then
                print("[HusbandryRedux] menu key NOT registered: ANIMALREDUX_OPEN_MANAGER is not a known "
                      .. "action -- check modDesc declares it under <actions>")
                return
            end
            -- THE CONTEXT IS THE WHOLE POINT, and getting this wrong is why the first attempt did
            -- nothing at all. An action event belongs to an INPUT CONTEXT; registering one outside a
            -- beginActionEventsModification block does not attach it to the context the player is
            -- actually in, so the key is simply never seen. This hook also RE-RUNS whenever the
            -- context is rebuilt, which is what keeps the binding alive across entering a vehicle,
            -- respawning and so on -- a one-shot registration at mission load could not.
            local ctx = PlayerInputComponent.INPUT_CONTEXT_NAME
            g_inputBinding:beginActionEventsModification(ctx)
            local ok, _, eventId = pcall(g_inputBinding.registerActionEvent, g_inputBinding,
                InputAction.ANIMALREDUX_OPEN_MANAGER, self,
                function() HusbandryRedux.openStandaloneMenu() end,
                false, true, false, true, nil, true)
            if ok and eventId ~= nil then
                pcall(function()
                    g_inputBinding:setActionEventText(eventId,
                        HusbandryRedux.l10n("ar_input_openMenu", "Husbandry Redux menu"))
                    g_inputBinding:setActionEventTextVisibility(eventId, true)
                end)
            else
                print("[HusbandryRedux] menu key registration FAILED: " .. tostring(eventId))
            end
            g_inputBinding:endActionEventsModification()
        end)
    -- UNCONDITIONAL, not HusbandryRedux.log: that one is gated on `debug`, so the whole standalone
    -- build reported NOTHING on success and a player could not tell "it worked" from "it never ran"
    -- -- the exact ambiguity DR 5.87c and today's pass profiler both had to be fixed for.
    -- The hook is in place; whether it BINDS anything depends on the standalone menu existing when
    -- the context is next built, which is why this says "armed" rather than "registered".
    print("[HusbandryRedux] standalone menu key hook armed (backslash by default)")
end

-- ---------------------------------------------------------------------------
-- THE OLD MOD, IF IT IS STILL INSTALLED
--
-- This mod was called Husbandry Redux until 2026-09-20 and shipped as FS25_Husbandry_Redux.
-- A renamed mod is a DIFFERENT mod to the game, so a player who unzips the new one
-- without deleting the old gets BOTH loaded: two Husbandry tabs, two settings tabs, two
-- guide tabs, two sets of hooks on the same husbandries. Nothing errors -- it all simply
-- happens twice -- which is the hardest kind of problem to report.
--
-- KEYED ON THE FOLDER NAME, because that is what g_modIsLoaded is keyed by and what the
-- player has to go and delete. It is deliberately NOT the display title: a title is
-- translated and a folder name is not.
-- ASSEMBLED FROM PIECES, not written out. The rename was done by a scripted substitution
-- over both repositories, and a literal of the old name sitting in the one file whose job
-- is to remember it would have been rewritten along with everything else -- which it was,
-- silently, leaving a warning that compared the new name against itself and could never
-- fire. Split like this it survives that pass and any future one.
HusbandryRedux.LEGACY_MOD_NAME = "FS25_" .. "Animal" .. "_Redux"
HusbandryRedux.LEGACY_TITLE    = "Animal" .. " Redux"

function HusbandryRedux.warnIfLegacyInstalled()
    if HusbandryRedux._legacyWarned then return false end
    HusbandryRedux._legacyWarned = true
    if g_modIsLoaded == nil or not g_modIsLoaded[HusbandryRedux.LEGACY_MOD_NAME] then
        return false
    end

    -- The OLD names come from the constants above, never from a literal here, for the
    -- reason given there. %s twice, so a translation can put them where its grammar needs.
    local br = string.char(10) .. string.char(10)
    local text = string.format(HusbandryRedux.l10n("ar_legacy_warning",
        "%s has been renamed to Husbandry Redux." .. br ..
        "The old mod (%s) is still installed and both are running, so everything will " ..
        "appear twice." .. br ..
        "Quit to the main menu, delete that mod from your mods folder, and load again. " ..
        "Your animal data is kept."),
        HusbandryRedux.LEGACY_TITLE, HusbandryRedux.LEGACY_MOD_NAME)

    -- ALWAYS LOGGED, dialog or no dialog: the log is what reaches us when a player reports
    -- a problem, and it outlives a dialog nobody wrote down (DR 5.82).
    HusbandryRedux.warn("the pre-rename %s is ALSO installed; both mods are running",
                        HusbandryRedux.LEGACY_MOD_NAME)
    if InfoDialog ~= nil and InfoDialog.show ~= nil then
        pcall(InfoDialog.show, text)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- THE INPUT HOOK GOES IN AT MOD LOAD, before any player exists. See registerMenuInput.
pcall(HusbandryRedux.registerMenuInput)

local function install()
    if Mission00 == nil or Mission00.loadMission00Finished == nil then
        HusbandryRedux.warn("Mission00.loadMission00Finished not found; cannot install.")
        return
    end
    Mission00.loadMission00Finished = Utils.appendedFunction(
        Mission00.loadMission00Finished,
        function()
            pcall(HusbandryRedux.onMissionLoaded)
            -- AFTER the mission load, for the reason DR's own warning is deferred (6.19):
            -- at mod-load time the GUI is not necessarily up, and a dialog raised into a
            -- half-built screen either does not appear or appears behind everything.
            pcall(HusbandryRedux.warnIfLegacyInstalled)
        end)
end

install()
