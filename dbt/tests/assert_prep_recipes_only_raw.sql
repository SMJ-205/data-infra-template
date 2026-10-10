-- tests/assert_prep_recipes_only_raw.sql : prep item tidak boleh berisi prep item lain (batas explosion 1 level)
select r.recipe_id, rl.ingredient_id
from {{ ref('stg_pos__recipes') }} as r
inner join {{ ref('stg_pos__recipe_lines') }} as rl on rl.recipe_id = r.recipe_id
inner join {{ ref('stg_pos__ingredients') }} as i on i.ingredient_id = rl.ingredient_id
where r.prep_ingredient_id is not null
  and i.is_prep_item
