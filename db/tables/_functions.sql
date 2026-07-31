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
