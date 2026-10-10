"""Reconcile row counts between Neon Postgres (schema fnb) and BigQuery dataset raw_fnb."""
import os
import sys
import psycopg2
from google.cloud import bigquery

TABLES = [
    "outlets", "employees", "customers", "sales_channels", "channel_commission_rates", "promotions",
    "menu_categories", "menu_items", "menu_item_prices", "modifiers", "modifier_lines",
    "ingredients", "ingredient_standard_costs", "suppliers", "recipes", "recipe_lines",
    "orders", "order_items", "order_item_modifiers", "payments", "refunds",
    "goods_receipts", "goods_receipt_lines", "stock_counts", "stock_count_lines",
    "waste_reasons", "waste_logs", "expense_categories", "operating_expenses",
]

def main():
    pg_url = os.environ.get("SOURCE_DATABASE_URL")
    project_id = os.environ.get("GCP_PROJECT_ID", "fnb-data-platform")
    if not pg_url:
        sys.exit("SOURCE_DATABASE_URL is required.")

    pg_conn = psycopg2.connect(pg_url)
    pg_cur = pg_conn.cursor()

    bq_client = bigquery.Client(project=project_id)

    print(f"{'Table':<26} | {'Neon Count':<12} | {'BQ raw_fnb':<12} | {'Match':<6}")
    print("-" * 64)

    all_matched = True
    total_pg = 0
    total_bq = 0

    for table in TABLES:
        # Neon count
        pg_cur.execute(f"SELECT COUNT(*) FROM fnb.{table};")
        pg_cnt = pg_cur.fetchone()[0]

        # BigQuery count
        try:
            query = f"SELECT count(*) as cnt FROM `{project_id}.raw_fnb.{table}`"
            job = bq_client.query(query, location="asia-southeast2")
            bq_cnt = list(job.result())[0].cnt
        except Exception as e:
            bq_cnt = f"ERR: {e}"

        match = (pg_cnt == bq_cnt)
        if not match:
            all_matched = False

        total_pg += pg_cnt
        if isinstance(bq_cnt, int):
            total_bq += bq_cnt

        print(f"{table:<26} | {pg_cnt:<12} | {str(bq_cnt):<12} | {'OK' if match else 'FAIL'}")

    print("-" * 64)
    print(f"{'TOTAL':<26} | {total_pg:<12} | {total_bq:<12} | {'ALL OK' if all_matched else 'MISMATCH'}")

    pg_cur.close()
    pg_conn.close()

    if not all_matched:
        sys.exit(1)

if __name__ == "__main__":
    main()
