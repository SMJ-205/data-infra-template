/*
  Grain   : date_day x item_type x item_id x ingredient_id (bahan raw)
  item_type: 'Menu Item' | 'Modifier' | 'Prep Item' | 'Ingredient'
  Rumus   : qty bruto per unit = qty_per_yield / (1 - loss_pct/100) / yield_qty
  Asumsi  : prep item hanya tersusun dari bahan raw (dijaga test assert_prep_recipes_only_raw)
*/
with dates as (
    select date_day
    from {{ ref('util_dates') }}
    where date_day between {{ var('start_date') }} and current_date('{{ var("local_tz") }}')
),

ingredients as (
    select * from {{ ref('stg_pos__ingredients') }}
),

recipes as (
    select * from {{ ref('stg_pos__recipes') }}
),

recipe_lines as (
    select * from {{ ref('stg_pos__recipe_lines') }}
),

modifier_lines as (
    select * from {{ ref('stg_pos__modifier_lines') }}
),

recipe_lines_on_day as (
    select
        d.date_day,
        if(r.menu_item_id is not null, 'Menu Item', 'Prep Item')      as item_type,
        coalesce(r.menu_item_id, r.prep_ingredient_id)                 as item_id,
        rl.ingredient_id                                               as component_id,
        rl.qty_per_yield / (1 - rl.loss_pct / 100) / r.yield_qty       as qty_per_unit
    from dates as d
    inner join recipes as r
        on d.date_day >= r.effective_from
       and d.date_day <  coalesce(r.effective_to, date '9999-12-31')
    inner join recipe_lines as rl
        on rl.recipe_id = r.recipe_id
),

modifier_lines_on_day as (
    select
        d.date_day,
        'Modifier'          as item_type,
        ml.modifier_id      as item_id,
        ml.ingredient_id    as component_id,
        ml.qty_delta        as qty_per_unit
    from dates as d
    cross join modifier_lines as ml
),

first_level as (
    select * from recipe_lines_on_day
    union all
    select * from modifier_lines_on_day
),

prep_to_raw as (
    select date_day, item_id as prep_id, component_id as raw_id, qty_per_unit
    from recipe_lines_on_day
    where item_type = 'Prep Item'
),

exploded as (
    -- 1) komponen raw langsung
    select f.date_day, f.item_type, f.item_id, f.component_id as ingredient_id, f.qty_per_unit
    from first_level as f
    inner join ingredients as i
        on i.ingredient_id = f.component_id
       and not i.is_prep_item

    union all

    -- 2) komponen prep diurai ke bahan raw (left join agar prep tanpa resep aktif tetap keluar dengan raw_id NULL)
    select
        f.date_day,
        f.item_type,
        f.item_id,
        p.raw_id as ingredient_id,
        f.qty_per_unit * coalesce(p.qty_per_unit, cast(1 as numeric)) as qty_per_unit
    from first_level as f
    inner join ingredients as i
        on i.ingredient_id = f.component_id
       and i.is_prep_item
    left join prep_to_raw as p
        on p.date_day = f.date_day
       and p.prep_id = f.component_id

    union all

    -- 3) bahan raw sebagai dirinya sendiri (untuk valuasi waste & stock)
    select d.date_day, 'Ingredient', i.ingredient_id, i.ingredient_id, cast(1 as numeric)
    from dates as d
    cross join ingredients as i
    where not i.is_prep_item
)

select
    date_day,
    item_type,
    item_id,
    ingredient_id,
    sum(qty_per_unit) as qty_per_unit
from exploded
group by 1, 2, 3, 4
