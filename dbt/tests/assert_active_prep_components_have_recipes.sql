-- Memastikan setiap komponen prep item dalam resep menu/modifier aktif memiliki resep prep aktif pada setiap tanggal aktifnya
with max_data_date as (
    select coalesce(max(order_date), current_date('{{ var("local_tz") }}')) as max_date
    from {{ ref('fct_orders') }}
),

active_prep_components as (
    select
        r.effective_from,
        coalesce(r.effective_to, date '9999-12-31') as effective_to,
        rl.ingredient_id as prep_id
    from {{ ref('stg_pos__recipes') }} as r
    inner join {{ ref('stg_pos__recipe_lines') }} as rl on rl.recipe_id = r.recipe_id
    inner join {{ ref('stg_pos__ingredients') }} as i on i.ingredient_id = rl.ingredient_id
    where i.is_prep_item
),

prep_recipes as (
    select
        prep_ingredient_id as prep_id,
        effective_from,
        coalesce(effective_to, date '9999-12-31') as effective_to
    from {{ ref('stg_pos__recipes') }}
    where prep_ingredient_id is not null
),

component_days as (
    select distinct
        c.prep_id,
        d.date_day
    from active_prep_components as c
    cross join max_data_date as m
    inner join {{ ref('util_dates') }} as d
        on d.date_day between c.effective_from and least(c.effective_to, m.max_date)
    where d.date_day >= {{ var('start_date') }}
)

select
    cd.prep_id,
    cd.date_day
from component_days as cd
left join prep_recipes as p
    on p.prep_id = cd.prep_id
   and cd.date_day >= p.effective_from
   and cd.date_day < p.effective_to
where p.prep_id is null
