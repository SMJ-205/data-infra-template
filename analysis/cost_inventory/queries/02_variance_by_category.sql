-- 02. Lokalisasi masalah: komponen selisih per outlet x kategori bahan (seluruh periode lengkap).
-- Efficiency variance (guideline) = waste tercatat + susut tak tercatat; price variance = invoice - standard cost.
with b as (
    select b.*, i.ingredient_category
    from `fnb-data-platform.core.fct_inventory_balance_daily` as b
    inner join `fnb-data-platform.core.dim_ingredient` as i using (ingredient_id)
    where b.balance_date between date '2025-08-01' and date '2026-09-30'
)
select
    outlet_id,
    ingredient_category,
    round(sum(theoretical_sales_qty * std_cost_per_unit))                           as recipe_cost,
    round(sum(waste_qty * std_cost_per_unit))                                       as waste_cost,
    round(-sum(coalesce(count_variance_qty, 0) * std_cost_per_unit))                as shrinkage_cost,
    round(sum(purchased_amount - purchased_qty * std_cost_per_unit))                as price_variance,
    round(safe_divide(-sum(coalesce(count_variance_qty, 0) * std_cost_per_unit),
                      sum(theoretical_sales_qty * std_cost_per_unit)) * 100, 2)     as shrinkage_pct_of_recipe
from b
group by 1, 2
order by shrinkage_cost desc
