-- Enyconomy: Herstellen über alle Realms + Einkaufs-/Sammelliste
--   Tab "Herstellen": Zielmenge pro Item, Bestand über alle Realms (inkl. eigener Auktionen) -> was fehlt
--   Tab "Einkauf":    Materialbedarf für alles, was fehlt - gegen den Bestand, einmal gezählt
-- Rezepte und Materialien liest das Addon selbst beim Öffnen der Berufsfenster.
-- Preise und Bestand des aktuellen Realms kommen von TSM (TSM_API).

local f = CreateFrame("Frame")
local AH_CUT = 0.95
local SALE_FORMULA = "min(first(DBRecent, DBMinBuyout), first(DBRegionSaleAvg, DBRecent, DBMinBuyout))"
local BUY_FORMULA = "first(DBMinBuyout, DBMarket, DBRegionMarketAvg)"
local BASIC = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic or 1

local defaults = {
    mode = "craft",
    craftGroup = "", craftOnlyTarget = true, craftOnlyMissing = false,
    shopMissing = true,
}

local function cfg()
    EnyconomyDB = EnyconomyDB or {}
    local c = EnyconomyDB
    for k, v in pairs(defaults) do
        if c[k] == nil then c[k] = v end
    end
    if c.mode ~= "craft" and c.mode ~= "shop" then c.mode = "craft" end
    c.recipes = c.recipes or {}   -- [itemID] = { prof, who, fr, link, numResult, mats = { { ids, qty } } }
    c.targets = c.targets or {}   -- [itemID] = Zielmenge
    c.stock = c.stock or {}       -- [Fraktion - Realm] = { time, items = { [itemID] = Anzahl inkl. Auktionen } }
    return c
end

local function out(msg) print("|cffffd100Enyconomy|r " .. msg) end

local function gold(c)
    if not c then return "-" end
    return string.format("%dg", math.floor(c / 10000 + 0.5))
end
local function goldSigned(c)
    if not c then return "-" end
    local g = math.floor(c / 10000 + 0.5)
    return string.format("%s%+dg|r", g >= 0 and "|cff40ff40" or "|cffff4040", g)
end
local function num1(v) return v and string.format("%.1f", v) or "-" end
local function int(v) return v and tostring(v) or "-" end
local function txt(v) return v or "-" end
local function red(v)
    if not v then return "-" end
    if v > 0 then return "|cffff4040" .. v .. "|r" end
    return "|cff40ff40" .. v .. "|r"
end
local function priceOrBound(v) return v and gold(v) or "|cffffa94dsammeln|r" end

local function tsm(source, itemID)
    if not TSM_API then return nil end
    local ok, v = pcall(TSM_API.GetCustomPriceValue, source, "i:" .. itemID)
    if ok then return v end
end

local function FactionRealm()
    return (UnitFactionGroup("player") or "?") .. " - " .. GetRealmName()
end

local function Age(ts)
    if not ts then return "?" end
    local d = time() - ts
    if d < 3600 then return string.format("%d min", math.floor(d / 60)) end
    if d < 86400 then return string.format("%d h", math.floor(d / 3600)) end
    return string.format("%d T", math.floor(d / 86400))
end

---------------------------------------------------------------------------
-- Bestand
---------------------------------------------------------------------------
-- Aktueller Realm (alle Chars dieser Fraktion), live von TSM: Besitz und Auktionen getrennt
local function TsmTotals(id)
    if not (TSM_API and TSM_API.GetPlayerTotals) then return 0, 0 end
    local ok, player, alts, auctions, altAuctions = pcall(TSM_API.GetPlayerTotals, "i:" .. id)
    if not ok then return 0, 0 end
    return (player or 0) + (alts or 0), (auctions or 0) + (altAuctions or 0)
end

-- Kriegsmeuten-Bank (gilt für alle Realms, wird nur einmal gezählt)
local function Warbank(id)
    local ok1, withWarbank = pcall(C_Item.GetItemCount, id, false, false, false, true)
    local ok2, bags = pcall(C_Item.GetItemCount, id, false, false, false, false)
    if ok1 and ok2 and withWarbank and bags then return math.max(0, withWarbank - bags) end
    return 0
end

-- Momentaufnahme des aktuellen Realms speichern (für die Anzeige auf anderen Realms)
local function SnapshotStock()
    local c = cfg()
    if not TSM_API then return end
    local items = {}
    for id in pairs(c.recipes) do
        local have, ah = TsmTotals(id)
        if have + ah > 0 then items[id] = have + ah end
    end
    c.stock[FactionRealm()] = { time = time(), items = items }
end

-- Bestand eines hergestellten Items: hier (live) + andere Realms (Momentaufnahme) + Kriegsmeuten-Bank
local function ItemStock(id)
    local c, here = cfg(), FactionRealm()
    local have, ah = TsmTotals(id)
    local others = 0
    for fr, snap in pairs(c.stock) do
        if fr ~= here then others = others + (snap.items[id] or 0) end
    end
    local wb = Warbank(id)
    return have + ah + wb, others, have + ah + wb + others
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
-- Rezepte inkl. Materialien mitlesen (beim Öffnen eines Berufsfensters)
---------------------------------------------------------------------------
local function CaptureRecipes()
    if not C_TradeSkillUI or not C_TradeSkillUI.GetAllRecipeIDs then return end
    if C_TradeSkillUI.IsTradeSkillLinked and C_TradeSkillUI.IsTradeSkillLinked() then return end
    if C_TradeSkillUI.IsTradeSkillGuild and C_TradeSkillUI.IsTradeSkillGuild() then return end

    local c = cfg()
    local info = C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
    local prof = info and info.professionName or "?"
    local who, fr = UnitName("player"), FactionRealm()
    local total, withMats = 0, 0

    for _, rid in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
        local ri = C_TradeSkillUI.GetRecipeInfo(rid)
        if ri and ri.learned and not ri.isRecraft then
            local s = C_TradeSkillUI.GetRecipeSchematic(rid, false)
            local id = s and s.outputItemID
            if id then
                total = total + 1
                local mats = {}
                for _, slot in ipairs(s.reagentSlotSchematics or {}) do
                    if slot.reagentType == BASIC and slot.required ~= false and (slot.quantityRequired or 0) > 0 then
                        local ids = {}
                        for _, r in ipairs(slot.reagents or {}) do
                            if r.itemID then ids[#ids + 1] = r.itemID end
                        end
                        if #ids > 0 then mats[#mats + 1] = { ids = ids, qty = slot.quantityRequired } end
                    end
                end
                if #mats > 0 then withMats = withMats + 1 end
                local e = c.recipes[id] or {}
                e.prof, e.who, e.fr, e.rid = prof, who, fr, rid
                e.numResult = math.max(1, s.quantityMin or 1)
                e.mats = mats
                local link = C_TradeSkillUI.GetRecipeItemLink and C_TradeSkillUI.GetRecipeItemLink(rid)
                if link then e.link = link end
                c.recipes[id] = e
            end
        end
    end
    out(string.format("%s (%s): %d Rezepte erfasst, %d mit Materialien.", prof, who, total, withMats))
end

---------------------------------------------------------------------------
-- Berechnungen
---------------------------------------------------------------------------
local function BuildCraftList()
    local c = cfg()
    local list = {}
    for id, e in pairs(c.recipes) do
        local target = c.targets[id]
        local here, others, total = ItemStock(id)
        local missing = target and math.max(0, target - total) or nil
        local sale = tsm(SALE_FORMULA, id)
        local cost = tsm("Crafting", id)
        local link = e.link or select(2, C_Item.GetItemInfo(id))
        list[#list + 1] = {
            id = id, link = link, prof = e.prof, who = e.who,
            name = link and link:match("%[(.-)%]") or tostring(id),
            group = GroupOf(id), target = target,
            here = here, others = others, total = total, missing = missing,
            crafts = missing and math.ceil(missing / (e.numResult or 1)) or nil,
            spd = tsm("DBRegionSoldPerDay", id),
            sale = sale, cost = cost,
            profit = (sale and cost) and (sale * AH_CUT - cost) or nil,
            noMats = not e.mats,
        }
    end
    return list
end

local function BuildShopping()
    local c = cfg()
    local entries, nItems, nCrafts, noMats = {}, 0, 0, 0
    for _, r in ipairs(BuildCraftList()) do
        local e = c.recipes[r.id]
        if r.crafts and r.crafts > 0 then
            if not e.mats then
                noMats = noMats + 1
            else
                nItems, nCrafts = nItems + 1, nCrafts + r.crafts
                for _, m in ipairs(e.mats) do
                    local gk = table.concat(m.ids, ",")
                    local en = entries[gk]
                    if not en then en = { ids = m.ids, need = 0, for_ = {} }; entries[gk] = en end
                    en.need = en.need + m.qty * r.crafts
                    en.for_[#en.for_ + 1] = r.name
                end
            end
        end
    end
    local list, buyCost, toBuy, toGather = {}, 0, 0, 0
    for _, en in pairs(entries) do
        local have = 0
        for _, id in ipairs(en.ids) do
            local h = TsmTotals(id)   -- nur Besitz, keine Auktionen
            have = have + h + Warbank(id)
        end
        local id = en.ids[1]
        local name, link = C_Item.GetItemInfo(id)
        if not name then
            Item:CreateFromItemID(id):ContinueOnItemLoad(function()
                if EnyconomyFrame and EnyconomyFrame:IsShown() and c.mode == "shop" then C_Timer.After(0.3, function() EnyApplyFilter() end) end
            end)
        end
        local missing = math.max(0, en.need - have)
        local price = tsm(BUY_FORMULA, id)
        if missing > 0 then
            if price then toBuy = toBuy + 1; buyCost = buyCost + missing * price else toGather = toGather + 1 end
        end
        list[#list + 1] = {
            id = id, ids = en.ids, name = name or ("Item " .. id), link = link,
            need = en.need, have = have, missing = missing, price = price,
            cost = price and missing * price or nil, source = price and "AH" or "Sammeln",
            usedFor = table.concat(en.for_, ", "),
        }
    end
    local info
    if nItems == 0 then
        info = noMats > 0 and string.format("%d Items fehlen, aber ohne Materialdaten - Berufsfenster einmal öffnen.", noMats)
            or "Nichts herzustellen. Im Tab Herstellen Zielmengen setzen (Rechtsklick)."
    else
        info = string.format("%d Items, %d Herstellungen | Kaufen: %d Materialien, ca. %s | Sammeln: %d%s",
            nItems, nCrafts, toBuy, gold(buyCost), toGather,
            noMats > 0 and string.format(" | %d ohne Materialdaten", noMats) or "")
    end
    return list, info
end

---------------------------------------------------------------------------
-- Tabs
---------------------------------------------------------------------------
local MODE_ORDER = { "craft", "shop" }
local win
local Refresh, ApplyFilter, SelectTab, MakeAuctionatorList, SetTargetForShown

local MODES = {
    craft = {
        label = "Herstellen", default = "missing",
        cols = {
            { key = "name",    title = "Item",    w = 175 },
            { key = "who",     title = "Wer",     w = 65, fmt = txt },
            { key = "target",  title = "Ziel",    w = 35, fmt = int },
            { key = "here",    title = "Hier",    w = 40, fmt = int },
            { key = "others",  title = "Andere",  w = 45, fmt = int },
            { key = "missing", title = "Fehlt",   w = 40, fmt = red },
            { key = "spd",     title = "/Tag",    w = 40, fmt = num1 },
            { key = "profit",  title = "Gewinn",  w = 70, fmt = goldSigned },
        },
        filters = {
            { key = "craftGroup",       label = "TSM-Gruppe enthält", type = "text", w = 110 },
            { key = "craftOnlyTarget",  label = "Nur mit Ziel",       type = "check" },
            { key = "craftOnlyMissing", label = "Nur fehlende",       type = "check" },
            { key = "_bulk", label = "Ziel für Liste", type = "button", w = 110,
              onClick = function() SetTargetForShown() end },
        },
        hint = "Rechtsklick = Zielmenge setzen. Hier = dieser Realm inkl. Auktionen + Kriegsmeuten-Bank. Andere = andere Realms (Stand letzter Login).",
    },
    shop = {
        label = "Einkauf", default = "cost",
        cols = {
            { key = "name",    title = "Material",  w = 200 },
            { key = "need",    title = "Bedarf",    w = 50, fmt = int },
            { key = "have",    title = "Vorhanden", w = 60, fmt = int },
            { key = "missing", title = "Fehlt",     w = 45, fmt = red },
            { key = "source",  title = "Quelle",    w = 55, fmt = txt },
            { key = "price",   title = "Preis",     w = 65, fmt = priceOrBound },
            { key = "cost",    title = "Kosten",    w = 75, fmt = gold },
        },
        filters = {
            { key = "shopMissing", label = "Nur fehlende", type = "check" },
            { key = "_auct", label = "Auktionator-Liste", type = "button", w = 140,
              onClick = function() MakeAuctionatorList() end },
        },
        hint = "Bedarf = Materialien für alles, was im Tab Herstellen fehlt. Vorhanden = alle Chars dieses Realms + Kriegsmeuten-Bank.",
    },
}

---------------------------------------------------------------------------
-- Fenster
---------------------------------------------------------------------------
local WIN_W, WIN_H = 680, 490
local LIST_W = WIN_W - 50
local ROW_H = 16
local MAX_COLS = 8
local rows = {}
local shown, sortKey, sortDesc = {}, "missing", true

local function SetStatus(text) if win then win.status:SetText(text or "") end end

local function ColumnLayout(mode)
    local layout, x = {}, 0
    for i, col in ipairs(MODES[mode].cols) do
        layout[i] = { x = x, w = col.w }
        x = x + col.w + 5
    end
    return layout
end

local function BuildFilterPanel(mode)
    local p = CreateFrame("Frame", nil, win)
    p:SetPoint("TOPLEFT", 14, -62)
    p:SetSize(640, 40)
    p.widgets = {}
    local x = 0
    for i, flt in ipairs(MODES[mode].filters) do
        local w
        if flt.type == "button" then
            w = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
            w:SetSize(flt.w, 22)
            w:SetPoint("TOPLEFT", x, -12)
            w:SetText(flt.label)
            w:SetScript("OnClick", flt.onClick)
            x = x + flt.w + 12
        else
            local label = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            label:SetPoint("TOPLEFT", x, 0)
            label:SetText(flt.label)
            if flt.type == "check" then
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
        if w.flt.type == "check" then w:SetChecked(v and true or false)
        elseif w.flt.type == "text" then w:SetText(tostring(v or "")) end
    end
end

local function ReadFilterValues(mode)
    local c = cfg()
    for _, w in ipairs(win.panels[mode].widgets) do
        if w.flt.type == "check" then c[w.flt.key] = w:GetChecked() and true or false
        elseif w.flt.type == "text" then c[w.flt.key] = strtrim(w:GetText() or "") end
    end
end

local function LayoutHeaders(mode)
    local m, layout = MODES[mode], ColumnLayout(mode)
    for i = 1, MAX_COLS do
        local h, col = win.headers[i], m.cols[i]
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

-- Zielmenge per Popup
StaticPopupDialogs["ENYCONOMY_TARGET"] = {
    text = "Zielmenge für %s (leer = kein Ziel):",
    button1 = OKAY, button2 = CANCEL,
    hasEditBox = true, editBoxWidth = 80,
    OnShow = function(self, data)
        local eb = self.editBox or self.EditBox
        local cur = data and data.single and cfg().targets[data.ids[1]]
        eb:SetText(cur and tostring(cur) or "")
        eb:HighlightText()
        eb:SetFocus()
    end,
    OnAccept = function(self, data)
        local eb = self.editBox or self.EditBox
        local v = tonumber(eb:GetText())
        local c = cfg()
        for _, id in ipairs(data.ids) do
            c.targets[id] = (v and v > 0) and math.floor(v) or nil
        end
        ApplyFilter()
    end,
    EditBoxOnEnterPressed = function(self)
        local p = self:GetParent()
        StaticPopupDialogs["ENYCONOMY_TARGET"].OnAccept(p, p.data)
        p:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

SetTargetForShown = function()
    if #shown == 0 then return SetStatus("Liste ist leer.") end
    local ids = {}
    for _, r in ipairs(shown) do ids[#ids + 1] = r.id end
    StaticPopup_Show("ENYCONOMY_TARGET", string.format("%d Items in der Liste", #ids), nil, { ids = ids })
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
    tinsert(UISpecialFrames, "EnyconomyFrame")

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Enyconomy")

    win.tabs = {}
    for i, mode in ipairs(MODE_ORDER) do
        local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        b:SetSize(110, 22)
        b:SetPoint("TOPLEFT", 12 + (i - 1) * 114, -28)
        b:SetText(MODES[mode].label)
        b:SetScript("OnClick", function() SelectTab(mode) end)
        b.mode = mode
        win.tabs[i] = b
    end

    local refresh = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    refresh:SetSize(100, 22)
    refresh:SetPoint("TOPRIGHT", -14, -28)
    refresh:SetText("Aktualisieren")
    refresh:SetScript("OnClick", function() SnapshotStock(); ApplyFilter() end)

    local line = win:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.4)
    line:SetPoint("TOPLEFT", 12, -54)
    line:SetPoint("TOPRIGHT", -12, -54)
    line:SetHeight(1)

    win.panels = {}
    for _, mode in ipairs(MODE_ORDER) do win.panels[mode] = BuildFilterPanel(mode) end

    local sl = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sl:SetPoint("TOPLEFT", 16, -108)
    sl:SetText("Suche:")
    win.search = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
    win.search:SetSize(220, 20)
    win.search:SetPoint("LEFT", sl, "RIGHT", 10, 0)
    win.search:SetAutoFocus(false)
    win.search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    win.search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    local pending = false
    win.search:SetScript("OnTextChanged", function(_, user)
        if not user or pending then return end
        pending = true
        C_Timer.After(0.4, function() pending = false; ApplyFilter() end)
    end)

    win.headers = {}
    for i = 1, MAX_COLS do
        local b = CreateFrame("Button", nil, win)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.text:SetAllPoints()
        b.text:SetJustifyH("LEFT")
        b:SetScript("OnClick", function(self)
            if sortKey == self.key then sortDesc = not sortDesc
            else sortKey, sortDesc = self.key, not (self.key == "name" or self.key == "who" or self.key == "source") end
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

    win:SetScript("OnShow", function() ApplyFilter() end)
end

local function GetRow(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, win.content)
    r:SetSize(LIST_W, ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r.cols = {}
    for j = 1, MAX_COLS do
        local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        r.cols[j] = fs
    end
    r:SetScript("OnEnter", function(self)
        local d = self.data
        if not d then return end
        local c = cfg()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if d.link then GameTooltip:SetHyperlink(d.link) else GameTooltip:SetText(d.name or ("Item " .. d.id)) end
        GameTooltip:AddLine(" ")
        if c.mode == "craft" then
            if d.prof then GameTooltip:AddLine("Herstellbar: " .. d.prof .. " (" .. (d.who or "?") .. ")", 0.2, 1, 0.6) end
            if d.group then GameTooltip:AddLine("TSM-Gruppe: " .. d.group, 0.6, 0.8, 1) end
            GameTooltip:AddDoubleLine("Dieser Realm + Kriegsmeuten-Bank", tostring(d.here), 1, 1, 1, 1, 1, 1)
            local here = FactionRealm()
            for fr, snap in pairs(c.stock) do
                if fr ~= here and (snap.items[d.id] or 0) > 0 then
                    GameTooltip:AddDoubleLine(fr .. " |cff888888(vor " .. Age(snap.time) .. ")|r",
                        tostring(snap.items[d.id]), 1, 1, 1, 1, 1, 1)
                end
            end
            if d.crafts and d.crafts > 0 then
                GameTooltip:AddLine(string.format("Herstellen: %dx", d.crafts), 1, 0.82, 0)
            end
            if d.noMats then GameTooltip:AddLine("Keine Materialdaten - Berufsfenster einmal öffnen.", 1, 0.6, 0.2) end
            if d.cost then GameTooltip:AddDoubleLine("Herstellkosten", gold(d.cost), 1, 1, 1, 1, 1, 1) end
            if d.sale then GameTooltip:AddDoubleLine("Verkaufswert", gold(d.sale), 1, 1, 1, 1, 1, 1) end
            GameTooltip:AddLine("Rechtsklick: Zielmenge setzen", 0.5, 0.5, 0.5)
        else
            if d.usedFor and d.usedFor ~= "" then GameTooltip:AddLine("Für: " .. d.usedFor, 0.6, 0.8, 1, true) end
        end
        GameTooltip:AddLine("Shift-Klick: Link in den Chat", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", GameTooltip_Hide)
    r:SetScript("OnClick", function(self, button)
        local d = self.data
        if not d then return end
        if button == "RightButton" and cfg().mode == "craft" then
            StaticPopup_Show("ENYCONOMY_TARGET", d.name, nil, { ids = { d.id }, single = true })
        elseif d.link and IsModifiedClick("CHATLINK") then
            ChatEdit_InsertLink(d.link)
        end
    end)
    rows[i] = r
    return r
end

Refresh = function()
    if not win then return end
    local mode = cfg().mode
    local m = MODES[mode]
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

ApplyFilter = function()
    local c = cfg()
    local mode = c.mode
    if win then ReadFilterValues(mode) end
    local q = win and strtrim(win.search:GetText() or ""):lower() or ""
    shown = {}

    if not TSM_API then
        Refresh()
        return SetStatus("TSM ist nicht geladen - ohne TSM keine Preise und kein Bestand.")
    end

    if mode == "craft" then
        local nRec = 0
        for _ in pairs(c.recipes) do nRec = nRec + 1 end
        local grp = (c.craftGroup or ""):lower()
        local nTarget, nMissing = 0, 0
        for _, r in ipairs(BuildCraftList()) do
            if r.target then nTarget = nTarget + 1 end
            if r.missing and r.missing > 0 then nMissing = nMissing + 1 end
            local ok = true
            if c.craftOnlyTarget and not r.target then ok = false end
            if ok and c.craftOnlyMissing and not (r.missing and r.missing > 0) then ok = false end
            if ok and grp ~= "" then ok = r.group and r.group:lower():find(grp, 1, true) ~= nil end
            if ok and q ~= "" then ok = r.name:lower():find(q, 1, true) ~= nil end
            if ok then shown[#shown + 1] = r end
        end
        Refresh()
        if nRec == 0 then
            SetStatus("Noch keine Rezepte. Auf jedem Twink einmal das Berufsfenster öffnen.")
        else
            SetStatus(string.format("%d angezeigt | %d Rezepte, %d mit Ziel, %d fehlen", #shown, nRec, nTarget, nMissing))
        end
        return
    end

    local list, info = BuildShopping()
    for _, r in ipairs(list) do
        if (not c.shopMissing or r.missing > 0) and (q == "" or r.name:lower():find(q, 1, true)) then
            shown[#shown + 1] = r
        end
    end
    Refresh()
    SetStatus(info)
end
EnyApplyFilter = function() ApplyFilter() end

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
    if not (Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.CreateShoppingList) then
        return SetStatus("Auktionator ist nicht geladen.")
    end
    local terms = {}
    for _, r in ipairs(list) do
        if r.missing > 0 and r.price and r.name and not r.name:match("^Item %d+$") then
            local ok, term = pcall(Auctionator.API.v1.ConvertToSearchString, "Enyconomy",
                { searchString = r.name, isExact = true, quantity = r.missing })
            if not ok or not term then
                term = string.format('"%s";;0;0;0;0;0;0;0;0;;#;;%d', r.name, r.missing)
            end
            terms[#terms + 1] = term
        end
    end
    if #terms == 0 then return SetStatus("Nichts im Auktionshaus zu kaufen.") end
    local ok, err = pcall(Auctionator.API.v1.CreateShoppingList, "Enyconomy", "Enyconomy Einkauf", terms)
    if ok then
        SetStatus(string.format("Auktionator-Liste 'Enyconomy Einkauf' mit %d Einträgen erstellt.", #terms))
    else
        SetStatus("Auktionator-Fehler: " .. tostring(err))
    end
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

local function OpenWindow(mode)
    if not win then CreateWindow() end
    win:Show()
    SelectTab(mode or cfg().mode)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local refreshPending = false
local function RefreshSoon()
    if refreshPending or not (win and win:IsShown()) then return end
    refreshPending = true
    C_Timer.After(2, function()
        refreshPending = false
        if win and win:IsShown() then ApplyFilter() end
    end)
end

f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("TRADE_SKILL_SHOW")
f:RegisterEvent("BAG_UPDATE_DELAYED")
f:RegisterEvent("AUCTION_HOUSE_CLOSED")
f:RegisterEvent("MAIL_CLOSED")
f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        cfg()
        C_Timer.After(10, SnapshotStock)
        C_Timer.After(5, function() ImportSniperList(false) end)
    elseif event == "PLAYER_LOGOUT" or event == "AUCTION_HOUSE_CLOSED" or event == "MAIL_CLOSED" then
        SnapshotStock()
    elseif event == "TRADE_SKILL_SHOW" then
        C_Timer.After(1.5, CaptureRecipes)
    elseif event == "BAG_UPDATE_DELAYED" then
        RefreshSoon()
    end
end)

SLASH_ENYCONOMY1 = "/eny"
SLASH_ENYCONOMY2 = "/enyconomy"
SlashCmdList.ENYCONOMY = function(msg)
    local cmd, arg = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "shop" or cmd == "einkauf" then
        OpenWindow("shop")
    elseif cmd == "craft" or cmd == "herstellen" then
        OpenWindow("craft")
    elseif cmd == "sniper" then
        ImportSniperList(true)
    elseif cmd == "resetrecipes" then
        cfg().recipes = {}
        out("Rezeptliste geleert - Berufsfenster neu öffnen.")
    elseif cmd == "test" and tonumber(arg) then
        local id = tonumber(arg)
        local have, ah = TsmTotals(id)
        local here, others, total = ItemStock(id)
        out(string.format("Item %d: TSM Besitz=%d Auktionen=%d | Kriegsmeuten-Bank=%d | andere Realms=%d | gesamt=%d | Ziel=%s",
            id, have, ah, Warbank(id), others, total, tostring(cfg().targets[id])))
    else
        if win and win:IsShown() then win:Hide() else OpenWindow() end
    end
end
