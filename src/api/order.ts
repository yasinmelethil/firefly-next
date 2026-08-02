import { statusCase } from "@/api/_status";
import type { Cases } from "@/api/_types";
import { query, withTransaction } from "@/lib/db";
import { isPhpEmpty, mysqlInt, mysqlNumeric, phpStr, post } from "@/lib/params";
import {
  dataArrayJson,
  decodeItems,
  emptySentinelJson,
  untouchedDefaultsJson,
} from "@/lib/read";
import {
  STATUS_ERROR,
  STATUS_SUCCESS,
  phpJson,
} from "@/lib/response";
import {
  bumpStartNumber,
  masterIdOf,
  readOrgSeparator,
  voucherNumberOf,
} from "@/lib/voucher";

/*
 * ---------------------------------------------------------------------------
 * get_ordermaster / get_ordercancelmaster, firefly_api.php lines 9532 and 9548.
 *
 * Both are master-plus-details reads driven by the Status filter, and both take
 * the N+1 shape the PHP uses: one query for the masters, then one per master for
 * its lines. Reproduced rather than batched -- PHP has no ORDER BY on either
 * details query, so collapsing them into a single WHERE IN would make the
 * per-master row order engine-determined across the whole batch instead of
 * within one master, which is observable in the response.
 * ---------------------------------------------------------------------------
 */

const ORDER_MASTER_SQL = `SELECT om."OrderMasterId" AS "OrdermstrID", om."OrderDate", om."PartyDetails", om."BillTypeId", om."LedgerId",
COALESCE(lm."LedgerName", '') AS "LedgerName", COALESCE(lm."RegionalName", '') AS "LedgerRegionalName",
om."NoofChair", om."Status", om."TotalAmount", om."CreatedByUser", om."Description"
FROM ordermaster om
LEFT JOIN ledger lm ON lm."LedgerId" = om."LedgerId"
WHERE om."Status" = $1
ORDER BY om."OrderMasterId"`;

// LEFT(...) is spelled the same in both engines. The parent's key is
// "OrderMasterId" but the child names it "ordermstr_id" -- snake_case into
// CamelCase, and only on the order tables.
const ORDER_DETAILS_SQL = `SELECT LEFT(od."InventoryDetailsId", 20) AS "InventoryId", od."InventoryDetailsId", od."UnitId", od."Quantity", od."Rate", od."TotalAmount", od."Description"
FROM orderdetails od WHERE od."ordermstr_id" = $1`;

const CANCEL_MASTER_SQL = `SELECT om."OrderCancelMasterId", om."OrderMasterId" AS "OrdermstrID", om."OrderCancelDate", om."OrderCancelNumber", om."PartyDetails", om."BillTypeId", om."LedgerId",
COALESCE(lm."LedgerName", '') AS "LedgerName", COALESCE(lm."RegionalName", '') AS "LedgerRegionalName",
om."Status", om."TotalAmount", om."CreatedByUser", om."Description"
FROM ordercancelmaster om
LEFT JOIN ledger lm ON lm."LedgerId" = om."LedgerId"
WHERE om."Status" = $1
ORDER BY om."OrderMasterId"`;

const CANCEL_DETAILS_SQL = `SELECT LEFT(od."InventoryDetailsId", 20) AS "InventoryId", od."InventoryDetailsId", od."UnitId", od."Quantity", od."Rate", od."TotalAmount", od."Description"
FROM ordercanceldetails od WHERE od."OrderCancelMasterId" = $1`;

/*
 * ---------------------------------------------------------------------------
 * The POS order reads: what is still uncommitted, one order by number, and the
 * lines of an order. Each comes in a plain and a `_test` flavour; the _test
 * ones are the newer, cancellation-aware variants the POS actually calls.
 *
 * These echo raw rows -- no key rebuild -- so the column lists are the JSON key
 * lists, in this order.
 *
 * Two joins to keep straight, because the plain and _test variants disagree:
 *
 *   - the three get_allnoncommited* use `LEFT JOIN "user"` (9655, 9734, 9831),
 *     so an order outlives its creator;
 *   - both get_ordermasterbynumber* use an INNER `JOIN "user"` (9951, 10026),
 *     so the same order is invisible to a lookup by number.
 *
 * Inconsistent, and reproduced: the two are separate endpoints with separate
 * callers, and "harmonising" them would change what the POS sees.
 * ---------------------------------------------------------------------------
 */

/** The 12 columns every order-master read starts with. */
const ORDER_LIST_COLUMNS = `om."OrderMasterId" AS "OrderMasterId", om."OrderNumber", om."OrderDate", om."PartyDetails", om."BillTypeId", om."LedgerId",
om."NoofChair", om."Status", om."TotalAmount", om."CreatedByUser", us."UserName" AS "CreatedUser", om."Description"`;

/**
 * "this order has not been billed yet", shared by the three get_allnoncommited*.
 *
 * MySQL's FIND_IN_SET(needle, haystack) searches a comma-joined string, which
 * is what salemaster.OrderMasterId is when several orders are merged onto one
 * bill. PostgreSQL has no equivalent; = ANY(string_to_array(...)) is, measured
 * across every edge case that occurs here:
 *
 *   haystack NULL -> both false;  haystack '' -> both false (PostgreSQL's
 *   string_to_array('', ',') is a ZERO-element array, not {''}, and live
 *   salemaster really does hold '' rows);  'a,,b' vs '' -> both true;
 *   'a, b' vs 'b' -> both false, neither trims.
 *
 * One difference, unreachable: MySQL's FIND_IN_SET is case-insensitive under
 * the table collation and PostgreSQL's = is not. Both sides of the comparison
 * are minted by the same masterIdOf(), so their case always agrees.
 *
 * The date bound is FromDate again, not TillDate -- PHP binds :FromDate twice,
 * once as :FromDateBilled (9661), so the "already billed" search starts at the
 * window's open and has no upper bound.
 */
const NOT_YET_BILLED = `NOT EXISTS (
  SELECT 1 FROM salemaster sm
  WHERE sm."VoucherDate" >= $1 AND om."OrderMasterId" = ANY(string_to_array(sm."OrderMasterId", ','))
)`;

const NONCOMMITED_SQL = `SELECT ${ORDER_LIST_COLUMNS}, om."PosMode"
FROM ordermaster om
LEFT JOIN "user" us ON om."CreatedByUser" = us."UserId"
WHERE om."BillTypeId" = $3 AND om."OrderDate" BETWEEN $1 AND $2
AND ${NOT_YET_BILLED}`;

const ORDER_BY_NUMBER_SQL = `SELECT ${ORDER_LIST_COLUMNS}
FROM ordermaster om
JOIN "user" us ON om."CreatedByUser" = us."UserId"
WHERE om."BillTypeId" = $1 AND om."OrderNumber" = $2`;

/**
 * get_allorderDetailsByMasterId, firefly_api.php line 10043.
 *
 * Wider than ORDER_DETAILS_SQL above -- it joins product for the naming
 * columns, and that join is INNER, so a line whose product was deleted vanishes.
 */
const ALL_ORDER_DETAILS_SQL = `SELECT LEFT(od."InventoryDetailsId", 20) AS "InventoryId", od."InventoryDetailsId", p."ProductName", p."ProductRegionalName", p."Code", p."Barcode", p."CustomBarcode", p."HSNCode",
od."UnitId", p."UnitName", p."UnitShortName", p."UnitRegionalName", od."Quantity", od."Rate", od."TotalAmount", od."Description"
FROM orderdetails od JOIN product p ON od."InventoryDetailsId" = p."InventoryDetailsId"
WHERE od."ordermstr_id" = $1`;

/*
 * ---------------------------------------------------------------------------
 * The `_test` variants: the same reads, made cancellation-aware.
 *
 * Four correlated subqueries and one extra filter, repeated verbatim in
 * firefly_api.php across get_allnoncommitedordermaster_test (9678-9752),
 * _test2 (9774-9848) and get_ordermasterbynumber_test (9970-10029). Written
 * once here and interpolated, so a change lands in all three.
 *
 * Every zero literal is typed. MySQL's COALESCE adopts the DECIMAL result type;
 * PostgreSQL takes the integer 0's scale of 0. Measured against live MySQL for
 * an order with no lines:
 *
 *     TotalOrderedQuantity     0.00000000           -> 0::numeric(24,8)
 *     TotalCancelledQuantity   0.00000000           -> 0::numeric(24,8)
 *     NetTotalAmount           0.0000000000000000   -> 0::numeric(38,16)
 *
 * NetTotalAmount lands on scale 16 because it sums a product of two scale-8
 * decimals, and both engines add the operands' scales when multiplying. The
 * bare literal would have shipped "0" for all three.
 *
 * TotalCancelledQuantity's zero is reached by any order nobody cancelled from,
 * which is most of them. TotalOrderedQuantity's and NetTotalAmount's need an
 * order with no lines at all -- unreachable in the two list endpoints, whose
 * EXISTS filter drops such orders, but reachable in get_ordermasterbynumber_test,
 * which has no such filter.
 * ---------------------------------------------------------------------------
 */

/** How much of one order line has been cancelled. Keyed on od.orderdtl_id. */
const CANCELLED_FOR_LINE = `COALESCE((
        SELECT SUM(odc."Quantity")
        FROM ordercanceldetails odc
        WHERE odc."OrderDetailsId" = od."orderdtl_id"
    ), 0::numeric(24,8))`;

const TOTAL_ORDERED = `COALESCE((
        SELECT SUM(od."Quantity")
        FROM orderdetails od
        WHERE od."ordermstr_id" = om."OrderMasterId"
    ), 0::numeric(24,8))`;

// Note the join back through orderdetails: ordercanceldetails knows its line but
// not its order, and OrderDetailsId is an integer -- the one integer reference
// in a schema that otherwise joins on opaque strings.
const TOTAL_CANCELLED = `COALESCE((
        SELECT SUM(odc."Quantity")
        FROM ordercanceldetails odc
        JOIN orderdetails od ON odc."OrderDetailsId" = od."orderdtl_id"
        WHERE od."ordermstr_id" = om."OrderMasterId"
    ), 0::numeric(24,8))`;

const NET_TOTAL = `COALESCE((
        SELECT SUM((od."Quantity" - ${CANCELLED_FOR_LINE}) * od."Rate")
        FROM orderdetails od
        WHERE od."ordermstr_id" = om."OrderMasterId"
    ), 0::numeric(38,16))`;

// Note FULL uses >= rather than =, so over-cancelling still reads as FULL.
const CANCEL_STATUS = `CASE
        WHEN ${TOTAL_CANCELLED} = 0 THEN 'NONE'
        WHEN ${TOTAL_CANCELLED} >= ${TOTAL_ORDERED} THEN 'FULL'
        ELSE 'PARTIAL'
    END`;

const COMPUTED_COLUMNS = `${TOTAL_ORDERED} AS "TotalOrderedQuantity",
${TOTAL_CANCELLED} AS "TotalCancelledQuantity",
${NET_TOTAL} AS "NetTotalAmount",
${CANCEL_STATUS} AS "CancelStatus"`;

/** Drops a fully-cancelled order from the list. Only the list variants use it. */
const HAS_UNCANCELLED_LINE = `EXISTS (
    SELECT 1
    FROM orderdetails od
    WHERE od."ordermstr_id" = om."OrderMasterId"
      AND od."Quantity" > ${CANCELLED_FOR_LINE}
)`;

// Same as NONCOMMITED_SQL but without PosMode, plus the computed columns, the
// fully-cancelled filter and an ORDER BY.
const NONCOMMITED_TEST_SQL = `SELECT ${ORDER_LIST_COLUMNS},
${COMPUTED_COLUMNS}
FROM ordermaster om
LEFT JOIN "user" us ON om."CreatedByUser" = us."UserId"
WHERE om."BillTypeId" = $3 AND om."OrderDate" BETWEEN $1 AND $2
AND ${NOT_YET_BILLED}
AND ${HAS_UNCANCELLED_LINE}
ORDER BY om."OrderDate" DESC`;

// _test2 is _test with the BillTypeId filter dropped -- and PosMode put back.
const NONCOMMITED_TEST2_SQL = `SELECT ${ORDER_LIST_COLUMNS}, om."PosMode",
${COMPUTED_COLUMNS}
FROM ordermaster om
LEFT JOIN "user" us ON om."CreatedByUser" = us."UserId"
WHERE om."OrderDate" BETWEEN $1 AND $2
AND ${NOT_YET_BILLED}
AND ${HAS_UNCANCELLED_LINE}
ORDER BY om."OrderDate" DESC`;

const ORDER_BY_NUMBER_TEST_SQL = `SELECT ${ORDER_LIST_COLUMNS},
${COMPUTED_COLUMNS}
FROM ordermaster om
JOIN "user" us ON om."CreatedByUser" = us."UserId"
WHERE om."BillTypeId" = $1 AND om."OrderNumber" = $2`;

/**
 * get_allorderDetailsByMasterId_test, firefly_api.php line 10054.
 *
 * Quantity is redefined as ordered-minus-cancelled and the original moves to
 * OriginalQuantity, so the POS can reopen a partly-cancelled KOT and see what
 * is left.
 *
 * The PHP filters it with `HAVING Quantity > 0` and no GROUP BY, which MySQL
 * evaluates row-wise against the SELECT *alias*. PostgreSQL cannot: a HAVING
 * without GROUP BY collapses the query to a single aggregate group, and HAVING
 * cannot see output aliases at all. Hence the subquery wrap, with the filter
 * moved to an outer WHERE.
 *
 * `SELECT *` on the wrapper is load-bearing -- it preserves the inner column
 * order, which is the JSON key order. And ORDER BY od.orderdtl_id survives as
 * t."OrderDetailsId", the alias that same column already carries.
 */
const ALL_ORDER_DETAILS_TEST_SQL = `SELECT * FROM (
SELECT LEFT(od."InventoryDetailsId", 20) AS "InventoryId", od."InventoryDetailsId", od."orderdtl_id" AS "OrderDetailsId",
p."ProductName", p."ProductRegionalName", p."Code", p."Barcode", p."CustomBarcode", p."HSNCode",
od."UnitId", p."UnitName", p."UnitShortName", p."UnitRegionalName",
od."Quantity" AS "OriginalQuantity",
${CANCELLED_FOR_LINE} AS "CancelledQuantity",
(od."Quantity" - ${CANCELLED_FOR_LINE}) AS "Quantity",
od."Rate",
((od."Quantity" - ${CANCELLED_FOR_LINE}) * od."Rate") AS "TotalAmount",
od."Description"
FROM orderdetails od
JOIN product p ON od."InventoryDetailsId" = p."InventoryDetailsId"
WHERE od."ordermstr_id" = $1
) t
WHERE t."Quantity" > 0
ORDER BY t."OrderDetailsId"`;

/*
 * ---------------------------------------------------------------------------
 * insert_orderbybilltype, firefly_api.php line 7642.
 *
 * Saves a KOT: upsert the master, replace all its lines, hand the number series
 * on. One transaction around the lot, and two details that look like bugs and
 * are not:
 *
 *   1. The master is written Status='P' and only flipped to 'N' after every
 *      line has landed (7684 -> 7815). 'N' is what the ERP's sync loop polls
 *      for, so the two-phase write is what stops it pulling a half-written
 *      order. Keep both statements.
 *   2. On the UPDATE path the response carries id="" and voucherNumber="":
 *      $lastInsertedId is only assigned inside the INSERT branch (7783) and
 *      $VoucherNumber is only built there. The POS already knows both for an
 *      order it is editing, so nothing reads them.
 * ---------------------------------------------------------------------------
 */

/** What the PHP helper returns: an object, never a bare 'TRUE'/'FALSE' string. */
type OrderWriteResult =
  | { status: "TRUE"; id: string; voucherNumber: string }
  | { status: "FALSE" };

const ORDER_UPDATE_SQL = `UPDATE ordermaster SET
"LedgerId" = $1, "OrderDate" = $2, "PartyDetails" = $3, "NoofChair" = $4,
"Status" = 'P',
"CreatedByUser" = $5, "CreatedTimeStamp" = $6, "TotalAmount" = $7, "Description" = $8,
"PosMode" = COALESCE(NULLIF($9::text, ''), "PosMode")
WHERE "OrderMasterId" = $10`;

const ORDER_DETAILS_DELETE_SQL = `DELETE FROM orderdetails WHERE "ordermstr_id" = $1`;

const BILLTYPE_SERIES_SQL = `SELECT "Prefix", "Suffix", "StartNumber" FROM billtype WHERE "BillTypeId" = $1 LIMIT 1`;

// COALESCE(...,0), not 1 -- insert_ordercancelbybilltype and
// insert_salebybilltypewithpdc both default to 1 instead. Preserved per-endpoint.
const ORDER_NEXT_AUTOID_SQL = `SELECT COALESCE(MAX("AUTOID") + 1, 0) AS "MaxId" FROM ordermaster WHERE "BillTypeId" = $1`;

const ORDER_INSERT_SQL = `INSERT INTO ordermaster
("AUTOID", "OrganizationCode", "BillTypeId", "OrderDate", "OrderMasterId", "OrderNumber",
 "LedgerId", "PartyDetails", "NoofChair", "Status", "CreatedByUser", "TotalAmount",
 "Description", "PosMode", "CreatedTimeStamp")
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'P', $10, $11, $12, $13, $14)`;

const PRODUCT_UNIT_SQL = `SELECT "UnitId" FROM product WHERE "InventoryDetailsId" = $1`;

const ORDER_DETAIL_INSERT_SQL = `INSERT INTO orderdetails
("ordermstr_id", "InventoryDetailsId", "UnitId", "Quantity", "Rate", "TotalAmount",
 "CreatedByUser", "Description", "CreatedTimeStamp")
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`;

const ORDER_READY_SQL = `UPDATE ordermaster SET "Status" = 'N' WHERE "OrderMasterId" = $1`;

/** One entry of the OrderDetails JSON array. */
interface OrderDetailItem {
  InventoryDetailsId?: unknown;
  Quantity?: unknown;
  Rate?: unknown;
  DetailsTotalAmount?: unknown;
  Description?: unknown;
}

export async function insertOrderByBillType(
  fd: FormData,
): Promise<OrderWriteResult> {
  // Unguarded $_POST reads in the PHP, so a missing field is null and hits the
  // NOT NULL column -- the same failure MySQL gives. Only PosMode has a ?? ''.
  const OrderMasterIdPosted = post(fd, "OrderMasterId");
  const OrderDate = post(fd, "OrderDate");
  const LedgerId = post(fd, "LedgerId");
  const PartyDetails = post(fd, "PartyDetails");
  const NoofChair = mysqlInt(post(fd, "NoofChair")); // int(11)
  const CreatedByUser = post(fd, "CreatedByUser");
  const TotalAmount = mysqlNumeric(post(fd, "TotalAmount")); // decimal(24,8)
  const BillTypeId = post(fd, "BillTypeId");
  const Description = post(fd, "Description");
  const CreatedTimeStamp = post(fd, "CreatedTimeStamp");
  const PosMode = post(fd, "PosMode") ?? "";

  try {
    return await withTransaction(async (client) => {
      const { OrganizationCode, Separator } = await readOrgSeparator(client);

      let OrderMasterId = OrderMasterIdPosted;
      let lastInsertedId = "";
      let VoucherNumber = "";

      if (!isPhpEmpty(OrderMasterId)) {
        await client.query(ORDER_UPDATE_SQL, [
          LedgerId,
          OrderDate,
          PartyDetails,
          NoofChair,
          CreatedByUser,
          CreatedTimeStamp,
          TotalAmount,
          Description,
          PosMode,
          OrderMasterId,
        ]);
        await client.query(ORDER_DETAILS_DELETE_SQL, [OrderMasterId]);
      } else {
        const series = await client.query(BILLTYPE_SERIES_SQL, [BillTypeId]);
        const row = series.rows[0];
        // PHP casts with (int), which turns a missing billtype row into 0.
        const StartNumber = Number(row?.StartNumber ?? 0);

        const next = await client.query(ORDER_NEXT_AUTOID_SQL, [BillTypeId]);
        const NextOrderId = Number(next.rows[0]?.MaxId ?? 0);

        // The series never goes backwards, whichever source is further ahead.
        const MaxId = Math.max(StartNumber, NextOrderId);

        VoucherNumber = voucherNumberOf(
          row?.Prefix ?? null,
          row?.Suffix ?? null,
          Separator,
          MaxId,
        );
        OrderMasterId = masterIdOf(BillTypeId ?? "", MaxId);

        await client.query(ORDER_INSERT_SQL, [
          MaxId,
          // Interpolated into the SQL text in PHP, so a missing organization
          // row writes '' rather than failing the NOT NULL column.
          OrganizationCode,
          BillTypeId,
          OrderDate,
          OrderMasterId,
          VoucherNumber,
          LedgerId,
          PartyDetails,
          NoofChair,
          CreatedByUser,
          TotalAmount,
          Description,
          PosMode,
          CreatedTimeStamp,
        ]);

        await bumpStartNumber(client, BillTypeId, MaxId + 1);
        lastInsertedId = OrderMasterId;
      }

      // json_decode of a missing payload gives null, and PHP's foreach over
      // null only warns -- so no lines is a no-op, not a failure.
      for (const item of decodeItems<OrderDetailItem>(post(fd, "OrderDetails"))) {
        const InventoryDetailsId = phpStr(item.InventoryDetailsId);
        const unit = await client.query(PRODUCT_UNIT_SQL, [InventoryDetailsId]);
        // No row means null into a NOT NULL column, exactly as in PHP.
        const UnitId = unit.rows[0]?.UnitId ?? null;

        await client.query(ORDER_DETAIL_INSERT_SQL, [
          OrderMasterId,
          InventoryDetailsId,
          UnitId,
          mysqlNumeric(phpStr(item.Quantity)),
          mysqlNumeric(phpStr(item.Rate)),
          mysqlNumeric(phpStr(item.DetailsTotalAmount)),
          CreatedByUser,
          phpStr(item.Description),
          CreatedTimeStamp,
        ]);
      }

      // Only now is the order visible to the sync loop.
      await client.query(ORDER_READY_SQL, [OrderMasterId]);

      return { status: "TRUE", id: lastInsertedId, voucherNumber: VoucherNumber };
    });
  } catch {
    // PHP returns an object carrying nothing but the status; the case block
    // then discards it and sends DATA: null.
    return { status: "FALSE" };
  }
}

/*
 * ---------------------------------------------------------------------------
 * insert_ordercancelbybilltype, firefly_api.php line 7835.
 *
 * Records the lines struck off a KOT. Structurally the sibling of
 * insert_orderbybilltype, and different from it in six places that all look
 * like drift and are all preserved:
 *
 *   1. Every $_POST read carries `?? ''` (7846-7856), so a missing field binds
 *      the empty string instead of null -- this endpoint does not fail on a
 *      partial payload the way the order and sale inserts do.
 *   2. No two-phase status. Status is 'N' from the first write on both paths;
 *      there is no 'P' and no mark-ready at the end.
 *   3. The UPDATE path *does* set lastInsertedId (7924), so it answers with a
 *      real id and an empty voucherNumber. insert_orderbybilltype returns both
 *      empty.
 *   4. MaxId starts from StartNumber `?? 1` and is then forced to 1 by an
 *      empty() test (7948-7952), so a StartNumber of 0 becomes 1. The order
 *      insert takes max(StartNumber, MAX(AUTOID)+1) with a 0 floor, and the
 *      sale insert uses is_null. Three endpoints, three rules.
 *   5. It probes for a colliding id first and only then falls back to
 *      MAX(AUTOID)+1, rather than always taking the larger.
 *   6. OrganizationCode is a bound parameter here (8048), not interpolated
 *      into the SQL text.
 *
 * It is also the only one of the three whose failure message is the driver's
 * exception text, so its error body differs from PHP's in the tail -- the same
 * documented divergence the README records for the pilot endpoints.
 * ---------------------------------------------------------------------------
 */

const CANCEL_UPDATE_SQL = `UPDATE ordercancelmaster SET
"OrderMasterId" = $1, "LedgerId" = $2, "OrderCancelDate" = $3, "PartyDetails" = $4,
"Status" = 'N',
"CreatedByUser" = $5, "CreatedTimeStamp" = $6, "TotalAmount" = $7, "Description" = $8
WHERE "OrderCancelMasterId" = $9`;

const CANCEL_DETAILS_DELETE_SQL = `DELETE FROM ordercanceldetails WHERE "OrderCancelMasterId" = $1`;

// PHP writes SELECT IF(EXISTS(...),'true','false'); the boolean never reaches
// the wire, so it stays a boolean here.
const CANCEL_ID_TAKEN_SQL = `SELECT EXISTS (
    SELECT 1 FROM ordercancelmaster WHERE "OrderCancelMasterId" = $1
) AS "IsUpdate"`;

const CANCEL_NEXT_AUTOID_SQL = `SELECT COALESCE(MAX("AUTOID") + 1, 1) AS "MaxId" FROM ordercancelmaster WHERE "BillTypeId" = $1`;

const CANCEL_INSERT_SQL = `INSERT INTO ordercancelmaster
("AUTOID", "OrganizationCode", "BillTypeId", "OrderCancelDate", "OrderCancelMasterId",
 "OrderMasterId", "OrderCancelNumber", "LedgerId", "PartyDetails", "Status",
 "CreatedByUser", "TotalAmount", "Description", "CreatedTimeStamp")
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'N', $10, $11, $12, $13)`;

const CANCEL_DETAIL_INSERT_SQL = `INSERT INTO ordercanceldetails
("OrderCancelMasterId", "OrderDetailsId", "InventoryDetailsId", "UnitId", "Quantity",
 "Rate", "TotalAmount", "CreatedByUser", "Description", "CreatedTimeStamp")
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`;

/** One entry of the OrderCancelDetails JSON array. */
interface OrderCancelDetailItem {
  InventoryDetailsId?: unknown;
  OrderDetailsId?: unknown;
  UnitId?: unknown;
  Quantity?: unknown;
  Rate?: unknown;
  DetailsTotalAmount?: unknown;
  Description?: unknown;
}

/**
 * `json_decode($OrderCancelDetails, true)` plus the `!is_array` guard at 8089.
 *
 * Not decodeItems: this endpoint *throws* on a malformed payload where the
 * others treat it as a no-op. And PHP's assoc decode turns a JSON object into
 * an array too, which is_array accepts and foreach then walks the values of --
 * so an object is iterated rather than rejected. Only a scalar, null, or
 * unparseable text reaches the throw.
 */
function decodeCancelDetails(raw: string): OrderCancelDetailItem[] {
  let decoded: unknown;
  try {
    decoded = JSON.parse(raw);
  } catch {
    throw new Error("Invalid OrderCancelDetails JSON");
  }
  if (Array.isArray(decoded)) return decoded as OrderCancelDetailItem[];
  if (decoded !== null && typeof decoded === "object") {
    return Object.values(decoded) as OrderCancelDetailItem[];
  }
  throw new Error("Invalid OrderCancelDetails JSON");
}

/** PHP's date('Y-m-d H:i:s') -- server-local, no timezone, second precision. */
function nowLocalTimestamp(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

/** The FALSE object here carries the exception text; the case block reads it. */
type CancelWriteResult =
  | { status: "TRUE"; id: string; voucherNumber: string }
  | { status: "FALSE"; message: string };

export async function insertOrderCancelByBillType(
  fd: FormData,
): Promise<CancelWriteResult> {
  const OrderCancelMasterIdPosted = post(fd, "OrderCancelMasterId") ?? "";
  const OrderMasterId = post(fd, "OrderMasterId") ?? "";
  const OrderCancelDate = post(fd, "OrderCancelDate") ?? "";
  const LedgerId = post(fd, "LedgerId") ?? "";
  const PartyDetails = post(fd, "PartyDetails") ?? "";
  const CreatedByUser = post(fd, "CreatedByUser") ?? "";
  // PHP's default is the integer 0, which PDO binds as the string "0".
  const TotalAmount = mysqlNumeric(post(fd, "TotalAmount") ?? "0");
  const BillTypeId = post(fd, "BillTypeId") ?? "";
  const Description = post(fd, "Description") ?? "";
  const CreatedTimeStamp = post(fd, "CreatedTimeStamp") ?? nowLocalTimestamp();
  const OrderCancelDetailsRaw = post(fd, "OrderCancelDetails") ?? "[]";

  try {
    return await withTransaction(async (client) => {
      const { OrganizationCode, Separator } = await readOrgSeparator(client);

      let OrderCancelMasterId = OrderCancelMasterIdPosted;
      let lastInsertedId = "";
      let VoucherNumber = "";

      if (!isPhpEmpty(OrderCancelMasterId)) {
        await client.query(CANCEL_UPDATE_SQL, [
          OrderMasterId,
          LedgerId,
          OrderCancelDate,
          PartyDetails,
          CreatedByUser,
          CreatedTimeStamp,
          TotalAmount,
          Description,
          OrderCancelMasterId,
        ]);
        await client.query(CANCEL_DETAILS_DELETE_SQL, [OrderCancelMasterId]);
        lastInsertedId = OrderCancelMasterId;
      } else {
        const series = await client.query(BILLTYPE_SERIES_SQL, [BillTypeId]);
        const row = series.rows[0];
        // `?? 1` then an empty() test, so 0 and null both land on 1.
        let MaxId = Number(row?.StartNumber ?? 1);
        if (isPhpEmpty(MaxId)) {
          MaxId = 1;
        }

        const taken = await client.query(CANCEL_ID_TAKEN_SQL, [
          masterIdOf(BillTypeId, MaxId),
        ]);
        if (taken.rows[0]?.IsUpdate) {
          const next = await client.query(CANCEL_NEXT_AUTOID_SQL, [BillTypeId]);
          MaxId = Number(next.rows[0]?.MaxId ?? 1);
        }

        VoucherNumber = voucherNumberOf(
          row?.Prefix ?? "",
          row?.Suffix ?? "",
          Separator,
          MaxId,
        );
        OrderCancelMasterId = masterIdOf(BillTypeId, MaxId);

        await client.query(CANCEL_INSERT_SQL, [
          MaxId,
          OrganizationCode,
          BillTypeId,
          OrderCancelDate,
          OrderCancelMasterId,
          OrderMasterId,
          VoucherNumber,
          LedgerId,
          PartyDetails,
          CreatedByUser,
          TotalAmount,
          Description,
          CreatedTimeStamp,
        ]);

        await bumpStartNumber(client, BillTypeId, MaxId + 1);
        lastInsertedId = OrderCancelMasterId;
      }

      for (const item of decodeCancelDetails(OrderCancelDetailsRaw)) {
        const InventoryDetailsId = phpStr(item.InventoryDetailsId) ?? "";
        let UnitId = phpStr(item.UnitId) ?? "";
        // Looked up only when the payload omitted it -- and a product that does
        // not exist leaves '' here, not null, so the write still succeeds.
        if (isPhpEmpty(UnitId)) {
          const unit = await client.query(PRODUCT_UNIT_SQL, [
            InventoryDetailsId,
          ]);
          UnitId = unit.rows[0]?.UnitId ?? "";
        }

        await client.query(CANCEL_DETAIL_INSERT_SQL, [
          OrderCancelMasterId,
          // int(11): PHP defaults this to '' and MySQL coerces that to 0.
          mysqlInt(phpStr(item.OrderDetailsId) ?? ""),
          InventoryDetailsId,
          UnitId,
          mysqlNumeric(phpStr(item.Quantity) ?? "0"),
          mysqlNumeric(phpStr(item.Rate) ?? "0"),
          mysqlNumeric(phpStr(item.DetailsTotalAmount) ?? "0"),
          CreatedByUser,
          phpStr(item.Description) ?? "",
          CreatedTimeStamp,
        ]);
      }

      return { status: "TRUE", id: lastInsertedId, voucherNumber: VoucherNumber };
    });
  } catch (e) {
    return {
      status: "FALSE",
      message: e instanceof Error ? e.message : String(e),
    };
  }
}

export const cases: Cases = [
  // firefly_api.php lines 752-764.
  [
    "get_allnoncommitedordermaster",
    async (fd) =>
      emptySentinelJson("No Orders found!!", async () => {
        const result = await query(NONCOMMITED_SQL, [
          post(fd, "FromDate"),
          post(fd, "TillDate"),
          post(fd, "BillTypeId"),
        ]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 766-778. Same empty message as the plain variant.
  [
    "get_allnoncommitedordermaster_test",
    async (fd) =>
      emptySentinelJson("No Orders found!!", async () => {
        const result = await query(NONCOMMITED_TEST_SQL, [
          post(fd, "FromDate"),
          post(fd, "TillDate"),
          post(fd, "BillTypeId"),
        ]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 780-792. No BillTypeId: every till at once.
  [
    "get_allnoncommitedordermaster_test2",
    async (fd) =>
      emptySentinelJson("No Orders found!!", async () => {
        const result = await query(NONCOMMITED_TEST2_SQL, [
          post(fd, "FromDate"),
          post(fd, "TillDate"),
        ]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 864-876.
  [
    "get_ordermasterbynumber",
    async (fd) =>
      emptySentinelJson("No Orders found!!", async () => {
        const result = await query(ORDER_BY_NUMBER_SQL, [
          post(fd, "BillTypeId"),
          post(fd, "OrderNumber"),
        ]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 879-891.
  //
  // Unlike the two list variants this has no "still has an uncancelled line"
  // filter, so a fully-cancelled order still comes back -- with CancelStatus
  // 'FULL' and NetTotalAmount 0. That is how the POS tells the difference
  // between an order that was cancelled and one that never existed.
  [
    "get_ordermasterbynumber_test",
    async (fd) =>
      emptySentinelJson("No Orders found!!", async () => {
        const result = await query(ORDER_BY_NUMBER_TEST_SQL, [
          post(fd, "BillTypeId"),
          post(fd, "OrderNumber"),
        ]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 894-906.
  //
  // No 'EMPTY' sentinel in the getter, so an order with no lines answers
  // {"STATUS":"ERROR","MESSAGE":"Something Went Wrong!!!","DATA":[]} and
  // 'No Order Details found!!' at line 899 is unreachable.
  [
    "get_allorderDetailsByMasterId",
    async (fd) =>
      untouchedDefaultsJson(async () => {
        const result = await query(ALL_ORDER_DETAILS_SQL, [
          post(fd, "OrderMasterId"),
        ]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 908-920. Same missing sentinel as the plain variant,
  // and here the filter makes an empty result routine: cancel every line of an
  // order and this returns [] with STATUS ERROR.
  [
    "get_allorderDetailsByMasterId_test",
    async (fd) =>
      untouchedDefaultsJson(async () => {
        const result = await query(ALL_ORDER_DETAILS_TEST_SQL, [
          post(fd, "OrderMasterId"),
        ]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 2348-2376.
  //
  // PartyDetails and LedgerRegionalName are selected and then dropped by the
  // case, so they never reach the wire. Details come back as whole rows, and an
  // order with no lines gets [] -- the detail fetchers return fetchAll()
  // directly, with none of the 'EMPTY' sentinel behaviour the masters have.
  [
    "get_ordermaster",
    async (fd) =>
      dataArrayJson(async () => {
        const masters = await query(ORDER_MASTER_SQL, [post(fd, "Status")]);
        const items = [];
        for (const item of masters.rows) {
          const details = await query(ORDER_DETAILS_SQL, [item.OrdermstrID]);
          items.push({
            OrdermstrID: item.OrdermstrID,
            OrderDate: item.OrderDate,
            BillTypeId: item.BillTypeId,
            LedgerId: item.LedgerId,
            LedgerName: item.LedgerName,
            NoofChair: item.NoofChair,
            Status: item.Status,
            TotalAmount: item.TotalAmount,
            CreatedByUser: item.CreatedByUser,
            Description: item.Description,
            OrderDetails: details.rows,
          });
        }
        return items;
      }),
  ],

  // firefly_api.php lines 2380-2409.
  //
  // Three things to preserve:
  //
  //   1. NoofChair is emitted but ordercancelmaster has no such column and the
  //      SELECT never fetches one. In PHP that reads a missing property off a
  //      stdClass, which error_reporting(0) turns into a silent null. So the key
  //      is present and always null -- hardcoded here rather than looked up.
  //   2. The details are keyed off OrderCancelMasterId, not OrdermstrID.
  //   3. OrderDate is the OrderCancelDate column renamed, and both
  //      OrderCancelNumber and PartyDetails are selected then dropped.
  [
    "get_ordercancelmaster",
    async (fd) =>
      dataArrayJson(async () => {
        const masters = await query(CANCEL_MASTER_SQL, [post(fd, "Status")]);
        const items = [];
        for (const item of masters.rows) {
          const details = await query(CANCEL_DETAILS_SQL, [
            item.OrderCancelMasterId,
          ]);
          items.push({
            OrdermstrID: item.OrdermstrID,
            OrderCancelMasterID: item.OrderCancelMasterId,
            OrderDate: item.OrderCancelDate,
            BillTypeId: item.BillTypeId,
            LedgerId: item.LedgerId,
            LedgerName: item.LedgerName,
            NoofChair: null,
            Status: item.Status,
            TotalAmount: item.TotalAmount,
            CreatedByUser: item.CreatedByUser,
            Description: item.Description,
            OrderDetails: details.rows,
          });
        }
        return items;
      }),
  ],

  // firefly_api.php lines 953-967.
  //
  // On success DATA is the whole result object; on failure PHP never assigns
  // DATA, so it stays null and the FALSE object is not passed through. Note
  // "Succesfully" -- one 's' -- in the success message.
  [
    "insert_orderbybilltype",
    async (fd) => {
      const ACTION = await insertOrderByBillType(fd);
      if (ACTION.status === "FALSE") {
        return phpJson({
          STATUS: STATUS_ERROR,
          MESSAGE: "Adding New Order Failed!",
          DATA: null,
        });
      }
      return phpJson({
        STATUS: STATUS_SUCCESS,
        MESSAGE: "Added New Order Succesfully!",
        DATA: ACTION,
      });
    },
  ],

  // firefly_api.php lines 970-1003.
  //
  // Two differences from insert_orderbybilltype's case block: DATA carries the
  // result object on the failure path too, and the failure MESSAGE is the
  // exception text when there is one. "Successfully" is spelled correctly here
  // and misspelled in the order case -- both verbatim.
  [
    "insert_ordercancelbybilltype",
    async (fd) => {
      const ACTION = await insertOrderCancelByBillType(fd);
      if (ACTION.status === "FALSE") {
        return phpJson({
          STATUS: STATUS_ERROR,
          MESSAGE: isPhpEmpty(ACTION.message)
            ? "Adding New Order Failed!"
            : ACTION.message,
          DATA: ACTION,
        });
      }
      return phpJson({
        STATUS: STATUS_SUCCESS,
        MESSAGE: "Added New Order Successfully!",
        DATA: ACTION,
      });
    },
  ],

  // firefly_api.php lines 3000-3014 and 3016-3030. Both read the same POST
  // field, ordermstr_id, even though the second one keys on OrderCancelMasterId.
  statusCase(
    "update_orderStatus",
    `UPDATE ordermaster SET "Status" = 'K' WHERE "OrderMasterId" = $1`,
    "ordermstr_id",
  ),
  statusCase(
    "update_ordercancelStatus",
    `UPDATE ordercancelmaster SET "Status" = 'K' WHERE "OrderCancelMasterId" = $1`,
    "ordermstr_id",
  ),
];
