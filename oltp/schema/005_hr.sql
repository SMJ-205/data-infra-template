-- Modul HR & Talent: data karyawan sensitif (PII), kompensasi, absensi, payroll, review kinerja, rekrutmen.
-- Idempoten (dijalankan oleh init-master). Data diisi oleh generator (hr.py), bukan seed SQL.
-- Kolom bertanda PII / SENSITIF hanya boleh keluar dari raw ke dataset BigQuery hr_restricted.

ALTER TABLE fnb.employees
    ADD COLUMN IF NOT EXISTS national_id        VARCHAR(16),                    -- PII (NIK)
    ADD COLUMN IF NOT EXISTS birth_date         DATE,                           -- PII
    ADD COLUMN IF NOT EXISTS gender             CHAR(1) CHECK (gender IN ('F', 'M')),
    ADD COLUMN IF NOT EXISTS email              VARCHAR(100),                   -- PII
    ADD COLUMN IF NOT EXISTS employment_type    VARCHAR(10) NOT NULL DEFAULT 'Full-time'
                                                CHECK (employment_type IN ('Full-time', 'Part-time')),
    ADD COLUMN IF NOT EXISTS hire_source        VARCHAR(20),
    ADD COLUMN IF NOT EXISTS termination_reason VARCHAR(20)
                                                CHECK (termination_reason IN ('Resign', 'Contract End', 'Dismissed'));

-- Riwayat kompensasi berversi (SENSITIF)
CREATE TABLE IF NOT EXISTS fnb.employee_compensation (
    employee_id         VARCHAR(10)   NOT NULL REFERENCES fnb.employees (employee_id),
    effective_from      DATE          NOT NULL,
    effective_to        DATE,
    base_salary_monthly NUMERIC(14,2) CHECK (base_salary_monthly > 0),     -- Full-time
    hourly_rate         NUMERIC(12,2) CHECK (hourly_rate > 0),             -- Part-time
    allowance_monthly   NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (allowance_monthly >= 0),
    change_reason       VARCHAR(30)   NOT NULL,                             -- Initial, Annual Review
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (employee_id, effective_from),
    CHECK (num_nonnulls(base_salary_monthly, hourly_rate) = 1),
    CHECK (effective_to IS NULL OR effective_to > effective_from)
);

-- Absensi per shift terjadwal (hari libur mingguan tidak dicatat)
CREATE TABLE IF NOT EXISTS fnb.attendance (
    attendance_id       VARCHAR(24)   PRIMARY KEY,                          -- {employee}-{yyyymmdd}
    employee_id         VARCHAR(10)   NOT NULL REFERENCES fnb.employees (employee_id),
    outlet_id           VARCHAR(10)   NOT NULL REFERENCES fnb.outlets (outlet_id),
    work_date           DATE          NOT NULL,
    status              VARCHAR(10)   NOT NULL CHECK (status IN ('Present', 'Late', 'Absent', 'Leave')),
    scheduled_hours     NUMERIC(4,1)  NOT NULL CHECK (scheduled_hours > 0),
    clock_in_at         TIMESTAMPTZ,
    clock_out_at        TIMESTAMPTZ,
    late_minutes        INT           NOT NULL DEFAULT 0 CHECK (late_minutes >= 0),
    worked_hours        NUMERIC(4,1)  NOT NULL DEFAULT 0 CHECK (worked_hours >= 0),
    overtime_hours      NUMERIC(4,1)  NOT NULL DEFAULT 0 CHECK (overtime_hours >= 0),
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CHECK (clock_out_at IS NULL OR clock_out_at > clock_in_at)
);

-- Payroll bulanan (SENSITIF)
CREATE TABLE IF NOT EXISTS fnb.payroll (
    payroll_id          VARCHAR(24)   PRIMARY KEY,                          -- PR-{employee}-{yyyymm}
    employee_id         VARCHAR(10)   NOT NULL REFERENCES fnb.employees (employee_id),
    outlet_id           VARCHAR(10)   NOT NULL REFERENCES fnb.outlets (outlet_id),
    period_month        DATE          NOT NULL CHECK (extract(day from period_month) = 1),
    base_pay            NUMERIC(14,2) NOT NULL CHECK (base_pay >= 0),
    allowance_pay       NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (allowance_pay >= 0),
    overtime_pay        NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (overtime_pay >= 0),
    absence_deduction   NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (absence_deduction >= 0),
    bpjs_deduction      NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (bpjs_deduction >= 0),
    net_pay             NUMERIC(14,2) NOT NULL,
    paid_at             TIMESTAMPTZ   NOT NULL,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    UNIQUE (employee_id, period_month),
    CHECK (net_pay = base_pay + allowance_pay + overtime_pay - absence_deduction - bpjs_deduction)
);

CREATE TABLE IF NOT EXISTS fnb.performance_reviews (
    review_id           VARCHAR(24)   PRIMARY KEY,                          -- RV-{period}-{employee}
    employee_id         VARCHAR(10)   NOT NULL REFERENCES fnb.employees (employee_id),
    review_period       VARCHAR(7)    NOT NULL,                             -- 2025-H2, 2026-H1
    reviewer_id         VARCHAR(10)   REFERENCES fnb.employees (employee_id),  -- NULL = HQ
    rating              SMALLINT      NOT NULL CHECK (rating BETWEEN 1 AND 5),
    goals_met_pct       NUMERIC(5,1)  NOT NULL CHECK (goals_met_pct BETWEEN 0 AND 100),
    reviewed_at         TIMESTAMPTZ   NOT NULL,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    UNIQUE (employee_id, review_period)
);

CREATE TABLE IF NOT EXISTS fnb.job_requisitions (
    requisition_id          VARCHAR(30)  PRIMARY KEY,                       -- REQ-{outlet}-{yyyymmdd}-{n}
    outlet_id               VARCHAR(10)  NOT NULL REFERENCES fnb.outlets (outlet_id),
    job_role                VARCHAR(30)  NOT NULL,
    employment_type         VARCHAR(10)  NOT NULL,
    reason                  VARCHAR(20)  NOT NULL CHECK (reason IN ('Replacement', 'New Headcount')),
    replaces_employee_id    VARCHAR(10)  REFERENCES fnb.employees (employee_id),
    opened_date             DATE         NOT NULL,
    filled_date             DATE,                                           -- tanggal mulai kerja karyawan baru
    filled_by_employee_id   VARCHAR(10)  REFERENCES fnb.employees (employee_id),
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS fnb.job_applications (
    application_id      VARCHAR(36)  PRIMARY KEY,                           -- {requisition}-A{nn}
    requisition_id      VARCHAR(30)  NOT NULL REFERENCES fnb.job_requisitions (requisition_id),
    candidate_name      VARCHAR(100) NOT NULL,                              -- PII
    candidate_phone     VARCHAR(20)  NOT NULL,                              -- PII
    source              VARCHAR(20)  NOT NULL CHECK (source IN ('Referral', 'JobStreet', 'Instagram', 'Walk-in')),
    applied_at          TIMESTAMPTZ  NOT NULL,
    screened_at         TIMESTAMPTZ,
    interviewed_at      TIMESTAMPTZ,
    offered_at          TIMESTAMPTZ,
    decided_at          TIMESTAMPTZ,
    status              VARCHAR(20)  NOT NULL
                        CHECK (status IN ('In Process', 'Rejected', 'Withdrawn', 'Offer Declined', 'Hired')),
    hired_employee_id   VARCHAR(10)  REFERENCES fnb.employees (employee_id),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now()
);
