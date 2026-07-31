# firefly-next

PostgreSQL + Next.js rebuild of the Firefly ERP backend, currently at
`c:\xampp\htdocs\ffapi\firefly_api.php` (11,680 lines of PHP, one `switch` with
203 API cases, MySQL via PDO).

This repo is a **single-endpoint pilot**: `insert_organization` reimplemented so
faithfully that the ERP needs no code change — only its stored API URL points
somewhere new. If the responses match byte for byte, the same recipe scales to
the remaining 202 cases.

## Setup

```powershell
# 1. Database (once, as the postgres superuser)
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -d postgres -f db\000_create_database.sql
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -d fireflydb_test -f db\001_baseline.sql

# 2. Credentials
cp .env.example .env.local     # edit if you changed the role password

# 3. Run
npm run dev                    # http://localhost:3000
```

## Pointing the ERP at it

The legacy URL is `http://<host>:8090/ffapi/firefly_api.php`. `next.config.ts`
rewrites that exact path to the internal `/api/firefly` route, so the ERP's
setting changes **host and port only**:

```
http://localhost:8090/ffapi/firefly_api.php   ->   http://localhost:3000/ffapi/firefly_api.php
```

The ERP stores this in `settings_common` (key `firefly_api_url`) / `settings_urls`.

## Verifying

```powershell
powershell -File scripts\compare-with-php.ps1   # response parity, needs both servers
powershell -File scripts\compare-schema.ps1     # schema parity, needs both databases
```

`compare-with-php.ps1` fires identical form-encoded requests at both servers and
diffs the raw response bodies. Requires XAMPP on :8090 and `npm run dev` on :3000.

`compare-schema.ps1` walks all 42 tables and 528 columns in both databases and
reports any difference in type, nullability or column order that the translation
rules below do not account for. Run it after touching anything in `db/tables/`.

## Layout

| Path | Role |
|---|---|
| `src/app/api/firefly/route.ts` | The dispatcher — `switch` on the `api` POST field. New endpoints get added here. |
| `src/api/organization.ts` | `insert_organization`, ported from PHP line 6176. |
| `src/lib/response.ts` | Wire-format constants + PHP-compatible JSON encoder. |
| `src/lib/params.ts` | `$_POST` read semantics. |
| `src/lib/db.ts` | `pg` pool. |
| `db/tables/*.sql` | One file per table — **edit these**. Plus `_functions.sql` for shared trigger functions. |
| `db/001_baseline.sql` | Generated. All 42 tables in dependency order. Never edit by hand. |
| `scripts/build-baseline.ps1` | Regenerates the baseline from `db/tables/`. Fails if a file is missing from its ordering list. |

## Schema

`db/001_baseline.sql` creates all 42 tables of MySQL `fireflydb`, empty. It is
generated — edit `db/tables/<name>.sql` and re-run:

```powershell
powershell -File scripts\build-baseline.ps1
```

The source of truth is the **live MySQL database**, not
`c:\xampp\htdocs\REST-APP\scripts\Migrations\00_baseline.sql`. That dump predates
23 incremental migrations: it is missing six tables outright and columns such as
`salemaster.IdempotencyKey`. Useful as a cross-check, wrong as a source.

Everything is `IF NOT EXISTS` / `CREATE OR REPLACE`, so re-running is a no-op.
Identity columns start at 1 because the tables are created empty; if rows are
ever loaded from MySQL, every sequence needs a `setval()` to `MAX(id)` afterwards.

## Porting the remaining endpoints — what the pilot established

**Compatibility quirks that must be preserved, not fixed.** The wire format is
the contract; "improving" any of it breaks the ERP.

- Every response is **HTTP 200**, including errors. Clients branch on the `STATUS`
  field in the body.
- `DATA` on success is the *string* `"[]"`, not an empty array (PHP assigns
  `$NULL_JSON_ARRAY = "[]"` then `json_encode`s it).
- Message strings are copied verbatim, misspellings included — `"Succesfully
  Inserted/Updated Organization with Code : "`.
- PHP's `substr($ACTION, 6)` leaves a leading space, so error messages render with
  **two** spaces after `Failed!`.
- `json_encode` escapes forward slashes (`Insertion\/Updation`) and emits non-ASCII
  as `\uXXXX`. `JSON.stringify` does neither, so use `phpJsonEncode` from
  `src/lib/response.ts` everywhere. This matters most for `RegionalName` and any
  endpoint echoing a URL.
- Missing POST fields become PHP `null`, and MySQL then **rejects** them
  (`Column 'Phone2' cannot be null`). Bind `null`, not `''` — `post()` in
  `src/lib/params.ts` does this, while `str()` gives the `''` that PHP uses when the
  same value is concatenated into a message string. Coercing to `''` at the SQL
  boundary would turn a shared error into a silent success that blanks columns.
  Consequence: the API has no partial update — every field must be sent on every call.
- Non-POST requests, and POSTs without an `api` field, return an **empty body** with
  headers set and no JSON at all.
- There is **no authentication** anywhere in the PHP API, and `Access-Control-Allow-Origin: *`.
  The port matches this so the ERP keeps working; hardening is a separate decision.

**Schema translation rules** (established by `db/tables/organization.sql`, applied
to all 42 tables):

- Columns are **quoted CamelCase** mirroring MySQL, so `SELECT *` yields rows whose
  keys are already the exact JSON keys the ERP expects — no mapping layer needed
  across ~203 endpoints. Every identifier needs double quotes.
- MySQL identifiers are case-insensitive; PostgreSQL quoted identifiers are **not**.
  Where the MySQL column and the PHP code disagree on case, adopt **the API payload's
  spelling** (e.g. `DefCustSIBillType`, not the table's `DefCustSIBilltype`).
- Add primary keys the MySQL schema lacks, then replace PHP's check-then-write
  upserts with `INSERT ... ON CONFLICT`. Atomic, and indistinguishable to the caller
  since the response says "Inserted/Updated" on both paths.

Type mapping:

| MySQL | PostgreSQL | Why |
|---|---|---|
| `char(n)` | `varchar(n)` | MySQL strips trailing `CHAR` spaces on retrieval, PostgreSQL pads them — different bytes on the wire |
| `tinyint(1)`, `tinyint(4)`, `bit(1)` | `smallint` | serialises as `0`/`1`, not `false`/`true`. Verified for the one `bit(1)` (`product.isVeg`): PDO returns a PHP integer and `json_encode` emits a bare `1` |
| `int(n)`, `bigint(n)` | `integer`, `bigint` | MySQL display widths carry no meaning |
| `decimal(p,s)` | `numeric(p,s)` | both pad to scale — `918.75000000` on either side |
| `datetime`, `timestamp` | **`timestamp(0)`** | every such column is `DATETIME_PRECISION = 0`. Bare `timestamp` is `timestamp(6)` and would emit `.123456` where MySQL emits nothing |
| `date` | `date` | one column, `pdcdetails.ChequeDate` |
| `text`, `longtext` | `text` | |
| `enum(...)` | `varchar(n)` + `CHECK` | `n` = longest label. A native `ENUM` serialises the same but needs a type declaration per column and an `ALTER TYPE` to add a label |
| `AUTO_INCREMENT` | `GENERATED BY DEFAULT AS IDENTITY` | `BY DEFAULT`, not `ALWAYS`, so an explicit id can be supplied without `OVERRIDING SYSTEM VALUE` |
| `DEFAULT current_timestamp()` | `DEFAULT LOCALTIMESTAMP(0)` | `now()` is `timestamptz`; MySQL's datetime is timezone-naive |
| `ON UPDATE current_timestamp()` | `BEFORE UPDATE` trigger | no column-level equivalent. Functions live in `db/tables/_functions.sql` |

Four rules that keep the wire format intact:

- **Never add a column MySQL does not have.** ~203 endpoints `SELECT *`, so an extra
  column is an extra JSON key the ERP never asked for. This is why the tables that
  needed a new primary key got a *natural* one — `userprivilege (UserId, ViewName)`,
  `printersettings (OrganizationCode, VoucherType, UserId)`, and `warehousestock`'s
  existing `UNIQUE uq_inv_wh` promoted in place — rather than a surrogate `id`.
- **Add no foreign keys beyond the two MySQL already declares** (both on `pos_modes`).
  The PHP API writes rows that would violate any "obvious" FK: `salemaster.OrderMasterId`
  is `varchar(480)` holding a *comma-joined list* of merged order ids, and widths
  disagree on purpose across joins (`varchar(31)` vs `(47)` vs `(50)`).
- **`user` is a PostgreSQL reserved word.** Unquoted it resolves to the `CURRENT_USER`
  function, so the table is `"user"` in DDL, in queries, and in `src/api/*.ts`.
- **Index names are prefixed with their table.** MySQL scopes them per table,
  PostgreSQL per schema, and `idx_inventory` alone would collide between
  `product_images` and `substock`. Index names never reach the wire.

## Known divergences

Both were confirmed by running `scripts/compare-with-php.ps1` against the live PHP
endpoint.

- **DB error text.** Each side leaks its own driver's wording. A missing field gives
  `SQLSTATE[23000] ... Column 'Phone2' cannot be null` on MySQL versus `null value in
  column "Phone2" ... violates not-null constraint` on PostgreSQL. Identical JSON
  shape, identical `STATUS`, identical `Insertion/Updation of Organization Failed! `
  prefix — only the tail differs. Harmless unless a client parses the message text.
- **Overlong values — a real behaviour change.** A 100-character `Name` against the
  `varchar(50)` column is **silently truncated to 50 by MySQL, which returns
  `SUCCESS`**; PostgreSQL rejects it and returns `ERROR`. Erroring is the better
  behaviour (silent truncation is data loss), but if the ERP ever sends oversized
  values it will now see failures where it previously saw success. If bug-for-bug
  compatibility is preferred, truncate per-column in the app layer before binding.

**Two node-postgres defaults that will bite the first read endpoint.** The schema
is correct; the driver is what needs configuring. Neither affects
`insert_organization`, which reads nothing back.

| Column type | PDO / PHP emits | node-postgres gives | Fix |
|---|---|---|---|
| `datetime` → `timestamp(0)` | `"2026-07-28 19:18:21"` | a JS `Date`, which `JSON.stringify`s to `"2026-07-28T19:18:21.000Z"` | `pg.types.setTypeParser(1114, (v) => v)` — PostgreSQL's own text output is already the exact MySQL format |
| `bigint(20)` → `bigint` | `219` (number) | `"219"` (string) | `pg.types.setTypeParser(20, (v) => parseInt(v, 10))` — only `counters.val` |

`decimal(24,8)` → `numeric` needs no fix: PDO and node-postgres both return
`"918.75000000"` as a string, scale padding included.

## Out of scope for the pilot

Authentication, the `uploadImage` flow that produces `ImagePath`, migrating existing
rows from MySQL, and the other 202 API cases. The schema for all 42 tables is in
place, so those cases are now application work only.
