{{
  config(
    materialized = 'table',
    tags = ['finance', 'monthly']
  )
}}

with actual_opex as (
    select
        e.period_month,
        e.outlet_id,
        c.pnl_line,
        sum(e.amount) as amount,
        false as is_opex_estimated
    from {{ ref('stg_pos__operating_expenses') }} as e
    inner join {{ ref('stg_pos__expense_categories') }} as c on c.category_code = e.category_code
    group by 1, 2, 3
),

outlet_months as (
    select
        date_trunc(d.date_day, month)   as period_month,
        o.outlet_id,
        count(*)                        as active_days_in_month
    from {{ ref('util_dates') }} as d
    inner join {{ ref('stg_pos__outlets') }} as o
        on d.date_day between o.opened_date and coalesce(o.closed_date, date '9999-12-31')
    where d.date_day >= {{ var('start_date') }}
      and d.date_day <= last_day(current_date('{{ var("local_tz") }}'), month)
    group by 1, 2
),

latest_actual as (
    select max(period_month) as max_actual_month from actual_opex
),

accrued_opex as (
    select
        m.period_month,
        a.outlet_id,
        a.pnl_line,
        a.amount,
        true as is_opex_estimated
    from (
        select distinct om.period_month
        from outlet_months as om
        cross join latest_actual as l
        where l.max_actual_month is not null
          and om.period_month > l.max_actual_month
    ) as m
    cross join (
        select a.outlet_id, a.pnl_line, a.amount
        from actual_opex as a
        inner join latest_actual as l on a.period_month = l.max_actual_month
    ) as a
),

all_opex as (
    select * from actual_opex
    union all
    select * from accrued_opex
),

sales_months as (
    select date_trunc(order_date, month) as period_month, outlet_id, sum(net_sales_amount) as net_sales
    from {{ ref('fct_order_lines') }}
    where is_revenue_line
    group by 1, 2
),

basis as (
    select
        om.period_month,
        om.outlet_id,
        om.active_days_in_month,
        coalesce(sm.net_sales, 0)                                           as net_sales,
        count(*) over (partition by om.period_month)                        as n_outlets,
        sum(coalesce(sm.net_sales, 0)) over (partition by om.period_month)  as total_net_sales
    from outlet_months as om
    left join sales_months as sm
        on sm.period_month = om.period_month and sm.outlet_id = om.outlet_id
),

direct_cost as (
    select
        coalesce(b.period_month, o.period_month) as period_month,
        coalesce(b.outlet_id, 'Unallocated')     as outlet_id,
        o.pnl_line,
        o.amount                                 as allocated_amount,
        coalesce(b.active_days_in_month, extract(day from last_day(o.period_month))) as active_days_in_month,
        if(b.outlet_id is null, 'Unallocated', 'Direct') as allocation_type,
        o.is_opex_estimated
    from all_opex as o
    left join basis as b on b.period_month = o.period_month and b.outlet_id = o.outlet_id
    where o.outlet_id is not null
),

shared_cost as (
    select
        coalesce(b.period_month, o.period_month) as period_month,
        coalesce(b.outlet_id, 'Unallocated')     as outlet_id,
        o.pnl_line,
        case
            when b.outlet_id is null then o.amount
            else o.amount * coalesce(
                safe_divide(b.net_sales, b.total_net_sales),
                safe_divide(cast(1 as numeric), cast(b.n_outlets as numeric))
            )
        end as allocated_amount,
        coalesce(b.active_days_in_month, extract(day from last_day(o.period_month))) as active_days_in_month,
        if(b.outlet_id is null, 'Unallocated', 'HQ Allocation') as allocation_type,
        o.is_opex_estimated
    from all_opex as o
    left join basis as b on b.period_month = o.period_month
    where o.outlet_id is null
)

select * from direct_cost
union all
select * from shared_cost
