-- CinosCurse / bar.lua
-- Single-bar widget factory.
-- Milestone M1: visual scaffolding + SecureActionButton base. No casting
-- wiring yet (that's M3/M5).

CinosCurse = CinosCurse or {}
local CC = CinosCurse
CC.bar = CC.bar or {}

local BACKDROP = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 8, edgeSize = 8,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
}

local STATUSBAR_TEX = "Interface\\TargetingFrame\\UI-StatusBar"

-- Bar method table.
local BarProto = {}

function BarProto:SetMob(name, guid)
    self.mobName = name
    self.mobGuid = guid
    if name then
        self.nameText:SetText(name)
        if self.SetStale then self:SetStale(false) end
        self:ApplySecure()
        self:Show()
    else
        self:Clear()
    end
end

function BarProto:Clear()
    self.mobName = nil
    self.mobGuid = nil
    self.nameText:SetText("")
    self.nameText:SetTextColor(1, 1, 1, 1)
    self.hpBar:SetValue(0)
    if self.raidMark then self.raidMark:Hide() end
    if self.targetIndicator then self.targetIndicator:Hide() end
    if self.debuffIcons then
        for _, ic in ipairs(self.debuffIcons) do ic:Hide() end
    end
    -- Wipe secure attributes so a blank bar can't fire a stale
    -- /targetexact at the previous occupant. Combat-safe: caller must
    -- only invoke Clear() out of combat (ui.lua handles the in-combat
    -- case by leaving the bar populated-but-stale).
    if not InCombatLockdown() then
        self.appliedName = nil
        self.appliedUnit = nil
        self.pendingName = nil
        self:SetAttribute("type1",      nil)
        self:SetAttribute("macrotext1", nil)
        self:SetAttribute("type2",      nil)
        self:SetAttribute("macrotext2", nil)
        self:SetAttribute("unit",       nil)
    end
    self:SetAlpha(1)
    self:Hide()
end

-- Mark this bar as showing a mob we've lost track of (combat-only
-- fallback). We can't Hide() a protected frame in combat, but SetAlpha
-- is allowed, so we make it invisible. Mouse hits still register but
-- the user has nothing visible to click on.
function BarProto:SetStale(stale)
    if stale then
        self:SetAlpha(0)
        if self.targetIndicator then self.targetIndicator:Hide() end
    else
        self:SetAlpha(1)
    end
end

-- Show / hide the "this is your current target" arrow. Combat-safe.
function BarProto:SetTargeted(on)
    if not self.targetIndicator then return end
    if on then self.targetIndicator:Show() else self.targetIndicator:Hide() end
end

-- ApplySecure: rewrite the secure macrotext attributes for this bar.
-- 3.3.5a forbids mutating secure attributes during combat, so if we're
-- locked down we stash the desired name and re-apply on PLAYER_REGEN_ENABLED.
function BarProto:ApplySecure()
    local name = self.mobName
    if not name then return end
    if InCombatLockdown() then
        self.pendingName = name
        return
    end
    self.pendingName = nil
    self.appliedName = name
    self:SetAttribute("type1",      "macro")
    self:SetAttribute("macrotext1", "/targetexact " .. name)

    -- type2 (right-click cast) is wired in M5. Keep slot reserved.
    local quick = CinosCurse.config and CinosCurse.config.db and CinosCurse.config.db.quickCurse
    if quick and quick ~= "" then
        self:SetAttribute("type2",      "macro")
        self:SetAttribute("macrotext2", "/cast [@mouseover,harm,nodead] " .. quick)
    else
        self:SetAttribute("type2", nil)
    end
end

-- SetUnit: expose a unit token on this bar so external [@mouseover]
-- macros (and tooltips) resolve to this bar's mob when the cursor is
-- over it. Token must be a real, currently-resolving unit token
-- (target / focus / raidNtarget / partyNtarget / mouseover). No-op in
-- combat (the attribute will be refreshed on next out-of-combat tick).
function BarProto:SetUnit(token)
    if InCombatLockdown() then return end
    if self.appliedUnit == token then return end
    self.appliedUnit = token
    self:SetAttribute("unit", token)
end

function BarProto:ClearUnit()
    if InCombatLockdown() then return end
    if self.appliedUnit == nil then return end
    self.appliedUnit = nil
    self:SetAttribute("unit", nil)
end

-- Called by ui.lua on PLAYER_REGEN_ENABLED to flush deferred rewrites.
function BarProto:FlushPending()
    if self.pendingName and self.pendingName ~= self.appliedName then
        self:ApplySecure()
    end
end

function BarProto:SetHealth(pct)
    self.hpBar:SetValue(pct or 0)
end

function BarProto:SetRaidMark(idx)
    if not self.raidMark then return end
    if not idx or idx == 0 then
        self.raidMark:Hide()
        return
    end
    SetRaidTargetIconTexture(self.raidMark, idx)
    self.raidMark:Show()
end

function BarProto:SetDebuffs(list)
    -- list: array of curse entries (sorted by expiration ascending), or nil.
    local icons = self.debuffIcons
    if not icons then return end
    local now = GetTime()
    for i = 1, #icons do
        local ic = icons[i]
        local e  = list and list[i]
        if e and (e.expiration or 0) > now then
            ic.texture:SetTexture(e.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            local remaining = (e.expiration or 0) - now
            -- Format: <10s shows decimals, otherwise integer seconds.
            if remaining < 10 then
                ic.text:SetFormattedText("%.1f", remaining)
            else
                ic.text:SetFormattedText("%d", math.floor(remaining + 0.5))
            end
            -- Color the timer text red when <3s (about to expire).
            if remaining < 3 then
                ic.text:SetTextColor(1, 0.3, 0.3)
            else
                ic.text:SetTextColor(1, 1, 1)
            end
            if e.stack and e.stack > 1 then
                ic.stack:SetText(e.stack)
                ic.stack:Show()
            else
                ic.stack:Hide()
            end
            ic:Show()
        else
            ic:Hide()
        end
    end
end

-- Factory --------------------------------------------------------------------

function CC.bar:Create(parent, index, width, height)
    local name = "CinosCurseBar" .. index
    local btn = CreateFrame("Button", name, parent, "SecureActionButtonTemplate,SecureUnitButtonTemplate")
    btn:SetWidth(width)
    btn:SetHeight(height)
    btn:RegisterForClicks("AnyUp")
    btn:Hide()

    -- Hook standard unit-button mouse handlers so the bar participates
    -- in the same mouseover/tooltip pipeline as Blizzard unit frames.
    -- This is what makes [@mouseover] macros resolve to the bar's
    -- current `unit` attribute.
    btn:SetScript("OnEnter", function(self)
        local u = self:GetAttribute("unit")
        if u and UnitExists(u) then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetUnit(u)
        end
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    btn:SetBackdrop(BACKDROP)
    btn:SetBackdropColor(0, 0, 0, 0.6)
    btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

    local hp = CreateFrame("StatusBar", nil, btn)
    hp:SetStatusBarTexture(STATUSBAR_TEX)
    hp:SetStatusBarColor(0.6, 0.1, 0.1, 0.85)
    hp:SetMinMaxValues(0, 1)
    hp:SetValue(0)
    hp:SetPoint("TOPLEFT", btn, "TOPLEFT", 3, -3)
    hp:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -3, 3)
    btn.hpBar = hp

    -- Name text is parented to the hp bar (and uses an OVERLAY child
    -- frame so it always renders above the bar's status texture, with
    -- a thin black outline for readability against any HP color).
    local textHost = CreateFrame("Frame", nil, hp)
    textHost:SetAllPoints(hp)
    textHost:SetFrameLevel(hp:GetFrameLevel() + 5)
    local nameText = textHost:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- Apply an outline manually for readability on red/green HP fills.
    local font, size = nameText:GetFont()
    if font then
        nameText:SetFont(font, size or 11, "OUTLINE")
    end
    nameText:SetPoint("LEFT", textHost, "LEFT", 6, 0)
    nameText:SetPoint("RIGHT", textHost, "RIGHT", -4, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetTextColor(1, 1, 1, 1)
    btn.nameText = nameText

    -- Raid target marker, anchored OUTSIDE the left edge of the bar so
    -- pre-marked pulls are easy to spot at a glance.
    local mark = btn:CreateTexture(nil, "OVERLAY")
    local MARK_SIZE = height
    mark:SetWidth(MARK_SIZE)
    mark:SetHeight(MARK_SIZE)
    mark:SetPoint("RIGHT", btn, "LEFT", -2, 0)
    mark:Hide()
    btn.raidMark = mark

    -- Target indicator: a yellow ">" just outside the left edge,
    -- positioned further left so it doesn't overlap the raid mark.
    local tih = CreateFrame("Frame", nil, btn)
    tih:SetPoint("RIGHT", mark, "LEFT", -1, 0)
    tih:SetWidth(10)
    tih:SetHeight(height)
    tih:SetFrameLevel(btn:GetFrameLevel() + 6)
    local ti = tih:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    do
        local f, s = ti:GetFont()
        if f then ti:SetFont(f, (s or 14) + 2, "OUTLINE") end
    end
    ti:SetPoint("CENTER", tih, "CENTER", 0, 0)
    ti:SetText(">")
    ti:SetTextColor(1, 0.85, 0.1, 1)
    ti:Hide()
    btn.targetIndicator = ti

    -- Debuff icon row, anchored OUTSIDE the bar to its right edge,
    -- growing further right as more icons appear. Icons are parented to
    -- the bar so they hide/show with it but live in their own visual
    -- region.
    local NUM_ICONS = 5
    local ICON_SIZE = height - 2
    btn.debuffIcons = {}
    for i = 1, NUM_ICONS do
        local ic = CreateFrame("Frame", nil, btn)
        ic:SetWidth(ICON_SIZE)
        ic:SetHeight(ICON_SIZE)
        if i == 1 then
            ic:SetPoint("LEFT", btn, "RIGHT", 4, 0)
        else
            ic:SetPoint("LEFT", btn.debuffIcons[i - 1], "RIGHT", 2, 0)
        end
        local tex = ic:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints(ic)
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ic.texture = tex
        local txt = ic:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        txt:SetPoint("CENTER", ic, "CENTER", 0, 0)
        txt:SetTextColor(1, 1, 1, 1)
        ic.text = txt
        local stack = ic:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        stack:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT", 1, 0)
        stack:SetTextColor(1, 1, 0, 1)
        stack:Hide()
        ic.stack = stack
        ic:Hide()
        btn.debuffIcons[i] = ic
    end

    -- Now that icons are external, name text can use the full bar width.
    nameText:ClearAllPoints()
    nameText:SetPoint("LEFT", textHost, "LEFT", 6, 0)
    nameText:SetPoint("RIGHT", textHost, "RIGHT", -4, 0)
    nameText:SetJustifyH("LEFT")

    for k, v in pairs(BarProto) do btn[k] = v end

    btn.index = index
    return btn
end
