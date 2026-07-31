import type { Cases } from "@/api/_types";
import { query, withTransaction } from "@/lib/db";
import { post } from "@/lib/params";
import { dataArrayJson } from "@/lib/read";
import { trueFalseJson, type TrueFalse } from "@/lib/response";
import { checkedSql, setList } from "@/lib/sql";

/*
 * ---------------------------------------------------------------------------
 * get_newcustomers, firefly_api.php line 4422.
 *
 * There is no customer table: a customer is a row in `ledger`, and a *new*
 * customer is one the app created that the ERP has not yet assigned an id to --
 * hence the LedgerId = '' filter. The ERP pulls these, allocates ids, and calls
 * update_customerledgerId to write them back, which is what takes the row out of
 * this result set.
 *
 * The only endpoint in the sync loop that takes no parameters at all.
 * ---------------------------------------------------------------------------
 */

/**
 * Transcribed verbatim, all seventeen columns, including the ten the case never
 * emits. Same choice get_userprivilegeslist made with UserId: the SELECT is part
 * of the transcription even where the router drops its result. Note this means
 * `mypassword` is fetched and discarded -- it is never referenced below and
 * cannot reach the wire.
 *
 * No ORDER BY in the PHP and none here; row order is whatever the engine returns.
 */
const NEW_CUSTOMERS_SQL = `SELECT "led_id", "LedgerId", "LedgerType", "LedgerName", "RegionalName", "LedgerCode", "CustomCode", "Address", "Email", "Phone", "TINNumber", "noofseats", "seatstaken", "UserName", "mypassword", "RoutId", "CurrentBalance"
FROM ledger WHERE "LedgerId" = ''`;

/*
 * ---------------------------------------------------------------------------
 * update_customerledgerId, firefly_api.php line 5446.
 *
 * The write-back half of get_newcustomers, and the only function in the sync
 * loop with a real beginTransaction/commit/rollBack -- which maps directly onto
 * withTransaction.
 * ---------------------------------------------------------------------------
 */

const LEDGER_SET = ["LedgerId", "CustomCode", "LedgerCode"] as const;

// The key is led_id, the surrogate integer PK -- not LedgerId, which is exactly
// the column being overwritten and is still '' at this point.
const LEDGER_SQL = checkedSql(
  "ledger customerledgerId UPDATE",
  `UPDATE ledger SET ${setList(LEDGER_SET)}
WHERE "led_id" = $${LEDGER_SET.length + 1}`,
  LEDGER_SET.length + 1,
);

/**
 * The eight tables PHP rewrites after the ledger row, with the column each one
 * names its party ledger. Two of them do not call it LedgerId.
 */
const CHILD_TABLES = [
  ["ordermaster", "LedgerId"],
  ["ordercancelmaster", "LedgerId"],
  ["salemaster", "LedgerId"],
  ["salereturn", "LedgerId"],
  ["receipt", "FromLedgerId"],
  ["payment", "ToLedgerId"],
  ["purchaseordermaster", "LedgerId"],
  ["pdcdetails", "PartyLedgerId"],
] as const;

/**
 * `UPDATE <t> SET <col> = :LedgerId WHERE <col> = :ID`, built the way PHP
 * interpolates it.
 *
 * The WHERE clause is wrong in the original and is reproduced wrong. It compares
 * a varchar ledger column against $ID, which is led_id -- an integer surrogate
 * key -- rather than against the ledger's previous LedgerId. So every one of
 * these eight statements matches zero rows, always. Harmless in the real flow: a
 * customer new enough to be in get_newcustomers has no documents pointing at it
 * yet, and the rows that would need repointing carry LedgerId '' anyway.
 *
 * Because of that the ID parameter must be bound as text, which post() does. Bind
 * it as a number and PostgreSQL raises "operator does not exist: character
 * varying = integer", turning MySQL's silent no-op into a hard failure and a
 * rolled-back transaction.
 */
const CHILD_SQL: readonly string[] = CHILD_TABLES.map(([table, column]) =>
  checkedSql(
    `${table} customerledgerId UPDATE`,
    `UPDATE ${table} SET "${column}" = $1 WHERE "${column}" = $2`,
    2,
  ),
);

/**
 * Port of update_customerledgerId($dbh), firefly_api.php line 5446.
 *
 * Nine statements in one transaction: the ledger row by led_id, then the eight
 * child tables. PHP rolls back on any exception and returns 'FALSE'.
 */
export async function updateCustomerLedgerId(fd: FormData): Promise<TrueFalse> {
  const LedgerId = post(fd, "LedgerId");
  const ID = post(fd, "ID");

  try {
    await withTransaction(async (client) => {
      await client.query(LEDGER_SQL, [
        LedgerId,
        post(fd, "CustomCode"),
        post(fd, "LedgerCode"),
        ID,
      ]);
      for (const sql of CHILD_SQL) {
        await client.query(sql, [LedgerId, ID]);
      }
    });
    return "TRUE";
  } catch {
    return "FALSE";
  }
}

export const cases: Cases = [
  // firefly_api.php lines 444-468.
  //
  // Eight keys out of the seventeen columns fetched, two of them renamed:
  // ID <- led_id and NativeName <- RegionalName. Built key by key so the JSON
  // key order matches PHP's array literal rather than the SELECT order.
  [
    "get_newcustomers",
    async () =>
      dataArrayJson(async () => {
        const result = await query(NEW_CUSTOMERS_SQL);
        return result.rows.map((row) => ({
          ID: row.led_id,
          LedgerType: row.LedgerType,
          LedgerName: row.LedgerName,
          NativeName: row.RegionalName,
          Address: row.Address,
          Email: row.Email,
          Phone: row.Phone,
          TINNumber: row.TINNumber,
        }));
      }),
  ],

  // firefly_api.php lines 3208-3222.
  //
  // The messages say "Current Balance" on both branches. They are copy-pasted
  // from update_ledgerCurrentBalance and describe nothing this endpoint does;
  // they are still what the ERP receives, so they stay.
  [
    "update_customerledgerId",
    async (fd) =>
      trueFalseJson(
        await updateCustomerLedgerId(fd),
        "Current Balance Updation Failed!",
        "Current Balance Updation Succes!",
      ),
  ],
];
