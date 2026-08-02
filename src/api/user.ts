import type { Cases } from "@/api/_types";
import { query } from "@/lib/db";
import { mysqlInt, phpStr, post } from "@/lib/params";
import { emptySentinelJson } from "@/lib/read";
import {
  FALSE,
  MESSAGE_ERROR,
  MESSAGE_SUCCESS,
  STATUS_ERROR,
  STATUS_SUCCESS,
  phpJson,
  trueFalseJson,
  type TrueFalse,
} from "@/lib/response";
import { binds, checkedSql, cols, paramOf, setList, upsertByKey } from "@/lib/sql";

/*
 * ---------------------------------------------------------------------------
 * insert_user, firefly_api.php line 4731.
 *
 * Every reference to the "user" table needs double quotes: unquoted, `user`
 * resolves to PostgreSQL's CURRENT_USER function.
 * ---------------------------------------------------------------------------
 */

/** The 22 columns insert_user writes, in the order the PHP INSERT lists them. */
const USER_FIELDS = [
  "OrganizationCode",
  "UserId",
  "Name",
  "UserName",
  "Password",
  "Phone",
  "DefSOBillType",
  "DefSOCBillType",
  "DefSIBillType",
  "DefRVBillType",
  "DefPVBillType",
  "DefPOBillType",
  "DefSRBillType",
  "DefJVBillType",
  "SaleTaxIncDiscount",
  "DefCashLedger",
  "DefCardBank",
  "RoutId",
  "UseOnlyRoutLedgers",
  "IsAdmin",
  "DefSaleRate",
  "DefWarehouseId",
] as const;

/**
 * The UPDATE assigns everything except UserId, which moves to the WHERE clause.
 *
 * Password *is* in the list -- updating a user overwrites their password.
 * insert_ledger deliberately does the opposite with its credential columns, so
 * do not make the two consistent.
 */
const USER_UPDATE_SET = USER_FIELDS.filter((f) => f !== "UserId");

const USER_COERCE: Partial<
  Record<(typeof USER_FIELDS)[number], (v: string | null) => unknown>
> = {
  SaleTaxIncDiscount: mysqlInt, // tinyint -> smallint
  UseOnlyRoutLedgers: mysqlInt,
  IsAdmin: mysqlInt, // tinyint(4), not tinyint(1)
};

// UserId leaves the SET list but is still bound as the WHERE key, so unlike
// insert_ledger this UPDATE can share the INSERT's parameter ordering.
const USER_UPDATE_SQL = checkedSql(
  "user UPDATE",
  `UPDATE "user" SET ${setList(USER_FIELDS, USER_UPDATE_SET)}
WHERE "UserId" = ${paramOf(USER_FIELDS, "UserId")}`,
  USER_FIELDS.length,
);

const USER_INSERT_SQL = checkedSql(
  "user INSERT",
  `INSERT INTO "user" (${cols(USER_FIELDS)})
VALUES (${binds(USER_FIELDS)})`,
  USER_FIELDS.length,
);

/**
 * Port of insert_user($dbh), firefly_api.php line 4731.
 *
 * The RoutId column is spelled "Routid" in the MySQL DDL and RoutId everywhere
 * in the PHP, including the login SELECT at line 4614 that puts it on the wire.
 * db/tables/user.sql adopts RoutId; see the note there.
 */
export async function insertUser(fd: FormData): Promise<TrueFalse> {
  const params = USER_FIELDS.map((field) => {
    const raw = post(fd, field);
    const coerce = USER_COERCE[field];
    return coerce ? coerce(raw) : raw;
  });

  try {
    await upsertByKey({
      updateSql: USER_UPDATE_SQL,
      updateParams: params,
      insertSql: USER_INSERT_SQL,
      insertParams: params,
    });
    return "TRUE";
  } catch {
    return "FALSE";
  }
}

/*
 * ---------------------------------------------------------------------------
 * Per-screen privileges.
 * ---------------------------------------------------------------------------
 */

/**
 * The 16 permission flags, in the order the PHP names them everywhere -- the
 * UPDATE SET list, the INSERT column list and the SELECT that feeds
 * get_userprivilegeslist. Column order reaches the wire on that last one, so
 * this array is the single source for all three.
 */
const PRIVILEGE_FLAGS = [
  "CanRead",
  "CanCreate",
  "CanUpdate",
  "CanDelete",
  "CanPrint",
  "CanEditRate",
  "MRP",
  "MOP",
  "MLOP",
  "SaleRate",
  "AvgRate",
  "PurchaseRate",
  "LastPurchaseRate",
  "Size",
  "Colour",
  "RateSelection",
] as const;

const PRIVILEGE_FIELDS = ["UserId", "ViewName", ...PRIVILEGE_FLAGS] as const;

const PRIVILEGE_UPDATE_SQL = checkedSql(
  "userprivilege UPDATE",
  `UPDATE userprivilege SET ${setList(PRIVILEGE_FIELDS, PRIVILEGE_FLAGS)}
WHERE "UserId" = $1 AND "ViewName" = $2`,
  PRIVILEGE_FIELDS.length,
);

// PHP guards this insert with a second probe -- only write privileges for a user
// that exists. Folding it into the INSERT makes the guard atomic instead of a
// second check-then-write race.
//
// The casts are required, not decorative: PostgreSQL does not propagate target
// column types through a SELECT list the way it does through VALUES, and $1
// appears both there and in the EXISTS comparison, which without a cast deduces
// two different types for one parameter.
const PRIVILEGE_INSERT_SQL = `INSERT INTO userprivilege (${cols(PRIVILEGE_FIELDS)})
SELECT $1::varchar, $2::varchar, ${PRIVILEGE_FLAGS.map(
  (_, i) => `$${i + 3}::smallint`,
).join(", ")}
WHERE EXISTS (SELECT 1 FROM "user" WHERE "UserId" = $1)`;

/** One entry of the ViewPrivileges JSON array. */
type PrivilegeItem = Record<string, unknown>;

/**
 * Decodes a JSON payload field the way PHP does.
 *
 * json_decode returns null for a missing or malformed value, foreach then warns
 * (suppressed by error_reporting(0)), and the function still returns 'TRUE'. So
 * a bad blob is not an error, it is a no-op.
 */
function decodeItems(raw: string | null): PrivilegeItem[] {
  if (!raw) return [];
  try {
    const decoded: unknown = JSON.parse(raw);
    return Array.isArray(decoded) ? (decoded as PrivilegeItem[]) : [];
  } catch {
    return [];
  }
}

/**
 * Port of insert_userprivileges($dbh), firefly_api.php line 4846.
 *
 * UserId comes from $_POST, not from the item -- every row in one call belongs
 * to the same user, and an item carrying its own UserId is ignored.
 *
 * The flags arrive as JSON *booleans*. phpStr reproduces PDO::PARAM_STR, where
 * true binds as "1" and false as "", which mysqlInt then turns into 1 and 0. A
 * plain String() would yield "true"/"false" and mysqlInt would score both as 0,
 * silently revoking every permission granted. See phpStr in src/lib/params.ts.
 */
export async function insertUserPrivileges(fd: FormData): Promise<TrueFalse> {
  try {
    const userId = post(fd, "UserId");
    for (const item of decodeItems(post(fd, "ViewPrivileges"))) {
      const params = [
        userId,
        phpStr(item.ViewName),
        ...PRIVILEGE_FLAGS.map((flag) => mysqlInt(phpStr(item[flag]))),
      ];
      await upsertByKey({
        updateSql: PRIVILEGE_UPDATE_SQL,
        updateParams: params,
        insertSql: PRIVILEGE_INSERT_SQL,
        insertParams: params,
      });
    }
    return "TRUE";
  } catch {
    return "FALSE";
  }
}

/*
 * ---------------------------------------------------------------------------
 * Per-ledger privileges. Two endpoints write this table: a batch one called from
 * the insert_user case, and a single-row one with its own api name.
 * ---------------------------------------------------------------------------
 */

const LEDGER_PRIV_UPDATE_SQL = `UPDATE userledgerprivilege SET "Block" = $3
WHERE "UserId" = $1 AND "LedgerId" = $2`;

// Guarded like the privilege insert above -- only write for a ledger that
// exists. $2 is the parameter used twice here, so it is the one that must carry
// a cast.
const LEDGER_PRIV_INSERT_GUARDED_SQL = `INSERT INTO userledgerprivilege ("UserId", "LedgerId", "Block")
SELECT $1::varchar, $2::varchar, $3::smallint
WHERE EXISTS (SELECT 1 FROM ledger WHERE "LedgerId" = $2)`;

const LEDGER_PRIV_INSERT_SQL = `INSERT INTO userledgerprivilege ("UserId", "LedgerId", "Block")
VALUES ($1, $2, $3)`;

/**
 * Port of insert_userledgerprivileges($dbh), firefly_api.php line 4800.
 *
 * Reads the Privileges JSON array. Note the item key is BlockTransactions while
 * the column is Block -- the two names disagree, as they do in the product
 * endpoint's stock payload.
 */
export async function insertUserLedgerPrivileges(fd: FormData): Promise<TrueFalse> {
  try {
    for (const item of decodeItems(post(fd, "Privileges"))) {
      const params = [
        phpStr(item.UserId),
        phpStr(item.LedgerId),
        mysqlInt(phpStr(item.BlockTransactions)),
      ];
      await upsertByKey({
        updateSql: LEDGER_PRIV_UPDATE_SQL,
        updateParams: params,
        insertSql: LEDGER_PRIV_INSERT_GUARDED_SQL,
        insertParams: params,
      });
    }
    return "TRUE";
  } catch {
    return "FALSE";
  }
}

/**
 * Port of insert_userledgerprivilege1($dbh), firefly_api.php line 4939.
 *
 * The single-row sibling of the above, and it differs in two ways beyond that:
 * it reads UserId/LedgerId/Block straight from $_POST (the payload key is Block,
 * not BlockTransactions), and its INSERT carries **no ledger-exists guard**.
 */
export async function insertUserLedgerPrivilege1(fd: FormData): Promise<TrueFalse> {
  try {
    const params = [
      post(fd, "UserId"),
      post(fd, "LedgerId"),
      mysqlInt(post(fd, "Block")),
    ];
    await upsertByKey({
      updateSql: LEDGER_PRIV_UPDATE_SQL,
      updateParams: params,
      insertSql: LEDGER_PRIV_INSERT_SQL,
      insertParams: params,
    });
    return "TRUE";
  } catch {
    return "FALSE";
  }
}

/*
 * ---------------------------------------------------------------------------
 * The two read endpoints.
 * ---------------------------------------------------------------------------
 */

/**
 * Transcribed from get_userprivileges, firefly_api.php line 4699. No ORDER BY
 * there and none here: row order is whatever the engine returns.
 *
 * Three cases read this statement and no two of them shape it the same way, so
 * changing it to suit one will break the others:
 *
 *   - get_userprivileges echoes the rows raw -- UserId stays on the wire and the
 *     flags stay smallint 0/1 -- through the 'EMPTY' sentinel envelope;
 *   - get_userprivilegeslist drops UserId and casts all sixteen flags to bool;
 *   - get_userprivileges_with_properties keeps UserId, splits the flags into six
 *     top-level keys and a nested Properties object, and has its own envelope
 *     again.
 */
const GET_PRIVILEGES_SQL = `SELECT "UserId", "ViewName", ${cols(PRIVILEGE_FLAGS)}
FROM userprivilege WHERE "UserId" = $1`;

/**
 * How get_userprivileges_with_properties splits the same sixteen flags.
 *
 * Its outer query (firefly_api.php 4662) selects UserId, ViewName and the six
 * Can* flags; its inner one (4672-4674) selects the other ten. The split falls
 * exactly on index 6 of PRIVILEGE_FLAGS, so both lists come from that array
 * rather than being retyped -- and the order of each reaches the wire.
 */
const OUTER_FLAGS = PRIVILEGE_FLAGS.slice(0, 6);
const PROPERTY_FLAGS = PRIVILEGE_FLAGS.slice(6);

/**
 * login, firefly_api.php line 4609 -- the SELECT at line 4614.
 *
 * Written out longhand rather than assembled from a field array: this is the
 * statement most worth having scripts/check-sql.ps1 actually PREPARE, and that
 * script skips anything containing a `${}` because it cannot resolve one.
 *
 * Two things to leave alone:
 *
 *   - 'र' is U+0930 DEVANAGARI LETTER RA, not a rupee sign and not "Rs". PHP's
 *     json_encode emits it as र and phpJsonEncode reproduces that, which
 *     keeps the whole response body ASCII.
 *   - Password ships back to the client in the clear, as does ledger.mypassword
 *     in customer_login and the ledger reads. Faithful; see the README.
 *
 * user_id is deliberately absent -- it is a PostgreSQL-side surrogate key and
 * MySQL's SELECT list never mentioned it.
 */
const LOGIN_SQL = `SELECT "UserId", "Name", "UserName", "Password", "Phone", "OrganizationCode",
'र' AS "CurrencySymbol", 'p' AS "SubCurrencySymbol",
"DefSOBillType", "DefSOCBillType", "DefSIBillType", "DefRVBillType", "DefPVBillType", "DefPOBillType", "DefSRBillType", "DefJVBillType",
"SaleTaxIncDiscount", "DefCashLedger", "DefCardBank", "RoutId", "UseOnlyRoutLedgers", "IsAdmin", "DefSaleRate", "DefWarehouseId"
FROM "user" WHERE "UserName" = $1 AND "Password" = $2`;

/**
 * get_userviewprivileges, firefly_api.php line 4712.
 *
 * The same table as GET_PRIVILEGES_SQL and almost the same columns, but a
 * completely different endpoint contract, so the two do not share a statement:
 *
 *   - it narrows to one ViewName rather than returning every screen;
 *   - its case block (615-629) echoes the raw rows, so UserId stays on the wire
 *     and the flags stay as the smallints 0/1. get_userprivilegeslist drops
 *     UserId and casts all sixteen to booleans;
 *   - it uses the 'EMPTY' sentinel envelope, with the message 'DATA NOT FOUND !!'
 *     -- spacing and all -- where the other uses "Succes !"/"Failed !".
 */
const GET_VIEW_PRIVILEGES_SQL = `SELECT "UserId", "ViewName", ${cols(PRIVILEGE_FLAGS)}
FROM userprivilege WHERE "UserId" = $1 AND "ViewName" = $2`;

export const cases: Cases = [
  // firefly_api.php lines 555-569.
  //
  // The whole of the ERP's authentication: username and password compared as
  // plaintext strings in the WHERE clause, every matching row returned. No
  // hashing, no session, no token, and the case is reachable unauthenticated
  // like all 203 others. Faithful -- see "Hardening" in the README for what
  // changing any of that would cost.
  //
  // fetchAll, not fetch, so DATA is an array even for the single row a caller
  // expects; clients read DATA[0]. Duplicate UserNames would return several.
  [
    "login",
    async (fd) =>
      emptySentinelJson("Login Failed check Username or Password !!", async () => {
        const result = await query(LOGIN_SQL, [
          post(fd, "UserName"),
          post(fd, "Password"),
        ]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 600-614.
  //
  // No isset guard on UserId, unlike get_userprivileges_with_properties below:
  // a missing UserId binds null, matches nothing, and comes back as the 'EMPTY'
  // sentinel with 'DATA NOT FOUND !!'. The two disagree on purpose.
  [
    "get_userprivileges",
    async (fd) =>
      emptySentinelJson("DATA NOT FOUND !!", async () => {
        const result = await query(GET_PRIVILEGES_SQL, [post(fd, "UserId")]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 586-598.
  //
  // Written inline because none of the four envelopes in src/lib/read.ts fits:
  // this getter has four exits and three of them are unlike anything else in
  // the file.
  //
  //   1. UserId absent -> the *string* 'UserId is required' lands in DATA, and
  //      because it is non-empty and not 'EMPTY' the case calls that SUCCESS.
  //      The guard is isset(), so UserId="" passes it and falls through to the
  //      query.
  //   2. Zero rows -> the getter returns null (with the PHP author's own
  //      comment saying so, rather than the 'EMPTY' every sibling uses), so
  //      !empty($DATA) is false, no branch runs, and the defaults from lines
  //      32-33 survive: ERROR / 'Something Went Wrong!!!' / DATA null. That is
  //      a fifth envelope -- untouchedDefaultsJson gives [] here, not null.
  //   3. PDOException -> caught *locally* and returned as a string, so it too
  //      reports SUCCESS and must not reach the four-key global handler.
  //
  // The case's own 'No Product found!!' at line 591 is copy-pasted from
  // get_product_with_category_withstock and unreachable, since the getter never
  // returns 'EMPTY'.
  //
  // The PHP re-queries userprivilege once per row to build Properties. That
  // inner query is a primary-key lookup of the row the outer query just
  // returned, so it is collapsed into one statement here -- unlike the sync
  // loop's N+1, which is kept because batching it would change row ordering.
  // Properties is assigned as a dynamic property in PHP, so it serialises last.
  [
    "get_userprivileges_with_properties",
    async (fd) => {
      const userId = post(fd, "UserId");
      if (userId === null) {
        return phpJson({
          STATUS: STATUS_SUCCESS,
          MESSAGE: MESSAGE_SUCCESS,
          DATA: "UserId is required",
        });
      }

      try {
        const result = await query(GET_PRIVILEGES_SQL, [userId]);
        if (result.rows.length === 0) {
          return phpJson({
            STATUS: STATUS_ERROR,
            MESSAGE: MESSAGE_ERROR,
            DATA: null,
          });
        }

        const DATA = result.rows.map((row) => {
          // Key by key, so the order matches PHP's: the outer SELECT's columns,
          // then Properties appended after them.
          const item: Record<string, unknown> = {
            UserId: row.UserId,
            ViewName: row.ViewName,
          };
          for (const flag of OUTER_FLAGS) {
            item[flag] = row[flag];
          }
          const properties: Record<string, unknown> = {};
          for (const flag of PROPERTY_FLAGS) {
            properties[flag] = row[flag];
          }
          item.Properties = properties;
          return item;
        });

        return phpJson({
          STATUS: STATUS_SUCCESS,
          MESSAGE: MESSAGE_SUCCESS,
          DATA,
        });
      } catch (e) {
        // Reported as SUCCESS, because the string is non-empty. Only the tail
        // differs between stacks -- each driver words its own errors.
        return phpJson({
          STATUS: STATUS_SUCCESS,
          MESSAGE: MESSAGE_SUCCESS,
          DATA: "Database error: " + (e instanceof Error ? e.message : String(e)),
        });
      }
    },
  ],

  // firefly_api.php lines 615-629.
  [
    "get_userviewprivileges",
    async (fd) =>
      emptySentinelJson("DATA NOT FOUND !!", async () => {
        const result = await query(GET_VIEW_PRIVILEGES_SQL, [
          post(fd, "UserId"),
          post(fd, "ViewName"),
        ]);
        return result.rows;
      }),
  ],

  // firefly_api.php lines 1511-1526.
  //
  // Three writes run unconditionally, in this order. The failure test then reads
  // `$ACTION == $FALSE || $ACTION1 == $FALSE` -- $ACTION2 is checked for
  // non-emptiness and never consulted again, so a failed insert_userprivileges
  // still reports Success. Reproduced deliberately.
  [
    "insert_user",
    async (fd) => {
      const ACTION = await insertUser(fd);
      const ACTION1 = await insertUserLedgerPrivileges(fd);
      await insertUserPrivileges(fd); // $ACTION2, never consulted
      return trueFalseJson(
        ACTION === FALSE || ACTION1 === FALSE ? "FALSE" : "TRUE",
        "User Insertion/Updation Failed!",
        "User Insertion/Updation Success!",
      );
    },
  ],

  // firefly_api.php lines 1544-1558.
  [
    "insert_userprivileges",
    async (fd) =>
      trueFalseJson(
        await insertUserPrivileges(fd),
        "User Privilege Insertion/Updation Failed!",
        "User Privilege Insertion/Updation Success!",
      ),
  ],

  // firefly_api.php lines 1528-1542.
  [
    "insert_userledgerprivilege1",
    async (fd) =>
      trueFalseJson(
        await insertUserLedgerPrivilege1(fd),
        "User Ledger Privilege Insertion/Updation Failed!",
        "User Ledger Privilege Insertion/Updation Success!",
      ),
  ],

  // firefly_api.php lines 631-664.
  //
  // Three things to preserve:
  //
  //   1. UserId is selected but dropped from each item; the other 16 columns are
  //      cast to bool, so the JSON holds true/false. PDO returns them as strings
  //      and node-postgres returns smallint as a number -- (bool)"0" and
  //      Boolean(0) are both false, so the two agree.
  //   2. With no rows, DATA is **null and STATUS is SUCCESS**. get_userprivileges
  //      returns the string 'EMPTY', foreach over a string only warns, and
  //      $data_array is never initialised anywhere in firefly_api.php. Not [].
  //   3. The messages are "Succes !" and "Failed !", misspelling and spacing
  //      included.
  [
    "get_userprivilegeslist",
    async (fd) => {
      try {
        const result = await query(GET_PRIVILEGES_SQL, [post(fd, "UserId")]);
        const DATA =
          result.rows.length > 0
            ? result.rows.map((row) => {
                // Built key by key so the JSON key order matches PHP's array
                // literal: ViewName first, then the flags in PRIVILEGE_FLAGS order.
                const item: Record<string, unknown> = { ViewName: row.ViewName };
                for (const flag of PRIVILEGE_FLAGS) {
                  item[flag] = Boolean(row[flag]);
                }
                return item;
              })
            : null;
        return phpJson({ STATUS: STATUS_SUCCESS, MESSAGE: "Succes !", DATA });
      } catch {
        return phpJson({ STATUS: STATUS_ERROR, MESSAGE: "Failed !", DATA: null });
      }
    },
  ],
];
