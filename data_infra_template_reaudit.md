# Audit Ulang: `SMJ-205/data-infra-template` (commit `9d844e4`)

**Dibandingkan dengan:** audit sebelumnya pada `884369f` (lihat `data_infra_template_fix_list.md`).
**Metode:**
- Kode dibaca tanpa dieksekusi, oleh tiga reviewer: dbt; generator, infra & CI; dashboard, export & Apps Script.
- Situs live diperiksa di browser.
- Temuan kritis dicek ulang langsung ke kode.

**Status pipeline:** `daily-pipeline` **masih belum pernah berjalan**. Run otomatis pertama dijadwalkan **Senin 12 Okt ±00:30 WIB (11 Okt 17:30 UTC)**. Karena hari Senin, run itu langsung `--full-refresh`.

---

## 1. Ringkasan

| Kategori | Hasil |
|---|---|
| P0 lama (10 item) | **7 FIXED**, 2 PARTIAL (#3 refund, #8 WIF), 1 FIXED di dbt dengan generator tetap posting opex akhir bulan (#1) |
| P1 lama (19 item) | Sebagian besar FIXED; 7 PARTIAL; #24 (purge Neon) kodenya rusak |
| **Regresi / bug baru yang memblokir** | **2**: test dbt yang selalu gagal (N1) dan tab Menu Engineering crash di situs live (N2) |
| Bug baru lain | 4 MEDIUM, ±10 LOW |

**Kesimpulan:** perbaikannya signifikan dan sebagian besar benar. Tetapi **jika dibiarkan, run otomatis malam ini akan gagal di tahap dbt** (N1), sehingga dashboard tidak ter-update. Tab Menu Engineering juga sudah rusak sekarang di situs publik (N2).

---

## 2. Wajib diperbaiki sebelum run malam ini

| # | Sev | Lokasi | Masalah | Dampak | Perbaikan |
|---|---|---|---|---|---|
| **N1** | CRITICAL | `dbt/tests/assert_order_totals_reconcile.sql:18,30` | Test menghitung `Σ net_sales + service + tax`. Padahal generator mengurangi **semua** diskon order dari total, termasuk promo yang didanai platform (`generate.py:414-420`), sedangkan `net_sales_amount` sengaja **tidak** mengurangi diskon platform (`fct_order_lines.sql:96-101`) | ±15% order online (GOFOOD15, GRAB20, SHOPEE12) selisih sebesar diskonnya. Test (severity error) gagal setiap run → `dbt build` exit non-zero, model hilir `fct_orders` di-skip (refund, P&L, KPI, kanal) → **job export di-skip, dashboard membeku** | Rumus test: `Σ net_sales − Σ platform_funded_discount_amount + service + tax = total_amount` |
| **N2** | CRITICAL (live) | `dashboard/public/app.js:1260` | Deklarasi `latestMonth` terhapus di commit perbaikan | **Terkonfirmasi di situs live:** buka tab Menu Engineering → `ReferenceError: latestMonth is not defined`, chart & tabel kosong | Tambahkan setelah baris 1259: `const latestMonth = (targetMonth && availableMonths.includes(targetMonth)) ? targetMonth : availableMonths[availableMonths.length - 1];` |
| N3 | MEDIUM | `dbt/tests/assert_opex_reconciles.sql:5`; `fct_opex_allocated_monthly.sql:87,90,111` | Bucket `Unallocated` tidak pernah masuk `mart_pnl_daily`. Opex HQ di bulan tanpa basis tetap terbuang. Test juga menganggap setiap bulan sebelum bulan berjalan sudah lengkap, padahal mart dibatasi `max(order_date)` | Test akan gagal (dan memblokir build) jika ada opex di luar periode aktif outlet, atau saat run tanggal 1 sementara data akhir bulan belum ter-ingest. **Kemungkinan tidak terpicu malam ini**, tetapi rawan pada 1 Nov | Filter test `report_month < date_trunc(max_data_date, month)` dan keluarkan bulan `is_opex_estimated`. Tampilkan `Unallocated` sebagai baris terpisah di P&L |

**Saran:** setelah N1 dan N2 diperbaiki, jalankan sekali **Actions → daily-pipeline → Run workflow** dari `main` sebelum jadwal malam, supaya error lain muncul di siang hari.

---

## 3. Langkah manual GCP: perbaikan keamanan WIF (P0 #8) belum aktif

Perubahan di `bootstrap_gcp.sh` hanya berlaku saat provider **dibuat baru**. Di project yang sudah ada, kondisinya sekarang:
- Provider masih memakai mapping lama, sehingga binding baru `attribute.ref/refs/heads/main` tidak pernah cocok.
- Binding lama tingkat repo (`attribute.repository/...`) pada `sa-ingest`, `sa-dbt`, dan `sa-export` **tidak dihapus**. Pipeline masih bisa auth justru karena binding lama ini, dan SA prod masih bisa dipakai dari branch atau PR mana pun.
- Baris GRANT untuk `sa-github-ci` hanya dihapus dari file SQL. GRANT bersifat additive, jadi akses CI ke `raw_fnb` dan `ops_secrets` **masih ada**.

Jalankan **berurutan**. Urutan ini penting agar pipeline tidak terputus.

1. Update mapping provider:
   ```bash
   gcloud iam workload-identity-pools providers update-oidc github-oidc --location=global --workload-identity-pool=github --project=fnb-data-platform --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_id=assertion.repository_id,attribute.ref=assertion.ref"
   ```
2. Pastikan binding `principalSet://.../attribute.ref/refs/heads/main` sudah ada di `sa-ingest`, `sa-dbt`, dan `sa-export` (jalankan ulang bagian binding di bootstrap).
3. Jalankan **wif-smoke-test dari `main`**. Lanjut hanya jika lulus.
4. Hapus binding lama `attribute.repository/SMJ-205/data-infra-template` dari ketiga SA prod (`gcloud iam service-accounts remove-iam-policy-binding ...`).
5. Cabut akses CI:
   ```sql
   REVOKE `roles/bigquery.dataViewer` ON SCHEMA `fnb-data-platform.raw_fnb` FROM "serviceAccount:sa-github-ci@fnb-data-platform.iam.gserviceaccount.com";
   REVOKE `roles/bigquery.dataViewer` ON SCHEMA `fnb-data-platform.ops_secrets` FROM "serviceAccount:sa-github-ci@fnb-data-platform.iam.gserviceaccount.com";
   ```
6. Jalankan smoke test sekali lagi dari `main`.

**Efek samping langkah 5:** PR CI akan gagal saat membangun model staging, karena view staging membaca `raw_fnb` dan salt (N7 di bawah). Siapkan dataset sampel dan salt khusus CI, atau batasi CI ke `--defer`.

`bootstrap_gcp.sh` juga sebaiknya dibuat idempotent untuk perubahan ini: `update-oidc` jika provider sudah ada, `remove-iam-policy-binding` untuk binding lama, dan `REVOKE` eksplisit di `bigquery_setup.sql`.

---

## 4. Status item audit sebelumnya

### P0

| # | Item | Status | Catatan |
|---|---|---|---|
| 1 | Opex MTD = 0 | **FIXED (dbt)** | Accrual dari aktual bulan sebelumnya + flag `is_opex_estimated`. Generator tetap posting akhir bulan, dan itu tidak masalah |
| 2 | Pembanding periode | **FIXED** | Terverifikasi live: "+Rp16,5 jt vs 1–9 Sep (9 hr)" |
| 3 | Refund termasuk pajak | **PARTIAL** | P&L & kanal sudah ex-tax. Mart kategori & menu belum dikoreksi refund. `tax_refunds` dihitung tetapi dibuang |
| 4 | Snapshot menulis ke prod | **FIXED** | `target_schema` dihapus; `hard_deletes='invalidate'` valid di 1.9 |
| 5 | Ukuran export | **PARTIAL** | Pembulatan, allowlist, jendela 450 hari untuk channel/category, dan peringatan 80% sudah ada. Masih kurang: `inventory_variance`, `pnl_daily`, dan `waste` tanpa jendela; warning hanya `print` (bukan `::warning::`); `round(x,0)` tetap menghasilkan `1755362.0` |
| 6 | Cleanup CI + concurrency | **FIXED** | |
| 7 | Transaksi generator | **FIXED** | `autocommit=True` → commit nyata per batch |
| 8 | WIF terlalu longgar | **PARTIAL** | Kode benar, tetapi belum efektif di project yang ada (§3) |
| 9 | Hari tanpa data / data_through | **FIXED** | Spine dibatasi `max(order_date)`; `data_through` ditulis ke meta.json, tetapi belum dibaca `app.js` |
| 10 | Prep tanpa resep | **FIXED (model)** | Left join → baris NULL terhitung missing cost. Singular test barunya tidak bisa menangkap celah 1 hari (N12) |

### P1

| # | Status | Catatan |
|---|---|---|
| 11 threshold channel_cost | FIXED | Threshold khusus Cloud Kitchen |
| 12 menu ALL outlet | **REGRESSED** | Logikanya benar, tetapi tab crash (N2) |
| 13 chart vs kartu food cost | FIXED | |
| 14 prep di inventory variance | FIXED | Dikonversi ke ekuivalen raw |
| 15 alokasi opex | PARTIAL | NUMERIC & full outer join sudah. Unallocated hilang dari P&L (N3) |
| 16 test not_null & reconcile | PARTIAL | not_null benar. Reconcile justru memunculkan N1. Relationship `fct_order_lines → fct_orders` tautologis, tidak bisa gagal |
| 17 incremental lookback | FIXED | Jadi `table` |
| 18 source freshness | PARTIAL | Konfigurasi valid, tetapi pipeline masih `dbt source freshness \|\| true`, jadi tidak pernah gagal. `refunds` bervolume rendah akan sering warning |
| 19 dedupe alert | PARTIAL | Kunci sudah tanpa nilai, tetapi tetap satu signature untuk seluruh set. Signature juga tidak di-reset saat set kosong |
| 20 allowlist kolom | FIXED | |
| 21 cache | **PARTIAL (config mundur)** | Versioning `?v=` di client sudah jalan (terverifikasi live). Tetapi `vercel.json` yang efektif (`dashboard/public/`, karena Root Directory Vercel = `dashboard/public`) justru dihapus; yang tersisa `dashboard/vercel.json` diabaikan Vercel |
| 22 guard branch | FIXED | |
| 23 rebase sebelum push | FIXED | |
| 24 retensi Neon | **NOT FIXED (kode rusak)** | `cmd_purge` memakai `fnb.orders.order_date` (kolomnya tidak ada). Urutan delete juga melanggar FK. Belum dijadwalkan |
| 25 pin dlt + lag | FIXED | `dlt==1.6.1`, `lag=3600` |
| 26 promo & kalender | PARTIAL | Filter tanggal promo ada, tetapi **semua promo berakhir 2026-12-31**, jadi mulai 2027 tidak ada promo sama sekali |
| 27 waste rate | PARTIAL | Probabilitas dinaikkan + mekanisme musim hujan. Histori tetap 0,1%, jadi akan ada lonjakan mulai 10 Okt di grafik |
| 28 kalender seed | PARTIAL | Lihat N13 |
| 29 mobile overflow | **PARTIAL** | Tab bar sudah benar. **Live:** halaman masih 795 px di layar 375 px karena grid panel Waterfall & Status KPI melebar mengikuti isi tabel (kolom grid 867 px). Media query baru menarget class yang tidak ada di HTML |

### P2 (ringkas)

- **FIXED:**
  - Dashboard: CSV zeros/filtered, pagination clamp, UTC date math, `chart.update` simulator, pills bisa diakses keyboard, exposures.
  - dbt: basis diskon, `abs()` variance, `iso_year`.
  - Skrip & CI: reconcile script, budget currency, publish docs minimal, `id-token` per job, path filter PR CI, `bq ls` max_results, README/.env/LICENSE.
- **PARTIAL:**
  - `stg_pos__customers`: normalisasi telepon hanya awalan `08`.
  - PII guard: masih hanya mengecek YAML.
  - Packages: `dbt_expectations` masih terpasang tanpa dipakai.
- **NOT FIXED:**
  - Dashboard: `hasPrev` completeness, waterfall tanpa refund, filter yang diabaikan (heatmap, kanal, cost-gap, variance overlap), target KPI hardcode, `innerHTML`/CSP/SRI, `res.ok` + lazy load (halaman kosong ±5 detik saat pertama dibuka).
  - Generator: cek hasil `ON CONFLICT`, urutan customer pool (perubahan dilakukan di sisi yang salah).
  - CI: guard PR dari fork, cleanup saat PR ditutup, pin SHA actions.

---

## 5. Bug baru lainnya

| # | Sev | Lokasi | Masalah | Perbaikan |
|---|---|---|---|---|
| N4 | HIGH | `generate.py:906-911` (`cmd_purge`) | Kolom `order_date` tidak ada di `fnb.orders`. Tidak ada `ON DELETE CASCADE`, sehingga menghapus parent sebelum child melanggar FK | Hapus child dulu: modifiers → refunds → payments → order_items → orders, berbasis `order_id in (select ... where ordered_at < cutoff)`. Sama untuk GR & stock count lines |
| N5 | MEDIUM | `mart_channel_performance_daily.sql:64-68` | Refund di-left-join ke baris order, sehingga refund pada hari tanpa order (mis. H+1 setelah Lebaran tutup) hilang dan tidak tie-out dengan P&L | Full outer join orders × refunds |
| N6 | MEDIUM | `export_marts.py:166,197` vs `app.js:386-404` | Hanya channel/category yang dijendela 450 hari, sementara date picker memakai rentang `pnl_daily` penuh. Preset "ALL" menampilkan P&L lengkap tetapi kategori/kanal terpotong diam-diam | Samakan jendela untuk semua file, atau clamp tanggal minimum di app |
| N7 | MEDIUM | PR CI setelah langkah §3.5 | View staging & `stg_pos__customers` butuh `raw_fnb` + salt | Dataset sampel + salt CI, atau CI hanya `--defer` |
| N8 | MEDIUM | `dashboard/vercel.json` | File yang salah yang dihapus. Header & `cleanUrls` tidak berlaku. Pola `/data/(.*)` juga menimpa aturan no-cache `meta.json` | Kembalikan ke `dashboard/public/vercel.json`, urutkan aturan agar `meta.json` no-cache menang |
| N9 | LOW | `fct_refunds.sql:44,48-51`; `generate.py:470` | Refund level item memakai net line penuh (bukan dibatasi `refund_amount`). Rasio pajak salah basis. Generator tidak mengalikan modifier dengan qty | Batasi net ke `refund_amount`; generator `qty × (price + Σmod) − disc − porsi diskon order` |
| N10 | LOW | `daily_pipeline.yml:106-114` | `cp ... \|\| true` menyembunyikan `index.html` yang hilang, sehingga situs docs kosong bisa ter-deploy | Upload hanya jika `index.html` ada |
| N11 | LOW | `app.js:1252-1306` | Dengan filter kategori + Semua Outlet, kelas menu dihitung ulang hanya dalam kategori itu, sedangkan mode satu outlet memakai kelas full-menu. Kelas bisa beda tergantung pilihan | Konsisten: hitung kelas pada full menu, lalu filter tampilannya |
| N12 | LOW | `tests/assert_active_prep_components_have_recipes.sql:29-30` | Cek overlap tidak bisa gagal untuk celah antar versi | Cek per hari via `util_dates`, atau hapus (model sudah aman) |
| N13 | LOW | `seeds/id_calendar_events.csv` | Isra Mikraj 2027 tercatat 5 Feb (seharusnya sekitar 5–6 Jan). Paskah 2027 tidak ada. Idulfitri 2026 tiga hari (cek SKB vs cuti bersama). Kalender berhenti 2027 sementara spine sampai 2031 | Verifikasi dengan SKB, tambahkan tahun berikutnya |
| N14 | LOW | `generate.py:150-157` + seed promo | Promo otomatis hilang mulai 2027 | Perpanjang `end_date` atau tambah promo 2027 |
| N15 | LOW | `Code.gs:190-198` | `LAST_ALERT_SIG` tidak di-reset saat tidak ada alert, sehingga set alert identik yang muncul lagi nanti tidak terkirim | Hapus property saat set kosong |

---

## 6. Urutan kerja yang disarankan

**Hari ini, sebelum ±00:30 WIB:**
1. Perbaiki N1 (rumus test) dan N2 (`latestMonth`).
2. Jalankan manual `daily-pipeline` dari `main`, lalu pantau sampai job export membuat commit "refresh data" dan Vercel ikut deploy.
3. Aktifkan GitHub Pages (Source: GitHub Actions).

**Minggu ini:**
1. Langkah WIF §3, lalu N7 (dataset/salt CI).
2. N3, N5, P0 #3 (refund di mart kategori/menu).
3. N8 (vercel.json), N6, dan sisa #5 (jendela export).
4. N4 (purge), lalu jadwalkan bulanan.

**Berikutnya:** mobile overflow (`grid-template-columns: minmax(0, 1fr)` + `min-width: 0` pada panel + wrapper tabel `overflow-x: auto`), lazy load, escaping `innerHTML`/CSP, dan sisa P2.
