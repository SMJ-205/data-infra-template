#!/usr/bin/env bash
# Setup akses HR (opsi B): dua service account demo sebagai pengganti grup HR Manager & HR Analyst,
# lalu menjalankan infra/hr_access.sql dengan placeholder terisi. Idempoten: aman dijalankan ulang.
#
#   sa-hr-manager-demo  -> baca hr_restricted (PII & gaji individual) + hr
#   sa-hr-analyst-demo  -> baca hr saja (ter-masking)
#
# Akun gcloud yang menjalankan script ini (owner project) diberi roles/iam.serviceAccountTokenCreator pada
# kedua SA agar bisa mengimpersonasi mereka di scripts/verify_hr_rbac.py.
#
# Pemakaian (dari root repo):  set -a && source .env && set +a && bash infra/setup_hr_demo.sh
set -euo pipefail

PROJECT="${GCP_PROJECT_ID:?GCP_PROJECT_ID belum diset (source .env)}"
REGION="${GCP_REGION:-asia-southeast2}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ME="$(gcloud config get-value account 2>/dev/null)"
[[ -n "$ME" ]] || { echo "gcloud belum login (gcloud auth login)"; exit 1; }
if [[ "$ME" == *.gserviceaccount.com ]]; then ME_MEMBER="serviceAccount:$ME"; else ME_MEMBER="user:$ME"; fi

MANAGER_SA="sa-hr-manager-demo@${PROJECT}.iam.gserviceaccount.com"
ANALYST_SA="sa-hr-analyst-demo@${PROJECT}.iam.gserviceaccount.com"

log() { printf '\n==> %s\n' "$*"; }

# IAM eventually consistent: SA yang baru dibuat bisa belum dikenali policy binding selama beberapa detik.
retry() {
  local n
  for n in 1 2 3 4 5 6 7 8; do
    if "$@"; then return 0; fi
    echo "   belum berhasil (percobaan $n/8), tunggu 10 detik..." >&2
    sleep 10
  done
  echo "Gagal setelah 8 percobaan: $*" >&2
  return 1
}

log "Service account demo"
for name in sa-hr-manager-demo sa-hr-analyst-demo; do
  email="${name}@${PROJECT}.iam.gserviceaccount.com"
  if gcloud iam service-accounts describe "$email" --project "$PROJECT" >/dev/null 2>&1; then
    echo "$name sudah ada, dilewati."
  else
    gcloud iam service-accounts create "$name" --project "$PROJECT" \
      --display-name "Demo RBAC HR (${name#sa-hr-})" --quiet
  fi
done

log "Izin menjalankan query (roles/bigquery.jobUser, level project)"
for email in "$MANAGER_SA" "$ANALYST_SA"; do
  retry gcloud projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:${email}" \
    --role roles/bigquery.jobUser --condition None --quiet >/dev/null
  echo "jobUser -> $email"
done

log "Impersonasi untuk verifikasi: $ME_MEMBER -> tokenCreator pada kedua SA"
for email in "$MANAGER_SA" "$ANALYST_SA"; do
  retry gcloud iam service-accounts add-iam-policy-binding "$email" --project "$PROJECT" \
    --member "$ME_MEMBER" --role roles/iam.serviceAccountTokenCreator --quiet >/dev/null
  echo "tokenCreator pada $email"
done

log "Dataset hr & hr_restricted + grant (infra/hr_access.sql)"
render_sql() {
sed -e "s/<PROJECT_ID>/${PROJECT}/g" \
    -e "s/<REGION>/${REGION}/g" \
    -e "s/group:<HR_MANAGER_GROUP>/serviceAccount:${MANAGER_SA}/g" \
    -e "s/group:<HR_ANALYST_GROUP>/serviceAccount:${ANALYST_SA}/g" \
    "$HERE/hr_access.sql"
}
run_sql() { render_sql | bq query --project_id="$PROJECT" --location="$REGION" --use_legacy_sql=false --quiet; }
retry run_sql

log "Cabut akses bawaan projectReaders dari hr_restricted"
# Dataset baru otomatis memberi READER ke projectReaders: siapa pun dengan role Viewer di level project bisa
# membaca PII. hr_restricted hanya boleh dibaca principal yang di-grant eksplisit (HR Manager, sa-dbt).
# projectWriters/projectOwners (Editor/Owner project) sengaja dipertahankan sebagai akses administratif.
PROJECT="$PROJECT" python3 - <<'PY'
import os
from google.cloud import bigquery

client = bigquery.Client(project=os.environ["PROJECT"])
ds = client.get_dataset(f"{os.environ['PROJECT']}.hr_restricted")
keep = [e for e in ds.access_entries
        if not (e.entity_type == "specialGroup" and e.entity_id == "projectReaders")]
if len(keep) == len(ds.access_entries):
    print("projectReaders sudah tidak ada, dilewati.")
else:
    ds.access_entries = keep
    client.update_dataset(ds, ["access_entries"])          # memakai etag: gagal bila ACL diubah bersamaan
    print("projectReaders dicabut dari hr_restricted.")
PY

log "Ringkasan akses dataset"
for ds in hr hr_restricted; do
  echo "[$ds]"
  bq show --format=json "${PROJECT}:${ds}" \
    | python3 -c "import json,sys; [print('  ', a.get('role'), a.get('userByEmail') or a.get('groupByEmail') or a.get('iamMember') or a.get('specialGroup')) for a in json.load(sys.stdin)['access']]"
done

cat <<EOF

Selesai. Langkah berikutnya:
  1. Set enable_hr: true di dbt/dbt_project.yml, commit & push ke main.
  2. Jalankan pipeline (atau tunggu jadwal 00:30 WIB).
  3. Verifikasi RBAC:  python3 scripts/verify_hr_rbac.py
Catatan: perubahan IAM bisa butuh 1-2 menit untuk berlaku.
EOF
