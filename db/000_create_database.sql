-- Bootstrap: creates the application role and the test database.
-- Run once as the postgres superuser, connected to any database:
--   psql -U postgres -d postgres -f db/000_create_database.sql
--
-- Then create the table with:
--   psql -U postgres -d fireflydb_test -f db/001_organization.sql

CREATE ROLE firefly_app WITH LOGIN PASSWORD 'firefly_dev_pw';

CREATE DATABASE fireflydb_test WITH OWNER = firefly_app ENCODING = 'UTF8';
