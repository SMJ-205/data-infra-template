-- tests/assert_inventory_balance_reconciles_variance.sql : dua jalur hitung harus sepakat.
-- Saldo harian (perpetual, reset tiap opname) vs mart variance (periode antar-opname):
-- count_variance_qty pada tanggal opname = -unexplained_variance_qty periode yang berakhir di tanggal itu.
select
    v.outlet_id,
    v.ingredient_id,
    v.period_end,
    v.unexplained_variance_qty,
    b.count_variance_qty
from {{ ref('mart_inventory_variance') }} as v
left join {{ ref('fct_inventory_balance_daily') }} as b
    on
        v.outlet_id = b.outlet_id
        and v.ingredient_id = b.ingredient_id
        and v.period_end = b.balance_date
where
    b.count_variance_qty is null
    or abs(v.unexplained_variance_qty + b.count_variance_qty) > 0.001
