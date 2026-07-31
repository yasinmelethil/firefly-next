import { statusCase } from "@/api/_status";
import type { Cases } from "@/api/_types";
import { query } from "@/lib/db";
import { post } from "@/lib/params";
import { dataArrayJson } from "@/lib/read";

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

export const cases: Cases = [
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
