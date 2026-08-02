import type { PoolClient } from "pg";

import { isPhpEmpty } from "@/lib/params";

/*
 * ---------------------------------------------------------------------------
 * Document numbering, shared by insert_orderbybilltype (firefly_api.php 7642),
 * insert_ordercancelbybilltype (7835) and insert_salebybilltypewithpdc (8627).
 *
 * All three mint two identifiers from the same billtype row and they are not
 * the same shape:
 *
 *   OrderMasterId / OrderCancelMasterId / SaleMasterId
 *       "<BillTypeId>-<MaxId padded to 10>"      -- always a hyphen
 *   OrderNumber / OrderCancelNumber / VoucherNumber
 *       "<Prefix><Sep><MaxId><Sep><Suffix>"      -- Sep is the org's separator
 *
 * The separator applies to one and not the other, and the PHP writes both a few
 * lines apart in three places, so they are built here once instead.
 * ---------------------------------------------------------------------------
 */

const ORG_SQL = `SELECT "OrganizationCode", "UseBackSlashAsInvSeparator" FROM organization LIMIT 1`;

export interface OrgSeparator {
  OrganizationCode: string;
  Separator: "-" | "/";
}

/**
 * The organization row all three writes open with (7663, 7861, 8688).
 *
 * `LIMIT 1` with no ORDER BY, so with more than one organization row the winner
 * is whatever the engine hands back first. Faithful, and worth knowing when
 * comparing the two stacks: the separator it carries reaches the wire inside
 * every voucher number.
 *
 * OrganizationCode is returned as '' rather than null when the table is empty.
 * insert_ordercancelbybilltype spells that out (`?? ''` at 7867); the other two
 * get there by accident, string-interpolating a null into their INSERT text
 * (7759, 8830), which PHP renders as ''. Binding null instead would fail the
 * NOT NULL column where MySQL writes a blank.
 */
export async function readOrgSeparator(
  client: PoolClient,
): Promise<OrgSeparator> {
  const result = await client.query(ORG_SQL);
  const row = result.rows[0];
  return {
    OrganizationCode: row?.OrganizationCode ?? "",
    // PHP compares == 1 against a tinyint, so only 1 selects the backslash --
    // which is, despite the column name, a forward slash.
    Separator: row?.UseBackSlashAsInvSeparator === 1 ? "/" : "-",
  };
}

/**
 * "<BillTypeId>-<MaxId padded to 10>", the document's primary key.
 *
 * Two of the three build this with a SQL round trip --
 * `SELECT CONCAT(:BillTypeId,'-',LPAD(:MaxId,10,'0'))` at 7750 and 8822 -- and
 * the third does it in PHP with str_pad (8005). Doing it in JS drops four
 * queries and makes all three agree.
 *
 * Divergence, unreachable: LPAD truncates a value longer than 10 characters
 * (measured -- '12345678901' gives '1234567890' on both MySQL and PostgreSQL)
 * while str_pad and padStart do not. MaxId comes from an `integer` column, so
 * it caps at 10 digits and neither branch can be reached.
 *
 * Always a hyphen, never the org separator -- see the header.
 */
export function masterIdOf(billTypeId: string, maxId: number): string {
  return `${billTypeId}-${String(maxId).padStart(10, "0")}`;
}

/**
 * "<Prefix><Sep><MaxId><Sep><Suffix>", the human-facing document number.
 *
 * Each affix is appended only when PHP's empty() says it is present, so a
 * Prefix of "0" is dropped along with '' and null -- the "0" trap from
 * params.ts, reached here through billtype data rather than a payload field.
 */
export function voucherNumberOf(
  prefix: string | null,
  suffix: string | null,
  separator: string,
  maxId: number,
): string {
  let voucher = "";
  if (!isPhpEmpty(prefix)) {
    voucher = `${prefix}${separator}`;
  }
  voucher += String(maxId);
  if (!isPhpEmpty(suffix)) {
    voucher += `${separator}${suffix}`;
  }
  return voucher;
}

/**
 * Hand the series on to the next document (7780, 8068, 8890).
 *
 * `next` is computed by the caller rather than as `SET StartNumber = $1 + 1` in
 * SQL. The PHP does it both ways -- MySQL arithmetic on a PARAM_STR bind in two
 * of the three, PHP arithmetic in the other -- and doing it in JS everywhere
 * keeps the increment where it can be read next to the MaxId that produced it.
 */
export async function bumpStartNumber(
  client: PoolClient,
  billTypeId: string | null,
  next: number,
): Promise<void> {
  await client.query(
    `UPDATE billtype SET "StartNumber" = $1 WHERE "BillTypeId" = $2`,
    [next, billTypeId],
  );
}
