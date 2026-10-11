{{ config(
    materialized = 'table',
    tags = ['menu', 'mart']
) }}

with lines as (
    select
        outlet_id,
        date_trunc(order_date, month)   as report_month,
        menu_item_id,
        sum(qty)                        as qty_sold,
        sum(net_sales_amount)           as gross_net_sales,
        sum(cogs_std_amount)            as cogs_standard
    from {{ ref('fct_order_lines') }}
    where is_revenue_line
    group by 1, 2, 3
),

refund_lines as (
    -- Item-level refund
    select
        date_trunc(r.refund_date, month) as report_month,
        r.outlet_id,
        l.menu_item_id,
        r.refund_net_amount as refund_amount
    from {{ ref('fct_refunds') }} as r
    inner join {{ ref('fct_order_lines') }} as l
        on l.order_item_id = r.order_item_id
    where r.order_item_id is not null

    union all

    -- Order-level refund dialokasikan ke masing-masing item sesuai proporsi net_sales
    select
        date_trunc(r.refund_date, month) as report_month,
        r.outlet_id,
        l.menu_item_id,
        r.refund_net_amount * coalesce(safe_divide(l.net_sales_amount, o.net_sales_amount), 0) as refund_amount
    from {{ ref('fct_refunds') }} as r
    inner join {{ ref('fct_orders') }} as o
        on o.order_id = r.order_id
    inner join {{ ref('fct_order_lines') }} as l
        on l.order_id = r.order_id and l.is_revenue_line
    where r.order_item_id is null
),

item_refunds as (
    select
        report_month,
        outlet_id,
        menu_item_id,
        sum(refund_amount) as refunds
    from refund_lines
    group by 1, 2, 3
),

items as (
    select
        l.outlet_id,
        l.report_month,
        l.menu_item_id,
        l.qty_sold,
        l.gross_net_sales - coalesce(r.refunds, 0) as net_sales,
        l.cogs_standard
    from lines as l
    left join item_refunds as r
        on r.report_month = l.report_month
       and r.outlet_id = l.outlet_id
       and r.menu_item_id = l.menu_item_id
),

calc as (
    select
        *,
        safe_divide(net_sales - cogs_standard, qty_sold)                                    as avg_contribution_margin,
        safe_divide(qty_sold, sum(qty_sold) over (partition by outlet_id, report_month))    as menu_mix_pct,
        count(*) over (partition by outlet_id, report_month)                                as n_items_sold,
        safe_divide(
            sum(net_sales - cogs_standard) over (partition by outlet_id, report_month),
            sum(qty_sold) over (partition by outlet_id, report_month)
        )                                                                                   as weighted_avg_cm
    from items
),

flags as (
    select
        *,
        menu_mix_pct >= 0.7 / n_items_sold          as is_high_popularity,
        avg_contribution_margin >= weighted_avg_cm  as is_high_profitability
    from calc
)

select
    f.*,
    case
        when is_high_popularity and is_high_profitability then 'Star'
        when is_high_popularity then 'Plowhorse'
        when is_high_profitability then 'Puzzle'
        else 'Dog'
    end                                                         as menu_class,
    d.menu_name,
    d.category_name
from flags as f
left join {{ ref('dim_menu_item') }} as d on d.menu_item_id = f.menu_item_id
