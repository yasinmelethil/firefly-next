import type { Cases } from "@/api/_types";
import { query } from "@/lib/db";
import { isPhpEmpty, mysqlInt, mysqlNumeric, phpStr, post } from "@/lib/params";
import { decodeItems, emptySentinelJson } from "@/lib/read";
import {
  FALSE,
  MESSAGE_SUCCESS,
  STATUS_SUCCESS,
  phpDie,
  phpJson,
  trueFalseJson,
  type TrueFalse,
} from "@/lib/response";
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

/*
 * ---------------------------------------------------------------------------
 * The three ledger reads the POS calls: the full list, a name search, and the
 * bank accounts.
 *
 * All three return raw rows -- the case blocks echo $DATA straight into
 * json_encode with no key rebuild -- so the SELECT column list below IS the
 * JSON key list, in this order. They also all ship `mypassword`, the
 * customer-portal credential, in the clear. Faithful; the README already flags
 * that copying those values across is a separate security decision.
 * ---------------------------------------------------------------------------
 */

/** The 16 columns shared by get_ledgers and get_ledgersbyname. */
const LEDGER_COLUMNS = `"LedgerName", "RegionalName", "LedgerCode", "CustomCode", "Address", "Email", "Phone", "TINNumber", "noofseats", "seatstaken", "UserName", "mypassword", "RoutId", "CurrentBalance", "IsActive"`;

// LedgerType 'C' is cash and 'B' is bank; this is every ledger that is neither.
const LEDGERS_SQL = `SELECT "LedgerId", ${LEDGER_COLUMNS}
FROM ledger WHERE "LedgerType" != 'C' AND "LedgerType" != 'B'`;

/**
 * get_ledgersbyname, both branches (firefly_api.php 4470-4503).
 *
 * Three things differ from get_ledgers beyond the search:
 *
 *   1. LedgerId falls back to led_id when blank. In MySQL that is
 *      COALESCE(NULLIF(LedgerId,''), led_id) over a varchar and an int, which
 *      PostgreSQL refuses outright -- COALESCE cannot unify the two. MySQL
 *      aggregates them to varchar and PDO reports VAR_STRING, so PHP emits a
 *      JSON *string*; "led_id"::text reproduces that exactly. The blank rows
 *      are the not-yet-synced customers get_newcustomers drains.
 *   2. The LIKE is built with || rather than concat(). PostgreSQL's concat()
 *      ignores NULL, so a missing Searchstring would become '%%' and match
 *      every ledger, where MySQL's CONCAT returns NULL and matches none.
 *   3. The RoutId branch also lets LedgerType 'O' through regardless of route.
 *
 * A blank Searchstring matches everything, which is what the POS actually
 * sends to populate its initial list.
 */
const LEDGERS_BY_NAME_SQL = `SELECT COALESCE(NULLIF("LedgerId", ''), "led_id"::text) AS "LedgerId", ${LEDGER_COLUMNS}
FROM ledger
WHERE "LedgerType" != 'C' AND "LedgerType" != 'B' AND "LedgerName" LIKE '%' || $1 || '%'
AND "LedgerId" NOT IN (SELECT "LedgerId" FROM userledgerprivilege WHERE "Block" = 1 AND "UserId" = $2)
ORDER BY "LedgerName"`;

const LEDGERS_BY_NAME_ROUT_SQL = `SELECT COALESCE(NULLIF("LedgerId", ''), "led_id"::text) AS "LedgerId", ${LEDGER_COLUMNS}
FROM ledger
WHERE "LedgerType" != 'C' AND "LedgerType" != 'B' AND "LedgerName" LIKE '%' || $1 || '%'
AND "LedgerId" NOT IN (SELECT "LedgerId" FROM userledgerprivilege WHERE "Block" = 1 AND "UserId" = $2)
AND ("RoutId" = $3 OR "LedgerType" = 'O')
ORDER BY "LedgerName"`;

/**
 * get_bankdetails (firefly_api.php 4593-4607). Four columns, not sixteen.
 *
 * The live POS does not send UserId at all, so the bound value is null, the
 * NOT IN subquery matches nothing, and the privilege filter is a no-op. Same on
 * both engines: `x NOT IN (empty set)` is true.
 */
const BANK_DETAILS_SQL = `SELECT "LedgerId", "LedgerName", "CurrentBalance", "IsActive"
FROM ledger WHERE "LedgerType" = 'B'
AND "LedgerId" NOT IN (SELECT "LedgerId" FROM userledgerprivilege WHERE "Block" = 1 AND "UserId" = $1)`;

/*
 * ---------------------------------------------------------------------------
 * The customer portal's credentials: one login, two uniqueness probes, and the
 * endpoint that changes them.
 *
 * All four work on `ledger`, including check_username -- despite its name, it
 * probes ledger.UserName, not "user".UserName. The staff login lives in
 * src/api/user.ts.
 * ---------------------------------------------------------------------------
 */

/**
 * customer_login, firefly_api.php line 4628 -- the SELECT at 4633-4637.
 *
 * Longhand rather than assembled, for the same reason as LOGIN_SQL in user.ts:
 * a `${}` makes scripts/check-sql.ps1 skip the statement, and this is one worth
 * PREPARing. Three transcription fixes, none of which reaches the wire:
 *
 *   1. The PHP selects l.UserName and l.mypassword **twice** each. PDO's
 *      FETCH_OBJ and node-postgres both keep the first occurrence's position
 *      and emit one key, so the duplicates are simply dropped -- the same call
 *      the three sale reads made for om.PartyDetails.
 *   2. The organization columns are spelled DefCustSOBilltype / DefCustSIBilltype
 *      / DefCustSRBilltype in the PHP, a casing matching neither the table nor
 *      the write path. MySQL folds it; PostgreSQL will not. Corrected here to
 *      the spellings in db/tables/organization.sql, which carries a note asking
 *      for exactly this. All three are aliased, so the JSON keys are unchanged.
 *   3. IsActive=1 filters inactive customers out, and they get the same generic
 *      "check Username or Password" message -- no separate "account disabled".
 *
 * mypassword goes back to the caller in the clear, as it does in get_ledgers.
 */
const CUSTOMER_LOGIN_SQL = `SELECT l."OrganizationCode", l."LedgerId", l."LedgerType", l."LedgerName", l."RegionalName" AS "LedgerRegionalName", l."LedgerCode", l."CustomCode", l."UserName", l."mypassword",
l."Address", l."Email", l."Phone", l."TINNumber", l."noofseats", l."seatstaken", l."RoutId",
l."CurrentBalance", 'र' AS "CurrencySymbol", 'p' AS "SubCurrencySymbol", og."DefCustSOBillType" AS "DefSOBillType",
og."DefCustSIBillType" AS "DefSIBillType", og."DefCustSRBillType" AS "DefSRBillType", og."DefCustBank" AS "DefCustBank",
og."DefCustRate", l."IsActive"
FROM ledger l JOIN organization og ON l."OrganizationCode" = og."OrganizationCode"
WHERE l."UserName" = $1 AND l."mypassword" = $2 AND l."IsActive" = 1`;

/*
 * check_username (5274) and check_usernamewithledger (5286).
 *
 * MySQL's IF(cond, a, b) becomes CASE WHEN -- an exact translation, unlike the
 * four constructs the README lists as having no PostgreSQL equivalent. The
 * parenthesised shape matches the Isparent probe in src/api/product.ts, and
 * `SELECT "UserName"` inside the EXISTS is the PHP's own spelling rather than
 * the more idiomatic SELECT 1; the planner treats them identically.
 *
 * Both return the *string* 'true' or 'false', never the 'EMPTY' sentinel, so
 * the case blocks' `$DATA == $EMPTY` branch and their 'No DATA found!!' message
 * are dead and the response is always SUCCESS. Note for callers: "false" is a
 * non-empty string and therefore truthy in JavaScript -- compare === "true".
 *
 * Neither has a try/catch, so a DB error reaches route.ts's four-key envelope.
 */
const CHECK_USERNAME_SQL = `SELECT (CASE WHEN EXISTS (
    SELECT "UserName" FROM ledger WHERE "UserName" = $1
) THEN 'true' ELSE 'false' END) AS "Result"`;

// The edit-form variant: does any *other* ledger already hold this username?
// A null LedgerId makes "LedgerId" != $2 unknown, so EXISTS is false and the
// answer is 'false' -- identical to MySQL, where != NULL is likewise never true.
const CHECK_USERNAME_WITH_LEDGER_SQL = `SELECT (CASE WHEN EXISTS (
    SELECT "UserName" FROM ledger WHERE "UserName" = $1 AND "LedgerId" != $2
) THEN 'true' ELSE 'false' END) AS "Result"`;

const CHANGE_CREDENTIALS_SQL = `UPDATE ledger SET "UserName" = $1, "mypassword" = $2
WHERE "LedgerId" = $3`;

/**
 * Port of change_ledgerusernameandpassword($dbh), firefly_api.php line 5218.
 *
 * Returns 'TRUE' or a Response, which is unlike every other helper here, because
 * the PHP catch calls `die($e->getMessage())` instead of returning 'FALSE'. The
 * body is then raw driver text with no JSON at all, and the case's echo never
 * runs -- so its "User Name And Password Change Failed!" message is unreachable.
 * See phpDie in src/lib/response.ts.
 *
 * The payload key is `mypassword`, not `Password` as in the two login endpoints.
 * A LedgerId matching nothing updates no rows and still reports success: PHP
 * never looks at the affected count. The `$data = $query->fetch()` at line 5230
 * is a fetch on an UPDATE and is not ported.
 */
export async function changeLedgerUsernameAndPassword(
  fd: FormData,
): Promise<TrueFalse | Response> {
  try {
    await query(CHANGE_CREDENTIALS_SQL, [
      post(fd, "UserName"),
      post(fd, "mypassword"),
      post(fd, "LedgerId"),
    ]);
    return "TRUE";
  } catch (e) {
    return phpDie(e instanceof Error ? e.message : String(e));
  }
}

export const cases: Cases = [
  // firefly_api.php lines 430-442.
  [
    "get_ledgers",
    async () =>
      emptySentinelJson("No Ledgers found!!", async () => {
        const result = await query(LEDGERS_SQL);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 484-496. Same empty message as get_ledgers.
  [
    "get_ledgersbyname",
    async (fd) =>
      emptySentinelJson("No Ledgers found!!", async () => {
        const routId = post(fd, "RoutId");
        const params = [post(fd, "Searchstring"), post(fd, "UserId")];
        // PHP branches on empty($RoutId), so "0" takes the no-route branch.
        const result = isPhpEmpty(routId)
          ? await query(LEDGERS_BY_NAME_SQL, params)
          : await query(LEDGERS_BY_NAME_ROUT_SQL, [...params, routId]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 541-553.
  [
    "get_bankdetails",
    async (fd) =>
      emptySentinelJson("No Cash/Bank found!!", async () => {
        const result = await query(BANK_DETAILS_SQL, [post(fd, "UserId")]);
        return result.rows;
      }),
  ],

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

  // firefly_api.php lines 571-585. Byte-identical to the login case in
  // src/api/user.ts, message included -- only the getter differs.
  [
    "customer_login",
    async (fd) =>
      emptySentinelJson("Login Failed check Username or Password !!", async () => {
        // The payload key is Password even though the column is mypassword
        // (firefly_api.php 4632 binds $_POST['Password'] to :Password, matched
        // against l.mypassword). change_ledgerusernameandpassword below reads
        // the *other* spelling, $_POST['mypassword']. Do not harmonise them.
        const result = await query(CUSTOMER_LOGIN_SQL, [
          post(fd, "UserName"),
          post(fd, "Password"),
        ]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 1682-1694.
  [
    "check_username",
    async (fd) => {
      const result = await query(CHECK_USERNAME_SQL, [post(fd, "UserName")]);
      return phpJson({
        STATUS: STATUS_SUCCESS,
        MESSAGE: MESSAGE_SUCCESS,
        DATA: result.rows[0].Result,
      });
    },
  ],

  // firefly_api.php lines 1696-1708. Same envelope, same dead branch.
  [
    "check_usernamewithledger",
    async (fd) => {
      const result = await query(CHECK_USERNAME_WITH_LEDGER_SQL, [
        post(fd, "UserName"),
        post(fd, "LedgerId"),
      ]);
      return phpJson({
        STATUS: STATUS_SUCCESS,
        MESSAGE: MESSAGE_SUCCESS,
        DATA: result.rows[0].Result,
      });
    },
  ],

  // firefly_api.php lines 1624-1638. The helper dies rather than returning
  // FALSE, so the failure message below can never be reached.
  [
    "change_ledgerusernameandpassword",
    async (fd) => {
      const ACTION = await changeLedgerUsernameAndPassword(fd);
      if (ACTION instanceof Response) return ACTION;
      return trueFalseJson(
        ACTION,
        "User Name And Password Change Failed!",
        "User Name And Password Change Success!",
      );
    },
  ],
];
