#!/usr/bin/env python3
"""Generator data simulasi POS F&B untuk OLTP (PostgreSQL / Neon), schema `fnb`.

Semua data sintetis dan DETERMINISTIK per tanggal: menjalankan ulang tanggal yang sama menghasilkan ID yang sama,
dan `ON CONFLICT DO NOTHING` mencegah duplikasi (idempotent).

Perintah:
  apply-schema [--drop]     buat schema fnb (29 tabel) + schema sim (state generator)
  init-master               seed master (SQL) + karyawan sintetis
  backfill --start --end    simulasi historis (state inventori dimulai dari nol; menolak bila state sudah ada)
  daily --date YYYY-MM-DD   proses 1 hari (otomatis menyusul hari yang terlewat sejak proses terakhir) + HR sync
  hr-sync --end YYYY-MM-DD  bangun ulang data HR (hr.py) s.d. tanggal lalu upsert
  stats                     jumlah baris per tabel dan ukuran database
  storage-check             peringatan (::warning:: GitHub) bila storage Neon >= 85% batas free tier
  reset --yes               kosongkan data transaksi dan state (master dipertahankan)

Koneksi: env SOURCE_DATABASE_URL (endpoint DIRECT Neon, bukan -pooler).
Model permintaan, story event, dan siklus inventori: lihat plan §4 dan config.yaml.
"""
import argparse
import bisect
import datetime as dt
import hashlib
import math
import os
import random
import sys
import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from itertools import accumulate
from pathlib import Path

import numpy as np
import psycopg
import yaml

HERE = Path(__file__).resolve().parent
SCHEMA_DIR = HERE.parent / "schema"
CFG = yaml.safe_load((HERE / "config.yaml").read_text(encoding="utf-8"))
TZ = dt.timezone(dt.timedelta(hours=CFG["timezone_offset_hours"]))
D = CFG["demand"]
INV = CFG["inventory"]
EPOCH = dt.date(2025, 1, 1)

ONLINE = "Online Delivery"
OFFLINE = "Offline"
ONLINE_PREFIX = {"GOFOOD": "GF", "GRABFOOD": "GR", "SHOPEEFOOD": "SF"}

FIRST_NAMES = ["Budi", "Siti", "Agus", "Dewi", "Rizky", "Putri", "Andi", "Ayu", "Fajar", "Nina", "Hendra", "Rina",
               "Bagas", "Maya", "Dimas", "Lestari", "Eko", "Wulan", "Yoga", "Intan", "Rama", "Sari", "Tegar", "Citra",
               "Bayu", "Anisa", "Galih", "Fitri", "Arif", "Mega", "Reza", "Nadia", "Teguh", "Sinta", "Irfan", "Laras"]
LAST_NAMES = ["Santoso", "Wijaya", "Pratama", "Kusuma", "Hidayat", "Saputra", "Lestari", "Nugroho", "Rahmawati",
              "Setiawan", "Purnama", "Firmansyah", "Hartono", "Susanto", "Wibowo", "Maulana", "Permata", "Gunawan"]
CANCEL_REASONS = ["Customer membatalkan", "Driver tidak ditemukan", "Stok habis", "Salah pesan"]


# ----------------------------------------------------------------------------- util
def seed_int(*parts):
    raw = "|".join(str(p) for p in (CFG["seed"], *parts)).encode()
    return int.from_bytes(hashlib.sha256(raw).digest()[:8], "big")


def rnd_for(*parts):
    return random.Random(seed_int(*parts))


def np_for(*parts):
    return np.random.default_rng(seed_int(*parts))


def local_dt(day, hour, minute=0, second=0):
    return dt.datetime(day.year, day.month, day.day, hour, minute, second, tzinfo=TZ)


def day_index(day):
    return (day - EPOCH).days


def poisson_small(rnd, lam):
    limit, k, p = math.exp(-lam), 0, 1.0
    while True:
        p *= rnd.random()
        if p <= limit:
            return k
        k += 1


def is_month_end(day):
    return (day + dt.timedelta(days=1)).day == 1


def daterange(a, b):
    d = a
    while d <= b:
        yield d
        d += dt.timedelta(days=1)


def db_url():
    url = os.environ.get("SOURCE_DATABASE_URL")
    if not url:
        sys.exit("SOURCE_DATABASE_URL belum diset (lihat .env.example)")
    return url.replace("postgresql+psycopg2://", "postgresql://")


def connect():
    conn = psycopg.connect(db_url())
    conn.autocommit = True
    return conn


# ----------------------------------------------------------------------------- master (dibaca dari DB)
class Master:
    def __init__(self, conn):
        q = lambda sql: conn.execute(sql).fetchall()
        self.outlets = {r[0]: {"type": r[1], "opened": r[2], "closed": r[3]} for r in
                        q("select outlet_id, outlet_type, opened_date, closed_date from fnb.outlets")}
        self.menu = {r[0]: {"launched": r[1], "discontinued": r[2], "group": r[3]} for r in q(
            "select m.menu_item_id, m.launched_date, m.discontinued_date, c.category_group "
            "from fnb.menu_items m join fnb.menu_categories c using (category_code) where m.deleted_at is null")}
        self.prices = defaultdict(list)
        for item, grp, f, t, p in q("select menu_item_id, channel_group, effective_from, effective_to, selling_price "
                                     "from fnb.menu_item_prices order by effective_from"):
            self.prices[(item, grp)].append((f, t, int(p)))
        self.ingredients = {r[0]: {"uom": r[1], "is_prep": r[2], "shelf": r[3]} for r in q(
            "select ingredient_id, base_uom, is_prep_item, shelf_life_days from fnb.ingredients")}
        self.costs = defaultdict(list)
        for ing, f, t, c in q("select ingredient_id, effective_from, effective_to, standard_cost_per_base_uom "
                              "from fnb.ingredient_standard_costs order by effective_from"):
            self.costs[ing].append((f, t, float(c)))
        lines = defaultdict(list)
        for rid, ing, qty, loss in q("select recipe_id, ingredient_id, qty_per_yield, loss_pct from fnb.recipe_lines"):
            lines[rid].append((ing, float(qty), float(loss)))
        self.recipes = defaultdict(list)       # owner (menu_item_id / prep_ingredient_id) -> [(from, to, yield, lines)]
        for rid, mid, pid, yq, f, t in q("select recipe_id, menu_item_id, prep_ingredient_id, yield_qty, "
                                         "effective_from, effective_to from fnb.recipes order by effective_from"):
            self.recipes[mid or pid].append((f, t, float(yq), lines[rid]))
        self.mod_price = {}
        self.mod_lines = defaultdict(list)
        for mid, pd in q("select modifier_id, price_delta from fnb.modifiers"):
            self.mod_price[mid] = int(pd)
        for mid, ing, qd in q("select modifier_id, ingredient_id, qty_delta from fnb.modifier_lines"):
            self.mod_lines[mid].append((ing, float(qd)))
        self.promos = {r[0]: (r[1], float(r[2]), r[3], r[4]) for r in q(
            "select promo_code, promo_type, promo_value, start_date, coalesce(end_date, '9999-12-31'::date) from fnb.promotions")}
        self.employees = defaultdict(lambda: defaultdict(list))
        # hanya karyawan tetap: crew part-time (modul HR) tidak dipakai sebagai kasir/pencatat di data POS
        for eid, oid, role in q("select employee_id, outlet_id, job_role from fnb.employees "
                                "where employment_type = 'Full-time' order by employee_id"):
            self.employees[oid][role].append(eid)
        self._rl_cache = {}

    def promo(self, code, day):
        info = self.promos.get(code)
        if not info:
            return None
        ptype, pval, start, end = info
        if start <= day <= end:
            return (ptype, pval)
        return None

    def price(self, item, group, day):
        for f, t, p in self.prices[(item, group)]:
            if f <= day and (t is None or day < t):
                return p
        raise KeyError(f"harga tidak ada: {item} {group} {day}")

    def cost(self, ing, day):
        for f, t, c in self.costs[ing]:
            if f <= day and (t is None or day < t):
                return c
        return 0.0

    def recipe(self, owner, day):
        """-> (yield, [(ingredient, gross qty per 1 unit output)]) untuk resep yang berlaku pada `day`."""
        for idx, (f, t, yq, lines) in enumerate(self.recipes.get(owner, [])):
            if f <= day and (t is None or day < t):
                key = (owner, idx)
                if key not in self._rl_cache:
                    self._rl_cache[key] = (yq, [(i, q / yq / (1 - loss / 100.0)) for i, q, loss in lines])
                return self._rl_cache[key]
        return None

    def employee_ids(self, outlet):
        return [e for role in self.employees[outlet].values() for e in role]

    def explode_to_raw(self, ing, qty, day, out):
        """Pecah prep item sampai bahan raw."""
        if self.ingredients[ing]["is_prep"]:
            rec = self.recipe(ing, day)
            for sub, g in rec[1]:
                self.explode_to_raw(sub, qty * g, day, out)
        else:
            out[ing] += qty

    def prep_production_order(self, day):
        """Prep item urut induk -> anak (prep yang memakai prep lain diproduksi lebih dulu agar kebutuhan anak ikut terhitung)."""
        depth = {}

        def level(ing, seen=()):
            if ing in seen:
                raise ValueError(f"Siklus BOM terdeteksi: {' -> '.join(seen + (ing,))}")
            if ing not in depth:
                rec = self.recipe(ing, day)
                subs = [s for s, _ in rec[1] if self.ingredients[s]["is_prep"]] if rec else []
                depth[ing] = 1 + max((level(s, seen + (ing,)) for s in subs), default=0)
            return depth[ing]

        preps = [i for i, m in self.ingredients.items() if m["is_prep"]]
        return sorted(preps, key=lambda i: (-level(i), i))


class Pool:
    """Pelanggan terdaftar, urut tanggal registrasi. Tersedia untuk order hari D bila registrasi < D."""
    def __init__(self):
        self.dates, self.ids = [], []

    def add(self, day, ids):
        for c in sorted(ids):
            self.dates.append(day)
            self.ids.append(c)

    def avail(self, day):
        return bisect.bisect_left(self.dates, day)

    @classmethod
    def load(cls, conn, before):
        pool = cls()
        for cid, reg in conn.execute("select customer_id, (registered_at at time zone 'Asia/Jakarta')::date "
                                     "from fnb.customers order by registered_at, customer_id"):
            if reg < before:
                pool.dates.append(reg)
                pool.ids.append(cid)
        return pool


# ----------------------------------------------------------------------------- struktur hasil
ORDERS_COLS = ["order_id", "outlet_id", "channel_code", "customer_id", "cashier_id", "promo_code", "external_order_ref",
               "ordered_at", "order_status", "cancelled_at", "cancel_reason", "guest_count", "subtotal_amount",
               "item_discount_amount", "order_discount_amount", "service_charge_amount", "tax_amount", "total_amount",
               "created_at", "updated_at"]
ITEMS_COLS = ["order_item_id", "order_id", "menu_item_id", "qty", "unit_price", "line_discount_amount", "line_status",
              "void_reason", "created_at", "updated_at"]
MODS_COLS = ["order_item_id", "modifier_id", "price_delta", "created_at", "updated_at"]
PAY_COLS = ["payment_id", "order_id", "payment_method", "amount", "mdr_fee_amount", "paid_at", "created_at", "updated_at"]
REFUND_COLS = ["refund_id", "order_id", "order_item_id", "refund_amount", "refund_reason", "approved_by", "refunded_at",
               "created_at", "updated_at"]
CUST_COLS = ["customer_id", "full_name", "phone_number", "email", "birth_date", "registered_at", "created_at", "updated_at"]
GR_COLS = ["gr_id", "outlet_id", "supplier_id", "invoice_no", "received_at", "created_at", "updated_at"]
GRL_COLS = ["gr_line_id", "gr_id", "ingredient_id", "purchase_qty", "purchase_uom", "qty_base_uom", "line_amount",
            "expiry_date", "created_at", "updated_at"]
SC_COLS = ["count_id", "outlet_id", "count_date", "count_type", "counted_by", "created_at", "updated_at"]
SCL_COLS = ["count_id", "ingredient_id", "counted_qty_base", "created_at", "updated_at"]
WASTE_COLS = ["waste_id", "outlet_id", "logged_at", "ingredient_id", "menu_item_id", "qty", "reason_code", "recorded_by",
              "notes", "created_at", "updated_at"]
OPEX_COLS = ["expense_id", "outlet_id", "period_month", "category_code", "amount", "description", "created_at", "updated_at"]

# (tabel, kolom, OVERRIDING SYSTEM VALUE?) -- urutan sesuai dependensi FK
TABLE_ORDER = [("customers", CUST_COLS, False), ("orders", ORDERS_COLS, False), ("order_items", ITEMS_COLS, True),
               ("order_item_modifiers", MODS_COLS, False), ("payments", PAY_COLS, False), ("refunds", REFUND_COLS, False),
               ("goods_receipts", GR_COLS, False), ("goods_receipt_lines", GRL_COLS, True),
               ("stock_counts", SC_COLS, False), ("stock_count_lines", SCL_COLS, False),
               ("waste_logs", WASTE_COLS, False), ("operating_expenses", OPEX_COLS, False)]
KEY_OF = {"customers": "customers", "orders": "orders", "order_items": "items", "order_item_modifiers": "mods",
          "payments": "payments", "refunds": "refunds", "goods_receipts": "gr", "goods_receipt_lines": "grl",
          "stock_counts": "sc", "stock_count_lines": "scl", "waste_logs": "waste", "operating_expenses": "opex"}


class Bundle:
    def __init__(self):
        for key in KEY_OF.values():
            setattr(self, key, [])

    def extend(self, other):
        for key in KEY_OF.values():
            getattr(self, key).extend(getattr(other, key))


@dataclass
class OutletUsage:
    sales: Counter = field(default_factory=Counter)        # menu_item_id -> porsi
    mods: Counter = field(default_factory=Counter)         # modifier_id -> jumlah unit
    waste_events: list = field(default_factory=list)       # (menu_item_id, qty, reason_code)
    closed: bool = False


@dataclass
class Gen:
    day: dt.date
    now: Bundle
    late: Bundle                      # baris yang tersinkron hari berikutnya (order offline telat)
    online_completed: list            # kandidat refund H+1
    usage: dict                       # outlet_id -> OutletUsage (outlet yang sudah buka)
    new_customers: list               # [(customer_id, ...)] untuk pool


# ----------------------------------------------------------------------------- generator penjualan
def is_ramadan(day):
    return any(r["start"] <= day <= r["end"] for r in D["ramadan"])


def day_flags(day):
    rnd = rnd_for("rain", day)
    wet = day.month in D["wet_season_months"]
    rain = rnd.random() < (D["rain_prob_wet_season"] if wet else D["rain_prob"])
    return {"rain": rain, "ramadan": is_ramadan(day), "closed": day in D["closed_days"],
            "payday": day.day >= 25 or day.day == 1, "dow": D["dow_factor"][day.weekday()]}


def hour_weights(group, ramadan):
    base = D["hour_weights_offline" if group == OFFLINE else "hour_weights_online"]
    total = sum(base.values())
    w = {h: v / total for h, v in base.items() if v > 0}
    if ramadan:
        w = {h: v * D["ramadan_hour_multiplier"].get(h, 1.0) for h, v in w.items()}
        if group == ONLINE:
            for h, v in D["ramadan_sahur_online"].items():
                w[h] = w.get(h, 0.0) + v / 100.0     # v = persen dari volume harian
    return w


def pick_payment_method(rnd):
    methods = CFG["payments"]["offline_methods"]
    return rnd.choices(list(methods), weights=list(methods.values()))[0]


def gen_new_customers(day):
    rnd = rnd_for("customers", day)
    n = poisson_small(rnd, D["new_customers_per_day"])
    rows, ids = [], []
    for k in range(n):
        cid = f"C{day:%Y%m%d}{k:03d}"
        first, last = rnd.choice(FIRST_NAMES), rnd.choice(LAST_NAMES)
        registered = local_dt(day, rnd.randint(7, 21), rnd.randint(0, 59), rnd.randint(0, 59))
        birth = dt.date(rnd.randint(1975, 2005), rnd.randint(1, 12), rnd.randint(1, 28))
        rows.append((cid, f"{first} {last}", f"08{day_index(day):05d}{k:03d}", f"{first.lower()}.{last.lower()}{k}{day:%d%m}@example.com",
                     birth, registered, registered, registered))
        ids.append(cid)
    return rows, ids


def generate_day(M, pool, day):
    now, late = Bundle(), Bundle()
    usage, online_completed = {}, []
    flags = day_flags(day)
    new_rows, new_ids = ([], [])
    if day >= CFG["start_date"]:
        new_rows, new_ids = gen_new_customers(day)
        now.customers.extend(new_rows)
    avail = pool.avail(day)
    cust_ids = pool.ids

    for oid, ocfg in CFG["outlets"].items():
        om = M.outlets[oid]
        if om["opened"] > day or (om["closed"] and om["closed"] < day):
            continue
        u = usage[oid] = OutletUsage(closed=flags["closed"])
        if flags["closed"]:
            continue
        cashiers = M.employees[oid].get("Cashier") or M.employee_ids(oid)
        managers = M.employees[oid].get("Outlet Manager") or M.employee_ids(oid)
        counter = 0
        orders_for_day = []
        for group in (OFFLINE, ONLINE):
            share = ocfg["offline_share"] if group == OFFLINE else 1.0 - ocfg["offline_share"]
            base = ocfg["base_orders"] * share
            if base <= 0:
                continue
            w = hour_weights(group, flags["ramadan"])
            wsum = sum(w.values())
            rain_f = D["rain_offline_factor"] if group == OFFLINE else D["rain_online_factor"]
            lam = base * flags["dow"] * (D["payday_factor"] if flags["payday"] else 1.0) * (rain_f if flags["rain"] else 1.0) * wsum
            nrng = np_for("n", day, oid, group)
            n = int(nrng.poisson(lam))
            if n == 0:
                continue
            hours = nrng.choice(list(w), size=n, p=[v / wsum for v in w.values()])
            splits = ocfg["offline_split"] if group == OFFLINE else ocfg["online_split"]
            rnd = rnd_for("orders", day, oid, group)
            for h in hours:
                minute, sec = rnd.randint(0, 59), rnd.randint(0, 59)
                channel = rnd.choices(list(splits), weights=list(splits.values()))[0]
                orders_for_day.append((local_dt(day, int(h), minute, sec), group, channel, rnd.getrandbits(48)))
        orders_for_day.sort(key=lambda o: (o[0], o[3]))

        # bobot menu (tersedia sesuai tanggal launching)
        menu_cache = {}
        for group in (OFFLINE, ONLINE):
            items = [i for i, m in M.menu.items() if m["launched"] <= day and (m["discontinued"] is None or day < m["discontinued"])]
            weights = [CFG["menu_weight"].get(i, 1) * (CFG["online_category_multiplier"].get(M.menu[i]["group"], 1.0) if group == ONLINE else 1.0)
                       for i in items]
            menu_cache[group] = (items, list(accumulate(weights)))

        for seq, (ordered_at, group, channel, salt) in enumerate(orders_for_day, start=1):
            order_id = f"{oid}-{day:%Y%m%d}-{seq:04d}"
            rnd = rnd_for("order", order_id)
            items_pop, cum = menu_cache[group]
            n_items = min(8, 1 + poisson_small(rnd, D["items_poisson_lambda"]))
            lines = []   # dict per baris
            for _ in range(n_items):
                item = rnd.choices(items_pop, cum_weights=cum)[0]
                qty = 2 if rnd.random() < D["qty2_prob"] else 1
                unit_price = M.price(item, group, day)
                mods = []
                mod_opts = CFG["menu_modifiers"].get(item)
                if mod_opts and rnd.random() < D["modifier_prob"]:
                    mods = rnd.sample(mod_opts, 2 if (len(mod_opts) > 2 and rnd.random() < 0.15) else 1)
                    if "MOD_OAT" in mods and "MOD_LARGE" in mods and len(mods) == 2:
                        mods = ["MOD_OAT"]
                disc = int(round(unit_price * 0.10)) * qty if rnd.random() < D["item_discount_prob"] else 0
                lines.append({"item": item, "qty": qty, "price": unit_price, "mods": mods, "disc": disc, "void": False})
            for ln in lines:
                if len(lines) > 1 and rnd.random() < D["void_line_prob"] and sum(1 for x in lines if not x["void"]) > 1:
                    ln["void"] = True
            cancelled = rnd.random() < D["cancel_prob"][group]
            subtotal = sum(l["qty"] * (l["price"] + sum(M.mod_price[m] for m in l["mods"])) for l in lines if not l["void"])
            item_disc = sum(l["disc"] for l in lines if not l["void"])
            base_amt = subtotal - item_disc

            promo = None
            if group == ONLINE and rnd.random() < D["online_promo_prob"]:
                if rnd.random() < CFG["promos"]["online_platform_prob"]:
                    promo = CFG["promos"]["online_platform"][channel]
                else:
                    promo = rnd.choice(CFG["promos"]["online_merchant"])
            elif group == OFFLINE and rnd.random() < D["offline_promo_prob"]:
                promo = rnd.choice(CFG["promos"]["offline"])
            order_disc = 0
            if promo:
                pinfo = M.promo(promo, day)
                if pinfo:
                    ptype, pval = pinfo
                    order_disc = int(base_amt * pval / 100) if ptype == "PERCENT" else int(min(pval, base_amt))
                else:
                    promo = None
            after = base_amt - order_disc
            service = int(round(after * ocfg["service_charge_pct"] / 100)) if channel == "DINE_IN" else 0
            tax = int(round((after + service) * 0.10))
            total = after + service + tax

            customer = None
            if group == OFFLINE and avail > 0 and rnd.random() < D["member_prob"]:
                customer = cust_ids[int(avail * rnd.random() ** 2)]
            cashier = rnd.choice(cashiers) if cashiers else None
            ext_ref = f"{ONLINE_PREFIX[channel]}-{rnd.randint(10**7, 10**8 - 1)}" if group == ONLINE else None
            guests = min(6, 1 + poisson_small(rnd, 1.0)) if channel == "DINE_IN" else None

            is_late = (not cancelled) and group == OFFLINE and rnd.random() < D["late_sync_prob"]
            status = "Cancelled" if cancelled else "Completed"
            cancelled_at = ordered_at + dt.timedelta(minutes=rnd.randint(3, 12)) if cancelled else None
            cancel_reason = rnd.choice(CANCEL_REASONS) if cancelled else None

            payments = []
            if not cancelled:
                if group == ONLINE:
                    payments.append(("Platform Settlement", total, ordered_at + dt.timedelta(minutes=2)))
                else:
                    paid_at = ordered_at + dt.timedelta(minutes=rnd.randint(1, 6))
                    m1 = pick_payment_method(rnd)
                    if rnd.random() < CFG["payments"]["split_prob"] and total >= 20000:
                        a1 = int(round(total * 0.5))
                        m2 = "Cash" if m1 != "Cash" else "QRIS"
                        payments.append((m1, a1, paid_at))
                        payments.append((m2, total - a1, paid_at + dt.timedelta(seconds=30)))
                    else:
                        payments.append((m1, total, paid_at))

            if is_late:
                sync_at = local_dt(day + dt.timedelta(days=1), rnd.randint(1, 10), rnd.randint(0, 59), rnd.randint(0, 59))
                created = updated = sync_at
                tgt = late
            else:
                created = ordered_at
                updated = max([ordered_at] + ([cancelled_at] if cancelled_at else []) + [p[2] for p in payments])
                tgt = now

            tgt.orders.append((order_id, oid, channel, customer, cashier, promo, ext_ref, ordered_at, status, cancelled_at,
                               cancel_reason, guests, subtotal, item_disc, order_disc, service, tax, total, created, updated))
            order_item_refs = []
            for ln in lines:
                counter += 1
                oiid = day_index(day) * 10_000_000 + ocfg["index"] * 1_000_000 + counter
                tgt.items.append((oiid, order_id, ln["item"], ln["qty"], ln["price"], ln["disc"],
                                  "Void" if ln["void"] else "Served", "Salah input kasir" if ln["void"] else None,
                                  created, updated))
                for m in ln["mods"]:
                    tgt.mods.append((oiid, m, M.mod_price[m], created, updated))
                if not ln["void"]:
                    line_mods_total = sum(M.mod_price[m] for m in ln["mods"])
                    line_gross = ln["qty"] * (ln["price"] + line_mods_total)
                    line_net = max(0, line_gross - ln["disc"])
                    order_disc_share = int(round(line_net * order_disc / base_amt)) if base_amt > 0 else 0
                    net_item_paid = max(0, line_net - order_disc_share)
                    order_item_refs.append((oiid, net_item_paid))
                    if not cancelled:
                        u.sales[ln["item"]] += ln["qty"]
                        for m in ln["mods"]:
                            u.mods[m] += ln["qty"]
                        # produk jatuh / QC reject (tercatat sebagai waste produk jadi)
                        if rnd.random() < INV["waste_item_prob"]:
                            u.waste_events.append((ln["item"], 1, "DROPPED" if rnd.random() < 0.6 else "QC_REJECT"))
            for pi, (method, amount, paid_at) in enumerate(payments, start=1):
                mdr = round(amount * CFG["payments"]["mdr_pct"][method] / 100.0, 2)
                tgt.payments.append((f"{order_id}-P{pi}", order_id, method, amount, mdr, paid_at,
                                     created if is_late else paid_at, updated))
            if group == ONLINE and not cancelled:
                online_completed.append((order_id, oid, total, order_item_refs, managers[0] if managers else None))
    return Gen(day, now, late, online_completed, usage, new_ids)


def refunds_for(day, prev_gen):
    """Refund H+1 untuk order online kemarin (CUST_RETURN), tercatat di tanggal refund, bukan tanggal order."""
    rows = []
    for order_id, oid, total, item_refs, manager in prev_gen.online_completed:
        rnd = rnd_for("refund", order_id)
        if rnd.random() >= D["refund_prob_online"]:
            continue
        refunded_at = local_dt(day, rnd.randint(9, 20), rnd.randint(0, 59), rnd.randint(0, 59))
        if item_refs and rnd.random() < D["refund_item_level_prob"]:
            oiid, amount = rnd.choice(item_refs)
        else:
            oiid, amount = None, total
        rows.append((f"{order_id}-R1", order_id, oiid, min(amount, total), "CUST_RETURN", manager, refunded_at,
                     refunded_at, refunded_at))
    return rows


def opex_rows(M, day):
    month = day.replace(day=1)
    created = local_dt(day, 22, 0)
    rows = []
    noise = CFG["opex_noise_pct"]
    def mk(oid, tag, cat, base):
        rnd = rnd_for("opex", month, tag, cat)
        amount = int(round(base * (1 + rnd.uniform(-noise, noise) / 100.0), -3))
        rows.append((f"EXP-{month:%Y%m}-{tag}-{cat}", oid, month, cat, amount, f"{cat} {month:%Y-%m}", created, created))
    for oid, ocfg in CFG["outlets"].items():
        om = M.outlets[oid]
        if om["opened"] <= day:
            for cat, base in ocfg["opex"].items():
                mk(oid, oid, cat, base)
    for cat, base in CFG["hq_opex"].items():
        mk(None, "HQ", cat, base)
    return rows


# ----------------------------------------------------------------------------- inventori
class Inventory:
    """State stok per outlet & bahan (lot FIFO). Disimpan di schema sim agar daily run bisa melanjutkan."""
    def __init__(self):
        self.lots = defaultdict(list)     # (outlet, ing) -> [[received_date, qty], ...]
        self.ema = {}                     # (outlet, ing) -> rata-rata pemakaian harian (base uom)
        self.as_of = None

    # -- persistence
    @classmethod
    def load(cls, conn):
        inv = cls()
        row = conn.execute("select as_of_date from sim.state").fetchone()
        inv.as_of = row[0] if row else None
        for o, i, d, q in conn.execute("select outlet_id, ingredient_id, received_date, qty from sim.inventory_lots order by received_date"):
            inv.lots[(o, i)].append([d, float(q)])
        for o, i, e in conn.execute("select outlet_id, ingredient_id, ema from sim.inventory_ema"):
            inv.ema[(o, i)] = float(e)
        return inv

    def save(self, conn, as_of):
        self.as_of = as_of
        conn.execute("truncate sim.inventory_lots, sim.inventory_ema, sim.state")
        with conn.cursor() as cur:
            with cur.copy("copy sim.inventory_lots (outlet_id, ingredient_id, received_date, qty) from stdin") as cp:
                for (o, i), lots in self.lots.items():
                    for d, q in lots:
                        if q > 1e-9:
                            cp.write_row((o, i, d, round(q, 4)))
            with cur.copy("copy sim.inventory_ema (outlet_id, ingredient_id, ema) from stdin") as cp:
                for (o, i), e in self.ema.items():
                    cp.write_row((o, i, round(e, 4)))
        conn.execute("insert into sim.state (as_of_date) values (%s)", (as_of,))

    # -- operasi stok
    def on_hand(self, o, ing):
        return sum(q for _, q in self.lots[(o, ing)])

    def add_lot(self, o, ing, day, qty):
        lots = self.lots[(o, ing)]
        if lots and lots[-1][0] == day:
            lots[-1][1] += qty
        else:
            lots.append([day, qty])

    def consume(self, o, ing, qty):
        lots, remaining = self.lots[(o, ing)], qty
        while remaining > 1e-9 and lots:
            if lots[0][1] <= remaining + 1e-9:
                remaining -= lots[0][1]
                lots.pop(0)
            else:
                lots[0][1] -= remaining
                remaining = 0.0
        return remaining

    def init_outlet(self, M, o, ocfg, day):
        """Estimasi pemakaian harian awal dari bobot menu (dipakai untuk par level hari pertama)."""
        items = [i for i, m in M.menu.items() if m["launched"] <= day]
        tw = sum(CFG["menu_weight"].get(i, 1) for i in items)
        use = Counter()
        for i in items:
            share = CFG["menu_weight"].get(i, 1) / tw
            rec = M.recipe(i, day)
            if rec:
                for ing, g in rec[1]:
                    M.explode_to_raw(ing, share * g, day, use)
        per_order = (1 + D["items_poisson_lambda"]) * (1 + D["qty2_prob"])
        for ing in M.ingredients:
            self.ema[(o, ing)] = use.get(ing, 0.0) * per_order * ocfg["base_orders"]
            self.lots[(o, ing)] = []

    def step(self, M, day, o, ocfg, usage, rnd, closed, first):
        out = Bundle()
        emp = M.employee_ids(o)
        managers = M.employees[o].get("Outlet Manager") or emp
        if first:
            self.init_outlet(M, o, ocfg, day)
        purchasing = INV["purchasing"]
        receipts = defaultdict(list)       # supplier -> [(ing, purchase_units, uom, qty_base)]

        def receive(ing, units):
            sup, uom, per = purchasing[ing]
            qty_base = units * per
            self.add_lot(o, ing, day, qty_base)
            receipts[sup].append((ing, units, uom, qty_base))

        if not closed:
            for ing, (sup, uom, per) in purchasing.items():
                shelf = M.ingredients[ing]["shelf"]
                daily = shelf is not None and shelf <= INV["daily_delivery_shelf_life_max"]
                if first or daily or day.weekday() in INV["receipt_weekdays"]:
                    ema = self.ema.get((o, ing), 0.0)          # bahan baru (migration) belum punya EMA
                    par = ema * 1.3 if daily else ema * INV["par_days"] * INV["par_safety"]
                    need = par - self.on_hand(o, ing)
                    if need > 1e-9:
                        receive(ing, math.ceil(need / per))

        # kebutuhan teoritis -> kebutuhan fisik
        def explode(sales, mods, day_):
            use = Counter()
            for item, qty in sales.items():
                rec = M.recipe(item, day_)
                if rec:
                    for ing, g in rec[1]:
                        use[ing] += g * qty
            for mod, qty in mods.items():
                for ing, d in M.mod_lines[mod]:
                    use[ing] += d * qty
            return use

        sales_use = explode(usage.sales, usage.mods, day)
        waste_counter = Counter()
        for item, qty, _ in usage.waste_events:
            waste_counter[item] += qty
        waste_use = explode(waste_counter, {}, day)
        overpour = ocfg.get("overpour", {})
        physical = Counter()
        for ing, q in sales_use.items():
            physical[ing] += q * (1 + overpour.get(ing, 0.0))
        for ing, q in waste_use.items():
            physical[ing] += q
        raw_consumed = Counter()

        def take(ing, qty):
            short = self.consume(o, ing, qty)
            if short > 1e-9 and ing in purchasing:          # pembelian darurat
                per = purchasing[ing][2]
                receive(ing, math.ceil(short / per))
                short = self.consume(o, ing, short)
            if not M.ingredients[ing]["is_prep"]:
                raw_consumed[ing] += qty

        # batch prep: produksi sebelum jam buka sesuai kebutuhan hari itu.
        # Urut induk -> anak: kebutuhan sub-prep dari batch induk ditambahkan ke `physical` sebelum giliran sub-prep.
        for ing in M.prep_production_order(day):
            need = physical.get(ing, 0.0) - self.on_hand(o, ing)
            if need > 1e-9:
                yq, lines = M.recipe(ing, day)
                batches = math.ceil(need / yq)
                for sub, g in lines:
                    if M.ingredients[sub]["is_prep"]:
                        physical[sub] += g * yq * batches
                    else:
                        take(sub, g * yq * batches)
                self.add_lot(o, ing, day, yq * batches)
        for ing, q in physical.items():
            take(ing, q)

        # waste produk jadi
        n_waste = 0
        waste_notes = {"DROPPED": "Jatuh / tumpah", "QC_REJECT": "Tidak lolos QC"}
        for item, qty, reason in usage.waste_events:
            n_waste += 1
            at = local_dt(day, rnd.randint(8, 20), rnd.randint(0, 59), rnd.randint(0, 59))
            out.waste.append((f"W-{o}-{day:%Y%m%d}-{n_waste:03d}", o, at, None, item, qty, reason, rnd.choice(emp),
                              waste_notes[reason], at, at))
        end = local_dt(day, 21, 30)

        def log_waste(ing, qty, reason, note):
            nonlocal n_waste
            if round(qty, 3) <= 0:
                return
            n_waste += 1
            out.waste.append((f"W-{o}-{day:%Y%m%d}-{n_waste:03d}", o, end, ing, None, round(qty, 3), reason,
                              rnd.choice(emp), note, end, end))

        # prep rusak di akhir hari
        for ing in [i for i, m in M.ingredients.items() if m["is_prep"]]:
            left = self.on_hand(o, ing)
            if left > 1.0 and rnd.random() < INV["prep_spoil_prob"]:
                qty = left * INV["prep_spoil_fraction"]
                self.consume(o, ing, qty)
                log_waste(ing, qty, "PREP_SPOIL", "Prep tidak habis, dibuang")
        # kedaluwarsa (FIFO kasar): lot yang umurnya >= shelf life
        for ing, meta in M.ingredients.items():
            if meta["shelf"] is None:
                continue
            lots = self.lots[(o, ing)]
            keep, expired = [], 0.0
            for d, q in lots:
                if (day - d).days >= meta["shelf"]:
                    expired += q
                else:
                    keep.append([d, q])
            if expired > 1e-9:
                self.lots[(o, ing)] = keep
                log_waste(ing, expired, "EXPIRED", "Melewati shelf life")

        # expired tambahan bakery di musim hujan (Nov - Feb)
        if day.month in (11, 12, 1, 2):
            bakery_prob = INV.get("bakery_rainy_expired_prob", 0.12)
            for b_ing in ("ING_BREAD", "ING_CROIS"):
                if b_ing in M.ingredients and rnd.random() < bakery_prob:
                    lots = self.lots[(o, b_ing)]
                    if lots and lots[0][1] > 0.5:
                        exp_qty = round(lots[0][1] * 0.4, 3)
                        lots[0][1] -= exp_qty
                        log_waste(b_ing, exp_qty, "EXPIRED", "Roti/pastry kedaluwarsa musim hujan")

        # pemakaian rata-rata (EMA)
        if not closed:
            for ing in M.ingredients:
                if not M.ingredients[ing]["is_prep"]:
                    self.ema[(o, ing)] = 0.9 * self.ema.get((o, ing), 0.0) + 0.1 * raw_consumed.get(ing, 0.0)

        # goods receipts
        n_line = 0
        for sup, lines in receipts.items():
            gr_id = f"GR-{o}-{day:%Y%m%d}-{sup}"
            at = local_dt(day, rnd.randint(6, 8), rnd.randint(0, 59))
            out.gr.append((gr_id, o, sup, f"INV/{sup}/{day:%Y%m%d}/{ocfg['short']}", at, at, at))
            for ing, units, uom, qty_base in lines:
                n_line += 1
                noise = max(0.5, rnd.gauss(1.0, INV["price_noise_sd"]))
                amount = round(qty_base * M.cost(ing, day) * noise, 2)
                shelf = M.ingredients[ing]["shelf"]
                out.grl.append((day_index(day) * 10_000_000 + ocfg["index"] * 1_000_000 + n_line, gr_id, ing, units, uom,
                                qty_base, amount, day + dt.timedelta(days=shelf) if shelf else None, at, at))

        # stock count (tutup toko): hari pertama (Opening), Minggu malam, dan akhir bulan
        count_type = "Opening" if first else ("Month End" if is_month_end(day) else ("Weekly" if day.weekday() == 6 else None))
        if count_type:
            cid = f"SC-{o}-{day:%Y%m%d}"
            at = local_dt(day, 22, 30)
            out.sc.append((cid, o, day, count_type, managers[0], at, at))
            for ing in M.ingredients:
                counted = self.on_hand(o, ing) * (1 + (0.0 if first else rnd.gauss(0.0, INV["count_noise_sd"])))
                out.scl.append((cid, ing, round(max(counted, 0.0), 3), at, at))
        return out


# ----------------------------------------------------------------------------- penulisan ke DB
def flush(conn, bundle):
    counts = {}
    for table, cols, override in TABLE_ORDER:
        rows = getattr(bundle, KEY_OF[table])
        if not rows:
            continue
        col_list = ", ".join(cols)
        with conn.cursor() as cur:
            cur.execute(f"create temp table _stage (like fnb.{table}) on commit drop")
            with cur.copy(f"copy _stage ({col_list}) from stdin") as cp:
                for r in rows:
                    cp.write_row(r)
            ov = "overriding system value " if override else ""
            cur.execute(f"insert into fnb.{table} ({col_list}) {ov}select {col_list} from _stage on conflict do nothing")
            counts[table] = (len(rows), cur.rowcount)
            cur.execute("drop table _stage")
    return counts


def run_days(conn, M, start, end, batch_days, fresh):
    pool = Pool.load(conn, before=start)
    inv = Inventory.load(conn)
    prev = generate_day(M, pool, start - dt.timedelta(days=1))     # regen deterministik: late sync & refund
    bundle, batch_start, t0 = Bundle(), start, time.time()
    totals = Counter()
    open_before = set(o for (o, _) in inv.ema)

    def commit(last_day):
        with conn.transaction():
            counts = flush(conn, bundle)
            inv.save(conn, last_day)
        for t, (sent, inserted) in counts.items():
            totals[t] += inserted
        print(f"  {batch_start} .. {last_day}: " + ", ".join(f"{t}={ins}" for t, (_, ins) in counts.items() if t in ("orders", "order_items", "waste_logs")) +
              f"  ({time.time() - t0:.0f}s)", flush=True)

    for day in daterange(start, end):
        gen = generate_day(M, pool, day)
        bundle.extend(gen.now)
        bundle.extend(prev.late)
        bundle.refunds.extend(refunds_for(day, prev))
        rnd = rnd_for("inventory", day)
        for oid, usage in gen.usage.items():
            out = inv.step(M, day, oid, CFG["outlets"][oid], usage, rnd_for("inventory", day, oid), usage.closed, oid not in open_before)
            open_before.add(oid)
            bundle.extend(out)
        if is_month_end(day):
            bundle.opex.extend(opex_rows(M, day))
        pool.add(day, gen.new_customers)
        prev = gen
        if (day - batch_start).days + 1 >= batch_days or day == end:
            commit(day)
            bundle, batch_start = Bundle(), day + dt.timedelta(days=1)
    print("Selesai. Baris baru:", dict(totals))


# ----------------------------------------------------------------------------- perintah
def exec_sql_file(conn, path):
    conn.execute(Path(path).read_text(encoding="utf-8"))


def cmd_apply_schema(args):
    with connect() as conn:
        conn.autocommit = True
        exists = conn.execute("select count(*) from information_schema.tables where table_schema = 'fnb'").fetchone()[0]
        if exists and not args.drop:
            sys.exit("Schema fnb sudah berisi tabel. Pakai --drop untuk membuat ulang (MENGHAPUS SEMUA DATA).")
        if args.drop:
            conn.execute("drop schema if exists fnb cascade")
            conn.execute("drop schema if exists sim cascade")
        exec_sql_file(conn, SCHEMA_DIR / "001_schema.sql")
        exec_sql_file(conn, SCHEMA_DIR / "003_sim_state.sql")
        n = conn.execute("select count(*) from information_schema.tables where table_schema = 'fnb'").fetchone()[0]
        print(f"OK: {n} tabel di schema fnb")


def cmd_init_master(args):
    with connect() as conn:
        exec_sql_file(conn, SCHEMA_DIR / "002_seed_master.sql")
        exec_sql_file(conn, SCHEMA_DIR / "004_multilevel_bom.sql")
        exec_sql_file(conn, SCHEMA_DIR / "005_hr.sql")
        rows = []
        for oid, ocfg in CFG["outlets"].items():
            n = 0
            for role, count in ocfg["staff"].items():
                for _ in range(count):
                    n += 1
                    rnd = rnd_for("employee", oid, n)
                    rows.append((f"E{ocfg['short']}{n:03d}", oid, f"{rnd.choice(FIRST_NAMES)} {rnd.choice(LAST_NAMES)}",
                                 f"0899{ocfg['index']}{n:05d}", role, dt.date(2025, 5, 15)))
        with conn.cursor() as cur:
            cur.executemany("insert into fnb.employees (employee_id, outlet_id, full_name, phone_number, job_role, hired_date) "
                            "values (%s, %s, %s, %s, %s, %s) on conflict do nothing", rows)
        conn.commit()
        print("OK: master di-seed,", len(rows), "karyawan sintetis")


def run_hr_sync(conn, end):
    import hr
    sim = hr.HRSim(CFG, rnd_for, local_dt, day_flags, FIRST_NAMES, LAST_NAMES)
    t0 = time.time()
    summary = hr.sync(conn, sim, end)
    print(f"HR sync s.d. {end} ({time.time() - t0:.0f}s): " +
          ", ".join(f"{t}=+{i}/~{u}" for t, (i, u) in summary.items()))


def cmd_hr_sync(args):
    with connect() as conn:
        run_hr_sync(conn, args.end)


def cmd_backfill(args):
    with connect() as conn:
        M = Master(conn)
        inv = Inventory.load(conn)
        if inv.as_of is not None:
            sys.exit(f"State inventori sudah ada (as_of {inv.as_of}). Gunakan `daily`, atau `reset --yes` lalu backfill ulang.")
        for oid in CFG["outlets"]:
            if not M.employee_ids(oid):
                sys.exit("Karyawan belum ada. Jalankan init-master dulu.")
        start, end = args.start or CFG["start_date"], args.end or CFG["default_end_date"]
        print(f"Backfill {start} .. {end}")
        run_days(conn, M, start, end, args.batch_days, fresh=True)


def cmd_daily(args):
    with connect() as conn:
        M = Master(conn)
        inv = Inventory.load(conn)
        if inv.as_of is None:
            sys.exit("Belum ada state. Jalankan backfill dulu.")
        if args.date <= inv.as_of:
            print(f"Tanggal {args.date} sudah diproses (as_of {inv.as_of}); tidak ada yang dilakukan.")
            return
        start = inv.as_of + dt.timedelta(days=1)
        print(f"Daily {start} .. {args.date}")
        run_days(conn, M, start, args.date, batch_days=7, fresh=False)
        run_hr_sync(conn, args.date)


def cmd_stats(args):
    with connect() as conn:
        tables = [r[0] for r in conn.execute("select table_name from information_schema.tables where table_schema='fnb' order by 1")]
        for t in tables:
            print(f"{t:28s} {conn.execute(f'select count(*) from fnb.{t}').fetchone()[0]:>10,}")
        size = conn.execute("select pg_size_pretty(pg_database_size(current_database())), pg_database_size(current_database())").fetchone()
        print(f"\nUkuran database: {size[0]} ({size[1] / 1024 / 1024:.0f} MB dari batas free tier 512 MB)")
        row = conn.execute("select as_of_date from sim.state").fetchone()
        print("State generator as_of:", row[0] if row else None)


def cmd_storage_check(args):
    """Peringatan dini kapasitas Neon free tier. Tidak pernah menggagalkan pipeline (exit 0)."""
    with connect() as conn:
        size = conn.execute("select pg_database_size(current_database())").fetchone()[0]
    used_mb, pct = size / 1024 / 1024, size / (args.limit_mb * 1024 * 1024) * 100
    msg = f"Neon storage {used_mb:.0f} MB dari {args.limit_mb} MB ({pct:.0f}%)"
    print(msg)
    if pct >= args.warn_pct:
        hint = ("jalankan retensi: python oltp/generator/generate.py purge --older-than-months 12 --yes "
                "(data historis di BigQuery tidak ikut terhapus)")
        print(f"::warning title=Neon storage >= {args.warn_pct}%::{msg} - {hint}")
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as f:
                f.write(f"### Neon storage {pct:.0f}% (ambang {args.warn_pct}%)\n\n{msg}.\n\nTindakan: {hint}.\n")


def cmd_reset(args):
    if not args.yes:
        sys.exit("Tambahkan --yes untuk mengosongkan data transaksi.")
    with connect() as conn:
        conn.execute("truncate fnb.refunds, fnb.payments, fnb.order_item_modifiers, fnb.order_items, fnb.orders, "
                     "fnb.stock_count_lines, fnb.stock_counts, fnb.goods_receipt_lines, fnb.goods_receipts, "
                     "fnb.waste_logs, fnb.operating_expenses, fnb.customers restart identity cascade")
        conn.execute("truncate sim.inventory_lots, sim.inventory_ema, sim.state")
        conn.commit()
        print("OK: data transaksi dan state generator dikosongkan (master dipertahankan)")


def cmd_purge(args):
    if not args.yes:
        sys.exit("Tambahkan --yes untuk menjalankan purge retensi.")
    cutoff = dt.date.today() - dt.timedelta(days=args.older_than_months * 30)
    print(f"Purging transaksi sebelum {cutoff}...")
    with connect() as conn:
        with conn.transaction():
            # 1. Hapus modifier item order
            conn.execute(
                """delete from fnb.order_item_modifiers
                   where order_item_id in (
                       select oi.order_item_id from fnb.order_items oi
                       join fnb.orders o on oi.order_id = o.order_id
                       where (o.ordered_at at time zone 'Asia/Jakarta')::date < %s
                   )""",
                (cutoff,),
            )
            # 2. Hapus refunds
            conn.execute(
                """delete from fnb.refunds
                   where order_id in (
                       select order_id from fnb.orders
                       where (ordered_at at time zone 'Asia/Jakarta')::date < %s
                   ) or (refunded_at at time zone 'Asia/Jakarta')::date < %s""",
                (cutoff, cutoff),
            )
            # 3. Hapus payments
            conn.execute(
                """delete from fnb.payments
                   where order_id in (
                       select order_id from fnb.orders
                       where (ordered_at at time zone 'Asia/Jakarta')::date < %s
                   )""",
                (cutoff,),
            )
            # 4. Hapus order_items
            conn.execute(
                """delete from fnb.order_items
                   where order_id in (
                       select order_id from fnb.orders
                       where (ordered_at at time zone 'Asia/Jakarta')::date < %s
                   )""",
                (cutoff,),
            )
            # 5. Hapus orders
            conn.execute(
                "delete from fnb.orders where (ordered_at at time zone 'Asia/Jakarta')::date < %s",
                (cutoff,),
            )
            # 6. Hapus goods receipt lines & receipts
            conn.execute(
                """delete from fnb.goods_receipt_lines
                   where gr_id in (
                       select gr_id from fnb.goods_receipts
                       where (received_at at time zone 'Asia/Jakarta')::date < %s
                   )""",
                (cutoff,),
            )
            conn.execute(
                "delete from fnb.goods_receipts where (received_at at time zone 'Asia/Jakarta')::date < %s",
                (cutoff,),
            )
            # 7. Hapus stock count lines & counts
            conn.execute(
                """delete from fnb.stock_count_lines
                   where count_id in (
                       select count_id from fnb.stock_counts
                       where count_date < %s
                   )""",
                (cutoff,),
            )
            conn.execute("delete from fnb.stock_counts where count_date < %s", (cutoff,))
            # 8. Hapus waste logs
            conn.execute(
                "delete from fnb.waste_logs where (logged_at at time zone 'Asia/Jakarta')::date < %s",
                (cutoff,),
            )
            # 9. Hapus operating expenses
            conn.execute(
                "delete from fnb.operating_expenses where period_month < %s",
                (cutoff.replace(day=1),),
            )
        print("OK: Purge selesai.")


def date_arg(s):
    return dt.date.fromisoformat(s)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("apply-schema"); p.add_argument("--drop", action="store_true"); p.set_defaults(fn=cmd_apply_schema)
    p = sub.add_parser("init-master"); p.set_defaults(fn=cmd_init_master)
    p = sub.add_parser("backfill"); p.add_argument("--start", type=date_arg); p.add_argument("--end", type=date_arg)
    p.add_argument("--batch-days", type=int, default=14); p.set_defaults(fn=cmd_backfill)
    p = sub.add_parser("daily"); p.add_argument("--date", type=date_arg, required=True); p.set_defaults(fn=cmd_daily)
    p = sub.add_parser("hr-sync", help="Bangun ulang data HR deterministik s.d. tanggal lalu upsert (idempoten)")
    p.add_argument("--end", type=date_arg, required=True); p.set_defaults(fn=cmd_hr_sync)
    p = sub.add_parser("stats"); p.set_defaults(fn=cmd_stats)
    p = sub.add_parser("storage-check", help="Peringatan bila storage Neon melewati ambang (default 85%% dari 512 MB)")
    p.add_argument("--limit-mb", type=int, default=512); p.add_argument("--warn-pct", type=int, default=85)
    p.set_defaults(fn=cmd_storage_check)
    p = sub.add_parser("purge", help="Hapus transaksi historis lama untuk menjaga batas kapasitas Neon")
    p.add_argument("--older-than-months", type=int, default=12)
    p.add_argument("--yes", action="store_true")
    p.set_defaults(fn=cmd_purge)
    p = sub.add_parser("reset"); p.add_argument("--yes", action="store_true"); p.set_defaults(fn=cmd_reset)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
