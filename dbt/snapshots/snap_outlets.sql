{% snapshot snap_outlets %}

{{
    config(
      unique_key='outlet_id',
      strategy='timestamp',
      updated_at='updated_at_utc',
      hard_deletes='invalidate'
    )
}}

select * from {{ ref('stg_pos__outlets') }}

{% endsnapshot %}
