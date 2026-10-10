with source as (
    select * from {{ source('pos', 'ingredients') }}
)

select
    ingredient_id,
    ingredient_name,
    ingredient_category,
    base_uom,
    is_prep_item,
    is_perishable,
    cast(shelf_life_days as int64) as shelf_life_days,
    deleted_at is not null as is_deleted,
    updated_at as updated_at_utc
from source
