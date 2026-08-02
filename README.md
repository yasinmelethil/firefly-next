# firefly-next

PostgreSQL + Next.js rebuild of the Firefly ERP backend, currently at
`c:\xampp\htdocs\ffapi\firefly_api.php` (11,680 lines of PHP, one `switch` with
203 API cases, MySQL via PDO).

The rebuild is faithful enough that the ERP needs no code change — only its
stored API URL points somewhere new. **65 of the 203 cases are ported** and
verified byte-for-byte against the live PHP:

| Case | Module |
|---|---|
| `insert_organization`, `get_organization` | `src/api/organization.ts` |
| `insert_productwtimage`, `insert_productwithwarehousestock`, `get_product_with_category_withstock`, `get_stock` | `src/api/product.ts` |
| `insert_billtype` | `src/api/billtype.ts` |
| `insert_category`, `insert_categorywtimage` | `src/api/category.ts` |
| `insert_taxdetails` | `src/api/taxdetails.ts` |
| `insert_ledger`, `update_ledgerCurrentBalance`, `update_ledgersCurrentBalances`, `get_ledgers`, `get_ledgersbyname`, `get_bankdetails`, `customer_login`, `check_username`, `check_usernamewithledger`, `change_ledgerusernameandpassword` | `src/api/ledger.ts` |
| `insert_user`, `insert_userprivileges`, `insert_userledgerprivilege1`, `get_userprivilegeslist`, `get_userviewprivileges`, `login`, `get_userprivileges`, `get_userprivileges_with_properties` | `src/api/user.ts` |
| `get_newcustomers`, `update_customerledgerId` | `src/api/customer.ts` |
| `get_ordermaster`, `get_ordercancelmaster`, `update_orderStatus`, `update_ordercancelStatus`, `get_allnoncommitedordermaster` (+`_test`, `_test2`), `get_ordermasterbynumber` (+`_test`), `get_allorderDetailsByMasterId` (+`_test`), `insert_orderbybilltype`, `insert_ordercancelbybilltype` | `src/api/order.ts` |
| `get_salemaster`, `get_salereturnmaster`, `update_saleStatus`, `update_saleReturnStatus`, `get_allsales`, `get_allsaleswithoutpaidamount`, `get_salemasterbyNumber`, `get_allsaleDetailsByMasterId`, `insert_salebybilltypewithpdc` | `src/api/sale.ts` |
| `get_purchaseordermasterforFireFly`, `update_purchaseorderStatus` | `src/api/purchase.ts` |
| `get_receipt`, `get_payment`, `get_journal`, `update_receiptStatus`, `update_paymentStatus`, `update_journalStatus` | `src/api/voucher.ts` |
| `get_pdcorcarddetails`, `get_pdcorcarddetailsforclearance`, `update_pdcStatus`, `update_pdcClearanceStatus`, `update_pdcdetailsstatus` | `src/api/pdc.ts` |

They came in three batches, and the split is worth knowing when reading the code:
**the sync loop**, which the ERP polls to pull finished documents, **the POS
billing loop**, which the point-of-sale front end calls interactively, and **the
authentication cases**, which both front ends call first. Each has its own
section below.

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
powershell -File scripts\check-sql.ps1          # every statement PREPAREs, needs the database
```

`check-sql.ps1` lifts every SQL statement out of `src/` and `PREPARE`s it. That
catches the one failure `checkedSql` cannot see, because it is the server's
opinion rather than a property of the text — type resolution:

```
COALESCE(NULLIF($1,''), "RoundOffAmount")
  ERROR:  COALESCE types text and numeric cannot be matched
COALESCE(NULLIF("LedgerId",''), "led_id")
  ERROR:  COALESCE types character varying and integer cannot be matched
```

MySQL accepts both, both parse as valid SQL, and both would surface at runtime
as the endpoint quietly answering `FALSE`. Statements assembled at runtime by
`cols()`/`binds()`/`setList()` are reported as SKIPPED — those are the ones
`checkedSql` already guards.

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
| `src/lib/response.ts` | Wire-format constants, PHP-compatible JSON encoder, `trueFalseJson`, and `phpDie` for the one endpoint that answers with raw non-JSON text. |
| `src/lib/read.ts` | The four `get_*` envelopes — `dataArrayJson`, `emptySentinelJson`, `untouchedDefaultsJson`, `emptyArrayJson` — and `decodeItems`. |
| `src/lib/imagepaths.ts` | `getBaseUrlWithPort` and the five image URL prefixes it derives. |
| `src/lib/voucher.ts` | Document numbering shared by the three `insert_*bybilltype*` writes. |
| `src/lib/params.ts` | `$_POST` read semantics + the MySQL/PHP coercion rules. |
| `src/lib/sql.ts` | Statement builders (`cols`/`binds`/`setList`/`paramOf`), `checkedSql`, and `upsertByKey`. |
| `src/lib/db.ts` | `pg` pool, type parsers, and `withTransaction`. |
| `db/tables/*.sql` | One file per table — **edit these**. Plus `_functions.sql` for shared trigger functions. |
| `db/001_baseline.sql` | Generated. All 42 tables in dependency order. Never edit by hand. |
| `scripts/build-baseline.ps1` | Regenerates the baseline from `db/tables/`. Fails if a file is missing from its ordering list. |
| `scripts/check-sql.ps1` | `PREPARE`s every statement in `src/`, catching the type-resolution failures `checkedSql` cannot. |

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
- **Nothing is authenticated.** There is a `login` case, but it only *answers* a
  credential check — no case is protected by it, there is no session or token, and
  `Access-Control-Allow-Origin: *` is on every response. The port matches this so
  the ERP keeps working; see "Authentication" and "Hardening" below.

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
| `date` | **`varchar(10)`** | one column, `pdcdetails.ChequeDate`, and the schema's only untranslated type. The ERP posts `ChequeDate=""` on every sale and non-strict MySQL stores `'0000-00-00'` — measured: all 32 live rows hold it — which PostgreSQL's `date` cannot represent at any setting. All 24 PHP references are bare SELECT entries or `PARAM_STR` binds, so nothing depends on it being a date. `mysqlDate` in `src/lib/params.ts` reproduces the coercion MySQL used to do on the way in |
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
| `mysqlDate` | the one ex-`date` column | `""`, whitespace, unparseable text and out-of-range dates all → `"0000-00-00"`. Parses loosely then validates strictly, so `"2026-7-8"`, `"2026/07/28"`, `"20260728"` and `"26-7-8"` all normalise to a padded `YYYY-MM-DD`, while `"2026-02-31"` and `"2026-13-01"` do not. Every case measured against the live server. |

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

## The POS billing loop

The 21 cases added after the sync loop are the other half of the ERP: not
polling for finished documents, but the point-of-sale front end working
interactively — load the catalogue and stock, search a customer, list the KOTs
nobody has billed yet, open one, strike lines off it, turn it into a bill.

**There are four `get_*` envelopes, not one, and the case block does not tell
you which.** `dataArrayJson` covers the sync loop's reads, where the case
rebuilds every item key by key. These reads echo `$DATA` straight into
`json_encode`, so the SELECT's column list *is* the JSON key list, and what
they differ on is the empty result. The getter decides, not the case:

| Helper | Zero rows | Used by |
|---|---|---|
| `dataArrayJson` | `DATA: null`, STATUS **SUCCESS**, `"Succes !"` | the sync loop |
| `emptySentinelJson` | `DATA: "EMPTY"` — the *string* — STATUS ERROR, a per-case message | eleven POS reads |
| `untouchedDefaultsJson` | `DATA: []`, STATUS ERROR, `"Something Went Wrong!!!"` | the four detail readers |
| `emptyArrayJson` | `DATA: []`, STATUS ERROR, `"No Product found!!"` | `get_product_with_category_withstock` alone |

`get_stock` is the trap. Its case block is written in the `emptySentinelJson`
shape, but its getter returns `fetchAll()` with no sentinel, so `$DATA == $EMPTY`
is never evaluated and `'No Stock found!!'` at line 376 is unreachable. Check the
getter, not the case.

The sentinel readers have **no try/catch**, so a DB error escapes to PHP's global
handler (lines 3282-3296) and gets a fourth key, `ERROR`. `route.ts` reproduces
that envelope; see "Known divergences" for what it cannot reproduce.

**Four MySQL constructs have no PostgreSQL equivalent.** Each was measured on
both engines rather than reasoned about:

- **`FIND_IN_SET(needle, haystack)`** → `needle = ANY(string_to_array(haystack, ','))`.
  `salemaster.OrderMasterId` is a comma-joined list when several orders are
  merged onto one bill. Equivalent for a NULL haystack, an empty one
  (PostgreSQL's `string_to_array('', ',')` is a **zero-element** array, not
  `{''}`, and live rows really do hold `''`), embedded empties, and untrimmed
  spaces. One unreachable difference: `FIND_IN_SET` is case-insensitive under
  the table collation and `=` is not, but both sides are minted by the same
  `masterIdOf()`.
- **`HAVING Quantity > 0` with no GROUP BY** → a subquery wrap with the filter in
  an outer `WHERE`. MySQL evaluates that row-wise against the SELECT *alias*;
  PostgreSQL would collapse the query to one aggregate group and cannot see
  output aliases at all. `SELECT *` on the wrapper is load-bearing — it
  preserves the inner column order, which is the JSON key order.
- **`CONCAT('%', :x, '%')` in a LIKE** → `'%' || $1 || '%'`. PostgreSQL's
  `concat()` **ignores NULL**, so a missing search string would become `'%%'` and
  match every row where MySQL's `CONCAT` returns NULL and matches none.
- **`GET_LOCK(name, 10)`** → `pg_advisory_xact_lock(hashtext($1)::bigint)`, which
  releases on COMMIT *and* ROLLBACK. All four manual `RELEASE_LOCK` sites
  disappear, and with them the leak `GET_LOCK` has if the process dies between
  commit and release.

**`COALESCE(<numeric>, 0)` needs its zero literal typed.** The single largest
wire risk in this batch. MySQL's COALESCE adopts the DECIMAL result type;
PostgreSQL takes the integer literal's scale of 0. Only the NULL branch differs —
every matched row already agrees, because PostgreSQL's display-scale rules (`SUM`
takes the max, `*` adds them) coincide with MySQL's here. Measured:

| Expression | MySQL | PostgreSQL, bare `0` | Fix |
|---|---|---|---|
| `COALESCE(SUM(numeric(24,8)), 0)`, no rows | `0.00000000` | `0` | `0::numeric(24,8)` |
| `NetTotalAmount` — SUM of a scale-16 product | `0.0000000000000000` | `0` | `0::numeric(38,16)` |
| `COALESCE(tax.Rate, 0)`, missed LEFT JOIN | `0.000` | `0` | `0::numeric(10,3)` |

Type the literal, not the whole expression: wrapping the expression risks the
paths that are already correct.

**Quirks reproduced deliberately**, each verified byte-for-byte:

- **The three sale reads select `om.PartyDetails` twice.** PDO's `FETCH_OBJ`
  keeps the first occurrence's position and emits one key; node-postgres does
  the same. The duplicate is dropped in the port with no wire change.
- **`JOIN "user"` is INNER in five reads and LEFT in three**, and the split is
  not accidental. `get_ordermasterbynumber` and the sale reads drop a document
  whose creating user was deleted; the `get_allnoncommited*` family does not.
  The `_test` variants softened it on purpose. Do not harmonise them.
- **`get_product_with_category_withstock` has two different key sets.** The
  no-`WarehouseId` branch selects `p.UnitShortName` and the `WarehouseId` branch
  does not, so they are two SQL constants rather than one with a predicate
  appended. Its stock subquery also groups by `(InventoryDetailsId, Unit)` while
  the join keys on `InventoryDetailsId` alone, so a product stocked under two
  units appears twice. And `Isparent` is the *string* `"True"`/`"False"` — the
  one EXISTS probe in the batch whose result reaches the wire.
- **The three `insert_*bybilltype*` writes disagree on everything.** Same shape,
  three different rules, all preserved: the order insert takes
  `max(StartNumber, MAX(AUTOID)+1)` with a 0 floor, the cancel insert uses
  `StartNumber ?? 1` forced through `empty()` so 0 becomes 1, and the sale insert
  uses `is_null` so 0 stays 0. Only the order insert writes `Status='P'` and
  flips to `'N'` after its lines land. Only the cancel insert sets
  `lastInsertedId` on the update path — the order insert returns `id: ""` and
  `voucherNumber: ""` there. Only the cancel insert puts the driver's exception
  text in `MESSAGE`. And `"Succesfully"` is misspelled in the order case while
  `"Successfully"` is correct in the cancel case.
- **`insert_salebybilltypewithpdc` writes no stock.** Nothing touches
  `warehousestock` or `stockposting`; billing does not decrement inventory here.
- **A blank `PaymentMode` yields `PDCDetailsId` with a double hyphen** —
  `MMKP--0000000032`. Every live row looks like that, because the ERP sends one
  all-blank `PdcDetails` element on every sale whether or not a cheque is
  involved. That element is also why `ChequeDate` had to stop being a `date`.

## Authentication

Seven cases, and between them they are the whole of the ERP's access control:
`login` (staff, reads `"user"`) and `customer_login` (the customer portal, joins
`ledger` to `organization`), the two privilege reads a client fetches immediately
afterwards, the two uniqueness probes the user and ledger editors call, and the
one endpoint that changes a customer's credentials.

There is **no hashing, no session, no token, and no authorisation**. Both logins
compare a plaintext password in a `WHERE` clause, return every matching row, and
ship the password back in the response. All seven cases are reachable
unauthenticated, like the other 196. That is what the ERP calls today; see
"Hardening" below for what changing any of it would cost.

- **`login` selects two literals that are not columns** — `'र' AS CurrencySymbol`
  and `'p' AS SubCurrencySymbol`. The first is U+0930 DEVANAGARI LETTER RA, not a
  rupee sign and not the `$CurrencySymbol = 'Rs'` global sitting unused at PHP
  line 34. `phpJsonEncode` emits it as `र`, matching `json_encode`, which
  keeps the whole response body ASCII.
- **`customer_login` needed three transcription fixes**, none of which reaches the
  wire. It selects `l.UserName` and `l.mypassword` twice each (dropped, like
  `om.PartyDetails` in the sale reads); it reads `og.DefCustSOBilltype` /
  `DefCustSIBilltype` / `DefCustSRBilltype`, a casing matching neither the table
  nor the write path, which MySQL folds and PostgreSQL will not; and its `FROM
  user` needs quoting. All three columns are aliased, so the JSON keys are
  unchanged.
- **The two logins disagree on the password's payload key.** `login` posts
  `Password`, `customer_login` also posts `Password` but binds it to the
  `mypassword` column — while `change_ledgerusernameandpassword` posts
  `mypassword`. Three endpoints, two spellings, no pattern. Do not harmonise.
- **`customer_login` filters `IsActive = 1`**, so a deactivated customer gets the
  same "check Username or Password" message as a wrong password.
- **`get_userprivileges_with_properties` is a fifth response envelope**, and none
  of the four in `src/lib/read.ts` fits, so it is written inline:

  | Condition | Response |
  |---|---|
  | `UserId` absent (`isset`, so `""` passes) | `SUCCESS` / `COMPLETED` / `DATA` is the string `"UserId is required"` |
  | zero rows — the getter returns `null`, not `'EMPTY'` | `ERROR` / `"Something Went Wrong!!!"` / `DATA: null` |
  | `PDOException`, caught locally | **`SUCCESS`** / `COMPLETED` / `DATA` is `"Database error: …"` |

  A DB error reporting SUCCESS is not a typo: the string is non-empty and is not
  the `EMPTY` sentinel, so the case block's success branch takes it. Because the
  catch is local, this is also the one read in the batch that must **not** reach
  the global four-key `ERROR` envelope. Its `'No Product found!!'` message at PHP
  line 591 is copy-pasted from the product endpoint and unreachable.
- **Its N+1 is collapsed, unlike the sync loop's.** PHP re-queries `userprivilege`
  once per row to build `Properties`, but that inner query is a primary-key lookup
  of the row the outer query just returned. The sync loop's N+1 is kept because
  batching it would change row ordering; this one cannot return a different row.
  `Properties` is a dynamic property in PHP, so it serialises after `CanEditRate`.
- **`get_userprivileges` and `get_userprivileges_with_properties` handle a missing
  `UserId` differently** — the first has no guard and answers `ERROR` /
  `'DATA NOT FOUND !!'`, the second answers `SUCCESS` with a string in `DATA`.
  Deliberate.
- **`check_username` reads `ledger`, not `"user"`**, despite the name: it is a
  customer-portal username probe. Both probes return the *string* `"true"` or
  `"false"` and always report SUCCESS, so their `'No DATA found!!'` branch is
  dead. **`"false"` is a non-empty string and therefore truthy in JavaScript** —
  clients must compare `=== "true"`.
- **`change_ledgerusernameandpassword` can answer with no JSON at all.** Its catch
  is `die($e->getMessage())` rather than `return 'FALSE'`, so on a driver error
  the body is raw text under a `Content-Type: application/json` header and the
  case's `echo` never runs — making its "Failed!" message unreachable. `phpDie` in
  `src/lib/response.ts` reproduces this. A `LedgerId` matching nothing updates no
  rows and still reports success; PHP never checks the affected count.

MySQL's `IF(cond, a, b)` becomes `CASE WHEN cond THEN a ELSE b END`. Unlike the
four constructs under "The POS billing loop" this translation is exact, needs no
measurement, and `src/api/product.ts` already used it for `Isparent` — so it is a
transcription note, not a compatibility hazard.

## Known divergences

All were confirmed by running `scripts/compare-with-php.ps1` against the live PHP
endpoint.

- **Credential comparison is now case- and whitespace-sensitive — a real
  behaviour change, and the loudest one in the port.** `user.UserName`,
  `user.Password`, `ledger.UserName`, `ledger.mypassword` and `ledger.LedgerId`
  are all `utf8mb4_unicode_ci` in MySQL: case-insensitive and PAD SPACE. So
  `UserName='ADMIN'` against a stored `admin`, and `Password='secret   '` against
  a stored `secret`, both authenticate today. PostgreSQL's `=` is exact and
  rejects both.

  The same class hits `check_username` / `check_usernamewithledger`, which will
  answer `'false'` where MySQL answers `'true'` — letting the UI create a
  case-variant account that then only logs in with exact case.

  Documented rather than reproduced, matching the "stricter is better" calls
  already made for overlong values and missing fields on UPDATE. But the failure
  mode here is *nobody can log in*, so it needs saying out loud before cutover
  rather than being discovered afterwards. Case 165 in `compare-with-php.ps1`
  demonstrates it without asserting on it, and counts the live accounts whose
  usernames collide case-insensitively — currently **zero**, so the port
  introduces no ambiguity. That count does not measure the actual risk, which is
  a user *typing* the wrong case, and which no query against the server can see.

  If bug-for-bug compatibility is ever wanted:

  ```sql
  CREATE COLLATION ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
  ```

  which is case-insensitive and accent-sensitive, matching `utf8mb4_unicode_ci` on
  both properties. PAD SPACE has no ICU equivalent and would need `RTRIM()` on
  both sides of every comparison. It also costs some index and `LIKE` usage on
  those columns, which is why it is not the default here.
- **`change_ledgerusernameandpassword` can now return an unparseable body.** The
  missing-field-on-UPDATE divergence below gains a new shape here:
  `ledger.UserName` and `ledger.mypassword` are NOT NULL, so omitting either
  against a matching `LedgerId` makes MySQL coerce it to `''` and report SUCCESS,
  while PostgreSQL raises and this endpoint `die()`s with raw driver text instead
  of JSON. Each side leaks its own driver's wording, as everywhere else.

- **Row order, where the PHP query has no `ORDER BY`.** Four reads sort nothing —
  `get_allnoncommitedordermaster`, `get_allsales`, `get_ledgers`,
  `get_bankdetails` — so the sequence is whatever the engine returns, and the two
  engines return the same rows in different orders. Every value of every row
  matches; only the order does not. `compare-with-php.ps1` has a `Set` mode for
  exactly this, which asserts the row multiset and excuses the sequence. The
  detail queries have the same property, which is also why the N+1 shape is kept
  rather than batched. A client relying on this order was already relying on
  MySQL's plan.
- **The global `ERROR` object is shaped, not reproduced.** PHP's outer catch adds
  a fourth key carrying `errorCode`, `errorLine`, `message`, `stackTrace` and
  `fileName`. `errorCode` maps cleanly — both drivers put a SQLSTATE there — and
  `message` carries the driver's text, but the other three are coordinates into
  `firefly_api.php` and frames of a PHP call stack. They are emitted as `0`,
  `[]` and `""` rather than invented. A client reading `ERROR.message` is
  unaffected; one reading `ERROR.errorLine` was reading a PHP line number.
- **The sale insert's advisory lock blocks where MySQL gives up.** `GET_LOCK`
  times out after 10 seconds and proceeds unlocked, relying on the unique index
  as the backstop; `pg_advisory_xact_lock` waits. Under a real double-submit both
  end up correct — PostgreSQL merely serialises where MySQL might race. If the
  timeout is ever wanted, `SET LOCAL lock_timeout = '10s'` plus catching `55P03`
  reproduces it exactly.
- **A blank date into a datetime column — a real behaviour change.**
  `insert_ordercancelbybilltype` is the only one of the three writes that
  defaults its date parameter to `''` rather than leaving it null (PHP 7848).
  Non-strict MySQL coerces that to `'0000-00-00 00:00:00'` and reports SUCCESS;
  PostgreSQL rejects it and the port answers ERROR.

  Same shape as the `ChequeDate` problem, deliberately not solved the same way.
  There, all 32 live `pdcdetails` rows hold the zero date because the ERP sends
  a blank on every sale — the zero value *is* the normal case, so the column had
  to change type. Here, measured across every datetime column of the POS tables,
  **zero production rows hold it**: the ERP always sends `OrderCancelDate`, and
  only a malformed call reaches this path. Retyping every `timestamp(0)` column
  in all 42 tables to reproduce a value that exists nowhere would make the port
  worse. Case 142 in `compare-with-php.ps1` demonstrates it without asserting on
  it. The other two writes are unaffected: they leave their date parameters
  unguarded, so a missing field is null and both engines reject it identically.
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

## Hardening

The seven authentication cases are ported, not improved. Everything below is what
real authentication would need, and every item is a **wire-format change the ERP
cannot consume without its own client change** — which is why none of it is here.
Listed so the decision is explicit rather than implied by silence.

- **Passwords are stored and compared in the clear**, in `user.Password` and
  `ledger.mypassword`. Hashing them means a migration for existing rows, and the
  comparison has to move out of the `WHERE` clause into the application — which
  changes `login` from one query into a fetch-then-verify. It also breaks
  `get_ledgers`, `get_ledgersbyname` and both logins, all of which currently
  return the stored password to the caller.
- **Nothing identifies the caller between requests.** There is no session, cookie
  or token: `login` hands back a user row and every subsequent call is anonymous.
  Adding one means the ERP and the POS both have to store and send it.
- **No endpoint checks authorisation.** `userprivilege` exists and is read by
  three cases, but nothing enforces it — a client that skips `get_userprivileges`
  is not restricted by it. Enforcement would have to be added at the dispatcher,
  and it would need a caller identity to enforce against.
- **`Access-Control-Allow-Origin: *`** on every response, with no credentials
  mechanism to protect. Tightening it is cheap once there is an origin to name.
- **Removing the password from response bodies** is the smallest useful change
  and still a breaking one, since it drops a key from four endpoints' JSON.

If any of this is taken on, it should be a deliberate joint change with the ERP,
not a quiet improvement inside the port — the whole value of this rebuild is that
the ERP does not need to know it happened.

## Out of scope

The `uploadImage` flow that produces `ImagePath`, migrating existing rows from
MySQL, and the remaining 138 API cases. The schema for all 42 tables is in place,
so those cases are now application work only.

**Serving the image bytes.** `get_organization` and
`get_product_with_category_withstock` build absolute image URLs from
`settings_common.firefly_api_url`, and `src/lib/imagepaths.ts` reproduces that
derivation exactly — the same setting yields the same bytes on both stacks. It
does not serve the files. They live under `c:\xampp\htdocs\ffapi\*_Image\`, which
Next.js does not expose, so once the ERP repoints `firefly_api_url` at this
server those URLs stop resolving. Leaving the setting on XAMPP, or fronting both
with one reverse proxy, are both fine; it is a deployment decision, not a porting
one.

The POS also calls six endpoints adjacent to the billing loop that are **not**
ported: `delete_salebybilltypewithpdc` (PHP 9025),
`insert_salereturnbybilltypewithpdc` (9232),
`get_allorderDetailsWithCancelByMasterId` (8190),
`get_allorderCancelDetailsByMasterId` (8206), `get_allordercancelmaster` (8217)
and `get_ordercancelmasterbynumber` (8237). They are the obvious next batch.

`get_alljournal` is deliberately left alone: it has a live SQL syntax error at
line 10839 (`BETWEEN C:FromDate AND :TillDate` — a stray `C`), which
`error_reporting(0)` hides, so the endpoint is permanently broken in PHP and the
ERP cannot be relying on it.
