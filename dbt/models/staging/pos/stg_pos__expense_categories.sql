with source as (
    select * from {{ source('pos', 'expense_categories') }}
)

select
    category_code,
    category_name,
    pnl_line,
    updated_at as updated_at_utc
from source
