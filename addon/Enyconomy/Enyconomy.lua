-- Enyconomy: Helfer fürs Enyconomy-Dashboard
--   SniperList.lua  -> legt die Sniper-Liste in Auktionator an (Einfügen großer Listen friert das Spiel ein)
--   RealmPrices.lua -> Tooltip mit den Preisen auf deinen Realms
-- Beide Dateien kommen aus dem Dashboard (Tab Sniper-Liste), danach /reload.

local function out(msg) print("|cffffd100Enyconomy|r " .. msg) end

local function cfg()
    EnyconomyDB = EnyconomyDB or {}
    local c = EnyconomyDB
    -- Altlasten der früheren Herstellen/Einkauf-Version entfernen
    c.recipes, c.targets, c.stock = nil, nil, nil
    c.mode, c.craftGroup, c.craftOnlyTarget, c.craftOnlyMissing, c.shopMissing = nil, nil, nil, nil, nil
    return c
end

-- Sniper-Liste aus SniperList.lua (vom Dashboard) in Auktionator anlegen
local function ImportSniperList(force)
    local data = EnyconomySniperData
    if not (data and data.terms and #data.terms > 0) then
        if force then out("Keine Sniper-Liste gefunden. SniperList.lua aus dem Dashboard ins Addon-Verzeichnis kopieren, dann /reload.") end
        return
    end
    if not force and cfg().sniperCreated == data.created then return end
    if not (Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.CreateShoppingList) then
        return out("Auktionator ist nicht geladen.")
    end
    local ok, err = pcall(Auctionator.API.v1.CreateShoppingList, "Enyconomy", data.name or "Enyconomy Sniper", data.terms)
    if ok then
        cfg().sniperCreated = data.created
        out(string.format("Auktionator-Liste '%s' mit %d Einträgen angelegt.", data.name or "Enyconomy Sniper", #data.terms))
    else
        out("Auktionator-Fehler: " .. tostring(err))
    end
end

-- Tooltip: günstigster Preis auf deinen Realms (aus RealmPrices.lua vom Dashboard)
local function RealmGold(g)
    if g >= 1000 then
        local s = tostring(g):reverse():gsub("(%d%d%d)", "%1."):reverse()
        return (s:gsub("^%.", "")) .. "g"
    end
    return g .. "g"
end

local function AddRealmPrices(tt, itemID)
    local data = EnyconomyRealmData
    if not (data and data.items and itemID) then return end
    local raw = data.items[itemID]
    if not raw then return end  -- Waren und nie angebotene Items: kein Eintrag
    local here = GetRealmName()
    local ages = time() - (data.created or time())
    tt:AddLine(string.format("Enyconomy Realms |cff808080(Stand vor %s)|r",
        ages < 3600 and (math.floor(ages / 60) .. " min") or (math.floor(ages / 3600) .. " h")), 1, 0.82, 0)
    local parts = raw and { strsplit(",", raw) } or {}
    for i, realm in ipairs(data.realms or {}) do
        local isHere = false
        for _, m in ipairs(realm.members or {}) do
            if m == here then isHere = true end
        end
        local name = realm.name .. (isHere and " (hier)" or "")
        local g, q = (parts[i] or ""):match("^(%d+):(%d+)$")
        if g then
            tt:AddDoubleLine("  " .. name, string.format("%s  |cff808080x%s|r", RealmGold(tonumber(g)), q), 1, 1, 1, 1, 1, 1)
        else
            tt:AddDoubleLine("  " .. name, "nicht im AH", 1, 1, 1, 0.5, 0.5, 0.5)
        end
    end
end

if TooltipDataProcessor and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, tdata)
        if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
        local id = tdata and tdata.id
        if not id and tt.GetItem then
            local _, link = tt:GetItem()
            id = link and C_Item.GetItemInfoInstant(link)
        end
        if id then AddRealmPrices(tt, id) end
    end)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    cfg()
    C_Timer.After(5, function() ImportSniperList(false) end)
end)

SLASH_ENYCONOMY1 = "/eny"
SLASH_ENYCONOMY2 = "/enyconomy"
SlashCmdList.ENYCONOMY = function(msg)
    local cmd = ((msg or ""):match("^(%S*)") or ""):lower()
    if cmd == "sniper" then
        ImportSniperList(true)
    else
        out("/eny sniper - Sniper-Liste aus SniperList.lua neu in Auktionator anlegen")
    end
end
