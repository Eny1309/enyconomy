"""Enyconomy Web - API und Oberfläche."""
import logging
import os
import time

from fastapi import FastAPI, Query
from fastapi.responses import FileResponse, Response

from . import collector as C

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("main")

AH_CUT = 0.95
LANG = {"deDE": "DE", "enGB": "EN", "enUS": "EN", "frFR": "FR", "esES": "ES", "itIT": "IT", "ptPT": "PT",
        "ptBR": "PT", "ruRU": "RU"}
app = FastAPI(title="Enyconomy")
col = None


@app.on_event("startup")
def startup():
    global col
    C.init_db()
    if os.environ.get("NO_COLLECTOR"):
        return
    col = C.Collector()
    col.start()


# --------------------------------------------------------------------------
# Daten laden (gecacht bis zum nächsten Scan)
# --------------------------------------------------------------------------
_cache = {"stamp": None}


def load():
    with C.db() as con:
        stamp = (C.meta_get(con, "last_run"), C.meta_get(con, "tsm_updated"), C.meta_get(con, "decor_updated"),
                 C.meta_get(con, "scout_updated"),
                 con.execute("SELECT COUNT(*) FROM item").fetchone()[0])
        if _cache["stamp"] == stamp:
            return _cache
        crs = C.tracked_cr_ids()
        names, locales, rtypes, pops = {}, {}, {}, {}
        for r in con.execute("SELECT * FROM realm"):
            names.setdefault(r["cr_id"], []).append(r["name"])
            if "locale" in r.keys():
                locales.setdefault(r["cr_id"], []).append(r["locale"])
                rtypes.setdefault(r["cr_id"], []).append(r["rtype"])
            if "pop" in r.keys() and r["pop"]:
                pops[r["cr_id"]] = r["pop"]
        listings = {}
        q = "SELECT cr_id, item_key, min_buyout, qty, n FROM listing WHERE cr_id IN (%s)" % ",".join("?" * len(crs))
        for r in con.execute(q, crs) if crs else []:
            listings.setdefault(r["item_key"], {})[r["cr_id"]] = (r["min_buyout"], r["qty"], r["n"])
        tsm = {r["item_key"]: dict(r) for r in con.execute("SELECT * FROM tsm")}
        items = {r["item_key"]: dict(r) for r in con.execute("SELECT * FROM item")}
        snaps = {r["cr_id"]: dict(r) for r in con.execute("SELECT * FROM snapshot")}
        decor = {r["item_key"]: dict(r) for r in con.execute("SELECT * FROM decor")}
        eu = {r["item_key"]: (r["realms"], r["median"], r["low"], r["high"] or r["median"])
              for r in con.execute("SELECT * FROM eu_item")}
    _cache.update(eu=eu, stamp=stamp, crs=crs, names=names, locales=locales, rtypes=rtypes, pops=pops, listings=listings, tsm=tsm, items=items, snaps=snaps,
                  decor=decor)
    return _cache


def realm_full(d, cr):
    n = sorted(d["names"].get(cr, [str(cr)]))
    return ", ".join(n)


def realm_label(d, cr):
    """Kurzname: dein Realm aus REALMS statt der ganzen Realm-Gruppe."""
    return realm_short(d, cr)


def tradable(meta):
    """Nur prüfen, ob Item-Infos da sind.
    Die Bindung aus den Blizzard-Daten gilt für die Grundversion eines Items. Varianten (Bonus-IDs)
    können handelbar sein - und alles, was im AH angeboten wird oder laut TSM verkauft wurde, ist es."""
    return bool(meta and meta.get("ok"))


def item_info(d, key):
    meta = d["items"].get(key) or {}
    kind, num = key.split(":")
    return {
        "key": key, "id": int(num), "pet": kind == "p",
        "name": meta.get("name") or key, "quality": meta.get("quality"),
        "class": meta.get("class_name"), "subclass": meta.get("subclass_name"),
        "level": meta.get("level"), "icon": meta.get("icon"),
    }


def page(rows, sort, desc, offset, limit):
    vals = [r for r in rows if r.get(sort) is not None]
    nones = [r for r in rows if r.get(sort) is None]
    vals.sort(key=lambda r: r[sort].lower() if isinstance(r[sort], str) else r[sort], reverse=desc)
    rows = vals + nones
    return {"total": len(rows), "rows": rows[offset:offset + limit],
            "sum_buy": sum(r.get("buy") or 0 for r in rows),
            "sum_sell": sum(int((r.get("sell") or 0) * AH_CUT) for r in rows),
            "sum_profit": sum(r.get("profit") or 0 for r in rows)}


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------
@app.get("/api/status")
def status():
    d = load()
    realms = []
    for cr in d["crs"]:
        s = d["snaps"].get(cr, {})
        realms.append({"cr_id": cr, "name": realm_label(d, cr), "group": realm_full(d, cr),
                       "fetched_at": s.get("fetched_at"),
                       "auctions": s.get("n_auctions"),
                       "items": sum(1 for v in d["listings"].values() if cr in v)})
    with C.db() as con:
        tsm_updated = C.meta_get(con, "tsm_updated")
        last_run = C.meta_get(con, "last_run")
    with C.db() as con:
        scout_updated = C.meta_get(con, "scout_updated")
        eu_items = con.execute("SELECT COUNT(*) FROM eu_item").fetchone()[0]
        scouted = con.execute("SELECT COUNT(*) FROM scout").fetchone()[0]
        no_names = con.execute("""SELECT COUNT(*) FROM eu_item e LEFT JOIN item i ON i.item_key = e.item_key
                                  WHERE i.item_key IS NULL""").fetchone()[0]
    scouting = col.scouting if col else False
    return {"scout_updated": scout_updated, "scout_running": scouting, "eu_items": eu_items, "scouted": scouted,
            "eu_no_names": no_names,
            "realms": realms, "tsm_updated": tsm_updated, "last_run": last_run, "decor_items": len(d["decor"]),
            "running": bool(col and col.running), "last_error": col.last_error if col else None,
            "tsm_items": len(d["tsm"]), "items_meta": len(d["items"]),
            "scan_minutes": C.SCAN_MINUTES, "now": int(time.time())}


@app.post("/api/scan")
def scan():
    if col:
        col.wake.set()
    return {"ok": True}


def realm_short(d, cr):
    """Dein Realm aus REALMS statt der ganzen Realm-Gruppe (z. B. 'Theradras' statt 'Dethecus, ...')."""
    want = C.tracked_realms()
    names = d["names"].get(cr, [])
    if want != "all":
        for w in want:
            for n in names:
                if C.norm(w) == C.norm(n) or C.norm(w) in C.norm(n):
                    return n
    return sorted(names)[0] if names else str(cr)


@app.get("/api/realms")
def realms():
    d = load()
    return [{"cr_id": cr, "name": realm_full(d, cr), "short": realm_short(d, cr)} for cr in d["crs"]]


@app.get("/api/flips")
def flips(min_profit: float = 100, min_return: float = 30, min_rate: float = 0.02, min_spd: float = 0,
          max_buy: float = 0, buy: int = 0, sell: int = 0, q: str = "", category: str = "",
          estimated: bool = True, all_sells: bool = False, only_cheapest: bool = False,
          sort: str = "profit", desc: bool = True, offset: int = 0, limit: int = Query(50, le=500)):
    """Auf Realm A kaufen, über die Kriegsmeuten-Bank auf Realm B verkaufen.
    Verkaufspreis = niedrigerer Wert aus Region-Verkaufs-Ø und aktuellem Mindestpreis dort.
    Gibt es das Item dort nicht, gilt der Region-Verkaufs-Ø (geschätzt)."""
    d = load()
    ql, cat = q.strip().lower(), category.strip().lower()
    rows = []
    for key, per in d["listings"].items():
        t = d["tsm"].get(key)
        if not t or not t.get("sale_avg"):
            continue
        if (t.get("sale_rate") or 0) < min_rate or (t.get("sold_per_day") or 0) < min_spd:
            continue
        meta = d["items"].get(key)
        if not tradable(meta):
            continue
        name = (meta.get("name") or "").lower()
        if ql and ql not in name:
            continue
        if cat and cat not in (meta.get("class_name") or "").lower() and cat not in (meta.get("subclass_name") or "").lower():
            continue
        usual = t["sale_avg"]
        options = []
        for scr in d["crs"]:
            if sell and scr != sell:
                continue
            listed = per.get(scr)
            if listed:
                options.append((scr, min(usual, listed[0]), listed[0], False))
            elif estimated:
                options.append((scr, usual, None, True))
        for bcr, (bprice, bqty, bn) in per.items():
            if buy and bcr != buy:
                continue
            if max_buy and bprice > max_buy * 10000:
                continue
            cands = []
            for scr, sprice, lowest, est in options:
                if scr == bcr:
                    continue
                profit = sprice * AH_CUT - bprice
                ret = profit / bprice * 100 if bprice > 0 else None
                if profit >= min_profit * 10000 and ret is not None and ret >= min_return:
                    cands.append((profit, not est, scr, sprice, lowest, est, ret))
            if not cands:
                continue
            cands.sort(reverse=True)  # bei gleichem Gewinn echte Angebote vor Schätzungen
            for profit, _, scr, sprice, lowest, est, ret in (cands if all_sells else cands[:1]):
                r = item_info(d, key)
                r.update(buy_realm=realm_label(d, bcr), buy_cr=bcr, buy=bprice, qty=bqty,
                         sell_realm=realm_label(d, scr), sell_cr=scr, sell=sprice, usual=usual,
                         lowest_there=lowest, estimated=est, profit=int(profit), ret=round(ret, 1),
                         sale_rate=t.get("sale_rate"), sold_per_day=t.get("sold_per_day"))
                rows.append(r)
    if only_cheapest:  # nur wo der Kaufrealm gerade EU-weit am günstigsten ist
        add_eu_cheapest(d, rows, "buy")
        rows = [r for r in rows if r.get("eu_cheapest")]
    res = page(rows, sort, desc, offset, limit)
    if not only_cheapest:
        add_eu_cheapest(d, res["rows"], "buy")
    return res


def add_eu_cheapest(d, rows, price_field):
    """Zu jeder Zeile: günstigstes Angebot EU-weit und der Platz des eigenen Kaufpreises darin."""
    keys = list({r["key"] for r in rows})
    if not keys:
        return
    per = {}
    with C.db() as con:
        for i in range(0, len(keys), 900):
            part = keys[i:i + 900]
            q = ",".join("?" * len(part))
            for x in con.execute(f"SELECT item_key, cr_id, min_buyout FROM eu_listing WHERE item_key IN ({q})", part):
                per.setdefault(x["item_key"], {})[x["cr_id"]] = x["min_buyout"]
            for x in con.execute(f"SELECT item_key, cr_id, min_buyout FROM listing WHERE item_key IN ({q})", part):
                per.setdefault(x["item_key"], {})[x["cr_id"]] = x["min_buyout"]  # eigene Realms: stündlich
    own = set(d["crs"])
    for r in rows:
        offers = per.get(r["key"], {})
        if not offers:
            continue
        cr, low = min(offers.items(), key=lambda x: x[1])
        price = r[price_field]
        r.update(eu_min=low, eu_n=len(offers),
                 eu_min_realm=realm_short(d, cr) if cr in own else realm_full(d, cr).split(",")[0],
                 eu_rank=1 + sum(1 for p in offers.values() if p < price),
                 eu_cheapest=price <= low)


@app.get("/api/deals")
def deals(min_pct: float = 25, min_profit: float = 50, min_rate: float = 0.02, min_spd: float = 0,
          realm: int = 0, q: str = "", category: str = "",
          sort: str = "profit", desc: bool = True, offset: int = 0, limit: int = Query(50, le=500)):
    """Angebote deutlich unter dem Region-Verkaufs-Ø (zum Wiederverkauf auf demselben Realm)."""
    d = load()
    ql, cat = q.strip().lower(), category.strip().lower()
    rows = []
    for key, per in d["listings"].items():
        t = d["tsm"].get(key)
        if not t or not t.get("sale_avg"):
            continue
        if (t.get("sale_rate") or 0) < min_rate or (t.get("sold_per_day") or 0) < min_spd:
            continue
        meta = d["items"].get(key)
        if not tradable(meta):
            continue
        name = (meta.get("name") or "").lower()
        if ql and ql not in name:
            continue
        if cat and cat not in (meta.get("class_name") or "").lower() and cat not in (meta.get("subclass_name") or "").lower():
            continue
        usual = t["sale_avg"]
        for cr, (price, qty, n) in per.items():
            if realm and cr != realm:
                continue
            if price <= 0 or usual < price * (1 + min_pct / 100):
                continue
            profit = usual * AH_CUT - price
            if profit < min_profit * 10000:
                continue
            r = item_info(d, key)
            r.update(realm=realm_label(d, cr), cr=cr, buy=price, qty=qty, n=n, usual=usual, sell=usual,
                     market=t.get("market"), pct=round((usual / price - 1) * 100, 1), profit=int(profit),
                     sale_rate=t.get("sale_rate"), sold_per_day=t.get("sold_per_day"))
            rows.append(r)
    return page(rows, sort, desc, offset, limit)


@app.get("/api/decor-missing")
def decor_missing(min_sale: float = 300, min_rate: float = 0, min_spd: float = 0, realm: int = 0,
                  all_missing: bool = False, q: str = "",
                  sort: str = "score", desc: bool = True, offset: int = 0, limit: int = Query(50, le=500)):
    """Deko, die auf deinen Realms fehlt - mit Region-Nachfrage aus TSM."""
    d = load()
    ql = q.strip().lower()
    crs = d["crs"]
    rows = []
    for key, dec in d["decor"].items():
        if dec.get("stackable"):
            continue  # Commodities gibt es regionsweit, nicht pro Realm
        t = d["tsm"].get(key)
        if not t or not t.get("sale_avg") or t["sale_avg"] < min_sale * 10000:
            continue
        if (t.get("sale_rate") or 0) < min_rate or (t.get("sold_per_day") or 0) < min_spd:
            continue
        meta = d["items"].get(key) or {}
        name = meta.get("name") or dec.get("name") or key
        if ql and ql not in name.lower():
            continue
        per = d["listings"].get(key, {})
        missing = [cr for cr in crs if cr not in per]
        if realm:
            if realm not in missing:
                continue
        elif all_missing:
            if len(missing) != len(crs):
                continue
        elif not missing:
            continue
        cheapest = min(((v[0], cr) for cr, v in per.items() if cr in crs), default=None)
        usual = t["sale_avg"]
        r = item_info(d, key)
        r.update(name=name, quality=meta.get("quality") or dec.get("quality"),
                 subclass=meta.get("subclass_name") or dec.get("subclass_name"),
                 missing=", ".join(realm_label(d, cr) for cr in missing), missing_n=len(missing),
                 present_n=len(crs) - len(missing),
                 cheapest=cheapest[0] if cheapest else None,
                 cheapest_realm=realm_label(d, cheapest[1]) if cheapest else None,
                 usual=usual, market=t.get("market"),
                 sale_rate=t.get("sale_rate"), sold_per_day=t.get("sold_per_day"),
                 score=int((t.get("sold_per_day") or 0) * usual),
                 flip=int(usual * AH_CUT - cheapest[0]) if cheapest else None)
        rows.append(r)
    return page(rows, sort, desc, offset, limit)


@app.get("/api/niches")
def niches(min_sale: float = 50, min_spd: float = 0.01, by_subclass: bool = True,
           sort: str = "score", desc: bool = True, offset: int = 0, limit: int = Query(100, le=500)):
    """Kategorien nach Nachfrage (TSM) und Konkurrenz (Angebote auf deinen Realms)."""
    d = load()
    crs = d["crs"] or [0]
    groups = {}
    for key, t in d["tsm"].items():
        meta = d["items"].get(key)
        if not tradable(meta):
            continue
        sale, spd = t.get("sale_avg") or 0, t.get("sold_per_day") or 0
        if sale < min_sale * 10000 or spd < min_spd:
            continue
        cls = meta.get("class_name") or "?"
        sub = meta.get("subclass_name") or "-"
        gk = (cls, sub if by_subclass else "")
        g = groups.get(gk)
        if not g:
            g = groups[gk] = {"items": 0, "listed": 0, "auctions": 0, "spd": 0.0, "gold": 0.0,
                              "missing": 0, "sale_sum": 0.0, "examples": []}
        per = d["listings"].get(key, {})
        auctions = sum(per[cr][2] for cr in crs if cr in per)
        g["items"] += 1
        g["listed"] += 1 if auctions else 0
        g["missing"] += sum(1 for cr in crs if cr not in per)
        g["auctions"] += auctions
        g["spd"] += spd
        g["gold"] += spd * sale
        g["sale_sum"] += sale
        g["examples"].append((spd * sale, meta.get("name") or key))
    rows = []
    n_realms = len(crs)
    for (cls, sub), g in groups.items():
        if g["items"] < 3:
            continue
        avg_auctions = g["auctions"] / (g["items"] * n_realms)        # Angebote pro Item und Realm
        supply = g["auctions"] / n_realms / g["spd"] if g["spd"] else None  # Angebot je regionalem Tagesverkauf
        missing_pct = g["missing"] / (g["items"] * n_realms) * 100
        gold_day = g["gold"]
        score = gold_day / (1 + (supply or 0)) / 10000
        g["examples"].sort(reverse=True)
        rows.append({
            "key": f"{cls}|{sub}", "category": cls, "subclass": sub or "-",
            "items": g["items"], "avg_sale": int(g["sale_sum"] / g["items"]),
            "spd": round(g["spd"], 2), "gold_day": int(gold_day),
            "avg_auctions": round(avg_auctions, 2), "supply": round(supply, 2) if supply is not None else None,
            "missing_pct": round(missing_pct, 1), "score": round(score, 1),
            "examples": ", ".join(n for _, n in g["examples"][:4]),
        })
    return page(rows, sort, desc, offset, limit)


@app.get("/api/search")
def search(q: str = "", category: str = "", only_listed: bool = False,
           sort: str = "name", desc: bool = False, offset: int = 0, limit: int = Query(50, le=500)):
    """Kleines AH: Items nach Namen suchen, Preise auf allen eigenen Realms."""
    d = load()
    ql, cat = q.strip().lower(), category.strip().lower()
    if len(ql) < 2 and not cat:
        return page([], sort, desc, offset, limit)
    names = {}
    for key, dec in d["decor"].items():
        names[key] = (dec.get("name"), dec.get("quality"), "Behausung", dec.get("subclass_name"))
    for key, meta in d["items"].items():
        if meta.get("ok"):
            names[key] = (meta.get("name"), meta.get("quality"), meta.get("class_name"), meta.get("subclass_name"))
    rows = []
    for key, (name, quality, cls, sub) in names.items():
        if not name or (ql and ql not in name.lower()):
            continue
        if cat and cat not in (cls or "").lower() and cat not in (sub or "").lower():
            continue
        per = d["listings"].get(key, {})
        prices = [{"cr": cr, "min": per[cr][0] if cr in per else None, "n": per[cr][2] if cr in per else 0}
                  for cr in d["crs"]]
        listed = [p["min"] for p in prices if p["min"]]
        if only_listed and not listed:
            continue
        t = d["tsm"].get(key) or {}
        r = item_info(d, key)
        r.update(name=name, quality=quality, **{"class": cls, "subclass": sub}, prices=prices,
                 cheapest=min(listed) if listed else None, listed_n=len(listed),
                 usual=t.get("sale_avg"), market=t.get("market"),
                 sale_rate=t.get("sale_rate"), sold_per_day=t.get("sold_per_day"))
        rows.append(r)
    return page(rows, sort, desc, offset, limit)


@app.get("/api/top")
def top(min_sale: float = 10, min_spd: float = 0.1, category: str = "", q: str = "",
        sort: str = "sold_per_day", desc: bool = True, offset: int = 0, limit: int = Query(100, le=500)):
    """Topliste: nicht stapelbare Items mit den meisten Verkäufen pro Tag (TSM, Region),
    dazu die Preise auf allen eigenen Realms."""
    d = load()
    cat, ql = category.strip().lower(), q.strip().lower()
    cands = {}
    for key, dec in d["decor"].items():
        if not dec.get("stackable"):
            cands[key] = (dec.get("name"), dec.get("quality"), "Behausung", dec.get("subclass_name"), None)
    for key, meta in d["items"].items():
        if meta.get("ok"):
            cands[key] = (meta.get("name"), meta.get("quality"), meta.get("class_name"),
                          meta.get("subclass_name"), meta.get("binding"))
    rows = []
    for key, (name, quality, cls, sub, binding) in cands.items():
        t = d["tsm"].get(key)
        if not t:
            continue
        spd, sale = t.get("sold_per_day") or 0, t.get("sale_avg") or 0
        if spd < min_spd or sale < min_sale * 10000:
            continue
        if cat and cat not in (cls or "").lower() and cat not in (sub or "").lower():
            continue
        if ql and ql not in (name or "").lower():
            continue
        per = d["listings"].get(key, {})
        prices = [{"cr": cr, "min": per[cr][0] if cr in per else None, "n": per[cr][2] if cr in per else 0}
                  for cr in d["crs"]]
        listed = [p["min"] for p in prices if p["min"]]
        r = item_info(d, key)
        r.update(name=name or key, quality=quality, **{"class": cls, "subclass": sub}, prices=prices,
                 cheapest=min(listed) if listed else None, listed_n=len(listed),
                 spread=round((max(listed) / min(listed) - 1) * 100) if len(listed) > 1 else None,
                 usual=sale, sale_rate=t.get("sale_rate"), sold_per_day=spd, gold_day=int(spd * sale))
        rows.append(r)
    return page(rows, sort, desc, offset, limit)


@app.get("/api/sniper")
def sniper(list_name: str = "Enyconomy Sniper",
           min_rate: float = 0, min_sale: float = 0, min_spd: float = 0, category: str = "", quality: str = "",
           q: str = "", max_items: int = 0, with_prices: bool = False, max_pct: float = 100, ref_pct: float = 60,
           sort: str = "score", desc: bool = True, offset: int = 0, limit: int = Query(100, le=500)):
    """Sniper-Liste für Point Blank Sniper: ALLE Items, die einzeln im AH gehandelt werden.
    Keine Vorfilter - die Bewertung macht PBS.
    Quellen: alles mit TSM-Daten + alles, was der Scout EU-weit im Angebot gesehen hat.
    Raus nur: Waren (stapelbar, regionsweit) und Items ohne Namen.
    Ohne TSM-Verkaufs-Ø bekommt ein Eintrag einen Höchstpreis (höchster bekannter Wert),
    sonst könnte PBS ihn mit DBRegionSaleAvg nicht bewerten."""
    d = load()
    skipped = {"commodity": 0, "no_name": 0, "filter": 0}
    cat, ql, qual = category.strip().lower(), q.strip().lower(), quality.strip().upper()
    best = {}
    for key in set(d["tsm"]) | set(d["eu"]) | set(d["listings"]):
        t = d["tsm"].get(key) or {}
        meta = d["items"].get(key) or {}
        dec = d["decor"].get(key) or {}
        stack = meta.get("stackable")
        if stack is None and dec:
            stack = dec.get("stackable")
        if stack:
            skipped["commodity"] += 1
            continue
        name = meta.get("name") or dec.get("name")
        if not name:
            skipped["no_name"] += 1
            continue
        sale = t.get("sale_avg") or 0
        e = d["eu"].get(key)
        ref = None
        if not sale:
            ref = max(e[3] if e else 0, t.get("market") or 0, t.get("historical") or 0) or None
        # Optionale Filter - standardmäßig alle aus (0 / leer)
        cls, sub, q_ = meta.get("class_name") or ("Behausung" if dec else ""), meta.get("subclass_name") or dec.get("subclass_name") or "", meta.get("quality") or dec.get("quality")
        if ((min_rate and (t.get("sale_rate") or 0) < min_rate)
                or (min_sale and (sale or ref or 0) < min_sale * 10000)
                or (min_spd and (t.get("sold_per_day") or 0) < min_spd)
                or (cat and cat not in cls.lower() and cat not in sub.lower())
                or (qual and q_ != qual)
                or (ql and ql not in name.lower())):
            skipped["filter"] += 1
            continue
        prev = best.get(name)
        if prev and (prev["usual"] or 0) >= sale and not (prev["ref"] is None and prev["usual"] is None):
            continue  # gleicher Name: ein Eintrag reicht, PBS findet per exakter Suche alle Varianten
        r = item_info(d, key)
        r.update(name=name, quality=meta.get("quality") or dec.get("quality"),
                 usual=sale or None, ref=ref, sale_rate=t.get("sale_rate"), sold_per_day=t.get("sold_per_day"),
                 eu_realms=e[0] if e else 0, score=int((t.get("sold_per_day") or 0) * sale))
        best[name] = r
    rows = sorted(best.values(), key=lambda r: (-r["score"], r["name"]))
    if max_items > 0:
        rows = rows[:max_items]
    terms = []
    for r in rows:
        nm = r["name"].replace('"', '')
        if r["usual"] is None and r["ref"]:
            terms.append('"{}";;0;0;0;0;0;0;0;{};;#;;'.format(nm, max(1, int(r["ref"] * ref_pct / 100 / 10000))))
        elif with_prices and r["usual"]:
            terms.append('"{}";;0;0;0;0;0;0;0;{};;#;;'.format(nm, max(1, int(r["usual"] * max_pct / 100 / 10000))))
        else:
            terms.append('"{}"'.format(nm))
    res = page(rows, sort, desc, offset, limit)
    res["export"] = (list_name.replace("^", "") or "Enyconomy Sniper") + "^" + "^".join(terms) if terms else ""
    res["count"] = len(terms)
    res["with_ref"] = sum(1 for r in rows if r["usual"] is None and r["ref"])
    res["tsm_export"] = ",".join(r["key"] for r in rows)
    res["skipped"] = skipped
    return res


@app.get("/api/realmprices.lua")
def realmprices_lua():
    """Günstigster Preis je Item auf deinen Realms (aus REALMS) als RealmPrices.lua fürs Addon-Tooltip."""
    d = load()
    crs = d["crs"]
    def lua(v):
        return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'
    out = ["-- Erzeugt von Enyconomy Web. In Interface/AddOns/Enyconomy/ ersetzen, dann /reload.",
           "EnyconomyRealmData = {", "  created = %d," % int(time.time()), "  realms = {"]
    for cr in crs:
        snap = d["snaps"].get(cr, {})
        out.append("    { name = %s, members = { %s }, fetched = %d }," % (
            lua(realm_short(d, cr)), ", ".join(lua(n) for n in sorted(d["names"].get(cr, []))),
            snap.get("fetched_at") or 0))
    out.append("  },")
    out.append("  items = {")
    for key, per in d["listings"].items():
        kind, num = key.split(":")
        if kind != "i":
            continue
        vals = ",".join("%d:%d" % (per[cr][0] // 10000 if per[cr][0] >= 10000 else 0, per[cr][1]) if cr in per else "" for cr in crs)
        out.append("    [%s] = %s," % (num, lua(vals)))
    out += ["  },", "}", ""]
    return Response("\n".join(out), media_type="text/plain; charset=utf-8",
                    headers={"Content-Disposition": 'attachment; filename="RealmPrices.lua"'})


@app.get("/api/sniper.lua")
def sniper_lua(list_name: str = "Enyconomy Sniper",
               min_rate: float = 0, min_sale: float = 0, min_spd: float = 0, category: str = "", quality: str = "",
               q: str = "", max_items: int = 0, with_prices: bool = False, max_pct: float = 100, ref_pct: float = 60):
    """Dieselbe Liste als SniperList.lua für das Enyconomy-Addon (statt Einfügen, das bei großen Listen einfriert)."""
    res = sniper(list_name=list_name, min_rate=min_rate, min_sale=min_sale, min_spd=min_spd, category=category,
                 quality=quality, q=q, max_items=max_items, with_prices=with_prices, max_pct=max_pct,
                 ref_pct=ref_pct, sort="score", desc=True, offset=0, limit=1)
    def lua(v):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'
    parts = res["export"].split("^") if res["export"] else [list_name]
    out = ["-- Erzeugt von Enyconomy Web. In Interface/AddOns/Enyconomy/ ersetzen, dann /reload.",
           "EnyconomySniperData = {", "  name = %s," % lua(parts[0]), "  created = %d," % int(time.time()), "  terms = {"]
    out += ["    %s," % lua(t) for t in parts[1:]]
    out += ["  },", "}", ""]
    return Response("\n".join(out), media_type="text/plain; charset=utf-8",
                    headers={"Content-Disposition": 'attachment; filename="SniperList.lua"'})


@app.get("/api/timing")
def timing(days: int = 28, realm: int = 0):
    """Schnäppchen pro Wochentag und Stunde (Durchschnitt je Snapshot)."""
    d = load()
    since = int(time.time()) - days * 86400
    crs = [realm] if realm else d["crs"]
    q = "SELECT weekday, hour, deals, new_auctions, deal_value, ts FROM deal_stats WHERE ts >= ? AND cr_id IN (%s)" \
        % ",".join("?" * len(crs))
    cells = {}
    first = None
    with C.db() as con:
        for r in con.execute(q, [since] + crs) if crs else []:
            c = cells.setdefault((r["weekday"], r["hour"]), {"deals": 0, "new": 0, "value": 0, "n": 0, "days": set()})
            c["deals"] += r["deals"]; c["new"] += r["new_auctions"]; c["value"] += r["deal_value"]; c["n"] += 1
            c["days"].add(r["ts"] // 86400)
            first = r["ts"] if first is None or r["ts"] < first else first
    grid = []
    for wd in range(7):
        row = []
        for h in range(24):
            c = cells.get((wd, h))
            # Durchschnitt pro beobachtetem Tag (Summe über die gewählten Realms)
            per = len(c["days"]) if c else 0
            row.append(None if not c else {"deals": round(c["deals"] / per, 1), "new": round(c["new"] / per),
                                           "value": int(c["value"] / per), "samples": c["n"]})
        grid.append(row)
    best = sorted(((wd, h, v["deals"]) for wd, row in enumerate(grid) for h, v in enumerate(row) if v),
                  key=lambda x: -x[2])[:5]
    return {"grid": grid, "best": best, "since": first, "deal_pct": C.DEAL_PCT,
            "snapshots": sum(c["n"] for c in cells.values())}


@app.post("/api/scout")
def scout_now():
    if col:
        col.scout_wake.set()
    return {"ok": True}


@app.get("/api/scout")
def scout(hide_ru: bool = True, lang: str = "", sort: str = "flip_profit", desc: bool = True, offset: int = 0,
          limit: int = Query(100, le=500)):
    """Rangliste aller fremden Realm-Gruppen: wo lohnt sich ein Einkaufs-Char?"""
    import json, re as _re
    d = load()
    with C.db() as con:
        rows_db = [dict(r) for r in con.execute("SELECT * FROM scout")]
        updated = C.meta_get(con, "scout_updated")
    rows = []
    for r in rows_db:
        names = sorted(d["names"].get(r["cr_id"], [str(r["cr_id"])]))
        langs = sorted({LANG.get(l, l or "?") for l in d["locales"].get(r["cr_id"], [])})
        types = sorted({t for t in d["rtypes"].get(r["cr_id"], []) if t})
        mine = r["cr_id"] in set(d["crs"])
        ru = "RU" in langs or any(_re.search("[а-яА-Я]", n) for n in names)
        if hide_ru and ru and not mine:
            continue
        if lang and lang not in langs and not mine:
            continue
        top = []
        for profit, key, unit in json.loads(r["top"] or "[]")[:5]:
            meta = d["items"].get(key) or d["decor"].get(key) or {}
            top.append(f'{meta.get("name") or key} (+{profit // 10000:,}g)'.replace(",", "."))
        rows.append({"key": str(r["cr_id"]), "realm": ", ".join(names), "realms_n": len(names), "ts": r["ts"],
                     "mine": mine, "short": realm_short(d, r["cr_id"]) if mine else None,
                     "lang": "/".join(langs) or "?", "rtype": ", ".join(types),
                     "auctions": r["auctions"], "items": r["items"], "deals": r["deals"],
                     "deal_value": r["deal_value"], "flips": r["flips"], "flip_profit": r["flip_profit"],
                     "top": ", ".join(top)})
    res = page(rows, sort, desc, offset, limit)
    res["updated"] = updated
    res["running"] = bool(col and col.scouting)
    return res


@app.get("/api/favorite-keys")
def favorite_keys():
    with C.db() as con:
        return [r[0] for r in con.execute("SELECT item_key FROM favorite")]


@app.post("/api/favorite/{key}")
def favorite_toggle(key: str):
    """Favorit an/aus."""
    with C.db() as con:
        if con.execute("SELECT 1 FROM favorite WHERE item_key=?", (key,)).fetchone():
            con.execute("DELETE FROM favorite WHERE item_key=?", (key,))
            return {"key": key, "fav": False}
        con.execute("INSERT INTO favorite (item_key, added) VALUES (?, ?)", (key, int(time.time())))
        return {"key": key, "fav": True}


@app.get("/api/favorites")
def favorites(sort: str = "pct", desc: bool = False, offset: int = 0, limit: int = Query(100, le=500)):
    """Favoriten: wo ist das Item gerade am günstigsten (alle EU-Realms) - und wie steht das zum Verkaufs-Ø."""
    d = load()
    own = set(d["crs"])
    with C.db() as con:
        keys = [r[0] for r in con.execute("SELECT item_key FROM favorite")]
        stamp = {r["cr_id"]: r["ts"] for r in con.execute("SELECT cr_id, ts FROM scout")}
        for r in con.execute("SELECT k, v FROM meta WHERE k LIKE 'live:%'"):
            c = int(r["k"].split(":")[1])
            stamp[c] = max(stamp.get(c, 0), int(r["v"]))
        for c, snap in d["snaps"].items():
            stamp[c] = snap.get("fetched_at") or stamp.get(c)
        per = {}
        if keys:
            q = ",".join("?" * len(keys))
            for r in con.execute(f"SELECT item_key, cr_id, min_buyout, qty FROM eu_listing WHERE item_key IN ({q})", keys):
                per.setdefault(r["item_key"], {})[r["cr_id"]] = (r["min_buyout"], r["qty"])
            for r in con.execute(f"SELECT item_key, cr_id, min_buyout, qty FROM listing WHERE item_key IN ({q})", keys):
                per.setdefault(r["item_key"], {})[r["cr_id"]] = (r["min_buyout"], r["qty"])
    rows = []
    for key in keys:
        r = item_info(d, key)
        dec = d["decor"].get(key) or {}
        if r["name"] == key and dec.get("name"):
            r.update(name=dec["name"], quality=dec.get("quality"))
        t = d["tsm"].get(key) or {}
        offers = sorted(per.get(key, {}).items(), key=lambda x: x[1][0])
        cheap = offers[0] if offers else None
        own_off = [o for o in offers if o[0] in own]
        usual = t.get("sale_avg")
        r.update(usual=usual, market=t.get("market"), sale_rate=t.get("sale_rate"), sold_per_day=t.get("sold_per_day"),
                 offers=len(offers),
                 best=cheap[1][0] if cheap else None, best_cr=cheap[0] if cheap else None,
                 best_realm=(realm_short(d, cheap[0]) if cheap[0] in own else realm_full(d, cheap[0])) if cheap else None,
                 best_own=cheap[0] in own if cheap else False, best_ts=stamp.get(cheap[0]) if cheap else None,
                 own_best=own_off[0][1][0] if own_off else None,
                 own_best_realm=realm_short(d, own_off[0][0]) if own_off else None,
                 next=", ".join(f"{gold_txt(o[1][0])} {realm_full(d, o[0]).split(',')[0]}" for o in offers[1:4]),
                 pct=round(cheap[1][0] / usual * 100) if cheap and usual else None)
        rows.append(r)
    return page(rows, sort, desc, offset, limit)


def gold_txt(c):
    return f"{c // 10000:,}g".replace(",", ".")


@app.get("/api/item/{key}")
def item(key: str, cr: int = 0):
    """Item-Detail: Preise auf allen EU-Realm-Gruppen, Angebote auf einem eigenen Realm, Preisverlauf."""
    d = load()
    r = item_info(d, key)
    dec = d["decor"].get(key) or {}
    if r["name"] == key and dec.get("name"):
        r.update(name=dec["name"], quality=dec.get("quality"), **{"class": "Behausung", "subclass": dec.get("subclass_name")})
    r["tsm"] = d["tsm"].get(key)
    own = set(d["crs"])
    live_ts, live_err = None, None
    if cr and cr not in own:  # fremder Realm: Auktionen live holen (stündlich gecacht)
        try:
            bz = col.bz if col else C.Blizzard(os.environ["BLIZZARD_CLIENT_ID"], os.environ["BLIZZARD_CLIENT_SECRET"])
            live_ts = C.live_realm(bz, cr)
        except Exception as e:
            live_err = str(e)
    with C.db() as con:
        per = {row["cr_id"]: (row["min_buyout"], row["qty"], row["n"]) for row in
               con.execute("SELECT cr_id, min_buyout, qty, n FROM eu_listing WHERE item_key=?", (key,))}
        for row in con.execute("SELECT cr_id, min_buyout, qty, n FROM listing WHERE item_key=?", (key,)):
            per[row["cr_id"]] = (row["min_buyout"], row["qty"], row["n"])  # eigene Realms: stündlich, also aktueller
        if not cr:
            have = [c for c in d["crs"] if c in per]
            cr = (min(have, key=lambda c: per[c][0]) if have else (d["crs"][0] if d["crs"] else 0))
        points = [{"unit": row["unit"], "qty": row["qty"], "n": row["n"]} for row in con.execute(
            "SELECT unit, qty, n FROM price_point WHERE item_key=? AND cr_id=? ORDER BY unit", (key, cr))]
        hist = [dict(row) for row in con.execute(
            "SELECT day, low, median, qty, realms, sale_avg FROM eu_history WHERE item_key=? ORDER BY day", (key,))]
        scout_updated = C.meta_get(con, "scout_updated")
    realms = []
    for c, (price, qty, n) in per.items():
        langs = sorted({LANG.get(l, l or "?") for l in d["locales"].get(c, [])})
        realms.append({"cr_id": c, "name": realm_full(d, c), "short": realm_short(d, c) if c in own else None,
                       "own": c in own, "lang": "/".join(langs), "pop": d["pops"].get(c),
                       "rtype": ", ".join(sorted({t for t in d["rtypes"].get(c, []) if t})),
                       "min": price, "qty": qty, "n": n})
    realms.sort(key=lambda x: x["min"])
    all_realms = sorted(({"cr_id": c, "name": realm_full(d, c)} for c in d["names"] if c not in own),
                        key=lambda x: x["name"].lower())
    with C.db() as con:
        r["fav"] = con.execute("SELECT 1 FROM favorite WHERE item_key=?", (key,)).fetchone() is not None
    r.update(realms=realms, cr=cr, listings=points, live_ts=live_ts, live_err=live_err, all_realms=all_realms, history=hist, scout_updated=scout_updated,
             eu_qty=sum(x["qty"] for x in realms), eu_realms=len(realms),
             own_realms=[{"cr_id": c, "name": realm_short(d, c)} for c in d["crs"]])
    return r


@app.get("/")
def index():
    return FileResponse(os.path.join(os.path.dirname(__file__), "static", "index.html"))
