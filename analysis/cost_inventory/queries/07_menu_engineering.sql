-- 07. Menu engineering (Kasavana-Smith) gabungan outlet, 6 bulan terakhir yang lengkap.
-- Klasifikasi ulang di level gabungan: popularitas = menu mix >= 70% x rata-rata (1/N);
-- profitabilitas = margin kontribusi per porsi >= rata-rata tertimbang.
with m as (
    select menu_item_id, any_value(menu_name) as menu_name, any_value(category_name) as category_name,
        sum(qty_sold) as qty_sold, sum(net_sales) as net_sales, sum(cogs_standard) as cogs_standard
    from `fnb-data-platform.marts.mart_menu_engineering`
    where report_month between date '2026-04-01' and date '2026-09-01'
    group by 1
),
calc as (
    select *,
        qty_sold / sum(qty_sold) over ()                                    as menu_mix,
        (net_sales - cogs_standard) / qty_sold                              as cm_per_unit,
        sum(net_sales - cogs_standard) over () / sum(qty_sold) over ()      as avg_cm,
        0.7 / count(*) over ()                                              as popularity_threshold
    from m
)
select
    menu_item_id, menu_name, category_name, qty_sold,
    round(net_sales) as net_sales,
    round(cogs_standard / net_sales * 100, 1)                               as food_cost_pct,
    round(menu_mix * 100, 2)                                                as menu_mix_pct,
    round(cm_per_unit)                                                      as cm_per_unit,
    case
        when menu_mix >= popularity_threshold and cm_per_unit >= avg_cm then 'Star'
        when menu_mix >= popularity_threshold then 'Plowhorse'
        when cm_per_unit >= avg_cm then 'Puzzle'
        else 'Dog'
    end                                                                     as menu_class
from calc
order by qty_sold desc
