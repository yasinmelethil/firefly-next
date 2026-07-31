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
