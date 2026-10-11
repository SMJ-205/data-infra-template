-- Memastikan setiap komponen prep item dalam resep menu/modifier aktif memiliki resep prep aktif pada tanggal yang sama
with active_prep_components as (
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
)

select
    c.prep_id,
    c.effective_from as component_from,
    c.effective_to as component_to
from active_prep_components as c
left join prep_recipes as p
    on p.prep_id = c.prep_id
   and c.effective_from < p.effective_to
   and c.effective_to > p.effective_from
where p.prep_id is null
