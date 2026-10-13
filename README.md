# F&B Data Platform

> **Enterprise-Grade Multi-Outlet Food & Beverage Data Platform built with Zero Operational Cost.**
> 
> Menggabungkan **Neon PostgreSQL (OLTP)**, **dlt (Ingestion)**, **Google BigQuery (`asia-southeast2`)**, **dbt Core v1.9 (Transformation & Semantic Costing)**, serta Serving layer ganda: **Vercel Static Dashboard (Chart.js + Kasavana-Smith Matrix)** dan **Google Sheets + Apps Script (Automated KPI & Alerts)**.

---

## Architecture Overview

Platform ini dirancang dengan prinsip **Keyless Security (WIF)**, **Strict Cost Guardrails**, dan **Idempotent Pipelines**.

```mermaid
flowchart LR
    subgraph OLTP["1. Source (OLTP)"]
        NEON[("Neon PostgreSQL<br/>Schema 'fnb' (29 tables)<br/>267k Orders · 1.33M Rows")]
    end

    subgraph INGEST["2. Ingestion"]
        DLT["dlt Pipeline<br/>(Merge & Incremental<br/>updated_at)"]
    end

    subgraph DWH["3. Data Warehouse (BigQuery asia-southeast2)"]
        RAW[("raw_fnb<br/>Raw Tables")]
        STG[("stg<br/>29 Clean Views")]
        INT[("int<br/>Recursive BOM Explosion<br/>Std Cost Daily Engine")]
        CORE[("core<br/>Star Schema Dimensions<br/>& Fact Tables")]
        MARTS[("marts<br/>P&L, Variance, Kasavana-Smith,<br/>Waste & Traffic")]
    end

    subgraph CI_CD["4. Orchestration & CI/CD"]
        GHA["GitHub Actions<br/>• Daily Pipeline (00:30 WIB)<br/>• Slim CI & SQLFluff<br/>• WIF Keyless Auth"]
    end

    subgraph SERVING["5. Serving Layer"]
        VERCEL["Vercel Static Web<br/>• Dark Glassmorphism UI<br/>• 6 Interactive Tabs<br/>• Kasavana-Smith Matrix<br/>• Static JSON (< 5.5 MB)"]
        GSHEETS["Google Sheets & Apps Script<br/>• Daily Cache Sync<br/>• Multi-Channel KPI Alerts<br/>• Web App Dashboard"]
    end

    NEON -->|dlt extract| DLT
    DLT -->|append / merge| RAW
    RAW --> STG
    STG --> INT
    INT --> CORE
    CORE --> MARTS
    MARTS -->|export_marts.py| VERCEL
    MARTS -->|Scheduled Query| GSHEETS
    GHA -.->|Orchestrates| DLT
    GHA -.->|dbt build| DWH
    GHA -.->|Pushes JSON| VERCEL
```

---

## Zero-Cost Guarantee (100% Free-Tier Breakdown)

Seluruh komponen arsitektur berada dalam batas gratis permanen (*free-tier*) tanpa risiko pembengkakan biaya:

| Komponen | Provider | Batas Free-Tier | Konsumsi Platform Ini | Safety Mechanism |
|---|---|---|---|---|
| **OLTP Database** | Neon PostgreSQL | 0.5 GB storage, autosuspend | 324 MB (267k orders, 1.33M rows) | Auto-suspend compute saat idle |
| **Data Warehouse** | Google BigQuery | 10 GB storage, 1 TB query/bln | < 1.5 GB storage, ~80 MB per run | **Hard Quota 20 GB/hari** + `maximum_bytes_billed: 2 GB` |
| **Transformation** | dbt Core v1.9 | Open-source (Free) | Runs on GitHub Actions runner | Local execution / CI runner |
| **CI/CD & Scheduler**| GitHub Actions | 2,000 menit/bln (Public: Unlimited) | ~5 menit per daily run | Concurrency lock + timeout 30m |
| **Serving (Web)** | Vercel | 100 GB bandwidth/bln | ~5.16 MB static JSON bundle | Static-only hosting (no serverless compute) |
| **Serving (Alerts)**| Google Sheets & Apps Script | 6 menit execution/run | Sync run ~40 detik | Read-only cached tabs (no ad-hoc BQ queries) |

> **Kompensasi Keamanan Biaya:** BigQuery Query Quota disarankan diset via GCP Cloud Console ke **0.02 TiB/hari** (~20 GB/hari) dan seluruh query dbt/script dibatasi oleh flag `maximum_bytes_billed: 2000000000` (2 GB). Query apapun yang melebihi batas ini akan langsung di-abort otomatis oleh GCP sebelum dieksekusi.

---

## Fitur Analitik & Business Storytelling

Dataset mensimulasikan jaringan F&B multi-outlet (3 gerai: Flagship Sudirman `FLG-01`, Kiosk Dago Bandung `KIOSK-02`, dan Cloud Kitchen Kemang `CLOUD-03`) dengan cerita bisnis nyata yang tertanam:

1. **Kasavana-Smith Menu Engineering Matrix (`mart_menu_engineering`)**:
   - Kategorisasi menu otomatis: **Stars** (Margin Tinggi, Volume Tinggi), **Plowhorses** (Margin Rendah, Volume Tinggi), **Puzzles** (Margin Tinggi, Volume Rendah), **Dogs** (Margin Rendah, Volume Rendah).
2. **Rekonsiliasi Inventori Teoritis vs Aktual (`mart_inventory_variance`)**:
   - Membandingkan konsumsi resep standar (Theoretical BOM Explosion) terhadap hasil *Stock Opname* fisik bulanan.
   - Mendeteksi anomali nyata seperti *incident overpour susu* di KIOSK-02 (+6% takaran tanpa tercatat di POS) dan *spoilage* berkala pada bahan segar serta bakery di musim hujan.
3. **P&L Harian & Bulanan (`mart_pnl_daily`, `mart_pnl_monthly`)**:
   - P&L Harian berbasis *standard costing* untuk evaluasi cepat manajer gerai.
   - P&L Bulanan berbasis *actual cost of sales* (termasuk variance inventori, alokasi OPEX sewa, utilitas, gaji staf, perbaikan/pemeliharaan, dan pemasaran).
4. **Kinerja Channel & Potongan Komisi (`mart_channel_performance_daily`)**:
   - Transparansi margin antara transaksi *Dine-in/Takeaway* vs *Online Delivery* (GoFood 20% naik ke 22% per 2026, GrabFood 20%, ShopeeFood 18%).
5. **Traffic & Heatmap Operasional (`mart_orders_hourly`)**:
   - Pola lonjakan jam makan siang (11:00–13:00) dan makan malam (18:00–20:00) untuk optimasi jadwal staf barista & dapur.

---

## Struktur Repositori

```
├── .github/workflows/
│   ├── daily_pipeline.yml       # Ingestion harian, dbt build, docs, export JSON
│   ├── pr_ci.yml                # Slim CI, SQLFluff linter, PII guard, CI teardown
│   └── wif_smoke_test.yml       # Verifikasi autentikasi Workload Identity Federation
├── infra/
│   ├── bootstrap_gcp.sh         # Script provisioning GCP idempotent (WIF, SA, dataset)
│   └── bigquery_setup.sql       # DDL dataset, WIF grant, PII salt secret
├── oltp/
│   ├── schema/
│   │   ├── 001_schema.sql       # 29 tabel DDL relasional (fnb schema)
│   │   └── 002_seed_master.sql  # Master outlets, ingredients, menu, BOM recipes
│   └── generator/
│       ├── generate.py          # Generator data deterministik & idempotent
│       └── config.yaml          # Parameter demand, event, dan elastisitas harga
├── ingestion/
│   ├── pipeline.py              # Ingestion dlt Postgres -> BigQuery raw_fnb
│   └── requirements.txt
├── dbt/
│   ├── models/
│   │   ├── staging/pos/         # 29 views pembersihan tipe data & metadata
│   │   ├── intermediate/        # BOM recursion explosion & daily standard costing
│   │   ├── core/                # Star schema (dim_*, fct_*)
│   │   ├── marts/               # Marts analitik P&L, KPI, Kasavana-Smith, Variance
│   │   └── exposures.yml        # Lineage exposure ke Vercel & Google Sheets
│   ├── seeds/                   # kpi_thresholds.csv, id_calendar_events.csv
│   ├── tests/                   # Singular data tests (reconciliation & business logic)
│   └── requirements.txt         # dbt-core, dbt-bigquery, sqlfluff
├── dashboard/
│   ├── export_marts.py          # JSON exporter aman (PII masked, key filtered)
│   ├── vercel.json              # Konfigurasi routing Vercel
│   └── public/                  # Static SPA (HTML5, Vanilla CSS dark glassmorphism, JS)
│       ├── index.html
│       ├── style.css
│       ├── app.js
│       └── data/*.json          # Snapshot data mart publik
├── apps_script/
│   ├── Code.gs                  # Sync BigQuery -> Sheets, deduplicated alert email
│   ├── Dashboard.html           # Embedded Google Sheets web app
│   └── appsscript.json          # Manifest OAuth scopes & BQ Advanced Service
└── scripts/
    ├── check_pii_columns.py     # Linter PII otomatis pada model YAML & JSON ekspor
    └── reconcile_neon_bigquery.py# Verifikasi 100% konsistensi row count OLTP vs DWH
```

---

## Kamus Tag dbt (`dbt tags`)

Gunakan tag dbt untuk menjalankan sub-DAG secara modular dan hemat resource:

| Tag | Deskripsi | Model yang Terkena | Contoh Perintah |
|---|---|---|---|
| `daily` | Model yang wajib diperbarui pada pipeline harian | `staging`, `intermediate`, `core`, `mart_pnl_daily`, dll. | `dbt build --select tag:daily` |
| `finance` | Seluruh model mart keuangan | `mart_pnl_daily`, `mart_pnl_monthly`, `mart_kpi_monthly_status` | `dbt build --select tag:finance` |
| `operations` | Seluruh model mart operasional gerai | `mart_inventory_variance`, `mart_waste_analysis`, `mart_menu_engineering`, `mart_channel_performance_daily`, `mart_orders_hourly` | `dbt build --select tag:operations` |
| `mart` | Seluruh tabel mart analitik akhir | Semua model di `models/marts/` | `dbt build --select tag:mart` |
| `staging` | Layer staging (views) | 29 models di `models/staging/pos/` | `dbt run --select tag:staging` |
| `core` | Layer dimensi dan fakta bintang | Dimensi & fakta di `models/core/` | `dbt build --select tag:core` |

---

## Keamanan & Good Practices

- **Zero Hardcoded Secrets**: Tidak ada file service account JSON key di repositori maupun GitHub Secrets. Seluruh autentikasi GitHub Actions menggunakan Google Cloud Workload Identity Federation (WIF).
- **Automated PII Guard**: Kolom pelanggan sensitif (`full_name`, `phone`, `email`, `address`) otomatis di-masking/hashing via macro dbt dan divalidasi oleh `check_pii_columns.py` sebelum di-publish.
- **Slim CI PR**: Setiap Pull Request memicu workflow `pr_ci.yml` yang menjalankan SQLFluff linter, PII guard, serta membangun hanya model yang berubah (`state:modified+`) pada dataset sementara `dbt_ci_pr<PR_NUMBER>_*` yang otomatis dihapus setelah pengujian selesai.

---

## Lisensi
Platform data ini dilisensikan di bawah [MIT License](LICENSE).
Dikembangkan untuk kebutuhan portofolio arsitektur data modern end-to-end berbiaya Rp 0.
