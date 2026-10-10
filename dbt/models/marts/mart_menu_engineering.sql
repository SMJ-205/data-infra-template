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
        sum(net_sales_amount)           as net_sales,
        sum(cogs_std_amount)            as cogs_standard
    from {{ ref('fct_order_lines') }}
    where is_revenue_line
    group by 1, 2, 3
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
    from lines
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
