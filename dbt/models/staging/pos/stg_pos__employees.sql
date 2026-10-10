with source as (
    select * from {{ source('pos', 'employees') }}
)

select
    employee_id,
    outlet_id,
    job_role,
    hired_date,
    terminated_date,
    terminated_date is not null as is_terminated,
    {{ to_local_datetime('created_at') }} as created_at_local,
    updated_at as updated_at_utc
from source
