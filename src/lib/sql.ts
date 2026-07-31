import { withTransaction } from "@/lib/db";

/**
 * SQL text builders shared by every ported endpoint.
 *
 * Each PHP handler names its columns three times -- in the INSERT column list, in
 * the VALUES list and in the UPDATE SET list -- and gets them out of order often
 * enough that transcribing by hand is the main source of porting mistakes. The
 * ports instead declare one ordered FIELDS array per statement and derive all
 * three from it, so the array is also the bind order.
 *
 * Identifiers are emitted double-quoted because the schema mirrors MySQL's
 * CamelCase column names, which PostgreSQL folds to lowercase unquoted.
 */

/** `"A", "B"` -- an INSERT column list. */
export function cols(fields: readonly string[]): string {
  return fields.map((f) => `"${f}"`).join(", ");
}

/** `$1, $2` -- a VALUES list matching cols() position for position. */
export function binds(fields: readonly string[]): string {
  return fields.map((_, i) => `$${i + 1}`).join(", ");
}

/**
 * `"A" = $1, "B" = $2` -- an UPDATE SET list, same positions again.
 *
 * `only` narrows the list while keeping each field's original placeholder, for
 * the handlers whose UPDATE assigns fewer columns than their INSERT (the key
 * column is usually bound but appears in the WHERE clause instead, and
 * insert_ledger leaves the credential columns out of the UPDATE entirely). One
 * params array still serves both statements.
 */
export function setList(
  fields: readonly string[],
  only?: readonly string[],
): string {
  const chosen = only ?? fields;
  return chosen.map((f) => `"${f}" = ${paramOf(fields, f)}`).join(", ");
}

/**
 * The placeholder a field already occupies, for reusing it as the WHERE key.
 *
 * The PHP names one parameter twice in a single statement (`SET BillTypeId=:x ...
 * WHERE BillTypeId=:x`), which works only because PDO emulates prepares.
 * node-postgres is positional, so the same $n is written twice instead.
 *
 * Throws rather than returning a bad index: a typo here would silently bind the
 * wrong column into the WHERE clause and update every row in the table.
 */
export function paramOf(fields: readonly string[], name: string): string {
  const i = fields.indexOf(name);
  if (i < 0) {
    throw new Error(`paramOf: "${name}" is not in the field list`);
  }
  return `$${i + 1}`;
}

/**
 * Fails at import time if a generated statement leaves any parameter dangling.
 *
 * PostgreSQL infers each parameter's type from where it is used, so a $n that
 * the statement never mentions has no type to infer and the whole statement is
 * rejected with "could not determine data type of parameter $n". It is an easy
 * shape to produce by accident: derive an UPDATE's SET list from a field array
 * by dropping a few columns, and the dropped ones leave holes in the numbering.
 * insert_ledger does exactly that with UserName and mypassword.
 *
 * Uncaught, that surfaces as the endpoint quietly answering 'FALSE' -- every
 * handler swallows its exception, because the PHP does. Checking here turns it
 * into a startup error naming the statement instead.
 */
export function checkedSql(label: string, sql: string, paramCount: number): string {
  for (let i = 1; i <= paramCount; i++) {
    // Negative lookahead so $1 is not considered present just because $12 is.
    if (!new RegExp(`\\$${i}(?![0-9])`).test(sql)) {
      throw new Error(
        `${label}: parameter $${i} of ${paramCount} is never referenced. ` +
          `PostgreSQL cannot infer its type and will reject the statement.`,
      );
    }
  }
  return sql;
}

export interface UpsertPlan {
  updateSql: string;
  updateParams: unknown[];
  insertSql: string;
  insertParams: unknown[];
  /**
   * Gate on the INSERT branch only, defaulting to true. insert_rout guards its
   * INSERT with `!empty($RoutId) && !empty($RoutName)` while leaving the UPDATE
   * branch unguarded, so a payload that fails the check must still be able to
   * rename an existing route.
   */
  insertWhen?: boolean;
}

/**
 * The PHP upsert shape: probe with SELECT IF(EXISTS(...)), then branch to UPDATE
 * or INSERT. Reproduced as UPDATE-then-INSERT-if-nothing-matched, in one
 * transaction -- one round trip fewer and the same observable behaviour.
 *
 * Not collapsible into ON CONFLICT for most tables: the conflict target would
 * have to be the business key (BillTypeId, LedgerId, UserId, TaxId,
 * InventoryGroupId), and none of them carries a unique index. The schema leaves
 * them non-unique on purpose so the port never rejects a write MySQL accepts.
 * organization is the exception and still uses ON CONFLICT directly.
 *
 * This relies on a PostgreSQL detail: rowCount after UPDATE counts rows that
 * MATCHED the WHERE clause, so a save that changes nothing still reports 1 and
 * correctly stays on the update path. MySQL's affected_rows would report 0 there
 * and send us on to a duplicate INSERT.
 *
 * updateParams and insertParams are separate because two handlers bind different
 * column sets per branch: insert_ledger's UPDATE omits UserName/mypassword, and
 * insert_user's UPDATE carries UserId only in the WHERE clause.
 */
export async function upsertByKey(plan: UpsertPlan): Promise<void> {
  await withTransaction(async (client) => {
    const updated = await client.query(plan.updateSql, plan.updateParams);
    if (updated.rowCount && updated.rowCount > 0) {
      return;
    }
    if (plan.insertWhen === false) {
      return;
    }
    await client.query(plan.insertSql, plan.insertParams);
  });
}
