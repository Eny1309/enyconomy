"""Enyconomy Web - API und Oberfläche."""
import logging
import os
import time

from fastapi import FastAPI, Query
from fastapi.responses import FileResponse

from . import collector as C

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("main")

AH_CUT = 0.95
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
                 con.execute("SELECT COUNT(*) FROM item").fetchone()[0])
        if _cache["stamp"] == stamp:
            return _cache
        crs = C.tracked_cr_ids()
        names = {}
        for r in con.execute("SELECT cr_id, name FROM realm"):
            names.setdefault(r["cr_id"], []).append(r["name"])
        listings = {}
        q = "SELECT cr_id, item_key, min_buyout, qty, n FROM listing WHERE cr_id IN (%s)" % ",".join("?" * len(crs))
        for r in con.execute(q, crs) if crs else []:
            listings.setdefault(r["item_key"], {})[r["cr_id"]] = (r["min_buyout"], r["qty"], r["n"])
        tsm = {r["item_key"]: dict(r) for r in con.execute("SELECT * FROM tsm")}
        items = {r["item_key"]: dict(r) for r in con.execute("SELECT * FROM item")}
        snaps = {r["cr_id"]: dict(r) for r in con.execute("SELECT * FROM snapshot")}
        decor = {r["item_key"]: dict(r) for r in con.execute("SELECT * FROM decor")}
    _cache.update(stamp=stamp, crs=crs, names=names, listings=listings, tsm=tsm, items=items, snaps=snaps,
                  decor=decor)
    return _cache


def realm_label(d, cr):
    n = sorted(d["names"].get(cr, [str(cr)]))
    return ", ".join(n)


def tradable(meta):
    """Seelengebundenes und Questitems raus. Ohne Metadaten: vorerst ausblenden."""
    if not meta or not meta.get("ok"):
        return False
    if meta.get("binding") in ("ON_ACQUIRE", "QUEST"):
        return False
    if meta.get("class_id") == 12:  # Quest
        return False
    return True


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
        realms.append({"cr_id": cr, "name": realm_label(d, cr), "fetched_at": s.get("fetched_at"),
                       "auctions": s.get("n_auctions"),
                       "items": sum(1 for v in d["listings"].values() if cr in v)})
    with C.db() as con:
        tsm_updated = C.meta_get(con, "tsm_updated")
        last_run = C.meta_get(con, "last_run")
    return {"realms": realms, "tsm_updated": tsm_updated, "last_run": last_run, "decor_items": len(d["decor"]),
            "running": bool(col and col.running), "last_error": col.last_error if col else None,
            "tsm_items": len(d["tsm"]), "items_meta": len(d["items"]),
            "scan_minutes": C.SCAN_MINUTES, "now": int(time.time())}


@app.post("/api/scan")
def scan():
    if col:
        col.wake.set()
    return {"ok": True}


@app.get("/api/realms")
def realms():
    d = load()
    return [{"cr_id": cr, "name": realm_label(d, cr)} for cr in d["crs"]]


@app.get("/api/flips")
def flips(min_profit: float = 100, min_return: float = 30, min_rate: float = 0.02, min_spd: float = 0,
          max_buy: float = 0, buy: int = 0, sell: int = 0, q: str = "", category: str = "",
          estimated: bool = True, all_sells: bool = False,
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
    return page(rows, sort, desc, offset, limit)


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
        if meta.get("binding") == "ON_ACQUIRE":
            continue
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


@app.get("/api/item/{key}")
def item(key: str):
    """Ein Item auf allen eigenen Realms."""
    d = load()
    per = d["listings"].get(key, {})
    r = item_info(d, key)
    r["tsm"] = d["tsm"].get(key)
    r["realms"] = [{"name": realm_label(d, cr), "cr_id": cr,
                    "min": per[cr][0] if cr in per else None,
                    "qty": per[cr][1] if cr in per else 0} for cr in d["crs"]]
    return r


@app.get("/")
def index():
    return FileResponse(os.path.join(os.path.dirname(__file__), "static", "index.html"))
