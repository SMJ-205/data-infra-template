-- RESTRICTED: rating kinerja individual.
select
    review_id,
    employee_id,
    review_period,
    reviewer_id,
    cast(rating as int64)                       as rating,
    cast(goals_met_pct as numeric)              as goals_met_pct,
    {{ to_local_datetime('reviewed_at') }}      as reviewed_at_local
from {{ source('hr', 'performance_reviews') }}
