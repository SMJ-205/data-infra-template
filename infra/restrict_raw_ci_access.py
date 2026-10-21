"""Tutup akses CI ke data mentah ber-PII tanpa mematikan slim CI.

1. Authorized dataset: view di dataset `stg` diizinkan membaca `raw_fnb` atas nama pembacanya. CI (dan pembaca
   stg lain) tetap bisa query view staging yang sudah dikurasi - PII dibuang / di-hash - tanpa akses raw.
2. Cabut READER sa-github-ci dari `raw_fnb` (grant manual yang bertentangan dengan bigquery_setup.sql).

Urutan sengaja: otorisasi dulu, baru cabut, sehingga tidak ada jeda CI tidak bisa membaca stg.
Idempoten; update memakai etag.

Konsekuensi: CI tidak bisa membangun model yang membaca raw langsung (models/staging, models/hr/restricted);
pr_ci.yml mengecualikannya dari build dan hanya meng-compile-nya.

Pemakaian:  set -a && source .env && set +a && python3 infra/restrict_raw_ci_access.py
"""
import os
import sys

from google.cloud import bigquery

RAW_DATASETS = ["raw_fnb"]
AUTHORIZED_VIEW_DATASET = "stg"
CI_SA = "sa-github-ci@{project}.iam.gserviceaccount.com"


def is_authorized(entry, project, dataset_id):
    if entry.entity_type != "dataset":
        return False
    ref = (entry.entity_id or {}).get("dataset", {})
    return ref.get("projectId") == project and ref.get("datasetId") == dataset_id


def main():
    project = os.environ.get("GCP_PROJECT_ID") or sys.exit("GCP_PROJECT_ID belum diset.")
    client = bigquery.Client(project=project)
    ci_sa = CI_SA.format(project=project)
    for raw in RAW_DATASETS:
        ds = client.get_dataset(f"{project}.{raw}")
        entries = list(ds.access_entries)
        if any(is_authorized(e, project, AUTHORIZED_VIEW_DATASET) for e in entries):
            print(f"{raw}: dataset {AUTHORIZED_VIEW_DATASET} sudah ter-otorisasi, dilewati.")
        else:
            entries.append(bigquery.AccessEntry(
                role=None, entity_type="dataset",
                entity_id={"dataset": {"projectId": project, "datasetId": AUTHORIZED_VIEW_DATASET},
                           "targetTypes": ["VIEWS"]}))
            ds.access_entries = entries
            ds = client.update_dataset(ds, ["access_entries"])
            print(f"{raw}: view di dataset {AUTHORIZED_VIEW_DATASET} di-otorisasi.")

        keep = [e for e in ds.access_entries if not (e.entity_type == "userByEmail" and e.entity_id == ci_sa)]
        if len(keep) == len(ds.access_entries):
            print(f"{raw}: {ci_sa} tidak punya akses langsung, dilewati.")
        else:
            ds.access_entries = keep
            client.update_dataset(ds, ["access_entries"])
            print(f"{raw}: akses langsung {ci_sa} dicabut.")


if __name__ == "__main__":
    main()
