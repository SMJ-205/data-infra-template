with source as (
    select * from {{ source('pos', 'recipes') }}
)

select
    recipe_id,
    menu_item_id,
    prep_ingredient_id,
    cast(version_no as int64) as version_no,
    cast(yield_qty as numeric) as yield_qty,
    effective_from,
    effective_to,
    updated_at as updated_at_utc
from source
