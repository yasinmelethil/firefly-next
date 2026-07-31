# firefly-next

PostgreSQL + Next.js rebuild of the Firefly ERP backend, currently at
`c:\xampp\htdocs\ffapi\firefly_api.php` (11,680 lines of PHP, one `switch` with
203 API cases, MySQL via PDO).

The rebuild is faithful enough that the ERP needs no code change — only its
stored API URL points somewhere new. **37 of the 203 cases are ported** and
verified byte-for-byte against the live PHP:

| Case | Module |
|---|---|
| `insert_organization` | `src/api/organization.ts` |
| `insert_productwtimage`, `insert_productwithwarehousestock` | `src/api/product.ts` |
| `insert_billtype` | `src/api/billtype.ts` |
| `insert_category`, `insert_categorywtimage` | `src/api/category.ts` |
| `insert_taxdetails` | `src/api/taxdetails.ts` |
| `insert_ledger`, `update_ledgerCurrentBalance`, `update_ledgersCurrentBalances` | `src/api/ledger.ts` |
| `insert_user`, `insert_userprivileges`, `insert_userledgerprivilege1`, `get_userprivilegeslist` | `src/api/user.ts` |
| `get_newcustomers`, `update_customerledgerId` | `src/api/customer.ts` |
| `get_ordermaster`, `get_ordercancelmaster`, `update_orderStatus`, `update_ordercancelStatus` | `src/api/order.ts` |
| `get_salemaster`, `get_salereturnmaster`, `update_saleStatus`, `update_saleReturnStatus` | `src/api/sale.ts` |
| `get_purchaseordermasterforFireFly`, `update_purchaseorderStatus` | `src/api/purchase.ts` |
| `get_receipt`, `get_payment`, `get_journal`, `update_receiptStatus`, `update_paymentStatus`, `update_journalStatus` | `src/api/voucher.ts` |
| `get_pdcorcarddetails`, `get_pdcorcarddetailsforclearance`, `update_pdcStatus`, `update_pdcClearanceStatus`, `update_pdcdetailsstatus` | `src/api/pdc.ts` |

## Setup

```powershell
# 1. Database (once, as the postgres superuser)
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -d postgres -f db\000_create_database.sql
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -d fireflydb_test -f db\001_baseline.sql
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -d fireflydb_test -f db\002_seed_settings.sql

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
reports any difference in type, nullability, column order or **spelling** that the
translation rules below do not account for. Column names are compared
case-sensitively — MySQL would not care, but PostgreSQL's quoted identifiers do,
and every deliberate rename so far has been case-only. Run it after touching
anything in `db/tables/`.

## Layout

| Path | Role |
|---|---|
| `src/app/api/firefly/route.ts` | The dispatcher — parse, look up, dispatch. Fixed size; endpoints are *not* added here. |
| `src/api/_registry.ts` | api name → handler `Map`, assembled from the domain modules. A new module gets imported here. |
| `src/api/_types.ts` | The `Handler` and `Cases` types. |
| `src/api/_status.ts` | `statusUpdater`/`statusCase` — builds the ten identical single-row status updaters. |
| `src/api/<domain>.ts` | One file per PHP domain, each exporting its ported helpers plus a `cases` array. |
| `src/lib/response.ts` | Wire-format constants, PHP-compatible JSON encoder, `trueFalseJson`. |
| `src/lib/read.ts` | `dataArrayJson` — the shared `get_*` envelope — and `decodeItems`. |
| `src/lib/params.ts` | `$_POST` read semantics + the MySQL/PHP coercion rules. |
| `src/lib/sql.ts` | Statement builders (`cols`/`binds`/`setList`/`paramOf`), `checkedSql`, and `upsertByKey`. |
| `src/lib/db.ts` | `pg` pool, type parsers, and `withTransaction`. |
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

Everything is `IF NOT EXISTS` / `CREATE OR REPLACE`, so re-running is a no-op —
which also means the baseline **cannot alter a table that already exists**. A
column rename has to be applied by hand to a live database, or the database
dropped and recreated:

```sql
ALTER TABLE "user" RENAME COLUMN "Routid" TO "RoutId";
```

Identity columns start at 1 because the tables are created empty; if rows are
ever loaded from MySQL, every sequence needs a `setval()` to `MAX(id)` afterwards.

`db/002_seed_settings.sql` is the one exception to "tables start empty".
`settings_common` is read by the code and changes what it does, so an empty table
is not a neutral default but a different configuration — see `stock_source` under
"Endpoint notes" below.

## Adding an endpoint

The PHP `case` block is the unit of transcription: it owns the whole response,
including the exact (often misspelled) `MESSAGE` strings, so a handler returns a
`Response` rather than data for someone else to shape.

1. Find the `case` and the `function` it calls in `firefly_api.php`. Port the
   function into `src/api/<domain>.ts`, keeping its `'TRUE'`/`'FALSE'` contract.
2. Declare one ordered `FIELDS` array per statement and derive the SQL from it
   with `cols` / `binds` / `setList` / `paramOf` — the array is also the bind
   order, which is where hand-transcription usually goes wrong.
3. Wrap each generated statement in `checkedSql` (see below).
4. Replace the `SELECT IF(EXISTS(...))`-then-branch probe with `upsertByKey`,
   unless the table has a unique constraint on the business key — only
   `organization` does, and it uses `INSERT ... ON CONFLICT` instead.
5. Add the case to the module's `cases` array. Most write endpoints collapse to
   one `trueFalseJson` call. Register a new module in `src/api/_registry.ts`.
6. Add INSERT / UPDATE / missing-field cases to `scripts/compare-with-php.ps1`,
   using ZZ-prefixed keys so the cleanup stays scoped.

**Every parameter must be referenced by its statement.** PostgreSQL infers a
parameter's type from where it appears, so a `$n` the statement never mentions
has no type to infer and the whole statement is rejected with *"could not
determine data type of parameter $n"*. This is easy to produce by accident:
derive an UPDATE's SET list from the INSERT's field array by dropping a few
columns, and the dropped ones leave holes in the numbering. `insert_ledger` does
exactly that — its UPDATE omits `UserName` and `mypassword` — so it builds a
separate `UPDATE_FIELDS` list with the key last, keeping the numbering
gap-free. Every handler swallows its exception (the PHP does), so uncaught this
surfaces only as the endpoint quietly answering `FALSE`. `checkedSql` turns it
into a startup error naming the statement.

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
- Missing POST fields become PHP `null`, and MySQL then **rejects them on INSERT**
  (`Column 'Phone2' cannot be null`). Bind `null`, not `''` — `post()` in
  `src/lib/params.ts` does this, while `str()` gives the `''` that PHP uses when the
  same value is concatenated into a message string. Coercing to `''` at the SQL
  boundary would turn a shared error into a silent success that blanks columns.
  Consequence: the API has no partial update — every field must be sent on every call.
  (On the *UPDATE* path MySQL behaves differently — see "Known divergences".)
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
  Three columns need this so far; `scripts/compare-schema.ps1` lists them in
  `$Renames`. The newest is `user.Routid` → **`RoutId`**, found while porting
  `insert_user`: MySQL declares `Routid`, but every PHP reference writes `RoutId`,
  including the login `SELECT` at PHP line 4614 that puts the name on the wire —
  so MySQL already emits `RoutId` and only the DDL disagreed. Left as `Routid`,
  `insert_user` fails outright with *column "RoutId" does not exist*.
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

**Value coercion — the thing `organization` did not need.** That table was all
`varchar`, so raw strings could be bound directly. Most tables are not, and the
ERP sends everything as a string regardless. MySQL runs non-strict here
(`sql_mode` has no `STRICT_TRANS_TABLES`) and quietly reshapes what does not fit;
PostgreSQL raises instead. `src/lib/params.ts` carries the rules, each measured
against the live server with temporary tables rather than assumed:

| Helper | For | Rule |
|---|---|---|
| `mysqlInt` | `int` columns | **Rounds, half away from zero** — not truncation. `"0.99"`→1, `"12.7"`→13, `"2.5"`→3, `"-1.5"`→-2, `""`/`"abc"`→0. JS `Math.round` breaks halves toward +∞, so the sign is factored out. |
| `mysqlBit` | `bit(1)` columns | `""`→0, **everything else→1**, including `"0"`. MySQL treats the string as binary and truncates anything wider than one bit. |
| `mysqlNumeric` | `decimal` columns | `""`/`"abc"`→`0`; anything parseable passes through as a string so PostgreSQL does the decimal conversion. |

A *missing* field is different from a badly-typed one and still binds `null`, so
NOT NULL rejects it on both engines. Coercion applies only to a value that is
actually present.

Two more helpers reproduce **PHP** semantics rather than MySQL's, for values that
did not come from `$_POST`:

| Helper | For | Rule |
|---|---|---|
| `phpStr` | values decoded out of a JSON payload field | PDO `PARAM_STR` casting: **`true`→`"1"`, `false`→`""`**, `null`→`null`. The privilege payloads send the permission flags as JSON *booleans*; a plain `String()` gives `"true"`/`"false"`, which `mysqlInt` scores as `0` — silently revoking every permission granted. |
| `isPhpEmpty` | `empty()` guards | `null`, `""`, **`"0"`**, `0`, `false`. The `"0"` case is real: `insert_rout` refuses to create a route whose `RoutId` is `"0"` while happily creating one whose `RoutId` is `"00"`. |

## Endpoint notes

**`insert_productwtimage`** — despite the name, "wtimage" means *without* image.
It is `insert_product` with every reference to `ImagePath` deleted, so that saving
a product leaves its existing image alone. Do not add image handling to it.
It writes `product` (including `CurrentStock`) and then `warehousestock`, both
unconditionally and in that order — the stock insert only fires for a product
that already exists, so the order is load-bearing.

- `settings_common.stock_source = 'APP'` makes the `warehousestock` write a
  no-op; anything else (including a missing row) lets it through. Live MySQL is
  set to `'APP'`, which is why `db/002_seed_settings.sql` exists.
- The `Inventoriesstock` payload is a JSON *string*, and its item keys do not
  match their columns: `Stock` → `CurrentStock`, `UnitShortName` → `Unit`.
- The ERP sends `isVeg="false"` on every call and MySQL stores `1` (see
  `mysqlBit`). Semantically backwards, faithfully reproduced.
- `product.ImagePath` carries `DEFAULT ''` purely because this endpoint omits the
  column from its INSERT and relies on MySQL's non-strict implicit default.

**`insert_categorywtimage`** — same "wtimage means *without* image" trick as the
product endpoint: `ImagePath` is never read, never bound, named in neither
statement, so a save leaves the existing image alone and a new row falls to
`DEFAULT 'no_image.jpg'`. `insert_category` is the variant that *does* write it,
substituting `no_image.jpg` whenever the posted value is `empty()`.

**`insert_ledger`** — three things to leave alone:

- `CentreCode` is not a payload field. PHP derives it as `explode('-', $LedgerId)[1]`
  — element **1**, the middle segment of `MMKP-MMKP-0000000042`. A `LedgerId` with
  no `-` leaves that index undefined, which becomes `null` and fails the NOT NULL
  column. That is the behaviour, not a bug to route around.
- The UPDATE omits `UserName` and `mypassword` entirely, so editing a ledger never
  overwrites its customer-portal credentials. `insert_user`'s UPDATE **does**
  overwrite `Password`. The asymmetry is real; do not harmonise the two.
- The case calls `insert_rout` unconditionally afterwards, whose INSERT is guarded
  by `!empty($RoutId) && !empty($RoutName)` while its UPDATE is not.

**`insert_user`** — the case runs three writes and then tests only two of them:
`$ACTION == $FALSE || $ACTION1 == $FALSE`. `$ACTION2`, the `insert_userprivileges`
result, is checked for non-emptiness and never consulted again, so a failed
privilege write still reports Success. Reproduced deliberately.

**`get_userprivilegeslist`** — the first read endpoint. It drops `UserId` from each
item even though the SELECT fetches it, and casts the other 16 columns to `bool`.
**With no rows, `DATA` is `null` and `STATUS` is still `SUCCESS`** — not `[]`:
`get_userprivileges` returns the *string* `'EMPTY'`, `foreach` over a string only
warns, and `$data_array` is never initialised anywhere in `firefly_api.php`. The
messages are `"Succes !"` and `"Failed !"`. Neither node-postgres type parser from
the table below is needed yet — `userprivilege` has no `timestamp` and no `bigint`.

## The sync loop

The 25 cases above `insert_user` in the table are one feature: the loop the ERP
polls to pull documents and mark them synced.

**There is no `issync` column.** Grepping `db/` and `firefly_api.php` for
`issync|IsSync|synced|is_sync` returns nothing. The one-character `Status` column
*is* the sync flag, and the lifecycle is `'P'` temp → `'N'` ready to pull →
`'K'` acknowledged, plus `'C'` cleared for cheques. Every `get_*` filters
`WHERE Status = :Status` and the ERP calls the matching `update_*Status` once per
row afterwards. There is likewise **no org/company/branch scoping anywhere** in
the PHP — the API is single-tenant, and `OrganizationCode` is just another
payload column.

Empty results are `DATA: null` with `STATUS: SUCCESS` — see `dataArrayJson` in
`src/lib/read.ts` for why. A master with no *detail* rows is different: it gets
`[]`, because the detail fetchers return `fetchAll()` with none of the `'EMPTY'`
sentinel behaviour the master fetchers have.

Quirks that are reproduced deliberately, each verified byte-for-byte:

- **`get_payment` ships the payment id under the key `ReceiptId`.** The case block
  reads `'ReceiptId' => $item->PaymentId`, almost certainly copy-pasted from
  `get_receipt`. There is no `PaymentId` key in the response at all.
- **`get_ordercancelmaster` emits `"NoofChair": null`.** `ordercancelmaster` has no
  such column and the SELECT never fetches one; PHP reads a missing property off a
  `stdClass`, which `error_reporting(0)` turns into a silent null. Hardcoded.
- **`get_salereturnmaster` crosses its two id keys.** `OrdermstrID` carries
  `SaleMasterId` (the original sale) and `SaleMasterID` carries
  `SaleReturnMasterId` (the return). Its lines also ship under `SaleDetails`, not
  `SaleReturnDetails`.
- **`update_customerledgerId`'s eight child updates match nothing, ever.** They
  compare a varchar ledger column against `$ID`, which is `led_id` — an integer
  surrogate key — rather than the previous `LedgerId`. Harmless in the real flow,
  since a customer new enough to appear in `get_newcustomers` has no documents yet.
  The `ID` parameter must therefore be bound as **text**: bind it as a number and
  PostgreSQL raises *operator does not exist: character varying = integer*, turning
  MySQL's silent no-op into a rolled-back transaction. This is the only function in
  the loop with a real `beginTransaction`.
- **`get_salemaster` is the only capped query in the API** (`LIMIT 100`). The ERP's
  loop depends on it: pull 100, acknowledge, come back.
- **`get_purchaseordermasterforFireFly`** returns `UpdatedQuantity` aliased to
  `Quantity` and filters `UpdatedQuantity > 0`, hiding lines zeroed during goods
  receipt. The non-FireFly variant returns both quantity columns unfiltered.
  Its table's primary key is `"ordermasterId"` — lowercase `o`, capital `I`, unlike
  every sibling. The PHP writes `OrderMasterId` and only works because MySQL folds
  case; the port uses the real spelling. That needs no `$Renames` entry: the SELECT
  aliases it and the UPDATE only names it in a `WHERE`, so it never reaches the wire.
- **`get_pdcorcarddetails` vs `…forclearance`** differ by exactly one predicate,
  `ReferenceId = ''`. The first lists standalone cheques only, because ones attached
  to a sale already ship inline under that document's `PdcDetails`.

The N+1 query shape is kept rather than batched — `get_salemaster` issues up to
201 round trips. Batching would change per-master detail ordering into
whole-batch ordering, and no details query has an `ORDER BY`, so the row order is
engine-determined either way. That is the largest available optimisation here and
is deliberately not taken.

`update_pdcdetailsstatus` and `update_ledgersCurrentBalances` are the two batch
writers, and **neither is transactional** — PHP has no transaction in either, so a
failure partway leaves the earlier rows written. `update_ledgersCurrentBalances`
has a transactional version sitting commented out directly above it in the PHP
(lines 5351-5382); it is not what runs, and the port transcribes what runs.

**`FFAPI_ECHO_SQL`** — the PHP handler has an unconditional `echo $sql;`
(line 5761), so its live response body is raw SQL text with the JSON glued on the
end, and is not valid JSON. The port emits clean JSON by default; set
`FFAPI_ECHO_SQL=1` to prepend the SQL byte-for-byte if something downstream turns
out to depend on it. `scripts/compare-with-php.ps1 -EchoSql` asserts full byte
equality in that mode.

## Known divergences

Both were confirmed by running `scripts/compare-with-php.ps1` against the live PHP
endpoint.

- **DB error text.** Each side leaks its own driver's wording. A missing field gives
  `SQLSTATE[23000] ... Column 'Phone2' cannot be null` on MySQL versus `null value in
  column "Phone2" ... violates not-null constraint` on PostgreSQL. Identical JSON
  shape, identical `STATUS`, identical `Insertion/Updation of Organization Failed! `
  prefix — only the tail differs. Harmless unless a client parses the message text.
- **Missing fields on the UPDATE path — a real behaviour change.** Non-strict MySQL
  rejects `NULL` into a `NOT NULL` column on **INSERT** (error 1048) but silently
  coerces it to `''` on **UPDATE** and reports success. Verified directly against
  the live server:

  ```sql
  INSERT INTO t (k,v) VALUES ('b', NULL);   -- ERROR 1048: Column 'v' cannot be null
  UPDATE t SET v = NULL WHERE k = 'a';      -- OK, and v becomes ''
  ```

  PostgreSQL rejects both. The pilot only ever exercised the INSERT path, which is
  why this was originally recorded as "MySQL rejects them" without qualification.
  Consequence: today a client can blank a column on an existing row just by omitting
  the field, and the port returns `ERROR` where PHP returned `SUCCESS`. Erroring is
  the better behaviour — the alternative is coercing `null`→`''` on the update path,
  which is data loss by design — but it is a behaviour change. Cases 54-55 in
  `compare-with-php.ps1` demonstrate it without asserting on it.

- **Overlong values — a real behaviour change.** A 100-character `Name` against the
  `varchar(50)` column is **silently truncated to 50 by MySQL, which returns
  `SUCCESS`**; PostgreSQL rejects it and returns `ERROR`. Erroring is the better
  behaviour (silent truncation is data loss), but if the ERP ever sends oversized
  values it will now see failures where it previously saw success. If bug-for-bug
  compatibility is preferred, truncate per-column in the app layer before binding.

**Three node-postgres defaults that bite a read endpoint.** The schema is
correct; the driver is what needed configuring. All three parsers are now
registered at the top of `src/lib/db.ts`, at module scope so they are in place
before any query runs. The sync-loop reads triggered all of them.

| Column type | PDO / PHP emits | node-postgres gives | Fix |
|---|---|---|---|
| `datetime` → `timestamp(0)` | `"2026-07-28 19:18:21"` | a JS `Date`, which `JSON.stringify`s to `"2026-07-28T19:18:21.000Z"` | `types.setTypeParser(1114, (v) => v)` — PostgreSQL's own text output is already the exact MySQL format |
| `date` → `date` | `"2026-07-28"` | `"2026-07-27T18:30:00.000Z"` — **the day before** | `types.setTypeParser(1082, (v) => v)` — only `pdcdetails.ChequeDate` |
| `bigint(20)` → `bigint` | `219` (number) | `"219"` (string) | `types.setTypeParser(20, (v) => parseInt(v, 10))` — only `counters.val` |

The `date` row is the one that corrupts rather than merely reformats. An unparsed
`date` becomes a JS `Date` at **local** midnight, so serialising it shifts back
across UTC and the cheque date arrives a day early. `pdcdetails.ChequeDate` is
the schema's only `date` column and four endpoints read it —
`get_pdcorcarddetails`, `get_pdcorcarddetailsforclearance`, and both sale reads
by way of the embedded `PdcDetails`.

**`int` needs no parser, which is not obvious.** `config.php` builds its PDO
handle with no options, so `ATTR_EMULATE_PREPARES` is on — which historically
meant every column came back a string. PHP 8.1 changed PDO_MySQL to return native
`int`/`float` types even under emulation, and this box is 8.2.12, so `int(11)`
and `tinyint` arrive as JSON numbers on both stacks. Measured with a temp table
rather than assumed; re-check if this ever runs on PHP 7, where every numeric
field would silently become a quoted string on the PHP side only.

`decimal(24,8)` → `numeric` needs no fix either: PDO and node-postgres both
return `"918.75000000"` as a string, scale padding included (mysqlnd never floats
`DECIMAL`, precisely to avoid losing digits).

**Error semantics are *not* a divergence, contrary to appearances.** `config.php`
builds its PDO handle without `PDO::ATTR_ERRMODE`, which on older PHP meant
`ERRMODE_SILENT` — a failed write would be ignored and the endpoint would answer
SUCCESS having stored nothing. This box runs **PHP 8.2.12, where the PDO default
changed to `ERRMODE_EXCEPTION`**, so failures really do throw and really do
surface. Verified: a product payload missing required fields returns
`STATUS=ERROR` on both stacks. Worth knowing before "fixing" a port to match
behaviour that no longer exists — but also worth re-checking if this ever runs on
PHP 7.

**No transaction spans the two writes** in `insert_productwtimage`. PHP has none,
and the port matches, so a product can be written while its `warehousestock` rows
fail. Each write is individually atomic; the pair is not.

## Out of scope

Authentication, the `uploadImage` flow that produces `ImagePath`, migrating existing
rows from MySQL, and the remaining 166 API cases. The schema for all 42 tables is in
place, so those cases are now application work only.

`get_alljournal` is deliberately left alone: it has a live SQL syntax error at
line 10839 (`BETWEEN C:FromDate AND :TillDate` — a stray `C`), which
`error_reporting(0)` hides, so the endpoint is permanently broken in PHP and the
ERP cannot be relying on it.
