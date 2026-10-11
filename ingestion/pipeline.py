"""Ingest OLTP Neon (schema fnb) -> BigQuery dataset raw_fnb via dlt.

Semua 29 tabel: incremental berdasarkan updated_at, merge by primary key (direfleksi dari Postgres).
Memakai BigQuery load jobs (gratis, bukan streaming insert).
"""
import os
import sys
import dlt
from dlt.sources.sql_database import sql_database

TABLES = [
    "outlets", "employees", "customers", "sales_channels", "channel_commission_rates", "promotions",
    "menu_categories", "menu_items", "menu_item_prices", "modifiers", "modifier_lines",
    "ingredients", "ingredient_standard_costs", "suppliers", "recipes", "recipe_lines",
    "orders", "order_items", "order_item_modifiers", "payments", "refunds",
    "goods_receipts", "goods_receipt_lines", "stock_counts", "stock_count_lines",
    "waste_reasons", "waste_logs", "expense_categories", "operating_expenses",
]


def get_db_credentials() -> str:
    url = os.environ.get("SOURCE_DATABASE_URL")
    if not url:
        sys.exit("SOURCE_DATABASE_URL belum diset.")
    if url.startswith("postgresql://"):
        return url.replace("postgresql://", "postgresql+psycopg2://", 1)
    return url


def main() -> None:
    db_uri = get_db_credentials()
    project_id = os.environ.get("GCP_PROJECT_ID", "fnb-data-platform")
    location = os.environ.get("GCP_REGION", "asia-southeast2")

    print(f"Menjalankan dlt pipeline Postgres -> BigQuery [{project_id}:{location} / raw_fnb]...")

    source = sql_database(
        credentials=db_uri,
        schema="fnb",
        table_names=TABLES,
        backend="pyarrow",
        reflection_level="full_with_precision",
    )

    for name in TABLES:
        # Incremental berdasarkan updated_at, merge by PK dari Postgres
        # lag=3600.0 (1 jam) memastikan commit lambat tetap terbaca
        source.resources[name].apply_hints(
            incremental=dlt.sources.incremental("updated_at", lag=3600.0),
            write_disposition="merge",
        )

    destination = dlt.destinations.bigquery(location=location)

    pipeline = dlt.pipeline(
        pipeline_name="fnb_pos_to_bigquery",
        destination=destination,
        dataset_name="raw_fnb",
    )

    load_info = pipeline.run(source)
    print(load_info)
    load_info.raise_on_failed_jobs()
    print("Ingestion selesai dengan sukses!")


if __name__ == "__main__":
    main()
