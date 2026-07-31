import { statusCase } from "@/api/_status";
import type { Cases } from "@/api/_types";
import { pdcDetailsByReferenceId } from "@/api/pdc";
import { query } from "@/lib/db";
import { post } from "@/lib/params";
import { dataArrayJson } from "@/lib/read";

/*
 * ---------------------------------------------------------------------------
 * get_salemaster / get_salereturnmaster, firefly_api.php lines 10219 and 10392.
 *
 * The heaviest reads in the API: three queries per master -- the master row, its
 * lines, and the cheques attached to it -- so get_salemaster issues up to 201
 * round trips for its 100 masters. Reproduced as-is; see order.ts for why the
 * details are not batched.
 *
 * The two are near-twins with three differences that matter, all of them easy to
 * get backwards:
 *
 *   - the return lives in `salereturn` (no underscore, no "master" suffix) and
 *     its lines in `salesreturndetails`, while sales use `salemaster` and
 *     `salesdetails` -- note the s on both detail tables,
 *   - salereturn has no RoundOffAmount column and the case emits no such key,
 *   - the return's two id keys are crossed over. See the case comment.
 * ---------------------------------------------------------------------------
 */

// The only capped query in the whole API. The batch size is hardcoded in the
// PHP, and the ERP's loop depends on it: it pulls 100, acknowledges them with
// update_saleStatus, and comes back for the next 100.
const SALE_MASTER_SQL = `SELECT om."OrderMasterId" AS "OrdermstrID", om."SaleMasterId", om."VoucherDate", om."PartyDetails", om."BillTypeId", om."LedgerId",
COALESCE(lm."LedgerName", '') AS "LedgerName", COALESCE(lm."RegionalName", '') AS "LedgerRegionalName",
om."GrossAmount", om."TaxableAmount", om."TaxId", om."TaxPercentage", om."TaxAmount", om."DiscountPercentage", om."DiscountAmount", om."RoundOffAmount",
om."Status", om."TotalAmount", om."PaidAmount", om."CreatedByUser", om."Description"
FROM salemaster om
LEFT JOIN ledger lm ON lm."LedgerId" = om."LedgerId"
WHERE om."Status" = $1
ORDER BY om."SaleMasterId"
LIMIT 100`;

const SALE_DETAILS_SQL = `SELECT LEFT(od."InventoryDetailsId", 20) AS "InventoryId", od."InventoryDetailsId", od."UnitId", od."Quantity", od."Rate",
od."GrossAmount", od."TaxableAmount", od."TaxId", od."TaxPercentage", od."TaxAmount",
od."AddTaxId", od."AddTaxPercentage", od."AddTaxAmount", od."AddTaxId1", od."AddTaxPercentage1", od."AddTaxAmount1",
od."DiscountPercentage", od."DiscountAmount", od."TotalAmount", od."Description"
FROM salesdetails od WHERE od."SaleMasterId" = $1`;

const RETURN_MASTER_SQL = `SELECT om."SaleMasterId", om."SaleReturnMasterId", om."ReturnNumber", om."VoucherDate", om."PartyDetails", om."BillTypeId", om."LedgerId",
COALESCE(lm."LedgerName", '') AS "LedgerName", COALESCE(lm."RegionalName", '') AS "LedgerRegionalName",
om."GrossAmount", om."TaxableAmount", om."TaxId", om."TaxPercentage", om."TaxAmount", om."DiscountPercentage", om."DiscountAmount",
om."Status", om."TotalAmount", om."PaidAmount", om."CreatedByUser", om."Description"
FROM salereturn om
LEFT JOIN ledger lm ON lm."LedgerId" = om."LedgerId"
WHERE om."Status" = $1
ORDER BY om."SaleReturnMasterId"`;

const RETURN_DETAILS_SQL = `SELECT LEFT(od."InventoryDetailsId", 20) AS "InventoryId", od."InventoryDetailsId", od."UnitId", od."Quantity", od."Rate",
od."GrossAmount", od."TaxableAmount", od."TaxId", od."TaxPercentage", od."TaxAmount",
od."AddTaxId", od."AddTaxPercentage", od."AddTaxAmount", od."AddTaxId1", od."AddTaxPercentage1", od."AddTaxAmount1",
od."DiscountPercentage", od."DiscountAmount", od."TotalAmount", od."Description"
FROM salesreturndetails od WHERE od."SaleReturnMasterId" = $1`;

export const cases: Cases = [
  // firefly_api.php lines 2825-2866.
  //
  // PartyDetails and LedgerRegionalName are selected then dropped. The cheques
  // are looked up by SaleMasterId used as pdcdetails.ReferenceId -- salemaster's
  // own OrderMasterId is a varchar(480) holding a comma-joined list of merged
  // order ids and is never joined on.
  [
    "get_salemaster",
    async (fd) =>
      dataArrayJson(async () => {
        const masters = await query(SALE_MASTER_SQL, [post(fd, "Status")]);
        const items = [];
        for (const item of masters.rows) {
          const details = await query(SALE_DETAILS_SQL, [item.SaleMasterId]);
          const pdcdetails = await pdcDetailsByReferenceId(item.SaleMasterId);
          items.push({
            OrdermstrID: item.OrdermstrID,
            SaleMasterID: item.SaleMasterId,
            VoucherDate: item.VoucherDate,
            BillTypeId: item.BillTypeId,
            LedgerId: item.LedgerId,
            LedgerName: item.LedgerName,
            Status: item.Status,
            GrossAmount: item.GrossAmount,
            TaxId: item.TaxId,
            TaxableAmount: item.TaxableAmount,
            TaxPercentage: item.TaxPercentage,
            TaxAmount: item.TaxAmount,
            DiscountPercentage: item.DiscountPercentage,
            DiscountAmount: item.DiscountAmount,
            RoundOffAmount: item.RoundOffAmount,
            TotalAmount: item.TotalAmount,
            PaidAmount: item.PaidAmount,
            CreatedByUser: item.CreatedByUser,
            Description: item.Description,
            SaleDetails: details.rows,
            PdcDetails: pdcdetails,
          });
        }
        return items;
      }),
  ],

  // firefly_api.php lines 1326-1365.
  //
  // The id keys are crossed and it is deliberate, so read this twice before
  // "fixing" it: OrdermstrID carries SaleMasterId (the original sale) and
  // SaleMasterID carries SaleReturnMasterId (the return itself). Both the lines
  // and the cheques are looked up by SaleReturnMasterId.
  //
  // The lines also ship under the key SaleDetails, not SaleReturnDetails. And
  // there is no RoundOffAmount key here -- salereturn has no such column.
  // ReturnNumber and PartyDetails are selected then dropped.
  [
    "get_salereturnmaster",
    async (fd) =>
      dataArrayJson(async () => {
        const masters = await query(RETURN_MASTER_SQL, [post(fd, "Status")]);
        const items = [];
        for (const item of masters.rows) {
          const details = await query(RETURN_DETAILS_SQL, [
            item.SaleReturnMasterId,
          ]);
          const pdcdetails = await pdcDetailsByReferenceId(
            item.SaleReturnMasterId,
          );
          items.push({
            OrdermstrID: item.SaleMasterId,
            SaleMasterID: item.SaleReturnMasterId,
            VoucherDate: item.VoucherDate,
            BillTypeId: item.BillTypeId,
            LedgerId: item.LedgerId,
            LedgerName: item.LedgerName,
            Status: item.Status,
            GrossAmount: item.GrossAmount,
            TaxId: item.TaxId,
            TaxableAmount: item.TaxableAmount,
            TaxPercentage: item.TaxPercentage,
            TaxAmount: item.TaxAmount,
            DiscountPercentage: item.DiscountPercentage,
            DiscountAmount: item.DiscountAmount,
            TotalAmount: item.TotalAmount,
            PaidAmount: item.PaidAmount,
            CreatedByUser: item.CreatedByUser,
            Description: item.Description,
            SaleDetails: details.rows,
            PdcDetails: pdcdetails,
          });
        }
        return items;
      }),
  ],

  // firefly_api.php lines 3127-3141 and 3143-3157.
  statusCase(
    "update_saleStatus",
    `UPDATE salemaster SET "Status" = 'K' WHERE "SaleMasterId" = $1`,
    "SaleMasterId",
  ),
  statusCase(
    "update_saleReturnStatus",
    `UPDATE salereturn SET "Status" = 'K' WHERE "SaleReturnMasterId" = $1`,
    "SaleReturnMasterId",
  ),
];
