-- tests/assert_completed_orders_fully_paid.sql
select order_id, total_amount, paid_amount
from {{ ref('fct_orders') }}
where order_status = 'Completed'
  and abs(total_amount - paid_amount) > 1
