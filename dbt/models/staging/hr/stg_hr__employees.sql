-- PII (nama, telepon, NIK, email) dibuang; tanggal lahir digeneralisasi ke tahun. Versi lengkap: hr_restricted.
with source as (
    select * from {{ source('hr', 'employees') }}
)

select
    employee_id,
    outlet_id,
    job_role,
    employment_type,
    gender,
    extract(year from birth_date)           as birth_year,
    hire_source,
    hired_date,
    terminated_date,
    termination_reason,
    terminated_date is not null             as is_terminated,
    updated_at                              as updated_at_utc
from source
