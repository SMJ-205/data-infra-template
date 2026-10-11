# Daftar Perbaikan: `SMJ-205/data-infra-template`

**Lingkup:** seluruh repo (commit `884369f`) + situs live `data-infra-template-public.vercel.app`.
**Metode:** baca kode tanpa eksekusi (dibagi tiga area: dbt; OLTP/generator/ingestion/infra; CI/Apps Script/dashboard) dan inspeksi JSON live di browser. Temuan paling berat sudah dicek ulang langsung ke kode.

**Prioritas:**
- **P0** = angka di dashboard publik salah, pipeline akan rusak, atau ada celah keamanan.
- **P1** = hasil menyesatkan, atau ada risiko operasional nyata.
- **P2** = hygiene, edge case, atau optimasi.

---

## Ringkasan

| Prioritas | Jumlah | Tema utama |
|---|---|---|
| P0 | 10 | Opex MTD = 0, pembanding periode keliru, refund termasuk pajak, snapshot menulis ke prod, export akan berhenti ~Feb 2027, CI menghapus dataset PR lain, backfill satu transaksi, WIF terlalu longgar, hari tanpa data ikut dihitung, HPP prep hilang diam-diam |
| P1 | 19 | Threshold KPI, menu engineering dobel, inkonsistensi chart, inventory variance prep, alokasi opex, test yang kurang, cache, workflow guard, retensi Neon, versi dlt, data generator |
| P2 | 30+ | CSV/pagination, edge case dbt, PII guard, README, XSS/CSP, hygiene CI |

**Yang sudah baik:**
- Tidak ada secret di repo maupun git history (21 commit diperiksa).
- Tidak ada PII di JSON publik.
- Semua kolom staging cocok dengan skema OLTP.
- Logika effective-dating `[from, to)` konsisten.
- Unit test explosion benar.
- Rasio di dashboard dihitung ulang dari total, bukan rata-rata dari rata-rata.
- Pagination di Apps Script benar.
- Cron dan timezone benar.
- CHECK constraint di tabel `orders` selalu terpenuhi oleh generator.

---

## P0: Kerjakan dulu

| # | Area | Lokasi | Masalah | Dampak terlihat | Perbaikan |
|---|---|---|---|---|---|
| 1 | Generator + dbt | `generate.py` (`opex_rows` hanya dipanggil `if is_month_end(day)`); `fct_opex_allocated_monthly.sql` | Opex baru diposting di hari terakhir bulan | **Live:** Oktober (MTD) labor & opex = 0 → EBITDA margin 63%, prime cost = food cost, "+40,6 pp vs periode lalu" | Accrual di dbt: untuk bulan belum lengkap, pakai run-rate opex bulan sebelumnya (atau seed `opex_budget`) dengan flag `is_opex_estimated`. Ganti dengan aktual saat bulan tutup |
| 2 | Dashboard | `app.js:371-372` | Periode pembanding = N hari tepat sebelum rentang | **Live:** 1–9 Okt dibandingkan 22–30 Sep (ada payday) → −Rp38,2 jt (merah). Pembanding apple-to-apple 1–9 Sep → **+Rp16,5 jt (+3,7%)** | Untuk preset MTD/bulan: bandingkan dengan tanggal yang sama bulan lalu. Untuk custom range: tetap N hari sebelumnya, beri label rentang pembanding |
| 3 | dbt + generator | `mart_pnl_daily.sql:43-46,75`; `generate.py:480-484` | `refund_amount` level order = total **termasuk PB1 & service charge**; level item = `qty × unit_price` tanpa diskon/modifier. Keduanya dikurangkan dari net sales (ex-tax) | Refund penuh order net 50.000 / total 55.000 → kontribusi order −5.000, bukan 0. Mart kanal/kategori/menu tidak dikoreksi refund, jadi tidak tie-out ke P&L | Di dbt, konversi refund ke net ex-tax: level order × `net_sales/total_amount`, level item pakai `net_sales_amount` line. Pajak yang dikembalikan dilaporkan terpisah. Di generator, hitung refund item dari net paid line |
| 4 | dbt | `snapshots/snap_*.sql:5,9` | `target_schema='snapshots'` mem-bypass `generate_schema_name` | Run dev/CI menulis ke dataset `snapshots` **prod** → riwayat SCD2 rusak. Di CI gagal permission (SA CI hanya viewer), termasuk PR yang menyentuh `stg_pos__menu_items`/`outlets` | Hapus `target_schema` (pakai `+schema: snapshots` di project). Ganti `invalidate_hard_deletes=True` dengan `hard_deletes='invalidate'` |
| 5 | Export | `export_marts.py:18,103-104` | Batas keras 2,5 MB per file. `channel_daily` 1,93 MB dan `category_daily` 1,89 MB, masing-masing tumbuh ~4 KB/hari | Mulai **~akhir Feb 2027** export gagal setiap hari dan dashboard publik membeku tanpa peringatan. Total JSON 5,3 MB dimuat sekaligus | Bulatkan angka (`round(x, 0)` untuk uang, 2 desimal untuk %), daftar kolom eksplisit, buang kolom turunan/berulang, jendela bergulir (mis. 400 hari) atau format kolumnar. Beri warning di 80% batas |
| 6 | CI | `pr_ci.yml:69`, tanpa `concurrency` | `grep "^dbt_ci_pr${PR_NUMBER}"` tanpa terminator; dua run di PR yang sama berjalan paralel | Cleanup PR #1 menghapus dataset PR #10, #12, #100… yang sedang dipakai. Cleanup run A menghapus dataset run B | `grep -E "^dbt_ci_pr${PR_NUMBER}(_\|$)"` + `concurrency: {group: pr-ci-${{ github.event.number }}, cancel-in-progress: true}` |
| 7 | Generator | `generate.py:753-756`, `cmd_backfill` / `cmd_daily` | psycopg 3 non-autocommit: `Master(conn)` membuka transaksi implisit, sehingga `with conn.transaction()` hanya membuat **savepoint**. Commit baru terjadi saat koneksi ditutup | Backfill ±466 hari (~1,3 jt baris) = satu transaksi. Koneksi Neon putus di hari ke-400 → semua rollback, padahal log menyatakan batch selesai | `conn.commit()` setelah load master/state, atau `conn.autocommit = True` dan pertahankan blok `transaction()` |
| 8 | Infra (keamanan) | `bootstrap_gcp.sh:67-75`; `bigquery_setup.sql:46-47` | WIF hanya mengecek `repository`. Keempat SA (ingest, dbt, ci, export) bisa diimpersonasi workflow apa pun dari branch apa pun. SA CI bisa membaca `ops_secrets.pii_salt` + raw PII | Kode PR (`pr_ci`) bisa menimpa raw/marts prod atau membaca salt, sehingga hash telepon/email bisa di-brute-force | Mapping `attribute.ref` + `attribute.repository_id`. SA prod hanya untuk `refs/heads/main` (atau GitHub environment). Cabut akses `ops_secrets` & raw dari SA CI, pakai salt CI terpisah |
| 9 | dbt | `mart_pnl_daily.sql:13-15` | Spine sampai `current_date` | **Live:** 10–11 Okt muncul dengan sales 0 (dan opex penuh begitu #1 diperbaiki), sehingga ada baris EBITDA negatif setiap hari. Data terakhir 9 Okt, padahal job 00:30 WIB 11 Okt seharusnya sudah memuat 10 Okt | Batasi ke `max(order_date)` yang sudah ter-ingest (atau `current_date - 1`). Ekspos `data_through` di `meta.json`. Investigasi kenapa data tertinggal 1 hari (urutan job generate → ingest → export) |
| 10 | dbt | `int_item_explosion_daily.sql:69-82` | Prep item tanpa resep berlaku pada tanggal d terbuang lewat inner join, sehingga `n_components_missing_cost` tidak pernah menghitungnya | Celah satu hari antar versi resep prep → Kopi Susu Aren dihitung hanya dari espresso. COGS understated, semua test tetap lulus | Left join `prep_to_raw` dan keluarkan baris ber-ingredient NULL (terhitung missing), **atau** singular test "setiap komponen prep di resep aktif punya resep prep aktif pada tanggal yang sama" |

---

## P1: Menyesatkan / risiko operasional

| # | Area | Lokasi | Masalah & dampak | Perbaikan |
|---|---|---|---|---|
| 11 | Seed KPI | `kpi_thresholds.csv` | **Live:** `channel_cost_pct` CLOUD-03 CRITICAL di **semua 16 bulan**. Threshold 13% tidak masuk akal untuk outlet 100% online, jadi alert jadi noise permanen | Threshold per `outlet_type`, atau ubah metrik menjadi komisi / **online** net sales |
| 12 | Dashboard | `app.js:1180-1284` | Menu Engineering dengan "Semua Outlet": setiap menu muncul **3×** (per outlet) dengan kelas berbeda | Agregasi lintas outlet lalu hitung ulang mix & kelas, atau wajibkan pilih satu outlet di tab ini |
| 13 | Dashboard | `app.js:713,726` vs `564,581` | Garis tren "Food Cost %" memakai `cogs_standard`, sedangkan kartu memakai `cost_of_sales` (+ waste), jadi angkanya beda di layar yang sama | Pakai field yang sama (dan label yang sama: theoretical vs actual) |
| 14 | dbt | `mart_inventory_variance.sql`, `fct_inventory_movements_daily.sql` | Prep item ikut di-stock-count, tetapi pergerakannya diurai ke raw. Variance prep = opening − closing, cost NULL, terbuang dari P&L. Sisa sirup di rak tercatat sebagai kehilangan gula aren palsu (~Rp24 rb/minggu, lalu berbalik) | Kecualikan prep dari perbandingan count dan tambahkan stok prep (ekuivalen raw) ke opening/closing raw. Alternatif: model produksi prep |
| 15 | dbt | `fct_opex_allocated_monthly.sql:52,60,64`; `tests/assert_opex_reconciles.sql:15` | Opex di luar periode aktif outlet terbuang lewat inner join. `1 / n_outlets` membuat uang jadi FLOAT64. Test rekonsiliasi memakai inner join, sehingga bulan yang hilang total tidak pernah gagal | Bucket "Unallocated", `cast(1 as numeric) / n_outlets`, test `sum(allocated) = sum(source)` per bulan dengan full outer join |
| 16 | dbt | `_core__models.yml` | Tidak ada `not_null` pada `fct_order_lines.std_cost_per_unit` (where `is_revenue_line`) dan `fct_waste.waste_cost_amount`. NULL hilang dalam `sum()` di mart | Tambah test tersebut + relationships `order_items → orders` + rekonsiliasi `Σ net line + service + tax = total_amount` |
| 17 | dbt | `fct_order_lines.sql:22-24` | Lookback tetap 3 hari: perbaikan cost/resep retroaktif, void, dan sync telat > 3 hari menunggu full refresh Senin. Sementara itu `fct_orders` (table) sudah berubah, sehingga keduanya tidak konsisten | Volume ±1,6 rb order/hari: jadikan `table` biasa. Alternatif: pilih partisi yang diproses ulang berdasarkan `updated_at` |
| 18 | dbt | `_pos__sources.yml` | Tidak ada `loaded_at_field`/`freshness`, sehingga `dbt source freshness` di pipeline tidak memeriksa apa-apa. Telatnya data #9 tidak terdeteksi | `loaded_at_field: updated_at` + warn 26 jam / error 50 jam pada tabel transaksi |
| 19 | Apps Script | `Code.gs:192-195` | Signature dedupe memakai `metric_value`, yang berubah setiap hari untuk baris MTD → email terkirim **setiap pagi** | Signature dari `(month, outlet, metric_code, status)`. Kirim hanya alert yang baru atau naik level |
| 20 | Export (privasi) | `export_marts.py:19-57` | 6 dari 9 export `select *` ke repo & situs publik. Guard hanya regex nama kolom | Allowlist kolom eksplisit per file |
| 21 | Vercel | `dashboard/vercel.json:9` (+ duplikat di `public/`) | `/data/*` di-cache `max-age=3600, stale-while-revalidate=86400` tanpa versi. Browser bisa mencampur JS baru dengan JSON lama, dan antar-file berbeda hari | `meta.json` `no-cache`. Fetch data dengan `?v=${meta.generated_at_utc}`. Hapus `vercel.json` duplikat |
| 22 | CI | `daily_pipeline.yml:6,59,115`; `pr_ci.yml:46` | `workflow_dispatch` dari branch mana pun membangun **prod** (bisa `--full-refresh`) dan push data ke branch itu. Slim CI bisa defer ke manifest branch tersebut | `if: github.ref == 'refs/heads/main'` di job prod + `gh run list --branch main` |
| 23 | CI | `daily_pipeline.yml:141` | `git push` gagal non-fast-forward jika main bergerak selama run → dashboard tidak update hari itu. Catatan: belum ada commit bot "refresh data" di history, jadi jalur ini **belum pernah berjalan sukses** | `git pull --rebase origin main` + retry sekali. Verifikasi end-to-end dengan satu run manual |
| 24 | Neon | `generate.py`, `001_schema.sql:379-390` | 324 MB setelah backfill, +~0,7 MB/hari, tanpa retensi (plan §3.4 belum diimplementasi). Limit 512 MB tercapai **~pertengahan 2027** | Perintah `purge --older-than 12mo` (BigQuery raw tetap menyimpan histori). Pertimbangkan membuang index `updated_at` di tabel master kecil |
| 25 | Ingestion | `ingestion/requirements.txt:1-4`; `pipeline.py:48` | Versi tidak dipin (`dlt>=1.6.0`); `lag` pada cursor dihapus tanpa pengganti | Pin versi eksak. Kembalikan `lag` (aman untuk writer nyata yang commit telat) |
| 26 | Generator | `generate.py:390-401`; `config.yaml:67-69`; `002_seed_master.sql:31-35` | Promo dipakai tanpa cek tanggal (semua berakhir 2026-12-31). Ramadan/Lebaran hanya untuk 2026 | Filter promo by tanggal. Kalender per tahun (2027+) dari config |
| 27 | Generator | config waste | **Live:** waste ≈ 0,1% dari sales (benchmark F&B 2–5%), jadi KPI waste & story "roti EXPIRED musim hujan" tidak pernah terlihat | Naikkan probabilitas spoil/expired, tambahkan mekanisme eksplisit musim hujan untuk bakery |
| 28 | dbt seed | `id_calendar_events.csv` | Libur 2025 H2 (17 Agu, Maulid, Natal) tidak ada. Ramadan 1446H di luar rentang data. **20 Mar 2026 tidak tercatat Ramadan maupun Lebaran.** Tidak ada data setelah 2026 | Lengkapi seed (verifikasi dengan SKB libur nasional) |
| 29 | Dashboard (mobile) | `style.css` / layout tab | **Live:** di 375 px lebar halaman 795 px (scroll horizontal), label tab terpotong | Tab bar `overflow-x: auto` dengan `white-space: nowrap`, grid kartu 1 kolom, cek elemen yang memaksa lebar (tabel/chart `min-width`) |

---

## P2: Hygiene, edge case, optimasi

**Dashboard (`app.js`)**
- `:1612` Ekspor CSV: `String(r[c] || '')` membuat `0`/`false` kosong dan mengabaikan hasil pencarian. Ganti `r[c] ?? ''` dan ekspor `filtered`.
- `:1564-1567` Tombol "Next" pagination tanpa batas atas. Clamp ke `ceil(total / pageSize)`.
- `:88-92` `dateAddDays` mencampur UTC dan lokal, bisa geser satu hari di zona DST. Pakai `setUTCDate`.
- `:543` `hasPrev` tidak mengecek kelengkapan periode pembanding (rentang dekat 2025-07-01).
- `:879-889` Waterfall tidak memasukkan refund, dan berupa bar absolut, bukan floating step.
- Heatmap mengabaikan filter tanggal. Cost-gap mengikutkan bulan berjalan. Kanal mengabaikan filter kategori. Periode variance yang hanya overlap sebagian dihitung penuh (`:1017`).
- `:463,623,635,647` Target KPI di-hardcode dan berbeda aturan dengan seed dbt. Ambil dari `kpi_status.json`.
- `innerHTML` untuk field data (`:997,1274,1592,1600`, juga `Dashboard.html`) tanpa CSP, dan Chart.js tanpa SRI. Escape atau pakai `textContent`, tambahkan header CSP.
- `loadData` tanpa cek `res.ok`, dan memuat semua 9 file di awal. Lazy-load per tab.
- Simulator membangun ulang chart pada setiap `input`. Pakai `chart.update()`.
- Category pills berupa `div` tanpa `role`/`tabindex`, sehingga tidak bisa dipakai lewat keyboard.

**dbt**
- `fct_order_lines.sql:88-95` Basis alokasi diskon order seharusnya `gross − line_discount`.
- `mart_kpi_monthly_status`: `inventory_variance_pct` harus dievaluasi `abs()`, karena variance negatif besar juga anomali.
- `stg_pos__customers` (view): pembaca view butuh akses ke salt. Materialisasi sebagai table, pakai `any_value(salt)`, normalisasi telepon ke E.164 sebelum hash.
- `dim_date.sql:34-37`: pasangkan `isoweek` dengan `isoyear`, bukan `year`.
- `dbt_project.yml:51-52` mengonfigurasi `elementary` yang tidak terpasang. `dbt_expectations` terpasang tapi tidak dipakai. Rapikan.
- Optimasi: partisi `int_item_explosion_daily`/`int_item_std_cost_daily` by `date_day`, cluster `item_type, item_id`.
- Snapshot tidak dipakai model mana pun. Gunakan untuk dimensi historis di `mart_category_performance_daily`, atau hapus.
- `exposures.yml:22-30`: tambahkan `mart_category_performance_daily` ke exposure `vercel_dashboard`.

**Generator / ingestion / skrip**
- `generate.py:197-204`: urutan customer pool berbeda antara backfill dan daily, sehingga hasilnya tidak reproducible. Urutkan by `customer_id`.
- `generate.py:739-740`: `ON CONFLICT DO NOTHING` tanpa cek. Log atau raise jika `inserted < sent` di luar set yang diharapkan.
- `reset` / `apply-schema --drop` tidak terpropagasi ke BigQuery raw. Dokumentasikan, atau sediakan jalur full refresh raw.
- `scripts/reconcile_neon_bigquery.py:22`: URL `postgresql+psycopg2://` ditolak libpq. Lokasi BigQuery di-hardcode. Kesetaraan count akan gagal setelah retensi; ganti menjadi `BQ ≥ Neon` atau filter tanggal.
- `scripts/check_pii_columns.py`: hanya mengecek kolom yang ada di YAML, error parse ditelan, regex kurang (`name`, `mobile`, `dob`, `hp`). Cek dari `manifest.json`/`catalog.json`.
- `bootstrap_gcp.sh:91-94`: budget `1USD` gagal untuk billing account IDR. Jadikan mata uang dan nominal sebagai parameter.

**CI**
- Upload `dbt/target` utuh ke Pages, termasuk saat docs gagal. Publikasikan hanya `index.html`, `manifest.json`, `catalog.json`.
- `id-token: write` di level workflow juga diwarisi job `generate`. Pindahkan ke level job.
- Path filter PR CI tidak mencakup `dashboard/**`, `ingestion/**`, `.github/workflows/**`. PR dari fork selalu gagal auth.
- `bq ls` default maksimal 50 dataset. Tambahkan `--max_results=1000` + job cleanup saat PR ditutup.
- Run manual yang masih pending tergantikan oleh schedule (concurrency group).
- Pin actions ke commit SHA.

**Dokumentasi**
- README: "6 gerai" (aktual 3), "overpour sirup KIOSK-02 / spoilage susu KIOSK-01" (aktual: overpour susu KIOSK-02, KIOSK-01 tidak ada), komisi "20%" (aktual GoFood 20→22%, ShopeeFood 18%), "depresiasi peralatan" (tidak ada), quota "diset permanen" (masih manual), file `LICENSE` tidak ada, langkah lokal kurang `apply-schema` / `init-master` / `backfill`.
- `.env.example`: pola dataset dev salah (`dev_<user>_*` vs `dbt_<user>`). `ALERT_EMAIL` tidak dipakai.

---

## Urutan pengerjaan yang disarankan

1. **Hari 1, keamanan & keselamatan data:** #8 (WIF), #4 (snapshot), #6 (CI cleanup), #7 (transaksi generator), #22 (guard branch).
2. **Hari 2–3, angka di dashboard publik:** #1 (accrual opex), #2 (pembanding), #3 (refund), #9 (data-through), #11, #12, #13.
3. **Hari 4, ketahanan pipeline:** #5 (ukuran export + allowlist #20), #18 (freshness), #23 (push + verifikasi end-to-end), #21 (cache), #25 (pin dlt).
4. **Hari 5, kebenaran costing:** #10, #14, #15, #16, #17 + test baru.
5. **Setelah itu:** #24, #26–#29, lalu P2.

Setiap perbaikan P0/P1 di dbt sebaiknya disertai test yang **gagal sebelum** diperbaiki, misalnya:
- singular test refund tie-out;
- test komponen prep tanpa resep;
- rekonsiliasi opex dengan full outer join;
- `not_null` pada cost di level fact.
