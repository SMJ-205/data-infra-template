"""Export mart BigQuery -> JSON statis untuk dashboard Vercel.

Hanya membaca dataset marts dengan allowlist kolom eksplisit per file.
Gagal keras bila ada kolom berpola PII atau file melebihi batas ukuran (2.5 MB).
Memberikan peringatan dini pada 80% kapasitas dan mencatat data_through di meta.json.
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
WARN_FILE_BYTES = int(MAX_FILE_BYTES * 0.8)  # Peringatan di 80% (2 MB)
BANNED_COLUMNS = re.compile(r"phone|email|full_name|birth|_key$|^_dlt_|password|salt", re.I)

# Allowlist eksplisit per export untuk privasi dan optimasi ukuran file
EXPORTS = {
    "pnl_monthly": """
        select
            report_month,
            outlet_id,
            is_complete_month,
            is_opex_estimated,
            reported_days,
            order_count,
            round(gross_sales, 0) as gross_sales,
            round(discounts, 0) as discounts,
            round(refunds, 0) as refunds,
            round(net_sales, 0) as net_sales,
            round(cogs_standard, 0) as cogs_standard,
            round(waste_cost, 0) as waste_cost,
            round(inventory_variance_cost, 0) as inventory_variance_cost,
            round(theoretical_cost_of_sales, 0) as theoretical_cost_of_sales,
            round(actual_cost_of_sales, 0) as actual_cost_of_sales,
            round(channel_commission, 0) as channel_commission,
            round(payment_fees, 0) as payment_fees,
            round(labor_cost, 0) as labor_cost,
            round(other_opex, 0) as other_opex,
            round(gross_profit, 0) as gross_profit,
            round(outlet_ebitda, 0) as outlet_ebitda,
            round(theoretical_food_cost_pct, 2) as theoretical_food_cost_pct,
            round(food_cost_pct, 2) as food_cost_pct,
            round(waste_pct, 2) as waste_pct,
            round(inventory_variance_pct, 2) as inventory_variance_pct,
            round(prime_cost_pct, 2) as prime_cost_pct,
            round(gross_margin_pct, 2) as gross_margin_pct,
            round(channel_cost_pct, 2) as channel_cost_pct,
            round(ebitda_margin_pct, 2) as ebitda_margin_pct
        from `{p}.marts.mart_pnl_monthly`
        order by report_month, outlet_id
    """,
    "pnl_daily": """
        select
            report_date,
            report_month,
            outlet_id,
            order_count,
            units_sold,
            round(gross_sales, 0) as gross_sales,
            round(discounts, 0) as discounts,
            round(refunds, 0) as refunds,
            round(net_sales, 0) as net_sales,
            round(cogs_standard, 0) as cogs_standard,
            round(waste_cost, 0) as waste_cost,
            round(channel_commission, 0) as channel_commission,
            round(payment_fees, 0) as payment_fees,
            round(labor_cost, 0) as labor_cost,
            round(other_opex, 0) as other_opex,
            round(cost_of_sales, 0) as cost_of_sales,
            round(gross_profit, 0) as gross_profit,
            round(contribution_after_channel, 0) as contribution_after_channel,
            round(outlet_ebitda, 0) as outlet_ebitda,
            round(food_cost_pct, 2) as food_cost_pct,
            round(waste_pct, 2) as waste_pct,
            round(prime_cost_pct, 2) as prime_cost_pct,
            round(gross_margin_pct, 2) as gross_margin_pct,
            round(ebitda_margin_pct, 2) as ebitda_margin_pct,
            round(avg_order_value, 0) as avg_order_value,
            is_opex_estimated
        from `{p}.marts.mart_pnl_daily`
        where report_date >= date_sub(current_date('Asia/Jakarta'), interval 450 day)
        order by report_date, outlet_id
    """,
    "kpi_status": """
        select
            report_month,
            outlet_id,
            is_complete_month,
            metric_code,
            metric_name,
            direction,
            round(metric_value, 2) as metric_value,
            round(warn_threshold, 2) as warn_threshold,
            round(critical_threshold, 2) as critical_threshold,
            status
        from `{p}.marts.mart_kpi_monthly_status`
        order by report_month, outlet_id, metric_code
    """,
    "menu_engineering": """
        select
            outlet_id,
            report_month,
            menu_item_id,
            menu_name,
            category_name,
            qty_sold,
            round(net_sales, 0) as net_sales,
            round(cogs_standard, 0) as cogs_standard,
            round(avg_contribution_margin, 0) as avg_contribution_margin,
            round(menu_mix_pct, 4) as menu_mix_pct,
            menu_class
        from `{p}.marts.mart_menu_engineering`
        order by outlet_id, report_month, menu_name
    """,
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
        where period_end >= date_sub(current_date('Asia/Jakarta'), interval 450 day)
        order by outlet_id, period_end
    """,
    "waste": """
        select
            outlet_id,
            waste_date,
            reason_code,
            reason_name,
            controllability,
            item_category,
            round(waste_qty, 2) as waste_qty,
            round(waste_cost, 0) as waste_cost,
            round(outlet_daily_net_sales, 0) as outlet_daily_net_sales,
            round(waste_pct_of_sales, 2) as waste_pct_of_sales
        from `{p}.marts.mart_waste_analysis`
        where waste_date >= date_sub(current_date('Asia/Jakarta'), interval 450 day)
        order by outlet_id, waste_date
    """,
    "channel_daily": """
        select
            order_date,
            outlet_id,
            channel_code,
            channel_name,
            channel_group,
            order_count,
            round(gross_sales, 0) as gross_sales,
            round(merchant_discounts, 0) as merchant_discounts,
            round(refunds, 0) as refunds,
            round(net_sales, 0) as net_sales,
            round(channel_commission, 0) as channel_commission,
            round(contribution_after_channel, 0) as contribution_after_channel,
            round(avg_order_value, 0) as avg_order_value,
            round(channel_commission_pct, 2) as channel_commission_pct
        from `{p}.marts.mart_channel_performance_daily`
        where order_date >= date_sub(current_date('Asia/Jakarta'), interval 450 day)
        order by order_date, outlet_id, channel_code
    """,
    "orders_hourly": """
        select
            outlet_id,
            channel_code,
            day_of_week_num,
            day_of_week_name,
            order_hour_local,
            order_count,
            round(total_net_sales, 0) as total_net_sales,
            round(avg_order_value, 0) as avg_order_value
        from `{p}.marts.mart_orders_hourly`
        order by outlet_id, channel_code, day_of_week_num, order_hour_local
    """,
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
            round(food_cost_pct, 2) as food_cost_pct,
            round(gross_margin_pct, 2) as gross_margin_pct
        from `{p}.marts.mart_category_performance_daily`
        where report_date >= date_sub(current_date('Asia/Jakarta'), interval 450 day)
        order by report_date, outlet_id, category_name
    """,
}


def _json_default(value):
    if isinstance(value, Decimal):
        return int(value) if value % 1 == 0 else float(value)
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
    data_through = None

    for name, sql in EXPORTS.items():
        result = client.query(sql.format(p=PROJECT), job_config=config).result()
        banned = [f.name for f in result.schema if BANNED_COLUMNS.search(f.name)]
        if banned:
            raise SystemExit(f"{name}: kolom terlarang untuk dipublikasikan: {banned}")
        raw_rows = [dict(r.items()) for r in result]
        rows = []
        for r in raw_rows:
            clean_row = {}
            for k, v in r.items():
                if isinstance(v, Decimal):
                    clean_row[k] = int(v) if v % 1 == 0 else float(v)
                elif isinstance(v, float) and v.is_integer():
                    clean_row[k] = int(v)
                else:
                    clean_row[k] = v
            rows.append(clean_row)

        if name == "pnl_daily" and rows:
            dates = [r["report_date"] for r in rows if r.get("report_date")]
            if dates:
                data_through = max(dates)
                if isinstance(data_through, (dt.date, dt.datetime)):
                    data_through = data_through.isoformat()

        payload = json.dumps(rows, default=_json_default, sort_keys=True, separators=(",", ":"))
        file_bytes = len(payload.encode("utf-8"))
        if file_bytes > MAX_FILE_BYTES:
            raise SystemExit(f"{name}: melebihi batas {MAX_FILE_BYTES} byte ({file_bytes} byte); agregasi atau perkecil jendela tanggal")
        if file_bytes >= WARN_FILE_BYTES:
            print(f"::warning::{name} mencapai {file_bytes / 1024:.1f} KB (>= 80% dari batas 2.5 MB)!")

        (OUT / f"{name}.json").write_text(payload, encoding="utf-8")
        counts[name] = len(rows)
        total_bytes += file_bytes
        print(f"Exported {name}: {len(rows)} rows ({file_bytes / 1024:.1f} KB)")

    meta = {
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "data_through": data_through,
        "rows": counts,
        "total_size_kb": round(total_bytes / 1024, 1),
    }
    (OUT / "meta.json").write_text(json.dumps(meta, sort_keys=True, indent=2), encoding="utf-8")
    print(f"Export marts to JSON selesai dengan sukses! Total data: {total_bytes / 1024 / 1024:.2f} MB (data through {data_through})")


if __name__ == "__main__":
    main()
