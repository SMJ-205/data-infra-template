with dates as (
    select date_day from {{ ref('util_dates') }}
),

events as (
    select * from {{ ref('id_calendar_events') }}
)

select
    d.date_day,
    extract(year from d.date_day)                   as year,
    extract(quarter from d.date_day)                as quarter,
    extract(month from d.date_day)                  as month,
    extract(isoweek from d.date_day)                as iso_week,
    extract(dayofweek from d.date_day)              as day_of_week_num,
    format_date('%A', d.date_day)                   as day_of_week_name,
    extract(dayofweek from d.date_day) in (1, 7)    as is_weekend,
    extract(day from d.date_day) >= 25
      or extract(day from d.date_day) = 1           as is_payday_window,
    e.event_name                                    as calendar_event,
    e.event_type                                    as calendar_event_type,
    coalesce(e.event_type = 'Ramadan', false)       as is_ramadan
from dates as d
left join events as e
    on d.date_day between e.start_date and e.end_date
