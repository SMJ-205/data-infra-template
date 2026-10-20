/*
  Grain   : period_month x outlet_id x job_role x employment_type
  Privasi : agregat gaji (rata-rata, median, compa-ratio, total biaya) di-NULL-kan bila headcount_paid
            < var('hr_k_anonymity_min') (k-anonymity). Headcount & jam lembur tetap tampil.
  Compa   : rata-rata gaji pokok / titik tengah band pasar (seed hr_salary_bands); < 0.90 = di bawah pasar.
*/
{{ config(post_hook = "{{ hr_outlet_row_access() }}") }}

with payroll as (
    select * from {{ ref('rst_hr__payroll') }}
),

employees as (
    select employee_id, job_role, employment_type from {{ ref('stg_hr__employees') }}
),

overtime as (
    select
        employee_id,
        date_trunc(work_date, month)    as period_month,
        sum(overtime_hours)             as overtime_hours
    from {{ ref('stg_hr__attendance') }}
    group by 1, 2
),

bands as (
    select * from {{ ref('hr_salary_bands') }}
),

grouped as (
    select
        p.period_month,
        p.outlet_id,
        e.job_role,
        e.employment_type,
        count(distinct p.employee_id)                                   as headcount_paid,
        sum(p.gross_pay)                                                as gross_payroll_cost,
        sum(p.overtime_pay)                                             as overtime_pay,
        sum(coalesce(o.overtime_hours, 0))                              as overtime_hours,
        avg(p.base_pay)                                                 as avg_base_pay,
        approx_quantiles(p.base_pay, 2)[offset(1)]                      as median_base_pay
    from payroll as p
    inner join employees as e on p.employee_id = e.employee_id
    left join overtime as o
        on
            p.employee_id = o.employee_id
            and p.period_month = o.period_month
    group by 1, 2, 3, 4
)

select
    g.period_month,
    g.outlet_id,
    g.job_role,
    g.employment_type,
    g.headcount_paid,
    g.overtime_hours,
    round(safe_divide(g.overtime_hours, g.headcount_paid), 1)                   as overtime_hours_per_head,
    g.headcount_paid < {{ var('hr_k_anonymity_min', 3) }}                       as is_suppressed,
    {{ k_anon('round(g.gross_payroll_cost, 0)', 'g.headcount_paid') }}          as gross_payroll_cost,
    {{ k_anon('round(g.overtime_pay, 0)', 'g.headcount_paid') }}                as overtime_pay,
    {{ k_anon('round(g.avg_base_pay, 0)', 'g.headcount_paid') }}                as avg_base_pay,
    {{ k_anon('round(g.median_base_pay, 0)', 'g.headcount_paid') }}             as median_base_pay,
    {{ k_anon('round(safe_divide(g.avg_base_pay, b.band_mid), 3)', 'g.headcount_paid') }}
                                                                                as compa_ratio
from grouped as g
left join bands as b
    on
        g.job_role = b.job_role
        and g.employment_type = 'Full-time'
