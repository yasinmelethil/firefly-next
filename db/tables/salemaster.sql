-- Sales invoice headers. The most-migrated table in the schema: IdempotencyKey,
-- RoundOffAmount, IsOut and PosMode were all added after the REST-APP baseline
-- was captured.
--
-- OrderMasterId is varchar(480) while ordermaster."OrderMasterId" is
-- varchar(31). That is not a mistake to tidy up: the column holds a
-- COMMA-JOINED LIST of order ids when several orders are merged onto one bill
-- (480 is roughly 15 x 32). It must never be given a foreign key or narrowed --
-- the live rows all happen to hold a single id, so a naive varchar(31) + FK
-- passes on today's data and fails on the first merged bill.

CREATE TABLE IF NOT EXISTS salemaster (
    "AUTOID"             integer       NOT NULL,
    "OrganizationCode"   varchar(4)    NOT NULL,
    "BillTypeId"         varchar(20)   NOT NULL,
    "OrderMasterId"      varchar(480),
    "LedgerId"           varchar(20)   NOT NULL,
    "PartyDetails"       varchar(500)  NOT NULL,
    "VoucherDate"        timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "Status"             varchar(1)    NOT NULL,  -- char(1) in MySQL
    "IsOut"              smallint      NOT NULL DEFAULT 0,
    "GrossAmount"        numeric(24,8) NOT NULL,
    "TaxId"              varchar(20)   NOT NULL,
    "TaxableAmount"      numeric(24,8) NOT NULL,
    "TaxPercentage"      numeric(5,2)  NOT NULL,
    "TaxAmount"          numeric(24,8) NOT NULL,
    "DiscountPercentage" numeric(5,2)  NOT NULL,
    "DiscountAmount"     numeric(24,8) NOT NULL,
    -- Sign convention flipped to the ERP's by REST-APP migration 23.
    "RoundOffAmount"     numeric(24,8) NOT NULL,
    "TotalAmount"        numeric(24,8) NOT NULL,
    "PaidAmount"         numeric(24,8) NOT NULL,
    "CreatedByUser"      varchar(20)   NOT NULL,
    "CreatedTimeStamp"   timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "SaleMasterId"       varchar(31)   NOT NULL,
    "VoucherNumber"      varchar(32)   NOT NULL,
    "Description"        varchar(500)  NOT NULL,
    "IdempotencyKey"     varchar(64),
    "PosMode"            varchar(40),

    CONSTRAINT salemaster_pkey PRIMARY KEY ("SaleMasterId")
);

-- Nullable and unique: both engines permit unlimited NULLs here, so invoices
-- written without an idempotency key are unaffected.
CREATE UNIQUE INDEX IF NOT EXISTS salemaster_uniq_salemaster_idempotency ON salemaster ("IdempotencyKey");

CREATE INDEX IF NOT EXISTS salemaster_idx_salemaster_posmode     ON salemaster ("PosMode");
CREATE INDEX IF NOT EXISTS salemaster_idx_salemaster_isout       ON salemaster ("IsOut");
CREATE INDEX IF NOT EXISTS salemaster_idx_salemaster_voucherdate ON salemaster ("VoucherDate");

ALTER TABLE salemaster OWNER TO firefly_app;
