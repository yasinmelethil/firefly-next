-- Per-user, per-screen permission flags.
--
-- MySQL declares no primary key and no index of any kind on 144 rows, so an
-- interrupted-and-retried write silently doubles them. (UserId, ViewName) is the
-- natural key; verified against the live data that no duplicate pair exists, and
-- the longest ViewName is 20 characters, far inside PostgreSQL's btree limit.
--
-- A surrogate id column would have been the other option, and is rejected on
-- purpose: roughly 203 endpoints SELECT *, so any column MySQL does not have
-- becomes an extra key in the JSON the ERP receives.

CREATE TABLE IF NOT EXISTS userprivilege (
    "UserId"           varchar(20)  NOT NULL,
    "ViewName"         varchar(500) NOT NULL,
    "CanRead"          smallint     NOT NULL DEFAULT 0,
    "CanCreate"        smallint     NOT NULL DEFAULT 0,
    "CanUpdate"        smallint     NOT NULL DEFAULT 0,
    "CanDelete"        smallint     NOT NULL DEFAULT 0,
    "CanPrint"         smallint     NOT NULL DEFAULT 0,
    "CanEditRate"      smallint     NOT NULL DEFAULT 0,
    "MRP"              smallint     NOT NULL DEFAULT 0,
    "MOP"              smallint     NOT NULL DEFAULT 0,
    "MLOP"             smallint     NOT NULL DEFAULT 0,
    "SaleRate"         smallint     NOT NULL DEFAULT 0,
    "AvgRate"          smallint     NOT NULL DEFAULT 0,
    "PurchaseRate"     smallint     NOT NULL DEFAULT 0,
    "LastPurchaseRate" smallint     NOT NULL DEFAULT 0,
    "Size"             smallint     NOT NULL DEFAULT 0,
    "Colour"           smallint     NOT NULL DEFAULT 0,
    "RateSelection"    smallint     NOT NULL DEFAULT 0,

    CONSTRAINT userprivilege_pkey PRIMARY KEY ("UserId", "ViewName")
);

ALTER TABLE userprivilege OWNER TO firefly_app;
