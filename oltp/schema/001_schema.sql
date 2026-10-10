-- Sumber: fnb_data_platform_implementation_plan_v2.md §3.3 (PostgreSQL 15+; diuji di Neon).
-- Jalankan lewat: python oltp/generator/generate.py apply-schema

-- =====================================================================
-- F&B OLTP v2 — schema fnb
-- Konvensi: PK natural (VARCHAR) untuk master, IDENTITY untuk baris detail,
-- TIMESTAMPTZ untuk semua waktu, uang NUMERIC, kuantitas bahan dalam base UOM.
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS fnb;
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- untuk exclusion constraint periode

CREATE OR REPLACE FUNCTION fnb.set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================ ORGANISASI =============================
CREATE TABLE fnb.outlets (
    outlet_id       VARCHAR(10)  PRIMARY KEY,
    outlet_name     VARCHAR(100) NOT NULL,
    city            VARCHAR(50)  NOT NULL,
    outlet_type     VARCHAR(20)  NOT NULL CHECK (outlet_type IN ('Flagship', 'Kiosk', 'Cloud Kitchen')),
    seat_capacity   INT          NOT NULL DEFAULT 0 CHECK (seat_capacity >= 0),
    opened_date     DATE         NOT NULL,
    closed_date     DATE         CHECK (closed_date IS NULL OR closed_date >= opened_date),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.employees (
    employee_id     VARCHAR(10)  PRIMARY KEY,
    outlet_id       VARCHAR(10)  NOT NULL REFERENCES fnb.outlets (outlet_id),
    full_name       VARCHAR(100) NOT NULL,                       -- PII
    phone_number    VARCHAR(20),                                 -- PII
    job_role        VARCHAR(30)  NOT NULL CHECK (job_role IN ('Barista', 'Cook', 'Cashier', 'Supervisor', 'Outlet Manager')),
    hired_date      DATE         NOT NULL,
    terminated_date DATE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.customers (
    customer_id     VARCHAR(20)  PRIMARY KEY,
    full_name       VARCHAR(100),                                -- PII
    phone_number    VARCHAR(20)  UNIQUE,                         -- PII
    email           VARCHAR(100),                                -- PII
    birth_date      DATE,                                        -- PII
    registered_at   TIMESTAMPTZ  NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);

-- ========================= KANAL & PROMO =============================
CREATE TABLE fnb.sales_channels (
    channel_code    VARCHAR(20)  PRIMARY KEY,                    -- DINE_IN, TAKEAWAY, GOFOOD, GRABFOOD, SHOPEEFOOD
    channel_name    VARCHAR(50)  NOT NULL,
    channel_group   VARCHAR(20)  NOT NULL CHECK (channel_group IN ('Offline', 'Online Delivery')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.channel_commission_rates (
    channel_code    VARCHAR(20)  NOT NULL REFERENCES fnb.sales_channels (channel_code),
    effective_from  DATE         NOT NULL,
    effective_to    DATE,                                        -- eksklusif; NULL = masih berlaku
    commission_pct  NUMERIC(5,2) NOT NULL CHECK (commission_pct BETWEEN 0 AND 100),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_code, effective_from),
    CHECK (effective_to IS NULL OR effective_to > effective_from),
    EXCLUDE USING gist (channel_code WITH =, daterange(effective_from, effective_to) WITH &&)
);

CREATE TABLE fnb.promotions (
    promo_code      VARCHAR(30)  PRIMARY KEY,
    promo_name      VARCHAR(100) NOT NULL,
    promo_type      VARCHAR(20)  NOT NULL CHECK (promo_type IN ('PERCENT', 'FIXED')),
    promo_value     NUMERIC(12,2) NOT NULL CHECK (promo_value > 0),
    funded_by       VARCHAR(20)  NOT NULL CHECK (funded_by IN ('Merchant', 'Platform')),
    start_date      DATE         NOT NULL,
    end_date        DATE         NOT NULL CHECK (end_date >= start_date),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- =============================== MENU ================================
CREATE TABLE fnb.menu_categories (
    category_code   VARCHAR(20)  PRIMARY KEY,
    category_name   VARCHAR(50)  NOT NULL,
    category_group  VARCHAR(20)  NOT NULL CHECK (category_group IN ('Beverage', 'Food', 'Bakery')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.menu_items (
    menu_item_id      VARCHAR(20)  PRIMARY KEY,
    menu_name         VARCHAR(100) NOT NULL,
    category_code     VARCHAR(20)  NOT NULL REFERENCES fnb.menu_categories (category_code),
    launched_date     DATE         NOT NULL,
    discontinued_date DATE,
    is_active         BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ
);

CREATE TABLE fnb.menu_item_prices (
    menu_item_id    VARCHAR(20)  NOT NULL REFERENCES fnb.menu_items (menu_item_id),
    channel_group   VARCHAR(20)  NOT NULL CHECK (channel_group IN ('Offline', 'Online Delivery')),
    effective_from  DATE         NOT NULL,
    effective_to    DATE,
    selling_price   NUMERIC(12,2) NOT NULL CHECK (selling_price > 0),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (menu_item_id, channel_group, effective_from),
    CHECK (effective_to IS NULL OR effective_to > effective_from),
    EXCLUDE USING gist (menu_item_id WITH =, channel_group WITH =, daterange(effective_from, effective_to) WITH &&)
);

-- ========================== BAHAN & RESEP ============================
CREATE TABLE fnb.ingredients (
    ingredient_id       VARCHAR(20)  PRIMARY KEY,
    ingredient_name     VARCHAR(100) NOT NULL,
    ingredient_category VARCHAR(20)  NOT NULL CHECK (ingredient_category IN
                        ('Coffee', 'Dairy', 'Syrup', 'Tea', 'Bakery', 'Protein', 'Produce', 'Dry Goods', 'Packaging', 'Prep')),
    base_uom            VARCHAR(5)   NOT NULL CHECK (base_uom IN ('g', 'ml', 'pcs')),
    is_prep_item        BOOLEAN      NOT NULL DEFAULT FALSE,     -- TRUE = setengah jadi, dibuat dari resep prep
    is_perishable       BOOLEAN      NOT NULL DEFAULT FALSE,
    shelf_life_days     INT          CHECK (shelf_life_days > 0),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ
);

CREATE TABLE fnb.ingredient_standard_costs (
    ingredient_id   VARCHAR(20)  NOT NULL REFERENCES fnb.ingredients (ingredient_id),
    effective_from  DATE         NOT NULL,
    effective_to    DATE,
    standard_cost_per_base_uom NUMERIC(14,4) NOT NULL CHECK (standard_cost_per_base_uom >= 0),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (ingredient_id, effective_from),
    CHECK (effective_to IS NULL OR effective_to > effective_from),
    EXCLUDE USING gist (ingredient_id WITH =, daterange(effective_from, effective_to) WITH &&)
);

CREATE TABLE fnb.suppliers (
    supplier_id       VARCHAR(10)  PRIMARY KEY,
    supplier_name     VARCHAR(100) NOT NULL,
    city              VARCHAR(50),
    payment_term_days INT          NOT NULL DEFAULT 0 CHECK (payment_term_days >= 0),
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ
);

-- Resep berversi untuk menu ATAU prep item (tepat salah satu)
CREATE TABLE fnb.recipes (
    recipe_id           VARCHAR(30)  PRIMARY KEY,                -- mis. R_MNU_LATTE_V2
    menu_item_id        VARCHAR(20)  REFERENCES fnb.menu_items (menu_item_id),
    prep_ingredient_id  VARCHAR(20)  REFERENCES fnb.ingredients (ingredient_id),
    version_no          INT          NOT NULL CHECK (version_no > 0),
    yield_qty           NUMERIC(12,4) NOT NULL DEFAULT 1 CHECK (yield_qty > 0), -- menu: 1 porsi; prep: hasil batch dlm base_uom
    effective_from      DATE         NOT NULL,
    effective_to        DATE,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(menu_item_id, prep_ingredient_id) = 1),
    CHECK (effective_to IS NULL OR effective_to > effective_from),
    EXCLUDE USING gist ((COALESCE(menu_item_id, prep_ingredient_id)) WITH =,
                        daterange(effective_from, effective_to) WITH &&)
);

CREATE TABLE fnb.recipe_lines (
    recipe_id       VARCHAR(30)  NOT NULL REFERENCES fnb.recipes (recipe_id),
    ingredient_id   VARCHAR(20)  NOT NULL REFERENCES fnb.ingredients (ingredient_id),  -- raw atau prep
    qty_per_yield   NUMERIC(12,4) NOT NULL CHECK (qty_per_yield > 0),                  -- qty bersih per yield_qty
    loss_pct        NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (loss_pct >= 0 AND loss_pct < 100), -- trimming/evaporasi
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (recipe_id, ingredient_id)
);

CREATE TABLE fnb.modifiers (
    modifier_id     VARCHAR(20)  PRIMARY KEY,                    -- MOD_EXTRA_SHOT, MOD_OAT, MOD_LARGE
    modifier_name   VARCHAR(50)  NOT NULL,
    modifier_group  VARCHAR(20)  NOT NULL CHECK (modifier_group IN ('Size', 'Milk', 'Sugar', 'Add-on')),
    price_delta     NUMERIC(12,2) NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);

-- qty_delta boleh negatif (ganti susu: -150 ml fresh milk, +150 ml oat milk)
CREATE TABLE fnb.modifier_lines (
    modifier_id     VARCHAR(20)  NOT NULL REFERENCES fnb.modifiers (modifier_id),
    ingredient_id   VARCHAR(20)  NOT NULL REFERENCES fnb.ingredients (ingredient_id),
    qty_delta       NUMERIC(12,4) NOT NULL CHECK (qty_delta <> 0),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (modifier_id, ingredient_id)
);

-- ============================ PENJUALAN ==============================
CREATE TABLE fnb.orders (
    order_id              VARCHAR(30)  PRIMARY KEY,              -- {outlet}-{yyyymmdd}-{seq}
    outlet_id             VARCHAR(10)  NOT NULL REFERENCES fnb.outlets (outlet_id),
    channel_code          VARCHAR(20)  NOT NULL REFERENCES fnb.sales_channels (channel_code),
    customer_id           VARCHAR(20)  REFERENCES fnb.customers (customer_id),
    cashier_id            VARCHAR(10)  REFERENCES fnb.employees (employee_id),
    promo_code            VARCHAR(30)  REFERENCES fnb.promotions (promo_code),
    external_order_ref    VARCHAR(50),                           -- id GoFood/GrabFood
    ordered_at            TIMESTAMPTZ  NOT NULL,
    order_status          VARCHAR(20)  NOT NULL CHECK (order_status IN ('Open', 'Completed', 'Cancelled')),
    cancelled_at          TIMESTAMPTZ,
    cancel_reason         VARCHAR(100),
    guest_count           INT          CHECK (guest_count > 0),
    subtotal_amount       NUMERIC(14,2) NOT NULL CHECK (subtotal_amount >= 0),  -- Σ qty × (unit_price + modifier)
    item_discount_amount  NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (item_discount_amount >= 0),
    order_discount_amount NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (order_discount_amount >= 0),
    service_charge_amount NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (service_charge_amount >= 0),
    tax_amount            NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),     -- PB1
    total_amount          NUMERIC(14,2) NOT NULL CHECK (total_amount >= 0),
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (total_amount = subtotal_amount - item_discount_amount - order_discount_amount
                          + service_charge_amount + tax_amount),
    CHECK ((order_status = 'Cancelled') = (cancelled_at IS NOT NULL))
);

CREATE TABLE fnb.order_items (
    order_item_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id              VARCHAR(30)  NOT NULL REFERENCES fnb.orders (order_id),
    menu_item_id          VARCHAR(20)  NOT NULL REFERENCES fnb.menu_items (menu_item_id),
    qty                   INT          NOT NULL CHECK (qty > 0),
    unit_price            NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),  -- salinan harga saat transaksi
    line_discount_amount  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (line_discount_amount >= 0),
    line_status           VARCHAR(10)  NOT NULL DEFAULT 'Served' CHECK (line_status IN ('Served', 'Void')),
    void_reason           VARCHAR(100),
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.order_item_modifiers (
    order_item_id   BIGINT       NOT NULL REFERENCES fnb.order_items (order_item_id),
    modifier_id     VARCHAR(20)  NOT NULL REFERENCES fnb.modifiers (modifier_id),
    price_delta     NUMERIC(12,2) NOT NULL DEFAULT 0,            -- salinan harga modifier per unit
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (order_item_id, modifier_id)
);

CREATE TABLE fnb.payments (
    payment_id      VARCHAR(30)  PRIMARY KEY,
    order_id        VARCHAR(30)  NOT NULL REFERENCES fnb.orders (order_id),
    payment_method  VARCHAR(30)  NOT NULL CHECK (payment_method IN
                    ('Cash', 'QRIS', 'Debit Card', 'Credit Card', 'E-Wallet', 'Platform Settlement')),
    amount          NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    mdr_fee_amount  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (mdr_fee_amount >= 0),
    paid_at         TIMESTAMPTZ  NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.refunds (
    refund_id       VARCHAR(30)  PRIMARY KEY,
    order_id        VARCHAR(30)  NOT NULL REFERENCES fnb.orders (order_id),
    order_item_id   BIGINT       REFERENCES fnb.order_items (order_item_id),   -- NULL = refund level order
    refund_amount   NUMERIC(14,2) NOT NULL CHECK (refund_amount > 0),
    refund_reason   VARCHAR(100) NOT NULL,
    approved_by     VARCHAR(10)  REFERENCES fnb.employees (employee_id),
    refunded_at     TIMESTAMPTZ  NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ============================ INVENTORI ==============================
CREATE TABLE fnb.goods_receipts (
    gr_id           VARCHAR(30)  PRIMARY KEY,
    outlet_id       VARCHAR(10)  NOT NULL REFERENCES fnb.outlets (outlet_id),
    supplier_id     VARCHAR(10)  NOT NULL REFERENCES fnb.suppliers (supplier_id),
    invoice_no      VARCHAR(50),
    received_at     TIMESTAMPTZ  NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.goods_receipt_lines (
    gr_line_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gr_id           VARCHAR(30)  NOT NULL REFERENCES fnb.goods_receipts (gr_id),
    ingredient_id   VARCHAR(20)  NOT NULL REFERENCES fnb.ingredients (ingredient_id),
    purchase_qty    NUMERIC(12,3) NOT NULL CHECK (purchase_qty > 0),
    purchase_uom    VARCHAR(10)  NOT NULL,                       -- kg, liter, pack, karton
    qty_base_uom    NUMERIC(14,3) NOT NULL CHECK (qty_base_uom > 0), -- sudah dikonversi ke base_uom
    line_amount     NUMERIC(14,2) NOT NULL CHECK (line_amount >= 0),
    expiry_date     DATE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.stock_counts (
    count_id        VARCHAR(30)  PRIMARY KEY,
    outlet_id       VARCHAR(10)  NOT NULL REFERENCES fnb.outlets (outlet_id),
    count_date      DATE         NOT NULL,                       -- dihitung saat tutup toko
    count_type      VARCHAR(20)  NOT NULL CHECK (count_type IN ('Opening', 'Weekly', 'Month End')),
    counted_by      VARCHAR(10)  REFERENCES fnb.employees (employee_id),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (outlet_id, count_date)
);

CREATE TABLE fnb.stock_count_lines (
    count_id        VARCHAR(30)  NOT NULL REFERENCES fnb.stock_counts (count_id),
    ingredient_id   VARCHAR(20)  NOT NULL REFERENCES fnb.ingredients (ingredient_id),
    counted_qty_base NUMERIC(14,3) NOT NULL CHECK (counted_qty_base >= 0),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (count_id, ingredient_id)
);

CREATE TABLE fnb.waste_reasons (
    reason_code     VARCHAR(20)  PRIMARY KEY,                    -- EXPIRED, PREP_SPOIL, DROPPED, QC_REJECT, CUST_RETURN
    reason_name     VARCHAR(50)  NOT NULL,
    controllability VARCHAR(20)  NOT NULL CHECK (controllability IN ('Controllable', 'Uncontrollable')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Waste bisa berupa bahan raw, prep item (keduanya via ingredient_id), atau produk jadi (menu_item_id)
CREATE TABLE fnb.waste_logs (
    waste_id        VARCHAR(30)  PRIMARY KEY,
    outlet_id       VARCHAR(10)  NOT NULL REFERENCES fnb.outlets (outlet_id),
    logged_at       TIMESTAMPTZ  NOT NULL,
    ingredient_id   VARCHAR(20)  REFERENCES fnb.ingredients (ingredient_id),
    menu_item_id    VARCHAR(20)  REFERENCES fnb.menu_items (menu_item_id),
    qty             NUMERIC(12,3) NOT NULL CHECK (qty > 0),      -- base_uom (bahan/prep) atau porsi (menu)
    reason_code     VARCHAR(20)  NOT NULL REFERENCES fnb.waste_reasons (reason_code),
    recorded_by     VARCHAR(10)  NOT NULL REFERENCES fnb.employees (employee_id),
    notes           VARCHAR(200),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(ingredient_id, menu_item_id) = 1)
);

-- ============================ KEUANGAN ===============================
CREATE TABLE fnb.expense_categories (
    category_code   VARCHAR(20)  PRIMARY KEY,
    category_name   VARCHAR(50)  NOT NULL,
    pnl_line        VARCHAR(30)  NOT NULL CHECK (pnl_line IN
                    ('Labor', 'Occupancy', 'Utilities', 'Marketing', 'Repairs & Maintenance', 'G&A')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE fnb.operating_expenses (
    expense_id      VARCHAR(30)  PRIMARY KEY,
    outlet_id       VARCHAR(10)  REFERENCES fnb.outlets (outlet_id),   -- NULL = biaya HQ/bersama (dialokasikan di dbt)
    period_month    DATE         NOT NULL CHECK (period_month = date_trunc('month', period_month)::date),
    category_code   VARCHAR(20)  NOT NULL REFERENCES fnb.expense_categories (category_code),
    amount          NUMERIC(14,2) NOT NULL CHECK (amount >= 0),
    description     VARCHAR(200),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE NULLS NOT DISTINCT (outlet_id, period_month, category_code)
);

-- ============================== INDEX ================================
CREATE INDEX ON fnb.orders (ordered_at);
CREATE INDEX ON fnb.orders (outlet_id, ordered_at);
CREATE INDEX ON fnb.order_items (order_id);
CREATE INDEX ON fnb.payments (order_id);
CREATE INDEX ON fnb.refunds (order_id);
CREATE INDEX ON fnb.goods_receipt_lines (gr_id);
CREATE INDEX ON fnb.waste_logs (outlet_id, logged_at);

-- Trigger updated_at + index updated_at (kursor incremental) untuk setiap tabel
DO $$
DECLARE t text;
BEGIN
    FOR t IN
        SELECT table_name FROM information_schema.columns
        WHERE table_schema = 'fnb' AND column_name = 'updated_at'
    LOOP
        EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON fnb.%I
                        FOR EACH ROW EXECUTE FUNCTION fnb.set_updated_at()', t, t);
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_updated_at ON fnb.%I (updated_at)', t, t);
    END LOOP;
END $$;
