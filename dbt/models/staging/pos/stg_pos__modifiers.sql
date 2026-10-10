with source as (
    select * from {{ source('pos', 'modifiers') }}
)

select
    modifier_id,
    modifier_name,
    modifier_group,
    cast(price_delta as numeric) as price_delta,
    deleted_at is not null as is_deleted,
    updated_at as updated_at_utc
from source
