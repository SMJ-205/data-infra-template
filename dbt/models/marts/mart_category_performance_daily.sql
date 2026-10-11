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
        sum(f.cogs_std_amount)                     as cogs_standard
    from {{ ref('fct_order_lines') }} as f
    left join {{ ref('dim_menu_item') }} as m
        on f.menu_item_id = m.menu_item_id
    where f.is_revenue_line
    group by 1, 2, 3
),

refund_lines as (
    -- Item-level refund
    select
        r.refund_date as report_date,
        r.outlet_id,
        coalesce(m.category_name, 'Uncategorized') as category_name,
        r.refund_net_amount as refund_amount
    from {{ ref('fct_refunds') }} as r
    inner join {{ ref('fct_order_lines') }} as l
        on l.order_item_id = r.order_item_id
    left join {{ ref('dim_menu_item') }} as m
        on l.menu_item_id = m.menu_item_id
    where r.order_item_id is not null

    union all

    -- Order-level refund dialokasikan ke masing-masing item sesuai proporsi net_sales
    select
        r.refund_date as report_date,
        r.outlet_id,
        coalesce(m.category_name, 'Uncategorized') as category_name,
        r.refund_net_amount * coalesce(safe_divide(l.net_sales_amount, o.net_sales_amount), 0) as refund_amount
    from {{ ref('fct_refunds') }} as r
    inner join {{ ref('fct_orders') }} as o
        on o.order_id = r.order_id
    inner join {{ ref('fct_order_lines') }} as l
        on l.order_id = r.order_id and l.is_revenue_line
    left join {{ ref('dim_menu_item') }} as m
        on l.menu_item_id = m.menu_item_id
    where r.order_item_id is null
),

category_refunds as (
    select
        report_date,
        outlet_id,
        category_name,
        sum(refund_amount) as refunds
    from refund_lines
    group by 1, 2, 3
),

keys as (
    select report_date, outlet_id, category_name from lines
    union distinct
    select report_date, outlet_id, category_name from category_refunds
)

select
    k.report_date,
    k.outlet_id,
    k.category_name,
    coalesce(l.line_count, 0)                                   as line_count,
    coalesce(l.units_sold, 0)                                   as units_sold,
    round(coalesce(l.gross_sales, 0), 0)                        as gross_sales,
    round(coalesce(l.discounts, 0), 0)                          as discounts,
    round(coalesce(r.refunds, 0), 0)                            as refunds,
    round(coalesce(l.gross_sales, 0) - coalesce(l.discounts, 0) - coalesce(r.refunds, 0), 0) as net_sales,
    round(coalesce(l.cogs_standard, 0), 0)                      as cogs_standard,
    round((coalesce(l.gross_sales, 0) - coalesce(l.discounts, 0) - coalesce(r.refunds, 0)) - coalesce(l.cogs_standard, 0), 0) as gross_profit,
    {{ safe_pct('coalesce(l.cogs_standard, 0)', 'coalesce(l.gross_sales, 0) - coalesce(l.discounts, 0) - coalesce(r.refunds, 0)') }} as food_cost_pct,
    {{ safe_pct('(coalesce(l.gross_sales, 0) - coalesce(l.discounts, 0) - coalesce(r.refunds, 0)) - coalesce(l.cogs_standard, 0)', 'coalesce(l.gross_sales, 0) - coalesce(l.discounts, 0) - coalesce(r.refunds, 0)') }} as gross_margin_pct
from keys as k
left join lines as l
    on l.report_date = k.report_date
   and l.outlet_id = k.outlet_id
   and l.category_name = k.category_name
left join category_refunds as r
    on r.report_date = k.report_date
   and r.outlet_id = k.outlet_id
   and r.category_name = k.category_name
