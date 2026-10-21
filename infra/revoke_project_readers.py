"""Cabut akses bawaan `projectReaders` dari dataset BigQuery yang berisi PII.

Dataset baru otomatis memberi READER ke projectReaders, sehingga siapa pun dengan role Viewer di level project
bisa membaca isinya. Dataset ber-PII hanya boleh dibaca principal yang di-grant eksplisit.
projectWriters/projectOwners (Editor/Owner project) sengaja dipertahankan sebagai akses administratif.
Idempoten; update memakai etag sehingga gagal bila ACL diubah bersamaan.

Pemakaian:  set -a && source .env && set +a && python3 infra/revoke_project_readers.py raw_fnb hr_restricted
"""
import os
import sys

from google.cloud import bigquery


def revoke(client, project, dataset_id):
    ds = client.get_dataset(f"{project}.{dataset_id}")
    keep = [e for e in ds.access_entries
            if not (e.entity_type == "specialGroup" and e.entity_id == "projectReaders")]
    if len(keep) == len(ds.access_entries):
        print(f"{dataset_id}: projectReaders sudah tidak ada, dilewati.")
        return
    ds.access_entries = keep
    client.update_dataset(ds, ["access_entries"])
    print(f"{dataset_id}: projectReaders dicabut.")


def main():
    datasets = sys.argv[1:]
    if not datasets:
        sys.exit(__doc__)
    project = os.environ.get("GCP_PROJECT_ID") or os.environ.get("PROJECT")
    if not project:
        sys.exit("GCP_PROJECT_ID belum diset.")
    client = bigquery.Client(project=project)
    for dataset_id in datasets:
        revoke(client, project, dataset_id)


if __name__ == "__main__":
    main()
