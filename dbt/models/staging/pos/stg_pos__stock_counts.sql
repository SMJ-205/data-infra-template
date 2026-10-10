with source as (
    select * from {{ source('pos', 'stock_counts') }}
)

select
    count_id,
    outlet_id,
    count_date,
    count_type,
    counted_by                          as counted_by_employee_id,
    updated_at                          as updated_at_utc
from source
