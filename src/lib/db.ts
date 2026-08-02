import { Pool, types, type PoolClient, type QueryResult, type QueryResultRow } from "pg";

/*
 * Type parsers, registered once at module load and before any query runs.
 *
 * node-postgres and PDO disagree on three column types, and the disagreement is
 * on the wire. PostgreSQL's own text output already IS the format MySQL emits,
 * so for the two date/time types the fix is to stop node-postgres parsing them
 * at all rather than to reformat afterwards.
 *
 * Measured against both stacks rather than assumed. PDO is the reference:
 * config.php builds its handle with no options, so ATTR_EMULATE_PREPARES is on,
 * which historically meant every value came back a string -- but PHP 8.1 changed
 * PDO_MySQL to return native int/float types even under emulation, and this box
 * is 8.2.12. Verified with a temp table:
 *
 *   int(11)       -> int(4)                     numeric on both, no parser needed
 *   tinyint(1)    -> int(1)                     numeric on both, no parser needed
 *   decimal(24,8) -> string "918.75000000"      string on both, no parser needed
 *   bigint(20)    -> int(219)                   node-postgres gives "219"
 *   datetime      -> "2026-07-28 19:18:21"      node-postgres gives a Date
 *   date          -> "2026-07-28"               node-postgres gives a Date
 *
 * The date case is the one that corrupts rather than merely reformats: an
 * unparsed Date is built at local midnight, so JSON.stringify shifts it back
 * across UTC and pdcdetails.ChequeDate reaches the ERP a day early
 * ("2026-07-27T18:30:00.000Z"). It was the schema's only `date` column, read by
 * get_pdcorcarddetails, get_pdcorcarddetailsforclearance, and -- through
 * get_pdcorcarddetailsbyrefId -- get_salemaster and get_salereturnmaster.
 *
 * That column is now varchar(10), so the date parser below matches nothing.
 * Porting insert_salebybilltypewithpdc showed why a date could not stay: the
 * ERP writes ChequeDate="" and non-strict MySQL stores '0000-00-00', which
 * PostgreSQL's date type cannot represent -- see db/tables/pdcdetails.sql. The
 * registration stays as the record of what a date would have done here, and
 * costs nothing while no column has the type.
 */
types.setTypeParser(1114, (v) => v); // timestamp(0) without time zone
types.setTypeParser(1082, (v) => v); // date -- no column has this type any more
types.setTypeParser(20, (v) => parseInt(v, 10)); // bigint -- counters.val only

// Next's dev server re-evaluates modules on hot reload; without caching on
// globalThis every reload would leak a fresh pool and exhaust max_connections.
const globalForPg = globalThis as unknown as { ffapiPool?: Pool };

export function getPool(): Pool {
  if (!globalForPg.ffapiPool) {
    const connectionString = process.env.DATABASE_URL;
    if (!connectionString) {
      throw new Error("DATABASE_URL is not set (expected in .env.local)");
    }
    globalForPg.ffapiPool = new Pool({ connectionString, max: 10 });
  }
  return globalForPg.ffapiPool;
}

export function query<T extends QueryResultRow = QueryResultRow>(
  text: string,
  values: unknown[] = [],
): Promise<QueryResult<T>> {
  return getPool().query<T>(text, values);
}

/**
 * Runs several statements on one connection inside a transaction.
 *
 * query() takes an arbitrary connection from the pool each call, which is fine
 * for a single statement but not for the read-then-write pairs the PHP uses
 * everywhere ("SELECT IF(EXISTS(...))" then UPDATE or INSERT). Those need to see
 * a consistent snapshot and to roll back together.
 *
 * The callback receives the client; on any throw the transaction is rolled back
 * and the error re-thrown, so callers keep their existing try/catch shape.
 */
export async function withTransaction<T>(
  fn: (client: PoolClient) => Promise<T>,
): Promise<T> {
  const client = await getPool().connect();
  try {
    await client.query("BEGIN");
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (e) {
    // A failed ROLLBACK would mask the original error, which is the one worth
    // reporting; the connection is released either way.
    await client.query("ROLLBACK").catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}
