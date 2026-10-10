with source as (
    select * from {{ source('pos', 'modifier_lines') }}
)

select
    modifier_id,
    ingredient_id,
    cast(qty_delta as numeric) as qty_delta,
    updated_at as updated_at_utc
from source
