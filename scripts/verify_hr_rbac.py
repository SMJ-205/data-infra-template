"""Bukti RBAC HR: jalankan query sebagai akun demo (impersonasi) dan cocokkan dengan akses yang diharapkan.

Prasyarat: infra/setup_hr_demo.sh sudah dijalankan dan model HR sudah dibangun (enable_hr: true).
Pemakaian (dari root repo):  set -a && source .env && set +a && python3 scripts/verify_hr_rbac.py
Exit code 1 bila ada akses yang tidak sesuai harapan (bocor ATAU tertolak padahal seharusnya boleh).
"""
import os
import sys

import google.auth
from google.api_core.exceptions import Forbidden, NotFound
from google.auth import impersonated_credentials
from google.cloud import bigquery

PROJECT = os.environ.get("GCP_PROJECT_ID", "fnb-data-platform")
LOCATION = os.environ.get("GCP_REGION", "asia-southeast2")
ROLES = {
    "analyst": f"sa-hr-analyst-demo@{PROJECT}.iam.gserviceaccount.com",
    "manager": f"sa-hr-manager-demo@{PROJECT}.iam.gserviceaccount.com",
}
TABLES = {
    "hr (ter-masking)": f"`{PROJECT}.hr.dim_hr_employee`",
    "hr_restricted (PII & gaji)": f"`{PROJECT}.hr_restricted.rst_hr__employee_directory`",
    "raw_fnb (mentah)": f"`{PROJECT}.raw_fnb.employees`",
}
# (role, tabel) -> boleh membaca?
EXPECTED = {
    ("analyst", "hr (ter-masking)"): True,
    ("analyst", "hr_restricted (PII & gaji)"): False,
    ("analyst", "raw_fnb (mentah)"): False,
    ("manager", "hr (ter-masking)"): True,
    ("manager", "hr_restricted (PII & gaji)"): True,
    ("manager", "raw_fnb (mentah)"): False,
}


def client_as(sa_email):
    source, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    creds = impersonated_credentials.Credentials(
        source_credentials=source, target_principal=sa_email,
        target_scopes=["https://www.googleapis.com/auth/cloud-platform"], lifetime=600)
    return bigquery.Client(project=PROJECT, location=LOCATION, credentials=creds)


def can_read(client, table):
    try:
        job = client.query(f"select count(*) as n from {table}",
                           job_config=bigquery.QueryJobConfig(maximum_bytes_billed=100_000_000))
        return True, f"{list(job.result())[0].n} baris"
    except Forbidden:
        return False, "Access Denied"
    except NotFound as e:
        return None, f"tidak ditemukan ({e.message.split(':')[0]})"


def main():
    failures = 0
    print(f"{'Peran':8s} {'Dataset':28s} {'Harapan':9s} {'Hasil':9s} Detail")
    for role, sa in ROLES.items():
        client = client_as(sa)
        for label, table in TABLES.items():
            ok, detail = can_read(client, table)
            want = EXPECTED[(role, label)]
            status = "OK" if ok == want else "TIDAK SESUAI"
            failures += status != "OK"
            fmt = lambda v: "boleh" if v else ("ditolak" if v is False else "?")
            print(f"{role:8s} {label:28s} {fmt(want):9s} {fmt(ok):9s} {detail}  [{status}]")
    print("\nRBAC sesuai harapan." if not failures else f"\n{failures} pemeriksaan TIDAK SESUAI.")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
