{{
  config(
    materialized = 'table',
    schema = 'core'
  )
}}

with spine as (
    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('2024-01-01' as date)",
        end_date="cast('2031-01-01' as date)"
    ) }}
)

select cast(date_day as date) as date_day
from spine
