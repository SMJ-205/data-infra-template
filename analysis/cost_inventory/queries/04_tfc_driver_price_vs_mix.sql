-- 04. Mengapa TFC naik: efek harga bahan (standard cost berubah) vs komposisi menu & resep.
-- recipe_cost_base = kuantitas resep aktual x standard cost Agustus 2025 (harga dibekukan).
with b as (
    select date_trunc(balance_date, month) as month, *
    from `fnb-data-platform.core.fct_inventory_balance_daily`
    where balance_date between date '2025-08-01' and date '2026-09-30'
),
base_cost as (
    select outlet_id, ingredient_id, any_value(std_cost_per_unit) as base_cost
    from `fnb-data-platform.core.fct_inventory_balance_daily`
    where balance_date = date '2025-08-01'
    group by 1, 2
),
sales as (
    select report_month as month, sum(net_sales) as net_sales
    from `fnb-data-platform.marts.mart_pnl_monthly`
    group by 1
)
select
    b.month,
    round(sum(b.theoretical_sales_qty * b.std_cost_per_unit) / any_value(s.net_sales) * 100, 2)       as tfc_pct,
    round(sum(b.theoretical_sales_qty * c.base_cost) / any_value(s.net_sales) * 100, 2)               as tfc_at_base_cost_pct,
    round(sum(b.theoretical_sales_qty * (b.std_cost_per_unit - c.base_cost)) / any_value(s.net_sales) * 100, 2)
                                                                                                        as price_effect_pp,
    round(sum(if(b.ingredient_id = 'ING_MILK', b.theoretical_sales_qty * (b.std_cost_per_unit - c.base_cost), 0)))
                                                                                                        as milk_price_effect_idr
from b
inner join base_cost as c using (outlet_id, ingredient_id)
inner join sales as s using (month)
group by 1
order by 1
