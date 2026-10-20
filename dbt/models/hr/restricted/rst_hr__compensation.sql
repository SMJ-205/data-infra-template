-- RESTRICTED: riwayat gaji individual.
select
    employee_id,
    effective_from,
    effective_to,
    cast(base_salary_monthly as numeric)    as base_salary_monthly,
    cast(hourly_rate as numeric)            as hourly_rate,
    cast(allowance_monthly as numeric)      as allowance_monthly,
    change_reason,
    effective_to is null                    as is_current
from {{ source('hr', 'employee_compensation') }}
