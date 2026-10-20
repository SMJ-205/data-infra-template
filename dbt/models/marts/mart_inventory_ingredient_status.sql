{{ config(
    materialized = 'table',
    tags = ['inventory', 'mart']
) }}
/*
  Grain  : outlet_id x ingredient_id, posisi pada tanggal saldo terakhir + kinerja susut 90 hari
  Status : Habis (saldo <= 0) > Kritis (macro is_stock_critical) > Risiko Kedaluwarsa (hari stok > shelf life)
           > Tidak Bergerak (tanpa pemakaian 28 hari) > Normal
*/
with balance as (
    select * from {{ ref('fct_inventory_balance_daily') }}
),

as_of as (
    select max(balance_date) as as_of_date from balance
),

window_90d as (
    select
        b.outlet_id,
        b.ingredient_id,
        sum(b.theoretical_sales_qty + b.waste_qty)                  as usage_qty_90d,
        -sum(coalesce(b.count_variance_qty, 0))                     as shrinkage_qty_90d,
        -sum(coalesce(b.count_variance_qty, 0) * b.std_cost_per_unit) as shrinkage_value_90d
    from balance as b
    cross join as_of as a
    where b.balance_date > date_sub(a.as_of_date, interval 90 day)
    group by 1, 2
),

latest as (
    select b.*
    from balance as b
    inner join as_of as a on b.balance_date = a.as_of_date
),

ingredients as (
    select * from {{ ref('dim_ingredient') }}
)

select
    l.balance_date                                                  as as_of_date,
    l.outlet_id,
    l.ingredient_id,
    i.ingredient_name,
    i.ingredient_category,
    i.base_uom,
    i.is_perishable,
    i.shelf_life_days,
    l.on_hand_qty,
    l.avg_daily_usage_28d,
    l.days_on_hand,
    l.on_hand_value,
    l.last_count_date,
    l.days_since_last_count,
    w.usage_qty_90d,
    w.shrinkage_qty_90d,
    w.shrinkage_value_90d,
    {{ safe_pct('w.shrinkage_qty_90d', 'w.usage_qty_90d') }}        as shrinkage_pct_90d,
    case
        when l.on_hand_qty <= 0 then 'Habis'
        when {{ is_stock_critical('l.days_on_hand', 'l.avg_daily_usage_28d', 'i.shelf_life_days') }} then 'Kritis'
        when i.shelf_life_days is not null and l.days_on_hand > i.shelf_life_days then 'Risiko Kedaluwarsa'
        when coalesce(l.avg_daily_usage_28d, 0) = 0 then 'Tidak Bergerak'
        else 'Normal'
    end                                                             as stock_status
from latest as l
inner join window_90d as w
    on
        l.outlet_id = w.outlet_id
        and l.ingredient_id = w.ingredient_id
left join ingredients as i
    on l.ingredient_id = i.ingredient_id
