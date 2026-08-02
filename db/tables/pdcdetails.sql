-- Post-dated cheques. Both ledger references point at ledger.LedgerId --
-- PartyLedgerId at a 'P' row, BankLedgerId at a 'B' row.
--
-- ChequeDate is MySQL's only DATE column, and it is mirrored here as
-- varchar(10) -- the one place this schema declines to translate the type.
--
-- The ERP posts ChequeDate="" on every sale (it sends one all-blank PdcDetails
-- element whether or not a cheque is involved), and non-strict MySQL stores
-- '0000-00-00'. Measured: all 32 live rows hold exactly that, none NULL. It is
-- not a value PostgreSQL's date type can represent at any setting, so a date
-- column here cannot round-trip the data the API actually writes.
--
-- Nothing treats it as a date. All 24 references in firefly_api.php are bare
-- SELECT list entries or PDO::PARAM_STR binds -- no comparison, no WHERE, no
-- ORDER BY, no date function -- so varchar(10) changes no behaviour and keeps
-- the wire bytes identical for the four endpoints that emit it
-- (get_pdcorcarddetails, get_pdcorcarddetailsforclearance, and both sale reads
-- via the embedded PdcDetails).
--
-- Same reasoning as char(n) -> varchar(n) and tinyint(1) -> smallint elsewhere:
-- the type is chosen for what reaches the wire, not for semantic tidiness.
-- Consequence: the types.setTypeParser(1082) registration in src/lib/db.ts is
-- now a no-op, since no column in the schema is a date. It stays as
-- documentation of why a date would have been wrong.

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
    "ChequeDate"       varchar(10),
    "ReferenceId"      varchar(50)   NOT NULL,
    "Status"           varchar(1)    NOT NULL,
    "CreatedByUser"    varchar(20)   NOT NULL,
    "CreatedTimeStamp" timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT pdcdetails_pkey PRIMARY KEY ("PDCDetailsId")
);

ALTER TABLE pdcdetails OWNER TO firefly_app;
