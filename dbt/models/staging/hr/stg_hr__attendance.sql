with source as (
    select * from {{ source('hr', 'attendance') }}
)

select
    attendance_id,
    employee_id,
    outlet_id,
    work_date,
    status,
    cast(scheduled_hours as numeric)        as scheduled_hours,
    {{ to_local_datetime('clock_in_at') }}  as clock_in_at_local,
    {{ to_local_datetime('clock_out_at') }} as clock_out_at_local,
    cast(late_minutes as int64)             as late_minutes,
    cast(worked_hours as numeric)           as worked_hours,
    cast(overtime_hours as numeric)         as overtime_hours,
    updated_at                              as updated_at_utc
from source
