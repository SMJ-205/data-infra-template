/*
  Grain   : review_period x outlet_id x job_role. Disiplin (absensi) vs hasil review kinerja.
  Privasi : rating rata-rata di-NULL-kan bila jumlah karyawan ter-review < var('hr_k_anonymity_min').
*/
{{ config(post_hook = "{{ hr_outlet_row_access() }}") }}

{% set periods = var('hr_review_periods') %}

with periods as (
    {% for p in periods %}
        select '{{ p.period }}' as review_period, date '{{ p.start }}' as period_start, date '{{ p.end }}' as period_end
        {% if not loop.last %}union all{% endif %}
    {% endfor %}
),

attendance as (
    select
        p.review_period,
        a.employee_id,
        a.outlet_id,
        countif(a.status in ('Present', 'Late'))                    as days_worked,
        countif(a.status = 'Late')                                  as days_late,
        countif(a.status = 'Absent')                                as days_absent,
        count(*)                                                    as days_scheduled,
        sum(a.overtime_hours)                                       as overtime_hours
    from {{ ref('stg_hr__attendance') }} as a
    inner join periods as p on a.work_date between p.period_start and p.period_end
    group by 1, 2, 3
),

reviews as (
    select * from {{ ref('rst_hr__performance_reviews') }}
),

employees as (
    select employee_id, job_role from {{ ref('stg_hr__employees') }}
),

grouped as (
    select
        a.review_period,
        a.outlet_id,
        e.job_role,
        count(distinct a.employee_id)                               as headcount,
        count(r.review_id)                                          as reviewed,
        sum(a.days_scheduled)                                       as days_scheduled,
        sum(a.days_worked)                                          as days_worked,
        sum(a.days_late)                                            as days_late,
        sum(a.days_absent)                                          as days_absent,
        sum(a.overtime_hours)                                       as overtime_hours,
        avg(r.rating)                                               as avg_rating,
        avg(r.goals_met_pct)                                        as avg_goals_met_pct
    from attendance as a
    inner join employees as e on a.employee_id = e.employee_id
    left join reviews as r
        on
            a.employee_id = r.employee_id
            and a.review_period = r.review_period
    group by 1, 2, 3
)

select
    review_period,
    outlet_id,
    job_role,
    headcount,
    reviewed,
    {{ safe_pct('days_worked', 'days_scheduled') }}                         as attendance_pct,
    {{ safe_pct('days_late', 'days_worked') }}                              as late_pct,
    {{ safe_pct('days_absent', 'days_scheduled') }}                         as absence_pct,
    round(safe_divide(overtime_hours, headcount), 1)                        as overtime_hours_per_head,
    reviewed < {{ var('hr_k_anonymity_min', 3) }}                           as is_rating_suppressed,
    {{ k_anon('round(avg_rating, 2)', 'reviewed') }}                        as avg_rating,
    {{ k_anon('round(avg_goals_met_pct, 1)', 'reviewed') }}                 as avg_goals_met_pct
from grouped
