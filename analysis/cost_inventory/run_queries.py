"""Jalankan query analisis (read-only) ke BigQuery dan simpan hasilnya sebagai CSV di output/.

Pemakaian (dari root repo):  set -a && source .env && set +a && python3 analysis/cost_inventory/run_queries.py
"""
import os
import pathlib
import sys

from google.cloud import bigquery

HERE = pathlib.Path(__file__).parent
PROJECT = os.environ.get("GCP_PROJECT_ID", "fnb-data-platform")


def main(selected=None):
    client = bigquery.Client(project=PROJECT, location="asia-southeast2")
    cfg = bigquery.QueryJobConfig(maximum_bytes_billed=2_000_000_000, labels={"app": "analysis_cost_inventory"})
    (HERE / "output").mkdir(exist_ok=True)
    total = 0
    for path in sorted((HERE / "queries").glob("0*.sql")):
        if path.stem.startswith("08") or (selected and not any(path.stem.startswith(s) for s in selected)):
            continue
        sql = path.read_text(encoding="utf-8").replace("fnb-data-platform", PROJECT)
        job = client.query(sql, job_config=cfg)
        df = job.result().to_dataframe()
        df.to_csv(HERE / "output" / f"{path.stem}.csv", index=False)
        total += job.total_bytes_billed or 0
        print(f"{path.stem}: {len(df)} baris, {(job.total_bytes_billed or 0) / 1e6:.0f} MB ditagih")
    print(f"Total ditagih: {total / 1e9:.2f} GB")


if __name__ == "__main__":
    main(sys.argv[1:] or None)
