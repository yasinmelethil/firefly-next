-- Post-dated cheques. Both ledger references point at ledger.LedgerId --
-- PartyLedgerId at a 'P' row, BankLedgerId at a 'B' row.
--
-- ChequeDate is the schema's only DATE column (everything else that carries a
-- time is datetime).

CREATE TABLE IF NOT EXISTS pdcdetails (
    "OrganizationCode" varchar(4)    NOT NULL,
    "AUTOID"           integer       NOT NULL,
    "PDCDetailsId"     varchar(18)   NOT NULL,
    "PDCNumber"        varchar(22)   NOT NULL,
    "VoucherDate"      timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "PartyLedgerId"    varchar(20)   NOT NULL,
    "BankLedgerId"     varchar(20)   NOT NULL,
    "PaymentMode"      varchar(2)    NOT NULL,
    "Amount"           numeric(24,8) NOT NULL,
    "Type"             varchar(1)    NOT NULL,
    "ChequeNumber"     varchar(50)   NOT NULL,
    "ChequeDate"       date,
    "ReferenceId"      varchar(50)   NOT NULL,
    "Status"           varchar(1)    NOT NULL,
    "CreatedByUser"    varchar(20)   NOT NULL,
    "CreatedTimeStamp" timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT pdcdetails_pkey PRIMARY KEY ("PDCDetailsId")
);

ALTER TABLE pdcdetails OWNER TO firefly_app;
