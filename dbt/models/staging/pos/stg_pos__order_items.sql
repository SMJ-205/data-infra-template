with source as (
    select * from {{ source('pos', 'order_items') }}
)

select
    cast(order_item_id as string)               as order_item_id,
    order_id,
    menu_item_id,
    cast(qty as int64)                          as qty,
    cast(unit_price as numeric)                 as unit_price,
    cast(line_discount_amount as numeric)       as line_discount_amount,
    line_status,
    void_reason,
    updated_at                                  as updated_at_utc
from source
