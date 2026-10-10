/*
  Grain  : date_day x item_type x item_id
  Isi    : standard cost per 1 unit item = Σ qty bahan raw × standard cost bahan yang berlaku hari itu
  Kontrol: n_components_missing_cost wajib 0 (test) → mencegah HPP diam-diam terlalu rendah
*/
with explosion as (
    select * from {{ ref('int_item_explosion_daily') }}
),

costs as (
    select * from {{ ref('stg_pos__ingredient_standard_costs') }}
)

select
    e.date_day,
    e.item_type,
    e.item_id,
    sum(e.qty_per_unit * c.standard_cost_per_base_uom)  as std_cost_per_unit,
    count(*)                                            as n_components,
    countif(c.ingredient_id is null)                    as n_components_missing_cost
from explosion as e
left join costs as c
    on c.ingredient_id = e.ingredient_id
   and e.date_day >= c.effective_from
   and e.date_day <  coalesce(c.effective_to, date '9999-12-31')
group by 1, 2, 3
