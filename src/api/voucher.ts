import { statusCase } from "@/api/_status";
import type { Cases } from "@/api/_types";
import { query } from "@/lib/db";
import { post } from "@/lib/params";
import { dataArrayJson } from "@/lib/read";

/*
 * ---------------------------------------------------------------------------
 * get_receipt / get_payment / get_journal, firefly_api.php lines 10728, 11093
 * and 10801.
 *
 * The three flat reads of the sync loop: one query each, no joins, no details,
 * and -- unlike every master read -- no ORDER BY and no LIMIT. Both omissions
 * are transcribed, so these return the whole matching set in engine order.
 *
 * The three tables are near-identical but not quite: receipt has an Adjustment
 * column the other two lack, and it declares its ledger columns To-before-From
 * where payment and journal go From-before-To. The SELECT lists below follow
 * each table's own order, as the PHP does; the emitted key order is the same for
 * all three regardless, To before From.
 * ---------------------------------------------------------------------------
 */

const RECEIPT_SQL = `SELECT "ReceiptId", "VoucherDate", "FromLedgerId", "ToLedgerId", "BillTypeId", "Amount", "Adjustment", "Status", "CreatedByUser"
FROM receipt WHERE "Status" = $1`;

const PAYMENT_SQL = `SELECT "PaymentId", "VoucherDate", "FromLedgerId", "ToLedgerId", "BillTypeId", "Amount", "Status", "CreatedByUser"
FROM payment WHERE "Status" = $1`;

const JOURNAL_SQL = `SELECT "JournalId", "VoucherDate", "FromLedgerId", "ToLedgerId", "BillTypeId", "Amount", "Status", "CreatedByUser"
FROM journal WHERE "Status" = $1`;

export const cases: Cases = [
  // firefly_api.php lines 2444-2470. The only one of the three carrying
  // Adjustment.
  [
    "get_receipt",
    async (fd) =>
      dataArrayJson(async () => {
        const result = await query(RECEIPT_SQL, [post(fd, "Status")]);
        return result.rows.map((row) => ({
          ReceiptId: row.ReceiptId,
          VoucherDate: row.VoucherDate,
          BillTypeId: row.BillTypeId,
          ToLedgerId: row.ToLedgerId,
          FromLedgerId: row.FromLedgerId,
          Status: row.Status,
          Amount: row.Amount,
          Adjustment: row.Adjustment,
          CreatedByUser: row.CreatedByUser,
        }));
      }),
  ],

  // firefly_api.php lines 2629-2654.
  //
  // The payment id ships under the key **ReceiptId**: the PHP case reads
  // 'ReceiptId' => $item->PaymentId, almost certainly because the block was
  // copy-pasted from get_receipt. There is no PaymentId key in the response at
  // all, and the ERP parses what it is given, so this is the contract.
  [
    "get_payment",
    async (fd) =>
      dataArrayJson(async () => {
        const result = await query(PAYMENT_SQL, [post(fd, "Status")]);
        return result.rows.map((row) => ({
          ReceiptId: row.PaymentId,
          VoucherDate: row.VoucherDate,
          BillTypeId: row.BillTypeId,
          ToLedgerId: row.ToLedgerId,
          FromLedgerId: row.FromLedgerId,
          Status: row.Status,
          Amount: row.Amount,
          CreatedByUser: row.CreatedByUser,
        }));
      }),
  ],

  // firefly_api.php lines 2528-2553. This one does use its own id key.
  [
    "get_journal",
    async (fd) =>
      dataArrayJson(async () => {
        const result = await query(JOURNAL_SQL, [post(fd, "Status")]);
        return result.rows.map((row) => ({
          JournalId: row.JournalId,
          VoucherDate: row.VoucherDate,
          BillTypeId: row.BillTypeId,
          ToLedgerId: row.ToLedgerId,
          FromLedgerId: row.FromLedgerId,
          Status: row.Status,
          Amount: row.Amount,
          CreatedByUser: row.CreatedByUser,
        }));
      }),
  ],

  // firefly_api.php lines 3032-3046, 3048-3062 and 3064-3078. All three POST
  // fields start with a lowercase letter, unlike the sale and order updaters.
  statusCase(
    "update_receiptStatus",
    `UPDATE receipt SET "Status" = 'K' WHERE "ReceiptId" = $1`,
    "receiptId",
  ),
  statusCase(
    "update_paymentStatus",
    `UPDATE payment SET "Status" = 'K' WHERE "PaymentId" = $1`,
    "paymentId",
  ),
  statusCase(
    "update_journalStatus",
    `UPDATE journal SET "Status" = 'K' WHERE "JournalId" = $1`,
    "journalId",
  ),
];
