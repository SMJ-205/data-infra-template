{{ config(
    partition_by = {'field': 'work_date', 'data_type': 'date', 'granularity': 'month'},
    cluster_by = ['outlet_id', 'job_role']
) }}

with attendance as (
    select * from {{ ref('stg_hr__attendance') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    {{ hash_pii('a.employee_id') }}         as employee_key,
    a.work_date,
    a.outlet_id,
    e.job_role,
    e.employment_type,
    a.status,
    a.status = 'Late'                       as is_late,
    a.status = 'Absent'                     as is_absent,
    a.status = 'Leave'                      as is_leave,
    a.scheduled_hours,
    a.worked_hours,
    a.late_minutes,
    a.overtime_hours
from attendance as a
inner join employees as e on a.employee_id = e.employee_id
