{{
  config(
    materialized = 'table',
    partition_by = {'field': 'waste_date', 'data_type': 'date', 'granularity': 'month'},
    cluster_by = ['outlet_id', 'reason_code'],
    tags = ['inventory', 'daily']
  )
}}

with waste as (
    select * from {{ ref('stg_pos__waste_logs') }}
),

ingredients as (
    select ingredient_id, is_prep_item from {{ ref('stg_pos__ingredients') }}
),

typed as (
    select
        w.*,
        case
            when w.menu_item_id is not null then 'Menu Item'
            when i.is_prep_item then 'Prep Item'
            else 'Ingredient'
        end                                         as item_type,
        coalesce(w.menu_item_id, w.ingredient_id)   as item_id
    from waste as w
    left join ingredients as i on i.ingredient_id = w.ingredient_id
)

select
    t.waste_id,
    t.waste_date,
    t.logged_at_local,
    t.outlet_id,
    t.item_type,
    t.item_id,
    t.qty,
    t.reason_code,
    r.reason_name,
    r.controllability,
    t.recorded_by_employee_id,
    c.std_cost_per_unit                     as unit_std_cost,
    t.qty * c.std_cost_per_unit             as waste_cost_amount
from typed as t
left join {{ ref('stg_pos__waste_reasons') }} as r on r.reason_code = t.reason_code
left join {{ ref('int_item_std_cost_daily') }} as c
    on c.date_day = t.waste_date
   and c.item_type = t.item_type
   and c.item_id = t.item_id
