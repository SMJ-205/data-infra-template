/*
  Grain  : applied_quarter x application_source (seluruh outlet; volume per outlet terlalu kecil)
  Retensi: hires_left_within_90d dihitung hanya untuk hire yang sudah >= 90 hari sejak mulai (cohort matang).
*/
with applications as (
    select * from {{ ref('stg_hr__job_applications') }}
),

hires as (
    select employee_id, hired_date, terminated_date
    from {{ ref('stg_hr__employees') }}
),

today as (
    select current_date('{{ var("local_tz") }}') as d
)

select
    date_trunc(date(a.applied_at_local), quarter)                               as applied_quarter,
    a.application_source,
    count(*)                                                                    as applications,
    countif(a.is_screened)                                                      as screened,
    countif(a.is_interviewed)                                                   as interviewed,
    countif(a.is_offered)                                                       as offered,
    countif(a.is_hired)                                                         as hired,
    {{ safe_pct('countif(a.is_hired)', 'count(*)') }}                           as application_to_hire_pct,
    {{ safe_pct('countif(a.is_hired)', 'countif(a.is_offered)') }}              as offer_acceptance_pct,
    round(avg(if(a.is_hired, date_diff(date(a.decided_at_local), date(a.applied_at_local), day), null)), 1)
                                                                                as avg_days_apply_to_accept,
    countif(h.employee_id is not null and date_diff(t.d, h.hired_date, day) >= 90)
                                                                                as hires_matured_90d,
    countif(
        h.employee_id is not null
        and date_diff(t.d, h.hired_date, day) >= 90
        and h.terminated_date is not null
        and date_diff(h.terminated_date, h.hired_date, day) < 90
    )                                                                           as hires_left_within_90d
from applications as a
cross join today as t
left join hires as h on a.hired_employee_id = h.employee_id
group by 1, 2
