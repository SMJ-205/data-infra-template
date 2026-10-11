with dates as (
    select date_day from {{ ref('util_dates') }}
),

events as (
    select * from {{ ref('id_calendar_events') }}
),

ramadan_days as (
    select distinct
        d.date_day,
        true as is_ramadan
    from dates as d
    inner join events as e
        on e.event_type = 'Ramadan'
        and d.date_day between e.start_date and e.end_date
),

holiday_days as (
    select
        d.date_day,
        string_agg(e.event_name, ', ' order by e.start_date, e.event_name) as holiday_name,
        string_agg(distinct e.event_type, ', ') as holiday_type,
        true as is_holiday
    from dates as d
    inner join events as e
        on e.event_type != 'Ramadan'
        and d.date_day between e.start_date and e.end_date
    group by 1
)

select
    d.date_day,
    extract(year from d.date_day)                   as year,
    extract(quarter from d.date_day)                as quarter,
    extract(month from d.date_day)                  as month,
    extract(isoyear from d.date_day)                as iso_year,
    extract(isoweek from d.date_day)                as iso_week,
    extract(dayofweek from d.date_day)              as day_of_week_num,
    format_date('%A', d.date_day)                   as day_of_week_name,
    extract(dayofweek from d.date_day) in (1, 7)    as is_weekend,
    extract(day from d.date_day) >= 25
      or extract(day from d.date_day) = 1           as is_payday_window,
    coalesce(h.holiday_name, case when r.is_ramadan then 'Ramadan' end) as calendar_event,
    coalesce(h.holiday_type, case when r.is_ramadan then 'Ramadan' end) as calendar_event_type,
    coalesce(h.is_holiday, false)                   as is_holiday,
    coalesce(r.is_ramadan, false)                   as is_ramadan
from dates as d
left join ramadan_days as r
    on d.date_day = r.date_day
left join holiday_days as h
    on d.date_day = h.date_day
