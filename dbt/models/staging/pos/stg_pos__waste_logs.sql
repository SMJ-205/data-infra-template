with source as (
    select * from {{ source('pos', 'waste_logs') }}
)

select
    waste_id,
    outlet_id,
    logged_at                           as logged_at_utc,
    {{ to_local_datetime('logged_at') }} as logged_at_local,
    {{ to_local_date('logged_at') }}    as waste_date,
    ingredient_id,
    menu_item_id,
    cast(qty as numeric)                as qty,
    reason_code,
    recorded_by                         as recorded_by_employee_id,
    notes,
    updated_at                          as updated_at_utc
from source
