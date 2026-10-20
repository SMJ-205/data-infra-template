{{
  config(
    materialized = 'incremental',
    incremental_strategy = 'insert_overwrite',
    partition_by = {'field': 'balance_date', 'data_type': 'date', 'granularity': 'month'},
    cluster_by = ['outlet_id', 'ingredient_id'],
    on_schema_change = 'fail',
    pre_hook = "{{ guard_incremental_relation(required_column='on_hand_qty') }}",
    tags = ['inventory', 'daily']
  )
}}
/*
  Grain   : 1 baris = balance_date x outlet_id x ingredient_id (bahan raw), spine padat (hari tanpa transaksi ikut)
  Saldo   : on_hand_qty = stock count terakhir + Σ pergerakan bersih sesudahnya (perpetual, di-reset tiap opname).
            Prep item yang dihitung saat opname dikonversi ke ekuivalen bahan raw (sama dengan mart_inventory_variance).
            Pada hari opname: count_variance_qty = counted_qty - (saldo kemarin + pergerakan hari itu) = susut/selisih.
  Incremental (tanpa menghitung ulang seluruh histori):
    1. Bangun ulang ringkasan pergerakan harian (murah, ~28 rb baris) lalu bandingkan dengan isi tabel.
    2. Tanggal pertama yang berbeda (hari baru, order telat, koreksi receipt) → rebuild_from = awal bulannya.
    3. Saldo dilanjutkan dari baris tabel tanggal rebuild_from - 1 (seed); 27 hari sebelumnya ikut dibaca
       sebagai konteks rata-rata pemakaian 28 hari. Partisi bulan >= rebuild_from ditimpa (insert_overwrite).
*/
with

ingredients as (
    select ingredient_id
    from {{ ref('stg_pos__ingredients') }}
    where not is_prep_item
),

outlets as (
    select outlet_id from {{ ref('dim_outlet') }}
),

movements as (
    select * from {{ ref('fct_inventory_movements_daily') }}
),

stock_counts as (
    select * from {{ ref('fct_stock_counts') }}
),

counts as (
    select
        c.outlet_id,
        c.count_date,
        coalesce(x.ingredient_id, c.ingredient_id)                          as ingredient_id,
        sum(c.counted_qty_base * coalesce(x.qty_per_unit, 1))               as counted_qty
    from stock_counts as c
    inner join {{ ref('stg_pos__ingredients') }} as i
        on c.ingredient_id = i.ingredient_id
    left join {{ ref('int_item_explosion_daily') }} as x
        on
            i.is_prep_item
            and c.count_date = x.date_day
            and c.ingredient_id = x.item_id
            and x.item_type = 'Prep Item'
    group by 1, 2, 3
),

end_date as (
    select greatest(
        (select max(m.movement_date) from movements as m),
        (select max(sc.count_date) from stock_counts as sc)
    ) as max_date
),

daily as (
    select
        d.date_day                                                          as balance_date,
        o.outlet_id,
        i.ingredient_id,
        coalesce(m.purchased_qty, 0)                                        as purchased_qty,
        coalesce(m.purchased_amount, 0)                                     as purchased_amount,
        coalesce(m.theoretical_sales_qty, 0)                                as theoretical_sales_qty,
        coalesce(m.waste_qty, 0)                                            as waste_qty,
        c.counted_qty
    from {{ ref('util_dates') }} as d
    cross join end_date as e
    cross join outlets as o
    cross join ingredients as i
    left join movements as m
        on
            d.date_day = m.movement_date
            and o.outlet_id = m.outlet_id
            and i.ingredient_id = m.ingredient_id
    left join counts as c
        on
            d.date_day = c.count_date
            and o.outlet_id = c.outlet_id
            and i.ingredient_id = c.ingredient_id
    where d.date_day between {{ var('start_date') }} and e.max_date
),

{% if is_incremental() %}
existing as (
    select
        balance_date,
        outlet_id,
        ingredient_id,
        purchased_qty,
        purchased_amount,
        theoretical_sales_qty,
        waste_qty,
        counted_qty,
        on_hand_qty,
        last_count_date
    from {{ this }}
),

first_changed as (
    select min(coalesce(d.balance_date, t.balance_date)) as first_changed_date
    from daily as d
    full outer join existing as t
        on
            d.balance_date = t.balance_date
            and d.outlet_id = t.outlet_id
            and d.ingredient_id = t.ingredient_id
    where
        d.balance_date is null
        or t.balance_date is null
        or d.purchased_qty is distinct from t.purchased_qty
        or d.purchased_amount is distinct from t.purchased_amount
        or d.theoretical_sales_qty is distinct from t.theoretical_sales_qty
        or d.waste_qty is distinct from t.waste_qty
        or d.counted_qty is distinct from t.counted_qty
),

rebuild as (
    -- tidak ada perubahan → tanggal jauh di depan → output kosong → tidak ada partisi yang ditimpa
    select date_trunc(coalesce(fc.first_changed_date, date '9999-12-31'), month) as rebuild_from
    from first_changed as fc
),

seed as (
    select
        t.outlet_id,
        t.ingredient_id,
        t.on_hand_qty       as seed_on_hand_qty,
        t.last_count_date   as seed_last_count_date
    from existing as t
    cross join rebuild as r
    where t.balance_date = date_sub(r.rebuild_from, interval 1 day)
),

usage_context as (
    select
        t.outlet_id,
        t.ingredient_id,
        t.balance_date,
        t.theoretical_sales_qty + t.waste_qty   as usage_qty
    from existing as t
    cross join rebuild as r
    where t.balance_date between date_sub(r.rebuild_from, interval 27 day) and date_sub(r.rebuild_from, interval 1 day)
),
{% endif %}

to_compute as (
    select
        d.*,
        d.purchased_qty - d.theoretical_sales_qty - d.waste_qty             as net_movement_qty,
        {% if is_incremental() %}
            s.seed_on_hand_qty,
            s.seed_last_count_date
        {% else %}
            cast(null as numeric)                                           as seed_on_hand_qty,
            cast(null as date)                                              as seed_last_count_date
        {% endif %}
    from daily as d
    {% if is_incremental() %}
        cross join rebuild as r
        left join seed as s
            on
                d.outlet_id = s.outlet_id
                and d.ingredient_id = s.ingredient_id
        where d.balance_date >= r.rebuild_from
    {% endif %}
),

segmented as (
    select
        *,
        -- segmen 0 = sebelum opname pertama di jendela ini (dilanjutkan dari seed); segmen n dimulai pada opname ke-n
        countif(counted_qty is not null) over (
            partition by outlet_id, ingredient_id order by balance_date
            rows between unbounded preceding and current row
        ) as count_segment
    from to_compute
),

balanced as (
    select
        *,
        if(
            count_segment = 0,
            coalesce(seed_on_hand_qty, 0) + sum(net_movement_qty) over seg,
            first_value(counted_qty) over seg + sum(net_movement_qty) over seg - first_value(net_movement_qty) over seg
        ) as on_hand_qty,
        if(
            count_segment = 0,
            seed_last_count_date,
            first_value(balance_date) over seg
        ) as last_count_date
    from segmented
    window seg as (
        partition by outlet_id, ingredient_id, count_segment order by balance_date
        rows between unbounded preceding and current row
    )
),

with_variance as (
    select
        *,
        if(
            counted_qty is null,
            null,
            counted_qty - (
                coalesce(
                    lag(on_hand_qty) over (partition by outlet_id, ingredient_id order by balance_date),
                    seed_on_hand_qty,
                    0
                ) + net_movement_qty
            )
        ) as count_variance_qty
    from balanced
),

usage_series as (
    select
        outlet_id,
        ingredient_id,
        balance_date,
        theoretical_sales_qty + waste_qty   as usage_qty
    from with_variance
    {% if is_incremental() %}
        union all
        select * from usage_context
    {% endif %}
),

usage_28d as (
    select
        outlet_id,
        ingredient_id,
        balance_date,
        avg(usage_qty) over (
            partition by outlet_id, ingredient_id order by balance_date
            rows between 27 preceding and current row
        ) as avg_daily_usage_28d
    from usage_series
),

costs as (
    select
        date_day,
        item_id             as ingredient_id,
        std_cost_per_unit
    from {{ ref('int_item_std_cost_daily') }}
    where item_type = 'Ingredient'
)

select
    b.balance_date,
    b.outlet_id,
    b.ingredient_id,
    b.purchased_qty,
    b.purchased_amount,
    b.theoretical_sales_qty,
    b.waste_qty,
    b.net_movement_qty,
    b.counted_qty,
    b.count_variance_qty,
    b.on_hand_qty,
    b.last_count_date,
    date_diff(b.balance_date, b.last_count_date, day)                       as days_since_last_count,
    u.avg_daily_usage_28d,
    safe_divide(b.on_hand_qty, u.avg_daily_usage_28d)                       as days_on_hand,
    b.on_hand_qty < 0                                                       as is_negative_on_hand,
    c.std_cost_per_unit,
    b.on_hand_qty * c.std_cost_per_unit                                     as on_hand_value
from with_variance as b
inner join usage_28d as u
    on
        b.outlet_id = u.outlet_id
        and b.ingredient_id = u.ingredient_id
        and b.balance_date = u.balance_date
left join costs as c
    on
        b.balance_date = c.date_day
        and b.ingredient_id = c.ingredient_id
