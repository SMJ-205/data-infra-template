with source as (
    select * from {{ source('pos', 'suppliers') }}
)

select
    supplier_id,
    supplier_name,
    city,
    cast(payment_term_days as int64) as payment_term_days,
    deleted_at is not null as is_deleted,
    updated_at as updated_at_utc
from source
