with channels as (
    select * from {{ ref('stg_pos__sales_channels') }}
),

rates as (
    select
        channel_code,
        commission_pct as current_commission_pct
    from {{ ref('stg_pos__channel_commission_rates') }}
    where current_date('{{ var("local_tz") }}') >= effective_from
      and current_date('{{ var("local_tz") }}') < coalesce(effective_to, date '9999-12-31')
)

select
    c.channel_code,
    c.channel_name,
    c.channel_group,
    coalesce(r.current_commission_pct, 0) as current_commission_pct
from channels as c
left join rates as r on r.channel_code = c.channel_code
