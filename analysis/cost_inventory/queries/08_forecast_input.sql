-- 08. Input forecasting (dipakai analysis/cost_inventory/forecast.py di GitHub Actions):
-- pemakaian harian per outlet x bahan (resep + waste) beserta stok akhir hari.
select
    b.balance_date,
    b.outlet_id,
    b.ingredient_id,
    i.ingredient_name,
    i.base_uom,
    i.shelf_life_days,
    b.theoretical_sales_qty + b.waste_qty   as usage_qty,
    b.on_hand_qty,
    b.std_cost_per_unit
from `fnb-data-platform.core.fct_inventory_balance_daily` as b
inner join `fnb-data-platform.core.dim_ingredient` as i using (ingredient_id)
where b.balance_date between date '2025-08-01' and date '2026-10-21'
order by 2, 3, 1
