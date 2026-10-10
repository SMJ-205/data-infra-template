{{ config(
    materialized = 'table',
    partition_by = {'field': 'waste_date', 'data_type': 'date', 'granularity': 'month'},
    cluster_by = ['outlet_id', 'reason_code'],
    tags = ['inventory', 'mart']
) }}

with waste as (
    select
        w.outlet_id,
        w.waste_date,
        w.reason_code,
        w.reason_name,
        w.controllability,
        case
            when w.item_type = 'Menu Item' then coalesce(m.category_name, 'Finished Menu')
            when w.item_type = 'Prep Item' then 'Prep Batch'
            else coalesce(i.ingredient_category, 'Raw Ingredient')
        end as item_category,
        sum(w.qty)                  as waste_qty,
        sum(w.waste_cost_amount)    as waste_cost
    from {{ ref('fct_waste') }} as w
    left join {{ ref('dim_menu_item') }} as m on m.menu_item_id = w.item_id and w.item_type = 'Menu Item'
    left join {{ ref('dim_ingredient') }} as i on i.ingredient_id = w.item_id and w.item_type in ('Ingredient', 'Prep Item')
    group by 1, 2, 3, 4, 5, 6
),

pnl as (
    select
        report_date,
        outlet_id,
        net_sales
    from {{ ref('mart_pnl_daily') }}
)

select
    w.outlet_id,
    w.waste_date,
    w.reason_code,
    w.reason_name,
    w.controllability,
    w.item_category,
    w.waste_qty,
    w.waste_cost,
    p.net_sales as outlet_daily_net_sales,
    {{ safe_pct('w.waste_cost', 'p.net_sales') }} as waste_pct_of_sales
from waste as w
left join pnl as p on p.report_date = w.waste_date and p.outlet_id = w.outlet_id
