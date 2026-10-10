with source as (
    select * from {{ source('pos', 'operating_expenses') }}
)

select
    expense_id,
    outlet_id,
    period_month,
    category_code,
    cast(amount as numeric) as amount,
    description,
    updated_at as updated_at_utc
from source
