with source as (
    select * from {{ source('pos', 'menu_categories') }}
)

select
    category_code,
    category_name,
    category_group,
    updated_at as updated_at_utc
from source
