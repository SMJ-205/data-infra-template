# F&B Data Platform v2: Audit & Implementation Plan (Free-Tier)

**Stack:** PostgreSQL (Neon) → BigQuery → dbt Core → Google Sheets/Apps Script (alert & laporan) + Dashboard Vercel (statis, JSON dari mart)
**Tambahan (semua gratis/OSS):** dlt (ingestion), GitHub Actions (orkestrasi, CI, export dashboard), GitHub Pages (dbt docs), Vercel Hobby (dashboard)
**Referensi tambahan:** `dbt_data_infrastructure_common.md` (blueprint generik, diadaptasi dari Snowflake ke BigQuery)

> Catatan: kuota free tier vendor (Neon, BigQuery, Vercel, GitHub) bisa berubah. Angka di dokumen ini adalah acuan perencanaan. Cek ulang halaman pricing tiap vendor sebelum deploy.

> **Perubahan v2.1** (keputusan setelah review):
> 1. **BigQuery + billing GCP tetap dipakai**, dengan hard quota **20 GB/hari** (maksimal 620 GB/bulan, di bawah 1 TB gratis), `maximum_bytes_billed` per query, dan budget alert (§6.4).
> 2. **Metabase dihapus**, termasuk Cloud Run, app DB Neon kedua, Secret Manager, dan key `sa-metabase`. Diganti **dashboard statis di Vercel** (HTML/CSS/JS + Chart.js) yang membaca JSON hasil export mart (§10). Polanya sama dengan proyek portofolio Tokopedia pricing sebelumnya.
> 3. Repo **publik** (portofolio): menit GitHub Actions tanpa batas, Pages gratis, dan semua data yang dipublikasikan harus agregat serta bebas PII.
> 4. Akibatnya tidak ada lagi JSON key di arsitektur: semua akses BigQuery dari GitHub Actions memakai WIF.

---

## Daftar Isi

0. Ringkasan eksekutif
1. Hasil audit plan v1
2. Arsitektur target v2 & strategi free tier
3. Source DB (PostgreSQL OLTP) v2
4. Data generator (simulasi POS)
5. Ingestion: Postgres → BigQuery (dlt)
6. Setup BigQuery: dataset, IAM, guardrail biaya
7. dbt project v2
8. Orkestrasi & CI/CD (GitHub Actions)
9. Route 1: Google Sheets + Apps Script (sync, alert, web dashboard)
10. Route 2: Dashboard Vercel (static, portofolio)
11. Observability & dokumentasi
12. Adopsi dari blueprint common
13. Roadmap implementasi & checklist

---

## 0. Ringkasan eksekutif

Plan v1 punya arah yang benar (medallion BigQuery, BOM explosion, P&L, dua jalur konsumsi), tetapi **belum bisa dijalankan apa adanya** dan **akan menghasilkan angka P&L yang salah** di beberapa kondisi. Lima masalah terbesar:

1. **BigQuery Sandbox tidak mendukung DML** (MERGE/INSERT/UPDATE/DELETE) dan tabel kedaluwarsa dalam 60 hari. Akibatnya ingestion incremental, dbt incremental, dan snapshot tidak bisa jalan. Solusinya: aktifkan billing tetapi tetap di dalam free tier (10 GB storage, 1 TB query/bulan), dengan quota keras dan budget alert.
2. **"BigQuery Federation" ke Neon/Supabase tidak tersedia.** Federated query hanya untuk Cloud SQL/AlloyDB/Spanner. Penggantinya dlt (OSS) yang dijalankan di GitHub Actions.
3. **Source DB belum cukup untuk analitik F&B yang dijanjikan.** Belum ada riwayat harga atau versi resep, sehingga HPP historis ikut berubah setiap kali harga bahan berubah. Belum ada pembelian dan stock opname, sehingga "actual COGS" tidak bisa dihitung. Belum ada outlet, komisi ojol, payment, refund parsial, maupun `updated_at` untuk incremental.
4. **Bug logika P&L:** kalender hanya berisi hari yang ada transaksinya, sehingga opex di hari tanpa transaksi hilang. Menu tanpa BOM menghasilkan COGS NULL yang kemudian terbaca 0, sehingga margin terlihat lebih tinggi. Test `not_null` pada rasio juga akan gagal di hari tanpa penjualan.
5. **Hosting Metabase di Render/Koyeb free (512 MB) tidak layak** karena JVM Metabase butuh ±1,5–2 GB. Pada v2.1 Metabase dihapus seluruhnya dan diganti dashboard statis Vercel yang membaca JSON hasil export mart (§10).

Plan v2 di bawah ini memperbaiki semua temuan, memperluas source DB menjadi 29 tabel (multi-outlet, resep berversi, sub-resep, modifier, pembelian, stock opname, kanal online, payment, refund, opex dan alokasi HQ), dan mengadopsi praktik blueprint common yang relevan untuk BigQuery.

---

## 1. Hasil audit plan v1

Tingkat severity: **KRITIS** (pipeline gagal atau angka salah), **TINGGI** (fitur yang dijanjikan tidak tercapai atau ada risiko keamanan), **SEDANG** (kualitas dan maintainability), **RENDAH** (kosmetik).

### 1.1 Arsitektur & free tier

| # | Sev | Temuan | Dampak | Perbaikan v2 |
|---|---|---|---|---|
| A1 | KRITIS | BigQuery **Sandbox**: tidak ada DML, tidak ada streaming, default table expiration 60 hari | `merge` ingestion, dbt `incremental`, dan `snapshot` gagal. Raw hilang setelah 60 hari | Aktifkan billing account (free tier tetap berlaku) + custom quota query/hari + budget alert (§6.4) |
| A2 | KRITIS | Opsi "BigQuery Federation" ke Neon/Supabase | Tidak didukung (EXTERNAL_QUERY hanya untuk Cloud SQL/AlloyDB/Spanner) | dlt `sql_database` → BigQuery via load job (gratis) di GitHub Actions (§5) |
| A3 | TINGGI | Metabase di Render/Koyeb free (512 MB RAM, sleep 15 menit) | Heap JVM kurang sehingga OOM/restart loop, cold start sangat lama | Tidak berlaku lagi sejak v2.1: Metabase dihapus, diganti dashboard Vercel statis (§10) |
| A4 | SEDANG | Image `metabase/metabase:latest` | Upgrade tak terduga menjalankan migrasi app DB yang tidak bisa di-rollback | Tidak berlaku lagi sejak v2.1 (Metabase dihapus) |
| A5 | TINGGI | Kredensial: contoh password plaintext, SA JSON key untuk semua komponen, role SA level project | Kebocoran key, Metabase bisa membaca raw (PII) | Workload Identity Federation (keyless) untuk GitHub Actions, SA per workload, grant per dataset (§6.3) |
| A6 | SEDANG | Tidak ada guardrail biaya | Query salah bisa melewati 1 TB/bulan | `maximum_bytes_billed` di profile dbt & Apps Script, custom quota, budget alert |
| A7 | SEDANG | "dbt via GitHub Actions" disebut tetapi tidak ada workflow, urutan job, maupun retry | Tidak ada jadwal yang andal | Workflow `daily_pipeline.yml` & `pr_ci.yml` (§8) |
| A8 | TINGGI | `+schema: marts` di dbt menghasilkan dataset `<target_schema>_marts`, padahal Apps Script membaca dataset `marts` | Apps Script gagal: dataset tidak ditemukan | Override `generate_schema_name` (prod = nama persis, dev = berprefix) |
| A9 | SEDANG | Lokasi dataset tidak ditentukan; Apps Script tidak mengirim `location` | Error lintas lokasi / job tidak ditemukan | Semua dataset di `asia-southeast2`, `location` eksplisit di setiap client |
| A10 | SEDANG | Tidak ada pemisahan dev/ci/prod | Developer menimpa tabel prod | Target `dev` (dataset per user), `ci` (per PR), `prod` |

### 1.2 Source DB (PostgreSQL)

| # | Sev | Temuan | Dampak | Perbaikan v2 |
|---|---|---|---|---|
| S1 | KRITIS | `standard_unit_cost` di-overwrite, resep tanpa versi | HPP historis ikut berubah saat harga bahan naik. Analisis inflasi bahan atau perubahan resep tidak mungkin dilakukan | `ingredient_standard_costs` & `recipes` effective-dated + exclusion constraint anti-overlap |
| S2 | KRITIS | Tidak ada pembelian & stock opname | "Actual COGS" dan theoretical vs actual usage (KPI inti F&B) tidak bisa dihitung | `goods_receipts(_lines)`, `stock_counts(_lines)` |
| S3 | TINGGI | Tidak ada `outlets` | Tidak ada perbandingan antar outlet dan alokasi opex | `outlets` + FK `outlet_id` di semua transaksi |
| S4 | TINGGI | Tidak ada `updated_at` / soft delete | Incremental ingestion tidak mungkin, delete tidak terlihat | `created_at`/`updated_at` (trigger) di semua tabel, `deleted_at` di master |
| S5 | TINGGI | Ekonomi kanal online hilang: komisi platform (20–30%), promo yang didanai platform vs merchant, PB1 & service charge tidak dipisah | Revenue online overstated, margin kanal salah | `sales_channels`, `channel_commission_rates`, `promotions.funded_by`, kolom pajak/service di `orders` |
| S6 | SEDANG | Tanpa modifier, konversi UOM, yield/loss, dan sub-resep (prep) | HPP under-estimated (extra shot, oat milk, sirup batch) | `modifiers`, `modifier_lines`, `recipe_lines.loss_pct`, prep item, `goods_receipt_lines.qty_base_uom` |
| S7 | SEDANG | Waste hanya untuk bahan; `recorded_by` berupa teks bebas | Waste produk jadi/prep tidak tercatat; nama staf (PII) mengalir ke mart | `waste_logs` mendukung menu/prep/bahan, FK `employees`, `waste_reasons` |
| S8 | SEDANG | Refund berupa status order | Hanya refund penuh, dan tercatat di tanggal order (bukan tanggal refund) | Tabel `refunds` (parsial, ada `refunded_at`) |
| S9 | SEDANG | Tidak ada `payments` | Split payment & MDR (QRIS/kartu) tidak terlihat | Tabel `payments` + `mdr_fee_amount` |
| S10 | SEDANG | `TIMESTAMP` tanpa zona waktu | Order 00:00–06:59 WIB bisa jatuh ke tanggal sebelumnya di BigQuery (UTC) | `TIMESTAMPTZ`, konversi ke WIB di staging |
| S11 | SEDANG | Tanpa CHECK/enum, tanpa index | Data kotor masuk, ekstraksi incremental lambat | CHECK constraint, index `updated_at`/`ordered_at` |
| S12 | SEDANG | Seed hanya 2 menu, tidak ada generator | Menu engineering, seasonality, dan variance tidak bisa didemokan | Generator deterministik + "story events" (§4) |
| S13 | RENDAH | Komentar `fnb_pos_inventory` ≠ schema `fnb_pos` | Membingungkan | Satu schema `fnb` |

### 1.3 dbt

| # | Sev | Temuan | Dampak | Perbaikan v2 |
|---|---|---|---|---|
| D1 | KRITIS | `calendar` = union tanggal sales & waste | Opex di hari tanpa transaksi hilang, sehingga P&L bulanan understated | Date spine × outlet aktif |
| D2 | KRITIS | `left join hpp` lalu `coalesce(...,0)` | Menu tanpa BOM dianggap COGS 0, margin naik diam-diam | Test `std_cost_per_unit not_null` pada revenue line + `n_components_missing_cost = 0` |
| D3 | TINGGI | Test `not_null` pada `gross_margin_pct` & `actual_food_cost_ratio_pct` | `safe_divide` menghasilkan NULL di hari tanpa sales, pipeline merah padahal datanya sah | Test range dengan `row_condition: net_sales > 0` |
| D4 | TINGGI | `sources.yml`, `stg_orders` (kolom `order_date`), `stg_menu_items`, `stg_ingredients`, `stg_operating_expenses`, `fct_waste_operational_analysis` tidak ada | Project gagal compile | Lengkap di §7 |
| D5 | TINGGI | Kartu Metabase "BCG matrix" memakai `standard_gross_profit_per_unit` dari `int_order_items_cogs` (kolomnya tidak ada) | Query error. Framework yang tepat untuk F&B adalah **Menu Engineering (Kasavana-Smith)**, bukan BCG | `mart_menu_engineering` dengan aturan 70% popularitas & CM rata-rata tertimbang |
| D6 | SEDANG | Opex diprorata per hari kalender tanpa melihat tanggal outlet buka; tidak ada biaya HQ bersama | Opex outlet baru salah | `fct_opex_allocated_monthly` (alokasi HQ by net sales share, prorata per hari aktif) |
| D7 | SEDANG | Label "EBIT", padahal tidak ada D&A | Istilah keliru | `outlet_ebitda` |
| D8 | SEDANG | Tidak ada Prime Cost (COGS + Labor) | KPI utama F&B tidak tersedia | `prime_cost_pct` |
| D9 | SEDANG | `fct_financial_pnl` adalah agregat, bukan fact; tidak ada layer dim | Metabase sulit melakukan drill/join | `dim_*`, `fct_*` (grain atomik), `mart_*` (agregat) |
| D10 | SEDANG | `order by` di model table, tanpa partisi/cluster | Biaya & waktu terbuang | Partition + cluster |
| D11 | SEDANG | Tanpa packages, freshness, unit test, singular test, docs; memakai `tests:` (deprecated) | Regresi tidak terdeteksi | `data_tests:`, dbt_utils, dbt_expectations, unit test, singular test, glossary |
| D12 | SEDANG | Logika bisnis (`net_sales_amount`) di staging | Melanggar prinsip "staging = cermin" | Dipindah ke `fct_order_lines` |
| D13 | SEDANG | PII (`recorded_by`) sampai ke mart | Risiko privasi | Hash PII di staging, raw/stg tidak bisa diakses BI (§7.6) |

### 1.4 Apps Script & Metabase

> Temuan A3, A4, D5 (bagian kartu), M1, M2, dan M3 terkait Metabase tidak berlaku lagi sejak v2.1 karena Metabase diganti dashboard Vercel (§10). Dipertahankan sebagai jejak audit v1.

| # | Sev | Temuan | Dampak | Perbaikan v2 |
|---|---|---|---|---|
| G1 | KRITIS | `const queryResults` di-assign ulang di dalam loop | `TypeError: Assignment to constant variable` saat job belum selesai | `let` + exponential backoff |
| G2 | TINGGI | Tanpa pagination (`pageToken`), `location`, dan `maximumBytesBilled` | Data terpotong, job tidak ditemukan, tidak ada cap biaya | `runQuery_()` lengkap (§9) |
| G3 | TINGGI | Alert hanya `Logger.log`; `latestWasteRatio` tidak dipakai; threshold di-hardcode | Tidak ada yang menerima notifikasi | Threshold dari seed dbt → `mart_kpi_monthly_status` → email (dedupe) |
| G4 | SEDANG | Alert memakai bulan berjalan (parsial) sebagai "latest" | False alarm di awal bulan | Alert berbasis bulan lengkap + MTD hanya untuk CRITICAL |
| G5 | SEDANG | Tidak ada trigger, timezone, run log, maupun dashboard (hanya tabel); `sheet.clear()` menghapus format & chart | Tidak otomatis, sulit di-debug | `installTriggers()`, `appsscript.json` (Asia/Jakarta), `_sync_log`, web app dashboard, `clearContents()` |
| G6 | SEDANG | `PROJECT_ID` di-hardcode | Rawan saat pindah project | Script Properties |
| M1 | SEDANG | Kartu waterfall tanpa data berbentuk long | Tidak bisa dibuat | Di v2.1 waterfall dihitung di JS dari `pnl_monthly` (§10.5) |
| M2 | TINGGI | SA Metabase `Data Viewer` level project | Metabase bisa membaca raw/PII | Grant hanya ke dataset `core` & `marts` |
| M3 | SEDANG | Subscriptions/alerts Metabase saat scale-to-zero | Tidak akan terkirim | Alerting lewat Apps Script; Metabase khusus eksplorasi |

---

## 2. Arsitektur target v2 & strategi free tier

```
 ┌───────────────────────────── GitHub Actions (cron 00:30 WIB) ─────────────────────────────┐
 │ 1 generate (POS) → 2 ingest (dlt) → 3 dbt build + docs → 4 export JSON dashboard           │
 └────────────────────────────────────────────────────────────────────────────────────────────┘
        │ INSERT/UPDATE                 │ load job (gratis)          │ SQL (WIF, keyless)
        ▼                               ▼                            ▼
 [Neon Postgres: fnb-oltp]  ──►  [BigQuery asia-southeast2]
   schema fnb (29 tabel)          raw_fnb          ← dlt merge by PK, cursor updated_at
                                  stg              ← view: cermin + cast + WIB + hash PII
                                  int              ← explosion resep & costing harian
                                  core             ← dim_* / fct_* (grain atomik)
                                  marts            ← mart_pnl_*, mart_inventory_variance, ...
                                  snapshots        ← SCD2 master yang di-overwrite
                                  ops_secrets      ← salt PII (hanya SA dbt)
                                  ops_elementary   ← hasil test/observability
                                        │
                ┌───────────────────────┼─────────────────────────────┐
                ▼                       ▼                             ▼
    [Google Sheets + Apps Script]  [Dashboard Vercel (statis)]   [GitHub Pages]
    • sync 07:00 WIB → tab cache   • job export → JSON → git     • dbt docs
    • email alert KPI (dedupe)     • HTML/JS + Chart.js          • (opsional) elementary report
    • web app dashboard (Chart.js) • tanpa server, tanpa key
```

### 2.1 Matriks free tier & guardrail

| Komponen | Layanan | Batas free (acuan) | Pemakaian proyek (estimasi) | Guardrail |
|---|---|---|---|---|
| OLTP | Neon free, project `fnb-oltp` | ±0,5 GB storage/project, compute auto-suspend | < 300 MB (lihat §3.4), aktif ±10 menit/hari | Data mulai 2025-07-01, 3 outlet; retensi OLTP 12 bulan (BQ raw tetap menyimpan histori) |
| Warehouse | BigQuery free tier (billing aktif) | 10 GB storage, 1 TB query/bulan; load job gratis | < 2 GB storage, < 20 GB query/bulan | Custom quota 20 GB/hari, `maximum_bytes_billed` 2 GB/query, budget alert USD 1 |
| Ingestion | dlt (OSS) di GitHub Actions | Repo publik: menit tak terbatas; privat: 2.000 menit/bulan | ±8 menit/hari | `timeout-minutes`, `concurrency` |
| Transform | dbt Core (OSS) | gratis | ±3 menit/hari | `job_execution_timeout_seconds` |
| BI | Dashboard statis di Vercel Hobby | Gratis untuk proyek personal non-komersial (cek batas terkini) | 1 project, 1 deploy/hari, total JSON < 5 MB | Export hanya dari `marts`; pengunjung tidak memicu query BigQuery |
| Reporting | Google Sheets + Apps Script | trigger ±90 menit/hari, MailApp ±100 email/hari (akun konsumen) | 1 run/hari < 1 menit | Dedupe alert |
| Docs | GitHub Pages | gratis untuk repo publik | statis | Jangan publish sampel data |

> **Kenapa tidak Sandbox?** Sandbox cukup untuk demo view/table yang di-rebuild penuh, tetapi tidak cukup untuk menunjukkan kemampuan inti data engineering di portofolio (MERGE incremental, snapshot SCD2, insert_overwrite partition). Billing aktif + quota keras membuat tagihan tetap Rp 0 selama pemakaian di bawah free tier.

---

## 3. Source DB (PostgreSQL OLTP) v2

### 3.1 Prinsip desain

1. **Semua transaksi immutable.** Pembatalan dicatat lewat status/void/refund, bukan DELETE. Master memakai soft delete (`deleted_at`).
2. **Semua tabel punya `created_at` & `updated_at` (TIMESTAMPTZ)** yang dijaga trigger. Kolom ini jadi kursor incremental dlt.
3. **Data yang berubah sepanjang waktu disimpan effective-dated** (`effective_from` inklusif, `effective_to` eksklusif, NULL = masih berlaku) dan dijaga **exclusion constraint** agar periodenya tidak overlap: harga menu, standard cost bahan, versi resep, komisi kanal.
4. **Harga transaksi disalin ke baris order** (`unit_price`, `price_delta`), sehingga penjualan historis tidak bergantung pada master harga.
5. **Kuantitas bahan selalu dalam base UOM** (`g`, `ml`, `pcs`). Konversi dari UOM pembelian dilakukan saat penerimaan barang (`qty_base_uom`).
6. **Satu level sub-resep (prep item)**, misalnya sirup gula aren batch atau cold brew concentrate. Prep item hanya boleh tersusun dari bahan raw (divalidasi dbt test).

### 3.2 Ringkasan entitas

| Domain | Tabel |
|---|---|
| Organisasi | `outlets`, `employees` (PII), `customers` (PII) |
| Kanal & promo | `sales_channels`, `channel_commission_rates`, `promotions` |
| Menu | `menu_categories`, `menu_items`, `menu_item_prices`, `modifiers`, `modifier_lines` |
| Bahan & resep | `ingredients`, `ingredient_standard_costs`, `suppliers`, `recipes`, `recipe_lines` |
| Penjualan | `orders`, `order_items`, `order_item_modifiers`, `payments`, `refunds` |
| Inventori | `goods_receipts`, `goods_receipt_lines`, `stock_counts`, `stock_count_lines`, `waste_reasons`, `waste_logs` |
| Keuangan | `expense_categories`, `operating_expenses` |

Relasi kunci: `orders` → `order_items` → `order_item_modifiers`; `orders` → `payments`/`refunds`; `menu_items` → `recipes` (berversi) → `recipe_lines` → `ingredients` (raw atau prep) → `recipes` (resep prep); `outlets` menjadi FK di semua transaksi.

### 3.3 DDL lengkap (PostgreSQL 15+)

```sql
-- =====================================================================
-- F&B OLTP v2 — schema fnb
-- Konvensi: PK natural (VARCHAR) untuk master, IDENTITY untuk baris detail,
-- TIMESTAMPTZ untuk semua waktu, uang NUMERIC, kuantitas bahan dalam base UOM.
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS fnb;
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- untuk exclusion constraint periode

CREATE OR REPLACE FUNCTION fnb.set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================ ORGANISASI =============================
CREATE TABLE fnb.outlets (
    outlet_id       VARCHAR(10)  PRIMARY KEY,
    outlet_name     VARCHAR(100) NOT NULL,
    city            VARCHAR(50)  NOT NULL,
    outlet_type     VARCHAR(20)  NOT NULL CHECK (outlet_type IN ('Flagship', 'Kiosk', 'Cloud Kitchen')),
    seat_capacity   INT          NOT NULL DEFAULT 0 CHECK (seat_capacity >= 0),
    opened_date     DATE         NOT NULL,
    closed_date     DATE         CHECK (closed_date IS NULL OR closed_date >= opened_date),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.employees (
    employee_id     VARCHAR(10)  PRIMARY KEY,
    outlet_id       VARCHAR(10)  NOT NULL REFERENCES fnb.outlets (outlet_id),
    full_name       VARCHAR(100) NOT NULL,                       -- PII
    phone_number    VARCHAR(20),                                 -- PII
    job_role        VARCHAR(30)  NOT NULL CHECK (job_role IN ('Barista', 'Cook', 'Cashier', 'Supervisor', 'Outlet Manager')),
    hired_date      DATE         NOT NULL,
    terminated_date DATE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.customers (
    customer_id     VARCHAR(20)  PRIMARY KEY,
    full_name       VARCHAR(100),                                -- PII
    phone_number    VARCHAR(20)  UNIQUE,                         -- PII
    email           VARCHAR(100),                                -- PII
    birth_date      DATE,                                        -- PII
    registered_at   TIMESTAMPTZ  NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);

-- ========================= KANAL & PROMO =============================
CREATE TABLE fnb.sales_channels (
    channel_code    VARCHAR(20)  PRIMARY KEY,                    -- DINE_IN, TAKEAWAY, GOFOOD, GRABFOOD, SHOPEEFOOD
    channel_name    VARCHAR(50)  NOT NULL,
    channel_group   VARCHAR(20)  NOT NULL CHECK (channel_group IN ('Offline', 'Online Delivery')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.channel_commission_rates (
    channel_code    VARCHAR(20)  NOT NULL REFERENCES fnb.sales_channels (channel_code),
    effective_from  DATE         NOT NULL,
    effective_to    DATE,                                        -- eksklusif; NULL = masih berlaku
    commission_pct  NUMERIC(5,2) NOT NULL CHECK (commission_pct BETWEEN 0 AND 100),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_code, effective_from),
    CHECK (effective_to IS NULL OR effective_to > effective_from),
    EXCLUDE USING gist (channel_code WITH =, daterange(effective_from, effective_to) WITH &&)
);

CREATE TABLE fnb.promotions (
    promo_code      VARCHAR(30)  PRIMARY KEY,
    promo_name      VARCHAR(100) NOT NULL,
    promo_type      VARCHAR(20)  NOT NULL CHECK (promo_type IN ('PERCENT', 'FIXED')),
    promo_value     NUMERIC(12,2) NOT NULL CHECK (promo_value > 0),
    funded_by       VARCHAR(20)  NOT NULL CHECK (funded_by IN ('Merchant', 'Platform')),
    start_date      DATE         NOT NULL,
    end_date        DATE         NOT NULL CHECK (end_date >= start_date),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- =============================== MENU ================================
CREATE TABLE fnb.menu_categories (
    category_code   VARCHAR(20)  PRIMARY KEY,
    category_name   VARCHAR(50)  NOT NULL,
    category_group  VARCHAR(20)  NOT NULL CHECK (category_group IN ('Beverage', 'Food', 'Bakery')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.menu_items (
    menu_item_id      VARCHAR(20)  PRIMARY KEY,
    menu_name         VARCHAR(100) NOT NULL,
    category_code     VARCHAR(20)  NOT NULL REFERENCES fnb.menu_categories (category_code),
    launched_date     DATE         NOT NULL,
    discontinued_date DATE,
    is_active         BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ
);

CREATE TABLE fnb.menu_item_prices (
    menu_item_id    VARCHAR(20)  NOT NULL REFERENCES fnb.menu_items (menu_item_id),
    channel_group   VARCHAR(20)  NOT NULL CHECK (channel_group IN ('Offline', 'Online Delivery')),
    effective_from  DATE         NOT NULL,
    effective_to    DATE,
    selling_price   NUMERIC(12,2) NOT NULL CHECK (selling_price > 0),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (menu_item_id, channel_group, effective_from),
    CHECK (effective_to IS NULL OR effective_to > effective_from),
    EXCLUDE USING gist (menu_item_id WITH =, channel_group WITH =, daterange(effective_from, effective_to) WITH &&)
);

-- ========================== BAHAN & RESEP ============================
CREATE TABLE fnb.ingredients (
    ingredient_id       VARCHAR(20)  PRIMARY KEY,
    ingredient_name     VARCHAR(100) NOT NULL,
    ingredient_category VARCHAR(20)  NOT NULL CHECK (ingredient_category IN
                        ('Coffee', 'Dairy', 'Syrup', 'Tea', 'Bakery', 'Protein', 'Produce', 'Dry Goods', 'Packaging', 'Prep')),
    base_uom            VARCHAR(5)   NOT NULL CHECK (base_uom IN ('g', 'ml', 'pcs')),
    is_prep_item        BOOLEAN      NOT NULL DEFAULT FALSE,     -- TRUE = setengah jadi, dibuat dari resep prep
    is_perishable       BOOLEAN      NOT NULL DEFAULT FALSE,
    shelf_life_days     INT          CHECK (shelf_life_days > 0),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ
);

CREATE TABLE fnb.ingredient_standard_costs (
    ingredient_id   VARCHAR(20)  NOT NULL REFERENCES fnb.ingredients (ingredient_id),
    effective_from  DATE         NOT NULL,
    effective_to    DATE,
    standard_cost_per_base_uom NUMERIC(14,4) NOT NULL CHECK (standard_cost_per_base_uom >= 0),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (ingredient_id, effective_from),
    CHECK (effective_to IS NULL OR effective_to > effective_from),
    EXCLUDE USING gist (ingredient_id WITH =, daterange(effective_from, effective_to) WITH &&)
);

CREATE TABLE fnb.suppliers (
    supplier_id       VARCHAR(10)  PRIMARY KEY,
    supplier_name     VARCHAR(100) NOT NULL,
    city              VARCHAR(50),
    payment_term_days INT          NOT NULL DEFAULT 0 CHECK (payment_term_days >= 0),
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ
);

-- Resep berversi untuk menu ATAU prep item (tepat salah satu)
CREATE TABLE fnb.recipes (
    recipe_id           VARCHAR(30)  PRIMARY KEY,                -- mis. R_MNU_LATTE_V2
    menu_item_id        VARCHAR(20)  REFERENCES fnb.menu_items (menu_item_id),
    prep_ingredient_id  VARCHAR(20)  REFERENCES fnb.ingredients (ingredient_id),
    version_no          INT          NOT NULL CHECK (version_no > 0),
    yield_qty           NUMERIC(12,4) NOT NULL DEFAULT 1 CHECK (yield_qty > 0), -- menu: 1 porsi; prep: hasil batch dlm base_uom
    effective_from      DATE         NOT NULL,
    effective_to        DATE,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(menu_item_id, prep_ingredient_id) = 1),
    CHECK (effective_to IS NULL OR effective_to > effective_from),
    EXCLUDE USING gist ((COALESCE(menu_item_id, prep_ingredient_id)) WITH =,
                        daterange(effective_from, effective_to) WITH &&)
);

CREATE TABLE fnb.recipe_lines (
    recipe_id       VARCHAR(30)  NOT NULL REFERENCES fnb.recipes (recipe_id),
    ingredient_id   VARCHAR(20)  NOT NULL REFERENCES fnb.ingredients (ingredient_id),  -- raw atau prep
    qty_per_yield   NUMERIC(12,4) NOT NULL CHECK (qty_per_yield > 0),                  -- qty bersih per yield_qty
    loss_pct        NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (loss_pct >= 0 AND loss_pct < 100), -- trimming/evaporasi
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (recipe_id, ingredient_id)
);

CREATE TABLE fnb.modifiers (
    modifier_id     VARCHAR(20)  PRIMARY KEY,                    -- MOD_EXTRA_SHOT, MOD_OAT, MOD_LARGE
    modifier_name   VARCHAR(50)  NOT NULL,
    modifier_group  VARCHAR(20)  NOT NULL CHECK (modifier_group IN ('Size', 'Milk', 'Sugar', 'Add-on')),
    price_delta     NUMERIC(12,2) NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);

-- qty_delta boleh negatif (ganti susu: -150 ml fresh milk, +150 ml oat milk)
CREATE TABLE fnb.modifier_lines (
    modifier_id     VARCHAR(20)  NOT NULL REFERENCES fnb.modifiers (modifier_id),
    ingredient_id   VARCHAR(20)  NOT NULL REFERENCES fnb.ingredients (ingredient_id),
    qty_delta       NUMERIC(12,4) NOT NULL CHECK (qty_delta <> 0),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (modifier_id, ingredient_id)
);

-- ============================ PENJUALAN ==============================
CREATE TABLE fnb.orders (
    order_id              VARCHAR(30)  PRIMARY KEY,              -- {outlet}-{yyyymmdd}-{seq}
    outlet_id             VARCHAR(10)  NOT NULL REFERENCES fnb.outlets (outlet_id),
    channel_code          VARCHAR(20)  NOT NULL REFERENCES fnb.sales_channels (channel_code),
    customer_id           VARCHAR(20)  REFERENCES fnb.customers (customer_id),
    cashier_id            VARCHAR(10)  REFERENCES fnb.employees (employee_id),
    promo_code            VARCHAR(30)  REFERENCES fnb.promotions (promo_code),
    external_order_ref    VARCHAR(50),                           -- id GoFood/GrabFood
    ordered_at            TIMESTAMPTZ  NOT NULL,
    order_status          VARCHAR(20)  NOT NULL CHECK (order_status IN ('Open', 'Completed', 'Cancelled')),
    cancelled_at          TIMESTAMPTZ,
    cancel_reason         VARCHAR(100),
    guest_count           INT          CHECK (guest_count > 0),
    subtotal_amount       NUMERIC(14,2) NOT NULL CHECK (subtotal_amount >= 0),  -- Σ qty × (unit_price + modifier)
    item_discount_amount  NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (item_discount_amount >= 0),
    order_discount_amount NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (order_discount_amount >= 0),
    service_charge_amount NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (service_charge_amount >= 0),
    tax_amount            NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),     -- PB1
    total_amount          NUMERIC(14,2) NOT NULL CHECK (total_amount >= 0),
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (total_amount = subtotal_amount - item_discount_amount - order_discount_amount
                          + service_charge_amount + tax_amount),
    CHECK ((order_status = 'Cancelled') = (cancelled_at IS NOT NULL))
);

CREATE TABLE fnb.order_items (
    order_item_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id              VARCHAR(30)  NOT NULL REFERENCES fnb.orders (order_id),
    menu_item_id          VARCHAR(20)  NOT NULL REFERENCES fnb.menu_items (menu_item_id),
    qty                   INT          NOT NULL CHECK (qty > 0),
    unit_price            NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),  -- salinan harga saat transaksi
    line_discount_amount  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (line_discount_amount >= 0),
    line_status           VARCHAR(10)  NOT NULL DEFAULT 'Served' CHECK (line_status IN ('Served', 'Void')),
    void_reason           VARCHAR(100),
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.order_item_modifiers (
    order_item_id   BIGINT       NOT NULL REFERENCES fnb.order_items (order_item_id),
    modifier_id     VARCHAR(20)  NOT NULL REFERENCES fnb.modifiers (modifier_id),
    price_delta     NUMERIC(12,2) NOT NULL DEFAULT 0,            -- salinan harga modifier per unit
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (order_item_id, modifier_id)
);

CREATE TABLE fnb.payments (
    payment_id      VARCHAR(30)  PRIMARY KEY,
    order_id        VARCHAR(30)  NOT NULL REFERENCES fnb.orders (order_id),
    payment_method  VARCHAR(30)  NOT NULL CHECK (payment_method IN
                    ('Cash', 'QRIS', 'Debit Card', 'Credit Card', 'E-Wallet', 'Platform Settlement')),
    amount          NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    mdr_fee_amount  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (mdr_fee_amount >= 0),
    paid_at         TIMESTAMPTZ  NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.refunds (
    refund_id       VARCHAR(30)  PRIMARY KEY,
    order_id        VARCHAR(30)  NOT NULL REFERENCES fnb.orders (order_id),
    order_item_id   BIGINT       REFERENCES fnb.order_items (order_item_id),   -- NULL = refund level order
    refund_amount   NUMERIC(14,2) NOT NULL CHECK (refund_amount > 0),
    refund_reason   VARCHAR(100) NOT NULL,
    approved_by     VARCHAR(10)  REFERENCES fnb.employees (employee_id),
    refunded_at     TIMESTAMPTZ  NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ============================ INVENTORI ==============================
CREATE TABLE fnb.goods_receipts (
    gr_id           VARCHAR(30)  PRIMARY KEY,
    outlet_id       VARCHAR(10)  NOT NULL REFERENCES fnb.outlets (outlet_id),
    supplier_id     VARCHAR(10)  NOT NULL REFERENCES fnb.suppliers (supplier_id),
    invoice_no      VARCHAR(50),
    received_at     TIMESTAMPTZ  NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.goods_receipt_lines (
    gr_line_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gr_id           VARCHAR(30)  NOT NULL REFERENCES fnb.goods_receipts (gr_id),
    ingredient_id   VARCHAR(20)  NOT NULL REFERENCES fnb.ingredients (ingredient_id),
    purchase_qty    NUMERIC(12,3) NOT NULL CHECK (purchase_qty > 0),
    purchase_uom    VARCHAR(10)  NOT NULL,                       -- kg, liter, pack, karton
    qty_base_uom    NUMERIC(14,3) NOT NULL CHECK (qty_base_uom > 0), -- sudah dikonversi ke base_uom
    line_amount     NUMERIC(14,2) NOT NULL CHECK (line_amount >= 0),
    expiry_date     DATE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.stock_counts (
    count_id        VARCHAR(30)  PRIMARY KEY,
    outlet_id       VARCHAR(10)  NOT NULL REFERENCES fnb.outlets (outlet_id),
    count_date      DATE         NOT NULL,                       -- dihitung saat tutup toko
    count_type      VARCHAR(20)  NOT NULL CHECK (count_type IN ('Opening', 'Weekly', 'Month End')),
    counted_by      VARCHAR(10)  REFERENCES fnb.employees (employee_id),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (outlet_id, count_date)
);

CREATE TABLE fnb.stock_count_lines (
    count_id        VARCHAR(30)  NOT NULL REFERENCES fnb.stock_counts (count_id),
    ingredient_id   VARCHAR(20)  NOT NULL REFERENCES fnb.ingredients (ingredient_id),
    counted_qty_base NUMERIC(14,3) NOT NULL CHECK (counted_qty_base >= 0),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (count_id, ingredient_id)
);

CREATE TABLE fnb.waste_reasons (
    reason_code     VARCHAR(20)  PRIMARY KEY,                    -- EXPIRED, PREP_SPOIL, DROPPED, QC_REJECT, CUST_RETURN
    reason_name     VARCHAR(50)  NOT NULL,
    controllability VARCHAR(20)  NOT NULL CHECK (controllability IN ('Controllable', 'Uncontrollable')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Waste bisa berupa bahan raw, prep item (keduanya via ingredient_id), atau produk jadi (menu_item_id)
CREATE TABLE fnb.waste_logs (
    waste_id        VARCHAR(30)  PRIMARY KEY,
    outlet_id       VARCHAR(10)  NOT NULL REFERENCES fnb.outlets (outlet_id),
    logged_at       TIMESTAMPTZ  NOT NULL,
    ingredient_id   VARCHAR(20)  REFERENCES fnb.ingredients (ingredient_id),
    menu_item_id    VARCHAR(20)  REFERENCES fnb.menu_items (menu_item_id),
    qty             NUMERIC(12,3) NOT NULL CHECK (qty > 0),      -- base_uom (bahan/prep) atau porsi (menu)
    reason_code     VARCHAR(20)  NOT NULL REFERENCES fnb.waste_reasons (reason_code),
    recorded_by     VARCHAR(10)  NOT NULL REFERENCES fnb.employees (employee_id),
    notes           VARCHAR(200),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(ingredient_id, menu_item_id) = 1)
);

-- ============================ KEUANGAN ===============================
CREATE TABLE fnb.expense_categories (
    category_code   VARCHAR(20)  PRIMARY KEY,
    category_name   VARCHAR(50)  NOT NULL,
    pnl_line        VARCHAR(30)  NOT NULL CHECK (pnl_line IN
                    ('Labor', 'Occupancy', 'Utilities', 'Marketing', 'Repairs & Maintenance', 'G&A')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.operating_expenses (
    expense_id      VARCHAR(30)  PRIMARY KEY,
    outlet_id       VARCHAR(10)  REFERENCES fnb.outlets (outlet_id),   -- NULL = biaya HQ/bersama (dialokasikan di dbt)
    period_month    DATE         NOT NULL CHECK (period_month = date_trunc('month', period_month)::date),
    category_code   VARCHAR(20)  NOT NULL REFERENCES fnb.expense_categories (category_code),
    amount          NUMERIC(14,2) NOT NULL CHECK (amount >= 0),
    description     VARCHAR(200),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE NULLS NOT DISTINCT (outlet_id, period_month, category_code)
);

-- ============================== INDEX ================================
CREATE INDEX ON fnb.orders (ordered_at);
CREATE INDEX ON fnb.orders (outlet_id, ordered_at);
CREATE INDEX ON fnb.order_items (order_id);
CREATE INDEX ON fnb.payments (order_id);
CREATE INDEX ON fnb.refunds (order_id);
CREATE INDEX ON fnb.goods_receipt_lines (gr_id);
CREATE INDEX ON fnb.waste_logs (outlet_id, logged_at);

-- Trigger updated_at + index updated_at (kursor incremental) untuk setiap tabel
DO $$
DECLARE t text;
BEGIN
    FOR t IN
        SELECT table_name FROM information_schema.columns
        WHERE table_schema = 'fnb' AND column_name = 'updated_at'
    LOOP
        EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON fnb.%I
                        FOR EACH ROW EXECUTE FUNCTION fnb.set_updated_at()', t, t);
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_updated_at ON fnb.%I (updated_at)', t, t);
    END LOOP;
END $$;
```

**Seed master minimal (contoh; generator mengisi lengkap):**

```sql
INSERT INTO fnb.sales_channels (channel_code, channel_name, channel_group) VALUES
('DINE_IN', 'Dine-In', 'Offline'), ('TAKEAWAY', 'Takeaway', 'Offline'),
('GOFOOD', 'GoFood', 'Online Delivery'), ('GRABFOOD', 'GrabFood', 'Online Delivery'),
('SHOPEEFOOD', 'ShopeeFood', 'Online Delivery');

INSERT INTO fnb.ingredients (ingredient_id, ingredient_name, ingredient_category, base_uom, is_prep_item, is_perishable, shelf_life_days) VALUES
('ING_ESPR', 'Espresso Beans',          'Coffee',    'g',   FALSE, FALSE, 60),
('ING_MILK', 'Fresh Milk',              'Dairy',     'ml',  FALSE, TRUE,  7),
('ING_OAT',  'Oat Milk',                'Dairy',     'ml',  FALSE, TRUE,  10),
('ING_PALM', 'Gula Aren Cair',          'Syrup',     'ml',  FALSE, FALSE, 90),
('ING_WATR', 'Air Mineral Galon',       'Dry Goods', 'ml',  FALSE, FALSE, 30),
('ING_CUP',  'Paper Cup & Lid 12oz',    'Packaging', 'pcs', FALSE, FALSE, NULL),
('PRP_AREN', 'Sirup Aren Batch',        'Prep',      'ml',  TRUE,  TRUE,  3);

INSERT INTO fnb.ingredient_standard_costs (ingredient_id, effective_from, effective_to, standard_cost_per_base_uom) VALUES
('ING_ESPR', '2025-07-01', NULL,         250.0000),
('ING_MILK', '2025-07-01', '2026-01-01',  20.0000),
('ING_MILK', '2026-01-01', NULL,          22.4000),   -- story event: susu naik 12%
('ING_OAT',  '2025-07-01', NULL,          45.0000),
('ING_PALM', '2025-07-01', NULL,          60.0000),
('ING_WATR', '2025-07-01', NULL,           0.5000),
('ING_CUP',  '2025-07-01', NULL,        1500.0000);

-- Sirup aren batch: 600 ml gula aren + 500 ml air (10% menguap) → 1.000 ml
INSERT INTO fnb.recipes (recipe_id, prep_ingredient_id, version_no, yield_qty, effective_from) VALUES
('R_PRP_AREN_V1', 'PRP_AREN', 1, 1000, '2025-07-01');
INSERT INTO fnb.recipe_lines (recipe_id, ingredient_id, qty_per_yield, loss_pct) VALUES
('R_PRP_AREN_V1', 'ING_PALM', 600, 0), ('R_PRP_AREN_V1', 'ING_WATR', 450, 10);
```

### 3.4 Sizing (agar muat di Neon free 0,5 GB)

| Tabel | Asumsi (3 outlet, 2025-07-01 → 2026-10, ±470 hari) | Baris | Estimasi (data + index) |
|---|---|---|---|
| orders | 180 order/outlet/hari | ±254 rb | ±70 MB |
| order_items | 2,3 item/order | ±585 rb | ±110 MB |
| order_item_modifiers | 35% item | ±205 rb | ±30 MB |
| payments | 1,05/order | ±267 rb | ±45 MB |
| waste_logs, goods_receipt_lines, stock_count_lines | — | ±120 rb | ±25 MB |
| master + lainnya | — | < 20 rb | < 10 MB |
| **Total** | | | **±290 MB** |

Jika mendekati batas, terapkan **retensi OLTP**: hapus order lebih dari 12 bulan di Neon. Raw BigQuery tetap menyimpan histori karena dlt hanya melakukan merge, sehingga hard delete di sumber tidak menghapus data di raw. Ini sesuai dengan pola nyata "OLTP retensi pendek, DWH histori penuh". **Jangan pernah** menjalankan dlt dengan `write_disposition="replace"` atau `--full-refresh` pada raw setelah retensi diaktifkan.

---

## 4. Data generator (simulasi POS)

Source DB baru bernilai untuk analitik kalau datanya realistis dan menyimpan pola yang bisa ditemukan oleh analis. Generator ditulis dalam Python (`numpy`, `psycopg`) dengan seed deterministik per tanggal, sehingga **idempotent**: menjalankan ulang tanggal yang sama menghasilkan ID yang sama, dan `ON CONFLICT DO NOTHING` mencegah duplikasi.

### 4.1 Mode

```bash
python oltp/generator/generate.py init-master                      # outlet, menu, bahan, resep, harga, kanal, karyawan
python oltp/generator/generate.py backfill --start 2025-07-01 --end 2026-10-09
python oltp/generator/generate.py daily --date 2026-10-09          # dipanggil GitHub Actions tiap malam
```

### 4.2 Model permintaan

| Faktor | Implementasi |
|---|---|
| Volume dasar | Flagship 260, Kiosk 150, Cloud Kitchen 130 order/hari |
| Hari | Sen 0,85 · Sel–Kam 0,95 · Jum 1,10 · Sab 1,30 · Min 1,20 |
| Jam | Distribusi campuran: puncak 07–09, 12–13, 16–18 (offline); 19–21 (online) |
| Payday | Tanggal 25–akhir bulan & tanggal 1: +12% |
| Ramadan | Siang −45%, buka puasa (17:30–19:00) +80%, sahur kanal online +; Lebaran: outlet tutup 2 hari |
| Hujan | Bernoulli harian 35% (musim hujan Nov–Mar 60%): offline −20%, online +25% |
| Kanal | Flagship 70% offline; Cloud Kitchen 100% online |
| Basket | Poisson(1,3)+1 item; 35% item ber-modifier; 25% order online memakai promo |
| Member | 30% order dine-in/takeaway memakai `customer_id` |

### 4.3 Story events (pola yang sengaja ditanam untuk ditemukan analis)

| Tanggal | Event | Yang seharusnya terlihat di mart |
|---|---|---|
| 2026-01-01 | Standard cost susu +12% (versi cost baru) | `food_cost_pct` menu berbasis susu naik; Latte bergeser dari Star ke Plowhorse |
| 2026-02-01 | Resep Kopi Susu Aren v2 (sirup 30 → 25 ml) | HPP turun; theoretical usage aren turun |
| 2026-04-01 | Komisi GoFood 20% → 22% | `channel_commission` naik; margin kanal online turun |
| Outlet KIOSK-02 | Overpour susu 6% (tidak tercatat) | `unexplained_variance` susu positif hanya di outlet ini |
| Musim hujan | Waste roti `EXPIRED` naik | `mart_waste_analysis` menunjukkan musiman |
| Acak 0,3% | Refund H+1 kanal online (`CUST_RETURN`) | Refund muncul di tanggal refund, bukan tanggal order |
| Acak 1% | Order offline tersinkron telat (H+1) | Menguji lookback incremental |

### 4.4 Siklus inventori

- **Penerimaan barang**: setiap Senin/Kamis, isi stok kembali sampai par level (par = rata-rata pemakaian 4 hari × 1,2). Harga beli = standard cost × N(1; 0,04).
- **Stock count**: setiap Minggu malam + hari terakhir bulan. `counted = buku teoritis − waste tercatat − shrinkage tersembunyi + noise N(0; 0,5%)`.
- **Waste**: bahan perishable kedaluwarsa di atas shelf life (FIFO kasar), prep spoil di akhir hari (Bernoulli), produk jatuh/QC reject sekitar 0,4% item.
- **Opex**: diinput bulanan (gaji per outlet, sewa, listrik ~ volume, marketing), plus biaya HQ dengan `outlet_id` NULL.

---

## 5. Ingestion: Postgres → BigQuery (dlt)

**Kenapa dlt:** OSS, gratis, mendukung `sql_database` + incremental cursor + `merge` ke BigQuery memakai load job (gratis, bukan streaming insert), dan menyimpan state incremental di destination sehingga runner GitHub Actions yang ephemeral tetap aman.

`ingestion/pipeline.py`

```python
"""Ingest OLTP Neon (schema fnb) -> BigQuery dataset raw_fnb.

Semua tabel: incremental berdasarkan updated_at, merge by primary key (direfleksi dari Postgres).
Raw bersifat append/merge-only: jangan pernah replace (lihat retensi OLTP).
"""
import os

import dlt
from dlt.sources.sql_database import sql_database

TABLES = [
    "outlets", "employees", "customers", "sales_channels", "channel_commission_rates", "promotions",
    "menu_categories", "menu_items", "menu_item_prices", "modifiers", "modifier_lines",
    "ingredients", "ingredient_standard_costs", "suppliers", "recipes", "recipe_lines",
    "orders", "order_items", "order_item_modifiers", "payments", "refunds",
    "goods_receipts", "goods_receipt_lines", "stock_counts", "stock_count_lines",
    "waste_reasons", "waste_logs", "expense_categories", "operating_expenses",
]


def main() -> None:
    source = sql_database(
        credentials=os.environ["SOURCE_DATABASE_URL"],   # postgresql+psycopg2://...?sslmode=require
        schema="fnb",
        table_names=TABLES,
        backend="pyarrow",
        reflection_level="full_with_precision",          # NUMERIC tetap presisi (uang)
    )
    for name in TABLES:
        source.resources[name].apply_hints(
            # lag 2 jam: tangkap transaksi yang commit lebih lambat dari updated_at-nya
            incremental=dlt.sources.incremental("updated_at", lag=7200),
            write_disposition="merge",
        )

    pipeline = dlt.pipeline(
        pipeline_name="fnb_pos_to_bigquery",
        destination="bigquery",
        dataset_name="raw_fnb",
    )
    load_info = pipeline.run(source)
    print(load_info)
    load_info.raise_on_failed_jobs()


if __name__ == "__main__":
    main()
```

`ingestion/requirements.txt` (pin versi eksak saat bootstrap):

```
dlt[bigquery,sql_database]==<pin>
psycopg2-binary==<pin>
pyarrow==<pin>
```

Environment (diset di workflow):

```
SOURCE_DATABASE_URL=<secret>
DESTINATION__BIGQUERY__LOCATION=asia-southeast2
DESTINATION__BIGQUERY__CREDENTIALS__PROJECT_ID=<gcp_project_id>   # kredensial = ADC dari Workload Identity
```

Catatan:
- dlt membuat dataset staging `raw_fnb_staging` untuk proses merge. Buat dataset ini lebih dulu dan beri akses ke SA ingest.
- Parameter `lag` pada `incremental` hanya ada di dlt versi baru. Jika versi yang terpasang belum mendukung, hapus parameter itu dan andalkan lookback dbt.
- Kolom metadata dlt (`_dlt_load_id`, `_dlt_id`) dibiarkan di raw dan tidak dipilih di staging.

---

## 6. Setup BigQuery: dataset, IAM, guardrail biaya

### 6.1 Bootstrap project (sekali)

```bash
gcloud projects create <PROJECT_ID>
gcloud billing projects link <PROJECT_ID> --billing-account=<BILLING_ID>
gcloud services enable bigquery.googleapis.com iamcredentials.googleapis.com sts.googleapis.com \
  --project <PROJECT_ID>
```

### 6.2 Dataset (BigQuery SQL)

```sql
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.raw_fnb`         OPTIONS (location = 'asia-southeast2');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.raw_fnb_staging` OPTIONS (location = 'asia-southeast2');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.stg`             OPTIONS (location = 'asia-southeast2');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.int`             OPTIONS (location = 'asia-southeast2');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.core`            OPTIONS (location = 'asia-southeast2');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.marts`           OPTIONS (location = 'asia-southeast2');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.snapshots`       OPTIONS (location = 'asia-southeast2');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.ops_secrets`     OPTIONS (location = 'asia-southeast2');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.ops_elementary`  OPTIONS (location = 'asia-southeast2');

-- Salt PII: dibuat sekali, tidak pernah ditulis di repo/log/compiled SQL
CREATE TABLE `<PROJECT_ID>.ops_secrets.pii_salt` AS SELECT GENERATE_UUID() AS salt;
```

### 6.3 Service account & akses (least privilege)

| SA | Dipakai oleh | Project-level | Dataset-level |
|---|---|---|---|
| `sa-ingest` | GitHub Actions (WIF) | `bigquery.jobUser` | `dataEditor`: raw_fnb, raw_fnb_staging |
| `sa-dbt` | GitHub Actions prod (WIF) | `bigquery.jobUser` | `dataViewer`: raw_fnb, ops_secrets · `dataEditor`: stg, int, core, marts, snapshots, ops_elementary |
| `sa-github-ci` | GitHub Actions PR (WIF) | `bigquery.user` (bisa membuat dataset CI) | `dataViewer`: raw_fnb, ops_secrets, stg, int, core, marts, snapshots |
| `sa-export` | GitHub Actions job export dashboard (WIF, tanpa key) | `bigquery.jobUser` | `dataViewer`: marts (hanya) |
| Akun Google pemilik | Apps Script | owner | — |

Grant dataset memakai DCL BigQuery:

```sql
GRANT `roles/bigquery.dataViewer` ON SCHEMA `<PROJECT_ID>.marts`
TO "serviceAccount:sa-export@<PROJECT_ID>.iam.gserviceaccount.com";
-- ulangi untuk setiap baris tabel di atas
```

Workload Identity Federation (GitHub Actions tanpa JSON key):

```bash
gcloud iam workload-identity-pools create github --location=global --project <PROJECT_ID>
gcloud iam workload-identity-pools providers create-oidc github-oidc \
  --location=global --workload-identity-pool=github --project <PROJECT_ID> \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='<OWNER>/<REPO>'"

for SA in sa-ingest sa-dbt sa-github-ci sa-export; do
  gcloud iam service-accounts add-iam-policy-binding "$SA@<PROJECT_ID>.iam.gserviceaccount.com" \
    --role=roles/iam.workloadIdentityUser \
    --member="principalSet://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github/attribute.repository/<OWNER>/<REPO>"
done
```

### 6.4 Guardrail biaya (wajib sebelum job pertama)

1. **Custom quota** (guardrail utama, satu-satunya yang memblokir query secara keras): Console → IAM & Admin → Quotas → BigQuery API → *Query usage per day* = **20 GB**. Karena 20 × 31 = 620 GB < 1 TB, tagihan query tidak mungkin muncul. Budget alert hanya notifikasi.
2. **Per-query cap**: `maximum_bytes_billed: 2000000000` di profile dbt dan `maximumBytesBilled` di Apps Script.
3. **Budget alert** USD 1 (50%/90%/100%), sebagai notifikasi saja karena budget tidak menghentikan tagihan:
   ```bash
   gcloud billing budgets create --billing-account=<BILLING_ID> --display-name="fnb-guard" \
     --budget-amount=1USD --threshold-rule=percent=0.5 --threshold-rule=percent=1.0
   ```
4. **Storage**: biarkan billing model logical (default), karena time travel/fail-safe tidak ditagih di model ini.
5. **Monitoring biaya**: dbt mengirim label job (§7.2), lalu biaya dapat dicek per target:
   ```sql
   SELECT l.value AS dbt_target, SUM(total_bytes_billed) / POW(1024, 3) AS gb_billed
   FROM `region-asia-southeast2`.INFORMATION_SCHEMA.JOBS, UNNEST(labels) AS l
   WHERE l.key = 'dbt_target' AND creation_time >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), MONTH)
   GROUP BY 1;
   ```

---

## 7. dbt project v2

### 7.1 Struktur & pemetaan layer

Pemetaan ke blueprint common: `staging` = **L1 Base**, `core` = **L2 Dim/Fact**, `marts` = **L3 Mart**. `intermediate` adalah helper logika lintas tabel (costing/explosion) yang tidak dikonsumsi BI.

```
dbt/
├── dbt_project.yml · packages.yml · package-lock.yml · profiles.yml · .sqlfluff · requirements.txt
├── macros/
│   ├── generate_schema_name.sql
│   ├── time.sql                 # to_local_datetime, to_local_date
│   ├── math.sql                 # safe_pct
│   └── pii.sql                  # hash_pii
├── models/
│   ├── glossary/                # {% docs %} definisi KPI
│   ├── staging/pos/             # _pos__sources.yml, _pos__models.yml, stg_pos__<tabel>.sql (29 model)
│   ├── utilities/               # util_dates
│   ├── intermediate/costing/    # int_item_explosion_daily, int_item_std_cost_daily
│   ├── core/                    # dim_date, dim_outlet, dim_menu_item, dim_ingredient, dim_channel,
│   │                            # fct_order_lines, fct_orders, fct_refunds, fct_waste,
│   │                            # fct_goods_receipt_lines, fct_stock_counts,
│   │                            # fct_inventory_movements_daily, fct_opex_allocated_monthly
│   ├── marts/finance/           # mart_pnl_daily, mart_pnl_monthly, mart_kpi_monthly_status, mart_channel_performance_daily
│   ├── marts/operations/        # mart_inventory_variance, mart_waste_analysis, mart_menu_engineering
│   ├── reconciliation/          # audit_helper (enabled=false)
│   └── exposures.yml            # Sheets & dashboard Vercel
├── seeds/                       # kpi_thresholds.csv, id_calendar_events.csv, _seeds.yml
├── snapshots/                   # _snapshots.yml (YAML-based, dbt ≥ 1.9)
└── tests/                       # singular tests
```

Konvensi nama: `stg_<source>__<tabel>`, `int_<deskripsi>`, `dim_<entitas>`, `fct_<proses>`, `mart_<subjek>`, `_<folder>__models.yml`.

### 7.2 Konfigurasi

`dbt_project.yml`

```yaml
name: 'fnb_data_platform'
version: '2.0.0'
config-version: 2
profile: 'fnb_data_platform'

flags:
  send_anonymous_usage_stats: false

query-comment:
  append: true
  job-label: true            # metadata dbt jadi label job BigQuery → biaya per target/model

vars:
  local_tz: 'Asia/Jakarta'
  start_date: "date '2025-07-01'"
  lookback_days: 3
  secrets_dataset: 'ops_secrets'
  'dbt_date:time_zone': 'Asia/Jakarta'

models:
  fnb_data_platform:
    +persist_docs: {relation: true, columns: true}
    +labels: {project: fnb, managed_by: dbt}
    staging:
      +materialized: view
      +schema: stg
    utilities:
      +materialized: table
      +schema: core
    intermediate:
      +materialized: table
      +schema: int
    core:
      +materialized: table
      +schema: core
    marts:
      +materialized: table
      +schema: marts
    reconciliation:
      +enabled: false
  elementary:
    +schema: ops_elementary

seeds:
  fnb_data_platform:
    +schema: core

snapshots:
  fnb_data_platform:
    +schema: snapshots
```

`packages.yml` (pin versi eksak, commit `package-lock.yml`):

```yaml
packages:
  - package: dbt-labs/dbt_utils
    version: <pin>
  - package: metaplane/dbt_expectations      # fork aktif dari calogica/dbt_expectations
    version: <pin>
  - package: dbt-labs/audit_helper
    version: <pin>
  - package: elementary-data/elementary
    version: <pin>
```

`profiles.yml` (tanpa secret; kredensial berasal dari ADC/WIF):

```yaml
fnb_data_platform:
  target: dev
  outputs:
    dev:
      type: bigquery
      method: oauth                                   # gcloud auth application-default login
      project: "{{ env_var('GCP_PROJECT_ID') }}"
      dataset: "dbt_{{ env_var('DBT_USER', 'dev') }}"
      location: asia-southeast2
      threads: 4
      priority: interactive
      job_execution_timeout_seconds: 300
      job_retries: 1
      maximum_bytes_billed: 2000000000
    ci:
      type: bigquery
      method: oauth                                   # ADC dari google-github-actions/auth
      project: "{{ env_var('GCP_PROJECT_ID') }}"
      dataset: "dbt_ci_pr{{ env_var('PR_NUMBER', '0') }}"
      location: asia-southeast2
      threads: 4
      job_execution_timeout_seconds: 300
      maximum_bytes_billed: 2000000000
    prod:
      type: bigquery
      method: oauth
      project: "{{ env_var('GCP_PROJECT_ID') }}"
      dataset: analytics                              # fallback; semua model punya custom schema
      location: asia-southeast2
      threads: 8
      job_execution_timeout_seconds: 600
      job_retries: 2
      maximum_bytes_billed: 2000000000
```

### 7.3 Macros

`macros/generate_schema_name.sql`: prod memakai nama dataset persis (`marts`), dev/ci memakai prefix (`dbt_sarif_marts`). Ini memperbaiki temuan A8.

```sql
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- elif target.name == 'prod' -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ target.schema }}_{{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
```

`macros/time.sql`

```sql
{# Satu-satunya titik konversi zona waktu. Input: kolom TIMESTAMP (UTC). #}
{% macro to_local_datetime(column_name) -%}
    datetime({{ column_name }}, '{{ var("local_tz") }}')
{%- endmacro %}

{% macro to_local_date(column_name) -%}
    date({{ column_name }}, '{{ var("local_tz") }}')
{%- endmacro %}
```

`macros/math.sql`

```sql
{# Persentase aman pembagi nol → NULL. Output: angka 0–100, bukan rasio 0–1. #}
{% macro safe_pct(numerator, denominator, digits=2) -%}
    round(safe_divide({{ numerator }}, {{ denominator }}) * 100, {{ digits }})
{%- endmacro %}
```

`macros/pii.sql`: adaptasi blueprint §8 untuk BigQuery. Snowflake masking policy tidak tersedia di free tier BigQuery, jadi PII di-hash di staging. Salt dibaca dari tabel terbatas, sehingga tidak pernah muncul di repo, log, compiled SQL, atau dbt docs.

```sql
{# Hash SHA-256 + salt. NULL tetap NULL (agar tidak semua NULL ter-hash ke nilai yang sama). #}
{% macro hash_pii(column_expr) -%}
    if(
        {{ column_expr }} is null,
        null,
        to_hex(sha256(concat(
            cast({{ column_expr }} as string),
            (select salt from `{{ target.project }}.{{ var('secrets_dataset') }}.pii_salt`)
        )))
    )
{%- endmacro %}
```

### 7.4 Sources

`models/staging/pos/_pos__sources.yml`

```yaml
version: 2

sources:
  - name: pos
    description: OLTP POS & inventori F&B (Neon Postgres, schema fnb), di-ingest dlt ke raw_fnb.
    database: "{{ env_var('GCP_PROJECT_ID') }}"
    schema: raw_fnb
    config:
      loaded_at_field: updated_at
      freshness:                       # default untuk tabel transaksi
        warn_after: {count: 26, period: hour}
        error_after: {count: 50, period: hour}
    tables:
      - name: orders
      - name: order_items
      - name: order_item_modifiers
      - name: payments
      - name: refunds
        config: {freshness: null}      # bisa kosong berhari-hari
      - name: waste_logs
      - name: goods_receipts
        config:
          freshness:
            warn_after: {count: 4, period: day}
      - name: goods_receipt_lines
        config: {freshness: null}
      - name: stock_counts
        config:
          freshness:
            warn_after: {count: 8, period: day}
      - name: stock_count_lines
        config: {freshness: null}
      # master: tanpa freshness
      - {name: outlets, config: {freshness: null}}
      - {name: employees, config: {freshness: null}}
      - {name: customers, config: {freshness: null}}
      - {name: sales_channels, config: {freshness: null}}
      - {name: channel_commission_rates, config: {freshness: null}}
      - {name: promotions, config: {freshness: null}}
      - {name: menu_categories, config: {freshness: null}}
      - {name: menu_items, config: {freshness: null}}
      - {name: menu_item_prices, config: {freshness: null}}
      - {name: modifiers, config: {freshness: null}}
      - {name: modifier_lines, config: {freshness: null}}
      - {name: ingredients, config: {freshness: null}}
      - {name: ingredient_standard_costs, config: {freshness: null}}
      - {name: suppliers, config: {freshness: null}}
      - {name: recipes, config: {freshness: null}}
      - {name: recipe_lines, config: {freshness: null}}
      - {name: waste_reasons, config: {freshness: null}}
      - {name: expense_categories, config: {freshness: null}}
      - {name: operating_expenses, config: {freshness: null}}
```

> Sintaks `config: {loaded_at_field, freshness}` mengikuti dbt ≥ 1.10. Di versi lama, letakkan `loaded_at_field`/`freshness` langsung di level source/table.

### 7.5 Staging (L1 Base: cermin, cast, WIB, hash PII)

Aturan: satu model per tabel, hanya `source()` di layer ini, tanpa join dan tanpa agregasi, kolom waktu diberi suffix `_utc`/`_local`, kolom `_dlt_*` dibuang.

`stg_pos__orders.sql`

```sql
with source as (
    select * from {{ source('pos', 'orders') }}
),

renamed as (
    select
        order_id,
        outlet_id,
        channel_code,
        customer_id,
        cashier_id                                              as cashier_employee_id,
        promo_code,
        external_order_ref,
        ordered_at                                              as ordered_at_utc,
        {{ to_local_datetime('ordered_at') }}                   as ordered_at_local,
        {{ to_local_date('ordered_at') }}                       as order_date,
        extract(hour from {{ to_local_datetime('ordered_at') }}) as order_hour_local,
        order_status,
        {{ to_local_datetime('cancelled_at') }}                 as cancelled_at_local,
        cancel_reason,
        guest_count,
        cast(subtotal_amount as numeric)                        as subtotal_amount,
        cast(item_discount_amount as numeric)                   as item_discount_amount,
        cast(order_discount_amount as numeric)                  as order_discount_amount,
        cast(service_charge_amount as numeric)                  as service_charge_amount,
        cast(tax_amount as numeric)                             as tax_amount,
        cast(total_amount as numeric)                           as total_amount,
        updated_at                                              as updated_at_utc
    from source
)

select * from renamed
```

`stg_pos__order_items.sql`

```sql
with source as (
    select * from {{ source('pos', 'order_items') }}
)

select
    cast(order_item_id as string)               as order_item_id,
    order_id,
    menu_item_id,
    cast(qty as int64)                          as qty,
    cast(unit_price as numeric)                 as unit_price,
    cast(line_discount_amount as numeric)       as line_discount_amount,
    line_status,
    void_reason,
    updated_at                                  as updated_at_utc
from source
```

`stg_pos__customers.sql` (PII: nama dibuang, kontak di-hash, tanggal lahir digeneralisasi)

```sql
with source as (
    select * from {{ source('pos', 'customers') }}
)

select
    customer_id,
    {{ hash_pii('phone_number') }}                  as phone_hash,
    {{ hash_pii('lower(trim(email))') }}            as email_hash,
    extract(year from birth_date)                   as birth_year,
    {{ to_local_datetime('registered_at') }}        as registered_at_local,
    deleted_at is not null                          as is_deleted,
    updated_at                                      as updated_at_utc
from source
```

`stg_pos__employees.sql`: `full_name` dan `phone_number` tidak dipilih. Hanya `employee_id`, `outlet_id`, `job_role`, `hired_date`, `terminated_date` yang dibawa. Tim operasional melihat nama staf di POS, bukan di BI.

Model staging lain mengikuti pola yang sama: rename `id`, cast numerik, konversi waktu, dan `deleted_at is not null as is_deleted`. Untuk tabel effective-dated, `effective_to` dibiarkan NULL (konsumen memakai `coalesce(effective_to, date '9999-12-31')`). Kolom turunan yang dipakai model hilir:

| Model staging | Kolom turunan / rename |
|---|---|
| `stg_pos__order_item_modifiers` | `cast(order_item_id as string)` (agar join ke `stg_pos__order_items` bertipe sama) |
| `stg_pos__waste_logs` | `logged_at_local`, `waste_date` (WIB), `recorded_by` → `recorded_by_employee_id` |
| `stg_pos__refunds` | `refunded_at_local`, `refund_date` (WIB), `cast(order_item_id as string)` |
| `stg_pos__goods_receipts` | `received_at_local`, `received_date` (WIB) |
| `stg_pos__payments` | `paid_at_local`, `paid_date` (WIB) |
| `stg_pos__stock_counts` / `_lines` | `counted_by` → `counted_by_employee_id` |

### 7.6 Strategi PII (adaptasi blueprint §8 ke BigQuery free)

| Lapisan | Kontrol |
|---|---|
| Raw (`raw_fnb`) | Hanya `sa-ingest` (tulis) & `sa-dbt`/`sa-github-ci` (baca). Tidak bisa diakses BI maupun Apps Script |
| Staging | PII di-hash (`hash_pii`) atau dibuang; tanggal lahir → tahun |
| Core/Marts | Tidak ada kolom PII mentah; join memakai `customer_id` (surrogate), bukan email/telepon |
| CI guard | `scripts/check_pii_columns.py` gagal jika ada kolom PII di YAML staging/core/marts tanpa `meta.pii: hashed|generalized|dropped` |
| Docs | Salt di tabel `ops_secrets`, bukan `vars`/env, sehingga aman dipublish ke GitHub Pages |

`scripts/check_pii_columns.py`

```python
"""Gagal jika kolom bernama mirip PII tidak ditandai meta.pii di YAML model."""
import pathlib
import re
import sys

import yaml

PII = re.compile(r"(email|phone|telp|full_name|address|alamat|birth|nik|account_number)", re.I)
ALLOWED = {"hashed", "generalized", "dropped"}

bad = []
for path in pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "models").rglob("*.yml"):
    doc = yaml.safe_load(path.read_text()) or {}
    for model in doc.get("models", []):
        for col in model.get("columns", []):
            meta = (col.get("config") or {}).get("meta") or col.get("meta") or {}
            if PII.search(col["name"]) and meta.get("pii") not in ALLOWED:
                bad.append(f"{path}: {model['name']}.{col['name']}")

print("\n".join(bad) or "PII guard OK")
sys.exit(1 if bad else 0)
```

### 7.7 Utilities & intermediate (costing engine)

`models/utilities/util_dates.sql`

```sql
with spine as (
    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('2024-01-01' as date)",
        end_date="cast('2031-01-01' as date)"
    ) }}
)

select cast(date_day as date) as date_day
from spine
```

`models/intermediate/costing/int_item_explosion_daily.sql`: inti HPP. Model ini mengurai **menu, modifier, prep item, dan bahan raw** menjadi kebutuhan bahan raw per 1 unit, memakai versi resep yang berlaku pada setiap tanggal. Grain harian membuat join effective-dated tetap sederhana dan benar. Ukurannya sekitar 470 hari × ±350 kombinasi item-bahan, sehingga kurang dari 200 ribu baris.

```sql
/*
  Grain   : date_day x item_type x item_id x ingredient_id (bahan raw)
  item_type: 'Menu Item' | 'Modifier' | 'Prep Item' | 'Ingredient'
  Rumus   : qty bruto per unit = qty_per_yield / (1 - loss_pct/100) / yield_qty
  Asumsi  : prep item hanya tersusun dari bahan raw (dijaga test assert_prep_recipes_only_raw)
*/
with dates as (
    select date_day
    from {{ ref('util_dates') }}
    where date_day between {{ var('start_date') }} and current_date('{{ var("local_tz") }}')
),

ingredients as (
    select * from {{ ref('stg_pos__ingredients') }}
),

recipes as (
    select * from {{ ref('stg_pos__recipes') }}
),

recipe_lines as (
    select * from {{ ref('stg_pos__recipe_lines') }}
),

modifier_lines as (
    select * from {{ ref('stg_pos__modifier_lines') }}
),

recipe_lines_on_day as (
    select
        d.date_day,
        if(r.menu_item_id is not null, 'Menu Item', 'Prep Item')      as item_type,
        coalesce(r.menu_item_id, r.prep_ingredient_id)                 as item_id,
        rl.ingredient_id                                               as component_id,
        rl.qty_per_yield / (1 - rl.loss_pct / 100) / r.yield_qty       as qty_per_unit
    from dates as d
    inner join recipes as r
        on d.date_day >= r.effective_from
       and d.date_day <  coalesce(r.effective_to, date '9999-12-31')
    inner join recipe_lines as rl
        on rl.recipe_id = r.recipe_id
),

modifier_lines_on_day as (
    select
        d.date_day,
        'Modifier'          as item_type,
        ml.modifier_id      as item_id,
        ml.ingredient_id    as component_id,
        ml.qty_delta        as qty_per_unit
    from dates as d
    cross join modifier_lines as ml
),

first_level as (
    select * from recipe_lines_on_day
    union all
    select * from modifier_lines_on_day
),

prep_to_raw as (
    select date_day, item_id as prep_id, component_id as raw_id, qty_per_unit
    from recipe_lines_on_day
    where item_type = 'Prep Item'
),

exploded as (
    -- 1) komponen raw langsung
    select f.date_day, f.item_type, f.item_id, f.component_id as ingredient_id, f.qty_per_unit
    from first_level as f
    inner join ingredients as i
        on i.ingredient_id = f.component_id
       and not i.is_prep_item

    union all

    -- 2) komponen prep diurai ke bahan raw
    select f.date_day, f.item_type, f.item_id, p.raw_id, f.qty_per_unit * p.qty_per_unit
    from first_level as f
    inner join prep_to_raw as p
        on p.date_day = f.date_day
       and p.prep_id = f.component_id

    union all

    -- 3) bahan raw sebagai dirinya sendiri (untuk valuasi waste & stock)
    select d.date_day, 'Ingredient', i.ingredient_id, i.ingredient_id, cast(1 as numeric)
    from dates as d
    cross join ingredients as i
    where not i.is_prep_item
)

select
    date_day,
    item_type,
    item_id,
    ingredient_id,
    sum(qty_per_unit) as qty_per_unit
from exploded
group by 1, 2, 3, 4
```

`models/intermediate/costing/int_item_std_cost_daily.sql`

```sql
/*
  Grain  : date_day x item_type x item_id
  Isi    : standard cost per 1 unit item = Σ qty bahan raw × standard cost bahan yang berlaku hari itu
  Kontrol: n_components_missing_cost wajib 0 (test) → mencegah HPP diam-diam terlalu rendah
*/
with explosion as (
    select * from {{ ref('int_item_explosion_daily') }}
),

costs as (
    select * from {{ ref('stg_pos__ingredient_standard_costs') }}
)

select
    e.date_day,
    e.item_type,
    e.item_id,
    sum(e.qty_per_unit * c.standard_cost_per_base_uom)  as std_cost_per_unit,
    count(*)                                            as n_components,
    countif(c.ingredient_id is null)                    as n_components_missing_cost
from explosion as e
left join costs as c
    on c.ingredient_id = e.ingredient_id
   and e.date_day >= c.effective_from
   and e.date_day <  coalesce(c.effective_to, date '9999-12-31')
group by 1, 2, 3
```

### 7.8 Core (L2 Dim & Fact)

**Dimensi** (materialized table, 1 baris per entitas):

| Model | Isi utama |
|---|---|
| `dim_date` | dari `util_dates` + `day_of_week`, `is_weekend`, `iso_week`, `is_payday_window` (tgl ≥ 25 atau = 1), `calendar_event` & `is_ramadan` (join seed `id_calendar_events`) |
| `dim_outlet` | atribut outlet + `is_active`, `operating_days_to_date` |
| `dim_menu_item` | menu + kategori + `current_offline_price`, `current_online_price`, `current_std_cost`, `current_food_cost_pct` |
| `dim_ingredient` | bahan + `current_std_cost`, `is_prep_item` |
| `dim_channel` | kanal + `current_commission_pct` |

**`fct_order_lines.sql`**: fact utama, incremental per partisi tanggal.

```sql
{{
  config(
    materialized = 'incremental',
    incremental_strategy = 'insert_overwrite',
    partition_by = {'field': 'order_date', 'data_type': 'date', 'granularity': 'day'},
    cluster_by = ['outlet_id', 'menu_item_id'],
    on_schema_change = 'append_new_columns',
    tags = ['finance', 'daily']
  )
}}
/*
  Grain   : 1 baris = 1 order_item_id
  Aturan  : is_revenue_line = order Completed AND line Served
            diskon level order dialokasikan pro-rata ke gross line revenue
            diskon yang didanai Platform TIDAK mengurangi net sales merchant
            COGS standar = qty × (std cost menu + std cost modifier) pada tanggal order
  Refresh : insert_overwrite partisi order_date ≥ max partisi − lookback_days; full refresh mingguan
*/
with orders as (
    select *
    from {{ ref('stg_pos__orders') }}
    {% if is_incremental() %}
    where order_date >= date_sub(_dbt_max_partition, interval {{ var('lookback_days') }} day)
    {% endif %}
),

items as (
    select * from {{ ref('stg_pos__order_items') }}
),

item_costs as (
    select * from {{ ref('int_item_std_cost_daily') }}
),

modifiers as (
    select
        m.order_item_id,
        sum(m.price_delta)                          as modifier_price_per_unit,
        sum(coalesce(c.std_cost_per_unit, 0))       as modifier_cost_per_unit
    from {{ ref('stg_pos__order_item_modifiers') }} as m
    inner join items as i on i.order_item_id = m.order_item_id
    inner join orders as o on o.order_id = i.order_id
    left join item_costs as c
        on c.item_type = 'Modifier'
       and c.item_id = m.modifier_id
       and c.date_day = o.order_date
    group by 1
),

promotions as (
    select promo_code, funded_by from {{ ref('stg_pos__promotions') }}
),

lines as (
    select
        i.order_item_id,
        i.order_id,
        o.order_date,
        o.ordered_at_local,
        o.outlet_id,
        o.channel_code,
        o.customer_id,
        i.menu_item_id,
        o.order_status,
        i.line_status,
        o.order_status = 'Completed' and i.line_status = 'Served'           as is_revenue_line,
        i.qty,
        i.unit_price,
        coalesce(m.modifier_price_per_unit, 0)                              as modifier_price_per_unit,
        i.qty * (i.unit_price + coalesce(m.modifier_price_per_unit, 0))     as gross_sales_amount,
        i.line_discount_amount,
        o.order_discount_amount,
        coalesce(p.funded_by, 'Merchant')                                   as order_discount_funded_by,
        mc.std_cost_per_unit + coalesce(m.modifier_cost_per_unit, 0)        as std_cost_per_unit
    from items as i
    inner join orders as o on o.order_id = i.order_id
    left join modifiers as m on m.order_item_id = i.order_item_id
    left join promotions as p on p.promo_code = o.promo_code
    left join item_costs as mc
        on mc.item_type = 'Menu Item'
       and mc.item_id = i.menu_item_id
       and mc.date_day = o.order_date
),

allocated as (
    select
        *,
        if(
            is_revenue_line,
            coalesce(order_discount_amount * safe_divide(
                gross_sales_amount,
                sum(if(is_revenue_line, gross_sales_amount, 0)) over (partition by order_id)
            ), 0),
            0
        ) as allocated_order_discount_amount
    from lines
),

final as (
    select
        *,
        if(is_revenue_line,
           line_discount_amount
           + if(order_discount_funded_by = 'Merchant', allocated_order_discount_amount, 0),
           0)                                                               as merchant_discount_amount,
        if(order_discount_funded_by = 'Platform', allocated_order_discount_amount, 0)
                                                                            as platform_funded_discount_amount
    from allocated
)

select
    order_item_id,
    order_id,
    order_date,
    ordered_at_local,
    outlet_id,
    channel_code,
    customer_id,
    menu_item_id,
    order_status,
    line_status,
    is_revenue_line,
    qty,
    unit_price,
    modifier_price_per_unit,
    gross_sales_amount,
    line_discount_amount,
    allocated_order_discount_amount,
    order_discount_funded_by,
    merchant_discount_amount,
    platform_funded_discount_amount,
    if(is_revenue_line, gross_sales_amount - merchant_discount_amount, 0)  as net_sales_amount,
    std_cost_per_unit,
    if(is_revenue_line, qty * std_cost_per_unit, 0)                        as cogs_std_amount
from final
```

**`fct_orders.sql`**: grain order. Berisi komisi kanal effective-dated dan biaya MDR.

```sql
with orders as (
    select * from {{ ref('stg_pos__orders') }}
),

lines as (
    select
        order_id,
        sum(gross_sales_amount)     as gross_sales_amount,
        sum(merchant_discount_amount) as merchant_discount_amount,
        sum(net_sales_amount)       as net_sales_amount,
        sum(cogs_std_amount)        as cogs_std_amount,
        sum(qty)                    as units
    from {{ ref('fct_order_lines') }}
    where is_revenue_line
    group by 1
),

payments as (
    select
        order_id,
        sum(amount)                                                 as paid_amount,
        sum(mdr_fee_amount)                                         as payment_fee_amount,
        string_agg(distinct payment_method order by payment_method) as payment_methods
    from {{ ref('stg_pos__payments') }}
    group by 1
),

rates as (
    select * from {{ ref('stg_pos__channel_commission_rates') }}
)

select
    o.order_id,
    o.order_date,
    o.ordered_at_local,
    o.order_hour_local,
    o.outlet_id,
    o.channel_code,
    o.customer_id,
    o.promo_code,
    o.order_status,
    o.guest_count,
    coalesce(l.gross_sales_amount, 0)                               as gross_sales_amount,
    coalesce(l.merchant_discount_amount, 0)                         as merchant_discount_amount,
    coalesce(l.net_sales_amount, 0)                                 as net_sales_amount,
    coalesce(l.cogs_std_amount, 0)                                  as cogs_std_amount,
    coalesce(l.units, 0)                                            as units,
    o.service_charge_amount,
    o.tax_amount,
    o.total_amount,
    coalesce(p.paid_amount, 0)                                      as paid_amount,
    coalesce(p.payment_fee_amount, 0)                               as payment_fee_amount,
    p.payment_methods,
    coalesce(r.commission_pct, 0)                                   as commission_pct,
    if(o.order_status = 'Completed',
       coalesce(l.net_sales_amount, 0) * coalesce(r.commission_pct, 0) / 100,
       0)                                                           as channel_commission_amount
from orders as o
left join lines as l on l.order_id = o.order_id
left join payments as p on p.order_id = o.order_id
left join rates as r
    on r.channel_code = o.channel_code
   and o.order_date >= r.effective_from
   and o.order_date <  coalesce(r.effective_to, date '9999-12-31')
```

**`fct_waste.sql`**: grain `waste_id`, divaluasi dengan standard cost pada tanggal waste.

```sql
with waste as (
    select * from {{ ref('stg_pos__waste_logs') }}
),

ingredients as (
    select ingredient_id, is_prep_item from {{ ref('stg_pos__ingredients') }}
),

typed as (
    select
        w.*,
        case
            when w.menu_item_id is not null then 'Menu Item'
            when i.is_prep_item then 'Prep Item'
            else 'Ingredient'
        end                                         as item_type,
        coalesce(w.menu_item_id, w.ingredient_id)   as item_id
    from waste as w
    left join ingredients as i on i.ingredient_id = w.ingredient_id
)

select
    t.waste_id,
    t.waste_date,
    t.logged_at_local,
    t.outlet_id,
    t.item_type,
    t.item_id,
    t.qty,
    t.reason_code,
    r.reason_name,
    r.controllability,
    t.recorded_by_employee_id,
    c.std_cost_per_unit                     as unit_std_cost,
    t.qty * c.std_cost_per_unit             as waste_cost_amount
from typed as t
left join {{ ref('stg_pos__waste_reasons') }} as r on r.reason_code = t.reason_code
left join {{ ref('int_item_std_cost_daily') }} as c
    on c.date_day = t.waste_date
   and c.item_type = t.item_type
   and c.item_id = t.item_id
```

**`fct_inventory_movements_daily.sql`**: grain outlet × tanggal × bahan raw. Berisi pembelian, pemakaian teoritis dari penjualan (menu + modifier), dan waste yang diurai ke bahan raw.

```sql
with explosion as (
    select * from {{ ref('int_item_explosion_daily') }}
),

sales_lines as (
    select order_item_id, order_date, outlet_id, menu_item_id, qty
    from {{ ref('fct_order_lines') }}
    where is_revenue_line
),

sales_usage as (
    select l.outlet_id, l.order_date as movement_date, x.ingredient_id, l.qty * x.qty_per_unit as qty
    from sales_lines as l
    inner join explosion as x
        on x.date_day = l.order_date and x.item_type = 'Menu Item' and x.item_id = l.menu_item_id

    union all

    select l.outlet_id, l.order_date, x.ingredient_id, l.qty * x.qty_per_unit
    from sales_lines as l
    inner join {{ ref('stg_pos__order_item_modifiers') }} as m on m.order_item_id = l.order_item_id
    inner join explosion as x
        on x.date_day = l.order_date and x.item_type = 'Modifier' and x.item_id = m.modifier_id
),

waste_usage as (
    select w.outlet_id, w.waste_date as movement_date, x.ingredient_id, w.qty * x.qty_per_unit as qty
    from {{ ref('fct_waste') }} as w
    inner join explosion as x
        on x.date_day = w.waste_date and x.item_type = w.item_type and x.item_id = w.item_id
),

purchases as (
    select outlet_id, received_date as movement_date, ingredient_id, qty_base_uom as qty, line_amount
    from {{ ref('fct_goods_receipt_lines') }}
),

unioned as (
    select outlet_id, movement_date, ingredient_id,
           qty as theoretical_sales_qty, cast(0 as numeric) as waste_qty,
           cast(0 as numeric) as purchased_qty, cast(0 as numeric) as purchased_amount
    from sales_usage
    union all
    select outlet_id, movement_date, ingredient_id, 0, qty, 0, 0
    from waste_usage
    union all
    select outlet_id, movement_date, ingredient_id, 0, 0, qty, line_amount
    from purchases
)

select
    outlet_id,
    movement_date,
    ingredient_id,
    sum(theoretical_sales_qty)  as theoretical_sales_qty,
    sum(waste_qty)              as waste_qty,
    sum(purchased_qty)          as purchased_qty,
    sum(purchased_amount)       as purchased_amount
from unioned
group by 1, 2, 3
```

**`fct_opex_allocated_monthly.sql`**: grain bulan × outlet × pnl_line. Biaya HQ (`outlet_id` NULL) dialokasikan berdasarkan pangsa net sales, atau dibagi rata jika total sales bulan itu 0. Prorata harian memakai jumlah **hari aktif outlet** dalam bulan, sehingga total bulanan selalu tereskonsiliasi.

```sql
with opex as (
    select e.period_month, e.outlet_id, c.pnl_line, sum(e.amount) as amount
    from {{ ref('stg_pos__operating_expenses') }} as e
    inner join {{ ref('stg_pos__expense_categories') }} as c on c.category_code = e.category_code
    group by 1, 2, 3
),

outlet_months as (
    select
        date_trunc(d.date_day, month)   as period_month,
        o.outlet_id,
        count(*)                        as active_days_in_month
    from {{ ref('util_dates') }} as d
    inner join {{ ref('stg_pos__outlets') }} as o
        on d.date_day between o.opened_date and coalesce(o.closed_date, date '9999-12-31')
    where d.date_day >= {{ var('start_date') }}
      and d.date_day <= last_day(current_date('{{ var("local_tz") }}'), month)
    group by 1, 2
),

sales_months as (
    select date_trunc(order_date, month) as period_month, outlet_id, sum(net_sales_amount) as net_sales
    from {{ ref('fct_order_lines') }}
    where is_revenue_line
    group by 1, 2
),

basis as (
    select
        om.period_month,
        om.outlet_id,
        om.active_days_in_month,
        coalesce(sm.net_sales, 0)                                           as net_sales,
        count(*) over (partition by om.period_month)                        as n_outlets,
        sum(coalesce(sm.net_sales, 0)) over (partition by om.period_month)  as total_net_sales
    from outlet_months as om
    left join sales_months as sm
        on sm.period_month = om.period_month and sm.outlet_id = om.outlet_id
),

direct_cost as (
    select b.period_month, b.outlet_id, o.pnl_line, o.amount as allocated_amount,
           b.active_days_in_month, 'Direct' as allocation_type
    from opex as o
    inner join basis as b on b.period_month = o.period_month and b.outlet_id = o.outlet_id
),

shared_cost as (
    select
        b.period_month,
        b.outlet_id,
        o.pnl_line,
        o.amount * coalesce(safe_divide(b.net_sales, b.total_net_sales), 1 / b.n_outlets) as allocated_amount,
        b.active_days_in_month,
        'HQ Allocation' as allocation_type
    from opex as o
    inner join basis as b on b.period_month = o.period_month
    where o.outlet_id is null
)

select * from direct_cost
union all
select * from shared_cost
```

Fact lain (pola sederhana, 1 baris per baris sumber): `fct_refunds` (grain refund, `refund_date` WIB), `fct_goods_receipt_lines` (join header untuk `outlet_id`, `received_date`, `unit_cost = line_amount / qty_base_uom`), `fct_stock_counts` (grain count × bahan).

### 7.9 Marts (L3)

**`mart_pnl_daily.sql`**: grain outlet × tanggal untuk semua hari outlet aktif (memperbaiki D1).

```sql
{{ config(
    partition_by = {'field': 'report_date', 'data_type': 'date', 'granularity': 'month'},
    cluster_by = ['outlet_id'],
    tags = ['finance', 'mart']
) }}
/*
  Tujuan : P&L harian per outlet berbasis STANDARD cost (theoretical)
  Grain  : 1 baris = outlet_id x report_date (semua hari outlet aktif, termasuk tanpa transaksi)
  Rumus  : net_sales          = gross_sales − merchant_discounts − refunds (refund dicatat di tanggal refund)
           cost_of_sales      = cogs_standard + waste_cost
           gross_profit       = net_sales − cost_of_sales
           contribution       = gross_profit − channel_commission − payment_fees
           outlet_ebitda      = contribution − labor_cost − other_opex   (tanpa D&A)
  Catatan: variance stock opname hanya ada di mart_pnl_monthly (stock count periodik)
*/
with outlet_days as (
    select d.date_day as report_date, o.outlet_id
    from {{ ref('util_dates') }} as d
    inner join {{ ref('stg_pos__outlets') }} as o
        on d.date_day between o.opened_date
                          and coalesce(o.closed_date, current_date('{{ var("local_tz") }}'))
    where d.date_day >= {{ var('start_date') }}
      and d.date_day <= current_date('{{ var("local_tz") }}')
),

sales as (
    select
        order_date                      as report_date,
        outlet_id,
        sum(gross_sales_amount)         as gross_sales,
        sum(merchant_discount_amount)   as discounts,
        sum(cogs_std_amount)            as cogs_standard,
        sum(qty)                        as units_sold
    from {{ ref('fct_order_lines') }}
    where is_revenue_line
    group by 1, 2
),

orders as (
    select
        order_date                          as report_date,
        outlet_id,
        count(*)                            as order_count,
        sum(channel_commission_amount)      as channel_commission,
        sum(payment_fee_amount)             as payment_fees
    from {{ ref('fct_orders') }}
    where order_status = 'Completed'
    group by 1, 2
),

refunds as (
    select refund_date as report_date, outlet_id, sum(refund_amount) as refunds
    from {{ ref('fct_refunds') }}
    group by 1, 2
),

waste as (
    select waste_date as report_date, outlet_id, sum(waste_cost_amount) as waste_cost
    from {{ ref('fct_waste') }}
    group by 1, 2
),

opex_daily as (
    select
        period_month,
        outlet_id,
        sum(if(pnl_line = 'Labor', allocated_amount, 0)) / any_value(active_days_in_month)   as labor_cost,
        sum(if(pnl_line != 'Labor', allocated_amount, 0)) / any_value(active_days_in_month)  as other_opex
    from {{ ref('fct_opex_allocated_monthly') }}
    group by 1, 2
),

joined as (
    select
        od.report_date,
        date_trunc(od.report_date, month)                                   as report_month,
        od.outlet_id,
        coalesce(o.order_count, 0)                                          as order_count,
        coalesce(s.units_sold, 0)                                           as units_sold,
        coalesce(s.gross_sales, 0)                                          as gross_sales,
        coalesce(s.discounts, 0)                                            as discounts,
        coalesce(r.refunds, 0)                                              as refunds,
        coalesce(s.gross_sales, 0) - coalesce(s.discounts, 0) - coalesce(r.refunds, 0) as net_sales,
        coalesce(s.cogs_standard, 0)                                        as cogs_standard,
        coalesce(w.waste_cost, 0)                                           as waste_cost,
        coalesce(o.channel_commission, 0)                                   as channel_commission,
        coalesce(o.payment_fees, 0)                                         as payment_fees,
        coalesce(x.labor_cost, 0)                                           as labor_cost,
        coalesce(x.other_opex, 0)                                           as other_opex
    from outlet_days as od
    left join sales as s on s.report_date = od.report_date and s.outlet_id = od.outlet_id
    left join orders as o on o.report_date = od.report_date and o.outlet_id = od.outlet_id
    left join refunds as r on r.report_date = od.report_date and r.outlet_id = od.outlet_id
    left join waste as w on w.report_date = od.report_date and w.outlet_id = od.outlet_id
    left join opex_daily as x
        on x.outlet_id = od.outlet_id
       and x.period_month = date_trunc(od.report_date, month)
),

calc as (
    select
        *,
        cogs_standard + waste_cost                                              as cost_of_sales,
        net_sales - cogs_standard - waste_cost                                  as gross_profit,
        net_sales - cogs_standard - waste_cost - channel_commission - payment_fees
                                                                                as contribution_after_channel,
        net_sales - cogs_standard - waste_cost - channel_commission - payment_fees
            - labor_cost - other_opex                                           as outlet_ebitda
    from joined
)

select
    *,
    {{ safe_pct('cost_of_sales', 'net_sales') }}                as food_cost_pct,
    {{ safe_pct('waste_cost', 'net_sales') }}                   as waste_pct,
    {{ safe_pct('cost_of_sales + labor_cost', 'net_sales') }}   as prime_cost_pct,
    {{ safe_pct('gross_profit', 'net_sales') }}                 as gross_margin_pct,
    {{ safe_pct('outlet_ebitda', 'net_sales') }}                as ebitda_margin_pct,
    safe_divide(net_sales, nullif(order_count, 0))              as avg_order_value
from calc
```

**`mart_inventory_variance.sql`**: theoretical vs actual usage per periode stock count. Ini KPI pengendalian biaya paling penting di F&B dan sebelumnya tidak mungkin dihitung (S2).

```sql
/*
  Grain  : outlet_id x ingredient_id x periode (period_start, period_end] antar dua stock count berurutan
  Rumus  : actual_usage   = opening + purchased − closing
           unexplained    = actual_usage − theoretical_sales − recorded_waste
           (> 0 = shrinkage: over-portioning, waste tidak dicatat, pencurian, salah input)
*/
with counts as (
    select outlet_id, ingredient_id, count_date, counted_qty_base
    from {{ ref('fct_stock_counts') }}
),

periods as (
    select
        outlet_id,
        ingredient_id,
        lag(count_date) over w          as period_start,
        count_date                      as period_end,
        lag(counted_qty_base) over w    as opening_qty,
        counted_qty_base                as closing_qty
    from counts
    window w as (partition by outlet_id, ingredient_id order by count_date)
),

period_movements as (
    select
        p.outlet_id,
        p.ingredient_id,
        p.period_end,
        sum(coalesce(m.purchased_qty, 0))           as purchased_qty,
        sum(coalesce(m.purchased_amount, 0))        as purchased_amount,
        sum(coalesce(m.theoretical_sales_qty, 0))   as theoretical_sales_qty,
        sum(coalesce(m.waste_qty, 0))               as recorded_waste_qty
    from periods as p
    left join {{ ref('fct_inventory_movements_daily') }} as m
        on m.outlet_id = p.outlet_id
       and m.ingredient_id = p.ingredient_id
       and m.movement_date > p.period_start
       and m.movement_date <= p.period_end
    where p.period_start is not null
    group by 1, 2, 3
),

costs as (
    select date_day, item_id as ingredient_id, std_cost_per_unit
    from {{ ref('int_item_std_cost_daily') }}
    where item_type = 'Ingredient'
),

calc as (
    select
        p.outlet_id,
        p.ingredient_id,
        p.period_start,
        p.period_end,
        p.opening_qty,
        pm.purchased_qty,
        pm.purchased_amount,
        p.closing_qty,
        p.opening_qty + pm.purchased_qty - p.closing_qty                    as actual_usage_qty,
        pm.theoretical_sales_qty,
        pm.recorded_waste_qty,
        p.opening_qty + pm.purchased_qty - p.closing_qty
            - pm.theoretical_sales_qty - pm.recorded_waste_qty              as unexplained_variance_qty,
        c.std_cost_per_unit
    from periods as p
    inner join period_movements as pm
        on pm.outlet_id = p.outlet_id
       and pm.ingredient_id = p.ingredient_id
       and pm.period_end = p.period_end
    left join costs as c
        on c.ingredient_id = p.ingredient_id
       and c.date_day = p.period_end
)

select
    {{ dbt_utils.generate_surrogate_key(['outlet_id', 'ingredient_id', 'period_end']) }} as inventory_period_key,
    *,
    unexplained_variance_qty * std_cost_per_unit                                         as unexplained_variance_value,
    theoretical_sales_qty * std_cost_per_unit                                            as theoretical_usage_value,
    {{ safe_pct('unexplained_variance_qty', 'theoretical_sales_qty') }}                  as unexplained_variance_pct
from calc
```

**`mart_pnl_monthly.sql`**: grain outlet × bulan. Di sini **actual cost** = standard + waste + variance stock opname (memenuhi janji "standard vs actual" di v1).

```sql
with daily as (
    select * from {{ ref('mart_pnl_daily') }}
),

variance as (
    select
        outlet_id,
        date_trunc(period_end, month)       as report_month,
        sum(unexplained_variance_value)     as inventory_variance_cost
    from {{ ref('mart_inventory_variance') }}
    group by 1, 2
),

monthly as (
    select
        report_month,
        outlet_id,
        count(*)                        as reported_days,
        sum(order_count)                as order_count,
        sum(gross_sales)                as gross_sales,
        sum(discounts)                  as discounts,
        sum(refunds)                    as refunds,
        sum(net_sales)                  as net_sales,
        sum(cogs_standard)              as cogs_standard,
        sum(waste_cost)                 as waste_cost,
        sum(channel_commission)         as channel_commission,
        sum(payment_fees)               as payment_fees,
        sum(labor_cost)                 as labor_cost,
        sum(other_opex)                 as other_opex
    from daily
    group by 1, 2
),

calc as (
    select
        m.*,
        report_month < date_trunc(current_date('{{ var("local_tz") }}'), month)    as is_complete_month,
        coalesce(v.inventory_variance_cost, 0)                                      as inventory_variance_cost,
        m.cogs_standard + m.waste_cost                                              as theoretical_cost_of_sales,
        m.cogs_standard + m.waste_cost + coalesce(v.inventory_variance_cost, 0)     as actual_cost_of_sales
    from monthly as m
    left join variance as v on v.outlet_id = m.outlet_id and v.report_month = m.report_month
),

pnl as (
    select
        *,
        net_sales - actual_cost_of_sales                                            as gross_profit,
        net_sales - actual_cost_of_sales - channel_commission - payment_fees
            - labor_cost - other_opex                                               as outlet_ebitda
    from calc
)

select
    *,
    {{ safe_pct('theoretical_cost_of_sales', 'net_sales') }}        as theoretical_food_cost_pct,
    {{ safe_pct('actual_cost_of_sales', 'net_sales') }}             as food_cost_pct,
    {{ safe_pct('waste_cost', 'net_sales') }}                       as waste_pct,
    {{ safe_pct('inventory_variance_cost', 'net_sales') }}          as inventory_variance_pct,
    {{ safe_pct('actual_cost_of_sales + labor_cost', 'net_sales') }} as prime_cost_pct,
    {{ safe_pct('gross_profit', 'net_sales') }}                     as gross_margin_pct,
    {{ safe_pct('channel_commission', 'net_sales') }}               as channel_cost_pct,
    {{ safe_pct('outlet_ebitda', 'net_sales') }}                    as ebitda_margin_pct
from pnl
```

**`mart_kpi_monthly_status.sql`**: threshold dari seed (satu sumber kebenaran untuk Sheets & dashboard Vercel).

```sql
with kpi as (
    select report_month, outlet_id, is_complete_month, metric_code, metric_value
    from {{ ref('mart_pnl_monthly') }}
    unpivot (metric_value for metric_code in (
        food_cost_pct, waste_pct, prime_cost_pct, gross_margin_pct, inventory_variance_pct, channel_cost_pct
    ))
),

thresholds as (
    select * from {{ ref('kpi_thresholds') }}
)

select
    k.report_month,
    k.outlet_id,
    k.is_complete_month,
    k.metric_code,
    t.metric_name,
    t.direction,
    k.metric_value,
    t.warn_threshold,
    t.critical_threshold,
    case
        when t.direction = 'higher_is_worse' and k.metric_value >= t.critical_threshold then 'CRITICAL'
        when t.direction = 'higher_is_worse' and k.metric_value >= t.warn_threshold     then 'WARN'
        when t.direction = 'lower_is_worse'  and k.metric_value <= t.critical_threshold then 'CRITICAL'
        when t.direction = 'lower_is_worse'  and k.metric_value <= t.warn_threshold     then 'WARN'
        else 'OK'
    end as status
from kpi as k
inner join thresholds as t
    on t.metric_code = k.metric_code
   and k.report_month >= t.effective_from
   and k.report_month <  coalesce(t.effective_to, date '9999-12-31')
```

**`mart_menu_engineering.sql`**: Kasavana-Smith (memperbaiki D5).

```sql
/*
  Grain : outlet_id x report_month x menu_item_id
  Popularitas tinggi : menu_mix_pct ≥ 70% × (1 / jumlah item terjual)
  Profitabilitas tinggi: avg contribution margin ≥ CM rata-rata tertimbang outlet-bulan
  Kelas: Star (tinggi/tinggi), Plowhorse (populer, CM rendah), Puzzle (CM tinggi, kurang populer), Dog
*/
with lines as (
    select
        outlet_id,
        date_trunc(order_date, month)   as report_month,
        menu_item_id,
        sum(qty)                        as qty_sold,
        sum(net_sales_amount)           as net_sales,
        sum(cogs_std_amount)            as cogs_standard
    from {{ ref('fct_order_lines') }}
    where is_revenue_line
    group by 1, 2, 3
),

calc as (
    select
        *,
        safe_divide(net_sales - cogs_standard, qty_sold)                                    as avg_contribution_margin,
        safe_divide(qty_sold, sum(qty_sold) over (partition by outlet_id, report_month))    as menu_mix_pct,
        count(*) over (partition by outlet_id, report_month)                                as n_items_sold,
        safe_divide(
            sum(net_sales - cogs_standard) over (partition by outlet_id, report_month),
            sum(qty_sold) over (partition by outlet_id, report_month)
        )                                                                                   as weighted_avg_cm
    from lines
),

flags as (
    select
        *,
        menu_mix_pct >= 0.7 / n_items_sold          as is_high_popularity,
        avg_contribution_margin >= weighted_avg_cm  as is_high_profitability
    from calc
)

select
    f.*,
    case
        when is_high_popularity and is_high_profitability then 'Star'
        when is_high_popularity then 'Plowhorse'
        when is_high_profitability then 'Puzzle'
        else 'Dog'
    end                                                         as menu_class,
    d.menu_name,
    d.category_name
from flags as f
left join {{ ref('dim_menu_item') }} as d on d.menu_item_id = f.menu_item_id
```

Mart lain:
- `mart_waste_analysis`: grain `outlet_id` × `waste_date` × `reason_code` × `item_category`, dengan `reason_name`, `controllability`, `waste_qty`, `waste_cost`, dan `waste_pct_of_sales` (join `mart_pnl_daily`).
- `mart_channel_performance_daily`: grain outlet × tanggal × kanal, dengan net sales, komisi, diskon yang didanai platform, `contribution_after_channel`, dan AOV.

### 7.10 Seeds

`seeds/kpi_thresholds.csv` (perubahan threshold ditambahkan sebagai baris baru dengan `effective_from` baru, tanpa mengedit baris lama):

```csv
metric_code,metric_name,direction,warn_threshold,critical_threshold,effective_from,effective_to
food_cost_pct,Food Cost %,higher_is_worse,32,35,2025-01-01,
waste_pct,Waste to Sales %,higher_is_worse,2,3,2025-01-01,
prime_cost_pct,Prime Cost %,higher_is_worse,60,65,2025-01-01,
gross_margin_pct,Gross Margin %,lower_is_worse,65,60,2025-01-01,
inventory_variance_pct,Unexplained Inventory Variance %,higher_is_worse,1,2,2025-01-01,
channel_cost_pct,Channel Commission %,higher_is_worse,10,13,2025-01-01,
```

`seeds/id_calendar_events.csv` (contoh. Verifikasi tanggal dengan SKB libur nasional dan kalender hijriah resmi):

```csv
event_name,event_type,start_date,end_date
Ramadan 1446H,Ramadan,2025-03-01,2025-03-30
Idul Fitri 1446H,Holiday,2025-03-31,2025-04-01
Ramadan 1447H,Ramadan,2026-02-18,2026-03-19
Idul Fitri 1447H,Holiday,2026-03-20,2026-03-21
```

`seeds/_seeds.yml` mendefinisikan `column_types` eksplisit (`warn_threshold: numeric`, `effective_from: date`, ...).

### 7.11 Snapshots (SCD2 untuk atribut yang di-overwrite)

Harga, cost, resep, dan komisi **sudah** effective-dated di sumber, sehingga tidak perlu snapshot (sesuai blueprint §11.5). Snapshot hanya dipakai untuk master yang di-overwrite.

`snapshots/_snapshots.yml` (dbt ≥ 1.9):

```yaml
snapshots:
  - name: snap_menu_items
    relation: ref('stg_pos__menu_items')
    description: Riwayat reklasifikasi kategori & status aktif menu.
    config:
      unique_key: menu_item_id
      strategy: timestamp
      updated_at: updated_at_utc
      hard_deletes: invalidate
  - name: snap_outlets
    relation: ref('stg_pos__outlets')
    config:
      unique_key: outlet_id
      strategy: timestamp
      updated_at: updated_at_utc
      hard_deletes: invalidate
```

Snapshot ditulis ke dataset `snapshots` (prod) atau `dbt_<user>_snapshots` (dev) lewat `generate_schema_name`, sehingga dev tidak pernah menimpa prod (lesson learned #6 di blueprint).

### 7.12 Testing

**Generic tests** (cuplikan `_core__models.yml` & `_finance__models.yml`):

```yaml
version: 2

models:
  - name: int_item_std_cost_daily
    data_tests:
      - dbt_utils.unique_combination_of_columns:
          combination_of_columns: [date_day, item_type, item_id]
    columns:
      - name: n_components_missing_cost
        data_tests:
          - accepted_values:
              values: [0]
              quote: false

  - name: fct_order_lines
    description: Baris penjualan atomik dengan net sales & COGS standar. Grain order_item_id.
    columns:
      - name: order_item_id
        data_tests: [unique, not_null]
      - name: menu_item_id
        data_tests:
          - relationships: {to: ref('dim_menu_item'), field: menu_item_id}
      - name: std_cost_per_unit
        data_tests:
          - not_null:
              config: {where: "is_revenue_line"}          # memperbaiki D2
      - name: net_sales_amount
        data_tests:
          - dbt_expectations.expect_column_values_to_be_between:
              min_value: 0

  - name: mart_pnl_daily
    data_tests:
      - dbt_utils.unique_combination_of_columns:
          combination_of_columns: [report_date, outlet_id]
    columns:
      - name: food_cost_pct
        description: '{{ doc("food_cost_pct") }}'
        data_tests:
          - dbt_expectations.expect_column_values_to_be_between:   # memperbaiki D3
              min_value: 0
              max_value: 100
              row_condition: "net_sales > 0"
              config: {severity: warn}

  - name: mart_menu_engineering
    columns:
      - name: menu_class
        data_tests:
          - accepted_values: {values: ['Star', 'Plowhorse', 'Puzzle', 'Dog']}
```

> dbt ≥ 1.10 menyarankan argumen generic test dibungkus `arguments:`. Bentuk di atas masih berjalan dengan deprecation warning. Seragamkan saat bootstrap sesuai versi yang dipin.

**Singular tests** (`tests/`, mengembalikan baris pelanggaran):

```sql
-- tests/assert_prep_recipes_only_raw.sql : prep item tidak boleh berisi prep item lain (batas explosion 1 level)
select r.recipe_id, rl.ingredient_id
from {{ ref('stg_pos__recipes') }} as r
inner join {{ ref('stg_pos__recipe_lines') }} as rl on rl.recipe_id = r.recipe_id
inner join {{ ref('stg_pos__ingredients') }} as i on i.ingredient_id = rl.ingredient_id
where r.prep_ingredient_id is not null
  and i.is_prep_item
```

```sql
-- tests/assert_opex_reconciles.sql : opex di mart_pnl_daily = opex sumber, untuk bulan lengkap
with mart as (
    select report_month, sum(labor_cost + other_opex) as opex
    from {{ ref('mart_pnl_daily') }}
    where report_month < date_trunc(current_date('{{ var("local_tz") }}'), month)
    group by 1
),
src as (
    select period_month as report_month, sum(amount) as opex
    from {{ ref('stg_pos__operating_expenses') }}
    group by 1
)
select m.report_month, m.opex as mart_opex, s.opex as source_opex
from mart as m
inner join src as s on s.report_month = m.report_month
where abs(m.opex - s.opex) > 1
```

```sql
-- tests/assert_completed_orders_fully_paid.sql (severity warn di YAML)
select order_id, total_amount, paid_amount
from {{ ref('fct_orders') }}
where order_status = 'Completed'
  and abs(total_amount - paid_amount) > 1
```

```sql
-- tests/assert_active_menu_has_recipe.sql : setiap menu yang terjual punya resep berlaku di tanggal itu
select l.order_item_id, l.menu_item_id, l.order_date
from {{ ref('fct_order_lines') }} as l
left join {{ ref('int_item_explosion_daily') }} as x
    on x.date_day = l.order_date and x.item_type = 'Menu Item' and x.item_id = l.menu_item_id
where l.is_revenue_line
  and x.item_id is null
```

**Unit test** (`models/intermediate/costing/_costing__unit_tests.yml`), memverifikasi loss %, yield, dan explosion prep:

```yaml
unit_tests:
  - name: test_item_explosion_handles_loss_and_prep
    description: >
      Espresso 18 g dengan loss 10% → 20 g. Sirup aren batch 1.000 ml dari 500 g gula aren,
      sehingga 30 ml sirup = 15 g gula aren.
    model: int_item_explosion_daily
    given:
      - input: ref('util_dates')
        rows:
          - {date_day: 2026-01-15}
      - input: ref('stg_pos__ingredients')
        rows:
          - {ingredient_id: ING_ESPR, is_prep_item: false}
          - {ingredient_id: ING_PALM, is_prep_item: false}
          - {ingredient_id: PRP_AREN, is_prep_item: true}
      - input: ref('stg_pos__recipes')
        rows:
          - {recipe_id: R_AREN, menu_item_id: null, prep_ingredient_id: PRP_AREN, yield_qty: 1000, effective_from: 2025-07-01, effective_to: null}
          - {recipe_id: R_KSA,  menu_item_id: MNU_KSA, prep_ingredient_id: null, yield_qty: 1, effective_from: 2025-07-01, effective_to: null}
      - input: ref('stg_pos__recipe_lines')
        rows:
          - {recipe_id: R_AREN, ingredient_id: ING_PALM, qty_per_yield: 500, loss_pct: 0}
          - {recipe_id: R_KSA,  ingredient_id: ING_ESPR, qty_per_yield: 18,  loss_pct: 10}
          - {recipe_id: R_KSA,  ingredient_id: PRP_AREN, qty_per_yield: 30,  loss_pct: 0}
      - input: ref('stg_pos__modifier_lines')
        rows: []
    expect:
      rows:
        - {date_day: 2026-01-15, item_type: Menu Item,  item_id: MNU_KSA,  ingredient_id: ING_ESPR, qty_per_unit: 20}
        - {date_day: 2026-01-15, item_type: Menu Item,  item_id: MNU_KSA,  ingredient_id: ING_PALM, qty_per_unit: 15}
        - {date_day: 2026-01-15, item_type: Prep Item,  item_id: PRP_AREN, ingredient_id: ING_PALM, qty_per_unit: 0.5}
        - {date_day: 2026-01-15, item_type: Ingredient, item_id: ING_ESPR, ingredient_id: ING_ESPR, qty_per_unit: 1}
        - {date_day: 2026-01-15, item_type: Ingredient, item_id: ING_PALM, ingredient_id: ING_PALM, qty_per_unit: 1}
```

Unit test kedua yang disarankan: `fct_order_lines` untuk alokasi diskon order (merchant vs platform) dan void line.

**Target cakupan:** 100% PK test di core & marts, freshness di semua tabel transaksi, unit test untuk semua logika costing/alokasi, dan `store_failures: true` untuk singular tests.

### 7.13 Glossary (dokumentasi KPI)

`models/glossary/kpi.md`:

```markdown
{% docs food_cost_pct %}
Food cost % = cost of sales / net sales × 100.
Harian (mart_pnl_daily): cost of sales = COGS standar + waste (theoretical).
Bulanan (mart_pnl_monthly): ditambah unexplained inventory variance dari stock opname (actual).
Benchmark kafe: 28–32%. Warning 32%, critical 35% (seed kpi_thresholds).
{% enddocs %}

{% docs prime_cost_pct %}
Prime cost % = (actual cost of sales + labor) / net sales × 100. Target ≤ 60%.
{% enddocs %}

{% docs net_sales %}
Gross sales − diskon yang didanai merchant − refund. Tidak termasuk PB1 dan service charge.
Diskon yang didanai platform (GoFood/Grab) tidak mengurangi net sales karena diganti platform.
{% enddocs %}
```

### 7.14 Exposures (lineage sampai konsumen)

```yaml
version: 2
exposures:
  - name: gsheet_pnl_report
    type: application
    maturity: high
    owner: {name: Data Team, email: <owner_email>}
    depends_on: [ref('mart_pnl_monthly'), ref('mart_kpi_monthly_status'), ref('mart_waste_analysis'), ref('mart_menu_engineering')]
  - name: vercel_dashboard
    type: dashboard
    maturity: medium
    url: https://<vercel-url>
    owner: {name: Data Team, email: <owner_email>}
    depends_on: [ref('mart_pnl_daily'), ref('mart_pnl_monthly'), ref('mart_kpi_monthly_status'), ref('mart_inventory_variance'), ref('mart_waste_analysis'), ref('mart_menu_engineering'), ref('mart_channel_performance_daily'), ref('mart_orders_hourly')]
```

### 7.15 Reconciliation v1 → v2 (audit_helper)

Saat migrasi dari `fct_financial_pnl` v1, bandingkan `net_sales` per bulan. Selisihnya harus dapat dijelaskan oleh refund, diskon platform, dan pemisahan pajak. Simpan hasilnya di deskripsi PR.

```sql
-- models/reconciliation/recon_pnl_v1_vs_v2.sql
{{ config(enabled = false) }}
{% set old_query %}
  select date_trunc(report_date, month) as m, round(sum(net_revenue), 0) as net_sales
  from `<PROJECT_ID>.marts.fct_financial_pnl` group by 1
{% endset %}
{% set new_query %}
  select report_month as m, round(sum(net_sales), 0) as net_sales
  from {{ ref('mart_pnl_monthly') }} group by 1
{% endset %}
{{ audit_helper.compare_queries(a_query=old_query, b_query=new_query, primary_key='m', summarize=true) }}
```

### 7.16 Lint (SQLFluff, dialek BigQuery)

`.sqlfluff`

```ini
[sqlfluff]
dialect = bigquery
templater = dbt
max_line_length = 120
exclude_rules = LT05

[sqlfluff:templater:dbt]
project_dir = .

[sqlfluff:layout:type:comma]
line_position = trailing

[sqlfluff:rules:capitalisation.keywords]
capitalisation_policy = lower

[sqlfluff:rules:capitalisation.functions]
extended_capitalisation_policy = lower
```

> Plan v1 memakai huruf kecil, jadi v2 juga huruf kecil. Yang penting dari blueprint adalah konsistensinya, dan itu di-enforce lint.

---

## 8. Orkestrasi & CI/CD (GitHub Actions)

GitHub repository variables: `GCP_PROJECT_ID`, `WIF_PROVIDER`, `SA_INGEST`, `SA_DBT`, `SA_CI`, `SA_EXPORT`. Secrets: `SOURCE_DATABASE_URL`.

### 8.1 `.github/workflows/daily_pipeline.yml`

```yaml
name: daily-pipeline

on:
  schedule:
    - cron: '30 17 * * *'          # 00:30 WIB
  workflow_dispatch:
    inputs:
      full_refresh:
        type: boolean
        default: false

concurrency:
  group: daily-pipeline
  cancel-in-progress: false

permissions:
  contents: read
  id-token: write

env:
  GCP_PROJECT_ID: ${{ vars.GCP_PROJECT_ID }}

jobs:
  generate:                         # hanya untuk simulasi; hapus bila OLTP diisi aplikasi nyata
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: {python-version: '3.12', cache: pip}
      - run: pip install -r oltp/generator/requirements.txt
      - run: python oltp/generator/generate.py daily --date "$(TZ=Asia/Jakarta date -d yesterday +%F)"
        env:
          SOURCE_DATABASE_URL: ${{ secrets.SOURCE_DATABASE_URL }}

  ingest:
    needs: generate
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: {python-version: '3.12', cache: pip}
      - run: pip install -r ingestion/requirements.txt
      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ vars.WIF_PROVIDER }}
          service_account: ${{ vars.SA_INGEST }}
      - run: python ingestion/pipeline.py
        env:
          SOURCE_DATABASE_URL: ${{ secrets.SOURCE_DATABASE_URL }}
          DESTINATION__BIGQUERY__LOCATION: asia-southeast2
          DESTINATION__BIGQUERY__CREDENTIALS__PROJECT_ID: ${{ vars.GCP_PROJECT_ID }}

  transform:
    needs: ingest
    runs-on: ubuntu-latest
    timeout-minutes: 30
    defaults:
      run:
        working-directory: dbt
    env:
      DBT_PROFILES_DIR: ${{ github.workspace }}/dbt
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: {python-version: '3.12', cache: pip}
      - run: pip install -r requirements.txt
      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ vars.WIF_PROVIDER }}
          service_account: ${{ vars.SA_DBT }}
      - run: dbt deps
      - run: dbt source freshness --target prod
      - name: dbt build (full refresh mingguan tiap Senin dini hari, atau manual)
        run: |
          if [ "${{ inputs.full_refresh }}" = "true" ] || [ "$(TZ=Asia/Jakarta date +%u)" = "1" ]; then
            dbt build --target prod --full-refresh
          else
            dbt build --target prod
          fi
      - run: dbt docs generate --target prod
        if: always()
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: prod-manifest
          path: |
            dbt/target/manifest.json
            dbt/target/run_results.json
          retention-days: 30
      - uses: actions/upload-pages-artifact@v3
        with:
          path: dbt/target

  deploy-docs:
    needs: transform
    runs-on: ubuntu-latest
    permissions:
      pages: write
      id-token: write
    environment:
      name: github-pages
    steps:
      - uses: actions/deploy-pages@v4

  export-dashboard:                 # v2.1: JSON mart -> dashboard Vercel (§10)
    needs: transform
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: write
      id-token: write
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: {python-version: '3.12', cache: pip}
      - run: pip install -r dashboard/requirements.txt
      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ vars.WIF_PROVIDER }}
          service_account: ${{ vars.SA_EXPORT }}
      - run: python dashboard/export_marts.py
        env:
          GCP_PROJECT_ID: ${{ vars.GCP_PROJECT_ID }}
      - name: Commit data bila berubah (memicu deploy Vercel)
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add dashboard/public/data
          git diff --cached --quiet || { git commit -m "chore(dashboard): refresh data $(date -u +%F)"; git push; }
```

Catatan:
- Job berjalan pukul 00:30 WIB (Senin dini hari = data Minggu), sehingga full refresh terjadi mingguan. Snapshot ikut `dbt build` sesuai urutan DAG dan tidak terpengaruh `--full-refresh`.
- Upload `dbt/target` ke Pages mempublikasikan compiled SQL. Ini aman karena salt ada di tabel. Untuk repo privat, Pages butuh plan berbayar, jadi cukup simpan docs sebagai artifact.
- Scheduled workflow di repo publik dinonaktifkan GitHub setelah 60 hari tanpa aktivitas repo. Lakukan commit berkala atau aktifkan ulang dari tab Actions.
- Pin action ke commit SHA untuk keamanan supply chain (tag versi di atas hanya untuk keterbacaan).
- Job `export-dashboard` perlu `contents: write`. Jika `main` dilindungi, beri bypass untuk `github-actions[bot]`, atau push ke branch `data` yang dijadikan Production Branch di Vercel. Jangan menambahkan `[skip ci]` pada pesan commit karena Vercel ikut melewati deploy.
- `pr_ci.yml` tidak boleh menjalankan job export (tanpa akses `sa-export`); PR cukup memeriksa JSON yang sudah ada dengan PII guard.

### 8.2 `.github/workflows/pr_ci.yml`: slim CI + lint + PII guard

```yaml
name: pr-ci

on:
  pull_request:
    paths: ['dbt/**', 'scripts/**']

permissions:
  contents: read
  id-token: write
  actions: read

jobs:
  dbt-ci:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    defaults:
      run:
        working-directory: dbt
    env:
      GCP_PROJECT_ID: ${{ vars.GCP_PROJECT_ID }}
      DBT_PROFILES_DIR: ${{ github.workspace }}/dbt
      PR_NUMBER: ${{ github.event.number }}
    steps:
      - uses: actions/checkout@v4
        with: {fetch-depth: 0}
      - uses: actions/setup-python@v5
        with: {python-version: '3.12', cache: pip}
      - run: pip install -r requirements.txt     # dbt-bigquery + sqlfluff + sqlfluff-templater-dbt (pin sama dengan lokal)
      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ vars.WIF_PROVIDER }}
          service_account: ${{ vars.SA_CI }}
      - uses: google-github-actions/setup-gcloud@v2
      - run: dbt deps

      - name: PII guard
        run: python ../scripts/check_pii_columns.py models

      - name: Ambil manifest prod terakhir
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          RUN_ID=$(gh run list --workflow daily_pipeline.yml --status success --limit 1 --json databaseId -q '.[0].databaseId')
          if [ -n "$RUN_ID" ]; then gh run download "$RUN_ID" --name prod-manifest --dir prod_state || true; fi

      - name: Lint SQL yang berubah (non-blocking dulu)
        run: |
          CHANGED=$(git diff --relative --name-only --diff-filter=AM "origin/${{ github.base_ref }}...HEAD" -- models | grep '\.sql$' || true)
          if [ -n "$CHANGED" ]; then
            sqlfluff lint $CHANGED --format github-annotation-native --nofail
          fi

      - name: Slim CI build
        run: |
          if [ -f prod_state/manifest.json ]; then
            dbt build --target ci --select state:modified+ --defer --state prod_state
          else
            dbt build --target ci
          fi

      - name: Hapus dataset CI
        if: always()
        run: |
          for ds in $(bq ls --format=json --project_id "$GCP_PROJECT_ID" | jq -r '.[].datasetReference.datasetId' | grep "^dbt_ci_pr${PR_NUMBER}" || true); do
            bq rm -r -f -d "$GCP_PROJECT_ID:$ds"
          done
```

Setelah backlog lint bersih, hapus `--nofail` agar lint menjadi blocking (lesson learned #9).

---

## 9. Route 1: Google Sheets + Apps Script

Desain: Apps Script **tidak** menghitung KPI. KPI dan threshold sepenuhnya berasal dari dbt, sehingga hanya ada satu definisi. Apps Script melakukan tiga hal:
1. **Sync** (07:00 WIB): query mart, lalu tulis ke tab cache (`PnL_Monthly`, `KPI_Status`, `Waste_By_Reason`, `Menu_Engineering`) dan `_sync_log`.
2. **Alert**: email jika ada KPI WARN/CRITICAL di bulan lengkap terakhir, atau CRITICAL di MTD. Dedupe dengan signature agar email tidak terkirim berulang setiap hari.
3. **Web app dashboard**: membaca tab cache (bukan BigQuery), sehingga cepat dan tidak memakai kuota query per view.

Kelola source dengan `clasp` agar ter-versi di repo (`apps_script/`).

### 9.1 `appsscript.json`

```json
{
  "timeZone": "Asia/Jakarta",
  "runtimeVersion": "V8",
  "exceptionLogging": "STACKDRIVER",
  "dependencies": {
    "enabledAdvancedServices": [
      { "userSymbol": "BigQuery", "serviceId": "bigquery", "version": "v2" }
    ]
  },
  "oauthScopes": [
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/bigquery",
    "https://www.googleapis.com/auth/script.send_mail",
    "https://www.googleapis.com/auth/script.scriptapp",
    "https://www.googleapis.com/auth/userinfo.email"
  ],
  "webapp": { "executeAs": "USER_DEPLOYING", "access": "MYSELF" }
}
```

Script Properties: `GCP_PROJECT_ID`, `BQ_LOCATION` (`asia-southeast2`), `BQ_DATASET` (`marts`), `ALERT_EMAILS` (pisahkan dengan koma).

### 9.2 `Code.gs`

```javascript
/**
 * F&B Reporting: sync mart BigQuery -> Google Sheets, alert KPI, web dashboard.
 * KPI & threshold dihitung di dbt (mart_kpi_monthly_status); script ini tidak mendefinisikan ulang rumus.
 */
const TZ = 'Asia/Jakarta';
const MAX_BYTES_BILLED = '2000000000';
const RP = 'Rp#,##0';
const PCT = '0.00"%"';

function cfg_() {
  const p = PropertiesService.getScriptProperties();
  const projectId = p.getProperty('GCP_PROJECT_ID');
  if (!projectId) throw new Error('Script Property GCP_PROJECT_ID belum di-set');
  return {
    projectId: projectId,
    location: p.getProperty('BQ_LOCATION') || 'asia-southeast2',
    dataset: p.getProperty('BQ_DATASET') || 'marts',
    alertEmails: p.getProperty('ALERT_EMAILS') || Session.getEffectiveUser().getEmail(),
  };
}

function table_(name) {
  const c = cfg_();
  return '`' + c.projectId + '.' + c.dataset + '.' + name + '`';
}

// ------------------------------------------------------------------ BigQuery
function runQuery_(sql) {
  const c = cfg_();
  let res = BigQuery.Jobs.query({
    query: sql,
    useLegacySql: false,
    location: c.location,
    maximumBytesBilled: MAX_BYTES_BILLED,
    timeoutMs: 30000,
  }, c.projectId);

  const jobId = res.jobReference.jobId;
  let waitMs = 500;
  while (!res.jobComplete) {
    Utilities.sleep(waitMs);
    waitMs = Math.min(waitMs * 2, 8000);
    res = BigQuery.Jobs.getQueryResults(c.projectId, jobId, { location: c.location, timeoutMs: 30000 });
  }

  const fields = res.schema.fields;
  let rows = res.rows || [];
  let pageToken = res.pageToken;
  while (pageToken) {
    const page = BigQuery.Jobs.getQueryResults(c.projectId, jobId, { location: c.location, pageToken: pageToken });
    rows = rows.concat(page.rows || []);
    pageToken = page.pageToken;
  }

  return {
    header: fields.map(f => f.name),
    types: fields.map(f => f.type),
    values: rows.map(r => r.f.map((cell, i) => cast_(cell.v, fields[i].type))),
  };
}

function cast_(v, type) {
  if (v === null || v === undefined) return '';
  if (['INTEGER', 'INT64', 'FLOAT', 'FLOAT64', 'NUMERIC', 'BIGNUMERIC'].indexOf(type) >= 0) return Number(v);
  if (type === 'BOOLEAN' || type === 'BOOL') return v === 'true';
  return v;
}

// ------------------------------------------------------------------ Sheets
function ss_() {
  return SpreadsheetApp.getActiveSpreadsheet()
    || SpreadsheetApp.openById(PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID'));
}

/** Tulis hasil query ke tab; format & chart di tab dipertahankan (clearContents, bukan clear). */
function writeTable_(sheetName, result, formats) {
  const sh = ss_().getSheetByName(sheetName) || ss_().insertSheet(sheetName);
  sh.clearContents();
  const nRows = result.values.length;
  const nCols = result.header.length;

  // kolom teks dipaksa plain text agar '2026-09' tidak di-parse menjadi tanggal
  result.types.forEach((t, i) => {
    if ((t === 'STRING' || t === 'DATE') && nRows > 0) sh.getRange(2, i + 1, nRows, 1).setNumberFormat('@');
  });

  sh.getRange(1, 1, 1, nCols).setValues([result.header])
    .setFontWeight('bold').setBackground('#1f4e78').setFontColor('#ffffff');
  if (nRows > 0) sh.getRange(2, 1, nRows, nCols).setValues(result.values);

  Object.keys(formats || {}).forEach(fmt => {
    formats[fmt].forEach(col => {
      const idx = result.header.indexOf(col);
      if (idx >= 0 && nRows > 0) sh.getRange(2, idx + 1, nRows, 1).setNumberFormat(fmt);
    });
  });
  sh.setFrozenRows(1);
}

function appendLog_(startedAt, status, detail) {
  const sh = ss_().getSheetByName('_sync_log') || ss_().insertSheet('_sync_log');
  if (sh.getLastRow() === 0) sh.appendRow(['started_at', 'finished_at', 'status', 'detail']);
  const fmt = d => Utilities.formatDate(d, TZ, 'yyyy-MM-dd HH:mm:ss');
  sh.appendRow([fmt(startedAt), fmt(new Date()), status, detail]);
}

// ------------------------------------------------------------------ Sync
function syncAll() {
  const startedAt = new Date();
  try {
    syncPnl_();
    const kpi = syncKpi_();
    syncWaste_();
    syncMenu_();
    notifyAlerts_(kpi);
    PropertiesService.getScriptProperties().setProperty('LAST_SYNC', startedAt.toISOString());
    appendLog_(startedAt, 'OK', 'pnl,kpi,waste,menu');
  } catch (e) {
    appendLog_(startedAt, 'ERROR', String(e && e.message));
    MailApp.sendEmail(cfg_().alertEmails, '[F&B Report] Sync gagal', String(e && e.stack));
    throw e;
  }
}

function syncPnl_() {
  const sql = `
    SELECT
      FORMAT_DATE('%Y-%m', report_month)                         AS month,
      IFNULL(outlet_id, 'ALL')                                   AS outlet,
      LOGICAL_AND(is_complete_month)                             AS is_complete_month,
      SUM(gross_sales) AS gross_sales, SUM(discounts) AS discounts, SUM(refunds) AS refunds,
      SUM(net_sales) AS net_sales, SUM(cogs_standard) AS cogs_standard, SUM(waste_cost) AS waste_cost,
      SUM(inventory_variance_cost) AS inventory_variance, SUM(actual_cost_of_sales) AS cost_of_sales,
      SUM(gross_profit) AS gross_profit, SUM(channel_commission) AS channel_commission,
      SUM(payment_fees) AS payment_fees, SUM(labor_cost) AS labor_cost, SUM(other_opex) AS other_opex,
      SUM(outlet_ebitda) AS ebitda,
      ROUND(SAFE_DIVIDE(SUM(actual_cost_of_sales), SUM(net_sales)) * 100, 2)                   AS food_cost_pct,
      ROUND(SAFE_DIVIDE(SUM(waste_cost), SUM(net_sales)) * 100, 2)                             AS waste_pct,
      ROUND(SAFE_DIVIDE(SUM(actual_cost_of_sales) + SUM(labor_cost), SUM(net_sales)) * 100, 2) AS prime_cost_pct,
      ROUND(SAFE_DIVIDE(SUM(outlet_ebitda), SUM(net_sales)) * 100, 2)                          AS ebitda_margin_pct
    FROM ${table_('mart_pnl_monthly')}
    WHERE report_month >= DATE_SUB(DATE_TRUNC(CURRENT_DATE('${TZ}'), MONTH), INTERVAL 12 MONTH)
    GROUP BY GROUPING SETS ((report_month, outlet_id), (report_month))
    ORDER BY month DESC, outlet`;
  writeTable_('PnL_Monthly', runQuery_(sql), {
    [RP]: ['gross_sales', 'discounts', 'refunds', 'net_sales', 'cogs_standard', 'waste_cost', 'inventory_variance',
           'cost_of_sales', 'gross_profit', 'channel_commission', 'payment_fees', 'labor_cost', 'other_opex', 'ebitda'],
    [PCT]: ['food_cost_pct', 'waste_pct', 'prime_cost_pct', 'ebitda_margin_pct'],
  });
}

function syncKpi_() {
  const sql = `
    SELECT FORMAT_DATE('%Y-%m', report_month) AS month, outlet_id AS outlet, is_complete_month,
           metric_code, metric_name, metric_value, warn_threshold, critical_threshold, status
    FROM ${table_('mart_kpi_monthly_status')}
    WHERE report_month >= DATE_SUB(DATE_TRUNC(CURRENT_DATE('${TZ}'), MONTH), INTERVAL 1 MONTH)
    ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, month DESC, outlet, metric_code`;
  const result = runQuery_(sql);
  writeTable_('KPI_Status', result, { [PCT]: ['metric_value', 'warn_threshold', 'critical_threshold'] });
  return result;
}

function syncWaste_() {
  const sql = `
    SELECT outlet_id AS outlet, reason_name, controllability,
           ROUND(SUM(waste_cost), 0) AS waste_cost
    FROM ${table_('mart_waste_analysis')}
    WHERE waste_date >= DATE_SUB(CURRENT_DATE('${TZ}'), INTERVAL 90 DAY)
    GROUP BY 1, 2, 3
    ORDER BY waste_cost DESC`;
  writeTable_('Waste_By_Reason', runQuery_(sql), { [RP]: ['waste_cost'] });
}

function syncMenu_() {
  const sql = `
    SELECT outlet_id AS outlet, menu_name, category_name, menu_class, qty_sold,
           ROUND(menu_mix_pct * 100, 2) AS menu_mix_pct, ROUND(avg_contribution_margin, 0) AS avg_cm
    FROM ${table_('mart_menu_engineering')}
    WHERE report_month = DATE_SUB(DATE_TRUNC(CURRENT_DATE('${TZ}'), MONTH), INTERVAL 1 MONTH)
    ORDER BY outlet, qty_sold DESC`;
  writeTable_('Menu_Engineering', runQuery_(sql), { [RP]: ['avg_cm'], [PCT]: ['menu_mix_pct'] });
}

// ------------------------------------------------------------------ Alert
function notifyAlerts_(kpi) {
  const h = kpi.header;
  const col = name => h.indexOf(name);
  const alerts = kpi.values.filter(r =>
    (r[col('is_complete_month')] === true && r[col('status')] !== 'OK') ||
    (r[col('is_complete_month')] === false && r[col('status')] === 'CRITICAL'));
  if (alerts.length === 0) return;

  const signature = Utilities.base64Encode(
    Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, JSON.stringify(alerts)));
  const props = PropertiesService.getScriptProperties();
  if (props.getProperty('LAST_ALERT_SIG') === signature) return;   // isi alert sama dengan kemarin, tidak dikirim ulang

  const rowsHtml = alerts.map(r =>
    `<tr><td>${r[col('month')]}${r[col('is_complete_month')] ? '' : ' (MTD)'}</td><td>${r[col('outlet')]}</td>` +
    `<td>${r[col('metric_name')]}</td><td>${r[col('metric_value')]}%</td>` +
    `<td>${r[col('warn_threshold')]}% / ${r[col('critical_threshold')]}%</td>` +
    `<td style="color:${r[col('status')] === 'CRITICAL' ? '#b00020' : '#a15c00'}"><b>${r[col('status')]}</b></td></tr>`
  ).join('');

  MailApp.sendEmail({
    to: cfg_().alertEmails,
    subject: `[F&B KPI] ${alerts.length} metrik di luar threshold`,
    htmlBody:
      '<p>KPI berikut melewati threshold (sumber: dbt mart_kpi_monthly_status).</p>' +
      '<table border="1" cellpadding="4" style="border-collapse:collapse">' +
      '<tr><th>Bulan</th><th>Outlet</th><th>Metrik</th><th>Nilai</th><th>Warn / Critical</th><th>Status</th></tr>' +
      rowsHtml + '</table>' +
      `<p><a href="${ss_().getUrl()}">Buka laporan</a></p>`,
  });
  props.setProperty('LAST_ALERT_SIG', signature);
}

// ------------------------------------------------------------------ Trigger & Web app
function installTriggers() {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'syncAll')
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('syncAll').timeBased().everyDays(1).atHour(7).inTimezone(TZ).create();
}

function onOpen() {
  SpreadsheetApp.getUi().createMenu('F&B Report')
    .addItem('Sync sekarang', 'syncAll')
    .addItem('Pasang trigger harian', 'installTriggers')
    .addToUi();
}

function doGet() {
  return HtmlService.createHtmlOutputFromFile('Dashboard')
    .setTitle('F&B Performance')
    .addMetaTag('viewport', 'width=device-width, initial-scale=1');
}

/** Dipanggil dari Dashboard.html via google.script.run. Hanya membaca tab cache (tanpa query BigQuery). */
function getDashboardData() {
  const read = name => {
    const sh = ss_().getSheetByName(name);
    if (!sh || sh.getLastRow() < 2) return [];
    const values = sh.getDataRange().getValues();
    const header = values.shift();
    return values.map(r => {
      const o = {};
      header.forEach((k, i) => { o[k] = r[i] instanceof Date ? r[i].toISOString() : r[i]; });
      return o;
    });
  };
  return {
    pnl: read('PnL_Monthly'),
    kpi: read('KPI_Status'),
    waste: read('Waste_By_Reason'),
    menu: read('Menu_Engineering'),
    lastSync: PropertiesService.getScriptProperties().getProperty('LAST_SYNC'),
  };
}
```

### 9.3 `Dashboard.html` (web app: KPI cards, tren, waste, menu engineering)

```html
<!DOCTYPE html>
<html>
<head>
  <base target="_top">
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.js"></script>
  <style>
    body { font-family: Arial, sans-serif; margin: 16px; background: #f6f7f9; color: #1d2433; }
    .row { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 16px; }
    .card { background: #fff; border-radius: 8px; padding: 12px 16px; flex: 1 1 160px; box-shadow: 0 1px 2px rgba(0,0,0,.08); }
    .card .label { font-size: 12px; color: #5b6475; }
    .card .value { font-size: 22px; font-weight: bold; margin-top: 4px; }
    .card .delta { font-size: 12px; }
    .bad { color: #b00020; } .good { color: #1b7f3b; }
    .panel { background: #fff; border-radius: 8px; padding: 12px; flex: 1 1 420px; min-width: 0; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td { text-align: left; padding: 4px 6px; border-bottom: 1px solid #e5e7eb; }
    .pill { padding: 2px 6px; border-radius: 4px; font-size: 11px; color: #fff; }
    .CRITICAL { background: #b00020; } .WARN { background: #c77700; } .OK { background: #1b7f3b; }
  </style>
</head>
<body>
  <h2 style="margin:0 0 4px">F&amp;B Performance</h2>
  <div style="font-size:12px;color:#5b6475;margin-bottom:12px">
    Outlet: <select id="outlet"></select> · Sync terakhir: <span id="sync">-</span>
  </div>
  <div class="row" id="cards"></div>
  <div class="row">
    <div class="panel"><canvas id="trend"></canvas></div>
    <div class="panel"><canvas id="waste"></canvas></div>
  </div>
  <div class="row">
    <div class="panel"><h4>Status KPI</h4><table id="kpi"></table></div>
    <div class="panel"><h4>Menu Engineering (bulan lalu)</h4><table id="menu"></table></div>
  </div>

<script>
  const fmtRp = v => 'Rp' + Math.round(v || 0).toLocaleString('id-ID');
  const fmtPct = v => (v === '' || v === null ? '-' : Number(v).toFixed(1) + '%');
  let DATA, trendChart, wasteChart;

  google.script.run.withSuccessHandler(d => {
    DATA = d;
    document.getElementById('sync').textContent = d.lastSync || '-';
    const outlets = [...new Set(d.pnl.map(r => r.outlet))].sort((a, b) => a === 'ALL' ? -1 : a.localeCompare(b));
    const sel = document.getElementById('outlet');
    sel.innerHTML = outlets.map(o => `<option>${o}</option>`).join('');
    sel.onchange = render;
    render();
  }).getDashboardData();

  function render() {
    const outlet = document.getElementById('outlet').value;
    const pnl = DATA.pnl.filter(r => r.outlet === outlet).sort((a, b) => a.month.localeCompare(b.month));
    const complete = pnl.filter(r => r.is_complete_month === true);
    const cur = complete[complete.length - 1] || {};
    const prev = complete[complete.length - 2] || {};

    const card = (label, key, isPct, higherIsBad) => {
      const d = Number(cur[key] || 0) - Number(prev[key] || 0);
      const cls = d === 0 ? '' : ((d > 0) === higherIsBad ? 'bad' : 'good');
      const dTxt = isPct ? (d >= 0 ? '+' : '') + d.toFixed(1) + ' pp' : (d >= 0 ? '+' : '') + fmtRp(d);
      return `<div class="card"><div class="label">${label} (${cur.month || '-'})</div>
              <div class="value">${isPct ? fmtPct(cur[key]) : fmtRp(cur[key])}</div>
              <div class="delta ${cls}">${dTxt} vs bulan sebelumnya</div></div>`;
    };
    document.getElementById('cards').innerHTML =
      card('Net Sales', 'net_sales', false, false) +
      card('Food Cost', 'food_cost_pct', true, true) +
      card('Prime Cost', 'prime_cost_pct', true, true) +
      card('Waste', 'waste_pct', true, true) +
      card('EBITDA Margin', 'ebitda_margin_pct', true, false);

    if (trendChart) trendChart.destroy();
    trendChart = new Chart(document.getElementById('trend'), {
      data: {
        labels: pnl.map(r => r.month),
        datasets: [
          { type: 'bar', label: 'Net Sales', data: pnl.map(r => r.net_sales), yAxisID: 'y', backgroundColor: '#8fb3d9' },
          { type: 'line', label: 'Food Cost %', data: pnl.map(r => r.food_cost_pct), yAxisID: 'y1', borderColor: '#b00020' },
        ],
      },
      options: { plugins: { title: { display: true, text: 'Net Sales & Food Cost % (12 bulan)' } },
                 scales: { y: { position: 'left' }, y1: { position: 'right', grid: { drawOnChartArea: false } } } },
    });

    const waste = DATA.waste.filter(r => outlet === 'ALL' || r.outlet === outlet);
    const byReason = {};
    waste.forEach(r => { byReason[r.reason_name] = (byReason[r.reason_name] || 0) + Number(r.waste_cost); });
    if (wasteChart) wasteChart.destroy();
    wasteChart = new Chart(document.getElementById('waste'), {
      type: 'bar',
      data: { labels: Object.keys(byReason), datasets: [{ label: 'Waste cost 90 hari', data: Object.values(byReason), backgroundColor: '#c77700' }] },
      options: { indexAxis: 'y', plugins: { title: { display: true, text: 'Waste by Reason (90 hari)' } } },
    });

    const kpi = DATA.kpi.filter(r => outlet === 'ALL' || r.outlet === outlet);
    document.getElementById('kpi').innerHTML = '<tr><th>Bulan</th><th>Outlet</th><th>Metrik</th><th>Nilai</th><th>Status</th></tr>' +
      kpi.map(r => `<tr><td>${r.month}${r.is_complete_month ? '' : ' (MTD)'}</td><td>${r.outlet}</td><td>${r.metric_name}</td>
                    <td>${fmtPct(r.metric_value)}</td><td><span class="pill ${r.status}">${r.status}</span></td></tr>`).join('');

    const menu = DATA.menu.filter(r => outlet === 'ALL' || r.outlet === outlet).slice(0, 15);
    document.getElementById('menu').innerHTML = '<tr><th>Menu</th><th>Kelas</th><th>Qty</th><th>Mix</th><th>Avg CM</th></tr>' +
      menu.map(r => `<tr><td>${r.menu_name}</td><td>${r.menu_class}</td><td>${r.qty_sold}</td>
                     <td>${fmtPct(r.menu_mix_pct)}</td><td>${fmtRp(r.avg_cm)}</td></tr>`).join('');
  }
</script>
</body>
</html>
```

Deploy: *Deploy → New deployment → Web app*, execute as **Me**, access **Only myself** (atau domain). Karena dashboard membaca tab cache, membuka dashboard tidak memakai kuota BigQuery.

---

## 10. Route 2: Dashboard Vercel (static, portofolio)

> **Perubahan v2.1:** Metabase, Cloud Run, app DB Neon `fnb-metabase`, Secret Manager, dan key `sa-metabase` **dihapus**. Digantikan dashboard statis di Vercel, dengan pola yang sama seperti proyek portofolio sebelumnya (`tokped-fashion-pricing-and-promo-analytics`): HTML + CSS + JS murni, Chart.js, dan data berupa JSON hasil export mart.

### 10.1 Keputusan arsitektur

| Aspek | Metabase di Cloud Run (v2) | Dashboard Vercel statis (v2.1) |
|---|---|---|
| Biaya | Free tier Cloud Run, risiko kuota habis | Vercel Hobby, tanpa server |
| Cold start | 60–120 detik (JVM) | Tidak ada (file statis di CDN) |
| Kredensial BI | 1 JSON key (`sa-metabase`) di luar WIF | **Tidak ada key**, export memakai WIF |
| Pemakaian BigQuery saat dashboard dibuka | Ada (query per kartu) | **Nol**: pengunjung hanya membaca JSON |
| Komponen yang harus dijaga | Cloud Run, app DB, Secret Manager, image pin | Satu job export + satu project Vercel |
| Nilai portofolio | Konfigurasi tool jadi | Front-end analitik buatan sendiri, dapat dibuka recruiter langsung |
| Keterbatasan | Ad-hoc query bebas | Hanya data yang sudah di-export (agregat, bukan baris transaksi) |

Konsekuensi yang diterima: tidak ada drill-down ad-hoc ke baris transaksi. Itu sengaja, karena repo publik dan data yang dipublikasikan harus agregat.

> [!NOTE]
> Bagian tampilan di bawah mengikuti struktur halaman proyek Tokopedia yang saya baca dari `index.html`-nya: header dengan badge dan tombol (slide, unduh JSON mart, GitHub), baris KPI card, navigasi tab, kartu bergrafik Chart.js, tabel, simulator interaktif, dan data explorer. `style.css` dan `app.js` proyek itu belum saya baca. Gunakan keduanya sebagai basis desain saat implementasi.

### 10.2 Alur data

```
[BigQuery marts] --(sa-export via WIF, job export-dashboard)--> dashboard/public/data/*.json
        --> git commit oleh github-actions[bot] --> Vercel auto-deploy (Git integration) --> URL publik
```

- Export dijalankan sebagai job terakhir `daily_pipeline.yml` (§8.1), setelah `dbt build` hijau. Jika dbt gagal, JSON lama tetap tampil (tidak ada data setengah jadi).
- Output deterministik (kunci diurutkan), sehingga diff git hanya muncul saat data berubah.
- Repo publik, jadi JSON ikut publik. Semua isi berasal dari dataset `marts` yang sudah bebas PII (§7.6) dan data ini sintetis.

### 10.3 Struktur folder

```
dashboard/
├── export_marts.py          BigQuery -> JSON (tanpa key; ADC dari WIF)
├── requirements.txt         google-cloud-bigquery==<pin>
├── vercel.json              (opsional) header cache
└── public/                  <- Root Directory Vercel, tanpa build step
    ├── index.html
    ├── style.css
    ├── app.js               muat data/*.json, render Chart.js
    └── data/                pnl_monthly.json · pnl_daily.json · kpi_status.json
                             menu_engineering.json · inventory_variance.json
                             waste.json · channel_daily.json · orders_hourly.json · meta.json
```

Pengaturan project Vercel: import repo GitHub, **Root Directory** `dashboard/public`, Framework Preset *Other*, Build Command kosong. Production branch `main`.

### 10.4 `dashboard/export_marts.py`

```python
"""Export mart BigQuery -> JSON statis untuk dashboard Vercel.

Hanya membaca dataset marts. Gagal keras bila ada kolom berpola PII atau file terlalu besar,
karena hasil export dipublikasikan ke repo publik.
"""
import datetime as dt
import json
import os
import re
from decimal import Decimal
from pathlib import Path

from google.cloud import bigquery

PROJECT = os.environ["GCP_PROJECT_ID"]
LOCATION = "asia-southeast2"
OUT = Path(__file__).parent / "public" / "data"
MAX_FILE_BYTES = 1_500_000
BANNED_COLUMNS = re.compile(r"phone|email|full_name|birth|_key$|^_dlt_|password|salt", re.I)

EXPORTS = {
    "pnl_monthly": "select * from `{p}.marts.mart_pnl_monthly` order by report_month, outlet_id",
    "pnl_daily": "select * from `{p}.marts.mart_pnl_daily` order by report_date, outlet_id",
    "kpi_status": "select * from `{p}.marts.mart_kpi_monthly_status` order by report_month, outlet_id",
    "menu_engineering": "select * from `{p}.marts.mart_menu_engineering` order by outlet_id, menu_name",
    "inventory_variance": "select * from `{p}.marts.mart_inventory_variance` order by outlet_id",
    "waste": "select * from `{p}.marts.mart_waste_analysis`",
    "channel_daily": "select * from `{p}.marts.mart_channel_performance_daily` order by report_date, outlet_id",
    "orders_hourly": "select * from `{p}.marts.mart_orders_hourly`",
}


def _json_default(value):
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (dt.date, dt.datetime)):
        return value.isoformat()
    raise TypeError(f"tipe tidak didukung: {type(value)}")


def main() -> None:
    client = bigquery.Client(project=PROJECT, location=LOCATION)
    config = bigquery.QueryJobConfig(
        maximum_bytes_billed=2_000_000_000,
        labels={"app": "dashboard_export"},
    )
    OUT.mkdir(parents=True, exist_ok=True)
    counts = {}
    for name, sql in EXPORTS.items():
        result = client.query(sql.format(p=PROJECT), job_config=config).result()
        banned = [f.name for f in result.schema if BANNED_COLUMNS.search(f.name)]
        if banned:
            raise SystemExit(f"{name}: kolom terlarang untuk dipublikasikan: {banned}")
        rows = [dict(r.items()) for r in result]
        payload = json.dumps(rows, default=_json_default, sort_keys=True, separators=(",", ":"))
        if len(payload.encode()) > MAX_FILE_BYTES:
            raise SystemExit(f"{name}: melebihi {MAX_FILE_BYTES} byte; agregasi lebih tinggi")
        (OUT / f"{name}.json").write_text(payload, encoding="utf-8")
        counts[name] = len(rows)
    meta = {"generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"), "rows": counts}
    (OUT / "meta.json").write_text(json.dumps(meta, sort_keys=True, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
```

Catatan:
- Daftar kolom final ditentukan saat marts selesai (Fase 5). `select *` aman hanya karena marts sudah bebas PII dan diperiksa oleh guard di script.
- Mart baru **`mart_orders_hourly`** (grain: outlet × kanal × hari-dalam-minggu × jam; ukuran kecil) ditambahkan di Fase 5 untuk heatmap. Sebelumnya heatmap membaca `fct_orders` di dataset `core`, yang tidak boleh diakses `sa-export`.
- Total ukuran semua JSON ditargetkan < 5 MB agar halaman termuat cepat. Jika `channel_daily` terlalu besar, agregasi ke mingguan.

### 10.5 Halaman dashboard

Satu halaman dengan navigasi tab (pola seperti proyek Tokopedia). Header menampilkan "Data per `meta.generated_at_utc`" dan tautan ke dbt docs (GitHub Pages), repo, dan unduhan JSON mart.

| Tab | Sumber JSON | Isi |
|---|---|---|
| **Executive P&L** | `pnl_monthly`, `pnl_daily`, `kpi_status` | Kartu KPI: Net Sales, Food Cost %, Prime Cost %, Waste %, EBITDA margin, dengan delta bulan lalu. Tren harian (bar + garis food cost % dengan garis threshold dari `kpi_status`). **Waterfall P&L** dihitung di JS dari `pnl_monthly`: Net Sales → Cost of Sales → Channel Commission → Payment Fees → Labor → Other Opex → Outlet EBITDA. Filter outlet dan bulan |
| **Cost Control** | `inventory_variance`, `waste` | Top 10 bahan dengan `unexplained_variance_value` terbesar (overpour susu KIOSK-02 harus terlihat). Waste per alasan, dipisah `controllability`. Garis theoretical vs actual food cost % per bulan |
| **Menu Engineering** | `menu_engineering` | Scatter: X = `menu_mix_pct`, Y = rata-rata contribution margin, warna = `menu_class`, garis referensi 0,7/N dan CM rata-rata tertimbang. Tabel aksi per kelas: Star, Plowhorse, Puzzle, Dog |
| **Channel & Jam Ramai** | `channel_daily`, `orders_hourly` | Net sales vs contribution after channel per kanal (dampak komisi GoFood 2026-04). Heatmap jam × hari (CSS grid) per kanal |
| **Simulator** | `pnl_monthly`, `menu_engineering` | Simulator what-if seperti simulator margin di proyek Tokopedia: geser komisi platform, harga menu, dan food cost %, lalu lihat perubahan margin per kanal dan EBITDA bulanan. Hitungan sepenuhnya di sisi browser |

Standar tampilan: format mata uang IDR, persentase, dan tanggal lokal `id-ID`. Setiap grafik punya judul, satuan, dan keterangan metrik yang merujuk ke glossary (§7.13). Halaman harus responsif dan terbaca di layar ponsel.

### 10.6 Job export di GitHub Actions

Ditambahkan di akhir `daily_pipeline.yml` (blok lengkap di §8.1). Ringkasannya:

- Auth lewat WIF sebagai `sa-export` (`dataViewer` pada dataset `marts` saja, `jobUser` pada project).
- Menjalankan `dashboard/export_marts.py`, lalu `git commit` dan `git push` ke `main` hanya bila ada perubahan data.
- Jika `main` dilindungi branch protection, beri bypass untuk `github-actions[bot]` pada ruleset, atau push ke branch `data` yang dijadikan Production Branch di Vercel.

### 10.7 Guardrail

- Hanya dataset `marts` yang dibaca; `sa-export` tidak punya akses ke `raw_fnb`, `stg`, `int`, dan `core`.
- `export_marts.py` menolak kolom berpola PII dan file > 1,5 MB.
- PII guard CI (§8.2) juga memeriksa isi `dashboard/public/data/*.json` terhadap pola email/nomor telepon.
- Pengunjung dashboard tidak memicu query BigQuery, sehingga tidak ada risiko biaya dari trafik publik.
- Alert email KPI tetap lewat Apps Script (§9); dashboard Vercel hanya untuk tampilan.

---

## 11. Observability & dokumentasi

| Lapisan | Alat (gratis) | Implementasi |
|---|---|---|
| Freshness | `dbt source freshness` | Step pertama job transform; gagal jika transaksi > 50 jam |
| Data tests | dbt generic/singular/unit | Di `dbt build`; `store_failures` untuk investigasi |
| Anomali volume/skema | elementary (OSS) | Fase 3: `elementary.volume_anomalies` pada `fct_order_lines`, `mart_pnl_daily`; hasil di `ops_elementary` |
| Report | `edr report` → HTML statis | Opsional ke GitHub Pages. **Matikan sampel baris** (`test_sample_row_count: 0`) sebelum publish |
| Biaya | `INFORMATION_SCHEMA.JOBS` + label dbt | Query di §6.4; bisa dijadikan tab dashboard |
| Pipeline | GitHub Actions | Notifikasi email bawaan saat workflow gagal |
| Reporting | `_sync_log` + email error Apps Script | §9 |
| Docs | dbt docs di GitHub Pages | Lineage sampai exposure (Sheets & dashboard Vercel) |

---

## 12. Adopsi dari blueprint common

| Praktik blueprint | Status | Bentuk di v2 (BigQuery) |
|---|---|---|
| Layering Base → Dim/Fact → Mart, `source()` hanya di Base | **Diadopsi** | staging → core → marts (+ intermediate costing) |
| Konvensi nama & YAML berawalan `_` | **Diadopsi** | §7.1 |
| `persist_docs`, glossary `{% docs %}`, header komentar mart (tujuan/grain/rumus) | **Diadopsi** | §7.9, §7.13 |
| Source freshness | **Diadopsi** | §7.4 |
| PII masking | **Diadaptasi** | Snowflake masking policy diganti hash + salt di staging, isolasi dataset, dan CI guard |
| Salt di secret, bukan `vars` | **Diadopsi + diperkuat** | Salt di tabel BigQuery terbatas, sehingga tidak masuk compiled SQL/docs |
| Daftar role PII terpusat | **Diadaptasi** | Tabel IAM per SA per dataset (§6.3) |
| Incremental + lookback + full refresh mingguan | **Diadopsi** | `insert_overwrite` partisi + `_dbt_max_partition` |
| Snapshot `timestamp`, schema terpisah, dev ≠ prod | **Diadopsi** | YAML snapshot (§7.11) |
| Prefer histori di sumber dibanding snapshot | **Diadopsi** | Tabel effective-dated di OLTP |
| Seeds kecil, `column_types`, effective-dated | **Diadopsi** | `kpi_thresholds`, `id_calendar_events` |
| Piramida test, unit test, `severity: warn` beralasan | **Diadopsi** | §7.12 |
| SQLFluff di PR (non-blocking dulu, lalu blocking) | **Diadopsi** | Dialek BigQuery, huruf kecil |
| Slim CI `state:modified+ --defer` | **Diadopsi** | §8.2 |
| `query_tag` per target | **Diadaptasi** | `query-comment.job-label` + `labels` BigQuery |
| Target dev/ci/prod, schema dev per user | **Diadopsi** | `generate_schema_name` + profiles |
| Pin package + `package-lock.yml`, satu `requirements.txt` | **Diadopsi** | §7.2 |
| audit_helper reconciliation | **Diadopsi** | v1 → v2 (§7.15) |
| elementary observability | **Diadopsi bertahap** | Fase 3 |
| Date spine sebagai kalender master | **Diadopsi** | `util_dates` → `dim_date` + kalender Indonesia |
| Exposures / lineage ke konsumen | **Ditambahkan** | §7.14 (tidak ada di blueprint) |
| `dbt_snow_mask`, key-pair auth, ukuran warehouse | **Tidak relevan** | Khusus Snowflake |
| Cross-project checker / dbt Mesh | **Ditunda** | Single repo; relevan bila ada konsumen repo lain |
| Generator model berbasis LLM | **Opsional** | Bukan kebutuhan portofolio inti |
| Dockerfile untuk dbt | **Opsional** | `setup-python` + requirements pin sudah cukup reprodusibel |

---

## 13. Roadmap implementasi & checklist

### 13.1 Struktur monorepo

```
fnb-data-platform/
├── .github/workflows/        daily_pipeline.yml · pr_ci.yml
├── infra/                    bootstrap_gcp.sh · bigquery_setup.sql (dataset, grant, salt)
├── oltp/
│   ├── schema/               001_schema.sql (§3.3) · 002_seed_master.sql
│   └── generator/            generate.py · config.yaml · requirements.txt
├── ingestion/                pipeline.py · requirements.txt
├── dbt/                      (§7)
├── apps_script/              appsscript.json · Code.gs · Dashboard.html · .clasp.json
├── dashboard/                export_marts.py · requirements.txt · public/ (index.html, style.css, app.js, data/*.json)
├── scripts/                  check_pii_columns.py
├── .env.example              (tanpa nilai; .env di-gitignore)
└── README.md                 setup per OS, env var, cara run, kamus tag
```

### 13.2 Fase

| Fase | Durasi | Deliverable | Definition of Done |
|---|---|---|---|
| 0. Fondasi | 1–2 hari | GCP project + billing + quota 20 GB/hari + budget, dataset, SA, WIF, Neon ×1, repo | `bq ls` menampilkan dataset; budget alert aktif; GitHub Actions bisa auth tanpa key |
| 1. Source DB | 3–4 hari | DDL v2, seed master, generator + backfill | 29 tabel terisi; ukuran < 300 MB; constraint tidak dilanggar; story events tertanam |
| 2. Ingestion | 1–2 hari | dlt pipeline + job `ingest` | Raw = jumlah baris OLTP; run kedua hanya memuat delta |
| 3. Staging & costing | 3–4 hari | 29 stg, util_dates, int_item_explosion/std_cost, unit test | `n_components_missing_cost = 0`; unit test lulus; PII guard lulus |
| 4. Core & finance marts | 4–5 hari | dim/fct, opex allocation, mart_pnl_daily/monthly, kpi status, seeds | Test reconciliation opex lulus; food cost bulanan dalam rentang 25–40% |
| 5. Operations marts | 3 hari | inventory variance, waste, menu engineering, channel, `mart_orders_hourly` | Story events (susu, overpour KIOSK-02, komisi GoFood) terlihat di mart |
| 6. Serving | 3–4 hari | Apps Script (sync, alert, web app) + dashboard Vercel (5 tab) + job `export-dashboard` | Email alert terkirim sekali per perubahan; dashboard Vercel live, memuat < 3 detik, menampilkan `generated_at` terbaru |
| 7. Hardening | 2–3 hari | PR CI, sqlfluff, docs Pages, PII guard untuk JSON dashboard, elementary, exposures, README | PR contoh lulus slim CI; docs online; lint menjadi blocking |

### 13.3 Checklist pre-production

- [ ] Billing aktif, custom quota 20 GB/hari, budget alert USD 1, `maximum_bytes_billed` di semua client
- [ ] Tidak ada JSON key sama sekali (semua lewat WIF); `.gitignore` berisi `*.json` key, `.env`, `target/`
- [ ] Raw & stg tidak bisa diakses `sa-export`/Apps Script (uji dengan query langsung)
- [ ] Salt hanya ada di `ops_secrets.pii_salt`; `grep -r salt dbt/target` tidak menemukan nilai salt
- [ ] Semua versi dipin: dbt, dbt-bigquery, packages, dlt, google-cloud-bigquery (export), GitHub Actions (SHA)
- [ ] `dbt build` hijau dua hari berturut-turut; full refresh mingguan menghasilkan angka yang sama dengan incremental (cek dengan audit_helper)
- [ ] Opex reconciliation, payment balance, dan menu-has-recipe test lulus
- [ ] Alert Apps Script diuji dengan menurunkan threshold sementara di seed
- [ ] README: cara setup lokal (`gcloud auth application-default login`, `DBT_USER`), kamus tag (`finance`, `operations`, `daily`, `mart`)
- [ ] Vercel: project terhubung ke repo, Root Directory `dashboard/public`, deploy otomatis setelah job export; halaman menampilkan `generated_at` hari ini
- [ ] `dashboard/public/data/*.json` bebas PII dan total < 5 MB
