with source as (
    select * from {{ source('pos', 'customers') }}
)

select
    customer_id,
    {{ hash_pii('phone_number') }} as phone_hash,
    {{ hash_pii('lower(trim(email))') }} as email_hash,
    extract(year from birth_date) as birth_year,
    {{ to_local_datetime('registered_at') }} as registered_at_local,
    deleted_at is not null as is_deleted,
    updated_at as updated_at_utc
from source
