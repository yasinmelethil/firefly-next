-- Which print design to use per voucher type, per user. Machine-local.
--
-- Like userprivilege, MySQL gives this table no key at all. The table is empty,
-- so there is no data to contradict the choice, but the key below encodes an
-- ASSUMPTION about intent: one design per (organisation, voucher type, user).
-- If the app is ever meant to store several designs for one user and voucher
-- type, this constraint is the thing that will fail, and it is the thing to
-- revisit -- not the app.

CREATE TABLE IF NOT EXISTS printersettings (
    "OrganizationCode" varchar(4)   NOT NULL,
    "VoucherType"      varchar(2)   NOT NULL,
    "DesignName"       varchar(100) NOT NULL,
    "PrintByDefault"   smallint     NOT NULL,
    "UserId"           varchar(20)  NOT NULL,
    "PrinterName"      varchar(100) NOT NULL,

    CONSTRAINT printersettings_pkey PRIMARY KEY ("OrganizationCode", "VoucherType", "UserId")
);

ALTER TABLE printersettings OWNER TO firefly_app;
