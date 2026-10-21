#!/usr/bin/env bash
# Bootstrap GCP untuk F&B Data Platform (plan v2.1, §6).
# Idempotent: aman dijalankan ulang. Tidak membuat JSON key (semua keyless via WIF).
#
# Prasyarat (manual, sekali):
#   1. Project GCP sudah dibuat dan billing sudah di-link   (plan §6.1)
#   2. gcloud auth login && gcloud auth application-default login
#   3. export GCP_PROJECT_ID=... GITHUB_REPO=owner/repo     (lihat .env.example)
#
# Opsional: GCP_BILLING_ACCOUNT_ID (untuk membuat budget alert), GCP_REGION.
set -euo pipefail

: "${GCP_PROJECT_ID:?set GCP_PROJECT_ID}"
: "${GITHUB_REPO:?set GITHUB_REPO (format owner/repo)}"
REGION="${GCP_REGION:-asia-southeast2}"
PROJECT="$GCP_PROJECT_ID"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\n==> %s\n' "$*"; }

log "Project: $PROJECT | region: $REGION | repo: $GITHUB_REPO"
gcloud config set project "$PROJECT" >/dev/null
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"

# ---------------------------------------------------------------- API
log "Aktifkan API"
gcloud services enable \
  bigquery.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  billingbudgets.googleapis.com \
  --project "$PROJECT"

# ------------------------------------------------------------ Service account
SERVICE_ACCOUNTS=(sa-ingest sa-dbt sa-github-ci sa-export)
log "Service account"
for sa in "${SERVICE_ACCOUNTS[@]}"; do
  if ! gcloud iam service-accounts describe "$sa@$PROJECT.iam.gserviceaccount.com" >/dev/null 2>&1; then
    gcloud iam service-accounts create "$sa" --display-name "$sa (fnb data platform)" --project "$PROJECT"
  fi
done

# Role level project (minimal). Akses data diberikan per dataset di bigquery_setup.sql.
grant_project_role() {
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member "serviceAccount:$1@$PROJECT.iam.gserviceaccount.com" \
    --role "$2" --condition=None --quiet >/dev/null
}
log "Role project"
grant_project_role sa-ingest roles/bigquery.jobUser
grant_project_role sa-dbt    roles/bigquery.jobUser
grant_project_role sa-export roles/bigquery.jobUser
grant_project_role sa-github-ci roles/bigquery.user        # boleh membuat dataset CI per PR

# ------------------------------------------------------ Workload Identity Federation
log "Workload Identity Federation (GitHub Actions, tanpa key)"
if ! gcloud iam workload-identity-pools describe github --location=global --project "$PROJECT" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create github --location=global --project "$PROJECT" \
    --display-name "GitHub Actions"
fi
if ! gcloud iam workload-identity-pools providers describe github-oidc \
     --location=global --workload-identity-pool=github --project "$PROJECT" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc github-oidc \
    --location=global --workload-identity-pool=github --project "$PROJECT" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_id=assertion.repository_id,attribute.ref=assertion.ref" \
    --attribute-condition="assertion.repository=='${GITHUB_REPO}'"
fi

# sa-github-ci dapat diimpersonasi oleh repo ini (seluruh branch / PR)
PRINCIPAL_REPO="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/${GITHUB_REPO}"
gcloud iam service-accounts add-iam-policy-binding "sa-github-ci@$PROJECT.iam.gserviceaccount.com" \
  --role=roles/iam.workloadIdentityUser --member="$PRINCIPAL_REPO" --project "$PROJECT" --quiet >/dev/null

# SA prod (sa-ingest, sa-dbt, sa-export) hanya dapat diimpersonasi oleh branch main
PRINCIPAL_MAIN="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.ref/refs/heads/main"
for sa in sa-ingest sa-dbt sa-export; do
  gcloud iam service-accounts add-iam-policy-binding "$sa@$PROJECT.iam.gserviceaccount.com" \
    --role=roles/iam.workloadIdentityUser --member="$PRINCIPAL_MAIN" --project "$PROJECT" --quiet >/dev/null
done

WIF_PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/providers/github-oidc"

# ------------------------------------------------------------ Dataset + grant + salt
log "Dataset, grant dataset, dan salt PII (bigquery_setup.sql)"
sed "s/<PROJECT_ID>/${PROJECT}/g; s/<REGION>/${REGION}/g" "$HERE/bigquery_setup.sql" \
  | bq query --project_id="$PROJECT" --location="$REGION" --use_legacy_sql=false --quiet

log "Cabut akses bawaan projectReaders dari dataset raw ber-PII"
# Dataset baru otomatis memberi READER ke projectReaders: semua Viewer project bisa membaca PII mentah.
# raw_fnb_staging: dataset transit merge dlt, sempat berisi baris mentah yang sama.
GCP_PROJECT_ID="$PROJECT" python3 "$HERE/revoke_project_readers.py" raw_fnb raw_fnb_staging

log "Authorized dataset: view stg boleh membaca raw_fnb (CI & pembaca stg tidak butuh akses raw)"
GCP_PROJECT_ID="$PROJECT" python3 "$HERE/restrict_raw_ci_access.py"

# ------------------------------------------------------------ Budget alert (opsional)
if [[ -n "${GCP_BILLING_ACCOUNT_ID:-}" ]]; then
  BUDGET_AMOUNT="${GCP_BUDGET_AMOUNT:-1USD}"
  log "Budget alert ${BUDGET_AMOUNT} (notifikasi saja, tidak menghentikan tagihan)"
  if gcloud billing budgets list --billing-account="$GCP_BILLING_ACCOUNT_ID" \
       --format='value(displayName)' | grep -qx 'fnb-guard'; then
    echo "Budget fnb-guard sudah ada, dilewati."
  else
    gcloud billing budgets create --billing-account="$GCP_BILLING_ACCOUNT_ID" \
      --display-name="fnb-guard" --budget-amount="${BUDGET_AMOUNT}" \
      --filter-projects="projects/${PROJECT_NUMBER}" \
      --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0
  fi
else
  echo "GCP_BILLING_ACCOUNT_ID kosong: buat budget alert manual (plan §6.4)."
fi

# ------------------------------------------------------------ Ringkasan
cat <<EOF

================================================================
SELESAI. Langkah manual yang tersisa (tidak bisa lewat CLI):

  1. Custom quota (WAJIB sebelum job pertama):
     Console -> IAM & Admin -> Quotas & System Limits
     -> BigQuery API -> "Query usage per day" -> set 20 GB (20480 MiB)
     (20 GB x 31 = 620 GB < 1 TB gratis)

  2. Simpan di GitHub (Settings -> Secrets and variables -> Actions):
     Variables:
       GCP_PROJECT_ID = ${PROJECT}
       WIF_PROVIDER   = ${WIF_PROVIDER}
       SA_INGEST      = sa-ingest@${PROJECT}.iam.gserviceaccount.com
       SA_DBT         = sa-dbt@${PROJECT}.iam.gserviceaccount.com
       SA_CI          = sa-github-ci@${PROJECT}.iam.gserviceaccount.com
       SA_EXPORT      = sa-export@${PROJECT}.iam.gserviceaccount.com
     Secrets:
       SOURCE_DATABASE_URL = (connection string Neon fnb-oltp)

  3. Verifikasi: jalankan workflow "wif-smoke-test" dari tab Actions,
     lalu: bq ls --project_id=${PROJECT}
================================================================
EOF
