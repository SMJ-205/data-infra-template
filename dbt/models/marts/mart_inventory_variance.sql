{{ config(
    materialized = 'table',
    tags = ['inventory', 'mart']
) }}

with counts as (
    select outlet_id, ingredient_id, count_date, counted_qty_base
    from {{ ref('fct_stock_counts') }}
),

periods as (
    select
        outlet_id,
        ingredient_id,
        lag(count_date) over w          as period_start,
        count_date                      as period_end,
        lag(counted_qty_base) over w    as opening_qty,
        counted_qty_base                as closing_qty
    from counts
    window w as (partition by outlet_id, ingredient_id order by count_date)
),

period_movements as (
    select
        p.outlet_id,
        p.ingredient_id,
        p.period_end,
        sum(coalesce(m.purchased_qty, 0))           as purchased_qty,
        sum(coalesce(m.purchased_amount, 0))        as purchased_amount,
        sum(coalesce(m.theoretical_sales_qty, 0))   as theoretical_sales_qty,
        sum(coalesce(m.waste_qty, 0))               as recorded_waste_qty
    from periods as p
    left join {{ ref('fct_inventory_movements_daily') }} as m
        on m.outlet_id = p.outlet_id
       and m.ingredient_id = p.ingredient_id
       and m.movement_date > p.period_start
       and m.movement_date <= p.period_end
    where p.period_start is not null
    group by 1, 2, 3
),

costs as (
    select date_day, item_id as ingredient_id, std_cost_per_unit
    from {{ ref('int_item_std_cost_daily') }}
    where item_type = 'Ingredient'
),

calc as (
    select
        p.outlet_id,
        p.ingredient_id,
        p.period_start,
        p.period_end,
        p.opening_qty,
        pm.purchased_qty,
        pm.purchased_amount,
        p.closing_qty,
        p.opening_qty + pm.purchased_qty - p.closing_qty                    as actual_usage_qty,
        pm.theoretical_sales_qty,
        pm.recorded_waste_qty,
        p.opening_qty + pm.purchased_qty - p.closing_qty
            - pm.theoretical_sales_qty - pm.recorded_waste_qty              as unexplained_variance_qty,
        c.std_cost_per_unit
    from periods as p
    inner join period_movements as pm
        on pm.outlet_id = p.outlet_id
       and pm.ingredient_id = p.ingredient_id
       and pm.period_end = p.period_end
    left join costs as c
        on c.ingredient_id = p.ingredient_id
       and c.date_day = p.period_end
)

select
    {{ dbt_utils.generate_surrogate_key(['outlet_id', 'ingredient_id', 'period_end']) }} as inventory_period_key,
    *,
    unexplained_variance_qty * std_cost_per_unit                                         as unexplained_variance_value,
    theoretical_sales_qty * std_cost_per_unit                                            as theoretical_usage_value,
    {{ safe_pct('unexplained_variance_qty', 'theoretical_sales_qty') }}                  as unexplained_variance_pct
from calc
