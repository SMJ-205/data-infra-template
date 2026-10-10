{% snapshot snap_outlets %}

{{
    config(
      target_schema='snapshots',
      unique_key='outlet_id',
      strategy='timestamp',
      updated_at='updated_at_utc',
      invalidate_hard_deletes=True
    )
}}

select * from {{ ref('stg_pos__outlets') }}

{% endsnapshot %}
