{{ config(
    materialized = 'table',
    partition_by = {'field': 'report_date', 'data_type': 'date', 'granularity': 'month'},
    cluster_by = ['outlet_id', 'category_name'],
    tags = ['sales', 'finance', 'daily', 'mart']
) }}

with lines as (
    select
        f.order_date                                as report_date,
        f.outlet_id,
        coalesce(m.category_name, 'Uncategorized')  as category_name,
        count(*)                                    as line_count,
        sum(f.qty)                                  as units_sold,
        sum(f.gross_sales_amount)                   as gross_sales,
        sum(f.merchant_discount_amount)            as discounts,
        sum(f.gross_sales_amount - f.merchant_discount_amount) as net_sales,
        sum(f.cogs_std_amount)                     as cogs_standard
    from {{ ref('fct_order_lines') }} as f
    left join {{ ref('dim_menu_item') }} as m
        on f.menu_item_id = m.menu_item_id
    where f.is_revenue_line
    group by 1, 2, 3
)

select
    report_date,
    outlet_id,
    category_name,
    line_count,
    units_sold,
    round(gross_sales, 0)                                       as gross_sales,
    round(discounts, 0)                                         as discounts,
    round(net_sales, 0)                                         as net_sales,
    round(cogs_standard, 0)                                     as cogs_standard,
    round(net_sales - cogs_standard, 0)                         as gross_profit,
    {{ safe_pct('cogs_standard', 'net_sales') }}                as food_cost_pct,
    {{ safe_pct('net_sales - cogs_standard', 'net_sales') }}    as gross_margin_pct
from lines
