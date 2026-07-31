-- Purchase order headers.
--
-- The primary key is spelled `ordermasterId` -- lowercase 'o', capital 'I'.
-- Every sibling table uses OrderMasterId. MySQL cannot tell the difference;
-- PostgreSQL can, so this is mirrored exactly as declared and any query against
-- it must use this spelling.

CREATE TABLE IF NOT EXISTS purchaseordermaster (
    "AUTOID"           integer       NOT NULL,
    "OrganizationCode" varchar(4)    NOT NULL,
    "BillTypeId"       varchar(20)   NOT NULL,
    "ordermasterId"    varchar(31)   NOT NULL,
    "OrderNumber"      varchar(32)   NOT NULL,
    "OrderDate"        timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "PartyDetails"     varchar(500)  NOT NULL,
    "LedgerId"         varchar(20)   NOT NULL,
    "Status"           varchar(1)    NOT NULL DEFAULT 'K',  -- char(1) in MySQL
    "CreatedByUser"    varchar(20)   NOT NULL,
    "CreatedTimeStamp" timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "TotalAmount"      numeric(24,8) NOT NULL,
    "Description"      varchar(500)  NOT NULL,

    CONSTRAINT purchaseordermaster_pkey PRIMARY KEY ("ordermasterId")
);

COMMENT ON COLUMN purchaseordermaster."Status" IS 'K- KOT Generated , B - Billed';

ALTER TABLE purchaseordermaster OWNER TO firefly_app;
