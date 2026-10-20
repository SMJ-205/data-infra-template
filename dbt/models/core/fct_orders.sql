{{
  config(
    materialized = 'incremental',
    incremental_strategy = 'insert_overwrite',
    partition_by = {'field': 'order_date', 'data_type': 'date', 'granularity': 'day'},
    cluster_by = ['outlet_id', 'channel_code'],
    on_schema_change = 'fail',
    pre_hook = "{{ guard_incremental_relation() }}",
    tags = ['finance', 'daily']
  )
}}
/*
  Incremental: insert_overwrite per order_date (pola sama dengan fct_order_lines, lihat macros/incremental.sql).
  Partisi dibangun ulang bila order, payment, atau baris fct_order_lines-nya berubah sejak watermark.
*/
with
{% if is_incremental() %}
changed_dates as (
    select o.order_date
    from {{ ref('stg_pos__orders') }} as o
    where o.updated_at_utc >= {{ late_arriving_watermark() }}

    union distinct

    select o.order_date
    from {{ ref('stg_pos__payments') }} as p
    inner join {{ ref('stg_pos__orders') }} as o on o.order_id = p.order_id
    where p.updated_at_utc >= {{ late_arriving_watermark() }}

    union distinct

    select fl.order_date
    from {{ ref('fct_order_lines') }} as fl
    where fl.source_updated_at_utc >= {{ late_arriving_watermark() }}
),
{% endif %}

orders as (
    select o.*
    from {{ ref('stg_pos__orders') }} as o
    {% if is_incremental() %}
        where o.order_date in (select cd.order_date from changed_dates as cd)
    {% endif %}
),

lines as (
    select
        order_id,
        sum(gross_sales_amount)         as gross_sales_amount,
        sum(merchant_discount_amount)   as merchant_discount_amount,
        sum(net_sales_amount)           as net_sales_amount,
        sum(cogs_std_amount)            as cogs_std_amount,
        sum(qty)                        as units,
        max(source_updated_at_utc)      as source_updated_at_utc
    from {{ ref('fct_order_lines') }}
    where
        is_revenue_line
        {% if is_incremental() %}
            and order_date in (select cd.order_date from changed_dates as cd)
        {% endif %}
    group by 1
),

payments as (
    select
        order_id,
        sum(amount)                                                 as paid_amount,
        sum(mdr_fee_amount)                                         as payment_fee_amount,
        string_agg(distinct payment_method order by payment_method) as payment_methods,
        max(updated_at_utc)                                         as updated_at_utc
    from {{ ref('stg_pos__payments') }}
    where order_id in (select o.order_id from orders as o)
    group by 1
),

rates as (
    select * from {{ ref('stg_pos__channel_commission_rates') }}
)

select
    o.order_id,
    o.order_date,
    o.ordered_at_local,
    o.order_hour_local,
    o.outlet_id,
    o.channel_code,
    o.customer_id,
    o.promo_code,
    o.order_status,
    o.guest_count,
    coalesce(l.gross_sales_amount, 0)                               as gross_sales_amount,
    coalesce(l.merchant_discount_amount, 0)                         as merchant_discount_amount,
    coalesce(l.net_sales_amount, 0)                                 as net_sales_amount,
    coalesce(l.cogs_std_amount, 0)                                  as cogs_std_amount,
    coalesce(l.units, 0)                                            as units,
    o.service_charge_amount,
    o.tax_amount,
    o.total_amount,
    coalesce(p.paid_amount, 0)                                      as paid_amount,
    coalesce(p.payment_fee_amount, 0)                               as payment_fee_amount,
    p.payment_methods,
    coalesce(r.commission_pct, 0)                                   as commission_pct,
    if(o.order_status = 'Completed',
       coalesce(l.net_sales_amount, 0) * coalesce(r.commission_pct, 0) / 100,
       0)                                                           as channel_commission_amount,
    greatest(
        o.updated_at_utc,
        coalesce(p.updated_at_utc, o.updated_at_utc),
        coalesce(l.source_updated_at_utc, o.updated_at_utc)
    )                                                               as source_updated_at_utc
from orders as o
left join lines as l on l.order_id = o.order_id
left join payments as p on p.order_id = o.order_id
left join rates as r
    on r.channel_code = o.channel_code
   and o.order_date >= r.effective_from
   and o.order_date <  coalesce(r.effective_to, date '9999-12-31')
