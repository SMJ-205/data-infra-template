# F&B Data Platform

Portofolio data engineering end-to-end untuk bisnis F&B (multi-outlet), 100% free tier.

```
Neon Postgres (OLTP) --dlt--> BigQuery --dbt Core--> marts --+--> Google Sheets + Apps Script (alert)
                                                             +--> JSON --> Dashboard Vercel (statis)
```

Orkestrasi dan CI memakai GitHub Actions. Dokumentasi dbt di GitHub Pages.

- Rencana lengkap: [fnb_data_platform_implementation_plan_v2.md](fnb_data_platform_implementation_plan_v2.md)
- Status: **Fase 0 (fondasi)** sedang berjalan. Lihat roadmap di plan §13.

## Struktur

| Folder | Isi |
|---|---|
| `infra/` | `bootstrap_gcp.sh`, `bigquery_setup.sql` (dataset, service account, WIF, grant) |
| `oltp/` | DDL OLTP dan generator data simulasi (Fase 1) |
| `ingestion/` | Pipeline dlt Postgres -> BigQuery (Fase 2) |
| `dbt/` | Project dbt (Fase 3-5) |
| `dashboard/` | Export mart -> JSON dan dashboard Vercel (Fase 6) |
| `apps_script/` | Google Sheets + Apps Script (Fase 6) |
| `scripts/` | Utilitas, mis. PII guard |
| `.github/workflows/` | Pipeline harian, CI PR, smoke test WIF |

## Setup Fase 0

Prasyarat manual (sekali):

1. Buat project GCP dan link billing account. Billing wajib aktif karena BigQuery Sandbox tidak mendukung DML.
2. Buat project Neon `fnb-oltp`.
3. Buat repo GitHub (publik) dan salin `.env.example` ke `.env` (jangan di-commit), lalu isi `GCP_PROJECT_ID` dan `GITHUB_REPO`.
4. Login:
   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```

Jalankan bootstrap:

```bash
set -a; source .env; set +a
bash infra/bootstrap_gcp.sh
```

Skrip ini idempotent: mengaktifkan API, membuat 4 service account, Workload Identity Federation (tanpa JSON key), 9 dataset, grant per dataset, salt PII, dan (opsional) budget alert.

Langkah manual setelah bootstrap (dicetak oleh skrip):

1. **Custom quota BigQuery 20 GB/hari** (wajib sebelum job pertama). Ini guardrail utama yang memblokir query secara keras.
2. Isi GitHub Actions variables/secrets (nilai dicetak oleh skrip).
3. Jalankan workflow **wif-smoke-test** dari tab Actions.

## Keamanan

- Tidak ada JSON key di repo maupun GitHub Secrets; akses GCP memakai WIF.
- Repo publik: jangan commit `.env`, connection string, atau output yang mengandung PII.
- Data yang dipublikasikan ke dashboard hanya agregat dari dataset `marts`.
