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
