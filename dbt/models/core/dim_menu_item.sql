with items as (
    select * from {{ ref('stg_pos__menu_items') }}
),

categories as (
    select * from {{ ref('stg_pos__menu_categories') }}
),

prices as (
    select
        menu_item_id,
        channel_group,
        selling_price
    from {{ ref('stg_pos__menu_item_prices') }}
    where current_date('{{ var("local_tz") }}') >= effective_from
      and current_date('{{ var("local_tz") }}') < coalesce(effective_to, date '9999-12-31')
),

offline_price as (
    select menu_item_id, selling_price as current_offline_price
    from prices
    where channel_group = 'Offline'
),

online_price as (
    select menu_item_id, selling_price as current_online_price
    from prices
    where channel_group = 'Online Delivery'
),

latest_cost as (
    select
        item_id as menu_item_id,
        std_cost_per_unit as current_std_cost
    from {{ ref('int_item_std_cost_daily') }}
    where item_type = 'Menu Item'
      and date_day = current_date('{{ var("local_tz") }}')
)

select
    i.menu_item_id,
    i.menu_name,
    i.category_code,
    c.category_name,
    c.category_group,
    i.launched_date,
    i.discontinued_date,
    i.is_active,
    i.is_deleted,
    off.current_offline_price,
    onl.current_online_price,
    cost.current_std_cost,
    {{ safe_pct('cost.current_std_cost', 'off.current_offline_price') }} as current_food_cost_pct
from items as i
left join categories as c on c.category_code = i.category_code
left join offline_price as off on off.menu_item_id = i.menu_item_id
left join online_price as onl on onl.menu_item_id = i.menu_item_id
left join latest_cost as cost on cost.menu_item_id = i.menu_item_id
