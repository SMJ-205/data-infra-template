{{ config(enabled = var('enable_hr', false)) }}
-- Absensi hanya boleh tercatat selama masa kerja [hired_date, terminated_date).
select a.attendance_id, a.work_date, e.hired_date, e.terminated_date
from {{ ref('stg_hr__attendance') }} as a
inner join {{ ref('stg_hr__employees') }} as e on a.employee_id = e.employee_id
where
    a.work_date < e.hired_date
    or (e.terminated_date is not null and a.work_date >= e.terminated_date)
