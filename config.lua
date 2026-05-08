-- CinosCurse / config.lua
-- SavedVariables defaults and initialization.
-- Milestone M0: scaffolding only.

CinosCurse = CinosCurse or {}
local CC = CinosCurse
CC.config = CC.config or {}

local DEFAULTS = {
    locked       = false,
    point        = { "CENTER", "UIParent", "CENTER", 0, 0 },
    maxBars      = 10,
    barWidth     = 180,
    barHeight    = 22,
    barSpacing   = 2,
    quickCurse   = "Curse of Agony",
    trackedSpells = {
        -- lowercase spell names (no rank). Filled in per-class later.
    },
    ignoredNames = {
        -- substrings to skip, e.g. "whelp"
    },
}

local function deepCopy(t)
    local o = {}
    for k, v in pairs(t) do
        if type(v) == "table" then o[k] = deepCopy(v) else o[k] = v end
    end
    return o
end

local function applyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            if type(v) == "table" then
                target[k] = deepCopy(v)
            else
                target[k] = v
            end
        elseif type(v) == "table" and type(target[k]) == "table" then
            applyDefaults(target[k], v)
        end
    end
end

function CC.config:Init()
    CinosCurseDB = CinosCurseDB or {}
    applyDefaults(CinosCurseDB, DEFAULTS)
    self.db = CinosCurseDB
end

function CC.config:Get(key)
    return self.db and self.db[key]
end

function CC.config:Set(key, value)
    if self.db then self.db[key] = value end
end
