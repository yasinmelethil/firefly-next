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
