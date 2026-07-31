-- Order cancellation headers (added by REST-APP migration 16).

CREATE TABLE IF NOT EXISTS ordercancelmaster (
    "AUTOID"              integer       NOT NULL,
    "OrganizationCode"    varchar(4)    NOT NULL,
    "BillTypeId"          varchar(20)   NOT NULL,
    "OrderCancelMasterId" varchar(31)   NOT NULL,
    "OrderCancelNumber"   varchar(32)   NOT NULL,
    "OrderCancelDate"     timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "OrderMasterId"       varchar(31)   NOT NULL,
    "PartyDetails"        varchar(500)  NOT NULL,
    "LedgerId"            varchar(20)   NOT NULL,
    "Status"              varchar(1)    NOT NULL DEFAULT 'N',  -- char(1) in MySQL
    "CreatedByUser"       varchar(20)   NOT NULL,
    "CreatedTimeStamp"    timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "TotalAmount"         numeric(24,8) NOT NULL,
    "Description"         varchar(500)  NOT NULL,

    CONSTRAINT ordercancelmaster_pkey PRIMARY KEY ("OrderCancelMasterId")
);

ALTER TABLE ordercancelmaster OWNER TO firefly_app;
