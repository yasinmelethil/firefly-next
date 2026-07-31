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
