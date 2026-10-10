-- Dataset, grant per dataset, dan salt PII (plan v2.1 §6.2-6.3).
-- Dijalankan oleh infra/bootstrap_gcp.sh, yang mengganti <PROJECT_ID> dan <REGION>.
-- Idempotent: CREATE ... IF NOT EXISTS; GRANT bersifat additive.

CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.raw_fnb`         OPTIONS (location = '<REGION>');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.raw_fnb_staging` OPTIONS (location = '<REGION>');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.stg`             OPTIONS (location = '<REGION>');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.int`             OPTIONS (location = '<REGION>');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.core`            OPTIONS (location = '<REGION>');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.marts`           OPTIONS (location = '<REGION>');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.snapshots`       OPTIONS (location = '<REGION>');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.ops_secrets`     OPTIONS (location = '<REGION>');
CREATE SCHEMA IF NOT EXISTS `<PROJECT_ID>.ops_elementary`  OPTIONS (location = '<REGION>');

-- Salt PII: dibuat sekali (tidak ditimpa bila sudah ada), tidak pernah ditulis di repo/log.
CREATE TABLE IF NOT EXISTS `<PROJECT_ID>.ops_secrets.pii_salt` AS
SELECT GENERATE_UUID() AS salt;

-- sa-ingest: tulis ke raw
GRANT `roles/bigquery.dataEditor` ON SCHEMA `<PROJECT_ID>.raw_fnb`
  TO "serviceAccount:sa-ingest@<PROJECT_ID>.iam.gserviceaccount.com";
GRANT `roles/bigquery.dataEditor` ON SCHEMA `<PROJECT_ID>.raw_fnb_staging`
  TO "serviceAccount:sa-ingest@<PROJECT_ID>.iam.gserviceaccount.com";

-- sa-dbt: baca raw + salt, tulis ke layer transformasi
GRANT `roles/bigquery.dataViewer` ON SCHEMA `<PROJECT_ID>.raw_fnb`
  TO "serviceAccount:sa-dbt@<PROJECT_ID>.iam.gserviceaccount.com";
GRANT `roles/bigquery.dataViewer` ON SCHEMA `<PROJECT_ID>.ops_secrets`
  TO "serviceAccount:sa-dbt@<PROJECT_ID>.iam.gserviceaccount.com";
GRANT `roles/bigquery.dataEditor` ON SCHEMA `<PROJECT_ID>.stg`
  TO "serviceAccount:sa-dbt@<PROJECT_ID>.iam.gserviceaccount.com";
GRANT `roles/bigquery.dataEditor` ON SCHEMA `<PROJECT_ID>.int`
  TO "serviceAccount:sa-dbt@<PROJECT_ID>.iam.gserviceaccount.com";
GRANT `roles/bigquery.dataEditor` ON SCHEMA `<PROJECT_ID>.core`
  TO "serviceAccount:sa-dbt@<PROJECT_ID>.iam.gserviceaccount.com";
GRANT `roles/bigquery.dataEditor` ON SCHEMA `<PROJECT_ID>.marts`
  TO "serviceAccount:sa-dbt@<PROJECT_ID>.iam.gserviceaccount.com";
GRANT `roles/bigquery.dataEditor` ON SCHEMA `<PROJECT_ID>.snapshots`
  TO "serviceAccount:sa-dbt@<PROJECT_ID>.iam.gserviceaccount.com";
GRANT `roles/bigquery.dataEditor` ON SCHEMA `<PROJECT_ID>.ops_elementary`
  TO "serviceAccount:sa-dbt@<PROJECT_ID>.iam.gserviceaccount.com";

-- sa-github-ci: baca semua layer (dataset CI per PR dibuat sendiri lewat role bigquery.user)
GRANT `roles/bigquery.dataViewer` ON SCHEMA `<PROJECT_ID>.raw_fnb`
  TO "serviceAccount:sa-github-ci@<PROJECT_ID>.iam.gserviceaccount.com";
GRANT `roles/bigquery.dataViewer` ON SCHEMA `<PROJECT_ID>.ops_secrets`
  TO "serviceAccount:sa-github-ci@<PROJECT_ID>.iam.gserviceaccount.com";
GRANT `roles/bigquery.dataViewer` ON SCHEMA `<PROJECT_ID>.stg`
  TO "serviceAccount:sa-github-ci@<PROJECT_ID>.iam.gserviceaccount.com";
GRANT `roles/bigquery.dataViewer` ON SCHEMA `<PROJECT_ID>.int`
  TO "serviceAccount:sa-github-ci@<PROJECT_ID>.iam.gserviceaccount.com";
GRANT `roles/bigquery.dataViewer` ON SCHEMA `<PROJECT_ID>.core`
  TO "serviceAccount:sa-github-ci@<PROJECT_ID>.iam.gserviceaccount.com";
GRANT `roles/bigquery.dataViewer` ON SCHEMA `<PROJECT_ID>.marts`
  TO "serviceAccount:sa-github-ci@<PROJECT_ID>.iam.gserviceaccount.com";
GRANT `roles/bigquery.dataViewer` ON SCHEMA `<PROJECT_ID>.snapshots`
  TO "serviceAccount:sa-github-ci@<PROJECT_ID>.iam.gserviceaccount.com";

-- sa-export: hanya marts (JSON dashboard dipublikasikan ke repo publik)
GRANT `roles/bigquery.dataViewer` ON SCHEMA `<PROJECT_ID>.marts`
  TO "serviceAccount:sa-export@<PROJECT_ID>.iam.gserviceaccount.com";
