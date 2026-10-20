-- RESTRICTED: direktori karyawan dengan PII apa adanya + gaji & rating terakhir. Hanya untuk HR Manager.
with employees as (
    select * from {{ source('hr', 'employees') }}
),

current_comp as (
    select *
    from {{ ref('rst_hr__compensation') }}
    where is_current
),

last_review as (
    select employee_id, rating, review_period
    from {{ ref('rst_hr__performance_reviews') }}
    qualify row_number() over (partition by employee_id order by reviewed_at_local desc) = 1
)

select
    e.employee_id,
    e.full_name,
    e.phone_number,
    e.email,
    e.national_id,
    e.birth_date,
    e.gender,
    e.outlet_id,
    e.job_role,
    e.employment_type,
    e.hire_source,
    e.hired_date,
    e.terminated_date,
    e.termination_reason,
    c.base_salary_monthly,
    c.hourly_rate,
    c.allowance_monthly,
    r.rating            as last_rating,
    r.review_period     as last_review_period
from employees as e
left join current_comp as c on e.employee_id = c.employee_id
left join last_review as r on e.employee_id = r.employee_id
