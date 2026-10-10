-- State internal generator (BUKAN data bisnis). Tidak diingest ke BigQuery (daftar tabel dlt eksplisit di schema fnb saja).
CREATE SCHEMA IF NOT EXISTS sim;

CREATE TABLE IF NOT EXISTS sim.state (
    as_of_date DATE NOT NULL            -- hari terakhir yang sudah disimulasikan (inventori + penjualan)
);

CREATE TABLE IF NOT EXISTS sim.inventory_lots (
    outlet_id     VARCHAR(10)   NOT NULL,
    ingredient_id VARCHAR(20)   NOT NULL,
    received_date DATE          NOT NULL,
    qty           NUMERIC(16,4) NOT NULL,
    PRIMARY KEY (outlet_id, ingredient_id, received_date)
);

CREATE TABLE IF NOT EXISTS sim.inventory_ema (
    outlet_id     VARCHAR(10)   NOT NULL,
    ingredient_id VARCHAR(20)   NOT NULL,
    ema           NUMERIC(16,4) NOT NULL,
    PRIMARY KEY (outlet_id, ingredient_id)
);
