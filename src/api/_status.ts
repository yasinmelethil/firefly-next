import type { Handler } from "@/api/_types";
import { query } from "@/lib/db";
import { post } from "@/lib/params";
import { trueFalseJson, type TrueFalse } from "@/lib/response";

/**
 * Shared by all eleven status cases, update_pdcdetailsstatus included. Verified
 * identical in every one of them; "Succes" is misspelled in the PHP and stays.
 */
export const STATUS_FAIL = "Status Updation Failed!";
export const STATUS_OK = "Status Updation Succes!";

/**
 * The ten single-row status updaters, which are the same function ten times.
 *
 * The ERP's sync loop is pull-then-acknowledge: a get_* case selects rows
 * WHERE Status = :Status, and the ERP then calls the matching update_*Status
 * once per row to flip that row's Status. There is no issync/synced column
 * anywhere in the schema -- the one-character Status column IS the sync flag.
 * Observed lifecycle: 'P' temp, 'N' ready to pull, 'K' acknowledged, and 'C'
 * cleared for PDC only.
 *
 * Each PHP function is a bare UPDATE with no transaction, no row-count check and
 * a hardcoded target character, wrapped in the identical router block. They
 * differ only in table, key column, POST field and target status, so they are
 * built here rather than transcribed ten times.
 *
 * Two things that look like mistakes and are not:
 *
 *   - An id matching nothing still reports SUCCESS. PHP never looks at the
 *     affected row count, so there is no not-found path to reproduce.
 *   - The POST field names are inconsistent -- ordermstr_id, SaleMasterId,
 *     SaleReturnMasterId, receiptId, paymentId, journalId, pdcdetailsId. The
 *     casing is part of the contract; the ERP sends exactly these.
 *
 * update_pdcdetailsstatus is deliberately not built here: it is the only batch
 * updater and the only one taking its target status from the payload, so it
 * lives in pdc.ts with its own loop.
 */
export function statusUpdater(
  sql: string,
  paramKey: string,
): (fd: FormData) => Promise<TrueFalse> {
  return async (fd: FormData): Promise<TrueFalse> => {
    try {
      await query(sql, [post(fd, paramKey)]);
      return "TRUE";
    } catch {
      return "FALSE";
    }
  };
}

/**
 * One registrable case for a status updater.
 *
 * Every one of the eleven status cases -- including update_pdcdetailsstatus --
 * emits the same two messages, verified across all of them in firefly_api.php.
 */
export function statusCase(
  name: string,
  sql: string,
  paramKey: string,
): readonly [string, Handler] {
  const run = statusUpdater(sql, paramKey);
  return [
    name,
    async (fd) => trueFalseJson(await run(fd), STATUS_FAIL, STATUS_OK),
  ] as const;
}
