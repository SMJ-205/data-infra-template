-- 01. Jembatan food cost bulanan per outlet: TFC (resep) -> AFC (aktual).
-- AFC (guideline) = (stok awal + pembelian - stok akhir) / penjualan, stok awal/akhir = opname akhir bulan,
-- pembelian = nilai invoice aktual. Selisih AFC - TFC terurai habis menjadi:
--   waste tercatat + susut tak tercatat (selisih opname) + efek harga beli (invoice vs standard cost).
with b as (
    select date_trunc(balance_date, month) as month, *
    from `fnb-data-platform.core.fct_inventory_balance_daily`
),
month_end as (
    select outlet_id, month, sum(on_hand_value) as ending_value
    from b
    where balance_date = last_day(balance_date)
    group by 1, 2
),
flows as (
    select
        outlet_id,
        month,
        sum(theoretical_sales_qty * std_cost_per_unit)                      as recipe_cost,
        sum(waste_qty * std_cost_per_unit)                                  as waste_cost,
        -sum(coalesce(count_variance_qty, 0) * std_cost_per_unit)           as shrinkage_cost,
        sum(purchased_amount)                                               as purchases_actual,
        sum(purchased_amount - purchased_qty * std_cost_per_unit)           as price_variance
    from b
    group by 1, 2
),
sales as (
    select outlet_id, report_month as month, net_sales
    from `fnb-data-platform.marts.mart_pnl_monthly`
    where is_complete_month
)
select
    f.month,
    f.outlet_id,
    s.net_sales,
    p.ending_value                                                          as beginning_value,
    f.purchases_actual,
    e.ending_value,
    p.ending_value + f.purchases_actual - e.ending_value                    as actual_cost,
    f.recipe_cost,
    f.waste_cost,
    f.shrinkage_cost,
    f.price_variance,
    round(f.recipe_cost / s.net_sales * 100, 2)                             as tfc_pct,
    round((p.ending_value + f.purchases_actual - e.ending_value) / s.net_sales * 100, 2) as afc_pct,
    round(f.waste_cost / s.net_sales * 100, 3)                              as waste_pct,
    round(f.shrinkage_cost / s.net_sales * 100, 3)                          as shrinkage_pct,
    round(f.price_variance / s.net_sales * 100, 3)                          as price_variance_pct
from flows as f
inner join sales as s using (outlet_id, month)
inner join month_end as e using (outlet_id, month)
inner join month_end as p
    on p.outlet_id = f.outlet_id and p.month = date_sub(f.month, interval 1 month)
order by 1, 2
