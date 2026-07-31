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
