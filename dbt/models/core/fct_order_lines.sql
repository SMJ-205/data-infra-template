{{
  config(
    materialized = 'incremental',
    incremental_strategy = 'insert_overwrite',
    partition_by = {'field': 'order_date', 'data_type': 'date', 'granularity': 'day'},
    cluster_by = ['outlet_id', 'menu_item_id'],
    on_schema_change = 'append_new_columns',
    tags = ['finance', 'daily']
  )
}}
/*
  Grain   : 1 baris = 1 order_item_id
  Aturan  : is_revenue_line = order Completed AND line Served
            diskon level order dialokasikan pro-rata ke gross line revenue
            diskon yang didanai Platform TIDAK mengurangi net sales merchant
            COGS standar = qty × (std cost menu + std cost modifier) pada tanggal order
  Refresh : insert_overwrite partisi order_date >= max partisi - lookback_days
*/
with orders as (
    select *
    from {{ ref('stg_pos__orders') }}
    {% if is_incremental() %}
    where order_date >= date_sub(_dbt_max_partition, interval {{ var('lookback_days') }} day)
    {% endif %}
),

items as (
    select * from {{ ref('stg_pos__order_items') }}
),

item_costs as (
    select * from {{ ref('int_item_std_cost_daily') }}
),

modifiers as (
    select
        m.order_item_id,
        sum(m.price_delta)                          as modifier_price_per_unit,
        sum(coalesce(c.std_cost_per_unit, 0))       as modifier_cost_per_unit
    from {{ ref('stg_pos__order_item_modifiers') }} as m
    inner join items as i on i.order_item_id = m.order_item_id
    inner join orders as o on o.order_id = i.order_id
    left join item_costs as c
        on c.item_type = 'Modifier'
       and c.item_id = m.modifier_id
       and c.date_day = o.order_date
    group by 1
),

promotions as (
    select promo_code, funded_by from {{ ref('stg_pos__promotions') }}
),

lines as (
    select
        i.order_item_id,
        i.order_id,
        o.order_date,
        o.ordered_at_local,
        o.outlet_id,
        o.channel_code,
        o.customer_id,
        i.menu_item_id,
        o.order_status,
        i.line_status,
        o.order_status = 'Completed' and i.line_status = 'Served'           as is_revenue_line,
        i.qty,
        i.unit_price,
        coalesce(m.modifier_price_per_unit, 0)                              as modifier_price_per_unit,
        i.qty * (i.unit_price + coalesce(m.modifier_price_per_unit, 0))     as gross_sales_amount,
        i.line_discount_amount,
        o.order_discount_amount,
        coalesce(p.funded_by, 'Merchant')                                   as order_discount_funded_by,
        mc.std_cost_per_unit + coalesce(m.modifier_cost_per_unit, 0)        as std_cost_per_unit
    from items as i
    inner join orders as o on o.order_id = i.order_id
    left join modifiers as m on m.order_item_id = i.order_item_id
    left join promotions as p on p.promo_code = o.promo_code
    left join item_costs as mc
        on mc.item_type = 'Menu Item'
       and mc.item_id = i.menu_item_id
       and mc.date_day = o.order_date
),

allocated as (
    select
        *,
        if(
            is_revenue_line,
            coalesce(order_discount_amount * safe_divide(
                gross_sales_amount,
                sum(if(is_revenue_line, gross_sales_amount, 0)) over (partition by order_id)
            ), 0),
            0
        ) as allocated_order_discount_amount
    from lines
),

final as (
    select
        *,
        if(is_revenue_line,
           line_discount_amount
           + if(order_discount_funded_by = 'Merchant', allocated_order_discount_amount, 0),
           0)                                                               as merchant_discount_amount,
        if(order_discount_funded_by = 'Platform', allocated_order_discount_amount, 0)
                                                                            as platform_funded_discount_amount
    from allocated
)

select
    order_item_id,
    order_id,
    order_date,
    ordered_at_local,
    outlet_id,
    channel_code,
    customer_id,
    menu_item_id,
    order_status,
    line_status,
    is_revenue_line,
    qty,
    unit_price,
    modifier_price_per_unit,
    gross_sales_amount,
    line_discount_amount,
    allocated_order_discount_amount,
    order_discount_funded_by,
    merchant_discount_amount,
    platform_funded_discount_amount,
    if(is_revenue_line, gross_sales_amount - merchant_discount_amount, 0)  as net_sales_amount,
    std_cost_per_unit,
    if(is_revenue_line, qty * std_cost_per_unit, 0)                        as cogs_std_amount
from final
