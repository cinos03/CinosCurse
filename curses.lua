-- CinosCurse / curses.lua
-- Combat-log driven curse/DoT timer store, keyed by destGUID.
-- Milestone M4.
--
-- Data model:
--   state[destGUID][lowerSpellName] = {
--     name        = "Curse of Agony",
--     spellId     = number,
--     start       = GetTime() at apply,
--     duration    = seconds (best estimate, refined by UnitDebuff),
--     expiration  = GetTime() + duration,
--     stack       = number or 1,
--     texture     = path or nil,
--   }
--
-- Combat log on 3.3.5a fires SPELL_AURA_APPLIED / _REFRESH / _REMOVED /
-- _APPLIED_DOSE / _REMOVED_DOSE for debuffs the player applies. We treat
-- only sourceGUID == player's GUID as ours. Duration is taken from a
-- per-spell table (we'll fill in defaults below); UnitDebuff() reconciles
-- exact expiration whenever a unit token resolves to that GUID.

CinosCurse = CinosCurse or {}
local CC = CinosCurse
CC.curses = CC.curses or {}
local C = CC.curses

C.state = {}  -- guid -> { lowerName -> entry }

-- Default base durations for common warlock/affliction-style spells.
-- Used as a fallback only; UnitDebuff overrides whenever available.
local DEFAULT_DURATIONS = {
    ["curse of agony"]          = 24,
    ["curse of doom"]           = 60,
    ["curse of the elements"]   = 300,
    ["curse of weakness"]       = 120,
    ["curse of recklessness"]   = 120,
    ["curse of tongues"]        = 30,
    ["curse of exhaustion"]     = 12,
    ["curse of shadow"]         = 300,
    ["corruption"]              = 18,
    ["unstable affliction"]     = 15,
    ["siphon life"]             = 30,
    ["haunt"]                   = 12,
    ["immolate"]                = 15,
    ["shadowflame"]             = 8,
    -- Shadow priest-ish, balance druid-ish, useful even pre-config.
    ["shadow word: pain"]       = 18,
    ["vampiric touch"]          = 15,
    ["devouring plague"]        = 24,
    ["moonfire"]                = 12,
    ["insect swarm"]            = 12,
}

local function lower(s) return s and s:lower() or nil end

-- Trim "(Rank N)" suffix and lowercase.
function C:NormalizeSpellName(spellName)
    if not spellName then return nil end
    local stripped = spellName:gsub("%s*%(.-%)$", "")
    return stripped:lower()
end

local function isTracked(lowerName)
    if not lowerName then return false end
    if DEFAULT_DURATIONS[lowerName] then return true end
    local cfg = CC.config and CC.config.db
    if cfg and cfg.trackedSpells then
        for _, s in ipairs(cfg.trackedSpells) do
            if s and s:lower() == lowerName then return true end
        end
    end
    return false
end

local function defaultDuration(lowerName)
    return DEFAULT_DURATIONS[lowerName] or 15
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function C:Get(guid)
    return self.state[guid]
end

function C:GetSpell(guid, spellName)
    local g = self.state[guid]
    return g and g[self:NormalizeSpellName(spellName)]
end

-- Returns array of active entries (sorted by expiration ascending) for a
-- given guid. Used by the bar to render icon row.
-- Optional `buf` is a reusable table the caller may supply to avoid GC
-- pressure on per-frame paths; it will be wiped and refilled.
local function _expCmp(a, b) return (a.expiration or 0) < (b.expiration or 0) end
function C:GetActive(guid, now, buf)
    local g = self.state[guid]
    if not g then return nil end
    now = now or GetTime()
    local list = buf or {}
    for i = #list, 1, -1 do list[i] = nil end
    for _, e in pairs(g) do
        if (e.expiration or 0) > now then
            list[#list + 1] = e
        end
    end
    table.sort(list, _expCmp)
    return list
end

function C:Wipe(guid)
    self.state[guid] = nil
end

-- ---------------------------------------------------------------------------
-- Reconcile via UnitDebuff when a unit token resolves to a guid we track.
-- 3.3.5 UnitDebuff returns:
--   name, rank, icon, count, debuffType, duration, expirationTime, ...
-- ---------------------------------------------------------------------------

function C:ReconcileUnit(unit)
    if not UnitExists(unit) then return end
    local guid = UnitGUID(unit)
    if not guid then return end
    local g = self.state[guid]
    -- We still want to seed entries even if state is empty, in case the
    -- player applied the debuff before the addon loaded.
    local playerGuid = UnitGUID("player")
    for i = 1, 40 do
        local name, _, icon, count, _, duration, expirationTime, source = UnitDebuff(unit, i)
        if not name then break end
        if source == "player" or source == playerGuid then
            local lowerName = self:NormalizeSpellName(name)
            if isTracked(lowerName) then
                g = g or {}
                self.state[guid] = g
                local e = g[lowerName] or {}
                e.name       = name
                e.texture    = icon
                e.stack      = (count and count > 0) and count or 1
                if duration and duration > 0 then
                    e.duration   = duration
                    e.expiration = expirationTime
                    e.start      = expirationTime - duration
                end
                g[lowerName] = e
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Combat log handler
-- ---------------------------------------------------------------------------

local function applyOrRefresh(guid, spellId, spellName, now, isRefresh)
    local lowerName = C:NormalizeSpellName(spellName)
    if not isTracked(lowerName) then return end
    local g = C.state[guid] or {}
    C.state[guid] = g
    local e = g[lowerName] or {}
    local dur = defaultDuration(lowerName)
    e.name       = spellName
    e.spellId    = spellId
    e.duration   = dur
    e.start      = now
    e.expiration = now + dur
    e.stack      = e.stack or 1
    if not e.texture then
        local _, _, icon = GetSpellInfo(spellId or spellName)
        e.texture = icon
    end
    g[lowerName] = e
end

local function removeAura(guid, spellName)
    local lowerName = C:NormalizeSpellName(spellName)
    local g = C.state[guid]
    if not g then return end
    g[lowerName] = nil
    if not next(g) then C.state[guid] = nil end
end

local function dose(guid, spellName, amount)
    local lowerName = C:NormalizeSpellName(spellName)
    local g = C.state[guid]
    if not g then return end
    local e = g[lowerName]
    if e then e.stack = amount or (e.stack or 1) end
end

CC:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", function(_, _, subEvent,
        sourceGUID, sourceName, sourceFlags,
        destGUID, destName, destFlags,
        spellId, spellName, spellSchool,
        auraType, amount)
    if not destGUID then return end
    if sourceGUID ~= UnitGUID("player") then return end

    if subEvent == "SPELL_AURA_APPLIED" then
        applyOrRefresh(destGUID, spellId, spellName, GetTime(), false)
    elseif subEvent == "SPELL_AURA_REFRESH" then
        applyOrRefresh(destGUID, spellId, spellName, GetTime(), true)
    elseif subEvent == "SPELL_AURA_REMOVED" then
        removeAura(destGUID, spellName)
    elseif subEvent == "SPELL_AURA_APPLIED_DOSE" or subEvent == "SPELL_AURA_REMOVED_DOSE" then
        dose(destGUID, spellName, amount)
    end
end)

-- UNIT_DIED's signature differs (no spell args). Handle separately.
CC:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", function(_, _, subEvent,
        _, _, _, destGUID)
    if subEvent == "UNIT_DIED" and destGUID then
        C:Wipe(destGUID)
    end
end)

-- Reconcile on token availability for accuracy.
CC:RegisterEvent("PLAYER_TARGET_CHANGED",  function() C:ReconcileUnit("target") end)
CC:RegisterEvent("UPDATE_MOUSEOVER_UNIT",  function() C:ReconcileUnit("mouseover") end)
CC:RegisterEvent("PLAYER_FOCUS_CHANGED",   function() C:ReconcileUnit("focus") end)
CC:RegisterEvent("UNIT_AURA",              function(_, unit) if unit then C:ReconcileUnit(unit) end end)

-- Periodic prune of expired entries.
local pruneFrame = CreateFrame("Frame")
local accum = 0
pruneFrame:SetScript("OnUpdate", function(_, elapsed)
    accum = accum + elapsed
    if accum < 1 then return end
    accum = 0
    local now = GetTime()
    for guid, g in pairs(C.state) do
        for k, e in pairs(g) do
            if (e.expiration or 0) <= now then
                g[k] = nil
            end
        end
        if not next(g) then C.state[guid] = nil end
    end
end)
