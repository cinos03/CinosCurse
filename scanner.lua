-- CinosCurse / scanner.lua
-- Discovers hostile mobs and maintains GUID<->name maps.
-- Milestone M2: nameplate walking + unit-token polling.
--
-- Data model:
--   mobs[guid] = {
--     guid     = "0x...",          -- may be nil for nameplate-only entries
--     name     = "Some Mob",
--     lastSeen = GetTime(),
--     hp       = 0..1 or nil,
--     mark     = 0..8,             -- raid target index
--     token    = "raid3target",    -- last unit token that resolved to it (transient)
--   }
--
-- Nameplate-only entries (no GUID yet) are keyed by a synthetic
-- "name:" .. mobName key so we still surface them on bars. When we later
-- learn the GUID via target/mouseover, we migrate the entry.

CinosCurse = CinosCurse or {}
local CC = CinosCurse
CC.scanner = CC.scanner or {}
local S = CC.scanner

S.mobs        = {}     -- key -> entry (key is guid or "name:"..mobName)
S.guidByName  = {}     -- name -> guid (last known)
S.nameByGuid  = {}     -- guid -> name

-- How long since lastSeen before we drop the entry.
local STALE_SECONDS = 6
-- Hard ceiling: even mobs we're "keeping alive" (raid-marked or
-- still-cursed) get dropped after this long without a sighting. Stops
-- bars from sticking around when you hearth out, change continents,
-- die and release, etc.
local HARD_STALE_SECONDS = 30

-- Throttle settings.
local POLL_INTERVAL  = 0.25  -- unit-token + nameplate sweep
local PRUNE_INTERVAL = 1.0

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function keyFor(guid, name)
    if guid and guid ~= "" then return guid end
    if name then return "name:" .. name end
    return nil
end

local function upsert(guid, name, token)
    if not name then return end
    local now = GetTime()
    local k = keyFor(guid, name)
    local e = S.mobs[k]
    if not e then
        -- If we previously had a name-only entry and now have a guid, migrate.
        if guid and S.mobs["name:" .. name] then
            e = S.mobs["name:" .. name]
            S.mobs["name:" .. name] = nil
            e.guid = guid
            S.mobs[guid] = e
        else
            e = { name = name, guid = guid, lastSeen = now }
            S.mobs[k] = e
        end
    end
    e.name     = name
    e.guid     = guid or e.guid
    e.lastSeen = now
    if token then e.token = token end

    if guid then
        S.guidByName[name] = guid
        S.nameByGuid[guid] = name
    end
end

local function readToken(token)
    if not UnitExists(token) then return end
    if not UnitCanAttack("player", token) then return end
    if UnitIsDead(token) then return end
    local name = UnitName(token)
    if not name then return end
    local guid = UnitGUID(token)
    upsert(guid, name, token)
    local e = S.mobs[keyFor(guid, name)]
    if e then
        local hpMax = UnitHealthMax(token)
        if hpMax and hpMax > 0 then
            e.hp = UnitHealth(token) / hpMax
        end
        e.mark = GetRaidTargetIndex(token) or 0
    end
end

-- ---------------------------------------------------------------------------
-- Nameplate scanning
--
-- 3.3.5 nameplates are unparented frames hanging off WorldFrame. We
-- identify them by inspecting their region structure: every nameplate has
-- a name fontstring as one of its regions. We track which children we've
-- already hooked so we don't hook twice.
-- ---------------------------------------------------------------------------

local hookedPlates = {}
local activePlates = {}  -- frame -> name currently shown

local function isNameplate(frame)
    if not frame.GetName or frame:GetName() then return false end -- nameplates are anonymous
    if not frame.GetObjectType or frame:GetObjectType() ~= "Frame" then return false end
    -- Heuristic: nameplates have a region named via overlay textures and
    -- exactly one fontstring at "ARTWORK"/"OVERLAY" with the mob name.
    -- Simpler heuristic that works on 3.3.5: check for a specific child
    -- structure used by Blizzard plates.
    local regions = { frame:GetRegions() }
    local hasName = false
    local hasThreat = false
    for _, r in ipairs(regions) do
        if r:GetObjectType() == "FontString" then
            hasName = true
        elseif r:GetObjectType() == "Texture" then
            local tex = r:GetTexture()
            if tex and type(tex) == "string" and tex:find("Nameplates") then
                hasThreat = true
            end
        end
    end
    return hasName and hasThreat
end

local function nameplateName(frame)
    -- The mob name fontstring is the first FontString region on the plate.
    local regions = { frame:GetRegions() }
    for _, r in ipairs(regions) do
        if r:GetObjectType() == "FontString" then
            return r:GetText()
        end
    end
end

local function nameplateHpPct(frame)
    -- Blizzard nameplate has a child StatusBar for HP. Cache the bar
    -- reference on first lookup to avoid allocating { GetChildren() }
    -- every frame for every visible plate.
    local hp = frame.__ccHpBar
    if not hp then
        local children = { frame:GetChildren() }
        for _, c in ipairs(children) do
            if c.GetObjectType and c:GetObjectType() == "StatusBar" then
                hp = c
                break
            end
        end
        if not hp then return end
        frame.__ccHpBar = hp
    end
    local mn, mx = hp:GetMinMaxValues()
    local v = hp:GetValue() or 0
    if mx and mx > mn then return (v - mn) / (mx - mn) end
end

local function hookPlate(frame)
    if hookedPlates[frame] then return end
    hookedPlates[frame] = true
    frame:HookScript("OnShow", function(self)
        local n = nameplateName(self)
        if n then activePlates[self] = n end
    end)
    frame:HookScript("OnHide", function(self)
        activePlates[self] = nil
    end)
    if frame:IsShown() then
        local n = nameplateName(frame)
        if n then activePlates[frame] = n end
    end
end

local function scanWorldFrame()
    local children = { WorldFrame:GetChildren() }
    for _, f in ipairs(children) do
        if not hookedPlates[f] and isNameplate(f) then
            hookPlate(f)
        end
    end
    for plate, _ in pairs(activePlates) do
        if plate:IsShown() then
            local name = nameplateName(plate)
            if name and name ~= "" then
                activePlates[plate] = name
                -- Per-plate key: gives same-name mobs distinct entries
                -- so two plates of "Searing Blade Enforcer" produce
                -- two bars, not one. GetSorted suppresses one of them
                -- when a GUID-keyed entry of the same name exists
                -- (the targeted/cursed copy).
                local pkey = "plate:" .. tostring(plate)
                local now = GetTime()
                local e = S.mobs[pkey]
                if not e then
                    e = { name = name, guid = nil, lastSeen = now, plate = plate }
                    S.mobs[pkey] = e
                end
                e.name = name
                e.lastSeen = now
                local pct = nameplateHpPct(plate)
                if pct then e.hp = pct end
            end
        else
            -- Plate hidden: drop its entry immediately.
            local name = activePlates[plate]
            activePlates[plate] = nil
            local pkey = "plate:" .. tostring(plate)
            S.mobs[pkey] = nil
            -- name var unused but kept for future targeting hooks.
            local _ = name
        end
    end
end

-- ---------------------------------------------------------------------------
-- Polling loop
-- ---------------------------------------------------------------------------

local function pollTokens()
    readToken("target")
    readToken("targettarget")
    readToken("mouseover")
    readToken("focus")
    readToken("pet")
    readToken("pettarget")
    for i = 1, 4 do
        readToken("party" .. i .. "target")
    end
    for i = 1, 40 do
        readToken("raid" .. i .. "target")
    end
end

local function prune()
    local now = GetTime()
    local curseState = CC.curses and CC.curses.state
    for k, e in pairs(S.mobs) do
        local age = now - (e.lastSeen or 0)
        if age > HARD_STALE_SECONDS then
            -- Hard ceiling: drop unconditionally so changing zones /
            -- hearthing out can't leave ghost bars around.
            S.mobs[k] = nil
        elseif age > STALE_SECONDS then
            -- Keep alive if:
            --   1. We still have an active curse on this guid, OR
            --   2. The mob has a raid marker (so pre-marked pulls stay
            --      visible until the marker is removed or the mob dies).
            local keep = false
            if e.mark and e.mark > 0 then
                keep = true
            elseif e.guid and curseState and curseState[e.guid] then
                for _, ce in pairs(curseState[e.guid]) do
                    if (ce.expiration or 0) > now then
                        keep = true
                        break
                    end
                end
            end
            if not keep then
                S.mobs[k] = nil
            end
        end
    end
end

local accumPoll, accumPrune = 0, 0
local pollFrame = CreateFrame("Frame")
pollFrame:SetScript("OnUpdate", function(self, elapsed)
    accumPoll  = accumPoll  + elapsed
    accumPrune = accumPrune + elapsed
    -- Cheap every-frame pass: refresh HP on already-known active
    -- nameplates so big incoming hits show up instantly. Walking the
    -- WorldFrame and re-detecting plates is the expensive part and
    -- stays gated by POLL_INTERVAL below.
    for plate, name in pairs(activePlates) do
        if plate:IsShown() and name then
            local pct = nameplateHpPct(plate)
            if pct then
                local k = keyFor(S.guidByName[name], name)
                local e = S.mobs[k]
                if e then e.hp = pct end
            end
        end
    end
    if accumPoll >= POLL_INTERVAL then
        accumPoll = 0
        pollTokens()
        scanWorldFrame()
    end
    if accumPrune >= PRUNE_INTERVAL then
        accumPrune = 0
        prune()
    end
end)

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Returns a sorted array of entries (descending priority):
--   1. Raid-marked mobs (by mark priority, skull first)
--   2. Current target
--   3. Mouseover
--   4. Highest HP first
local MARK_PRIORITY = { [8]=8, [7]=7, [6]=6, [5]=5, [4]=4, [3]=3, [2]=2, [1]=1 }

local function ignored(name)
    local cfg = CC.config and CC.config.db
    if not (cfg and cfg.ignoredNames) then return false end
    local lower = name:lower()
    for _, sub in ipairs(cfg.ignoredNames) do
        if sub ~= "" and lower:find(sub:lower(), 1, true) then
            return true
        end
    end
    return false
end

function S:GetSorted(limit)
    local list = {}
    local targetGuid = UnitGUID("target")
    local moGuid     = UnitGUID("mouseover")
    -- Count GUID-keyed entries per name so we know how many plate-only
    -- entries of each name to suppress (one per GUID-keyed entry, to
    -- avoid showing the targeted/cursed copy as both a guid bar AND a
    -- plate-only bar).
    local guidCountByName = {}
    for _, e in pairs(self.mobs) do
        if e.name and e.guid then
            guidCountByName[e.name] = (guidCountByName[e.name] or 0) + 1
        end
    end
    local plateSuppress = {}
    for k, v in pairs(guidCountByName) do plateSuppress[k] = v end
    for _, e in pairs(self.mobs) do
        if e.name and not ignored(e.name) then
            if not e.guid and e.plate and (plateSuppress[e.name] or 0) > 0 then
                -- Skip: this plate-only entry is the same mob as one
                -- of the GUID-keyed entries.
                plateSuppress[e.name] = plateSuppress[e.name] - 1
            else
                table.insert(list, e)
            end
        end
    end
    table.sort(list, function(a, b)
        local am = MARK_PRIORITY[a.mark or 0] or 0
        local bm = MARK_PRIORITY[b.mark or 0] or 0
        if am ~= bm then return am > bm end
        local at = (a.guid and a.guid == targetGuid) and 1 or 0
        local bt = (b.guid and b.guid == targetGuid) and 1 or 0
        if at ~= bt then return at > bt end
        local amo = (a.guid and a.guid == moGuid) and 1 or 0
        local bmo = (b.guid and b.guid == moGuid) and 1 or 0
        if amo ~= bmo then return amo > bmo end
        local ah = a.hp or 0
        local bh = b.hp or 0
        if ah ~= bh then return ah > bh end
CC:RegisterEvent("UNIT_HEALTH_FREQUENT",     function(_, unit) if unit then readToken(unit) end end)

-- Drop mobs the instant they die so their bar disappears immediately.
CC:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", function(_, _, subEvent,
        _, _, _, destGUID, destName)
    if (subEvent == "UNIT_DIED" or subEvent == "UNIT_DESTROYED" or subEvent == "PARTY_KILL")
        and destGUID then
        S.mobs[destGUID] = nil
        if destName then S.mobs["name:" .. destName] = nil end
    end
end)
        return (a.name or "") < (b.name or "")
    end)
    if limit and #list > limit then
        for i = #list, limit + 1, -1 do list[i] = nil end
    end
    return list
end

-- Hooks for opportunistic GUID capture.
CC:RegisterEvent("PLAYER_TARGET_CHANGED",    function() readToken("target") end)
CC:RegisterEvent("UPDATE_MOUSEOVER_UNIT",    function() readToken("mouseover") end)
CC:RegisterEvent("PLAYER_FOCUS_CHANGED",     function() readToken("focus") end)
CC:RegisterEvent("RAID_TARGET_UPDATE",       function() pollTokens() end)
CC:RegisterEvent("UNIT_HEALTH",              function(_, unit) if unit then readToken(unit) end end)

-- Zone changes: wipe everything. Anything we were tracking is by
-- definition no longer nearby (and any GUIDs we cached are gone from
-- the world). Prevents ghost bars after hearth / portal / death.
local function wipeAll()
    for k in pairs(S.mobs)       do S.mobs[k]       = nil end
    for k in pairs(S.guidByName) do S.guidByName[k] = nil end
    for k in pairs(S.nameByGuid) do S.nameByGuid[k] = nil end
    for k in pairs(activePlates) do activePlates[k] = nil end
end
CC:RegisterEvent("PLAYER_ENTERING_WORLD", wipeAll)
CC:RegisterEvent("ZONE_CHANGED_NEW_AREA", wipeAll)
