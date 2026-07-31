import type { Cases } from "@/api/_types";
import { query } from "@/lib/db";
import { isPhpEmpty, mysqlInt, mysqlNumeric, phpStr, post } from "@/lib/params";
import { decodeItems } from "@/lib/read";
import { FALSE, trueFalseJson, type TrueFalse } from "@/lib/response";
import { binds, checkedSql, cols, paramOf, setList, upsertByKey } from "@/lib/sql";

/**
 * The 19 columns insert_ledger writes, in the order the PHP INSERT lists them.
 *
 * CentreCode is the one entry that is not a payload field -- see centreCode()
 * below. Every other name is both the $_POST key and the column, including
 * `mypassword`, which is lowercase on both sides.
 */
const FIELDS = [
  "OrganizationCode",
  "CentreCode",
  "LedgerId",
  "LedgerType",
  "LedgerName",
  "RegionalName",
  "LedgerCode",
  "CustomCode",
  "Address",
  "Email",
  "Phone",
  "TINNumber",
  "UserName",
  "mypassword",
  "noofseats",
  "seatstaken",
  "RoutId",
  "CurrentBalance",
  "IsActive",
] as const;

/**
 * The columns the UPDATE assigns -- three fewer than the INSERT.
 *
 * LedgerId moves to the WHERE clause, which is unremarkable. UserName and
 * mypassword are the interesting pair: they appear only in the INSERT, so
 * editing an existing ledger deliberately never overwrites its customer-portal
 * credentials. insert_user does the opposite with its Password column, so the
 * asymmetry is real and must not be smoothed out.
 */
const UPDATE_SET = FIELDS.filter(
  (f) => f !== "LedgerId" && f !== "UserName" && f !== "mypassword",
);

/**
 * The UPDATE therefore needs its own parameter list, not a subset of the
 * INSERT's. Reusing the INSERT ordering would leave UserName and mypassword
 * bound but unmentioned, and PostgreSQL rejects a statement carrying a
 * parameter it cannot type -- see checkedSql. The key goes last, after the SET
 * columns, so the numbering stays gap-free.
 */
const UPDATE_FIELDS = [...UPDATE_SET, "LedgerId"];

const COERCE: Partial<Record<(typeof FIELDS)[number], (v: string | null) => unknown>> = {
  noofseats: mysqlInt, // int(2) -- MySQL display widths carry no meaning
  seatstaken: mysqlInt, // int(2)
  CurrentBalance: mysqlNumeric, // decimal(24,8)
  IsActive: mysqlInt, // tinyint(1) -> smallint
};

/**
 * CentreCode is derived, not posted: PHP computes explode('-', $LedgerId)[1].
 *
 * Element **1**, not 0 -- a LedgerId looks like "MMKP-MMKP-0000000042" and the
 * centre is the middle segment. A LedgerId with no '-' leaves index 1 undefined,
 * which PHP's suppressed warnings turn into null, and null then fails the NOT
 * NULL column on both engines. That is the behaviour, not a bug to route around.
 */
function centreCode(ledgerId: string | null): string | null {
  const parts = (ledgerId ?? "").split("-");
  return parts.length > 1 ? parts[1] : null;
}

/** Binds any ordered subset of the columns, so both statements share one reader. */
function values(fd: FormData, fields: readonly string[]): unknown[] {
  const ledgerId = post(fd, "LedgerId");
  return fields.map((field) => {
    if (field === "CentreCode") return centreCode(ledgerId);
    const raw = post(fd, field);
    const coerce = COERCE[field as (typeof FIELDS)[number]];
    return coerce ? coerce(raw) : raw;
  });
}

const UPDATE_SQL = checkedSql(
  "ledger UPDATE",
  `UPDATE ledger SET ${setList(UPDATE_FIELDS, UPDATE_SET)}
WHERE "LedgerId" = ${paramOf(UPDATE_FIELDS, "LedgerId")}`,
  UPDATE_FIELDS.length,
);

const INSERT_SQL = checkedSql(
  "ledger INSERT",
  `INSERT INTO ledger (${cols(FIELDS)})
VALUES (${binds(FIELDS)})`,
  FIELDS.length,
);

/**
 * Port of insert_ledger($dbh), firefly_api.php line 5061.
 */
export async function insertLedger(fd: FormData): Promise<TrueFalse> {
  try {
    await upsertByKey({
      updateSql: UPDATE_SQL,
      updateParams: values(fd, UPDATE_FIELDS),
      insertSql: INSERT_SQL,
      insertParams: values(fd, FIELDS),
    });
    return "TRUE";
  } catch {
    return "FALSE";
  }
}

// rout has two columns and one quirk: the payload calls it RoutName, the column
// is Name.
const ROUT_UPDATE_SQL = `UPDATE rout SET "Name" = $2 WHERE "RoutId" = $1`;
const ROUT_INSERT_SQL = `INSERT INTO rout ("RoutId", "Name") VALUES ($1, $2)`;

/**
 * Port of insert_rout($dbh), firefly_api.php line 5300.
 *
 * The INSERT branch is guarded by `!empty($RoutId) && !empty($RoutName)` and the
 * UPDATE branch is not, so a payload failing the guard can still rename an
 * existing route but cannot create one. Remember PHP's empty() counts the string
 * "0" as empty -- see isPhpEmpty.
 */
export async function insertRout(fd: FormData): Promise<TrueFalse> {
  const routId = post(fd, "RoutId");
  const routName = post(fd, "RoutName");
  try {
    await upsertByKey({
      updateSql: ROUT_UPDATE_SQL,
      updateParams: [routId, routName],
      insertSql: ROUT_INSERT_SQL,
      insertParams: [routId, routName],
      insertWhen: !isPhpEmpty(routId) && !isPhpEmpty(routName),
    });
    return "TRUE";
  } catch {
    return "FALSE";
  }
}

const BALANCE_SQL = `UPDATE ledger SET "CurrentBalance" = $1 WHERE "LedgerId" = $2`;

/**
 * Port of update_ledgerCurrentBalance($dbh), firefly_api.php line 5335.
 *
 * UPDATE-only and unchecked: a LedgerId that matches nothing still reports
 * success, because PHP never looks at the affected row count.
 */
export async function updateLedgerCurrentBalance(fd: FormData): Promise<TrueFalse> {
  try {
    await query(BALANCE_SQL, [
      mysqlNumeric(post(fd, "CurrentBalance")),
      post(fd, "LedgerId"),
    ]);
    return "TRUE";
  } catch {
    return "FALSE";
  }
}

/** One entry of the ledgerdetails JSON array. */
interface BalanceItem {
  LedgerId?: unknown;
  CurrentBalance?: unknown;
}

/**
 * Port of update_ledgersCurrentBalances($dbh), firefly_api.php line 5385.
 *
 * The plural form: same statement as above, run once per item of a JSON array,
 * which is how the ERP pushes a whole revaluation in one call.
 *
 * Deliberately **not** transactional. A transactional version sits commented out
 * directly above it in the PHP (lines 5351-5382), batching inside
 * beginTransaction/commit with a note about the initial 30k-ledger seed -- but it
 * is not what runs, and this port transcribes what runs. The consequence is real:
 * a failure partway leaves the earlier ledgers updated and reports FALSE.
 *
 * phpStr before mysqlNumeric for the same reason insert_userprivileges needs it:
 * these values come out of json_decode already typed, and PDO::PARAM_STR is what
 * PHP binds them through.
 */
export async function updateLedgersCurrentBalances(
  fd: FormData,
): Promise<TrueFalse> {
  try {
    for (const item of decodeItems<BalanceItem>(post(fd, "ledgerdetails"))) {
      await query(BALANCE_SQL, [
        mysqlNumeric(phpStr(item.CurrentBalance)),
        phpStr(item.LedgerId),
      ]);
    }
    return "TRUE";
  } catch {
    return "FALSE";
  }
}

export const cases: Cases = [
  // firefly_api.php lines 1591-1606. insert_rout runs unconditionally after
  // insert_ledger, neither guarded by the other's result, and no transaction
  // spans the pair -- same shape as the product/warehousestock pairing.
  [
    "insert_ledger",
    async (fd) => {
      const ACTION = await insertLedger(fd);
      const ACTION1 = await insertRout(fd);
      return trueFalseJson(
        ACTION === FALSE || ACTION1 === FALSE ? "FALSE" : "TRUE",
        "Ledger Insertion/Updation Failed!",
        "Ledger Insertion/Updation Success!",
      );
    },
  ],

  // firefly_api.php lines 3176-3190.
  [
    "update_ledgerCurrentBalance",
    async (fd) =>
      trueFalseJson(
        await updateLedgerCurrentBalance(fd),
        "Current Balance Updation Failed!",
        "Current Balance Updation Succes!",
      ),
  ],

  // firefly_api.php lines 3192-3206. Same two messages as the singular case.
  [
    "update_ledgersCurrentBalances",
    async (fd) =>
      trueFalseJson(
        await updateLedgersCurrentBalances(fd),
        "Current Balance Updation Failed!",
        "Current Balance Updation Succes!",
      ),
  ],
];
