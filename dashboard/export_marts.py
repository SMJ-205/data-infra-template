"""Export mart BigQuery -> JSON statis untuk dashboard Vercel.

Hanya membaca dataset marts. Gagal keras bila ada kolom berpola PII atau file terlalu besar,
karena hasil export dipublikasikan ke repo publik.
"""
import datetime as dt
import json
import os
import re
from decimal import Decimal
from pathlib import Path

from google.cloud import bigquery

PROJECT = os.environ.get("GCP_PROJECT_ID", "fnb-data-platform")
LOCATION = "asia-southeast2"
OUT = Path(__file__).parent / "public" / "data"
MAX_FILE_BYTES = 2_500_000
BANNED_COLUMNS = re.compile(r"phone|email|full_name|birth|_key$|^_dlt_|password|salt", re.I)

EXPORTS = {
    "pnl_monthly": "select * from `{p}.marts.mart_pnl_monthly` order by report_month, outlet_id",
    "pnl_daily": "select * from `{p}.marts.mart_pnl_daily` order by report_date, outlet_id",
    "kpi_status": "select * from `{p}.marts.mart_kpi_monthly_status` order by report_month, outlet_id",
    "menu_engineering": "select * from `{p}.marts.mart_menu_engineering` order by outlet_id, menu_name",
    "inventory_variance": """
        select
            outlet_id,
            ingredient_id,
            period_start,
            period_end,
            round(unexplained_variance_qty, 2) as unexplained_variance_qty,
            round(unexplained_variance_value, 0) as unexplained_variance_value,
            round(theoretical_sales_qty, 2) as theoretical_sales_qty,
            round(unexplained_variance_pct, 2) as unexplained_variance_pct
        from `{p}.marts.mart_inventory_variance`
        order by outlet_id, period_end
    """,
    "waste": "select * from `{p}.marts.mart_waste_analysis` order by outlet_id, waste_date",
    "channel_daily": """
        select
            order_date,
            outlet_id,
            channel_code,
            channel_name,
            channel_group,
            order_count,
            round(gross_sales, 0) as gross_sales,
            round(net_sales, 0) as net_sales,
            round(channel_commission, 0) as channel_commission,
            round(contribution_after_channel, 0) as contribution_after_channel,
            round(avg_order_value, 0) as avg_order_value,
            channel_commission_pct
        from `{p}.marts.mart_channel_performance_daily`
        order by order_date, outlet_id, channel_code
    """,
    "orders_hourly": "select * from `{p}.marts.mart_orders_hourly` order by outlet_id, channel_code, day_of_week_num, order_hour_local",
    "category_daily": """
        select
            report_date,
            outlet_id,
            category_name,
            line_count,
            units_sold,
            round(gross_sales, 0) as gross_sales,
            round(discounts, 0) as discounts,
            round(net_sales, 0) as net_sales,
            round(cogs_standard, 0) as cogs_standard,
            round(gross_profit, 0) as gross_profit,
            food_cost_pct,
            gross_margin_pct
        from `{p}.marts.mart_category_performance_daily`
        order by report_date, outlet_id, category_name
    """,
}


def _json_default(value):
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (dt.date, dt.datetime)):
        return value.isoformat()
    raise TypeError(f"tipe tidak didukung: {type(value)}")


def main() -> None:
    client = bigquery.Client(project=PROJECT, location=LOCATION)
    config = bigquery.QueryJobConfig(
        maximum_bytes_billed=2_000_000_000,
        labels={"app": "dashboard_export"},
    )
    OUT.mkdir(parents=True, exist_ok=True)
    counts = {}
    total_bytes = 0
    for name, sql in EXPORTS.items():
        result = client.query(sql.format(p=PROJECT), job_config=config).result()
        banned = [f.name for f in result.schema if BANNED_COLUMNS.search(f.name)]
        if banned:
            raise SystemExit(f"{name}: kolom terlarang untuk dipublikasikan: {banned}")
        rows = [dict(r.items()) for r in result]
        payload = json.dumps(rows, default=_json_default, sort_keys=True, separators=(",", ":"))
        file_bytes = len(payload.encode("utf-8"))
        if file_bytes > MAX_FILE_BYTES:
            raise SystemExit(f"{name}: melebihi {MAX_FILE_BYTES} byte ({file_bytes} byte); agregasi lebih tinggi")
        (OUT / f"{name}.json").write_text(payload, encoding="utf-8")
        counts[name] = len(rows)
        total_bytes += file_bytes
        print(f"Exported {name}: {len(rows)} rows ({file_bytes / 1024:.1f} KB)")

    meta = {
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "rows": counts,
        "total_size_kb": round(total_bytes / 1024, 1),
    }
    (OUT / "meta.json").write_text(json.dumps(meta, sort_keys=True, indent=2), encoding="utf-8")
    print(f"Export marts to JSON selesai dengan sukses! Total data: {total_bytes / 1024 / 1024:.2f} MB")


if __name__ == "__main__":
    main()
