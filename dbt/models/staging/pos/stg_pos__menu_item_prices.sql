with source as (
    select * from {{ source('pos', 'menu_item_prices') }}
)

select
    menu_item_id,
    channel_group,
    effective_from,
    effective_to,
    cast(selling_price as numeric) as selling_price,
    updated_at as updated_at_utc
from source
