with source as (
    select * from {{ source('pos', 'promotions') }}
)

select
    promo_code,
    promo_name,
    promo_type,
    cast(promo_value as numeric) as promo_value,
    funded_by,
    start_date,
    end_date,
    updated_at as updated_at_utc
from source
