-- CinosCurse / ui.lua
-- Anchor frame + bar pool + slash subcommands.
-- Milestone M1: movable/lockable anchor, N empty bars stacked, no logic.

CinosCurse = CinosCurse or {}
local CC = CinosCurse
CC.ui = CC.ui or {}

local L = CC.L

local anchor
local bars = {}
CC.ui.bars = bars

local DEFAULT_POINT = { "CENTER", "UIParent", "CENTER", 0, 0 }

local function applyPoint(frame, p)
    p = p or DEFAULT_POINT
    frame:ClearAllPoints()
    frame:SetPoint(p[1], p[2] or "UIParent", p[3] or p[1], p[4] or 0, p[5] or 0)
end

local function savePoint()
    if not (anchor and CC.config and CC.config.db) then return end
    local point, _, relPoint, x, y = anchor:GetPoint()
    CC.config.db.point = { point, "UIParent", relPoint, x, y }
end

local function setLocked(locked)
    if not anchor then return end
    if locked then
        anchor:EnableMouse(false)
        anchor:SetBackdropColor(0, 0, 0, 0)
        anchor:SetBackdropBorderColor(0, 0, 0, 0)
        anchor.label:Hide()
    else
        anchor:EnableMouse(true)
        anchor:SetBackdropColor(0, 0, 0, 0.4)
        anchor:SetBackdropBorderColor(1, 0.8, 0, 1)
        anchor.label:Show()
    end
    if CC.config and CC.config.db then
        CC.config.db.locked = locked and true or false
    end
end

local function layoutBars()
    if not anchor then return end
    local cfg = CC.config and CC.config.db
    local spacing = (cfg and cfg.barSpacing) or 2
    for i = 1, #bars do
        local b = bars[i]
        b:ClearAllPoints()
        if i == 1 then
            b:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
            b:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
        else
            b:SetPoint("TOPLEFT", bars[i - 1], "BOTTOMLEFT", 0, -spacing)
            b:SetPoint("TOPRIGHT", bars[i - 1], "BOTTOMRIGHT", 0, -spacing)
        end
    end
end

local function buildAnchor()
    local cfg = CC.config and CC.config.db
    local width  = (cfg and cfg.barWidth)  or 180
    local height = 16

    anchor = CreateFrame("Frame", "CinosCurseAnchor", UIParent)
    anchor:SetWidth(width)
    anchor:SetHeight(height)
    anchor:SetMovable(true)
    anchor:SetClampedToScreen(true)
    anchor:RegisterForDrag("LeftButton")
    anchor:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })

    anchor:SetScript("OnDragStart", function(self) self:StartMoving() end)
    anchor:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        savePoint()
    end)

    local label = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER", anchor, "CENTER", 0, 0)
    label:SetText("CinosCurse")
    label:SetTextColor(1, 0.82, 0, 1)
    anchor.label = label

    applyPoint(anchor, cfg and cfg.point)
    CC.ui.anchor = anchor
end

local function buildBars()
    local cfg = CC.config and CC.config.db
    local count  = (cfg and cfg.maxBars)   or 10
    local width  = (cfg and cfg.barWidth)  or 180
    local height = (cfg and cfg.barHeight) or 22

    for i = 1, count do
        local b = CC.bar:Create(anchor, i, width, height)
        bars[i] = b
    end
end

function CC.ui:Build()
    if anchor then return end
    buildAnchor()
    buildBars()
    layoutBars()
    setLocked(CC.config and CC.config.db and CC.config.db.locked or false)
    self:StartUpdater()
end

-- ---------------------------------------------------------------------------
-- Update loop: pull sorted mob list from scanner, paint bars.
--
-- Slot assignment policy (stable):
--   * Whenever possible, keep an existing slot->mob binding. A bar only
--     gets reassigned when its mob disappears from the visible list.
--     This prevents flicker when same-name mobs swap priority due to
--     small HP/sort wobbles.
--   * Out of combat: emptied slots are immediately refilled from the
--     leftover priority list (any mob is fair game).
--   * In combat: emptied slots can only be refilled with a mob whose
--     name matches the slot's last-applied secure macrotext, since we
--     cannot rewrite secure attributes under lockdown.
-- ---------------------------------------------------------------------------

local UPDATE_INTERVAL = 0.1
local accum = 0
local updaterFrame

-- slotAssign[i] = { name = "...", guid = "..." } or nil
local slotAssign = {}
CC.ui.slotAssign = slotAssign

local function entryKey(e)
    return e.guid or ("name:" .. (e.name or ""))
end

local function slotKey(slot)
    return slot.guid or ("name:" .. (slot.name or ""))
end

-- Find a currently-resolving unit token whose UnitGUID matches `guid`.
-- Returns the token name (e.g. "raid3target") or nil. Used so that
-- external [@mouseover] macros can resolve to the bar's mob.
local function tokenForGuid(guid)
    if not guid then return nil end
    if UnitExists("target")    and UnitGUID("target")    == guid then return "target"    end
    if UnitExists("focus")     and UnitGUID("focus")     == guid then return "focus"     end
    if UnitExists("mouseover") and UnitGUID("mouseover") == guid then return "mouseover" end
    for i = 1, 4 do
        local t = "party" .. i .. "target"
        if UnitExists(t) and UnitGUID(t) == guid then return t end
    end
    for i = 1, 40 do
        local t = "raid" .. i .. "target"
        if UnitExists(t) and UnitGUID(t) == guid then return t end
    end
    if UnitExists("pettarget") and UnitGUID("pettarget") == guid then return "pettarget" end
    return nil
end

function CC.ui:Refresh()
    if not anchor or not CC.scanner then return end
    local cfg = CC.config and CC.config.db
    local maxBars = (cfg and cfg.maxBars) or 10
    local list = CC.scanner:GetSorted(maxBars)

    local present = {}
    for _, e in ipairs(list) do
        present[entryKey(e)] = e
    end

    local locked = InCombatLockdown()
    local taken = {}

    -- Phase 1: keep stable bindings. A slot whose mob is still in the
    -- list stays put (regardless of whether priority shuffled). A slot
    -- whose mob is gone gets cleared.
    for i = 1, maxBars do
        local b = bars[i]
        if not b then break end
        local slot = slotAssign[i]
        if slot then
            local k = slotKey(slot)
            local e = present[k]
            if e and not taken[k] then
                taken[k] = true
                b:SetHealth(e.hp or 0)
                b:SetRaidMark(e.mark or 0)
                b:SetDebuffs(e.guid and CC.curses:GetActive(e.guid) or nil)
                if b.SetStale then b:SetStale(false) end
                if not locked then b:SetUnit(tokenForGuid(e.guid)) end
            else
                -- Mob gone.
                if locked then
                    -- In combat we can't mutate secure attributes or
                    -- toggle visibility on a protected frame. Leave
                    -- the bar visible with its existing macrotext
                    -- (so what the user clicks matches what they
                    -- see) but grey it out to flag staleness. The
                    -- slot binding stays so PLAYER_REGEN_ENABLED can
                    -- clean up properly after combat.
                    if b.SetStale then b:SetStale(true) end
                    b:SetDebuffs(nil)
                else
                    slotAssign[i] = nil
                    b:ClearUnit()
                    b:Clear()
                end
            end
        end
    end

    -- Phase 2: fill empty slots from leftover entries in priority order.
    for _, e in ipairs(list) do
        local k = entryKey(e)
        if not taken[k] then
            for i = 1, maxBars do
                local b = bars[i]
                if b and not slotAssign[i] then
                    if locked then
                        if e.name == b.appliedName then
                            slotAssign[i] = { name = e.name, guid = e.guid }
                            taken[k] = true
                            b:SetHealth(e.hp or 0)
                            b:SetRaidMark(e.mark or 0)
                            b:SetDebuffs(e.guid and CC.curses:GetActive(e.guid) or nil)
                            b.nameText:SetText(e.name)
                            b:Show()
                            break
                        end
                    else
                        slotAssign[i] = { name = e.name, guid = e.guid }
                        taken[k] = true
                        b:SetMob(e.name, e.guid)
                        b:SetHealth(e.hp or 0)
                        b:SetUnit(tokenForGuid(e.guid))
                        b:SetRaidMark(e.mark or 0)
                        b:SetDebuffs(e.guid and CC.curses:GetActive(e.guid) or nil)
                        break
                    end
                end
            end
        end
    end

    -- Phase 3 (out of combat only): compact upward so we don't leave
    -- holes above filled slots. Stable bindings still apply within the
    -- compacted order — we just slide filled slots toward index 1 and
    -- preserve their relative order.
    if not locked then
        local write = 1
        for read = 1, maxBars do
            local slot = slotAssign[read]
            if slot then
                if read ~= write then
                    local src = bars[read]
                    local dst = bars[write]
                    slotAssign[write] = slot
                    slotAssign[read]  = nil
                    local e = present[slotKey(slot)]
                    if e then
                        dst:SetMob(e.name, e.guid)
                        dst:SetHealth(e.hp or 0)
                        dst:SetUnit(tokenForGuid(e.guid))
                        dst:SetRaidMark(e.mark or 0)
                        dst:SetDebuffs(e.guid and CC.curses:GetActive(e.guid) or nil)
                    end
                    src:ClearUnit()
                    src:Clear()
                end
                write = write + 1
            end
        end
    end
end

-- Fast path runs at ~20Hz (sufficient for visible HP/timer changes;
-- avoids per-frame GC churn from GetActive() and per-frame UnitGUID
-- spam from tokenForGuid()). Slow path stays at UPDATE_INTERVAL.
local FAST_INTERVAL = 0.05
local fastAccum = 0
local debuffBuf = {}

function CC.ui:StartUpdater()
    if updaterFrame then return end
    updaterFrame = CreateFrame("Frame")
    updaterFrame:SetScript("OnUpdate", function(_, elapsed)
        accum     = accum     + elapsed
        fastAccum = fastAccum + elapsed
        if fastAccum >= FAST_INTERVAL then
            fastAccum = 0
            -- Throttled fast path: repaint HP + debuff timers for
            -- already-assigned slots. No slot reassignment, no SetMob,
            -- no secure attribute writes — cheap and combat-safe.
            -- tokenForGuid is intentionally NOT called here; the slow
            -- path (Refresh) handles unit-token resolution.
            local cfg = CC.config and CC.config.db
            local maxBars = (cfg and cfg.maxBars) or 10
            local mobs = CC.scanner.mobs
            local tGuid = UnitGUID("target")
            local tName = (not tGuid) and UnitName("target") or nil
            for i = 1, maxBars do
                local b = bars[i]
                local slot = slotAssign[i]
                if b and slot then
                    local entry = slot.guid and mobs[slot.guid]
                                  or mobs["name:" .. slot.name]
                    if entry then
                        b:SetHealth(entry.hp or 0)
                    end
                    if slot.guid then
                        b:SetDebuffs(CC.curses:GetActive(slot.guid, nil, debuffBuf))
                    end
                    -- Target indicator: show when this bar's mob is
                    -- the player's current target. Match by GUID when
                    -- available (most reliable), otherwise by name.
                    local targeted = false
                    if slot.guid and tGuid and slot.guid == tGuid then
                        targeted = true
                    elseif tName and slot.name == tName and not slot.guid then
                        targeted = true
                    end
                    if b.SetTargeted then b:SetTargeted(targeted) end
                end
            end
        end
        -- Throttled slow path: full re-sort, slot reassignment, secure
        -- macrotext rewrites, [@mouseover] unit-token refresh.
        if accum >= UPDATE_INTERVAL then
            accum = 0
            CC.ui:Refresh()
        end
    end)
end

CC:RegisterEvent("PLAYER_LOGIN", function()
    CC.ui:Build()
end)

-- After combat ends, flush any deferred secure-attribute rewrites and
-- force a full refresh so slots can re-bind freely.
CC:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    for _, b in ipairs(bars) do
        if b.FlushPending then b:FlushPending() end
    end
    CC.ui:Refresh()
end)

-- ---------------------------------------------------------------------------
-- Slash subcommands
-- ---------------------------------------------------------------------------

function CC.ui:HandleSlash(msg)
    local cmd, rest = msg:match("^(%S+)%s*(.-)$")
    cmd = cmd or msg

    if cmd == "lock" then
        setLocked(true)
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r " .. (L["LOCK"] or "locked"))
    elseif cmd == "unlock" then
        setLocked(false)
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r " .. (L["UNLOCK"] or "unlocked"))
    elseif cmd == "reset" then
        if CC.config and CC.config.db then
            CC.config.db.point = { unpack(DEFAULT_POINT) }
        end
        if anchor then applyPoint(anchor, DEFAULT_POINT) end
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r " .. (L["RESET"] or "reset"))
    elseif cmd == "show" then
        for i, b in ipairs(bars) do
            b:SetMob("Test Mob " .. i, nil)
            b:SetHealth(1 - (i - 1) / #bars)
        end
    elseif cmd == "hide" then
        for _, b in ipairs(bars) do b:Clear() end
    elseif cmd == "dump" then
        local n = 0
        for _, e in pairs(CC.scanner.mobs) do
            n = n + 1
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "  %s | guid=%s | hp=%.2f | mark=%d",
                e.name or "?", tostring(e.guid), e.hp or 0, e.mark or 0))
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r " .. n .. " mob(s) tracked")
    elseif cmd == "quick" then
        if InCombatLockdown() then
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r cannot change quick-curse during combat")
            return
        end
        if rest == nil or rest == "" then
            local q = CC.config and CC.config.db and CC.config.db.quickCurse or "(none)"
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r quick-curse: " .. q)
            DEFAULT_CHAT_FRAME:AddMessage("  use |cffffff00/cinoscurse quick <Spell Name>|r to change")
            return
        end
        if CC.config and CC.config.db then
            CC.config.db.quickCurse = rest
        end
        for _, b in ipairs(bars) do
            if b.ApplySecure then b:ApplySecure() end
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r quick-curse set to: " .. rest)
    elseif cmd == "track" then
        local cfg = CC.config and CC.config.db
        if not cfg then return end
        cfg.trackedSpells = cfg.trackedSpells or {}
        if rest == nil or rest == "" then
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r tracked spells (in addition to defaults):")
            for _, s in ipairs(cfg.trackedSpells) do
                DEFAULT_CHAT_FRAME:AddMessage("  - " .. s)
            end
            return
        end
        table.insert(cfg.trackedSpells, rest)
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r now tracking: " .. rest)
    elseif cmd == "untrack" then
        local cfg = CC.config and CC.config.db
        if not (cfg and cfg.trackedSpells) then return end
        local low = (rest or ""):lower()
        for i = #cfg.trackedSpells, 1, -1 do
            if cfg.trackedSpells[i]:lower() == low then
                table.remove(cfg.trackedSpells, i)
                DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r stopped tracking: " .. rest)
                return
            end
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r not tracked: " .. (rest or ""))
    elseif cmd == "ignore" then
        local cfg = CC.config and CC.config.db
        if not cfg then return end
        cfg.ignoredNames = cfg.ignoredNames or {}
        if rest == nil or rest == "" then
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r ignored substrings:")
            for _, s in ipairs(cfg.ignoredNames) do
                DEFAULT_CHAT_FRAME:AddMessage("  - " .. s)
            end
            return
        end
        table.insert(cfg.ignoredNames, rest)
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r ignoring substring: " .. rest)
    elseif cmd == "unignore" then
        local cfg = CC.config and CC.config.db
        if not (cfg and cfg.ignoredNames) then return end
        local low = (rest or ""):lower()
        for i = #cfg.ignoredNames, 1, -1 do
            if cfg.ignoredNames[i]:lower() == low then
                table.remove(cfg.ignoredNames, i)
                DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r unignored: " .. rest)
                return
            end
        end
    elseif cmd == "size" then
        if InCombatLockdown() then
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r cannot resize during combat")
            return
        end
        local n = tonumber(rest)
        if not n or n < 1 or n > 40 then
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r usage: /cinoscurse size <1-40>")
            return
        end
        if CC.config and CC.config.db then
            CC.config.db.maxBars = n
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r bar count set to " .. n .. ". /reload to apply.")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r " .. (L["UNKNOWN_CMD"] or "unknown"))
    end
end
