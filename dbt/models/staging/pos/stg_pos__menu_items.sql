with source as (
    select * from {{ source('pos', 'menu_items') }}
)

select
    menu_item_id,
    menu_name,
    category_code,
    launched_date,
    discontinued_date,
    is_active,
    deleted_at is not null as is_deleted,
    updated_at as updated_at_utc
from source
