import { statusCase } from "@/api/_status";
import type { Cases } from "@/api/_types";
import { query } from "@/lib/db";
import { post } from "@/lib/params";
import { dataArrayJson } from "@/lib/read";

/*
 * ---------------------------------------------------------------------------
 * get_purchaseordermasterforFireFly, firefly_api.php line 2938.
 *
 * No function of that name exists. The case calls get_purchaseordermaster
 * (line 10153) -- the same master query the plain get_purchaseordermaster case
 * uses -- and swaps in get_purchaseorderDetailsByMasterIdForFireFly (line 10192)
 * for the lines. That swap is the whole difference between the two endpoints:
 *
 *   plain     returns both "OrderQuantity" and "UpdatedQuantity", every line
 *   ForFireFly returns "UpdatedQuantity" aliased to "Quantity", and only lines
 *              where it is > 0
 *
 * So the FireFly variant hides lines that were zeroed out during goods receipt
 * and presents the received quantity under the same key the order and sale
 * endpoints use. Both behaviours are load-bearing; this module ports only the
 * FireFly variant.
 *
 * Column-name landmine: purchaseordermaster's primary key is "ordermasterId" --
 * lowercase o, capital I -- where every sibling table has "OrderMasterId". Live
 * MySQL declares it that way too; the PHP writes OrderMasterId in both the SELECT
 * and update_purchaseorderStatus and only works because MySQL folds case.
 * PostgreSQL does not, so both statements below use the real spelling. This needs
 * no entry in compare-schema.ps1's $Renames: the SELECT aliases the column to
 * "OrdermstrID" and the UPDATE only names it in a WHERE clause, so the declared
 * spelling never reaches the wire and nothing observable changes.
 * ---------------------------------------------------------------------------
 */

const PO_MASTER_SQL = `SELECT om."ordermasterId" AS "OrdermstrID", om."OrderDate", om."PartyDetails", om."BillTypeId", om."LedgerId",
COALESCE(lm."LedgerName", '') AS "LedgerName", COALESCE(lm."RegionalName", '') AS "LedgerRegionalName",
om."Status", om."TotalAmount", om."CreatedByUser", om."Description"
FROM purchaseordermaster om
LEFT JOIN ledger lm ON lm."LedgerId" = om."LedgerId"
WHERE om."Status" = $1
ORDER BY om."ordermasterId"`;

// The details table calls its parent key "ordermstr_id" -- snake_case, and a
// third spelling of the same id within one endpoint. The UpdatedQuantity > 0
// filter and the Quantity alias are what make this the FireFly variant.
const PO_DETAILS_SQL = `SELECT LEFT(od."InventoryDetailsId", 20) AS "InventoryId", od."InventoryDetailsId", od."UnitId", od."UpdatedQuantity" AS "Quantity", od."Rate", od."TotalAmount", od."Description"
FROM purchaseorderdetails od WHERE od."ordermstr_id" = $1 AND od."UpdatedQuantity" > 0`;

export const cases: Cases = [
  // firefly_api.php lines 2938-2966. PartyDetails and LedgerRegionalName are
  // selected then dropped, as in every other master read.
  [
    "get_purchaseordermasterforFireFly",
    async (fd) =>
      dataArrayJson(async () => {
        const masters = await query(PO_MASTER_SQL, [post(fd, "Status")]);
        const items = [];
        for (const item of masters.rows) {
          const details = await query(PO_DETAILS_SQL, [item.OrdermstrID]);
          items.push({
            OrdermstrID: item.OrdermstrID,
            OrderDate: item.OrderDate,
            BillTypeId: item.BillTypeId,
            LedgerId: item.LedgerId,
            LedgerName: item.LedgerName,
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

  // firefly_api.php lines 3159-3173.
  statusCase(
    "update_purchaseorderStatus",
    `UPDATE purchaseordermaster SET "Status" = 'K' WHERE "ordermasterId" = $1`,
    "ordermstr_id",
  ),
];
