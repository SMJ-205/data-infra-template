with ingredients as (
    select * from {{ ref('stg_pos__ingredients') }}
),

latest_cost as (
    select
        ingredient_id,
        standard_cost_per_base_uom as current_std_cost
    from {{ ref('stg_pos__ingredient_standard_costs') }}
    where current_date('{{ var("local_tz") }}') >= effective_from
      and current_date('{{ var("local_tz") }}') < coalesce(effective_to, date '9999-12-31')
)

select
    i.ingredient_id,
    i.ingredient_name,
    i.ingredient_category,
    i.base_uom,
    i.is_prep_item,
    i.is_perishable,
    i.shelf_life_days,
    i.is_deleted,
    c.current_std_cost
from ingredients as i
left join latest_cost as c on c.ingredient_id = i.ingredient_id
