with outlets as (
    select * from {{ ref('stg_pos__outlets') }}
)

select
    outlet_id,
    outlet_name,
    city,
    outlet_type,
    seat_capacity,
    opened_date,
    closed_date,
    closed_date is null or closed_date > current_date('{{ var("local_tz") }}') as is_active,
    date_diff(
        coalesce(closed_date, current_date('{{ var("local_tz") }}')),
        opened_date,
        day
    ) as operating_days_to_date
from outlets
