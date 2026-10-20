/*
  Dimensi karyawan untuk analitik: employee_key = hash ber-salt dari employee_id (tidak bisa di-join ke
  direktori restricted maupun ke cashier_id di data POS). Usia & masa kerja hanya dalam bentuk band.
*/
with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

today as (
    select current_date('{{ var("local_tz") }}') as d
)

select
    {{ hash_pii('e.employee_id') }}                                             as employee_key,
    e.outlet_id,
    e.job_role,
    e.employment_type,
    e.gender,
    case
        when extract(year from t.d) - e.birth_year < 25 then '< 25'
        when extract(year from t.d) - e.birth_year < 35 then '25-34'
        when extract(year from t.d) - e.birth_year < 45 then '35-44'
        else '45+'
    end                                                                         as age_band,
    e.hire_source,
    e.hired_date,
    e.terminated_date,
    e.termination_reason,
    e.is_terminated,
    date_diff(coalesce(e.terminated_date, t.d), e.hired_date, day)              as tenure_days,
    case
        when date_diff(coalesce(e.terminated_date, t.d), e.hired_date, day) < 90 then '< 3 bulan'
        when date_diff(coalesce(e.terminated_date, t.d), e.hired_date, day) < 365 then '3-12 bulan'
        when date_diff(coalesce(e.terminated_date, t.d), e.hired_date, day) < 730 then '1-2 tahun'
        else '2+ tahun'
    end                                                                         as tenure_band,
    e.is_terminated and date_diff(e.terminated_date, e.hired_date, day) < 90    as is_early_attrition
from employees as e
cross join today as t
