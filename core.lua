-- CinosCurse / core.lua
-- Addon table, event dispatch, SavedVariables bootstrap, slash command.
-- Milestone M0: skeleton only.

local ADDON_NAME = ...

CinosCurse = CinosCurse or {}
local CC = CinosCurse
CC.NAME = "CinosCurse"
CC.VERSION = "0.0.1"

-- Submodule namespaces (populated by other files).
CC.scanner = CC.scanner or {}
CC.curses  = CC.curses  or {}
CC.ui      = CC.ui      or {}
CC.bar     = CC.bar     or {}
CC.config  = CC.config  or {}
CC.L       = CC.L       or {}

-- ---------------------------------------------------------------------------
-- Event dispatch
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame", "CinosCurseEventFrame", UIParent)
CC.eventFrame = frame

local handlers = {}
CC._handlers = handlers

function CC:RegisterEvent(event, handler)
    if not handlers[event] then
        handlers[event] = {}
        frame:RegisterEvent(event)
    end
    table.insert(handlers[event], handler)
end

frame:SetScript("OnEvent", function(self, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], event, ...)
        if not ok then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff5555CinosCurse error in " .. event .. ":|r " .. tostring(err))
        end
    end
end)

-- ---------------------------------------------------------------------------
-- ADDON_LOADED
-- ---------------------------------------------------------------------------

CC:RegisterEvent("ADDON_LOADED", function(_, name)
    if name ~= ADDON_NAME then return end

    if CC.config and CC.config.Init then
        CC.config:Init()
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r v" .. CC.VERSION ..
        " loaded. Type |cffffff00/cinoscurse|r for commands.")
end)

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

SLASH_CINOSCURSE1 = "/cinoscurse"
SLASH_CINOSCURSE2 = "/cc"

SlashCmdList["CINOSCURSE"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd = msg:match("^(%S+)")
    local lower = cmd and cmd:lower() or ""

    if msg == "" or lower == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCinosCurse|r commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffff00/cinoscurse lock|r / |cffffff00unlock|r / |cffffff00reset|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffff00/cinoscurse size <1-40>|r        - bar pool size (reload)")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffff00/cinoscurse quick <Spell>|r      - right-click cast spell")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffff00/cinoscurse track <Spell>|r      - track an extra spell")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffff00/cinoscurse untrack <Spell>|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffff00/cinoscurse ignore <substr>|r    - ignore mob name substring")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffff00/cinoscurse unignore <substr>|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffff00/cinoscurse show|r / |cffffff00hide|r / |cffffff00dump|r  - debug")
        return
    end

    -- Pass through with cmd lowercased but rest preserved.
    local rest = msg:sub(#cmd + 1):gsub("^%s+", "")
    local payload = lower
    if rest ~= "" then payload = payload .. " " .. rest end

    if CC.ui and CC.ui.HandleSlash then
        CC.ui:HandleSlash(payload)
    end
end
