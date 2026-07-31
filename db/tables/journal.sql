-- Journal vouchers. Identical in shape to payment, with JournalNumber.

CREATE TABLE IF NOT EXISTS journal (
    "AUTOID"            integer       NOT NULL,
    "JournalId"         varchar(31)   NOT NULL,
    "FromLedgerId"      varchar(20)   NOT NULL,
    "FromLedgerDetails" varchar(100)  NOT NULL,
    "ToLedgerId"        varchar(20)   NOT NULL,
    "ToLedgerDetails"   varchar(100)  NOT NULL,
    "BillTypeId"        varchar(20)   NOT NULL,
    "Amount"            numeric(24,8) NOT NULL,
    "JournalNumber"     varchar(22)   NOT NULL,
    "VoucherDate"       timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "Status"            varchar(1)    NOT NULL,
    "CreatedByUser"     varchar(20)   NOT NULL,
    "CreatedTimeStamp"  timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT journal_pkey PRIMARY KEY ("JournalId")
);

ALTER TABLE journal OWNER TO firefly_app;
