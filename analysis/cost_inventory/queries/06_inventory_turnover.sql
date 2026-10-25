-- 06. Perputaran stok per kategori bahan (gabungan outlet, per bulan):
--   ITR = nilai pemakaian (COGS bahan) / rata-rata nilai stok (awal & akhir bulan); DSI = hari dalam bulan / ITR.
with b as (
    select date_trunc(balance_date, month) as month, b.*, i.ingredient_category
    from `fnb-data-platform.core.fct_inventory_balance_daily` as b
    inner join `fnb-data-platform.core.dim_ingredient` as i using (ingredient_id)
),
month_end as (
    select month, ingredient_category, sum(on_hand_value) as ending_value
    from b where balance_date = last_day(balance_date) group by 1, 2
),
usage as (
    select month, ingredient_category,
        sum((theoretical_sales_qty + waste_qty) * std_cost_per_unit) - sum(coalesce(count_variance_qty, 0) * std_cost_per_unit)
            as cogs_value,
        count(distinct balance_date) as days
    from b group by 1, 2
)
select
    u.month,
    u.ingredient_category,
    round(u.cogs_value)                                                         as cogs_value,
    round((p.ending_value + e.ending_value) / 2)                                as avg_inventory_value,
    round(safe_divide(u.cogs_value, (p.ending_value + e.ending_value) / 2), 1) as itr,
    round(safe_divide(u.days, safe_divide(u.cogs_value, (p.ending_value + e.ending_value) / 2)), 1) as dsi_days
from usage as u
inner join month_end as e using (month, ingredient_category)
inner join month_end as p on p.ingredient_category = u.ingredient_category and p.month = date_sub(u.month, interval 1 month)
where u.month between date '2025-08-01' and date '2026-09-01'
order by 1, 2
