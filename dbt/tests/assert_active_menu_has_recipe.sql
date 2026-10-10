-- tests/assert_active_menu_has_recipe.sql : setiap menu yang terjual punya resep berlaku di tanggal itu
select l.order_item_id, l.menu_item_id, l.order_date
from {{ ref('fct_order_lines') }} as l
left join {{ ref('int_item_explosion_daily') }} as x
    on x.date_day = l.order_date and x.item_type = 'Menu Item' and x.item_id = l.menu_item_id
where l.is_revenue_line
  and x.item_id is null
