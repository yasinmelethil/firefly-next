-- ============================================================================
-- db/001_baseline.sql -- the complete fireflydb schema, ported to PostgreSQL.
--
-- GENERATED FILE. Do not edit. Edit db/tables/<name>.sql and re-run:
--     powershell -File scripts\build-baseline.ps1
--
-- Creates all 42 tables empty, translated from the live MySQL
-- `fireflydb` schema. Idempotent -- every statement is IF NOT EXISTS or
-- CREATE OR REPLACE, so re-running is a no-op.
--
-- Run as the postgres superuser, after db/000_create_database.sql:
--     psql -U postgres -d fireflydb_test -f db/001_baseline.sql
--
-- Identity columns start at 1 because the tables are created empty. If rows are
-- ever loaded from MySQL, every sequence must be setval'd to MAX(id) afterwards
-- or the first insert will collide.
-- ============================================================================

-- ==========================================================================
-- shared functions
-- ==========================================================================
-- Shared helpers. Emitted first by scripts/build-baseline.ps1, before any table.
--
-- MySQL's `ON UPDATE current_timestamp()` is a column attribute with no
-- PostgreSQL equivalent, so the seven columns that use it get a BEFORE UPDATE
-- trigger instead. Two functions rather than one generic one because the column
-- is spelled `updated_at` on six tables and `UpdatedAt` on substock, and
-- rewriting NEW dynamically would need hstore or a jsonb round-trip for no gain.
--
-- Divergence worth knowing: MySQL only bumps the column when the UPDATE actually
-- changes a value, while a PostgreSQL trigger fires on every UPDATE statement.
-- Nothing on the wire depends on it.

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := LOCALTIMESTAMP(0);
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION set_updatedat_camel() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW."UpdatedAt" := LOCALTIMESTAMP(0);
    RETURN NEW;
END;
$$;

ALTER FUNCTION set_updated_at() OWNER TO firefly_app;
ALTER FUNCTION set_updatedat_camel() OWNER TO firefly_app;

-- ==========================================================================
-- organization
-- ==========================================================================
-- Mirrors `organization` from MySQL `fireflydb`, with the deliberate changes noted below.
-- Ported for the insert_organization pilot (firefly_api.php line 6176).

CREATE TABLE IF NOT EXISTS organization (
    -- MySQL declares this char(4), but MySQL strips trailing spaces from CHAR on
    -- retrieval while PostgreSQL returns them padded. varchar keeps the values
    -- byte-identical on the wire; the length cap is unchanged.
    "OrganizationCode"           varchar(4)  NOT NULL,
    "Type"                       varchar(50) NOT NULL,
    "Name"                       varchar(50) NOT NULL,
    "RegionalName"               varchar(100) NOT NULL,
    "Address"                    varchar(50) NOT NULL,
    "CityId"                     varchar(10) NOT NULL,
    "ZipCode"                    varchar(15) NOT NULL,
    "CountryCode"                varchar(3)  NOT NULL,  -- char(3) in MySQL; see note above
    "Phone1"                     varchar(15) NOT NULL,
    "Phone2"                     varchar(15) NOT NULL,
    "Fax"                        varchar(15) NOT NULL,
    "EmailId"                    varchar(50) NOT NULL,
    "Url"                        varchar(100) NOT NULL,
    "Description"                varchar(100) NOT NULL,
    "ImagePath"                  varchar(250) NOT NULL,
    "Longitude"                  varchar(50) NOT NULL,
    "Latitude"                   varchar(50) NOT NULL,
    "StartTime"                  varchar(15) NOT NULL,
    "EndTime"                    varchar(15) NOT NULL,
    "TINNumber"                  varchar(50) NOT NULL,
    "DefCustSOBillType"          varchar(20) NOT NULL,
    -- MySQL spells these "...Billtype" but the PHP code and the API payload use
    -- "...BillType". MySQL's case-insensitive identifiers hide the discrepancy;
    -- PostgreSQL's quoted identifiers do not, so we adopt the API's spelling.
    --
    -- Note for whoever ports customer_login (firefly_api.php line 4635): that
    -- query reads all three as `og.DefCustSOBilltype` / `DefCustSIBilltype` /
    -- `DefCustSRBilltype` -- a casing that matches neither this table nor the
    -- write path, and which MySQL silently accepts. It must be rewritten to the
    -- spellings declared here. No wire impact: the query aliases every one of
    -- them (AS DefSOBillType, AS DefSIBillType, AS DefSRBillType), so the JSON
    -- keys come from the aliases, not the column names.
    "DefCustSIBillType"          varchar(20) NOT NULL,
    "DefCustSRBillType"          varchar(20) NOT NULL,
    "DefCustBank"                varchar(20) NOT NULL,
    "DefCustRate"                varchar(20) NOT NULL,
    -- tinyint(1) in MySQL. smallint rather than boolean so these serialise as
    -- 0/1 exactly like MySQL, not false/true -- other endpoints read them.
    -- insert_organization never writes these; a fresh row leaves them at 0.
    "DiscAffectTax"              smallint    NOT NULL DEFAULT 0,
    "UseBackSlashAsInvSeparator" smallint    NOT NULL DEFAULT 0,

    -- The MySQL table has no primary key and no indexes at all, leaving its
    -- check-then-write upsert racy. The key is required here for ON CONFLICT.
    CONSTRAINT organization_pkey PRIMARY KEY ("OrganizationCode")
);

ALTER TABLE organization OWNER TO firefly_app;

-- ==========================================================================
-- taxdetails
-- ==========================================================================
-- Tax rates. Referenced by product, salemaster, salesdetails, salesreturndetails
-- via TaxId -- which, despite being the business key, carries no unique
-- constraint in MySQL. Not adding one: duplicate TaxIds are apparently tolerated
-- and rejecting them here would break writes that succeed today.

CREATE TABLE IF NOT EXISTS taxdetails (
    "AUTOID"          integer      NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "TaxId"           varchar(20)  NOT NULL,
    "TaxName"         varchar(50)  NOT NULL,
    "Rate"            numeric(10,3) NOT NULL,
    "CalculatingMode" varchar(2)   NOT NULL,  -- char(2) in MySQL
    "TaxType"         varchar(1)   NOT NULL,  -- char(1) in MySQL

    CONSTRAINT taxdetails_pkey PRIMARY KEY ("AUTOID")
);

ALTER TABLE taxdetails OWNER TO firefly_app;

-- ==========================================================================
-- rout
-- ==========================================================================
-- Delivery routes. Referenced by ledger.RoutId and user.RoutId -- both plain
-- varchars, no constraint. (MySQL declares the user-side column "Routid"; see
-- the note in user.sql for why this port spells it RoutId.)

CREATE TABLE IF NOT EXISTS rout (
    "rt_id"  integer     NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "RoutId" varchar(20) NOT NULL,
    "Name"   varchar(20) NOT NULL,

    CONSTRAINT rout_pkey PRIMARY KEY ("rt_id")
);

ALTER TABLE rout OWNER TO firefly_app;

-- ==========================================================================
-- counters
-- ==========================================================================
-- Named sequence state (currently one row: 'PS'). This is allocation state, not
-- business data -- if rows are ever copied from MySQL while the PHP side is
-- still allocating from its own copy, both will hand out the same numbers.
--
-- Wire note: MySQL bigint comes back from PDO as a PHP integer and encodes as a
-- JSON number. node-postgres returns int8 as a *string* by default, so any
-- endpoint reading this column needs
--     pg.types.setTypeParser(20, (v) => parseInt(v, 10))
-- or it will emit "219" where PHP emits 219.

CREATE TABLE IF NOT EXISTS counters (
    "name" varchar(20) NOT NULL,
    "val"  bigint      NOT NULL DEFAULT 0,

    CONSTRAINT counters_pkey PRIMARY KEY ("name")
);

ALTER TABLE counters OWNER TO firefly_app;

-- ==========================================================================
-- settings_common
-- ==========================================================================
-- Key/value application settings. Holds firefly_api_url -- the setting the ERP
-- reads to find this very API -- so copying values here and then repointing the
-- ERP is a chicken-and-egg step worth doing deliberately.
--
-- "key" and "value" are both non-reserved in PostgreSQL, but the quoted
-- CamelCase convention applies to every identifier anyway, so nothing special
-- is needed.

CREATE TABLE IF NOT EXISTS settings_common (
    "key"   varchar(100) NOT NULL,
    "value" text,

    CONSTRAINT settings_common_pkey PRIMARY KEY ("key")
);

ALTER TABLE settings_common OWNER TO firefly_app;

-- ==========================================================================
-- settings_urls
-- ==========================================================================
-- Candidate API URLs offered by the ERP's settings screen. Machine-local.

CREATE TABLE IF NOT EXISTS settings_urls (
    "id"         integer       NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "url"        varchar(1000) NOT NULL,
    "label"      varchar(255),
    "created_at" timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT settings_urls_pkey PRIMARY KEY ("id")
);

ALTER TABLE settings_urls OWNER TO firefly_app;

-- ==========================================================================
-- settings_upi
-- ==========================================================================
-- UPI payment addresses. OrganizationCode is varchar(20) here while every other
-- table declares varchar(4)/char(4); mirrored as-is rather than "corrected".

CREATE TABLE IF NOT EXISTS settings_upi (
    "UpiId"            integer      NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "OrganizationCode" varchar(20)  NOT NULL,
    "UpiAddress"       varchar(100) NOT NULL,
    "IsDefault"        smallint     DEFAULT 0,
    "IsActive"         smallint     DEFAULT 1,
    "CreatedAt"        timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT settings_upi_pkey PRIMARY KEY ("UpiId")
);

ALTER TABLE settings_upi OWNER TO firefly_app;

-- ==========================================================================
-- printers
-- ==========================================================================
-- Physical printer definitions. Machine-local: holds LAN IPs and OS printer names.
--
-- MySQL enums become varchar + CHECK. A native PostgreSQL ENUM would serialise
-- identically, but there are 17 enum columns across the schema and each would
-- need its own type declaration plus an ALTER TYPE dance to add a label.
-- varchar keeps the wire bytes the same and stays editable.

CREATE TABLE IF NOT EXISTS printers (
    "Id"            integer      NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "Name"          varchar(100) NOT NULL,
    "Mode"          varchar(7)   NOT NULL,
    "IpAddress"     varchar(50),
    "Port"          integer      DEFAULT 9100,
    "SystemName"    varchar(150),
    "PaperWidth"    varchar(4)   DEFAULT '80mm',
    "Type"          varchar(5)   DEFAULT 'EPSON',
    "CharacterSet"  varchar(50)  DEFAULT 'PC437_USA',
    "TimeoutMs"     integer      DEFAULT 5000,
    "IsActive"      smallint     DEFAULT 1,
    "PrintBehavior" varchar(10)  NOT NULL DEFAULT 'split_only',
    "CreatedAt"     timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT printers_pkey PRIMARY KEY ("Id"),
    -- A CHECK passes when the expression is NULL, so the nullable columns below
    -- accept NULL without any extra clause -- same as the MySQL enums.
    CONSTRAINT chk_printers_mode           CHECK ("Mode" IN ('Network', 'Usb', 'Pdf', 'Kiosk')),
    CONSTRAINT chk_printers_paperwidth     CHECK ("PaperWidth" IN ('80mm', '58mm')),
    CONSTRAINT chk_printers_type           CHECK ("Type" IN ('EPSON', 'STAR')),
    CONSTRAINT chk_printers_printbehavior  CHECK ("PrintBehavior" IN ('split_only', 'full_order', 'both', 'disabled'))
);

ALTER TABLE printers OWNER TO firefly_app;

-- ==========================================================================
-- print_templates
-- ==========================================================================
-- Receipt/KOT layouts. layout_json and compiled_json are the only large payloads
-- in the schema (longtext in MySQL).

CREATE TABLE IF NOT EXISTS print_templates (
    "id"            integer      NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "name"          varchar(120) NOT NULL,
    "kind"          varchar(6)   NOT NULL DEFAULT 'bill',
    "paper_width"   varchar(20)  NOT NULL DEFAULT '80mm',
    "engine"        varchar(8)   NOT NULL DEFAULT 'compiled',
    "layout_json"   text         NOT NULL,
    "compiled_json" text,
    "compile_hash"  varchar(64),
    "compiled_at"   timestamp(0),
    "is_default"    smallint     NOT NULL DEFAULT 0,
    "is_active"     smallint     NOT NULL DEFAULT 1,
    "created_at"    timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "updated_at"    timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT print_templates_pkey PRIMARY KEY ("id"),
    CONSTRAINT chk_print_templates_kind   CHECK ("kind" IN ('bill', 'kot', 'parcel', 'bar')),
    CONSTRAINT chk_print_templates_engine CHECK ("engine" IN ('compiled', 'html'))
);

-- MySQL index names are per-table; PostgreSQL's are schema-global, and
-- idx_inventory alone would collide between product_images and substock. Every
-- index is therefore prefixed with its table name. Index names are never on the
-- wire, so this costs nothing.
CREATE INDEX IF NOT EXISTS print_templates_idx_pt_kind ON print_templates ("kind", "is_active");

DROP TRIGGER IF EXISTS print_templates_set_updated_at ON print_templates;
CREATE TRIGGER print_templates_set_updated_at
    BEFORE UPDATE ON print_templates
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE print_templates OWNER TO firefly_app;

-- ==========================================================================
-- pos_modes
-- ==========================================================================
-- POS operating modes (dine-in, takeaway, ...). The only table other code
-- declares a real foreign key against, so it must be created before
-- pos_mode_print_targets and pos_user_mode_prefs.

CREATE TABLE IF NOT EXISTS pos_modes (
    "id"                integer      NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "mode_key"          varchar(40)  NOT NULL,
    "mode_uid"          varchar(40),
    "label"             varchar(60)  NOT NULL,
    "icon"              varchar(60),
    "color"             varchar(20),
    "sort_order"        integer      NOT NULL DEFAULT 0,
    "is_active"         smallint     NOT NULL DEFAULT 1,
    "default_ledger"    varchar(40),
    "default_billtype"  varchar(40),
    "default_rate_type" varchar(20),
    "voucher_type"      varchar(2)   NOT NULL DEFAULT 'SI',
    "kot_routing"       varchar(8)   NOT NULL DEFAULT 'single',
    "default_paymode"   varchar(20)  NOT NULL DEFAULT 'CASH',
    "default_bank"      varchar(40),
    "description_tag"   varchar(120),
    "created_at"        timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "updated_at"        timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT pos_modes_pkey PRIMARY KEY ("id"),
    CONSTRAINT chk_pos_modes_voucher_type CHECK ("voucher_type" IN ('SI', 'SO')),
    CONSTRAINT chk_pos_modes_kot_routing  CHECK ("kot_routing" IN ('single', 'gatepass'))
);

-- Both engines allow repeated NULLs under a unique index, so nullable mode_uid
-- behaves the same on either side.
CREATE UNIQUE INDEX IF NOT EXISTS pos_modes_uk_pos_modes_key ON pos_modes ("mode_key");
CREATE UNIQUE INDEX IF NOT EXISTS pos_modes_uk_pos_modes_uid ON pos_modes ("mode_uid");

DROP TRIGGER IF EXISTS pos_modes_set_updated_at ON pos_modes;
CREATE TRIGGER pos_modes_set_updated_at
    BEFORE UPDATE ON pos_modes
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE pos_modes OWNER TO firefly_app;

-- ==========================================================================
-- billtype
-- ==========================================================================
-- Voucher numbering series. Every transaction master points at BillTypeId,
-- and user.Def*BillType / organization.DefCust*BillType hold eleven more
-- references -- none of them constrained in MySQL, none constrained here.
--
-- StartNumber is allocation state in the same sense as counters.val.

CREATE TABLE IF NOT EXISTS billtype (
    "billtype_id"      integer      NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "OrganizationCode" varchar(4)   NOT NULL,
    "BillTypeId"       varchar(20)  NOT NULL,
    "BillTypeName"     varchar(50)  NOT NULL,
    "StartNumber"      integer      NOT NULL,
    "Prefix"           varchar(10)  NOT NULL,
    "Suffix"           varchar(10)  NOT NULL,
    "VoucherType"      varchar(5)   NOT NULL,
    "TaxType"          varchar(20)  NOT NULL DEFAULT '',
    "CreatedByUser"    varchar(20)  NOT NULL,
    "CreatedTimeStamp" timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT billtype_pkey PRIMARY KEY ("billtype_id")
);

ALTER TABLE billtype OWNER TO firefly_app;

-- ==========================================================================
-- category
-- ==========================================================================
-- Inventory groups. ParentGroup is a self-reference to InventoryGroupId, stored
-- as a bare string with no constraint -- the hierarchy is resolved in PHP.

CREATE TABLE IF NOT EXISTS category (
    "cat_id"           integer      NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "OrganizationCode" varchar(4)   NOT NULL,  -- char(4) in MySQL
    "InventoryGroupId" varchar(20)  NOT NULL,
    "GroupName"        varchar(50)  NOT NULL,
    "ParentGroup"      varchar(20)  NOT NULL,
    "ImagePath"        varchar(200) NOT NULL DEFAULT 'no_image.jpg',
    "Colour"           varchar(50)  NOT NULL,

    CONSTRAINT category_pkey PRIMARY KEY ("cat_id")
);

ALTER TABLE category OWNER TO firefly_app;

-- ==========================================================================
-- ledger
-- ==========================================================================
-- Customers, suppliers and bank accounts in one table, discriminated by
-- LedgerType ('P' party, 'B' bank).
--
-- mypassword is a customer-portal credential stored in the clear. It is
-- mirrored here so the schema matches, but copying its values across is a
-- security decision, not a data-copy decision.

CREATE TABLE IF NOT EXISTS ledger (
    "led_id"           integer       NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "OrganizationCode" varchar(4)    NOT NULL,
    "CentreCode"       varchar(4)    NOT NULL,
    "LedgerId"         varchar(20)   NOT NULL,
    "LedgerType"       varchar(1)    NOT NULL,  -- char(1) in MySQL
    "LedgerName"       varchar(50)   NOT NULL,
    "RegionalName"     varchar(100)  NOT NULL,
    "Address"          varchar(100)  NOT NULL,
    "Email"            varchar(50)   NOT NULL,
    "Phone"            varchar(15)   NOT NULL,
    "UserName"         varchar(50)   NOT NULL,
    "mypassword"       varchar(500)  NOT NULL,
    "noofseats"        integer       NOT NULL,  -- int(2); MySQL display widths mean nothing
    "seatstaken"       integer       NOT NULL,  -- int(2)
    "CurrentBalance"   numeric(24,8) NOT NULL,
    "LedgerCode"       varchar(10)   NOT NULL,
    "CustomCode"       varchar(50)   NOT NULL,
    "RoutId"           varchar(20)   NOT NULL,
    "TINNumber"        varchar(50)   NOT NULL,
    "IsActive"         smallint      NOT NULL DEFAULT 1,

    CONSTRAINT ledger_pkey PRIMARY KEY ("led_id")
);

ALTER TABLE ledger OWNER TO firefly_app;

-- ==========================================================================
-- product
-- ==========================================================================
-- The catalogue.
--
-- Two things here look like bugs and must not be "fixed":
--
--   1. Every price column is varchar(50), not a numeric type. Converting them
--      would change the wire format from "120.00" to 120.00 and break every
--      client that reads them as strings.
--
--   2. isVeg is the schema's only bit(1). Verified against the live stack:
--      PDO returns it as a PHP integer and json_encode emits a bare 1, so
--      smallint reproduces it exactly (node-postgres parses int2 as a JS
--      number). A boolean would emit true/false instead.

CREATE TABLE IF NOT EXISTS product (
    "OrganizationCode"    varchar(4)   NOT NULL,  -- char(4) in MySQL
    "prod_id"             integer      NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "UnitId"              varchar(20)  NOT NULL,
    "UnitName"            varchar(50)  NOT NULL,
    "UnitShortName"       varchar(50)  NOT NULL,
    "ProductName"         varchar(100) NOT NULL,
    -- MySQL declares this NOT NULL with no default. insert_productwtimage omits
    -- ImagePath from its INSERT column list entirely -- that omission is the whole
    -- point of the endpoint, which updates a product while leaving its existing
    -- image alone -- and this server's non-strict sql_mode then supplies the
    -- implicit default ''. That is why 63 of the 87 live products hold ''.
    -- PostgreSQL has no implicit default, so without this the INSERT would fail.
    "ImagePath"           varchar(100) NOT NULL DEFAULT '',
    "InventoryDetailsId"  varchar(31)  NOT NULL,
    "InventoryGroupId"    varchar(20)  NOT NULL,
    "MRP"                 varchar(50)  NOT NULL,
    "MOP"                 varchar(50)  NOT NULL,
    "MLOP"                varchar(50)  NOT NULL,
    "PurchaseRate"        varchar(50)  NOT NULL,
    "AvgRate"             varchar(50)  NOT NULL,
    "LastPurchaseRate"    varchar(50)  NOT NULL,
    "SaleRate"            varchar(50)  NOT NULL,
    "isVeg"               smallint     NOT NULL,  -- bit(1) in MySQL; see note above
    "Description"         varchar(100) NOT NULL,
    "CurrentStock"        integer      NOT NULL,
    "OrderLimit"          integer      NOT NULL,
    "TaxId"               varchar(20)  NOT NULL,
    "AddTaxId"            varchar(20)  NOT NULL,
    "AddTaxId1"           varchar(20)  NOT NULL,
    "Barcode"             varchar(20)  NOT NULL,
    "CustomBarcode"       varchar(50)  NOT NULL,
    "Code"                varchar(50)  NOT NULL,
    "HSNCode"             varchar(30)  NOT NULL,
    -- These two are declared CHARACTER SET utf8 (3-byte) in MySQL while the rest
    -- of the table is utf8mb4. PostgreSQL is UTF-8 throughout, so they simply
    -- hold more than MySQL would accept -- a widening, not a divergence.
    "Size"                varchar(10)  NOT NULL,
    "Colour"              varchar(50)  NOT NULL,
    "ProductRegionalName" varchar(100) NOT NULL,
    "UnitRegionalName"    varchar(100) NOT NULL,
    "StockMaster"         integer      NOT NULL DEFAULT 0,

    CONSTRAINT product_pkey PRIMARY KEY ("prod_id")
);

-- InventoryDetailsId is the business key every other table joins on, but MySQL
-- indexes it non-uniquely. Kept non-unique: making it unique could reject rows
-- the PHP API writes today.
CREATE INDEX IF NOT EXISTS product_idx_product_inventory ON product ("InventoryDetailsId");

ALTER TABLE product OWNER TO firefly_app;

-- ==========================================================================
-- user
-- ==========================================================================
-- POS operators.
--
-- "user" is a RESERVED WORD in PostgreSQL. Unquoted it resolves to the
-- CURRENT_USER function, so every reference -- DDL, queries, src/api/*.ts --
-- must write it as "user". This is the one table name in the schema that cannot
-- be spelled bare.
--
-- Password is stored in the clear, same caveat as ledger.mypassword.

CREATE TABLE IF NOT EXISTS "user" (
    "user_id"            integer     NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "UserId"             varchar(20) NOT NULL,
    "OrganizationCode"   varchar(4)  NOT NULL,
    "Name"               varchar(50) NOT NULL,
    "UserName"           varchar(50) NOT NULL,
    "Password"           varchar(500) NOT NULL,
    "Phone"              varchar(15) NOT NULL,
    "DefSOBillType"      varchar(20) NOT NULL,
    "DefSOCBillType"     varchar(20) NOT NULL,
    "DefSIBillType"      varchar(20) NOT NULL,
    "DefRVBillType"      varchar(20) NOT NULL,
    "DefPVBillType"      varchar(20) NOT NULL,
    "DefPOBillType"      varchar(20) NOT NULL,
    "DefSRBillType"      varchar(20) NOT NULL,
    "DefJVBillType"      varchar(20) NOT NULL,
    "SaleTaxIncDiscount" smallint    NOT NULL,
    "DefCashLedger"      varchar(20) NOT NULL,
    "IsAdmin"            smallint    NOT NULL,  -- tinyint(4) in MySQL, not tinyint(1)
    -- MySQL declares this "Routid", lowercase 'id'. Spelled "RoutId" here, per the
    -- README rule that the API payload's spelling wins: every PHP reference uses
    -- RoutId, both the writes in insert_user and the login read at
    -- firefly_api.php line 4614, which names it in the select list -- so MySQL
    -- already emits "RoutId" on the wire and only the DDL disagrees. Unquoted
    -- MySQL identifiers hide the difference; quoted PostgreSQL ones do not, and
    -- "Routid" here would make insert_user fail outright.
    "RoutId"             varchar(20) NOT NULL,
    "UseOnlyRoutLedgers" smallint    NOT NULL DEFAULT 0,
    "DefSaleRate"        varchar(20) NOT NULL,
    "DefWarehouseId"     varchar(20) NOT NULL,
    "DefCardBank"        varchar(20) NOT NULL,

    CONSTRAINT user_pkey PRIMARY KEY ("user_id")
);

ALTER TABLE "user" OWNER TO firefly_app;

-- ==========================================================================
-- gatepass
-- ==========================================================================
-- Routes an inventory group's items to a kitchen printer. Machine-local
-- (holds LAN IPs). InventoryGroupId is varchar(31) here but varchar(20) on
-- category -- mirrored as declared.

CREATE TABLE IF NOT EXISTS gatepass (
    "autoid"           integer      NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "InventoryGroupId" varchar(31)  NOT NULL,
    "GroupName"        varchar(100) NOT NULL,
    "PrinterIp"        varchar(50)  NOT NULL,
    "Port"             integer      NOT NULL DEFAULT 9100,
    "Type"             varchar(50)  NOT NULL,
    "IsActive"         smallint     NOT NULL DEFAULT 1,
    "PrinterId"        integer,

    CONSTRAINT gatepass_pkey PRIMARY KEY ("autoid")
);

ALTER TABLE gatepass OWNER TO firefly_app;

-- ==========================================================================
-- warehousestock
-- ==========================================================================
-- Per-warehouse stock. MySQL declares no primary key, only UNIQUE uq_inv_wh.
-- Promoting that existing unique constraint to the primary key adds no new
-- restriction -- verified: no duplicate (InventoryDetailsId, WarehouseId) pairs
-- exist -- and gives ON CONFLICT something to target.

CREATE TABLE IF NOT EXISTS warehousestock (
    "InventoryDetailsId" varchar(31)   NOT NULL,
    "WarehouseId"        varchar(20)   NOT NULL,
    "Warehouse"          varchar(100)  NOT NULL,
    "CurrentStock"       numeric(24,8) NOT NULL,
    "Unit"               varchar(100)  NOT NULL,

    CONSTRAINT warehousestock_pkey PRIMARY KEY ("InventoryDetailsId", "WarehouseId")
);

ALTER TABLE warehousestock OWNER TO firefly_app;

-- ==========================================================================
-- substock
-- ==========================================================================
-- Unit conversions: a master SKU to its sub-SKU, with a conversion factor.
-- A self-junction on product.InventoryDetailsId.

CREATE TABLE IF NOT EXISTS substock (
    "id"                       integer       NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "MasterInventoryDetailsId" varchar(31)   NOT NULL,
    "InventoryDetailsId"       varchar(31)   NOT NULL,
    "ConversionFactor"         numeric(10,4) NOT NULL DEFAULT 0.0000,
    "CreatedByUser"            varchar(100)  NOT NULL,
    "created_at"               timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "IsActive"                 smallint      NOT NULL DEFAULT 1,
    "UpdatedAt"                timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT substock_pkey PRIMARY KEY ("id"),
    CONSTRAINT uq_master_sub UNIQUE ("MasterInventoryDetailsId", "InventoryDetailsId")
);

CREATE INDEX IF NOT EXISTS substock_idx_master    ON substock ("MasterInventoryDetailsId");
CREATE INDEX IF NOT EXISTS substock_idx_inventory ON substock ("InventoryDetailsId");

-- The only ON UPDATE column spelled "UpdatedAt" rather than updated_at.
DROP TRIGGER IF EXISTS substock_set_updated_at ON substock;
CREATE TRIGGER substock_set_updated_at
    BEFORE UPDATE ON substock
    FOR EACH ROW EXECUTE FUNCTION set_updatedat_camel();

ALTER TABLE substock OWNER TO firefly_app;

-- ==========================================================================
-- product_images
-- ==========================================================================
-- Product image gallery, keyed on the product business key rather than prod_id.

CREATE TABLE IF NOT EXISTS product_images (
    "ImageId"            integer      NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "InventoryDetailsId" varchar(31)  NOT NULL,
    "ImagePath"          varchar(255) NOT NULL,
    "IsPrimary"          smallint     DEFAULT 0,
    "CreatedAt"          timestamp(0) DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT product_images_pkey PRIMARY KEY ("ImageId")
);

CREATE INDEX IF NOT EXISTS product_images_idx_inventory ON product_images ("InventoryDetailsId");

ALTER TABLE product_images OWNER TO firefly_app;

-- ==========================================================================
-- userprivilege
-- ==========================================================================
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

-- ==========================================================================
-- userledgerprivilege
-- ==========================================================================
-- Which ledgers a user may not see. The largest table in the database (287 rows).
-- MySQL has a surrogate key but no uniqueness on (UserId, LedgerId); not adding
-- one, since duplicates are evidently tolerated today.

CREATE TABLE IF NOT EXISTS userledgerprivilege (
    "uspv_id"  integer     NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "UserId"   varchar(20) NOT NULL,
    "LedgerId" varchar(20) NOT NULL,
    "Block"    smallint    NOT NULL,

    CONSTRAINT userledgerprivilege_pkey PRIMARY KEY ("uspv_id")
);

ALTER TABLE userledgerprivilege OWNER TO firefly_app;

-- ==========================================================================
-- printersettings
-- ==========================================================================
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

-- ==========================================================================
-- user_printers
-- ==========================================================================
-- Per-user printer assignment by role. Machine-local.
-- Note user_id is varchar(30) here but varchar(40) on pos_user_mode_prefs and
-- user_print_formats; mirrored as declared.

CREATE TABLE IF NOT EXISTS user_printers (
    "id"            integer      NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "user_id"       varchar(30)  NOT NULL,
    "printer_type"  varchar(6)   NOT NULL,
    "mode"          varchar(7)   NOT NULL DEFAULT 'network',
    "name"          varchar(255),
    "ip_address"    varchar(50),
    "port"          integer,
    "paper_width"   varchar(20)  DEFAULT '80mm',
    "type"          varchar(50)  DEFAULT 'EPSON',
    "character_set" varchar(50)  DEFAULT 'PC437_USA',
    "timeout_ms"    integer      DEFAULT 5000,
    "is_active"     smallint     DEFAULT 1,
    "PrinterId"     integer,
    "created_at"    timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "updated_at"    timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT user_printers_pkey PRIMARY KEY ("id"),
    CONSTRAINT uk_user_printer UNIQUE ("user_id", "printer_type"),
    CONSTRAINT chk_user_printers_printer_type CHECK ("printer_type" IN ('bill', 'parcel', 'kot', 'bar', 'pickup')),
    CONSTRAINT chk_user_printers_mode         CHECK ("mode" IN ('network', 'usb', 'pdf', 'kiosk'))
);

DROP TRIGGER IF EXISTS user_printers_set_updated_at ON user_printers;
CREATE TRIGGER user_printers_set_updated_at
    BEFORE UPDATE ON user_printers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE user_printers OWNER TO firefly_app;

-- ==========================================================================
-- user_print_formats
-- ==========================================================================
-- Per-user override of the bill print engine. `kind` is a plain varchar(20) in
-- MySQL, not an enum, unlike the visually similar print_templates.kind.

CREATE TABLE IF NOT EXISTS user_print_formats (
    "id"          integer      NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "user_id"     varchar(40)  NOT NULL,
    "kind"        varchar(20)  NOT NULL DEFAULT 'bill',
    "engine"      varchar(8)   NOT NULL DEFAULT 'inherit',
    "template_id" integer,
    "is_active"   smallint     NOT NULL DEFAULT 1,
    "created_at"  timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "updated_at"  timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT user_print_formats_pkey PRIMARY KEY ("id"),
    CONSTRAINT uk_upf_user_kind UNIQUE ("user_id", "kind"),
    CONSTRAINT chk_user_print_formats_engine CHECK ("engine" IN ('inherit', 'escpos', 'html', 'compiled'))
);

DROP TRIGGER IF EXISTS user_print_formats_set_updated_at ON user_print_formats;
CREATE TRIGGER user_print_formats_set_updated_at
    BEFORE UPDATE ON user_print_formats
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE user_print_formats OWNER TO firefly_app;

-- ==========================================================================
-- pos_user_mode_prefs
-- ==========================================================================
-- Per-user defaults for a POS mode. One of only two tables carrying a real
-- foreign key in MySQL, so the reference is replicated here -- including
-- ON DELETE CASCADE.

CREATE TABLE IF NOT EXISTS pos_user_mode_prefs (
    "id"         integer      NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "user_id"    varchar(40)  NOT NULL,
    "mode_id"    integer      NOT NULL,
    "ledger"     varchar(40),
    "billtype"   varchar(40),
    "paymode"    varchar(20)  NOT NULL DEFAULT 'CASH',
    "bank"       varchar(40),
    "auto_print" smallint     NOT NULL DEFAULT 1,
    "print_bill" smallint     NOT NULL DEFAULT 1,
    "print_kot"  smallint     NOT NULL DEFAULT 0,
    "created_at" timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "updated_at" timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT pos_user_mode_prefs_pkey PRIMARY KEY ("id"),
    CONSTRAINT uk_user_mode UNIQUE ("user_id", "mode_id"),
    CONSTRAINT fk_pump_mode FOREIGN KEY ("mode_id") REFERENCES pos_modes ("id") ON DELETE CASCADE
);

DROP TRIGGER IF EXISTS pos_user_mode_prefs_set_updated_at ON pos_user_mode_prefs;
CREATE TRIGGER pos_user_mode_prefs_set_updated_at
    BEFORE UPDATE ON pos_user_mode_prefs
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE pos_user_mode_prefs OWNER TO firefly_app;

-- ==========================================================================
-- pos_mode_print_targets
-- ==========================================================================
-- Which printer and template each POS mode uses, per printer role. The second
-- and last table with a real MySQL foreign key.

CREATE TABLE IF NOT EXISTS pos_mode_print_targets (
    "id"            integer      NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "mode_id"       integer      NOT NULL,
    "printer_role"  varchar(6),
    "printer_id"    integer,
    "template"      varchar(14)  NOT NULL DEFAULT 'full_bill',
    "template_id"   integer,
    "print_mode"    varchar(8)   NOT NULL DEFAULT 'escpos',
    "paper_width"   varchar(20),
    "copies"        integer      NOT NULL DEFAULT 1,
    "trigger_event" varchar(7)   NOT NULL DEFAULT 'manual',
    "sort_order"    integer      NOT NULL DEFAULT 0,
    "is_active"     smallint     NOT NULL DEFAULT 1,
    "created_at"    timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "updated_at"    timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT pos_mode_print_targets_pkey PRIMARY KEY ("id"),
    CONSTRAINT fk_mpt_mode FOREIGN KEY ("mode_id") REFERENCES pos_modes ("id") ON DELETE CASCADE,
    CONSTRAINT chk_pmpt_printer_role  CHECK ("printer_role" IN ('bill', 'kot', 'parcel', 'bar', 'pickup')),
    CONSTRAINT chk_pmpt_template      CHECK ("template" IN ('full_bill', 'packing_slip', 'kitchen_ticket', 'label', 'bar_ticket')),
    CONSTRAINT chk_pmpt_print_mode    CHECK ("print_mode" IN ('escpos', 'html', 'compiled')),
    CONSTRAINT chk_pmpt_trigger_event CHECK ("trigger_event" IN ('on_save', 'on_pay', 'manual'))
);

CREATE INDEX IF NOT EXISTS pos_mode_print_targets_idx_mpt_mode ON pos_mode_print_targets ("mode_id");

DROP TRIGGER IF EXISTS pos_mode_print_targets_set_updated_at ON pos_mode_print_targets;
CREATE TRIGGER pos_mode_print_targets_set_updated_at
    BEFORE UPDATE ON pos_mode_print_targets
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE pos_mode_print_targets OWNER TO firefly_app;

-- ==========================================================================
-- ordermaster
-- ==========================================================================
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

-- ==========================================================================
-- purchaseordermaster
-- ==========================================================================
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

-- ==========================================================================
-- orderdetails
-- ==========================================================================
-- Order line items. `ordermstr_id` is snake_case while its parent column is
-- ordermaster."OrderMasterId" -- mirrored as declared.

CREATE TABLE IF NOT EXISTS orderdetails (
    "orderdtl_id"        integer       NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "ordermstr_id"       varchar(31)   NOT NULL,
    "InventoryDetailsId" varchar(31)   NOT NULL,
    "UnitId"             varchar(20)   NOT NULL,
    "Quantity"           numeric(24,8) NOT NULL,
    "Rate"               numeric(24,8) NOT NULL,
    "TotalAmount"        numeric(24,8) NOT NULL,
    "Description"        varchar(500)  NOT NULL,
    "CreatedByUser"      varchar(20)   NOT NULL,
    "CreatedTimeStamp"   timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT orderdetails_pkey PRIMARY KEY ("orderdtl_id")
);

CREATE INDEX IF NOT EXISTS orderdetails_idx_orderdetails_ordermstr ON orderdetails ("ordermstr_id");

ALTER TABLE orderdetails OWNER TO firefly_app;

-- ==========================================================================
-- purchaseorderdetails
-- ==========================================================================
-- Purchase order line items. Same shape as orderdetails but with OrderQuantity
-- instead of Quantity, plus UpdatedQuantity for partial receipts.
-- ordermstr_id points at purchaseordermaster."ordermasterId".

CREATE TABLE IF NOT EXISTS purchaseorderdetails (
    "orderdtl_id"        integer       NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "ordermstr_id"       varchar(31)   NOT NULL,
    "InventoryDetailsId" varchar(31)   NOT NULL,
    "UnitId"             varchar(20)   NOT NULL,
    "OrderQuantity"      numeric(24,8) NOT NULL,
    "Rate"               numeric(24,8) NOT NULL,
    "TotalAmount"        numeric(24,8) NOT NULL,
    "Description"        varchar(500)  NOT NULL,
    "CreatedByUser"      varchar(20)   NOT NULL,
    "CreatedTimeStamp"   timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "UpdatedQuantity"    numeric(24,8) NOT NULL,

    CONSTRAINT purchaseorderdetails_pkey PRIMARY KEY ("orderdtl_id")
);

ALTER TABLE purchaseorderdetails OWNER TO firefly_app;

-- ==========================================================================
-- ordercancelmaster
-- ==========================================================================
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

-- ==========================================================================
-- salemaster
-- ==========================================================================
-- Sales invoice headers. The most-migrated table in the schema: IdempotencyKey,
-- RoundOffAmount, IsOut and PosMode were all added after the REST-APP baseline
-- was captured.
--
-- OrderMasterId is varchar(480) while ordermaster."OrderMasterId" is
-- varchar(31). That is not a mistake to tidy up: the column holds a
-- COMMA-JOINED LIST of order ids when several orders are merged onto one bill
-- (480 is roughly 15 x 32). It must never be given a foreign key or narrowed --
-- the live rows all happen to hold a single id, so a naive varchar(31) + FK
-- passes on today's data and fails on the first merged bill.

CREATE TABLE IF NOT EXISTS salemaster (
    "AUTOID"             integer       NOT NULL,
    "OrganizationCode"   varchar(4)    NOT NULL,
    "BillTypeId"         varchar(20)   NOT NULL,
    "OrderMasterId"      varchar(480),
    "LedgerId"           varchar(20)   NOT NULL,
    "PartyDetails"       varchar(500)  NOT NULL,
    "VoucherDate"        timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "Status"             varchar(1)    NOT NULL,  -- char(1) in MySQL
    "IsOut"              smallint      NOT NULL DEFAULT 0,
    "GrossAmount"        numeric(24,8) NOT NULL,
    "TaxId"              varchar(20)   NOT NULL,
    "TaxableAmount"      numeric(24,8) NOT NULL,
    "TaxPercentage"      numeric(5,2)  NOT NULL,
    "TaxAmount"          numeric(24,8) NOT NULL,
    "DiscountPercentage" numeric(5,2)  NOT NULL,
    "DiscountAmount"     numeric(24,8) NOT NULL,
    -- Sign convention flipped to the ERP's by REST-APP migration 23.
    "RoundOffAmount"     numeric(24,8) NOT NULL,
    "TotalAmount"        numeric(24,8) NOT NULL,
    "PaidAmount"         numeric(24,8) NOT NULL,
    "CreatedByUser"      varchar(20)   NOT NULL,
    "CreatedTimeStamp"   timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "SaleMasterId"       varchar(31)   NOT NULL,
    "VoucherNumber"      varchar(32)   NOT NULL,
    "Description"        varchar(500)  NOT NULL,
    "IdempotencyKey"     varchar(64),
    "PosMode"            varchar(40),

    CONSTRAINT salemaster_pkey PRIMARY KEY ("SaleMasterId")
);

-- Nullable and unique: both engines permit unlimited NULLs here, so invoices
-- written without an idempotency key are unaffected.
CREATE UNIQUE INDEX IF NOT EXISTS salemaster_uniq_salemaster_idempotency ON salemaster ("IdempotencyKey");

CREATE INDEX IF NOT EXISTS salemaster_idx_salemaster_posmode     ON salemaster ("PosMode");
CREATE INDEX IF NOT EXISTS salemaster_idx_salemaster_isout       ON salemaster ("IsOut");
CREATE INDEX IF NOT EXISTS salemaster_idx_salemaster_voucherdate ON salemaster ("VoucherDate");

ALTER TABLE salemaster OWNER TO firefly_app;

-- ==========================================================================
-- ordercanceldetails
-- ==========================================================================
-- Order cancellation line items. OrderDetailsId points at
-- orderdetails."orderdtl_id" -- an integer reference, unlike everything else
-- in the schema, which joins on opaque strings.

CREATE TABLE IF NOT EXISTS ordercanceldetails (
    "OrderCancelDetailsId" integer       NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "OrderCancelMasterId"  varchar(31)   NOT NULL,
    "OrderDetailsId"       integer       NOT NULL,
    "InventoryDetailsId"   varchar(31)   NOT NULL,
    "UnitId"               varchar(20)   NOT NULL,
    "Quantity"             numeric(24,8) NOT NULL,
    "Rate"                 numeric(24,8) NOT NULL,
    "TotalAmount"          numeric(24,8) NOT NULL,
    "Description"          varchar(500)  NOT NULL,
    "CreatedByUser"        varchar(20)   NOT NULL,
    "CreatedTimeStamp"     timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT ordercanceldetails_pkey PRIMARY KEY ("OrderCancelDetailsId")
);

CREATE INDEX IF NOT EXISTS ordercanceldetails_idx_ocd_orderdetailsid ON ordercanceldetails ("OrderDetailsId");

ALTER TABLE ordercanceldetails OWNER TO firefly_app;

-- ==========================================================================
-- salesdetails
-- ==========================================================================
-- Invoice line items. Three parallel tax slots (TaxId, AddTaxId, AddTaxId1),
-- each with its own percentage and amount.

CREATE TABLE IF NOT EXISTS salesdetails (
    "SaleDetailsId"      integer       NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "SaleMasterId"       varchar(31)   NOT NULL,
    "InventoryDetailsId" varchar(31)   NOT NULL,
    "UnitId"             varchar(20)   NOT NULL,
    "Quantity"           numeric(24,8) NOT NULL,
    "Rate"               numeric(24,8) NOT NULL,
    "GrossAmount"        numeric(24,8) NOT NULL,
    "DiscountPercentage" numeric(5,2)  NOT NULL,
    "DiscountAmount"     numeric(24,8) NOT NULL,
    "TaxId"              varchar(20)   NOT NULL,
    "TaxableAmount"      numeric(24,8) NOT NULL,
    "TaxPercentage"      numeric(5,2)  NOT NULL,
    "TaxAmount"          numeric(24,8) NOT NULL,
    "TotalAmount"        numeric(24,8) NOT NULL,
    "CreatedByUser"      varchar(20)   NOT NULL,
    "CreatedTimeStamp"   timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "Description"        varchar(500)  NOT NULL,
    "AddTaxId"           varchar(20)   NOT NULL,
    "AddTaxPercentage"   numeric(5,2)  NOT NULL,
    "AddTaxAmount"       numeric(24,8) NOT NULL,
    "AddTaxId1"          varchar(20)   NOT NULL,
    "AddTaxPercentage1"  numeric(5,2)  NOT NULL,
    "AddTaxAmount1"      numeric(24,8) NOT NULL,

    CONSTRAINT salesdetails_pkey PRIMARY KEY ("SaleDetailsId")
);

CREATE INDEX IF NOT EXISTS salesdetails_idx_salesdetails_salemaster ON salesdetails ("SaleMasterId");

ALTER TABLE salesdetails OWNER TO firefly_app;

-- ==========================================================================
-- salereturn
-- ==========================================================================
-- Sales return headers. Same shape as salemaster minus RoundOffAmount, IsOut,
-- IdempotencyKey and PosMode.
--
-- SaleMasterId is varchar(47) while salemaster."SaleMasterId" is varchar(31) --
-- another deliberate width mismatch, mirrored as declared.

CREATE TABLE IF NOT EXISTS salereturn (
    "AUTOID"             integer       NOT NULL,
    "OrganizationCode"   varchar(4)    NOT NULL,
    "BillTypeId"         varchar(20)   NOT NULL,
    "SaleMasterId"       varchar(47)   NOT NULL,
    "LedgerId"           varchar(20)   NOT NULL,
    "PartyDetails"       varchar(500)  NOT NULL,
    "VoucherDate"        timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "Status"             varchar(1)    NOT NULL,  -- char(1) in MySQL
    "GrossAmount"        numeric(24,8) NOT NULL,
    "TaxId"              varchar(20)   NOT NULL,
    "TaxableAmount"      numeric(24,8) NOT NULL,
    "TaxPercentage"      numeric(5,2)  NOT NULL,
    "TaxAmount"          numeric(24,8) NOT NULL,
    "DiscountPercentage" numeric(5,2)  NOT NULL,
    "DiscountAmount"     numeric(24,8) NOT NULL,
    "TotalAmount"        numeric(24,8) NOT NULL,
    "PaidAmount"         numeric(24,8) NOT NULL,
    "CreatedByUser"      varchar(20)   NOT NULL,
    "CreatedTimeStamp"   timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "SaleReturnMasterId" varchar(31)   NOT NULL,
    "ReturnNumber"       varchar(32)   NOT NULL,
    "Description"        varchar(500)  NOT NULL,

    CONSTRAINT salereturn_pkey PRIMARY KEY ("SaleReturnMasterId")
);

ALTER TABLE salereturn OWNER TO firefly_app;

-- ==========================================================================
-- stockposting
-- ==========================================================================
-- The stock ledger: one row per line item per voucher. The only table in the
-- schema with unbounded growth.
--
-- MasterId is polymorphic -- it holds a salemaster."SaleMasterId" or an
-- ordermaster."OrderMasterId" depending on VoucherType, which is why it can
-- never carry a foreign key. InventoryDetailsId is varchar(50) here against
-- product's varchar(31); mirrored as declared.

CREATE TABLE IF NOT EXISTS stockposting (
    "id"                 integer       NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "InventoryDetailsId" varchar(50)   NOT NULL,
    "VoucherType"        varchar(10)   NOT NULL,
    "VoucherNumber"      varchar(30),
    "Qty"                numeric(18,4) NOT NULL,
    "Unit"               varchar(20)   NOT NULL DEFAULT 'No',
    "WarehouseId"        varchar(50),
    "MasterId"           varchar(50),
    "Direction"          varchar(1)    NOT NULL DEFAULT 'I',
    "VoucherDate"        timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "CreatedAt"          timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT stockposting_pkey PRIMARY KEY ("id"),
    CONSTRAINT chk_stockposting_direction CHECK ("Direction" IN ('I', 'O'))
);

CREATE INDEX IF NOT EXISTS stockposting_idx_inv_wh       ON stockposting ("InventoryDetailsId", "WarehouseId");
CREATE INDEX IF NOT EXISTS stockposting_idx_master_type  ON stockposting ("MasterId", "VoucherType", "Direction");
CREATE INDEX IF NOT EXISTS stockposting_idx_voucher_date ON stockposting ("VoucherDate");

ALTER TABLE stockposting OWNER TO firefly_app;

-- ==========================================================================
-- receipt
-- ==========================================================================
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

-- ==========================================================================
-- payment
-- ==========================================================================
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

-- ==========================================================================
-- journal
-- ==========================================================================
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

-- ==========================================================================
-- pdcdetails
-- ==========================================================================
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

-- ==========================================================================
-- salesreturndetails
-- ==========================================================================
-- Sales return line items. Column-for-column identical to salesdetails, with
-- SaleReturnDetailsId as the key and SaleReturnMasterId as the parent. MySQL
-- gives this one no secondary index, unlike salesdetails.

CREATE TABLE IF NOT EXISTS salesreturndetails (
    "SaleReturnDetailsId" integer       NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "SaleReturnMasterId"  varchar(31)   NOT NULL,
    "InventoryDetailsId"  varchar(31)   NOT NULL,
    "UnitId"              varchar(20)   NOT NULL,
    "Quantity"            numeric(24,8) NOT NULL,
    "Rate"                numeric(24,8) NOT NULL,
    "GrossAmount"         numeric(24,8) NOT NULL,
    "DiscountPercentage"  numeric(5,2)  NOT NULL,
    "DiscountAmount"      numeric(24,8) NOT NULL,
    "TaxId"               varchar(20)   NOT NULL,
    "TaxableAmount"       numeric(24,8) NOT NULL,
    "TaxPercentage"       numeric(5,2)  NOT NULL,
    "TaxAmount"           numeric(24,8) NOT NULL,
    "TotalAmount"         numeric(24,8) NOT NULL,
    "CreatedByUser"       varchar(20)   NOT NULL,
    "CreatedTimeStamp"    timestamp(0)  NOT NULL DEFAULT LOCALTIMESTAMP(0),
    "Description"         varchar(500)  NOT NULL,
    "AddTaxId"            varchar(20)   NOT NULL,
    "AddTaxPercentage"    numeric(5,2)  NOT NULL,
    "AddTaxAmount"        numeric(24,8) NOT NULL,
    "AddTaxId1"           varchar(20)   NOT NULL,
    "AddTaxPercentage1"   numeric(5,2)  NOT NULL,
    "AddTaxAmount1"       numeric(24,8) NOT NULL,

    CONSTRAINT salesreturndetails_pkey PRIMARY KEY ("SaleReturnDetailsId")
);

ALTER TABLE salesreturndetails OWNER TO firefly_app;

-- ==========================================================================
-- schema_migrations
-- ==========================================================================
-- Bookkeeping for the PHP migration runner at
-- c:\xampp\htdocs\REST-APP\scripts\migrate.php.
--
-- Created for schema completeness only. This project applies db/001_baseline.sql
-- by hand and has no migration runner of its own, so the table stays empty --
-- copying MySQL's 24 rows here would assert that PHP migrations had been applied
-- to a database they have never touched.

CREATE TABLE IF NOT EXISTS schema_migrations (
    "version"    varchar(190) NOT NULL,
    "applied_at" timestamp(0) NOT NULL DEFAULT LOCALTIMESTAMP(0),

    CONSTRAINT schema_migrations_pkey PRIMARY KEY ("version")
);

ALTER TABLE schema_migrations OWNER TO firefly_app;
