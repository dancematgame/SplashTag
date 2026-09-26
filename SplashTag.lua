local ADDON_NAME = ...
local MACRO_NAME = "Splashtag"
local ART_PATH = "Interface\\AddOns\\SplashTag\\TuxedoMask"

local SplashTagDB
local mainFrame, configFrame, targetBox, selectedSpellText, zoneDropdown
local currentTarget
local customTargetActive = false
local mobButtons, spellButtons = {}, {}

local function clearButtons(t)
    for _, b in ipairs(t) do b:Hide(); b:SetParent(nil) end
    wipe(t)
end

local function sortedZones()
    local t = {}
    for z in pairs(SplashTagZones or {}) do t[#t+1] = z end
    table.sort(t)
    return t
end

local function getDetectedZone()
    local zone

    if C_Map and C_Map.GetBestMapForUnit and C_Map.GetMapInfo then
        local mapID = C_Map.GetBestMapForUnit("player")
        if mapID then
            local info = C_Map.GetMapInfo(mapID)
            if info then zone = info.name end
        end
    end

    if (not zone or zone == "") and GetZoneText then
        zone = GetZoneText()
    end

    return zone
end

local function currentZone()
    if SplashTagDB.zoneMode and SplashTagDB.zoneMode ~= "AUTO" then
        if SplashTagZones[SplashTagDB.zoneMode] then
            return SplashTagDB.zoneMode
        end
        return nil
    end

    local zone = getDetectedZone()
    if zone and SplashTagZones[zone] then
        return zone
    end

    return nil
end

local function refreshZoneDropdown()
    if not zoneDropdown then return end

    local mode = SplashTagDB.zoneMode or "AUTO"
    local text = mode == "AUTO" and "Auto-detect" or mode

    if UIDropDownMenu_SetSelectedValue then
        UIDropDownMenu_SetSelectedValue(zoneDropdown, mode)
    end
    if UIDropDownMenu_SetText then
        UIDropDownMenu_SetText(zoneDropdown, text)
    end
end

local function fullSpell(name, rank)
    if rank and rank ~= "" then return name .. "(" .. rank .. ")" end
    return name
end

-- Compatibility scan: WoW Forever may expose one of several Classic-era APIs.
local function getInstantSpells()
    local result, seen = {}, {}

    if not C_SpellBook or not C_Spell then
        return result
    end

    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0

    local function looksDamaging(spellID, name)
        -- Prefer the client-provided harmful-spell classification where available.
        if C_Spell.IsSpellHarmful and spellID then
            local ok = C_Spell.IsSpellHarmful(spellID)
            if ok ~= nil then return ok end
        end
        if IsHarmfulSpell then
            local ok = IsHarmfulSpell(spellID or name)
            if ok ~= nil then return ok end
        end

        -- If Forever exposes neither classifier, do not guess from spell names/tooltips.
        return false
    end

    local function addSpell(name, subName, spellID)
        if not name then return end

        local spellInfo
        if spellID and C_Spell.GetSpellInfo then
            spellInfo = C_Spell.GetSpellInfo(spellID)
        elseif C_Spell.GetSpellInfo then
            spellInfo = C_Spell.GetSpellInfo(name)
        end
        if not spellInfo then return end

        local castMS = spellInfo.castTime
        if castMS == nil then castMS = spellInfo.castTimeMS end

        local isAttack = (name == "Attack")
        if isAttack or (castMS == 0 and looksDamaging(spellID, name)) then
            local rank = subName or spellInfo.subName or ""
            local full = name
            if rank ~= "" then full = name .. "(" .. rank .. ")" end

            if not seen[full] then
                seen[full] = true
                result[#result+1] = {
                    full = full,
                    name = name,
                    spellID = spellID,
                    icon = spellInfo.iconID or spellInfo.iconFileID,
                    isAttack = isAttack,
                }
            end
        end
    end

    if C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookSkillLineInfo then
        local numLines = C_SpellBook.GetNumSpellBookSkillLines() or 0
        for line = 1, numLines do
            local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if lineInfo then
                local offset = lineInfo.itemIndexOffset or lineInfo.offset or 0
                local count = lineInfo.numSpellBookItems or lineInfo.numSlots or 0
                for itemIndex = offset + 1, offset + count do
                    local name, subName
                    if C_SpellBook.GetSpellBookItemName then
                        name, subName = C_SpellBook.GetSpellBookItemName(itemIndex, bank)
                    end

                    local spellID
                    if C_SpellBook.GetSpellBookItemInfo then
                        local itemInfo = C_SpellBook.GetSpellBookItemInfo(itemIndex, bank)
                        if type(itemInfo) == "table" then
                            spellID = itemInfo.spellID or itemInfo.actionID
                        elseif type(itemInfo) == "number" then
                            spellID = itemInfo
                        end
                    end

                    addSpell(name, subName, spellID)
                end
            end
        end
    end

    table.sort(result, function(a, b)
        if a.isAttack ~= b.isAttack then return a.isAttack end
        return a.full < b.full
    end)

    return result
end

local function setMacro(mob, suppressTargetMessage, isCustomTarget)
    local idx = GetMacroIndexByName(MACRO_NAME)
    if not idx or idx == 0 then
        print("|cffff5555SplashTag:|r Could not find macro '"..MACRO_NAME.."'.")
        return false
    end
    if InCombatLockdown and InCombatLockdown() then
        print("|cffff5555SplashTag:|r The macro cannot be changed during combat.")
        return false
    end
    if not SplashTagDB.spell then
        print("|cffffcc00SplashTag:|r Choose a tagging spell in Config first.")
        return false
    end

    currentTarget = mob
    local name, icon = GetMacroInfo(idx)
    local action
    if SplashTagDB.spell == "Attack" then
        action = "/startattack"
    else
        action = "/cast " .. SplashTagDB.spell
    end

    EditMacro(idx, name, icon, "/target " .. mob .. "\n" .. action)

    customTargetActive = isCustomTarget == true
    if targetBox then
        targetBox:SetText(mob)
    end

    if not suppressTargetMessage then
        print("|cff33ff99SplashTag:|r Target changed to |cffffffff" .. mob .. "|r")
    end
    return true
end

local function refreshMacroForSpell()
    if currentTarget then
        setMacro(currentTarget, true, customTargetActive)
        return
    end

    -- Recover the current /target from the existing Splashtag macro if the
    -- addon was reloaded before a mob was clicked this session.
    local idx = GetMacroIndexByName(MACRO_NAME)
    if idx and idx ~= 0 then
        local _, _, body = GetMacroInfo(idx)
        if body then
            local mob = string.match(body, "/target%s+([^\r\n]+)")
            if mob and mob ~= "" then
                setMacro(mob, true)
            end
        end
    end
end

-- MAIN WINDOW: restored to the v3 layout/sizing.
local function normaliseMob(entry)
    if type(entry) ~= "string" then return nil, false end

    -- A trailing * in Zones.lua marks a priority/contested target.
    -- Strip it before display sorting and, crucially, before /target.
    local priority = string.sub(entry, -1) == "*"
    local name = priority and string.sub(entry, 1, -2) or entry
    return name, priority
end

local function refreshMain()
    clearButtons(mobButtons)
    local zone = currentZone()

    local source = SplashTagZones[zone] or {}
    local mobs = {}

    for _, entry in ipairs(source) do
        local name, priority = normaliseMob(entry)
        if name and name ~= "" then
            mobs[#mobs+1] = { name=name, priority=priority }
        end
    end

    table.sort(mobs, function(a,b)
        return string.lower(a.name) < string.lower(b.name)
    end)

    local visibleRows = 5
    local rowHeight = 24
    mainFrame:SetHeight(40 + (visibleRows * rowHeight) + 12)

    local scroll = mainFrame.mobScroll
    if not scroll then
        scroll = CreateFrame("ScrollFrame", "SplashTagMobScroll", mainFrame, "UIPanelScrollFrameTemplate")
        mainFrame.mobScroll = scroll
        scroll:SetPoint("TOPLEFT", 10, -32)
        scroll:SetPoint("BOTTOMRIGHT", -29, 10)

        local child = CreateFrame("Frame", nil, scroll)
        mainFrame.mobChild = child
        child:SetWidth(185)
        child:SetHeight(1)
        scroll:SetScrollChild(child)
    end

    local child = mainFrame.mobChild
    child:SetHeight(math.max(#mobs, visibleRows) * rowHeight)

    for i, mob in ipairs(mobs) do
        local b = CreateFrame("Button", nil, child)
        b:SetHeight(rowHeight - 2)
        b:SetPoint("TOPLEFT", 0, -((i-1)*rowHeight))
        b:SetPoint("RIGHT", child, "RIGHT", 0, 0)

        local hi = b:CreateTexture(nil, "HIGHLIGHT")
        hi:SetAllPoints()
        hi:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hi:SetBlendMode("ADD")

        local text = b:CreateFontString(nil, "OVERLAY", mob.priority and "GameFontNormal" or "GameFontHighlight")
        text:SetPoint("LEFT", 5, 0)
        text:SetPoint("RIGHT", -5, 0)
        text:SetJustifyH("LEFT")

        if mob.priority then
            -- Gold star + gold name makes rare/contested targets obvious without widening the window.
            text:SetText("|cffffd100" .. mob.name .. " *|r")
        else
            text:SetText(mob.name)
        end

        b:SetScript("OnClick", function() setMacro(mob.name, false, false) end)
        mobButtons[#mobButtons+1] = b
    end
end

local function refreshSelectedSpell()
    if selectedSpellText then
        selectedSpellText:SetText(SplashTagDB.spell or "None selected")
    end
end

local function buildSpellList()
    clearButtons(spellButtons)
    local spells = getInstantSpells()
    local child = configFrame.spellChild
    child:SetHeight(math.max(1, #spells) * 27)

    if #spells == 0 then
        local fs = child:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        fs:SetPoint("TOPLEFT", 8, -8)
        fs:SetText("No instant spells detected.")
        child.emptyText = fs
        return
    end

    if child.emptyText then child.emptyText:Hide(); child.emptyText = nil end

    for i, spell in ipairs(spells) do
        local b = CreateFrame("Button", nil, child)
        b:SetHeight(25)
        b:SetPoint("TOPLEFT", 0, -((i-1)*27))
        b:SetPoint("RIGHT", child, "RIGHT", 0, 0)

        local hi = b:CreateTexture(nil, "HIGHLIGHT")
        hi:SetAllPoints()
        hi:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hi:SetBlendMode("ADD")

        if spell.icon then
            local icon = b:CreateTexture(nil, "ARTWORK")
            icon:SetSize(21,21)
            icon:SetPoint("LEFT", 2, 0)
            icon:SetTexture(spell.icon)
        end

        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", spell.icon and 29 or 5, 0)
        fs:SetText(spell.full)

        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if spell.spellID and GameTooltip.SetSpellByID then
                GameTooltip:SetSpellByID(spell.spellID)
            elseif GameTooltip.SetText then
                GameTooltip:SetText(spell.full)
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        b:SetScript("OnClick", function()
            SplashTagDB.spell = spell.full
            refreshSelectedSpell()
            refreshMacroForSpell()
            print("|cff33ff99SplashTag:|r Tagging Spell changed to |cffffffff" .. spell.full .. "|r")
        end)
        spellButtons[#spellButtons+1] = b
    end
end

local function createConfig()
    if configFrame then
        buildSpellList()
        refreshSelectedSpell()
        refreshZoneDropdown()
        configFrame:Show()
        return
    end

    local f = CreateFrame("Frame", "SplashTagConfigFrame", UIParent, "BasicFrameTemplateWithInset")
    configFrame = f
    f:SetSize(700, 500)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("TOP", 0, -7)
    f.title:SetText("SplashTag v1.0")

    local zoneLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    zoneLabel:SetPoint("TOPLEFT", 22, -48)
    zoneLabel:SetText("Zone :")

    zoneDropdown = CreateFrame("Frame", "SplashTagZoneDropdown", f, "UIDropDownMenuTemplate")
    zoneDropdown:SetPoint("TOPLEFT", 58, -38)
    UIDropDownMenu_SetWidth(zoneDropdown, 220)

    UIDropDownMenu_Initialize(zoneDropdown, function(self, level)
        local info = UIDropDownMenu_CreateInfo()
        info.text = "Auto-detect"
        info.value = "AUTO"
        info.checked = (SplashTagDB.zoneMode or "AUTO") == "AUTO"
        info.func = function()
            SplashTagDB.zoneMode = "AUTO"
            refreshZoneDropdown()
            refreshMain()
        end
        UIDropDownMenu_AddButton(info, level)

        for _, zone in ipairs(sortedZones()) do
            local zoneInfo = UIDropDownMenu_CreateInfo()
            zoneInfo.text = zone
            zoneInfo.value = zone
            zoneInfo.checked = SplashTagDB.zoneMode == zone
            zoneInfo.func = function()
                SplashTagDB.zoneMode = zone
                refreshZoneDropdown()
                refreshMain()
            end
            UIDropDownMenu_AddButton(zoneInfo, level)
        end
    end)

    local spellLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    spellLabel:SetPoint("TOPLEFT", 22, -92)
    spellLabel:SetText("Current Tagging Spell :")

    selectedSpellText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    selectedSpellText:SetPoint("TOPLEFT", 22, -113)
    selectedSpellText:SetWidth(355)
    selectedSpellText:SetJustifyH("LEFT")

    local spellBorder = CreateFrame("Frame", nil, f, "BackdropTemplate")
    spellBorder:SetSize(390, 248)
    spellBorder:SetPoint("TOPLEFT", 20, -137)
    spellBorder:SetBackdrop({
        bgFile="Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize=12,
        insets={left=4,right=4,top=4,bottom=4},
    })

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", spellBorder, "TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", spellBorder, "BOTTOMRIGHT", -28, 8)

    local child = CreateFrame("Frame", nil, scroll)
    f.spellChild = child
    child:SetWidth(320); child:SetHeight(1)
    scroll:SetScrollChild(child)

    -- Tuxedo Mask is important. He is the glue that holds the addon together.
    local art = f:CreateTexture(nil, "ARTWORK")
    art:SetSize(311, 390)
    art:SetPoint("TOPRIGHT", 10, -50)
    art:SetTexture(ART_PATH)
    art:SetTexCoord(0, 1, 0, 1)

    local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    close:SetSize(170, 30)
    close:SetPoint("BOTTOMRIGHT", -45, 16)
    close:SetText("Close")
    close:SetScript("OnClick", function() f:Hide() end)

    refreshSelectedSpell()
    refreshZoneDropdown()
    buildSpellList()
end

local function createMain()
    local f = CreateFrame("Frame", "SplashTagFrame", UIParent, "BackdropTemplate")
    mainFrame = f
    f:SetSize(230,182)
    f:SetPoint("CENTER")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true,tileSize=32,edgeSize=16,
        insets={left=4,right=4,top=4,bottom=4},
    })
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    targetBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    targetBox:SetHeight(20)
    targetBox:SetPoint("TOPLEFT", 14, -9)
    targetBox:SetPoint("RIGHT", f, "RIGHT", -43, 0)
    targetBox:SetAutoFocus(false)
    targetBox:SetMaxLetters(100)

    targetBox:SetScript("OnEnterPressed", function(self)
        local mob = self:GetText()
        mob = mob and string.gsub(mob, "^%s*(.-)%s*$", "%1") or ""
        if mob ~= "" then
            setMacro(mob, false, true)
            self:ClearFocus()
        end
    end)

    targetBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    local configButton = CreateFrame("Button", nil, f)
    configButton:SetSize(24,24)
    configButton:SetPoint("TOPRIGHT",-10,-7)

    -- Same simple cog presentation as v3, but ASCII-safe fallback if glyph unsupported.
    local gear = configButton:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    gear:SetPoint("CENTER")
    gear:SetText("*")

    configButton:SetScript("OnClick", function()
        if configFrame and configFrame:IsShown() then configFrame:Hide() else createConfig() end
    end)

    local macroIndex = GetMacroIndexByName(MACRO_NAME)
    if macroIndex and macroIndex ~= 0 then
        local _, _, body = GetMacroInfo(macroIndex)
        if body then
            local mob = string.match(body, "/target%s+([^\r\n]+)")
            if mob and mob ~= "" then
                currentTarget = mob
                customTargetActive = false
                targetBox:SetText(mob)
            end
        end
    end

    refreshMain()
end


SLASH_SPLASHTAG1 = "/st"
SlashCmdList["SPLASHTAG"] = function()
    createConfig()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("ZONE_CHANGED")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:RegisterEvent("ZONE_CHANGED_INDOORS")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        SplashTagSaved = SplashTagSaved or {}

        local characterName = UnitName("player") or "Unknown"
        local realmName = GetRealmName and GetRealmName() or ""
        local characterKey = characterName .. "-" .. realmName

        SplashTagSaved.characters = SplashTagSaved.characters or {}
        SplashTagSaved.characters[characterKey] = SplashTagSaved.characters[characterKey] or {}
        SplashTagDB = SplashTagSaved.characters[characterKey]

        if SplashTagDB.zoneMode == nil then
            -- Migrate an older saved forced zone if one exists; otherwise new characters use Auto-detect.
            if SplashTagDB.zone and SplashTagZones[SplashTagDB.zone] then
                SplashTagDB.zoneMode = "AUTO"
            else
                SplashTagDB.zoneMode = "AUTO"
            end
        elseif SplashTagDB.zoneMode ~= "AUTO" and not SplashTagZones[SplashTagDB.zoneMode] then
            SplashTagDB.zoneMode = "AUTO"
        end

        SplashTagDB.zone = nil
        createMain()
        print("|cff33ff99SplashTag|r - Select a spell with |cffffffff/st|r")
    elseif event == "SPELLS_CHANGED" and configFrame and configFrame:IsShown() then
        buildSpellList()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED_INDOORS" then
        if mainFrame and SplashTagDB and (SplashTagDB.zoneMode or "AUTO") == "AUTO" then
            refreshMain()
            refreshZoneDropdown()
        end
    end
end)
