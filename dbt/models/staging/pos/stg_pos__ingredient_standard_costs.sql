with source as (
    select * from {{ source('pos', 'ingredient_standard_costs') }}
)

select
    ingredient_id,
    effective_from,
    effective_to,
    cast(standard_cost_per_base_uom as numeric) as standard_cost_per_base_uom,
    updated_at as updated_at_utc
from source
