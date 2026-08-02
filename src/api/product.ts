import type { Cases } from "@/api/_types";
import { query, withTransaction } from "@/lib/db";
import { imagePaths } from "@/lib/imagepaths";
import {
  isPhpEmpty,
  mysqlBit,
  mysqlInt,
  mysqlNumeric,
  phpStr,
  post,
} from "@/lib/params";
import { emptyArrayJson, untouchedDefaultsJson } from "@/lib/read";
import {
  FALSE,
  MESSAGE_ERROR,
  NULL_JSON_ARRAY,
  STATUS_ERROR,
  STATUS_SUCCESS,
  echoSqlPrefix,
  phpJson,
  trueFalseJson,
} from "@/lib/response";
import { binds, checkedSql, cols, paramOf, setList } from "@/lib/sql";

/**
 * The 29 fields insert_productwtimage reads from $_POST, in the order the PHP
 * INSERT lists them. As with organization, PostgreSQL column names are quoted
 * CamelCase mirroring MySQL, so this one array drives the payload keys, the SQL
 * identifiers and the bind order.
 *
 * ImagePath is absent on purpose and must stay absent. Despite the name,
 * "wtimage" means *without* image: this function is insert_product with every
 * trace of ImagePath deleted, so that saving a product leaves its existing image
 * untouched. It is never read from $_POST, never bound, and never named in
 * either statement. On insert the column falls to its default -- '' in MySQL by
 * way of non-strict mode, and explicitly DEFAULT '' in db/tables/product.sql.
 */
const FIELDS = [
  "OrganizationCode",
  "UnitId",
  "UnitName",
  "UnitShortName",
  "UnitRegionalName",
  "ProductName",
  "ProductRegionalName",
  "Barcode",
  "CustomBarcode",
  "Code",
  "HSNCode",
  "Size",
  "Colour",
  "InventoryDetailsId",
  "InventoryGroupId",
  "MRP",
  "SaleRate",
  "MOP",
  "MLOP",
  "PurchaseRate",
  "AvgRate",
  "LastPurchaseRate",
  "isVeg",
  "Description",
  "CurrentStock",
  "OrderLimit",
  "TaxId",
  "AddTaxId",
  "AddTaxId1",
] as const;

/**
 * product is not all-varchar the way organization was, and the ERP sends every
 * value as a string regardless. Non-strict MySQL reshapes the mismatches
 * silently; PostgreSQL would raise. See the helpers in src/lib/params.ts for the
 * measured rules. Everything not listed here is a varchar column -- including
 * all seven price fields, which stay text so "120.00" survives on the wire.
 */
const COERCE: Partial<Record<(typeof FIELDS)[number], (v: string | null) => unknown>> = {
  isVeg: mysqlBit, // bit(1) -> smallint
  CurrentStock: mysqlInt, // int(10)
  OrderLimit: mysqlInt, // int(10)
};

function values(fd: FormData): unknown[] {
  return FIELDS.map((field) => {
    const raw = post(fd, field);
    const coerce = COERCE[field];
    return coerce ? coerce(raw) : raw;
  });
}

// InventoryDetailsId is FIELDS[13], so it binds to $14 -- reused as the WHERE
// key. PHP names the parameter twice in one statement, which only works because
// PDO emulates prepares; node-postgres is positional, so the same $n is reused.
const UPDATE_SQL = checkedSql(
  "product UPDATE",
  `UPDATE product SET ${setList(FIELDS)}
WHERE "InventoryDetailsId" = ${paramOf(FIELDS, "InventoryDetailsId")}`,
  FIELDS.length,
);

const INSERT_SQL = checkedSql(
  "product INSERT",
  `INSERT INTO product (${cols(FIELDS)})
VALUES (${binds(FIELDS)})`,
  FIELDS.length,
);

/**
 * The raw SQL that firefly_api.php line 5761 echoes into the response body
 * before the JSON, making the live response invalid JSON. Reproduced verbatim --
 * tabs, CRLF and the doubled space before WHERE included -- and emitted only
 * when FFAPI_ECHO_SQL is set. The UPDATE string was verified byte-for-byte
 * (748 bytes) against a logged production response.
 *
 * Note this is the *PHP* statement text, not the SQL this module actually runs.
 * That is the point: it is a compatibility artefact for any client that came to
 * depend on the prefix, not a debugging aid.
 */
const ECHO_SQL_UPDATE =
  "UPDATE product SET OrganizationCode=:OrganizationCode, UnitId=:UnitId,UnitName=:UnitName,UnitShortName=:UnitShortName, UnitRegionalName=:UnitRegionalName, ProductName=:ProductName,\r\n\t    \t\t        ProductRegionalName=:ProductRegionalName,\r\n    \t\t        Barcode=:Barcode,CustomBarcode=:CustomBarcode,Code=:Code,HSNCode=:HSNCode,Size=:Size,Colour=:Colour,InventoryDetailsId=:InventoryDetailsId, InventoryGroupId=:InventoryGroupId, MRP=:MRP, SaleRate=:SaleRate,MOP=:MOP,MLOP=:MLOP,PurchaseRate=:PurchaseRate,AvgRate=:AvgRate,LastPurchaseRate=:LastPurchaseRate, isVeg=:isVeg, Description=:Description, CurrentStock=:CurrentStock, OrderLimit=:OrderLimit,TaxId=:TaxId,AddTaxId=:AddTaxId,AddTaxId1=:AddTaxId1  WHERE InventoryDetailsId=:InventoryDetailsId";

const ECHO_SQL_INSERT =
  "INSERT INTO product (OrganizationCode, UnitId,UnitName,UnitShortName, UnitRegionalName, ProductName,ProductRegionalName,Barcode,CustomBarcode,Code,HSNCode,Size,Colour,InventoryDetailsId, InventoryGroupId, MRP,SaleRate,MOP,MLOP,PurchaseRate,AvgRate,LastPurchaseRate, isVeg, Description, CurrentStock,OrderLimit,TaxId,AddTaxId,AddTaxId1) VALUES (:OrganizationCode, :UnitId,\r\n    \t\t            :UnitName,:UnitShortName, :UnitRegionalName, :ProductName,:ProductRegionalName,:Barcode,:CustomBarcode,:Code,:HSNCode,:Size,:Colour,:InventoryDetailsId, :InventoryGroupId, :MRP,:SaleRate,:MOP,:MLOP,:PurchaseRate,:AvgRate,:LastPurchaseRate, :isVeg, :Description, :CurrentStock,:OrderLimit,:TaxId,:AddTaxId,:AddTaxId1)";

/** What a handler returns: the PHP 'TRUE'/'FALSE' contract, plus the echoed SQL. */
export interface ProductResult {
  action: "TRUE" | "FALSE";
  /** The statement PHP would have echoed, or '' if this run took no branch. */
  echo: string;
}

/**
 * Port of insert_productwtimage($dbh), firefly_api.php line 5713.
 *
 * PHP probes with SELECT IF(EXISTS(...)) and then branches to UPDATE or INSERT.
 * Reproduced as UPDATE-then-INSERT-if-nothing-matched, in a transaction. That is
 * one round trip fewer and the same observable behaviour, and unlike organization
 * it cannot be collapsed into ON CONFLICT: the conflict target would have to be
 * InventoryDetailsId, whose index db/tables/product.sql deliberately leaves
 * non-unique so the port never rejects a write MySQL accepts.
 *
 * This relies on a PostgreSQL detail: rowCount after UPDATE counts rows that
 * MATCHED the WHERE clause, so a save that changes nothing still reports 1 and
 * correctly stays on the update path. MySQL's affected_rows would report 0 there
 * and send us on to a duplicate INSERT.
 */
export async function insertProductWtImage(fd: FormData): Promise<ProductResult> {
  const params = values(fd);

  try {
    return await withTransaction(async (client) => {
      const updated = await client.query(UPDATE_SQL, params);
      if (updated.rowCount && updated.rowCount > 0) {
        return { action: "TRUE", echo: ECHO_SQL_UPDATE };
      }
      await client.query(INSERT_SQL, params);
      return { action: "TRUE", echo: ECHO_SQL_INSERT };
    });
  } catch {
    // PHP returns 'FALSE' only from catch (Exception), and its PDO handle is
    // built without ERRMODE_EXCEPTION, so in practice a failed write there still
    // reports success. We surface it instead -- see README "Known divergences".
    return { action: "FALSE", echo: "" };
  }
}

/** One entry of the Inventoriesstock JSON array. */
interface StockItem {
  InventoryDetailsId?: unknown;
  WarehouseId?: unknown;
  Warehouse?: unknown;
  /** Maps to the CurrentStock column -- the key and the column disagree. */
  Stock?: unknown;
  /** Maps to the Unit column, likewise. */
  UnitShortName?: unknown;
}

const STOCK_UPDATE_SQL = `UPDATE warehousestock
SET "CurrentStock" = $3, "Warehouse" = $4, "Unit" = $5
WHERE "InventoryDetailsId" = $1 AND "WarehouseId" = $2`;

// PHP guards the insert with a second probe -- only write stock for a product
// that exists. Folding it into the INSERT makes the guard atomic instead of a
// second check-then-write race.
//
// The casts are required, not decorative. PostgreSQL propagates target column
// types into a VALUES list but NOT through a SELECT list, so without them $3
// stays text and is rejected against numeric ("column CurrentStock is of type
// numeric but expression is of type text"). $1 is worse: it appears both here
// and in the EXISTS comparison, and with no cast the two uses deduce different
// types ("inconsistent types deduced for parameter $1").
const STOCK_INSERT_SQL = `INSERT INTO warehousestock
  ("InventoryDetailsId", "WarehouseId", "CurrentStock", "Warehouse", "Unit")
SELECT $1::varchar, $2::varchar, $3::numeric, $4::varchar, $5::varchar
WHERE EXISTS (SELECT 1 FROM product WHERE "InventoryDetailsId" = $1)`;

/**
 * Port of insert_productwithwarehousestock($dbh), firefly_api.php line 5995.
 *
 * The switch case calls this straight after the product write, unconditionally
 * and in that order -- the order matters, because the insert path only writes
 * stock for a product that already exists.
 */
export async function insertProductWithWarehouseStock(
  fd: FormData,
): Promise<"TRUE" | "FALSE"> {
  try {
    // Kill switch. Exactly 'APP' means the POS owns stock and the ERP sync is
    // skipped; a missing row means 'ERP'. Live MySQL is set to 'APP', so this
    // returns early today -- see db/002_seed_settings.sql.
    const mode = await query<{ value: string | null }>(
      `SELECT "value" FROM settings_common WHERE "key" = 'stock_source' LIMIT 1`,
    );
    const stockMode = mode.rows.length > 0 ? mode.rows[0].value : "ERP";
    if (stockMode === "APP") {
      return "TRUE";
    }

    // PHP json_decodes $_POST['Inventoriesstock']. A missing or malformed value
    // yields null there, foreach warns (suppressed), and the function still
    // returns 'TRUE' -- so a bad blob is not an error, it is a no-op.
    const raw = post(fd, "Inventoriesstock");
    let items: StockItem[] = [];
    if (raw) {
      try {
        const decoded: unknown = JSON.parse(raw);
        if (Array.isArray(decoded)) items = decoded as StockItem[];
      } catch {
        items = [];
      }
    }

    for (const item of items) {
      // phpStr, not String(): PHP binds every item field through
      // PDO::PARAM_STR, which renders true as "1" and false as "".
      const params = [
        phpStr(item.InventoryDetailsId),
        phpStr(item.WarehouseId),
        mysqlNumeric(phpStr(item.Stock)),
        phpStr(item.Warehouse),
        phpStr(item.UnitShortName),
      ];

      await withTransaction(async (client) => {
        const updated = await client.query(STOCK_UPDATE_SQL, params);
        if (!updated.rowCount || updated.rowCount === 0) {
          await client.query(STOCK_INSERT_SQL, params);
        }
      });
    }

    return "TRUE";
  } catch {
    return "FALSE";
  }
}

/*
 * ---------------------------------------------------------------------------
 * The catalogue reads: get_stock and get_product_with_category_withstock.
 *
 * The second is the largest read in the API -- the POS calls it once to fill
 * its whole product grid, ~90 KB in practice -- and it is assembled the way the
 * PHP assembles it: one query for the categories, one for every product across
 * all of them, then the products are grouped onto their category in code
 * (firefly_api.php 4307-4316).
 *
 * Both take an optional WarehouseId, and in both the optional predicate means a
 * second statement rather than string concatenation. For the product query that
 * is not a stylistic choice: the two branches select **different columns** --
 * the no-warehouse one includes p.UnitShortName (4165) and the warehouse one
 * does not (4233) -- so they are genuinely two shapes on the wire.
 *
 * Every `COALESCE(<numeric>, 0)` here carries an explicit cast. MySQL's COALESCE
 * adopts the DECIMAL result type, so on a missed LEFT JOIN it prints
 * "0.00000000"/"0.000"; PostgreSQL takes the integer literal's scale of 0 and
 * prints "0". Measured on both engines. Only the NULL branch differs -- every
 * matched row already agrees -- so the zero literal is typed rather than the
 * whole expression, which would risk the paths that are correct today.
 * ---------------------------------------------------------------------------
 */

const STOCK_SQL = `SELECT ws."InventoryDetailsId", SUM(ws."CurrentStock") AS "Stock"
FROM warehousestock ws
INNER JOIN product p ON p."InventoryDetailsId" = ws."InventoryDetailsId"
INNER JOIN category c ON c."InventoryGroupId" = p."InventoryGroupId"
WHERE c."OrganizationCode" = $1
GROUP BY ws."InventoryDetailsId"`;

const STOCK_BY_WAREHOUSE_SQL = `SELECT ws."InventoryDetailsId", SUM(ws."CurrentStock") AS "Stock"
FROM warehousestock ws
INNER JOIN product p ON p."InventoryDetailsId" = ws."InventoryDetailsId"
INNER JOIN category c ON c."InventoryGroupId" = p."InventoryGroupId"
WHERE c."OrganizationCode" = $1
AND ws."WarehouseId" = $2
GROUP BY ws."InventoryDetailsId"`;

/**
 * Isparent is the string "True" or "False", capital letter included -- not a
 * boolean. It is one of the few EXISTS probes in the file whose result reaches
 * the wire, so the CASE is transcribed rather than collapsed to SELECT EXISTS.
 */
const CATEGORY_SQL = `SELECT mc."InventoryGroupId", mc."GroupName", mc."Colour",
(CASE WHEN EXISTS (
    SELECT 1 FROM category sc WHERE sc."ParentGroup" = mc."InventoryGroupId"
) THEN 'True' ELSE 'False' END) AS "Isparent",
$2::text AS "ThumpnailPath",
$2::text || mc."ImagePath" AS "thumbnail",
$3::text AS "ImagePath",
$3::text || mc."ImagePath" AS "Image",
mc."ImagePath" AS "ImageName"
FROM category mc
WHERE mc."OrganizationCode" = $1`;

/**
 * The stock subquery groups by (InventoryDetailsId, Unit) while the LEFT JOIN
 * keys on InventoryDetailsId alone, so a product stocked under two Units comes
 * back twice. Faithful to the PHP; not deduplicated here.
 */
const PRODUCT_SQL = `SELECT p."InventoryDetailsId", p."InventoryGroupId", p."ProductName", p."ProductRegionalName", p."Code", p."Barcode", p."CustomBarcode", p."HSNCode",
p."UnitShortName", p."Size", p."Colour",
$2::text AS "ProdImagePath",
CASE WHEN p."ImagePath" IS NULL OR TRIM(p."ImagePath") = '' THEN $2::text || 'no_image.jpg' ELSE $2::text || p."ImagePath" END AS "Image",
$3::text AS "ProdThumpnailPath",
CASE WHEN p."ImagePath" IS NULL OR TRIM(p."ImagePath") = '' THEN $3::text || 'no_image.jpg' ELSE $3::text || p."ImagePath" END AS "Thumpnail",
COALESCE(p."ImagePath", '') AS "ImageName",
p."MRP", p."SaleRate", p."MOP", p."MLOP", p."PurchaseRate", p."AvgRate", p."LastPurchaseRate", p."isVeg", p."CurrentStock", p."OrderLimit", p."Description",
p."TaxId", COALESCE(tax."Rate", 0::numeric(10,3)) AS "TaxPercentage", COALESCE(tax."TaxType", '') AS "TaxType",
p."AddTaxId", COALESCE(addtax."Rate", 0::numeric(10,3)) AS "AddTaxPercentage", COALESCE(addtax."TaxType", '') AS "AddTaxType",
p."AddTaxId1", COALESCE(addtax1."Rate", 0::numeric(10,3)) AS "AddTaxPercentage1", COALESCE(addtax1."TaxType", '') AS "AddTaxType1",
COALESCE(stock."Stock", 0::numeric(24,8)) AS "Stock", COALESCE(stock."StockUnit", '') AS "StockUnit"
FROM product p
LEFT JOIN taxdetails tax ON p."TaxId" = tax."TaxId"
LEFT JOIN taxdetails addtax ON p."AddTaxId" = addtax."TaxId"
LEFT JOIN taxdetails addtax1 ON p."AddTaxId1" = addtax1."TaxId"
LEFT JOIN (
    SELECT "InventoryDetailsId",
           SUM("CurrentStock") AS "Stock",
           COALESCE("Unit", '') AS "StockUnit"
    FROM warehousestock
    GROUP BY "InventoryDetailsId", "Unit"
) stock ON stock."InventoryDetailsId" = p."InventoryDetailsId"
INNER JOIN category cat
    ON cat."InventoryGroupId" = p."InventoryGroupId"
    AND cat."OrganizationCode" = $1`;

/** Same as above minus UnitShortName, plus the warehouse filter. */
const PRODUCT_BY_WAREHOUSE_SQL = `SELECT p."InventoryDetailsId", p."InventoryGroupId", p."ProductName", p."ProductRegionalName", p."Code", p."Barcode", p."CustomBarcode", p."HSNCode",
p."Size", p."Colour",
$2::text AS "ProdImagePath",
CASE WHEN p."ImagePath" IS NULL OR TRIM(p."ImagePath") = '' THEN $2::text || 'no_image.jpg' ELSE $2::text || p."ImagePath" END AS "Image",
$3::text AS "ProdThumpnailPath",
CASE WHEN p."ImagePath" IS NULL OR TRIM(p."ImagePath") = '' THEN $3::text || 'no_image.jpg' ELSE $3::text || p."ImagePath" END AS "Thumpnail",
COALESCE(p."ImagePath", '') AS "ImageName",
p."MRP", p."SaleRate", p."MOP", p."MLOP", p."PurchaseRate", p."AvgRate", p."LastPurchaseRate", p."isVeg", p."CurrentStock", p."OrderLimit", p."Description",
p."TaxId", COALESCE(tax."Rate", 0::numeric(10,3)) AS "TaxPercentage", COALESCE(tax."TaxType", '') AS "TaxType",
p."AddTaxId", COALESCE(addtax."Rate", 0::numeric(10,3)) AS "AddTaxPercentage", COALESCE(addtax."TaxType", '') AS "AddTaxType",
p."AddTaxId1", COALESCE(addtax1."Rate", 0::numeric(10,3)) AS "AddTaxPercentage1", COALESCE(addtax1."TaxType", '') AS "AddTaxType1",
COALESCE(stock."Stock", 0::numeric(24,8)) AS "Stock", COALESCE(stock."StockUnit", '') AS "StockUnit"
FROM product p
LEFT JOIN taxdetails tax ON p."TaxId" = tax."TaxId"
LEFT JOIN taxdetails addtax ON p."AddTaxId" = addtax."TaxId"
LEFT JOIN taxdetails addtax1 ON p."AddTaxId1" = addtax1."TaxId"
LEFT JOIN (
    SELECT "InventoryDetailsId",
           SUM("CurrentStock") AS "Stock",
           COALESCE("Unit", '') AS "StockUnit",
           "WarehouseId"
    FROM warehousestock
    GROUP BY "InventoryDetailsId", "Unit", "WarehouseId"
) stock ON stock."InventoryDetailsId" = p."InventoryDetailsId"
   AND stock."WarehouseId" = $4
INNER JOIN category cat
    ON cat."InventoryGroupId" = p."InventoryGroupId"
    AND cat."OrganizationCode" = $1`;

export const cases: Cases = [
  // firefly_api.php lines 344-369. The one case block that turns the sentinel
  // into a real [] rather than the string "EMPTY".
  [
    "get_product_with_category_withstock",
    async (fd) =>
      emptyArrayJson("No Product found!!", async () => {
        const organizationCode = post(fd, "OrganizationCode");
        const warehouseId = post(fd, "WarehouseId");
        const paths = await imagePaths();

        const categories = await query(CATEGORY_SQL, [
          organizationCode,
          paths.CatThumpnailPath,
          paths.CatImagePath,
        ]);
        // PHP returns 'EMPTY' here without ever running the product query.
        if (categories.rows.length === 0) {
          return [];
        }

        const productParams = [
          organizationCode,
          paths.ProdImagePath,
          paths.ProdThumpnailPath,
        ];
        // empty($WarehouseId), so "0" takes the no-warehouse branch.
        const products = isPhpEmpty(warehouseId)
          ? await query(PRODUCT_SQL, productParams)
          : await query(PRODUCT_BY_WAREHOUSE_SQL, [
              ...productParams,
              warehouseId,
            ]);

        const grouped = new Map<unknown, unknown[]>();
        for (const product of products.rows) {
          const bucket = grouped.get(product.InventoryGroupId);
          if (bucket) {
            bucket.push(product);
          } else {
            grouped.set(product.InventoryGroupId, [product]);
          }
        }

        // `products` is assigned onto the category object, so it is the last
        // key of each one, after ImageName. A category with no products gets [].
        return categories.rows.map((category) => ({
          ...category,
          products: grouped.get(category.InventoryGroupId) ?? [],
        }));
      }),
  ],

  // firefly_api.php lines 371-384.
  //
  // The case block is written in the 'EMPTY' sentinel shape, but get_stock
  // returns fetchAll() directly with no sentinel, so `$DATA == $EMPTY` is never
  // evaluated and 'No Stock found!!' at line 376 cannot be reached. Empty
  // answers {"STATUS":"ERROR","MESSAGE":"Something Went Wrong!!!","DATA":[]}.
  [
    "get_stock",
    async (fd) =>
      untouchedDefaultsJson(async () => {
        const organizationCode = post(fd, "OrganizationCode");
        const warehouseId = post(fd, "WarehouseId");
        const result = isPhpEmpty(warehouseId)
          ? await query(STOCK_SQL, [organizationCode])
          : await query(STOCK_BY_WAREHOUSE_SQL, [organizationCode, warehouseId]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 1815-1829. Does not use trueFalseJson: this case
  // combines two actions and also carries the echoed-SQL prefix.
  [
    "insert_productwtimage",
    async (fd) => {
      let STATUS = STATUS_ERROR;
      let MESSAGE = MESSAGE_ERROR;
      let DATA: unknown = null;

      // Both run, in this order, neither guarded by the other's result -- so a
      // failed product write still attempts the stock write, and the stock
      // insert's "product must exist" guard sees the row this line just wrote.
      // There is no transaction across the pair in PHP and none here.
      const ACTION = await insertProductWtImage(fd);
      const ACTION1 = await insertProductWithWarehouseStock(fd);

      if (ACTION.action && ACTION1) {
        if (ACTION.action === FALSE || ACTION1 === FALSE) {
          STATUS = STATUS_ERROR;
          MESSAGE = "Inventory Insertion/Updation Failed!";
          // PHP never assigns DATA on this branch, so it stays null.
        } else {
          STATUS = STATUS_SUCCESS;
          MESSAGE = "Inventory Insertion/Updation Success!";
          DATA = NULL_JSON_ARRAY;
        }
      }

      return phpJson({ STATUS, MESSAGE, DATA }, echoSqlPrefix(ACTION.echo));
    },
  ],

  // firefly_api.php lines 1799-1813. The same helper the case above calls as its
  // second write, exposed on its own so the ERP can push stock without touching
  // the product row -- which is what it does on a stock-only sync.
  //
  // No echoed-SQL prefix here: the unconditional echo lives in
  // insert_productwtimage, not in insert_productwithwarehousestock, so this case
  // returns clean JSON on both stacks. "Succesfully" is misspelled in the PHP.
  [
    "insert_productwithwarehousestock",
    async (fd) =>
      trueFalseJson(
        await insertProductWithWarehouseStock(fd),
        "Product With Warehouse Stock Insertion/Updation Failed!",
        "Product With Warehouse Stock Insertion/Updation Completed Succesfully!",
      ),
  ],
];
