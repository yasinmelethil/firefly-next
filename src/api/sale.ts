import { statusCase } from "@/api/_status";
import type { Cases } from "@/api/_types";
import { pdcDetailsByReferenceId } from "@/api/pdc";
import { createHash } from "node:crypto";

import { query, withTransaction } from "@/lib/db";
import {
  isPhpEmpty,
  mysqlDate,
  mysqlNumeric,
  phpStr,
  post,
} from "@/lib/params";
import {
  dataArrayJson,
  decodeItems,
  emptySentinelJson,
  untouchedDefaultsJson,
} from "@/lib/read";
import { STATUS_ERROR, STATUS_SUCCESS, phpJson } from "@/lib/response";
import {
  bumpStartNumber,
  masterIdOf,
  readOrgSeparator,
  voucherNumberOf,
} from "@/lib/voucher";

/** PHP's md5(), used only to build the advisory lock name. */
function md5(value: string): string {
  return createHash("md5").update(value, "utf8").digest("hex");
}

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

/*
 * ---------------------------------------------------------------------------
 * The POS billing reads: three salemaster lists and one line-item fetch.
 *
 * Unlike the two sync-loop reads above, these echo raw rows -- no key rebuild --
 * so the column list below is the JSON key list, in this order.
 *
 * Two things they share, both easy to lose in transcription:
 *
 *   1. `JOIN "user"` is an INNER join in all three (10275, 10295, 10317), so a
 *      sale whose creating user has been deleted disappears from the list
 *      entirely. The order-side equivalents use LEFT. Not a mistake to
 *      harmonise -- see order.ts.
 *   2. The PHP selects om.PartyDetails **twice** (once at position 5, again
 *      after LedgerId). PDO's FETCH_OBJ keeps the first occurrence's position
 *      and emits a single key, and node-postgres does the same, so the
 *      duplicate is dropped here with no wire change.
 * ---------------------------------------------------------------------------
 */

/** The 21 columns get_salemasterbyNumber and get_allsaleswithoutpaidamount share. */
const SALES_COLUMNS = `om."OrderMasterId" AS "OrdermstrID", om."SaleMasterId", om."VoucherNumber", om."VoucherDate", om."PartyDetails", om."BillTypeId", om."LedgerId",
om."GrossAmount", om."TaxableAmount", om."TaxId", om."TaxPercentage", om."TaxAmount", om."DiscountPercentage", om."DiscountAmount", om."RoundOffAmount",
om."Status", om."TotalAmount", om."PaidAmount", om."CreatedByUser", us."UserName" AS "CreatedUser", om."Description"`;

// get_allsales is the only one of the three carrying PosMode and IsOut.
const ALL_SALES_SQL = `SELECT ${SALES_COLUMNS}, om."PosMode", om."IsOut"
FROM salemaster om
JOIN "user" us ON om."CreatedByUser" = us."UserId"
WHERE om."VoucherDate" BETWEEN $1 AND $2`;

// The unpaid-bills screen. VoucherDate is timestamp(0), so a bare date as
// TillDate truncates to midnight and excludes that day -- same on both engines.
const ALL_SALES_UNPAID_SQL = `SELECT ${SALES_COLUMNS}
FROM salemaster om
JOIN "user" us ON om."CreatedByUser" = us."UserId"
WHERE om."VoucherDate" BETWEEN $1 AND $2
AND om."PaidAmount" = 0`;

const SALE_BY_NUMBER_SQL = `SELECT ${SALES_COLUMNS}
FROM salemaster om
JOIN "user" us ON om."CreatedByUser" = us."UserId"
WHERE om."BillTypeId" = $1 AND om."VoucherNumber" = $2`;

/**
 * get_allsaleDetailsByMasterId, firefly_api.php line 10347.
 *
 * The wider sibling of SALE_DETAILS_SQL above: same salesdetails columns plus
 * five product ones, reached through an INNER join, so a line whose product was
 * deleted vanishes from the invoice.
 */
const ALL_SALE_DETAILS_SQL = `SELECT LEFT(od."InventoryDetailsId", 20) AS "InventoryId", od."InventoryDetailsId", p."ProductName", p."ProductRegionalName", p."HSNCode", od."UnitId",
p."UnitName", p."UnitShortName", p."UnitRegionalName", od."Quantity", od."Rate",
od."GrossAmount", od."TaxableAmount", od."TaxId", od."TaxPercentage", od."TaxAmount",
od."AddTaxId", od."AddTaxPercentage", od."AddTaxAmount", od."AddTaxId1", od."AddTaxPercentage1", od."AddTaxAmount1",
od."DiscountPercentage", od."DiscountAmount", od."TotalAmount", od."Description"
FROM salesdetails od JOIN product p ON od."InventoryDetailsId" = p."InventoryDetailsId"
WHERE od."SaleMasterId" = $1`;

/*
 * ---------------------------------------------------------------------------
 * insert_salebybilltypewithpdc, firefly_api.php line 8627.
 *
 * Turns one or more KOTs into a bill: upsert the master, replace its lines and
 * its cheques, hand the number series on. The largest write in the API, and the
 * only one with an idempotency story -- a double-clicked "Print Bill" must not
 * mint two invoices.
 *
 * That guard has three layers, all of them kept:
 *
 *   1. An advisory lock on the idempotency key (or, failing that, the order
 *      ids) so concurrent attempts serialise instead of racing the check below.
 *   2. Before inserting, look for a sale already carrying this key -- or
 *      already billing any of these orders -- and return it instead. That reply
 *      carries a fourth key, "duplicate": true.
 *   3. If two requests still slip through, the unique index on IdempotencyKey
 *      rejects the loser, which rolls back and returns the winner's sale.
 *
 * It does NOT touch stock. Nothing here writes warehousestock or stockposting;
 * billing does not decrement inventory in this API.
 * ---------------------------------------------------------------------------
 */

/**
 * PHP takes `GET_LOCK(name, 10)` and releases it by hand after commit and on
 * every error path (8685, 8779, 8870, 9002, 9015).
 *
 * pg_advisory_xact_lock releases on COMMIT and on ROLLBACK, so all four release
 * sites disappear -- and with them the leak GET_LOCK has if the process dies in
 * between. hashtext folds the name into the bigint the lock space wants; it is
 * 32-bit and unstable across major versions, which does not matter for a
 * namespace that only has to agree with itself.
 *
 * Divergence: MySQL gives up after 10 seconds and proceeds unlocked, relying on
 * layer 3; this blocks until it gets the lock. Under a real double-submit both
 * end up correct -- PostgreSQL just serialises where MySQL might race. If the
 * timeout is ever wanted, `SET LOCAL lock_timeout = '10s'` plus catching 55P03
 * reproduces it exactly.
 */
const ADVISORY_LOCK_SQL = `SELECT pg_advisory_xact_lock(hashtext($1)::bigint)`;

const SALE_UPDATE_SQL = `UPDATE salemaster SET
"LedgerId" = $1, "VoucherDate" = $2, "PartyDetails" = $3, "OrderMasterId" = $4,
"Status" = 'N',
"CreatedByUser" = $5, "GrossAmount" = $6, "TaxId" = $7, "TaxableAmount" = $8,
"TaxPercentage" = $9, "TaxAmount" = $10, "DiscountPercentage" = $11, "DiscountAmount" = $12,
"RoundOffAmount" = COALESCE(NULLIF($13::text, '')::numeric, "RoundOffAmount"),
"TotalAmount" = $14, "PaidAmount" = $15, "Description" = $16,
"PosMode" = COALESCE(NULLIF($17::text, ''), "PosMode"),
"CreatedTimeStamp" = $18
WHERE "SaleMasterId" = $19`;

const SALE_DETAILS_DELETE_SQL = `DELETE FROM salesdetails WHERE "SaleMasterId" = $1`;
const SALE_PDC_DELETE_SQL = `DELETE FROM pdcdetails WHERE "ReferenceId" = $1`;
const SALE_VOUCHER_SQL = `SELECT "VoucherNumber" FROM salemaster WHERE "SaleMasterId" = $1 LIMIT 1`;

const SALE_BY_IDEMPOTENCY_SQL = `SELECT "SaleMasterId", "VoucherNumber" FROM salemaster WHERE "IdempotencyKey" = $1 LIMIT 1`;

// FIND_IN_SET over the comma-joined OrderMasterId -- see NOT_YET_BILLED in
// order.ts for why = ANY(string_to_array(...)) is the equivalent.
const SALE_BY_ORDER_SQL = `SELECT "SaleMasterId", "VoucherNumber" FROM salemaster
WHERE $1 = ANY(string_to_array("OrderMasterId", ','))
ORDER BY "AUTOID" LIMIT 1`;

const SALE_BILLTYPE_SERIES_SQL = `SELECT "Prefix", "Suffix", "StartNumber" FROM billtype WHERE "BillTypeId" = $1 LIMIT 1`;
const SALE_ID_TAKEN_SQL = `SELECT EXISTS (SELECT 1 FROM salemaster WHERE "SaleMasterId" = $1) AS "IsUpdate"`;
const SALE_NEXT_AUTOID_SQL = `SELECT COALESCE(MAX("AUTOID") + 1, 1) AS "MaxId" FROM salemaster WHERE "BillTypeId" = $1`;

const SALE_INSERT_SQL = `INSERT INTO salemaster
("AUTOID", "OrganizationCode", "BillTypeId", "OrderMasterId", "VoucherDate", "SaleMasterId",
 "VoucherNumber", "LedgerId", "PartyDetails", "Status", "CreatedByUser", "GrossAmount",
 "TaxId", "TaxableAmount", "TaxPercentage", "TaxAmount", "DiscountPercentage", "DiscountAmount",
 "RoundOffAmount", "TotalAmount", "PaidAmount", "Description", "IdempotencyKey", "PosMode",
 "CreatedTimeStamp")
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'N', $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24)`;

const SALE_PRODUCT_UNIT_SQL = `SELECT "UnitId" FROM product WHERE "InventoryDetailsId" = $1`;

const SALE_DETAIL_INSERT_SQL = `INSERT INTO salesdetails
("SaleMasterId", "InventoryDetailsId", "UnitId", "Quantity", "Rate", "GrossAmount",
 "TaxId", "TaxableAmount", "TaxPercentage", "TaxAmount",
 "AddTaxId", "AddTaxPercentage", "AddTaxAmount", "AddTaxId1", "AddTaxPercentage1", "AddTaxAmount1",
 "DiscountPercentage", "DiscountAmount", "TotalAmount", "CreatedByUser", "Description", "CreatedTimeStamp")
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22)`;

// Numbered per PaymentMode, not globally.
const PDC_NEXT_AUTOID_SQL = `SELECT COALESCE(MAX("AUTOID") + 1, 1) AS "MaxId" FROM pdcdetails WHERE "PaymentMode" = $1`;

const PDC_INSERT_SQL = `INSERT INTO pdcdetails
("OrganizationCode", "AUTOID", "PDCDetailsId", "PDCNumber", "VoucherDate", "PartyLedgerId",
 "BankLedgerId", "PaymentMode", "Amount", "Type", "ChequeNumber", "ChequeDate", "ReferenceId",
 "Status", "CreatedByUser", "CreatedTimeStamp")
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, 'N', $14, $15)`;

interface SaleDetailItem {
  InventoryDetailsId?: unknown;
  Rate?: unknown;
  Quantity?: unknown;
  DetailsGrossAmount?: unknown;
  DetailsTaxId?: unknown;
  DetailsTaxableAmount?: unknown;
  DetailsTaxPercentage?: unknown;
  DetailsTaxAmount?: unknown;
  DetailsAddTaxId?: unknown;
  DetailsAddTaxPercentage?: unknown;
  DetailsAddTaxAmount?: unknown;
  DetailsAddTaxId1?: unknown;
  DetailsAddTaxPercentage1?: unknown;
  DetailsAddTaxAmount1?: unknown;
  DetailsDiscountPercentage?: unknown;
  DetailsDiscountAmount?: unknown;
  DetailsTotalAmount?: unknown;
  DetailsDescription?: unknown;
}

interface PdcDetailItem {
  BankLedgerId?: unknown;
  PaymentMode?: unknown;
  Amount?: unknown;
  ChequeNumber?: unknown;
  ChequeDate?: unknown;
}

/** The PHP returns a stdClass on success and a plain string on failure. */
type SaleWriteResult =
  | { status: "TRUE"; id: string; voucherNumber: string; duplicate?: true }
  | string;

/**
 * Layer 3: the loser of a true race. Thrown from inside the transaction so
 * withTransaction rolls back, then caught outside, where the winner's row can
 * be read on a clean connection -- PHP does the same dance by hand at 8863-8888.
 */
class DuplicateSale extends Error {
  constructor(readonly key: string) {
    super("duplicate sale");
  }
}

/** PostgreSQL's unique_violation. PDO reports the generic class 23000. */
const UNIQUE_VIOLATION = "23505";

export async function insertSaleByBillTypeWithPdc(
  fd: FormData,
): Promise<SaleWriteResult> {
  const SaleMasterIdPosted = post(fd, "SaleMasterId");
  const VoucherDate = post(fd, "VoucherDate");
  const LedgerId = post(fd, "LedgerId");
  const PartyDetails = post(fd, "PartyDetails");
  const CreatedByUser = post(fd, "CreatedByUser");
  const OrderMasterId = post(fd, "OrderMasterId");
  const GrossAmount = mysqlNumeric(post(fd, "GrossAmount"));
  const TaxId = post(fd, "TaxId");
  const TaxableAmount = mysqlNumeric(post(fd, "TaxableAmount"));
  const TaxPercentage = mysqlNumeric(post(fd, "TaxPercentage"));
  const TaxAmount = mysqlNumeric(post(fd, "TaxAmount"));
  const DiscountPercentage = mysqlNumeric(post(fd, "DiscountPercentage"));
  const DiscountAmount = mysqlNumeric(post(fd, "DiscountAmount"));
  const TotalAmount = mysqlNumeric(post(fd, "TotalAmount"));
  const PaidAmount = mysqlNumeric(post(fd, "PaidAmount"));
  const BillTypeId = post(fd, "BillTypeId");
  const Description = post(fd, "Description");
  const CreatedTimeStamp = post(fd, "CreatedTimeStamp");
  const PosMode = post(fd, "PosMode") ?? "";

  // Blank means "keep what is stored" on update -- the COALESCE(NULLIF(...))
  // above -- so it is trimmed to '' rather than coerced. On insert there is
  // nothing to keep and the column is NOT NULL with no default, hence '0.00'.
  const RoundOffAmount = (post(fd, "RoundOffAmount") ?? "").trim();
  const RoundOffForInsert = RoundOffAmount === "" ? "0.00" : RoundOffAmount;
  const IdempotencyKey = (post(fd, "IdempotencyKey") ?? "").trim();

  // The lock name is PHP's, md5 and all. The hash is redundant now that
  // hashtext runs over it, but keeping it makes the two implementations diffable.
  let lockName = "";
  if (IdempotencyKey !== "") {
    lockName = `salebill_${md5(IdempotencyKey)}`;
  } else if (!isPhpEmpty(OrderMasterId)) {
    lockName = `salebill_${md5(OrderMasterId ?? "")}`;
  }

  try {
    return await withTransaction(async (client) => {
      if (lockName !== "") {
        await client.query(ADVISORY_LOCK_SQL, [lockName]);
      }

      const { OrganizationCode, Separator } = await readOrgSeparator(client);

      let SaleMasterId = SaleMasterIdPosted;
      let lastInsertedId = "";
      let VoucherNumber = "";

      if (!isPhpEmpty(SaleMasterId)) {
        await client.query(SALE_UPDATE_SQL, [
          LedgerId, VoucherDate, PartyDetails, OrderMasterId, CreatedByUser,
          GrossAmount, TaxId, TaxableAmount, TaxPercentage, TaxAmount,
          DiscountPercentage, DiscountAmount, RoundOffAmount,
          TotalAmount, PaidAmount, Description, PosMode, CreatedTimeStamp,
          SaleMasterId,
        ]);
        await client.query(SALE_DETAILS_DELETE_SQL, [SaleMasterId]);
        await client.query(SALE_PDC_DELETE_SQL, [SaleMasterId]);
        const voucher = await client.query(SALE_VOUCHER_SQL, [SaleMasterId]);
        VoucherNumber = voucher.rows[0]?.VoucherNumber ?? null;
        lastInsertedId = SaleMasterId ?? "";
      } else {
        // Layer 2: has this bill already been written?
        let existing: { SaleMasterId: string; VoucherNumber: string } | undefined;
        if (IdempotencyKey !== "") {
          const byKey = await client.query(SALE_BY_IDEMPOTENCY_SQL, [
            IdempotencyKey,
          ]);
          existing = byKey.rows[0];
        }
        if (!existing && !isPhpEmpty(OrderMasterId)) {
          // array_filter drops falsy entries, so a blank -- or an order id of
          // literally "0" -- is skipped. PHP's empty() trap, reached via ids.
          const ids = (OrderMasterId ?? "")
            .split(",")
            .map((id) => id.trim())
            .filter((id) => !isPhpEmpty(id));
          for (const oid of ids) {
            const byOrder = await client.query(SALE_BY_ORDER_SQL, [oid]);
            existing = byOrder.rows[0];
            if (existing) break;
          }
        }
        if (existing) {
          // Commits having written nothing, and never reaches the details loops.
          return {
            status: "TRUE" as const,
            id: existing.SaleMasterId,
            voucherNumber: existing.VoucherNumber,
            duplicate: true as const,
          };
        }

        const series = await client.query(SALE_BILLTYPE_SERIES_SQL, [BillTypeId]);
        const row = series.rows[0];
        // is_null, not empty() -- so a StartNumber of 0 stays 0 here, where
        // insert_ordercancelbybilltype would force it to 1.
        let MaxId = row?.StartNumber ?? null;
        if (MaxId === null) {
          MaxId = 1;
        }

        const taken = await client.query(SALE_ID_TAKEN_SQL, [
          masterIdOf(BillTypeId ?? "", MaxId),
        ]);
        if (taken.rows[0]?.IsUpdate) {
          const next = await client.query(SALE_NEXT_AUTOID_SQL, [BillTypeId]);
          MaxId = Number(next.rows[0]?.MaxId ?? 1);
        }

        VoucherNumber = voucherNumberOf(
          row?.Prefix ?? null,
          row?.Suffix ?? null,
          Separator,
          MaxId,
        );
        SaleMasterId = masterIdOf(BillTypeId ?? "", MaxId);

        try {
          await client.query(SALE_INSERT_SQL, [
            MaxId, OrganizationCode, BillTypeId, OrderMasterId, VoucherDate,
            SaleMasterId, VoucherNumber, LedgerId, PartyDetails, CreatedByUser,
            GrossAmount, TaxId, TaxableAmount, TaxPercentage, TaxAmount,
            DiscountPercentage, DiscountAmount, RoundOffForInsert,
            TotalAmount, PaidAmount, Description,
            // NULL rather than '' when unkeyed, so the unique index tolerates
            // any number of legacy and unkeyed sales.
            IdempotencyKey !== "" ? IdempotencyKey : null,
            PosMode, CreatedTimeStamp,
          ]);
        } catch (e) {
          if (
            IdempotencyKey !== "" &&
            (e as { code?: string })?.code === UNIQUE_VIOLATION
          ) {
            throw new DuplicateSale(IdempotencyKey);
          }
          throw e;
        }

        await bumpStartNumber(client, BillTypeId, Number(MaxId) + 1);
        lastInsertedId = SaleMasterId;
      }

      for (const item of decodeItems<SaleDetailItem>(post(fd, "SaleDetails"))) {
        const InventoryDetailsId = phpStr(item.InventoryDetailsId);
        const unit = await client.query(SALE_PRODUCT_UNIT_SQL, [
          InventoryDetailsId,
        ]);
        const UnitId = unit.rows[0]?.UnitId ?? null;

        await client.query(SALE_DETAIL_INSERT_SQL, [
          SaleMasterId,
          InventoryDetailsId,
          UnitId,
          mysqlNumeric(phpStr(item.Quantity)),
          mysqlNumeric(phpStr(item.Rate)),
          mysqlNumeric(phpStr(item.DetailsGrossAmount)),
          phpStr(item.DetailsTaxId),
          mysqlNumeric(phpStr(item.DetailsTaxableAmount)),
          mysqlNumeric(phpStr(item.DetailsTaxPercentage)),
          mysqlNumeric(phpStr(item.DetailsTaxAmount)),
          phpStr(item.DetailsAddTaxId),
          mysqlNumeric(phpStr(item.DetailsAddTaxPercentage)),
          mysqlNumeric(phpStr(item.DetailsAddTaxAmount)),
          phpStr(item.DetailsAddTaxId1),
          mysqlNumeric(phpStr(item.DetailsAddTaxPercentage1)),
          mysqlNumeric(phpStr(item.DetailsAddTaxAmount1)),
          mysqlNumeric(phpStr(item.DetailsDiscountPercentage)),
          mysqlNumeric(phpStr(item.DetailsDiscountAmount)),
          mysqlNumeric(phpStr(item.DetailsTotalAmount)),
          CreatedByUser,
          phpStr(item.DetailsDescription),
          CreatedTimeStamp,
        ]);
      }

      for (const item of decodeItems<PdcDetailItem>(post(fd, "PdcDetails"))) {
        const PaymentMode = phpStr(item.PaymentMode);
        const next = await client.query(PDC_NEXT_AUTOID_SQL, [PaymentMode]);
        const MaxId = Number(next.rows[0]?.MaxId ?? 1);

        // 'PC' is a post-dated cheque; everything else -- including the blank
        // the ERP sends on a cash sale -- is filed as a card payment.
        const PDCNumber = `${PaymentMode === "PC" ? "PDC" : "CC"}-${MaxId}`;
        // With a blank PaymentMode this yields a double hyphen,
        // "MMKP--0000000032". Every live row looks like that. Faithful.
        const PDCDetailsId = `${OrganizationCode}-${PaymentMode ?? ""}-${String(MaxId).padStart(10, "0")}`;

        await client.query(PDC_INSERT_SQL, [
          OrganizationCode,
          MaxId,
          PDCDetailsId,
          PDCNumber,
          VoucherDate,
          LedgerId, // PartyLedgerId
          phpStr(item.BankLedgerId),
          PaymentMode,
          mysqlNumeric(phpStr(item.Amount)),
          "R", // Type: receipt
          phpStr(item.ChequeNumber),
          // varchar(10) holding what MySQL's date column would have coerced to.
          mysqlDate(phpStr(item.ChequeDate)),
          SaleMasterId, // ReferenceId
          CreatedByUser,
          CreatedTimeStamp,
        ]);
      }

      return {
        status: "TRUE" as const,
        id: lastInsertedId,
        voucherNumber: VoucherNumber,
      };
    });
  } catch (e) {
    if (e instanceof DuplicateSale) {
      // The transaction is already rolled back; read the winner outside it.
      const winner = await query(SALE_BY_IDEMPOTENCY_SQL, [e.key]);
      const w = winner.rows[0];
      if (w) {
        return {
          status: "TRUE",
          id: w.SaleMasterId,
          voucherNumber: w.VoucherNumber,
          duplicate: true,
        };
      }
      return `ERROR: ${e.message}`;
    }
    // A string, not an object -- the case block branches on the type.
    return `ERROR: ${e instanceof Error ? e.message : String(e)}`;
  }
}

export const cases: Cases = [
  // firefly_api.php lines 1166-1193.
  //
  // substr($ACTION, 6) cuts "ERROR:" and leaves the space that followed it, so
  // the rendered message has TWO spaces after "Failed!". Same quirk the README
  // records for insert_organization.
  [
    "insert_salebybilltypewithpdc",
    async (fd) => {
      const ACTION = await insertSaleByBillTypeWithPdc(fd);
      if (typeof ACTION === "string") {
        return phpJson({
          STATUS: STATUS_ERROR,
          MESSAGE: ACTION.startsWith("ERROR:")
            ? "Adding New Sales Details Failed! " + ACTION.substring(6)
            : "Unknown string response.",
          DATA: null,
        });
      }
      return phpJson({
        STATUS: STATUS_SUCCESS,
        MESSAGE: "Added New Sales Details Successfully!",
        DATA: ACTION,
      });
    },
  ],

  // firefly_api.php lines 1268-1280.
  [
    "get_allsales",
    async (fd) =>
      emptySentinelJson("No Sales found!!", async () => {
        const result = await query(ALL_SALES_SQL, [
          post(fd, "FromDate"),
          post(fd, "TillDate"),
        ]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 1282-1294.
  [
    "get_allsaleswithoutpaidamount",
    async (fd) =>
      emptySentinelJson("No Sales found!!", async () => {
        const result = await query(ALL_SALES_UNPAID_SQL, [
          post(fd, "FromDate"),
          post(fd, "TillDate"),
        ]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 1298-1310.
  [
    "get_salemasterbyNumber",
    async (fd) =>
      emptySentinelJson("No Sales found!!", async () => {
        const result = await query(SALE_BY_NUMBER_SQL, [
          post(fd, "BillTypeId"),
          post(fd, "VoucherNumber"),
        ]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 1312-1324.
  //
  // The getter returns fetchAll() with no 'EMPTY' sentinel, so an invoice with
  // no lines answers {"STATUS":"ERROR","MESSAGE":"Something Went Wrong!!!",
  // "DATA":[]} and 'No Sale Details found!!' at line 1317 is unreachable.
  [
    "get_allsaleDetailsByMasterId",
    async (fd) =>
      untouchedDefaultsJson(async () => {
        const result = await query(ALL_SALE_DETAILS_SQL, [
          post(fd, "SaleMasterId"),
        ]);
        return result.rows;
      }),
  ],

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
