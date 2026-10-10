{{
  config(
    materialized = 'table',
    partition_by = {'field': 'movement_date', 'data_type': 'date', 'granularity': 'month'},
    cluster_by = ['outlet_id', 'ingredient_id'],
    tags = ['inventory', 'daily']
  )
}}

with explosion as (
    select * from {{ ref('int_item_explosion_daily') }}
),

sales_lines as (
    select order_item_id, order_date, outlet_id, menu_item_id, qty
    from {{ ref('fct_order_lines') }}
    where is_revenue_line
),

sales_usage as (
    select l.outlet_id, l.order_date as movement_date, x.ingredient_id, l.qty * x.qty_per_unit as qty
    from sales_lines as l
    inner join explosion as x
        on x.date_day = l.order_date and x.item_type = 'Menu Item' and x.item_id = l.menu_item_id

    union all

    select l.outlet_id, l.order_date, x.ingredient_id, l.qty * x.qty_per_unit
    from sales_lines as l
    inner join {{ ref('stg_pos__order_item_modifiers') }} as m on m.order_item_id = l.order_item_id
    inner join explosion as x
        on x.date_day = l.order_date and x.item_type = 'Modifier' and x.item_id = m.modifier_id
),

waste_usage as (
    select w.outlet_id, w.waste_date as movement_date, x.ingredient_id, w.qty * x.qty_per_unit as qty
    from {{ ref('fct_waste') }} as w
    inner join explosion as x
        on x.date_day = w.waste_date and x.item_type = w.item_type and x.item_id = w.item_id
),

purchases as (
    select outlet_id, received_date as movement_date, ingredient_id, qty_base_uom as qty, line_amount
    from {{ ref('fct_goods_receipt_lines') }}
),

unioned as (
    select outlet_id, movement_date, ingredient_id,
           qty as theoretical_sales_qty, cast(0 as numeric) as waste_qty,
           cast(0 as numeric) as purchased_qty, cast(0 as numeric) as purchased_amount
    from sales_usage
    union all
    select outlet_id, movement_date, ingredient_id, 0, qty, 0, 0
    from waste_usage
    union all
    select outlet_id, movement_date, ingredient_id, 0, 0, qty, line_amount
    from purchases
)

select
    outlet_id,
    movement_date,
    ingredient_id,
    sum(theoretical_sales_qty)  as theoretical_sales_qty,
    sum(waste_qty)              as waste_qty,
    sum(purchased_qty)          as purchased_qty,
    sum(purchased_amount)       as purchased_amount
from unioned
group by 1, 2, 3
