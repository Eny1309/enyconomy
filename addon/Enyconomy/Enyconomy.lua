-- Enyconomy: Handelsfenster auf Basis von AH-Vollscan + TSM-Daten
--   Tab "Lücken":    Items mit Nachfrage, aber wenig/keinem Angebot auf diesem Realm
--   Tab "Deals":     Items, deren Mindestpreis deutlich unter dem regionalen Verkaufs-Ø liegt
--   Tab "Herstellen": alle Rezepte deiner Twinks mit Bestand, eigenen Auktionen und Gewinn
-- Benoetigt TradeSkillMaster (TSM_API).

local f = CreateFrame("Frame")
local ahOpen, waiting = false, false

local RAW_MAX_LISTINGS = 10   -- Lücken: max. Angebote fuer Rohdaten
local RAW_MIN_SOLD = 0.1      -- min. Verkäufe/Tag fuer Rohdaten
local DEAL_MIN_GAP = 1.10     -- Deals: Verkaufs-Ø mind. 10 % ueber Mindestpreis (Rohdaten)
local PET_CAGE = 82800
local AH_CUT = 0.95
local BATCH = 1500

-- Verkaufswert fuer Hergestelltes (wie in CraftSim): niedrigerer Wert aus Realm-Preis und Region-Verkaufs-Ø
local SALE_FORMULA = "min(first(DBRecent, DBMinBuyout), first(DBRegionSaleAvg, DBRecent, DBMinBuyout))"

local defaults = {
    mode = "gaps",
    maxListings = 3, minSold = 1, minPrice = 0,          -- Lücken
    dealPct = 25, dealSold = 0.1, dealProfit = 10,      -- Deals
    craftGroup = "", craftSold = 0, craftEmpty = true,  -- Herstellen
    realmPct = 30, realmSold = 0.1, realmProfit = 50,   -- Realms
    realmOwned = false,
    shopMissing = true,                                 -- Einkauf
    search = "",
}

local function cfg()
    EnyconomyDB = EnyconomyDB or {}
    for k, v in pairs(defaults) do
        if EnyconomyDB[k] == nil then EnyconomyDB[k] = v end
    end
    if EnyconomyDB.mode == "craftable" then EnyconomyDB.mode = "craft" end
    EnyconomyDB.seen = EnyconomyDB.seen or {}
    EnyconomyDB.recipes = EnyconomyDB.recipes or {}
    EnyconomyDB.realms = EnyconomyDB.realms or {}   -- [Realm] = { time, items = { [id] = { n, min } } }
    EnyconomyDB.stack = EnyconomyDB.stack or {}     -- [id] = true wenn stapelbar (Commodity)
    EnyconomyDB.names = EnyconomyDB.names or {}     -- [id] = Itemname aus dem Scan (fuer die Suche)
    return EnyconomyDB
end

local function out(msg) print("|cffffd100Enyconomy|r " .. msg) end

local function gold(c)
    if not c then return "-" end
    return string.format("%dg", math.floor(c / 10000 + 0.5))
end

local function goldSigned(c)
    if not c then return "-" end
    local g = math.floor(c / 10000 + 0.5)
    local col = g >= 0 and "|cff40ff40" or "|cffff4040"
    return string.format("%s%+dg|r", col, g)
end

local function num1(v) return v and string.format("%.1f", v) or "-" end
local function int(v) return v and tostring(v) or "-" end
local function pct(v) return v and string.format("%+d%%", v) or "-" end
local function txt(v) return v or "-" end
local function stock(v)
    if not v then return "-" end
    if v == 0 then return "|cffff4040" .. v .. "|r" end
    return tostring(v)
end

local function tsm(source, itemID)
    if not TSM_API then return nil end
    local ok, v = pcall(TSM_API.GetCustomPriceValue, source, "i:" .. itemID)
    if ok then return v end
end

---------------------------------------------------------------------------
-- Bestand: TSM (alle Chars, Taschen/Bank/Post/AH) + Kriegsmeuten-Bank
---------------------------------------------------------------------------
local function TsmTotals(id)
    if not (TSM_API and TSM_API.GetPlayerTotals) then return nil end
    local ok, player, alts, auctions, altAuctions = pcall(TSM_API.GetPlayerTotals, "i:" .. id)
    if not ok then return nil end
    return (player or 0) + (alts or 0), (auctions or 0) + (altAuctions or 0)
end

local function Warbank(id)
    local ok1, withWarbank = pcall(C_Item.GetItemCount, id, false, false, false, true)
    local ok2, bags = pcall(C_Item.GetItemCount, id, false, false, false, false)
    if ok1 and ok2 and withWarbank and bags then return math.max(0, withWarbank - bags) end
    return 0
end

local function Stock(id)
    local have, ah = TsmTotals(id)
    if not have then return nil, nil end
    return have + Warbank(id), ah
end

local function GroupOf(id)
    if not (TSM_API and TSM_API.GetGroupPathByItem) then return nil end
    local ok, path = pcall(TSM_API.GetGroupPathByItem, "i:" .. id)
    if not ok or not path then return nil end
    if TSM_API.FormatGroupPath then
        local ok2, nice = pcall(TSM_API.FormatGroupPath, path)
        if ok2 and nice then return nice end
    end
    return (path:gsub("`", " > "))
end

---------------------------------------------------------------------------
-- Rezepte merken (beim Oeffnen eines Berufsfensters, kontoweit)
---------------------------------------------------------------------------
local function CaptureRecipes()
    if not C_TradeSkillUI or not C_TradeSkillUI.GetAllRecipeIDs then return end
    if C_TradeSkillUI.IsTradeSkillLinked and C_TradeSkillUI.IsTradeSkillLinked() then return end
    if C_TradeSkillUI.IsTradeSkillGuild and C_TradeSkillUI.IsTradeSkillGuild() then return end

    local c = cfg()
    local info = C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
    local prof = info and info.professionName or "?"
    local who = UnitName("player")
    local added, total = 0, 0

    for _, rid in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
        local ri = C_TradeSkillUI.GetRecipeInfo(rid)
        if ri and ri.learned and not ri.isRecraft then
            local s = C_TradeSkillUI.GetRecipeSchematic(rid, false)
            local id = s and s.outputItemID
            if id then
                total = total + 1
                local e = c.recipes[id]
                if not e then e = {}; c.recipes[id] = e; added = added + 1 end
                e.prof, e.who = prof, who
                local link = C_TradeSkillUI.GetRecipeItemLink and C_TradeSkillUI.GetRecipeItemLink(rid)
                if link then e.link = link end
            end
        end
    end
    if added > 0 then
        out(string.format("%s: %d Rezepte erfasst (%d neu).", prof, total, added))
    end
end

---------------------------------------------------------------------------
-- Tabs: Spalten und Filter
---------------------------------------------------------------------------
local MODE_ORDER = { "gaps", "deals", "craft", "realms", "shop" }
local win
local Refresh, ApplyFilter, StartScan, SelectTab, MakeAuctionatorList

local MODES = {
    gaps = {
        label = "Lücken", default = "score", needsScan = true,
        cols = {
            { key = "name", title = "Item",   w = 260 },
            { key = "spd",  title = "/Tag",   w = 55, fmt = num1 },
            { key = "n",    title = "Da",     w = 45, fmt = int },
            { key = "min",  title = "Ab",     w = 75, fmt = gold },
            { key = "avg",  title = "Region", w = 75, fmt = gold },
            { key = "diff", title = "%",      w = 55, fmt = pct },
        },
        filters = {
            { key = "maxListings", label = "Max. Angebote",  type = "num", w = 50 },
            { key = "minSold",     label = "Min. /Tag",      type = "num", w = 50 },
            { key = "minPrice",    label = "Min. Preis (g)", type = "num", w = 60 },
        },
        hint = "Wenig Angebot, aber Nachfrage. Werte aus dem letzten Scan.",
    },
    deals = {
        label = "Deals", default = "profit", needsScan = true,
        cols = {
            { key = "name",    title = "Item",    w = 245 },
            { key = "spd",     title = "/Tag",    w = 50, fmt = num1 },
            { key = "dealPct", title = "Ø über",  w = 55, fmt = pct },
            { key = "min",     title = "Ab",      w = 75, fmt = gold },
            { key = "sale",    title = "Verk. Ø", w = 75, fmt = gold },
            { key = "profit",  title = "Gewinn",  w = 75, fmt = goldSigned },
        },
        filters = {
            { key = "dealPct",    label = "Min. Abstand %",  type = "num", w = 50 },
            { key = "dealSold",   label = "Min. /Tag",       type = "num", w = 50 },
            { key = "dealProfit", label = "Min. Gewinn (g)", type = "num", w = 60 },
        },
        hint = "Günstig angeboten im Vergleich zum regionalen Verkaufs-Ø.",
    },
    craft = {
        label = "Herstellen", default = "profit", needsScan = false,
        cols = {
            { key = "name",   title = "Item",    w = 200 },
            { key = "who",    title = "Wer",     w = 75, fmt = txt },
            { key = "have",   title = "Lager",   w = 45, fmt = stock },
            { key = "ah",     title = "Mein AH", w = 50, fmt = int },
            { key = "n",      title = "Markt",   w = 45, fmt = int },
            { key = "spd",    title = "/Tag",    w = 45, fmt = num1 },
            { key = "profit", title = "Gewinn",  w = 70, fmt = goldSigned },
        },
        filters = {
            { key = "craftGroup", label = "TSM-Gruppe enthält", type = "text", w = 120 },
            { key = "craftSold",  label = "Min. /Tag",          type = "num",  w = 50 },
            { key = "craftEmpty", label = "Nur leer",           type = "check" },
        },
        hint = "Lager = alle Chars + Kriegsmeuten-Bank. Markt = Angebote beim letzten Scan.",
    },
    realms = {
        label = "Realms", default = "profit", needsScan = true,
        cols = {
            { key = "name",      title = "Item",         w = 175 },
            { key = "spd",       title = "/Tag",         w = 35, fmt = num1 },
            { key = "buyMin",    title = "Hier",         w = 65, fmt = gold },
            { key = "bestRealm", title = "Bester Realm", w = 100, fmt = txt },
            { key = "sellMin",   title = "Dort",         w = 65, fmt = gold },
            { key = "paid",      title = "Bezahlt",      w = 60, fmt = gold },
            { key = "profit",    title = "Gewinn",       w = 70, fmt = goldSigned },
        },
        filters = {
            { key = "realmPct",    label = "Min. Abstand %",  type = "num", w = 45 },
            { key = "realmSold",   label = "Min. /Tag",       type = "num", w = 40 },
            { key = "realmProfit", label = "Min. Gewinn (g)", type = "num", w = 55 },
            { key = "realmOwned",  label = "Nur Bestand",     type = "check" },
        },
        hint = "",
    },
    shop = {
        label = "Einkauf", default = "cost", needsScan = false,
        cols = {
            { key = "name",    title = "Material",   w = 230 },
            { key = "need",    title = "Bedarf",     w = 55, fmt = int },
            { key = "have",    title = "Vorhanden",  w = 65, fmt = int },
            { key = "missing", title = "Fehlt",      w = 55, fmt = stock },
            { key = "price",   title = "Preis",      w = 75, fmt = gold },
            { key = "cost",    title = "Kosten",     w = 85, fmt = gold },
        },
        filters = {
            { key = "shopMissing", label = "Nur fehlende", type = "check" },
            { key = "_auct", label = "Auktionator-Liste erstellen", type = "button", w = 190,
              onClick = function() MakeAuctionatorList() end },
        },
        hint = "Bedarf = alle Rezepte der TSM-Warteschlange. Vorhanden = alle Chars des Realms + Kriegsmeuten-Bank, einmal gezählt.",
    },
}

-- Gespeicherte Realm-Scans ausser dem aktuellen Realm
local function OtherRealms()
    local list, here = {}, GetRealmName()
    for name in pairs(cfg().realms) do
        if name ~= here then list[#list + 1] = name end
    end
    table.sort(list)
    return list
end

-- Einkaufspreise aus TSM-Accounting, kontoweit ueber alle Realms
local paidCache
local function LoadPaid()
    paidCache = {}
    local db = _G.TradeSkillMasterDB
    if type(db) ~= "table" then return paidCache end
    for key, val in pairs(db) do
        if type(key) == "string" and type(val) == "string" then
            local realm = key:match("^r@(.-)@internalData@csvBuys$")
            if realm then
                for line in val:gmatch("[^\n]+") do
                    local itemString, _, qty, price, _, _, t = strsplit(",", line)
                    local id = itemString and tonumber(itemString:match("^i:(%d+)"))
                    qty, price, t = tonumber(qty), tonumber(price), tonumber(t)
                    if id and qty and price and t then
                        local list = paidCache[id]
                        if not list then list = {}; paidCache[id] = list end
                        list[#list + 1] = { q = qty, p = price, t = t, realm = realm }
                    end
                end
            end
        end
    end
    for _, list in pairs(paidCache) do
        table.sort(list, function(a, b) return a.t > b.t end)
    end
    return paidCache
end

-- Durchschnittspreis der letzten gekauften Stuecke (so viele, wie man besitzt)
local function Paid(id, have)
    if not paidCache then LoadPaid() end
    local list = paidCache[id]
    if not list then return nil end
    local need, q, sum = math.max(have or 1, 1), 0, 0
    for _, b in ipairs(list) do
        local take = math.min(b.q, need - q)
        q, sum = q + take, sum + take * b.p
        if q >= need then break end
    end
    if q == 0 then return nil end
    return sum / q, list[1].realm, list[1].t
end

local function Age(ts)
    if not ts then return "?" end
    local d = time() - ts
    if d < 3600 then return string.format("%dmin", math.floor(d / 60)) end
    if d < 86400 then return string.format("%dh", math.floor(d / 3600)) end
    return string.format("%dT", math.floor(d / 86400))
end

-- Einkaufsliste aus der TSM-Warteschlange aller Chars (Bestand nur einmal gezaehlt)
local function ItemIdOf(key)
    local id = type(key) == "string" and key:match("^i:(%d+)")
    return id and tonumber(id)
end

local function BuildShopping()
    local db = _G.TradeSkillMasterDB
    if type(db) ~= "table" then return nil, "TSM-Daten nicht gefunden." end
    local fr = (UnitFactionGroup("player") or "?") .. " - " .. GetRealmName()
    local queue = db["f@" .. fr .. "@internalData@craftingQueue"]
    local crafts = db["f@" .. fr .. "@internalData@crafts"]
    if type(queue) ~= "table" or type(crafts) ~= "table" then
        return nil, "Keine TSM-Warteschlange für " .. fr .. " gefunden."
    end

    -- Bedarf: [Gruppe] = { ids = {...}, need = n }
    local entries, nRecipes, nCrafts, unknown = {}, 0, 0, 0
    for craftString, q in pairs(queue) do
        local n = type(q) == "number" and q
            or (type(q) == "table" and (q.num or q.quantity or q.count or q[1])) or 0
        local craft = crafts[craftString]
        if n > 0 and not craft then unknown = unknown + 1 end
        if n > 0 and craft and type(craft.mats) == "table" then
            nRecipes, nCrafts = nRecipes + 1, nCrafts + n
            for matKey, qty in pairs(craft.mats) do
                local ids
                if matKey:sub(1, 2) == "i:" then
                    local id = ItemIdOf(matKey)
                    if id then ids = { id } end
                elseif matKey:sub(1, 2) == "q:" then
                    -- Reagenz mit Qualitaetsstufen: jede Stufe zaehlt
                    ids = {}
                    for id in (matKey:match("^q:%d+:(.+)$") or ""):gmatch("%d+") do ids[#ids + 1] = tonumber(id) end
                end
                -- "o:" (optional) und "f:" (Veredelung) zaehlen nicht zum Pflichtbedarf
                if ids and #ids > 0 then
                    local gk = table.concat(ids, ",")
                    local e = entries[gk]
                    if not e then e = { ids = ids, need = 0 }; entries[gk] = e end
                    e.need = e.need + qty * n
                end
            end
        end
    end
    if nRecipes == 0 then
        return nil, "Die TSM-Warteschlange ist leer (oder TSM hat sie noch nicht gespeichert - dann /reload)."
    end

    -- Bestand: alle Chars dieses Realms (Taschen, Bank, Reagenzienbank, Post) + Kriegsmeuten-Bank
    local have = {}
    local function add(tbl)
        if type(tbl) ~= "table" then return end
        for k, v in pairs(tbl) do
            local id = ItemIdOf(k)
            if id and type(v) == "number" then have[id] = (have[id] or 0) + v end
        end
    end
    local suffix = " - " .. fr
    for key, val in pairs(db) do
        if type(key) == "string" and key:sub(1, 2) == "s@" then
            local who, what = key:match("^s@(.-)@internalData@(%a+)$")
            if who and who:sub(-#suffix) == suffix and (what == "bagQuantity" or what == "bankQuantity"
               or what == "reagentBankQuantity" or what == "mailQuantity") then
                add(val)
            end
        end
    end
    add(db["g@ @internalData@warbankQuantity"])

    local list, totalCost, missingItems = {}, 0, 0
    for _, e in pairs(entries) do
        local h = 0
        for _, id in ipairs(e.ids) do h = h + (have[id] or 0) end
        local id = e.ids[1]
        local name, link = C_Item.GetItemInfo(id)
        if not name then Item:CreateFromItemID(id):ContinueOnItemLoad(function()
            if win and win:IsShown() and cfg().mode == "shop" then C_Timer.After(0.3, ApplyFilter) end
        end) end
        local missing = math.max(0, e.need - h)
        local price = tsm("first(DBMinBuyout, DBMarket, DBRegionMarketAvg)", id)
        local cost = price and missing * price or nil
        if missing > 0 then
            missingItems = missingItems + 1
            totalCost = totalCost + (cost or 0)
        end
        list[#list + 1] = {
            id = id, ids = e.ids, name = name or ("Item " .. id), link = link,
            need = e.need, have = h, missing = missing, price = price, cost = cost,
        }
    end
    local info = string.format("%d Rezepte, %d Herstellungen | %d Materialien fehlen, ca. %s%s",
        nRecipes, nCrafts, missingItems, gold(totalCost),
        unknown > 0 and string.format(" | %d Rezepte ohne Materialdaten", unknown) or "")
    return list, info
end

-- Bester Verkaufs-Realm: hoechster Mindestpreis; fehlt das Item dort, gilt der Region-Verkaufs-Ø (geschaetzt)
local function BestSell(id, exclude)
    local c = cfg()
    local best, bestRealm, bestEst, sale
    for name, snap in pairs(c.realms) do
        if name ~= exclude then
            local s = snap.items[id]
            local p, est
            if s then p = s[2]
            else
                if sale == nil then sale = tsm("DBRegionSaleAvg", id) or false end
                p, est = sale or nil, true
            end
            if p and (not best or p > best or (p == best and bestEst and not est)) then
                best, bestRealm, bestEst = p, name, est
            end
        end
    end
    return best, bestRealm, bestEst
end

-- Stapelbarkeit pruefen; unbekannte Items nachladen und danach neu filtern
local stackPending = 0
local function KnownNonStack(id)
    local c = cfg()
    local st = c.stack[id]
    if st ~= nil then return not st end
    stackPending = stackPending + 1
    if C_Item.DoesItemExistByID(id) then
        Item:CreateFromItemID(id):ContinueOnItemLoad(function()
            local size = select(8, C_Item.GetItemInfo(id))
            c.stack[id] = (size or 1) > 1 or id == PET_CAGE
            stackPending = stackPending - 1
            if stackPending == 0 and win and win:IsShown() and c.mode == "realms" then
                C_Timer.After(0.2, ApplyFilter)
            end
        end)
    else
        c.stack[id] = true
        stackPending = stackPending - 1
    end
    return false
end

---------------------------------------------------------------------------
-- Fenster
---------------------------------------------------------------------------
local WIN_W, WIN_H = 680, 490
local LIST_W = WIN_W - 50
local ROW_H = 16
local MAX_COLS = 8

local rows = {}
local shown, sortKey, sortDesc = {}, "score", true

local function ColumnLayout(mode)
    local layout, x = {}, 0
    for i, col in ipairs(MODES[mode].cols) do
        layout[i] = { x = x, w = col.w }
        x = x + col.w + 5
    end
    return layout
end

local function SetStatus(text)
    if win then win.status:SetText(text or "") end
end

-- Filterleiste je Tab
local function BuildFilterPanel(mode)
    local p = CreateFrame("Frame", nil, win)
    p:SetPoint("TOPLEFT", 14, -62)
    p:SetSize(420, 40)
    p.widgets = {}
    local x = 0
    for i, flt in ipairs(MODES[mode].filters) do
        local label = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", x, 0)
        label:SetText(flt.label)
        local w
        if flt.type == "button" then
            label:SetText("")
            w = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
            w:SetSize(flt.w, 22)
            w:SetPoint("TOPLEFT", x, -12)
            w:SetText(flt.label)
            w:SetScript("OnClick", flt.onClick)
            x = x + flt.w + 12
        elseif flt.type == "realm" then
            -- Knopf, der durch die gescannten Realms blaettert
            w = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
            w:SetSize(flt.w, 20)
            w:SetPoint("TOPLEFT", x, -14)
            w:SetScript("OnClick", function(self)
                local c, list = cfg(), OtherRealms()
                if #list == 0 then return end
                local idx = 0
                for i, name in ipairs(list) do if name == c.realmOther then idx = i end end
                c.realmOther = list[idx % #list + 1]
                self:SetText(c.realmOther)
                ApplyFilter()
            end)
            x = x + flt.w + 12
        elseif flt.type == "check" then
            w = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
            w:SetSize(24, 24)
            w:SetPoint("TOPLEFT", x - 2, -12)
            w:SetScript("OnClick", function() ApplyFilter() end)
            x = x + math.max(label:GetStringWidth(), 30) + 16
        else
            w = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
            w:SetSize(flt.w, 20)
            w:SetPoint("TOPLEFT", x + 4, -14)
            w:SetAutoFocus(false)
            w:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyFilter() end)
            w:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
            x = x + math.max(label:GetStringWidth(), flt.w + 8) + 16
        end
        w.flt = flt
        p.widgets[i] = w
    end
    p:Hide()
    return p
end

local function LoadFilterValues(mode)
    local c = cfg()
    for _, w in ipairs(win.panels[mode].widgets) do
        local v = c[w.flt.key]
        if w.flt.type == "button" then
            -- nichts zu laden
        elseif w.flt.type == "realm" then
            local list = OtherRealms()
            local valid = false
            for _, name in ipairs(list) do if name == v then valid = true end end
            if not valid then c[w.flt.key] = list[1]; v = list[1] end
            w:SetText(v or "(keiner)")
        elseif w.flt.type == "check" then w:SetChecked(v and true or false)
        else w:SetText(tostring(v or "")) end
    end
end

local function ReadFilterValues(mode)
    local c = cfg()
    for _, w in ipairs(win.panels[mode].widgets) do
        local key = w.flt.key
        if w.flt.type == "realm" or w.flt.type == "button" then
            -- wird per Klick gesetzt
        elseif w.flt.type == "check" then
            c[key] = w:GetChecked() and true or false
        elseif w.flt.type == "text" then
            c[key] = strtrim(w:GetText() or "")
        else
            local v = tonumber(((w:GetText() or ""):gsub(",", ".")))
            if v then c[key] = v end
            w:SetText(tostring(c[key]))
        end
    end
end

local function LayoutHeaders(mode)
    local m = MODES[mode]
    local layout = ColumnLayout(mode)
    for i = 1, MAX_COLS do
        local h = win.headers[i]
        local col = m.cols[i]
        if col then
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", 14 + layout[i].x + 4, -130)
            h:SetSize(layout[i].w, 16)
            h.text:SetText(col.title)
            h.key = col.key
            h:Show()
        else
            h:Hide()
        end
    end
end

local function LayoutRow(r, mode)
    if r.layoutMode == mode then return end
    local layout = ColumnLayout(mode)
    for j = 1, MAX_COLS do
        local fs = r.cols[j]
        if layout[j] then
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", layout[j].x + 4, 0)
            fs:SetWidth(layout[j].w)
            fs:Show()
        else
            fs:Hide()
        end
    end
    r.layoutMode = mode
end

local function CreateWindow()
    win = CreateFrame("Frame", "EnyconomyFrame", UIParent, "BasicFrameTemplateWithInset")
    win:SetSize(WIN_W, WIN_H)
    win:SetPoint("CENTER")
    win:SetFrameStrata("HIGH")
    win:SetMovable(true)
    win:SetClampedToScreen(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    tinsert(UISpecialFrames, "EnyconomyFrame") -- schliessen mit ESC

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Enyconomy")

    -- Tabs
    win.tabs = {}
    for i, mode in ipairs(MODE_ORDER) do
        local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        b:SetSize(90, 22)
        b:SetPoint("TOPLEFT", 12 + (i - 1) * 92, -28)
        b:SetText(MODES[mode].label)
        b:SetScript("OnClick", function() SelectTab(mode) end)
        b.mode = mode
        win.tabs[i] = b
    end

    -- Trennlinie unter den Tabs
    local line = win:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.4)
    line:SetPoint("TOPLEFT", 12, -54)
    line:SetPoint("TOPRIGHT", -12, -54)
    line:SetHeight(1)

    -- Filterleisten (je Tab eine)
    win.panels = {}
    for _, mode in ipairs(MODE_ORDER) do win.panels[mode] = BuildFilterPanel(mode) end

    -- Aktionsknoepfe rechts
    local apply = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    apply:SetSize(90, 22)
    apply:SetPoint("TOPRIGHT", -108, -28)
    apply:SetText("Anwenden")
    apply:SetScript("OnClick", function() ApplyFilter() end)

    win.scanBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    win.scanBtn:SetSize(90, 22)
    win.scanBtn:SetPoint("TOPRIGHT", -14, -28)
    win.scanBtn:SetText("Scannen")
    win.scanBtn:SetScript("OnClick", function() StartScan() end)

    -- Suchfeld (alle Tabs)
    local sl = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sl:SetPoint("TOPLEFT", 16, -108)
    sl:SetText("Suche:")
    win.search = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
    win.search:SetSize(220, 20)
    win.search:SetPoint("LEFT", sl, "RIGHT", 10, 0)
    win.search:SetAutoFocus(false)
    win.search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    win.search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    local searchPending = false
    win.search:SetScript("OnTextChanged", function(self, user)
        if not user or searchPending then return end
        searchPending = true
        C_Timer.After(0.4, function() searchPending = false; ApplyFilter() end)
    end)
    win.searchHint = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    win.searchHint:SetPoint("LEFT", win.search, "RIGHT", 10, 0)
    win.searchHint:SetText("")

    -- Spaltenkoepfe (Klick = sortieren)
    win.headers = {}
    for i = 1, MAX_COLS do
        local b = CreateFrame("Button", nil, win)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.text:SetAllPoints()
        b.text:SetJustifyH("LEFT")
        b:SetScript("OnClick", function(self)
            if sortKey == self.key then sortDesc = not sortDesc
            else sortKey, sortDesc = self.key, (self.key ~= "name" and self.key ~= "who") end
            Refresh()
        end)
        win.headers[i] = b
    end

    local sf = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 10, -148)
    sf:SetPoint("BOTTOMRIGHT", -30, 44)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(LIST_W, 1)
    sf:SetScrollChild(content)
    win.content = content

    win.hint = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    win.hint:SetPoint("BOTTOMLEFT", 14, 26)
    win.hint:SetPoint("BOTTOMRIGHT", -14, 26)
    win.hint:SetJustifyH("LEFT")

    win.status = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    win.status:SetPoint("BOTTOMLEFT", 14, 10)
    win.status:SetPoint("BOTTOMRIGHT", -14, 10)
    win.status:SetJustifyH("LEFT")

    win:SetScript("OnShow", function()
        if cfg().mode == "craft" then ApplyFilter() end
    end)
end

local function GetRow(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, win.content)
    r:SetSize(LIST_W, ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    r.cols = {}
    for j = 1, MAX_COLS do
        local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        r.cols[j] = fs
    end
    r:SetScript("OnEnter", function(self)
        if not self.data then return end
        local d = self.data
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if d.link then GameTooltip:SetHyperlink(d.link) else GameTooltip:SetText(d.name or ("Item " .. d.id)) end
        GameTooltip:AddLine(" ")
        if d.prof then
            GameTooltip:AddLine("Herstellbar: " .. d.prof .. " (" .. (d.who or "?") .. ")", 0.2, 1, 0.6)
        end
        if d.group then GameTooltip:AddLine("TSM-Gruppe: " .. d.group, 0.6, 0.8, 1) end
        if d.cost then
            GameTooltip:AddDoubleLine("Herstellkosten", gold(d.cost), 1, 1, 1, 1, 1, 1)
        end
        if d.sale then
            GameTooltip:AddDoubleLine("Verkaufswert", gold(d.sale), 1, 1, 1, 1, 1, 1)
        end
        local c = cfg()
        if cfg().mode == "realms" then
            GameTooltip:AddLine("Preise pro Realm:", 1, 0.82, 0)
            local names = {}
            for name in pairs(c.realms) do names[#names + 1] = name end
            table.sort(names)
            for _, name in ipairs(names) do
                local snap = c.realms[name]
                local s = snap.items[d.id]
                local right = s and string.format("%s (%d)", gold(s[2]), s[1]) or "nicht da"
                GameTooltip:AddDoubleLine(name .. " |cff888888vor " .. Age(snap.ts) .. "|r", right,
                    1, 1, 1, s and 1 or 1, s and 1 or 0.5, s and 1 or 0.3)
            end
            if d.sellEstimated then
                GameTooltip:AddLine("* dort kein Angebot - geschätzt mit Region-Verkaufs-Ø", 1, 0.6, 0.2)
            end
        end
        local paid, paidRealm, paidTime = Paid(d.id, d.have)
        if paid then
            GameTooltip:AddDoubleLine("Bezahlt", string.format("%s (%s, %s)", gold(paid), paidRealm or "?",
                paidTime and date("%d.%m.", paidTime) or "?"), 1, 1, 1, 0.2, 1, 0.6)
        end
        GameTooltip:AddLine("Shift-Klick: Link in den Chat", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", GameTooltip_Hide)
    r:SetScript("OnClick", function(self)
        if self.data and self.data.link and IsModifiedClick("CHATLINK") then
            ChatEdit_InsertLink(self.data.link)
        end
    end)
    rows[i] = r
    return r
end

Refresh = function()
    if not win then return end
    local mode = cfg().mode
    local m = MODES[mode]
    local q = win.search and strtrim(win.search:GetText() or ""):lower() or ""
    if q ~= "" and not shown.searched then
        local filtered = {}
        for _, r in ipairs(shown) do
            local nm = r.name or (r.link and r.link:match("%[(.-)%]")) or cfg().names[r.id]
            if nm and nm:lower():find(q, 1, true) then filtered[#filtered + 1] = r end
        end
        shown = filtered
    end
    table.sort(shown, function(a, b)
        local x, y = a[sortKey], b[sortKey]
        if x == nil then return false end
        if y == nil then return true end
        if type(x) ~= type(y) then x, y = tostring(x), tostring(y) end
        if sortDesc then return x > y else return x < y end
    end)
    for i, r in ipairs(shown) do
        local row = GetRow(i)
        LayoutRow(row, mode)
        row.data = r
        row.cols[1]:SetText(r.link or r.name or ("Item " .. r.id))
        for j = 2, #m.cols do
            local col = m.cols[j]
            row.cols[j]:SetText(col.fmt(r[col.key]))
        end
        row:Show()
    end
    for i = #shown + 1, #rows do rows[i]:Hide() end
    win.content:SetHeight(math.max(1, #shown * ROW_H))
end

local function ScanInfo(c)
    return c.scanTime and (" | Scan: " .. c.scanTime .. (c.scanRealm and (" (" .. c.scanRealm .. ")") or "")) or ""
end

-- Liste fuer "Herstellen" aus Rezepten, Bestand und letztem Scan bauen
local function BuildCraftList()
    local c = cfg()
    local list = {}
    for id, e in pairs(c.recipes) do
        local link = e.link or select(2, C_Item.GetItemInfo(id))
        local sale = tsm(SALE_FORMULA, id)
        local cost = tsm("Crafting", id)
        local have, ah = Stock(id)
        list[#list + 1] = {
            id = id, link = link, prof = e.prof, who = e.who,
            name = link and link:match("%[(.-)%]") or tostring(id),
            group = GroupOf(id),
            have = have, ah = ah,
            n = c.lastCounts and c.lastCounts[id] or nil,
            spd = tsm("DBRegionSoldPerDay", id),
            cost = cost, sale = sale,
            profit = (sale and cost) and (sale * AH_CUT - cost) or nil,
        }
    end
    return list
end

ApplyFilter = function()
    local c = cfg()
    local mode = c.mode
    if win then ReadFilterValues(mode) end

    shown = {}

    if mode == "craft" then
        local nRec = 0
        for _ in pairs(c.recipes) do nRec = nRec + 1 end
        local grp = (c.craftGroup or ""):lower()
        for _, r in ipairs(BuildCraftList()) do
            local ok = (r.spd or 0) >= c.craftSold
            if ok and grp ~= "" then
                ok = r.group and r.group:lower():find(grp, 1, true) ~= nil
            end
            if ok and c.craftEmpty then
                ok = r.have ~= nil and (r.have + (r.ah or 0)) == 0
            end
            if ok then shown[#shown + 1] = r end
        end
        Refresh()
        if nRec == 0 then
            SetStatus("Noch keine Rezepte. Auf jedem Twink einmal das Berufsfenster öffnen.")
        elseif not TSM_API then
            SetStatus("TSM ist nicht geladen - kein Bestand und keine Preise.")
        else
            SetStatus(string.format("%d von %d Rezepten%s", #shown, nRec, ScanInfo(c)))
        end
        return
    end

    if mode == "shop" then
        local list, info = BuildShopping()
        if not list then
            Refresh()
            return SetStatus(info)
        end
        for _, r in ipairs(list) do
            if not c.shopMissing or r.missing > 0 then shown[#shown + 1] = r end
        end
        Refresh()
        return SetStatus(info)
    end

    if mode == "realms" then
        local here = GetRealmName()
        local names = {}
        for name in pairs(c.realms) do names[#names + 1] = name end
        table.sort(names)
        local ages = {}
        for _, name in ipairs(names) do
            ages[#ages + 1] = name .. ": " .. Age(c.realms[name].ts)
        end
        if win then
            win.hint:SetText(#ages > 0 and ("Scans - " .. table.concat(ages, "  |  "))
                or "Noch keine Realm-Scans. Auf jedem Realm einmal scannen.")
        end
        if #names < 2 then
            Refresh()
            return SetStatus("Für den Vergleich braucht es Scans von mindestens zwei Realms.")
        end
        paidCache = nil
        local A = c.realms[here]
        local q = win and strtrim(win.search:GetText() or ""):lower() or ""

        local function makeRow(id)
            local a = A and A.items[id]
            local buyMin = a and a[2]
            local have = Stock(id)
            local best, bestRealm, est = BestSell(id, (not c.realmOwned and q == "") and here or nil)
            local paid = Paid(id, have)
            local basis = paid or buyMin
            local nm = c.names[id] or C_Item.GetItemNameByID(id)
            local _, link = C_Item.GetItemInfo(id)
            return {
                id = id, name = nm, link = link, have = have,
                spd = tsm("DBRegionSoldPerDay", id),
                buyMin = buyMin, paid = paid,
                bestRealm = bestRealm and (bestRealm .. (est and "*" or "")) or nil,
                sellMin = best, sellEstimated = est,
                profit = (basis and best) and (best * AH_CUT - basis) or nil,
            }
        end

        if q ~= "" then
            -- Suche: alle passenden Items aller Realms, ohne die anderen Filter
            local done = {}
            for _, name in ipairs(names) do
                for id in pairs(c.realms[name].items) do
                    if not done[id] then
                        done[id] = true
                        local nm = c.names[id] or C_Item.GetItemNameByID(id)
                        if nm and nm:lower():find(q, 1, true) and c.stack[id] ~= true then
                            shown[#shown + 1] = makeRow(id)
                        end
                    end
                end
            end
            shown.searched = true
            Refresh()
            return SetStatus(string.format("Suche: %d Treffer (Filter ignoriert)", #shown))
        end

        if c.realmOwned then
            -- Alles, was du besitzt und mal gekauft hast: wo verkauft es sich am besten?
            if not paidCache then LoadPaid() end
            for id in pairs(paidCache) do
                local have = Stock(id)
                if have and have > 0 and c.stack[id] ~= true then
                    local r = makeRow(id)
                    if r.sellMin and (r.spd or 0) >= c.realmSold then shown[#shown + 1] = r end
                end
            end
            Refresh()
            return SetStatus(string.format("%d Items im Bestand | Gewinn = Bester Preis nach Gebühr - Bezahlt", #shown))
        end

        if not A then
            Refresh()
            return SetStatus("Für " .. here .. " gibt es noch keinen Scan. Erst hier scannen.")
        end
        for id, a in pairs(A.items) do
            local buyMin = a[2]
            if buyMin and buyMin > 0 and c.stack[id] ~= true then
                local best = BestSell(id, here)
                if best and best >= buyMin * (1 + c.realmPct / 100)
                   and (best * AH_CUT - buyMin) >= c.realmProfit * 10000 then
                    local spd = tsm("DBRegionSoldPerDay", id) or 0
                    if spd >= c.realmSold and KnownNonStack(id) then
                        local r = makeRow(id)
                        r.profit = r.sellMin and (r.sellMin * AH_CUT - buyMin) or nil
                        shown[#shown + 1] = r
                    end
                end
            end
        end
        Refresh()
        SetStatus(string.format("%d Items: hier (%s) kaufen, woanders verkaufen%s", #shown, here,
            stackPending > 0 and string.format(" | lade %d Items ...", stackPending) or ""))
        return
    end

    if not c.raw then
        Refresh()
        return SetStatus("Noch kein Scan. Auktionshaus öffnen und 'Scannen' klicken.")
    end

    local total = 0
    for _, r in ipairs(c.raw) do
        if mode == "deals" then
            if r.deal then
                total = total + 1
                if r.dealPct >= c.dealPct and r.spd >= c.dealSold
                   and r.profit >= c.dealProfit * 10000 then
                    shown[#shown + 1] = r
                end
            end
        elseif r.gap then
            total = total + 1
            if r.n <= c.maxListings and r.spd >= c.minSold
               and (r.avg or 0) >= c.minPrice * 10000 then
                shown[#shown + 1] = r
            end
        end
    end
    Refresh()
    SetStatus(string.format("%d von %d Items%s", #shown, total, ScanInfo(c)))
end

SelectTab = function(mode)
    local c = cfg()
    c.mode = mode
    for _, b in ipairs(win.tabs) do
        if b.mode == mode then b:Disable() else b:Enable() end
    end
    for m, p in pairs(win.panels) do
        if m == mode then p:Show() else p:Hide() end
    end
    LoadFilterValues(mode)
    LayoutHeaders(mode)
    win.hint:SetText(MODES[mode].hint or "")
    sortKey, sortDesc = MODES[mode].default, true
    ApplyFilter()
end

MakeAuctionatorList = function()
    local list = BuildShopping()
    if not list then return SetStatus("Keine Warteschlange - nichts zu erstellen.") end
    if not (Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.CreateShoppingList) then
        return SetStatus("Auktionator ist nicht geladen.")
    end
    local terms = {}
    for _, r in ipairs(list) do
        if r.missing > 0 and r.name and not r.name:match("^Item %d+$") then
            local ok, term = pcall(Auctionator.API.v1.ConvertToSearchString, "Enyconomy",
                { searchString = r.name, isExact = true, quantity = r.missing })
            if not ok or not term then
                term = string.format('"%s";;0;0;0;0;0;0;0;0;;#;;%d', r.name, r.missing)
            end
            terms[#terms + 1] = term
        end
    end
    if #terms == 0 then return SetStatus("Es fehlt nichts - alles vorhanden.") end
    local ok, err = pcall(Auctionator.API.v1.CreateShoppingList, "Enyconomy", "Enyconomy Einkauf", terms)
    if ok then
        SetStatus(string.format("Auktionator-Liste 'Enyconomy Einkauf' mit %d Einträgen erstellt.", #terms))
    else
        SetStatus("Auktionator-Fehler: " .. tostring(err))
    end
end

local function OpenWindow(mode)
    if not win then CreateWindow() end
    win:Show()
    SelectTab(mode or cfg().mode)
end

---------------------------------------------------------------------------
-- Scan
---------------------------------------------------------------------------
-- Namen nachladen, Stapelbares (Commodities) und Haustierkaefige aussortieren
local function Finalize(cands)
    local c = cfg()
    local pending, done, final = #cands, false, {}

    local function finish()
        if done then return end
        done = true
        c.raw = final
        OpenWindow()
        if win.scanBtn then win.scanBtn:Enable() end
    end

    if pending == 0 then return finish() end

    local function one(r, ok)
        if ok then
            local name, link, _, _, _, _, _, stack = C_Item.GetItemInfo(r.id)
            if link then c.stack[r.id] = (stack or 1) > 1 or r.id == PET_CAGE end
            if link and (stack or 1) <= 1 and r.id ~= PET_CAGE then
                r.link, r.name = link, name
                if r.min and r.avg and r.avg > 0 then
                    r.diff = math.floor((r.min / r.avg - 1) * 100 + 0.5)
                end
                final[#final + 1] = r
            end
        end
        pending = pending - 1
        if pending == 0 then finish() end
    end

    SetStatus(string.format("Lade %d Itemnamen ...", pending))
    for _, r in ipairs(cands) do
        if C_Item.DoesItemExistByID(r.id) then
            Item:CreateFromItemID(r.id):ContinueOnItemLoad(function() one(r, true) end)
        else
            one(r, false)
        end
    end

    C_Timer.After(30, finish) -- Notbremse, falls einzelne Items nie laden
end

local function Process()
    local c = cfg()
    local n = C_AuctionHouse.GetNumReplicateItems()
    local items = {}

    for i = 0, n - 1 do
        local name, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID =
            C_AuctionHouse.GetReplicateItemInfo(i)
        if itemID and buyout and buyout > 0 then
            local e = items[itemID]
            if not e then e = { n = 0 }; items[itemID] = e end
            if name and name ~= "" then e.name = name end
            e.n = e.n + 1
            local per = buyout / math.max(count or 1, 1)
            if not e.min or per < e.min then e.min = per end
        end
    end

    -- Angebot fuer alle eigenen Rezepte festhalten (Tab "Herstellen")
    c.lastCounts = {}
    for id in pairs(c.recipes) do
        c.lastCounts[id] = items[id] and items[id].n or 0
    end
    c.scanTime = date("%d.%m. %H:%M")
    c.scanRealm = GetRealmName()

    for id in pairs(items) do c.seen[id] = true end

    local ids = {}
    for id in pairs(items) do ids[#ids + 1] = id end

    local cands, idx = {}, 1
    local snap = {}   -- Realm-Schnappschuss (nur Items mit Nachfrage, ohne bekannte Commodities)

    local function check(id, e)
        local spd = tsm("DBRegionSoldPerDay", id)
        if not spd or spd < RAW_MIN_SOLD then return end
        if e and c.stack[id] ~= true then
            snap[id] = { e.n, math.floor(e.min) }
            if e.name then c.names[id] = e.name end
        end
        local cnt, min = e and e.n or 0, e and e.min
        local sale = min and tsm("DBRegionSaleAvg", id)
        local isGap = cnt <= RAW_MAX_LISTINGS
        local isDeal = sale and min and min > 0 and sale >= min * DEAL_MIN_GAP
        if not isGap and not isDeal then return end
        local avg = tsm("DBRegionMarketAvg", id) or min
        if not avg then return end
        cands[#cands + 1] = {
            id = id, n = cnt, min = min, spd = spd, avg = avg, sale = sale,
            score = spd * avg, gap = isGap or nil, deal = isDeal or nil,
            dealPct = isDeal and math.floor((sale / min - 1) * 100 + 0.5) or nil,
            profit = isDeal and (sale * AH_CUT - min) or nil,
        }
    end

    -- in Portionen auswerten, damit das Spiel nicht einfriert
    local function step()
        local last = math.min(idx + BATCH - 1, #ids)
        for i = idx, last do check(ids[i], items[ids[i]]) end
        idx = last + 1
        if idx <= #ids then
            SetStatus(string.format("Werte aus ... %d / %d", idx - 1, #ids))
            C_Timer.After(0, step)
            return
        end
        -- Items, die frueher da waren, jetzt aber komplett fehlen
        for id in pairs(c.seen) do
            if not items[id] then check(id, nil) end
        end
        c.realms[c.scanRealm] = { time = c.scanTime, ts = time(), items = snap }
        out(string.format("%d Auktionen gescannt, %d Kandidaten.", n, #cands))
        Finalize(cands)
    end
    step()
end

StartScan = function()
    if not win then OpenWindow() end
    if not TSM_API then return SetStatus("TSM ist nicht geladen.") end
    if not ahOpen then return SetStatus("Erst das Auktionshaus öffnen.") end
    waiting = true
    win.scanBtn:Disable()
    SetStatus("Scan läuft ... (Vollscan geht nur alle 15 Minuten)")
    C_AuctionHouse.ReplicateItems()
    -- Falls der Server den Scan wegen der Sperre ignoriert
    C_Timer.After(60, function()
        if waiting then
            waiting = false
            win.scanBtn:Enable()
            SetStatus("Keine Antwort - vermutlich noch in der 15-Minuten-Sperre.")
        end
    end)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local refreshPending = false
local function RefreshCraftSoon()
    if refreshPending or not (win and win:IsShown() and cfg().mode == "craft") then return end
    refreshPending = true
    C_Timer.After(2, function()
        refreshPending = false
        if win and win:IsShown() and cfg().mode == "craft" then ApplyFilter() end
    end)
end

f:RegisterEvent("AUCTION_HOUSE_SHOW")
f:RegisterEvent("AUCTION_HOUSE_CLOSED")
f:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
f:RegisterEvent("TRADE_SKILL_SHOW")
f:RegisterEvent("BAG_UPDATE_DELAYED")
f:SetScript("OnEvent", function(_, event)
    if event == "AUCTION_HOUSE_SHOW" then
        ahOpen = true
    elseif event == "AUCTION_HOUSE_CLOSED" then
        ahOpen = false
        if waiting then
            waiting = false
            if win then win.scanBtn:Enable(); SetStatus("Scan abgebrochen (AH geschlossen).") end
        end
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" and waiting then
        waiting = false
        SetStatus("Werte Scan aus ...")
        C_Timer.After(2, Process)
    elseif event == "TRADE_SKILL_SHOW" then
        C_Timer.After(1.5, CaptureRecipes)
    elseif event == "BAG_UPDATE_DELAYED" then
        RefreshCraftSoon()
    end
end)

SLASH_ENYCONOMY1 = "/eny"
SLASH_ENYCONOMY2 = "/enyconomy"
SLASH_ENYCONOMY3 = "/ahgaps"
SlashCmdList.ENYCONOMY = function(msg)
    local cmd, arg = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "reset" then
        local c = cfg()
        c.seen, c.raw, c.lastCounts, c.realms = {}, nil, nil, {}
        out("Gedächtnis, Realm-Scans und letzter Scan geleert (Rezepte bleiben).")
        if win and win:IsShown() then ApplyFilter() end
    elseif cmd == "resetrecipes" then
        cfg().recipes = {}
        out("Rezeptliste geleert.")
        if win and win:IsShown() then ApplyFilter() end
    elseif cmd == "test" and tonumber(arg) then
        local id = tonumber(arg)
        local tHave, tAh = TsmTotals(id)
        out(string.format("Item %d: SoldPerDay=%s  SaleAvg=%s  RegionAvg=%s  Realm=%s  Crafting=%s  Verkaufswert=%s",
            id, tostring(tsm("DBRegionSoldPerDay", id)), gold(tsm("DBRegionSaleAvg", id)),
            gold(tsm("DBRegionMarketAvg", id)), gold(tsm("DBMarket", id)), gold(tsm("Crafting", id)),
            gold(tsm(SALE_FORMULA, id))))
        out(string.format("  Bestand TSM=%s  davon AH=%s  Kriegsmeuten-Bank=%d  Gruppe=%s",
            tostring(tHave), tostring(tAh), Warbank(id), tostring(GroupOf(id))))
    elseif cmd == "luecken" or cmd == "gaps" then
        OpenWindow("gaps")
    elseif cmd == "deals" then
        OpenWindow("deals")
    elseif cmd == "craft" or cmd == "herstellen" then
        OpenWindow("craft")
    elseif cmd == "realms" then
        OpenWindow("realms")
    elseif cmd == "shop" or cmd == "einkauf" then
        OpenWindow("shop")
    else
        if win and win:IsShown() then win:Hide() else OpenWindow() end
    end
end
