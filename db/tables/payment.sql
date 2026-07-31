-- Money paid out.

CREATE TABLE IF NOT EXISTS payment (
    "AUTOID"            integer       NOT NULL,
    "PaymentId"         varchar(31)   NOT NULL,
    "FromLedgerId"      varchar(20)   NOT NULL,
    "FromLedgerDetails" varchar(100)  NOT NULL,
    "ToLedgerId"        varchar(20)   NOT NULL,
    "ToLedgerDetails"   varchar(100)  NOT NULL,
    "BillTypeId"        varchar(20)   NOT NULL,
    "Amount"            numeric(24,8) NOT NULL,
    "PaymentNumber"     varchar(22)   NOT NULL,
    "VoucherDate"       timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "Status"            varchar(1)    NOT NULL,
    "CreatedByUser"     varchar(20)   NOT NULL,
    "CreatedTimeStamp"  timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT payment_pkey PRIMARY KEY ("PaymentId")
);

ALTER TABLE payment OWNER TO firefly_app;
