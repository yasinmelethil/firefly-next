-- Seeds the settings_common rows the ported endpoints branch on.
--
-- db/001_baseline.sql creates every table empty. That is right for master data,
-- but settings_common is different: code reads it and changes behaviour on what
-- it finds, so an empty table is not a neutral starting point -- it is a
-- different configuration.
--
-- Specifically, insert_productwithwarehousestock (firefly_api.php line 6000)
-- reads stock_source and writes nothing at all when it is exactly 'APP'. Live
-- MySQL has it set to 'APP', so warehousestock writes are currently disabled in
-- production. With settings_common empty, PostgreSQL would fall back to 'ERP'
-- and start writing rows MySQL is not writing.
--
-- Only the keys that change ported behaviour are seeded. The rest of the live
-- table is deliberately left out: firefly_api_url and print_server_url point at
-- the machine the old stack runs on, and copying them here then repointing the
-- ERP is a chicken-and-egg step to take deliberately, not as a side effect.
--
-- Values captured from live MySQL fireflydb on 2026-07-31. Re-run safely: an
-- existing row keeps its value, so local overrides survive.
--   psql -U postgres -d fireflydb_test -f db/002_seed_settings.sql

INSERT INTO settings_common ("key", "value") VALUES
    -- 'APP' = the POS owns stock and the ERP sync is skipped. 'ERP' (or a
    -- missing row) = warehousestock is written on every product save.
    ('stock_source',        'APP'),
    ('stock_decrease_mode', 'on_order'),
    ('bulk_edit_stock',     '0')
ON CONFLICT ("key") DO NOTHING;
