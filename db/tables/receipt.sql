-- Money received. Ledger details are varchar(500) here but varchar(100) on
-- payment and journal; mirrored as declared.

CREATE TABLE IF NOT EXISTS receipt (
    "AUTOID"            integer       NOT NULL,  -- int(10) in MySQL
    "BillTypeId"        varchar(20)   NOT NULL,
    "ReceiptId"         varchar(31)   NOT NULL,
    "ToLedgerId"        varchar(20)   NOT NULL,
    "ToLedgerDetails"   varchar(500)  NOT NULL,
    "FromLedgerId"      varchar(20)   NOT NULL,
    "FromLedgerDetails" varchar(500)  NOT NULL,
    "VoucherDate"       timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "Amount"            numeric(24,8) NOT NULL,
    "Adjustment"        numeric(24,8) NOT NULL DEFAULT 0.00000000,
    "Status"            varchar(1)    NOT NULL,
    "CreatedByUser"     varchar(20)   NOT NULL,
    "CreatedTimeStamp"  timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "ReceiptNumber"     varchar(22)   NOT NULL,

    CONSTRAINT receipt_pkey PRIMARY KEY ("ReceiptId")
);

ALTER TABLE receipt OWNER TO firefly_app;
