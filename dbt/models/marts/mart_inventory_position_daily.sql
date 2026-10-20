{{ config(
    materialized = 'table',
    tags = ['inventory', 'mart']
) }}
/*
  Grain  : balance_date x outlet_id (ringkasan fct_inventory_balance_daily untuk dashboard)
  Susut  : shrinkage_value = -Σ(count_variance_qty × std cost) pada hari opname; positif = stok hilang.
  Hari stok outlet = on_hand_value / avg_daily_usage_value_28d (dibobot nilai, bukan rata-rata per bahan).
*/
with balance as (
    select
        b.*,
        i.shelf_life_days
    from {{ ref('fct_inventory_balance_daily') }} as b
    left join {{ ref('dim_ingredient') }} as i
        on b.ingredient_id = i.ingredient_id
)

select
    balance_date,
    outlet_id,
    sum(on_hand_value)                                                          as on_hand_value,
    sum(purchased_amount)                                                       as purchased_amount,
    sum((theoretical_sales_qty + waste_qty) * std_cost_per_unit)                as usage_value,
    sum(avg_daily_usage_28d * std_cost_per_unit)                                as avg_daily_usage_value_28d,
    safe_divide(
        sum(on_hand_value),
        sum(avg_daily_usage_28d * std_cost_per_unit)
    )                                                                           as days_on_hand,
    -sum(coalesce(count_variance_qty, 0) * std_cost_per_unit)                   as shrinkage_value,
    countif(counted_qty is not null) > 0                                        as is_count_day,
    countif({{ is_stock_critical('days_on_hand', 'avg_daily_usage_28d', 'shelf_life_days') }}) as n_ingredients_critical,
    countif(is_negative_on_hand)                                                as n_ingredients_negative
from balance
group by 1, 2
