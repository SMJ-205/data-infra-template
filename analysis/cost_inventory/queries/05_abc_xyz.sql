-- 05. Klasifikasi ABC-XYZ bahan baku (gabungan 3 outlet, Agustus 2025 - September 2026).
-- ABC: kumulatif nilai pemakaian (A <= 80%, B <= 95%, C sisanya).
-- XYZ: koefisien variasi pemakaian MINGGUAN (menghilangkan pola hari-dalam-minggu):
--      X < 0.10 stabil, Y 0.10-0.25, Z > 0.25 fluktuatif.
with usage_daily as (
    select
        b.balance_date,
        b.ingredient_id,
        sum((b.theoretical_sales_qty + b.waste_qty) * b.std_cost_per_unit)  as usage_value,
        sum(b.theoretical_sales_qty + b.waste_qty)                          as usage_qty
    from `fnb-data-platform.core.fct_inventory_balance_daily` as b
    where b.balance_date between date '2025-08-04' and date '2026-09-27'   -- minggu penuh Senin-Minggu
    group by 1, 2
),
weekly as (
    select date_trunc(balance_date, isoweek) as week, ingredient_id, sum(usage_qty) as qty, sum(usage_value) as value
    from usage_daily
    group by 1, 2
),
stats as (
    select
        ingredient_id,
        sum(value)                                          as usage_value,
        safe_divide(stddev(qty), avg(qty))                  as cv_weekly
    from weekly
    group by 1
    having sum(value) > 0
),
ranked as (
    select
        *,
        sum(usage_value) over (order by usage_value desc) / sum(usage_value) over ()   as cum_share
    from stats
)
select
    r.ingredient_id,
    i.ingredient_name,
    i.ingredient_category,
    i.is_perishable,
    i.shelf_life_days,
    round(r.usage_value)                                                    as usage_value,
    round(r.cum_share * 100, 1)                                             as cum_share_pct,
    round(r.cv_weekly, 3)                                                   as cv_weekly,
    case when r.cum_share <= 0.80 then 'A' when r.cum_share <= 0.95 then 'B' else 'C' end
        || case when r.cv_weekly < 0.10 then 'X' when r.cv_weekly <= 0.25 then 'Y' else 'Z' end
                                                                            as abc_xyz
from ranked as r
inner join `fnb-data-platform.core.dim_ingredient` as i using (ingredient_id)
order by r.usage_value desc
