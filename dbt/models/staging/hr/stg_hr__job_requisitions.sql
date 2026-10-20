with source as (
    select * from {{ source('hr', 'job_requisitions') }}
)

select
    requisition_id,
    outlet_id,
    job_role,
    employment_type,
    reason,
    replaces_employee_id,
    opened_date,
    filled_date,
    filled_by_employee_id,
    date_diff(filled_date, opened_date, day)    as days_to_fill,
    updated_at                                  as updated_at_utc
from source
