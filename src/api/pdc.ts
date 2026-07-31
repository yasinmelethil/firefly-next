import { STATUS_FAIL, STATUS_OK, statusCase } from "@/api/_status";
import type { Cases } from "@/api/_types";
import { query } from "@/lib/db";
import { post } from "@/lib/params";
import { dataArrayJson, decodeItems } from "@/lib/read";
import { trueFalseJson, type TrueFalse } from "@/lib/response";

/*
 * ---------------------------------------------------------------------------
 * Post-dated cheque and card details, firefly_api.php lines 11256-11300.
 *
 * The table is pdcdetails; "pdcorcard" appears only in the api names. Three
 * readers share one column list and differ only in their WHERE clause:
 *
 *   get_pdcorcarddetails            ReferenceId = '' AND Status = :Status
 *   get_pdcorcarddetailsforclearance                   Status = :Status
 *   get_pdcorcarddetailsbyrefId     ReferenceId = :ReferenceId
 *
 * The ReferenceId = '' predicate on the first is what makes it "standalone"
 * entries only: a cheque attached to a sale or a return already ships inline
 * under that document's PdcDetails key, so listing it here too would double it.
 * Dropping the predicate is the entire difference between the first two.
 * ---------------------------------------------------------------------------
 */

const PDC_COLUMNS = `"PDCDetailsId", "PDCNumber", "VoucherDate", "PartyLedgerId", "BankLedgerId", "PaymentMode", "Amount", "Type", "ChequeNumber", "ChequeDate", "ReferenceId", "Status", "CreatedByUser", "CreatedTimeStamp"`;

const STANDALONE_SQL = `SELECT ${PDC_COLUMNS} FROM pdcdetails WHERE "ReferenceId" = '' AND "Status" = $1`;

const FOR_CLEARANCE_SQL = `SELECT ${PDC_COLUMNS} FROM pdcdetails WHERE "Status" = $1`;

const BY_REFERENCE_SQL = `SELECT ${PDC_COLUMNS} FROM pdcdetails WHERE "ReferenceId" = $1`;

/** One item as the two list cases emit it: thirteen of the fourteen columns. */
interface PdcItem {
  PDCDetailsId: unknown;
  VoucherDate: unknown;
  PDCNumber: unknown;
  PartyLedgerId: unknown;
  BankLedgerId: unknown;
  PaymentMode: unknown;
  Amount: unknown;
  Type: unknown;
  ChequeNumber: unknown;
  ChequeDate: unknown;
  ReferenceId: unknown;
  Status: unknown;
  CreatedByUser: unknown;
}

/**
 * Both list cases build their item the same way, key for key.
 *
 * CreatedTimeStamp is fetched and dropped, and PDCNumber comes second in the
 * emitted object but tenth in the SELECT -- the order here is PHP's array
 * literal, which is what lands on the wire.
 */
function pdcItem(row: Record<string, unknown>): PdcItem {
  return {
    PDCDetailsId: row.PDCDetailsId,
    VoucherDate: row.VoucherDate,
    PDCNumber: row.PDCNumber,
    PartyLedgerId: row.PartyLedgerId,
    BankLedgerId: row.BankLedgerId,
    PaymentMode: row.PaymentMode,
    Amount: row.Amount,
    Type: row.Type,
    ChequeNumber: row.ChequeNumber,
    ChequeDate: row.ChequeDate,
    ReferenceId: row.ReferenceId,
    Status: row.Status,
    CreatedByUser: row.CreatedByUser,
  };
}

/**
 * Port of get_pdcorcarddetailsbyrefId($dbh, $ReferenceId), firefly_api.php line
 * 11289.
 *
 * Exported for sale.ts: get_salemaster and get_salereturnmaster both attach the
 * cheques belonging to each document under a PdcDetails key, looked up by the
 * document id. Unlike the two list cases this one returns whole rows --
 * CreatedTimeStamp included, since the sale cases embed what fetchAll returned
 * rather than rebuilding it.
 */
export async function pdcDetailsByReferenceId(
  referenceId: unknown,
): Promise<Record<string, unknown>[]> {
  const result = await query(BY_REFERENCE_SQL, [referenceId]);
  return result.rows;
}

/** One entry of the pdcdetails JSON array update_pdcdetailsstatus loops over. */
interface PdcStatusItem {
  PDCDetailsId?: unknown;
}

const BATCH_STATUS_SQL = `UPDATE pdcdetails SET "Status" = $1 WHERE "PDCDetailsId" = $2`;

/**
 * Port of update_pdcdetailsstatus($dbh), firefly_api.php line 10544.
 *
 * The only batch status updater in the API, and the only one whose target status
 * comes from the payload instead of being hardcoded -- the ERP uses it with 'K'
 * to acknowledge and with 'C' to clear.
 *
 * No transaction: PHP has none, so a failure partway leaves the earlier rows
 * updated. One statement per item, matching that.
 */
export async function updatePdcDetailsStatus(fd: FormData): Promise<TrueFalse> {
  try {
    const Status = post(fd, "Status");
    for (const item of decodeItems<PdcStatusItem>(post(fd, "pdcdetails"))) {
      await query(BATCH_STATUS_SQL, [Status, item.PDCDetailsId]);
    }
    return "TRUE";
  } catch {
    return "FALSE";
  }
}

export const cases: Cases = [
  // firefly_api.php lines 2684-2714.
  [
    "get_pdcorcarddetails",
    async (fd) =>
      dataArrayJson(async () => {
        const result = await query(STANDALONE_SQL, [post(fd, "Status")]);
        return result.rows.map(pdcItem);
      }),
  ],

  // firefly_api.php lines 2717-2747. Identical to the above but for the missing
  // ReferenceId = '' predicate, so cheques already attached to a sale are
  // included -- which is the point, since clearance applies to those too.
  [
    "get_pdcorcarddetailsforclearance",
    async (fd) =>
      dataArrayJson(async () => {
        const result = await query(FOR_CLEARANCE_SQL, [post(fd, "Status")]);
        return result.rows.map(pdcItem);
      }),
  ],

  // firefly_api.php lines 3079-3093 and 3095-3109. Same table, same key, same
  // POST field -- only the character written differs.
  statusCase(
    "update_pdcStatus",
    `UPDATE pdcdetails SET "Status" = 'K' WHERE "PDCDetailsId" = $1`,
    "pdcdetailsId",
  ),
  statusCase(
    "update_pdcClearanceStatus",
    `UPDATE pdcdetails SET "Status" = 'C' WHERE "PDCDetailsId" = $1`,
    "pdcdetailsId",
  ),

  // firefly_api.php lines 3111-3125. Not built by statusCase: it loops a payload
  // array and takes its status from POST, but the two messages are the same ones
  // every other status case uses.
  [
    "update_pdcdetailsstatus",
    async (fd) =>
      trueFalseJson(await updatePdcDetailsStatus(fd), STATUS_FAIL, STATUS_OK),
  ],
];
