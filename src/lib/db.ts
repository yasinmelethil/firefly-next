import { Pool, type QueryResult, type QueryResultRow } from "pg";

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
