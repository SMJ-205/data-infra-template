-- Akses data HR & Talent (RBAC). TIDAK dijalankan otomatis: review, ganti placeholder, lalu jalankan manual:
--   sed -e "s/<PROJECT_ID>/$PROJECT/g" -e "s/<REGION>/asia-southeast2/g" infra/hr_access.sql \
--     | bq query --use_legacy_sql=false
-- Setelah itu aktifkan model HR: vars.enable_hr = true di dbt/dbt_project.yml.
--
-- Lapisan akses:
--   raw_fnb        PII & gaji mentah        -> sa-ingest (tulis), sa-dbt (baca)            [sudah ada]
--   hr_restricted  PII & gaji individual    -> HR Manager, sa-dbt
--   hr             analitik ter-masking     -> HR Manager, HR/People Analyst, sa-dbt
--                  (+ row-level security per outlet untuk Outlet Manager, via var hr_row_access dbt)
--   stg            tanpa PII HR (dibuang/di-hash) -> tetap seperti grant yang ada
-- Analis TIDAK mendapat akses raw_fnb maupun hr_restricted, sehingga hanya melihat data ter-masking.

CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.hr_restricted`
  OPTIONS (location = '<REGION>', description = 'PII & gaji individual karyawan. Akses: HR Manager.');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.hr`
  OPTIONS (location = '<REGION>', description = 'Analitik HR ter-masking (hash, band, k-anonymity).');

-- Pipeline: sa-dbt membangun kedua dataset
GRANT `roles/bigquery.dataEditor` ON SCHEMA `<PROJECT_ID>.hr_restricted`
  TO "serviceAccount:sa-dbt@<PROJECT_ID>.iam.gserviceaccount.com";
GRANT `roles/bigquery.dataEditor` ON SCHEMA `<PROJECT_ID>.hr`
  TO "serviceAccount:sa-dbt@<PROJECT_ID>.iam.gserviceaccount.com";

-- CI (slim CI defer ke prod): hanya dataset ter-masking, tidak pernah restricted
GRANT `roles/bigquery.dataViewer` ON SCHEMA `<PROJECT_ID>.hr`
  TO "serviceAccount:sa-github-ci@<PROJECT_ID>.iam.gserviceaccount.com";

-- HR Manager: data lengkap (restricted) + analitik
GRANT `roles/bigquery.dataViewer` ON SCHEMA `<PROJECT_ID>.hr_restricted`
  TO "group:<HR_MANAGER_GROUP>";
GRANT `roles/bigquery.dataViewer` ON SCHEMA `<PROJECT_ID>.hr`
  TO "group:<HR_MANAGER_GROUP>";

-- HR / People Analyst: hanya analitik ter-masking
GRANT `roles/bigquery.dataViewer` ON SCHEMA `<PROJECT_ID>.hr`
  TO "group:<HR_ANALYST_GROUP>";

-- Pengguna manusia butuh izin menjalankan query (level project), mis.:
--   gcloud projects add-iam-policy-binding <PROJECT_ID> --member="group:<HR_ANALYST_GROUP>" --role="roles/bigquery.jobUser"

-- Row-level security per outlet (Outlet Manager hanya melihat outlet-nya) TIDAK dibuat di sini:
-- tabel yang dibangun ulang dbt kehilangan row access policy-nya. Policy dipasang ulang setiap build oleh
-- post-hook dbt (macros/hr_governance.sql) bila var hr_row_access diisi, contoh di dbt_project.yml:
--   hr_row_access:
--     full_access: ["group:<HR_MANAGER_GROUP>", "group:<HR_ANALYST_GROUP>",
--                   "serviceAccount:sa-dbt@<PROJECT_ID>.iam.gserviceaccount.com",
--                   "serviceAccount:sa-github-ci@<PROJECT_ID>.iam.gserviceaccount.com"]
--     outlets:
--       FLG-01:   ["user:<MANAGER_FLG01_EMAIL>"]
--       KIOSK-02: ["user:<MANAGER_KIOSK02_EMAIL>"]
--       CLOUD-03: ["user:<MANAGER_CLOUD03_EMAIL>"]
-- Outlet Manager juga perlu dataViewer pada dataset hr agar policy bisa berlaku.
