-- tests/assert_incremental_facts_in_sync.sql : jaring pengaman model incremental.
-- Setiap order / order item di staging harus ada di fact dengan versi terbaru (updated_at tidak lebih baru
-- dari source_updated_at_utc), dan fact tidak boleh berisi baris yang sudah tidak ada di source.
with stg_orders as (
    select order_id, updated_at_utc from {{ ref('stg_pos__orders') }}
),

stg_items as (
    select order_item_id, updated_at_utc from {{ ref('stg_pos__order_items') }}
),

fct_orders as (
    select order_id, source_updated_at_utc from {{ ref('fct_orders') }}
),

fct_lines as (
    select order_item_id, source_updated_at_utc from {{ ref('fct_order_lines') }}
)

select 'fct_orders' as model, coalesce(s.order_id, f.order_id) as id,
    case
        when f.order_id is null then 'missing in fact'
        when s.order_id is null then 'not in source'
        else 'stale'
    end as issue
from stg_orders as s
full outer join fct_orders as f on f.order_id = s.order_id
where f.order_id is null
   or s.order_id is null
   or s.updated_at_utc > f.source_updated_at_utc

union all

select 'fct_order_lines' as model, coalesce(s.order_item_id, f.order_item_id) as id,
    case
        when f.order_item_id is null then 'missing in fact'
        when s.order_item_id is null then 'not in source'
        else 'stale'
    end as issue
from stg_items as s
full outer join fct_lines as f on f.order_item_id = s.order_item_id
where f.order_item_id is null
   or s.order_item_id is null
   or s.updated_at_utc > f.source_updated_at_utc
