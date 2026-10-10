with source as (
    select * from {{ source('pos', 'recipe_lines') }}
)

select
    recipe_id,
    ingredient_id,
    cast(qty_per_yield as numeric) as qty_per_yield,
    cast(loss_pct as numeric) as loss_pct,
    updated_at as updated_at_utc
from source
