with source as (
    select * from {{ source('pos', 'stock_count_lines') }}
)

select
    count_id,
    ingredient_id,
    cast(counted_qty_base as numeric)   as counted_qty_base,
    updated_at                          as updated_at_utc
from source
