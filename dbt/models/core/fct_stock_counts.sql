{{
  config(
    materialized = 'table',
    partition_by = {'field': 'count_date', 'data_type': 'date', 'granularity': 'month'},
    cluster_by = ['outlet_id', 'ingredient_id'],
    tags = ['inventory', 'daily']
  )
}}

with lines as (
    select * from {{ ref('stg_pos__stock_count_lines') }}
),

headers as (
    select * from {{ ref('stg_pos__stock_counts') }}
)

select
    l.count_id,
    h.outlet_id,
    h.count_date,
    h.count_type,
    h.counted_by_employee_id,
    l.ingredient_id,
    l.counted_qty_base
from lines as l
inner join headers as h on h.count_id = l.count_id
