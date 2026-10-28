"""Enyconomy Web - Datensammler.

Holt stündlich die Auktionen deiner Realm-Gruppen von der Blizzard-API,
regelmäßig die Regionsdaten von TSM und Item-Metadaten (deutsche Namen,
Qualität, Bindung) und schreibt alles in SQLite.
"""
import logging
import os
import re
import sqlite3
import threading
import time
from datetime import datetime
from zoneinfo import ZoneInfo
from concurrent.futures import ThreadPoolExecutor

import requests
from array import array

log = logging.getLogger("collector")

REGION = os.environ.get("REGION", "eu")
LOCALE = os.environ.get("LOCALE", "de_DE")
API = f"https://{REGION}.api.blizzard.com"
DB_PATH = os.environ.get("DB_PATH", "/data/enyconomy.db")
SCAN_MINUTES = int(os.environ.get("SCAN_MINUTES", "60"))
TSM_HOURS = float(os.environ.get("TSM_HOURS", "6"))
PET_CAGE = 82800
TIMEZONE = os.environ.get("TIMEZONE", "Europe/Berlin")
SCOUT_HOURS = float(os.environ.get("SCOUT_HOURS", "24"))   # 0 = nur per Knopf
HISTORY_DAYS = int(os.environ.get("HISTORY_DAYS", "180"))  # Preisverlauf aufbewahren
SCOUT_MIN_PROFIT = int(float(os.environ.get("SCOUT_MIN_PROFIT", "100")) * 10000)
SCOUT_MIN_RETURN = float(os.environ.get("SCOUT_MIN_RETURN", "30"))
DEAL_PCT = float(os.environ.get("DEAL_PCT", "65"))         # Schnäppchen = Preis <= x % des Region-Verkaufs-Ø
DEAL_MIN_RATE = float(os.environ.get("DEAL_MIN_RATE", "0.02"))
SNIPER_MIN_RATE = float(os.environ.get("SNIPER_MIN_RATE", "0.05"))

# Öffentliche Client-ID der TSM-API (aus der TSM-API-Doku), dazu dein persönlicher API-Key
TSM_CLIENT_ID = "c260f00d-1071-409a-992f-dda2e5498536"


# --------------------------------------------------------------------------
# Datenbank
# --------------------------------------------------------------------------
SCHEMA = """
CREATE TABLE IF NOT EXISTS realm (cr_id INTEGER, name TEXT, slug TEXT, PRIMARY KEY (cr_id, slug));
CREATE TABLE IF NOT EXISTS snapshot (cr_id INTEGER PRIMARY KEY, last_modified TEXT, fetched_at INTEGER, n_auctions INTEGER);
CREATE TABLE IF NOT EXISTS listing (cr_id INTEGER, item_key TEXT, min_buyout INTEGER, qty INTEGER, n INTEGER,
                                    PRIMARY KEY (cr_id, item_key));
CREATE INDEX IF NOT EXISTS listing_item ON listing (item_key);
CREATE TABLE IF NOT EXISTS item (item_key TEXT PRIMARY KEY, name TEXT, quality TEXT, class_id INTEGER,
                                 class_name TEXT, subclass_name TEXT, binding TEXT, level INTEGER,
                                 icon TEXT, fetched_at INTEGER, ok INTEGER);
CREATE TABLE IF NOT EXISTS tsm (item_key TEXT PRIMARY KEY, market INTEGER, historical INTEGER, sale_avg INTEGER,
                                sale_rate REAL, sold_per_day REAL, updated INTEGER);
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS auction_id (cr_id INTEGER, id INTEGER, PRIMARY KEY (cr_id, id)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS deal_stats (cr_id INTEGER, ts INTEGER, weekday INTEGER, hour INTEGER,
                                       new_auctions INTEGER, deals INTEGER, deal_value INTEGER,
                                       PRIMARY KEY (cr_id, ts));
CREATE TABLE IF NOT EXISTS scout (cr_id INTEGER PRIMARY KEY, ts INTEGER, auctions INTEGER, items INTEGER,
                                  deals INTEGER, deal_value INTEGER, flips INTEGER, flip_profit INTEGER,
                                  top TEXT);
CREATE TABLE IF NOT EXISTS eu_item (item_key TEXT PRIMARY KEY, realms INTEGER, median INTEGER, low INTEGER,
                                    updated INTEGER, high INTEGER);
CREATE TABLE IF NOT EXISTS eu_listing (item_key TEXT, cr_id INTEGER, min_buyout INTEGER, qty INTEGER, n INTEGER,
                                       PRIMARY KEY (item_key, cr_id)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS price_point (cr_id INTEGER, item_key TEXT, unit INTEGER, qty INTEGER, n INTEGER,
                                        PRIMARY KEY (item_key, cr_id, unit)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS eu_history (item_key TEXT, day TEXT, low INTEGER, median INTEGER, qty INTEGER,
                                       realms INTEGER, sale_avg INTEGER, PRIMARY KEY (item_key, day)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS decor (item_key TEXT PRIMARY KEY, name TEXT, quality TEXT, subclass_name TEXT,
                                  stackable INTEGER, updated INTEGER);
"""


def db():
    con = sqlite3.connect(DB_PATH, timeout=60)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    return con


def init_db():
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    with db() as con:
        con.executescript(SCHEMA)
        cols = [r["name"] for r in con.execute("PRAGMA table_info(item)")]
        if "stackable" not in cols:
            con.execute("ALTER TABLE item ADD COLUMN stackable INTEGER")
        ecols = [r["name"] for r in con.execute("PRAGMA table_info(eu_item)")]
        if "high" not in ecols:
            con.execute("ALTER TABLE eu_item ADD COLUMN high INTEGER")
        rcols = [r["name"] for r in con.execute("PRAGMA table_info(realm)")]
        if "locale" not in rcols:
            con.execute("ALTER TABLE realm ADD COLUMN locale TEXT")
            con.execute("ALTER TABLE realm ADD COLUMN rtype TEXT")
            meta_set(con, "realms_updated", 0)  # Realm-Liste mit Sprache neu holen
        if "pop" not in [r["name"] for r in con.execute("PRAGMA table_info(realm)")]:
            con.execute("ALTER TABLE realm ADD COLUMN pop TEXT")
            meta_set(con, "realms_updated", 0)  # Bevölkerung nachholen


def meta_get(con, k, default=None):
    row = con.execute("SELECT v FROM meta WHERE k=?", (k,)).fetchone()
    return row["v"] if row else default


def meta_set(con, k, v):
    con.execute("INSERT OR REPLACE INTO meta (k, v) VALUES (?, ?)", (k, str(v)))


def norm(name):
    """Realmnamen vergleichbar machen: 'Die Aldor' -> 'diealdor'."""
    return re.sub(r"[^a-z0-9äöüß]", "", (name or "").lower())


def tracked_realms():
    raw = os.environ.get("REALMS", "")
    if raw.strip().lower() == "all":
        return "all"
    return [r.strip() for r in raw.split(",") if r.strip()]


# --------------------------------------------------------------------------
# Blizzard-API
# --------------------------------------------------------------------------
class Blizzard:
    def __init__(self, client_id, secret):
        self.client_id, self.secret = client_id, secret
        self.token, self.expires = None, 0
        self.sess = requests.Session()

    def _token(self):
        if self.token and time.time() < self.expires - 60:
            return self.token
        r = requests.post("https://oauth.battle.net/token", data={"grant_type": "client_credentials"},
                          auth=(self.client_id, self.secret), timeout=30)
        r.raise_for_status()
        j = r.json()
        self.token, self.expires = j["access_token"], time.time() + j.get("expires_in", 3600)
        return self.token

    def get(self, path, namespace, headers=None, absolute=False, params=None):
        url = path if absolute else API + path
        p = {} if absolute else {"namespace": f"{namespace}-{REGION}", "locale": LOCALE}
        p.update(params or {})
        params = p
        h = {"Authorization": f"Bearer {self._token()}"}
        h.update(headers or {})
        for attempt in range(5):
            r = self.sess.get(url, params=params, headers=h, timeout=180)
            if r.status_code == 429:
                time.sleep(2 ** attempt)
                continue
            if r.status_code == 304:
                return None, r
            if r.status_code == 404:
                return {}, r
            r.raise_for_status()
            return r.json(), r
        r.raise_for_status()


def refresh_realms(bz):
    """Alle Realm-Gruppen der Region mit ihren Realmnamen einlesen (einmal am Tag)."""
    idx, _ = bz.get("/data/wow/connected-realm/index", "dynamic")
    links = [x["href"] for x in idx.get("connected_realms", [])]
    rows = []

    def one(href):
        data, _ = bz.get(href.split("?")[0] + f"?namespace=dynamic-{REGION}&locale={LOCALE}", "dynamic", absolute=True)
        out = []
        for realm in (data or {}).get("realms", []):
            name = realm.get("name")
            if isinstance(name, dict):
                name = name.get(LOCALE) or next(iter(name.values()), "")
            rtype = _loc((realm.get("type") or {}).get("name"))
            pop = (data.get("population") or {}).get("type")
            out.append((data["id"], name, realm.get("slug"), realm.get("locale"), rtype, pop))
        return out

    with ThreadPoolExecutor(8) as ex:
        for part in ex.map(one, links):
            rows.extend(part)
    with db() as con:
        con.execute("DELETE FROM realm")
        con.executemany("INSERT OR REPLACE INTO realm (cr_id, name, slug, locale, rtype, pop) VALUES (?, ?, ?, ?, ?, ?)", rows)
        meta_set(con, "realms_updated", int(time.time()))
    log.info("Realm-Gruppen: %d Realms in %d Gruppen", len(rows), len(links))


def tracked_cr_ids():
    """Realm-Gruppen-IDs zu den Realms aus REALMS (oder alle)."""
    want = tracked_realms()
    with db() as con:
        rows = con.execute("SELECT cr_id, name, slug FROM realm").fetchall()
    if want == "all":
        return sorted({r["cr_id"] for r in rows})
    ids, missing = set(), []
    for w in want:
        hit = [r["cr_id"] for r in rows if norm(r["name"]) == norm(w) or norm(r["slug"]) == norm(w)]
        if not hit:  # z. B. "Mithrilorden" -> "Der Mithrilorden"
            hit = [r["cr_id"] for r in rows if norm(w) in norm(r["name"]) or norm(w) in norm(r["slug"])]
            if len(set(hit)) > 1:
                log.warning("Realm '%s' ist mehrdeutig: %s", w,
                            ", ".join(sorted({r["name"] for r in rows if norm(w) in norm(r["name"])})))
        if hit:
            ids.update(hit)
        else:
            missing.append(w)
    if missing:
        log.warning("Realm(s) nicht gefunden: %s", ", ".join(missing))
    return sorted(ids)


def item_key(item):
    if item.get("id") == PET_CAGE and item.get("pet_species_id"):
        return f"p:{item['pet_species_id']}"
    return f"i:{item['id']}"


def fetch_auctions(bz, cr_id):
    with db() as con:
        row = con.execute("SELECT last_modified FROM snapshot WHERE cr_id=?", (cr_id,)).fetchone()
    headers = {"If-Modified-Since": row["last_modified"]} if row and row["last_modified"] else {}
    data, resp = bz.get(f"/data/wow/connected-realm/{cr_id}/auctions", "dynamic", headers=headers)
    if data is None:
        log.info("Realm-Gruppe %d: keine neuen Daten", cr_id)
        return False
    agg = {}
    n = 0
    ids, units = [], {}
    points = {}
    for a in data.get("auctions", []):
        buyout = a.get("buyout")
        qty = a.get("quantity") or 1
        if not buyout or "item" not in a:
            continue
        n += 1
        key = item_key(a["item"])
        unit = buyout // qty
        if a.get("id"):
            ids.append(a["id"])
            units[a["id"]] = (key, unit)
        pp = points.get((key, unit))
        if pp is None:
            points[(key, unit)] = [qty, 1]
        else:
            pp[0] += qty
            pp[1] += 1
        e = agg.get(key)
        if e is None:
            agg[key] = [unit, qty, 1]
        else:
            if unit < e[0]:
                e[0] = unit
            e[1] += qty
            e[2] += 1
    record_deal_stats(cr_id, ids, units)
    with db() as con:
        con.execute("DELETE FROM listing WHERE cr_id=?", (cr_id,))
        con.executemany("INSERT INTO listing (cr_id, item_key, min_buyout, qty, n) VALUES (?, ?, ?, ?, ?)",
                        [(cr_id, k, v[0], v[1], v[2]) for k, v in agg.items()])
        con.execute("DELETE FROM price_point WHERE cr_id=?", (cr_id,))
        con.executemany("INSERT INTO price_point (cr_id, item_key, unit, qty, n) VALUES (?, ?, ?, ?, ?)",
                        [(cr_id, k, u, v[0], v[1]) for (k, u), v in points.items()])
        con.execute("INSERT OR REPLACE INTO snapshot (cr_id, last_modified, fetched_at, n_auctions) VALUES (?, ?, ?, ?)",
                    (cr_id, resp.headers.get("Last-Modified"), int(time.time()), n))
    log.info("Realm-Gruppe %d: %d Auktionen, %d Items", cr_id, n, len(agg))
    return True


def record_deal_stats(cr_id, ids, units):
    """Neue Auktionen seit dem letzten Snapshot zählen und wie viele davon Schnäppchen sind."""
    with db() as con:
        prev = {r[0] for r in con.execute("SELECT id FROM auction_id WHERE cr_id=?", (cr_id,))}
        if prev:
            tsm = {r["item_key"]: (r["sale_avg"], r["sale_rate"]) for r in
                   con.execute("SELECT item_key, sale_avg, sale_rate FROM tsm WHERE sale_avg IS NOT NULL")}
            new = [i for i in ids if i not in prev]
            deals, value = 0, 0
            for i in new:
                key, unit = units[i]
                t = tsm.get(key)
                if t and (t[1] or 0) >= DEAL_MIN_RATE and unit <= t[0] * DEAL_PCT / 100:
                    deals += 1
                    value += t[0] - unit
            now = datetime.now(ZoneInfo(TIMEZONE))
            con.execute("INSERT OR REPLACE INTO deal_stats VALUES (?, ?, ?, ?, ?, ?, ?)",
                        (cr_id, int(now.timestamp()), now.weekday(), now.hour, len(new), deals, int(value)))
            log.info("Realm-Gruppe %d: %d neue Auktionen, %d Schnäppchen", cr_id, len(new), deals)
        con.execute("DELETE FROM auction_id WHERE cr_id=?", (cr_id,))
        con.executemany("INSERT OR IGNORE INTO auction_id (cr_id, id) VALUES (?, ?)", [(cr_id, i) for i in ids])


def scout_realm(bz, cr_id, tsm, home, eu=None, euq=None):
    """Eine fremde Realm-Gruppe bewerten: Schnäppchen und Flips zu deinen Realms.
    Dazu Mindestpreis, Menge und Angebote je Item für die Item-Detailansicht speichern."""
    data, _ = bz.get(f"/data/wow/connected-realm/{cr_id}/auctions", "dynamic")
    mins, agg, n = {}, {}, 0
    for a in (data or {}).get("auctions", []):
        buyout, qty = a.get("buyout"), a.get("quantity") or 1
        if not buyout or "item" not in a:
            continue
        n += 1
        key, unit = item_key(a["item"]), buyout // qty
        if key not in mins or unit < mins[key]:
            mins[key] = unit
        e = agg.get(key)
        if e is None:
            agg[key] = [qty, 1]
        else:
            e[0] += qty
            e[1] += 1
    if data is not None:
        with db() as con:
            con.execute("DELETE FROM eu_listing WHERE cr_id=?", (cr_id,))
            con.executemany("INSERT INTO eu_listing (item_key, cr_id, min_buyout, qty, n) VALUES (?, ?, ?, ?, ?)",
                            [(k, cr_id, mins[k], v[0], v[1]) for k, v in agg.items()])
    if eu is not None:
        for key, unit in mins.items():
            arr = eu.get(key)
            if arr is None:
                arr = eu[key] = array("Q")
            arr.append(unit)
            if euq is not None:
                euq[key] = euq.get(key, 0) + agg[key][0]
    deals = deal_value = flips = flip_profit = 0
    top = []
    for key, unit in mins.items():
        t = tsm.get(key)
        if not t or not t[0] or (t[1] or 0) < DEAL_MIN_RATE:
            continue
        sale = t[0]
        if unit <= sale * DEAL_PCT / 100:
            deals += 1
            deal_value += sale - unit
        listed = home.get(key)
        sell = min(sale, max(listed)) if listed else sale
        profit = sell * 0.95 - unit
        if profit >= SCOUT_MIN_PROFIT and unit > 0 and profit / unit * 100 >= SCOUT_MIN_RETURN:
            flips += 1
            flip_profit += profit
            top.append((int(profit), key, unit))
    top.sort(reverse=True)
    import json
    with db() as con:
        con.execute("INSERT OR REPLACE INTO scout VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (cr_id, int(time.time()), n, len(mins), deals, int(deal_value), flips, int(flip_profit),
                     json.dumps(top[:10])))
    return flips


_live_locks = {}


def live_realm(bz, cr_id, max_age=3600):
    """Auktionen einer fremden Realm-Gruppe bei Bedarf holen (Item-Detail): Einzelangebote + Mindestpreise.
    Bleibt max_age Sekunden gültig. Einzelangebote fremder Realms werden nach einem Tag wieder gelöscht."""
    lock = _live_locks.setdefault(cr_id, threading.Lock())
    with lock:
        with db() as con:
            ts = int(meta_get(con, f"live:{cr_id}", 0))
        if time.time() - ts < max_age:
            return ts
        data, _ = bz.get(f"/data/wow/connected-realm/{cr_id}/auctions", "dynamic")
        agg, points = {}, {}
        for a in (data or {}).get("auctions", []):
            buyout, qty = a.get("buyout"), a.get("quantity") or 1
            if not buyout or "item" not in a:
                continue
            key, unit = item_key(a["item"]), buyout // qty
            pp = points.get((key, unit))
            if pp is None:
                points[(key, unit)] = [qty, 1]
            else:
                pp[0] += qty
                pp[1] += 1
            e = agg.get(key)
            if e is None:
                agg[key] = [unit, qty, 1]
            else:
                e[0] = min(e[0], unit)
                e[1] += qty
                e[2] += 1
        now = int(time.time())
        with db() as con:
            con.execute("DELETE FROM price_point WHERE cr_id=?", (cr_id,))
            con.executemany("INSERT INTO price_point (cr_id, item_key, unit, qty, n) VALUES (?, ?, ?, ?, ?)",
                            [(cr_id, k, u, v[0], v[1]) for (k, u), v in points.items()])
            con.execute("DELETE FROM eu_listing WHERE cr_id=?", (cr_id,))
            con.executemany("INSERT INTO eu_listing (item_key, cr_id, min_buyout, qty, n) VALUES (?, ?, ?, ?, ?)",
                            [(k, cr_id, v[0], v[1], v[2]) for k, v in agg.items()])
            meta_set(con, f"live:{cr_id}", now)
            own = set(tracked_cr_ids())
            for r in con.execute("SELECT k, v FROM meta WHERE k LIKE 'live:%'").fetchall():
                old = int(r["k"].split(":")[1])
                if old not in own and now - int(r["v"]) > 86400:
                    con.execute("DELETE FROM price_point WHERE cr_id=?", (old,))
                    con.execute("DELETE FROM meta WHERE k=?", (r["k"],))
        log.info("Realm-Gruppe %d live geholt: %d Items", cr_id, len(agg))
        return now


def scout_all(bz):
    """Alle Realm-Gruppen der Region einmal durchgehen (die eigenen ausgenommen)."""
    own = set(tracked_cr_ids())
    with db() as con:
        all_crs = sorted({r[0] for r in con.execute("SELECT cr_id FROM realm")})
        tsm = {r["item_key"]: (r["sale_avg"], r["sale_rate"]) for r in
               con.execute("SELECT item_key, sale_avg, sale_rate FROM tsm WHERE sale_avg IS NOT NULL")}
        home = {}
        for r in con.execute("SELECT item_key, min_buyout FROM listing WHERE cr_id IN (%s)" % ",".join("?" * len(own)),
                             list(own)) if own else []:
            home.setdefault(r["item_key"], []).append(r["min_buyout"])
    todo = [cr for cr in all_crs if cr not in own]
    log.info("Realm-Scout: %d Realm-Gruppen ...", len(todo))
    # EU-weites Angebot: pro Item der Mindestpreis je Realm-Gruppe (inkl. der eigenen)
    eu, euq = {}, {}
    with db() as con:
        for r in con.execute("SELECT item_key, min_buyout, qty FROM listing"):
            eu.setdefault(r["item_key"], array("Q")).append(r["min_buyout"])
            euq[r["item_key"]] = euq.get(r["item_key"], 0) + (r["qty"] or 0)
    for i, cr in enumerate(todo, 1):
        try:
            f = scout_realm(bz, cr, tsm, home, eu, euq)
            log.info("Scout %d/%d: Realm-Gruppe %d - %d Flips", i, len(todo), cr, f)
        except Exception as e:
            log.warning("Scout Realm-Gruppe %d: %s", cr, e)
    now = int(time.time())
    day = datetime.now(ZoneInfo(TIMEZONE)).strftime("%Y-%m-%d")
    rows, hist = [], []
    for key, arr in eu.items():
        vals = sorted(arr)
        rows.append((key, len(vals), vals[len(vals) // 2], vals[0], now, vals[-1]))
        hist.append((key, day, vals[0], vals[len(vals) // 2], euq.get(key, 0), len(vals), (tsm.get(key) or (None,))[0]))
    with db() as con:
        con.executemany("INSERT OR REPLACE INTO eu_history (item_key, day, low, median, qty, realms, sale_avg) "
                        "VALUES (?, ?, ?, ?, ?, ?, ?)", hist)
        if HISTORY_DAYS > 0:
            cut = datetime.fromtimestamp(now - HISTORY_DAYS * 86400, ZoneInfo(TIMEZONE)).strftime("%Y-%m-%d")
            con.execute("DELETE FROM eu_history WHERE day < ?", (cut,))
        con.execute("DELETE FROM eu_item")
        con.executemany("INSERT INTO eu_item (item_key, realms, median, low, updated, high) VALUES (?, ?, ?, ?, ?, ?)", rows)
        meta_set(con, "scout_updated", now)
    log.info("Realm-Scout fertig - %d verschiedene Items EU-weit im Angebot", len(rows))


# --------------------------------------------------------------------------
# Item-Metadaten (deutsche Namen, Qualität, Bindung, Icon)
# --------------------------------------------------------------------------
def fetch_item_meta(bz, key):
    kind, num = key.split(":")
    try:
        if kind == "p":
            data, _ = bz.get(f"/data/wow/pet/{num}", "static")
            if not data:
                return (key, None, None, None, None, None, None, None, None, int(time.time()), 0, None)
            icon = data.get("icon")
            return (key, data.get("name"), "PET", 17, "Haustier", None,
                    None if data.get("is_tradable", True) else "ON_ACQUIRE", None, icon, int(time.time()), 1, 0)
        data, _ = bz.get(f"/data/wow/item/{num}", "static")
        if not data:
            return (key, None, None, None, None, None, None, None, None, int(time.time()), 0, None)
        icon = None
        media, _ = bz.get(f"/data/wow/media/item/{num}", "static")
        for asset in (media or {}).get("assets", []):
            if asset.get("key") == "icon":
                icon = asset.get("value")
        binding = ((data.get("preview_item") or {}).get("binding") or {}).get("type")
        return (key, data.get("name"), (data.get("quality") or {}).get("type"),
                (data.get("item_class") or {}).get("id"), (data.get("item_class") or {}).get("name"),
                (data.get("item_subclass") or {}).get("name"), binding, data.get("level"), icon,
                int(time.time()), 1, 1 if data.get("is_stackable") else 0)
    except requests.RequestException as e:
        log.warning("Item %s: %s", key, e)
        return None


def fill_item_meta(bz, min_sale=100_000):
    """Metadaten für alle Items holen, die irgendwo angeboten werden und laut TSM etwas wert sind."""
    with db() as con:
        keys = [r["item_key"] for r in con.execute(
            """SELECT DISTINCT l.item_key FROM listing l
               JOIN tsm t ON t.item_key = l.item_key
               LEFT JOIN item i ON i.item_key = l.item_key
               WHERE i.item_key IS NULL AND COALESCE(t.sale_avg, t.market, 0) >= ?""", (min_sale,))]
        # für Sniper-Listen: alle Items mit guter Verkaufsrate, auch wenn sie auf deinen Realms nie angeboten werden
        keys += [r["item_key"] for r in con.execute(
            """SELECT t.item_key FROM tsm t LEFT JOIN item i ON i.item_key = t.item_key
               WHERE i.item_key IS NULL AND COALESCE(t.sale_rate, 0) >= ? AND COALESCE(t.sale_avg, 0) >= ?""",
            (SNIPER_MIN_RATE, 10_000))]
        keys = list(dict.fromkeys(keys))
    if not keys:
        return
    log.info("Hole Metadaten für %d Items ...", len(keys))
    done = 0
    with ThreadPoolExecutor(8) as ex:
        batch = []
        for row in ex.map(lambda k: fetch_item_meta(bz, k), keys):
            if row:
                batch.append(row)
            if len(batch) >= 200:
                _store_meta(batch)
                done += len(batch)
                batch = []
        _store_meta(batch)
        done += len(batch)
    log.info("Metadaten: %d Items gespeichert", done)


def _store_meta(rows):
    if not rows:
        return
    with db() as con:
        con.executemany("""INSERT OR REPLACE INTO item (item_key, name, quality, class_id, class_name, subclass_name,
                           binding, level, icon, fetched_at, ok, stackable)
                           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""", rows)


# --------------------------------------------------------------------------
# Alle Deko-Items (Item-Klasse "Behausung") ueber die Blizzard-Suche
# --------------------------------------------------------------------------
DECOR_CLASS_ID = int(os.environ.get("DECOR_CLASS_ID", "20"))


def _loc(v):
    if isinstance(v, dict):
        return v.get(LOCALE) or v.get("en_US") or next(iter(v.values()), None)
    return v


def refresh_decor(bz):
    rows, page, pages = [], 1, 1
    now = int(time.time())
    while page <= pages:
        data, _ = bz.get(f"/data/wow/search/item?item_class.id={DECOR_CLASS_ID}&orderby=id&_pageSize=1000&_page={page}",
                         "static")
        if not data:
            break
        pages = data.get("pageCount") or 1
        for res in data.get("results", []):
            d = res.get("data") or {}
            if not d.get("id"):
                continue
            rows.append((f"i:{d['id']}", _loc(d.get("name")), (d.get("quality") or {}).get("type"),
                         _loc((d.get("item_subclass") or {}).get("name")),
                         1 if d.get("is_stackable") else 0, now))
        page += 1
    if not rows:
        log.warning("Deko-Suche lieferte keine Items (Klasse %s)", DECOR_CLASS_ID)
        return
    with db() as con:
        con.execute("DELETE FROM decor")
        con.executemany("INSERT OR REPLACE INTO decor VALUES (?, ?, ?, ?, ?, ?)", rows)
        meta_set(con, "decor_updated", now)
    log.info("Deko: %d Items (%d Seiten)", len(rows), pages)


# --------------------------------------------------------------------------
# Item-Infos in großen Paketen: alle Items aus den TSM-Regionsdaten
# --------------------------------------------------------------------------
def fill_bulk_meta(bz):
    """Name, Qualität, Kategorie und 'stapelbar' für alle TSM-Items über die Blizzard-Suche
    (1000 Item-IDs pro Abfrage) und alle Haustiere über den Haustier-Index."""
    with db() as con:
        missing = [r["item_key"] for r in con.execute(
            """SELECT t.item_key FROM tsm t LEFT JOIN item i ON i.item_key = t.item_key
               WHERE i.item_key IS NULL OR i.stackable IS NULL
               UNION
               SELECT e.item_key FROM eu_item e LEFT JOIN item i ON i.item_key = e.item_key
               WHERE i.item_key IS NULL OR i.stackable IS NULL""")]
    item_ids = sorted({int(k[2:]) for k in missing if k.startswith("i:")})
    pet_ids = {int(k[2:]) for k in missing if k.startswith("p:")}
    now, rows = int(time.time()), []

    if pet_ids:
        data, _ = bz.get("/data/wow/pet/index", "static")
        for p in (data or {}).get("pets", []):
            if p.get("id") in pet_ids:
                rows.append((f"p:{p['id']}", _loc(p.get("name")), "PET", 17, "Haustier", None,
                             None, None, None, now, 1, 0))
        _store_meta(rows)
        log.info("Haustier-Namen: %d", len(rows))

    chunks = sorted({i // 1000 for i in item_ids})
    if not chunks:
        return
    wanted = set(item_ids)
    log.info("Item-Infos in Paketen: %d Items in %d Abfragen ...", len(item_ids), len(chunks))
    done = 0

    def one(chunk):
        lo, hi = chunk * 1000, chunk * 1000 + 999
        data, _ = bz.get("/data/wow/search/item", "static",
                         params={"id": f"[{lo},{hi}]", "orderby": "id", "_pageSize": 1000, "_page": 1})
        out = []
        for res in (data or {}).get("results", []):
            d = res.get("data") or {}
            iid = d.get("id")
            if iid not in wanted:
                continue
            out.append((f"i:{iid}", _loc(d.get("name")), (d.get("quality") or {}).get("type"),
                        (d.get("item_class") or {}).get("id"), _loc((d.get("item_class") or {}).get("name")),
                        _loc((d.get("item_subclass") or {}).get("name")), None, d.get("level"), None, now, 1,
                        1 if d.get("is_stackable") else 0))
        return out

    with ThreadPoolExecutor(6) as ex:
        for part in ex.map(one, chunks):
            # vorhandene Einträge (mit Icon/Bindung) nicht überschreiben, nur ergänzen
            with db() as con:
                for r in part:
                    cur = con.execute("SELECT ok FROM item WHERE item_key=?", (r[0],)).fetchone()
                    if cur:
                        con.execute("UPDATE item SET stackable=? WHERE item_key=?", (r[11], r[0]))
                    else:
                        con.execute("""INSERT INTO item (item_key, name, quality, class_id, class_name, subclass_name,
                                       binding, level, icon, fetched_at, ok, stackable)
                                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""", r)
            done += len(part)
    log.info("Item-Infos in Paketen: %d Items ergänzt", done)


# --------------------------------------------------------------------------
# TSM-API (Regionsdaten: Verkaufs-Ø, Verkaufsrate, Verkäufe/Tag)
# --------------------------------------------------------------------------
def tsm_token(api_key):
    r = requests.post("https://auth.tradeskillmaster.com/oauth2/token", json={
        "client_id": TSM_CLIENT_ID, "grant_type": "api_token",
        "scope": "app:realm-api app:pricing-api", "token": api_key}, timeout=30)
    r.raise_for_status()
    return r.json()["access_token"]


def _first(d, *names):
    for n in names:
        if d.get(n) is not None:
            return d[n]
    return None


def refresh_tsm(api_key):
    token = tsm_token(api_key)
    h = {"Authorization": f"Bearer {token}"}
    r = requests.get("https://realm-api.tradeskillmaster.com/regions", headers=h, timeout=60)
    r.raise_for_status()
    regions = r.json()
    regions = regions.get("items", regions) if isinstance(regions, dict) else regions
    region_id = None
    for reg in regions:
        prefix = (reg.get("regionPrefix") or reg.get("prefix") or "").lower()
        version = (reg.get("gameVersion") or "").lower()
        if prefix == REGION and version in ("retail", ""):
            region_id = reg.get("regionId") or reg.get("id")
            break
    if region_id is None:
        raise RuntimeError(f"TSM-Region '{REGION}' nicht gefunden: {regions[:5]}")
    r = requests.get(f"https://pricing-api.tradeskillmaster.com/region/{region_id}", headers=h, timeout=300)
    r.raise_for_status()
    data = r.json()
    data = data.get("items", data) if isinstance(data, dict) else data
    now = int(time.time())
    rows = []
    for e in data:
        species = _first(e, "petSpeciesId", "petSpeciesID")
        item_id = _first(e, "itemId", "itemID")
        if species:
            key = f"p:{species}"
        elif item_id:
            key = f"i:{item_id}"
        else:
            continue
        rows.append((key, _first(e, "marketValue"), _first(e, "historical"), _first(e, "avgSalePrice"),
                     _first(e, "saleRate"), _first(e, "soldPerDay"), now))
    with db() as con:
        con.executemany("""INSERT OR REPLACE INTO tsm (item_key, market, historical, sale_avg, sale_rate,
                           sold_per_day, updated) VALUES (?, ?, ?, ?, ?, ?, ?)""", rows)
        meta_set(con, "tsm_updated", now)
    log.info("TSM: %d Einträge für Region %s (%s)", len(rows), REGION, region_id)


# --------------------------------------------------------------------------
# Ablauf
# --------------------------------------------------------------------------
class Collector:
    def __init__(self):
        self.bz = Blizzard(os.environ["BLIZZARD_CLIENT_ID"], os.environ["BLIZZARD_CLIENT_SECRET"])
        self.tsm_key = os.environ.get("TSM_API_KEY", "")
        self.wake = threading.Event()
        self.scout_wake = threading.Event()
        self.scouting = False
        self.running = False
        self.last_error = None

    def run_once(self):
        self.running = True
        try:
            with db() as con:
                realms_updated = int(meta_get(con, "realms_updated", 0))
                tsm_updated = int(meta_get(con, "tsm_updated", 0))
            if time.time() - realms_updated > 86400:
                refresh_realms(self.bz)
            with db() as con:
                decor_updated = int(meta_get(con, "decor_updated", 0))
            if time.time() - decor_updated > 86400:
                try:
                    refresh_decor(self.bz)
                except Exception as e:
                    log.exception("Deko-Liste: %s", e)
                    self.last_error = f"Deko: {e}"
            if self.tsm_key and time.time() - tsm_updated > TSM_HOURS * 3600:
                try:
                    refresh_tsm(self.tsm_key)
                except Exception as e:  # TSM darf den Scan nicht blockieren
                    log.exception("TSM-Abruf fehlgeschlagen: %s", e)
                    self.last_error = f"TSM: {e}"
            for cr in tracked_cr_ids():
                try:
                    fetch_auctions(self.bz, cr)
                except Exception as e:
                    log.exception("Auktionen Realm-Gruppe %d: %s", cr, e)
                    self.last_error = f"Auktionen {cr}: {e}"
            try:
                fill_bulk_meta(self.bz)
            except Exception as e:
                log.exception("Item-Infos (Pakete): %s", e)
            fill_item_meta(self.bz)
            with db() as con:
                meta_set(con, "last_run", int(time.time()))
        finally:
            self.running = False

    def loop(self):
        while True:
            try:
                self.run_once()
            except Exception as e:
                log.exception("Lauf fehlgeschlagen: %s", e)
                self.last_error = str(e)
            self.wake.wait(SCAN_MINUTES * 60)
            self.wake.clear()

    def scout_loop(self):
        time.sleep(300)  # erst den normalen Lauf durchlassen
        while True:
            with db() as con:
                last = int(meta_get(con, "scout_updated", 0))
            due = SCOUT_HOURS > 0 and time.time() - last > SCOUT_HOURS * 3600
            if due or self.scout_wake.is_set():
                self.scout_wake.clear()
                self.scouting = True
                try:
                    scout_all(self.bz)
                    self.scouting = "names"
                    fill_bulk_meta(self.bz)  # Namen der neu entdeckten Items gleich nachholen
                except Exception as e:
                    log.exception("Realm-Scout: %s", e)
                finally:
                    self.scouting = False
            self.scout_wake.wait(600)

    def start(self):
        threading.Thread(target=self.loop, daemon=True).start()
        threading.Thread(target=self.scout_loop, daemon=True).start()
