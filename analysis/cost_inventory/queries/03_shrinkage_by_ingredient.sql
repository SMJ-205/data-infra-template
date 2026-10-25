-- 03. Bahan dengan susut tak tercatat terbesar per outlet, dan tren bulanannya.
with b as (
    select b.*, i.ingredient_name, i.base_uom
    from `fnb-data-platform.core.fct_inventory_balance_daily` as b
    inner join `fnb-data-platform.core.dim_ingredient` as i using (ingredient_id)
    where b.balance_date between date '2025-08-01' and date '2026-09-30'
)
select
    date_trunc(balance_date, month)                                                 as month,
    outlet_id,
    ingredient_id,
    any_value(ingredient_name)                                                      as ingredient_name,
    any_value(base_uom)                                                             as base_uom,
    round(sum(theoretical_sales_qty + waste_qty), 1)                                as recorded_usage_qty,
    round(-sum(coalesce(count_variance_qty, 0)), 1)                                 as shrinkage_qty,
    round(-sum(coalesce(count_variance_qty, 0) * std_cost_per_unit))                as shrinkage_cost,
    round(safe_divide(-sum(coalesce(count_variance_qty, 0)),
                      sum(theoretical_sales_qty + waste_qty)) * 100, 2)             as shrinkage_pct_of_usage
from b
group by 1, 2, 3
order by 1, shrinkage_cost desc
