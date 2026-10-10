with source as (
    select * from {{ source('pos', 'order_item_modifiers') }}
)

select
    cast(order_item_id as string)   as order_item_id,
    modifier_id,
    cast(price_delta as numeric)    as price_delta,
    updated_at                      as updated_at_utc
from source
