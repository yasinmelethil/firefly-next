-- Sales return headers. Same shape as salemaster minus RoundOffAmount, IsOut,
-- IdempotencyKey and PosMode.
--
-- SaleMasterId is varchar(47) while salemaster."SaleMasterId" is varchar(31) --
-- another deliberate width mismatch, mirrored as declared.

CREATE TABLE IF NOT EXISTS salereturn (
    "AUTOID"             integer       NOT NULL,
    "OrganizationCode"   varchar(4)    NOT NULL,
    "BillTypeId"         varchar(20)   NOT NULL,
    "SaleMasterId"       varchar(47)   NOT NULL,
    "LedgerId"           varchar(20)   NOT NULL,
    "PartyDetails"       varchar(500)  NOT NULL,
    "VoucherDate"        timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "Status"             varchar(1)    NOT NULL,  -- char(1) in MySQL
    "GrossAmount"        numeric(24,8) NOT NULL,
    "TaxId"              varchar(20)   NOT NULL,
    "TaxableAmount"      numeric(24,8) NOT NULL,
    "TaxPercentage"      numeric(5,2)  NOT NULL,
    "TaxAmount"          numeric(24,8) NOT NULL,
    "DiscountPercentage" numeric(5,2)  NOT NULL,
    "DiscountAmount"     numeric(24,8) NOT NULL,
    "TotalAmount"        numeric(24,8) NOT NULL,
    "PaidAmount"         numeric(24,8) NOT NULL,
    "CreatedByUser"      varchar(20)   NOT NULL,
    "CreatedTimeStamp"   timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "SaleReturnMasterId" varchar(31)   NOT NULL,
    "ReturnNumber"       varchar(32)   NOT NULL,
    "Description"        varchar(500)  NOT NULL,

    CONSTRAINT salereturn_pkey PRIMARY KEY ("SaleReturnMasterId")
);

ALTER TABLE salereturn OWNER TO firefly_app;
