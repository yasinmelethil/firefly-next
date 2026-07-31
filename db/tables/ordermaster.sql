-- KOT / order headers. AUTOID is a plain integer here, NOT auto_increment --
-- the PHP allocates it. Only the *details* tables use auto_increment.

CREATE TABLE IF NOT EXISTS ordermaster (
    "AUTOID"           integer       NOT NULL,
    "OrganizationCode" varchar(4)    NOT NULL,
    "BillTypeId"       varchar(20)   NOT NULL,
    "OrderMasterId"    varchar(31)   NOT NULL,
    "OrderNumber"      varchar(32)   NOT NULL,
    "OrderDate"        timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "PartyDetails"     varchar(500)  NOT NULL,
    "LedgerId"         varchar(20)   NOT NULL,
    "NoofChair"        integer       NOT NULL,
    -- MySQL carries COMMENT 'K- KOT Generated , B - Billed' on this column.
    "Status"           varchar(1)    NOT NULL DEFAULT 'K',  -- char(1) in MySQL
    "CreatedByUser"    varchar(20)   NOT NULL,
    "CreatedTimeStamp" timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "TotalAmount"      numeric(24,8) NOT NULL,
    "Description"      varchar(500)  NOT NULL,
    "PosMode"          varchar(40),
    "RazorpayOrderId"  varchar(100),

    CONSTRAINT ordermaster_pkey PRIMARY KEY ("OrderMasterId")
);

CREATE INDEX IF NOT EXISTS ordermaster_idx_ordermaster_posmode   ON ordermaster ("PosMode");
CREATE INDEX IF NOT EXISTS ordermaster_idx_ordermaster_orderdate ON ordermaster ("OrderDate");

COMMENT ON COLUMN ordermaster."Status" IS 'K- KOT Generated , B - Billed';

ALTER TABLE ordermaster OWNER TO firefly_app;
