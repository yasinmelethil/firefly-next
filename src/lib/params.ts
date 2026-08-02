/**
 * Reads a request field the way the PHP endpoint reads $_POST.
 *
 * firefly_api.php sets error_reporting(0) and indexes $_POST with no isset()
 * guard, so a missing field silently becomes PHP null. Returning null here --
 * rather than '' -- is what makes a partial payload behave identically: MySQL
 * rejects a NULL bound into a NOT NULL column ("Column 'Phone2' cannot be null",
 * SQLSTATE 23000/1048) even in non-strict mode, and PostgreSQL likewise raises a
 * not-null violation. Coercing to '' here would turn that shared error into a
 * silent success that blanks columns.
 *
 * Use this for values bound into SQL. For values interpolated into a message
 * string, use str() instead.
 */
export function post(fd: FormData, key: string): string | null {
  const value = fd.get(key);
  // A File (multipart upload) would land in $_FILES rather than $_POST in PHP,
  // so treat it as absent here too.
  return typeof value === "string" ? value : null;
}

/**
 * Same read, but in PHP's string context, where null concatenates as ''.
 * Used for building response messages, not for binding into SQL.
 */
export function str(fd: FormData, key: string): string {
  return post(fd, key) ?? "";
}

/**
 * PHP's string cast, as PDO::PARAM_STR applies it to a value that came out of
 * json_decode rather than out of $_POST.
 *
 * The privilege payloads (Privileges, ViewPrivileges) are JSON, so their values
 * arrive already typed -- and the ERP sends the permission flags as JSON
 * *booleans*. PHP binds those through PDO::PARAM_STR, where true becomes "1" and
 * false becomes the empty string; MySQL then stores 1 and 0 in the tinyint
 * column. A plain String() would produce "true"/"false" instead, and mysqlInt
 * turns both of those into 0 -- silently revoking every permission the payload
 * granted. That is the bug this helper exists to prevent.
 *
 * null stays null, so a key missing from the JSON object still hits NOT NULL
 * exactly as it does in PHP.
 */
export function phpStr(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "string") return value;
  if (typeof value === "boolean") return value ? "1" : "";
  // Numbers only: an object here would be (string)Array in PHP, which no payload
  // in this API produces, so String() is close enough and never reached.
  return String(value);
}

/**
 * PHP's empty(), for the guards the handlers branch on.
 *
 * The trap is "0": PHP counts the one-character string "0" as empty, so
 * insert_rout refuses to create a route whose RoutId is "0" while happily
 * creating one whose RoutId is "00". Reproduced rather than fixed.
 */
export function isPhpEmpty(value: unknown): boolean {
  if (value === null || value === undefined) return true;
  if (typeof value === "string") return value === "" || value === "0";
  if (typeof value === "boolean") return !value;
  if (typeof value === "number") return value === 0;
  if (Array.isArray(value)) return value.length === 0;
  return false;
}

/*
 * ---------------------------------------------------------------------------
 * MySQL coercion helpers.
 *
 * The ERP sends every value as a string, and this MySQL server runs non-strict
 * (sql_mode is NO_ZERO_IN_DATE,NO_ZERO_DATE,NO_ENGINE_SUBSTITUTION -- no
 * STRICT_TRANS_TABLES), so it quietly reshapes a string that does not fit the
 * column. PostgreSQL raises instead. Where organization was all varchar and
 * could bind raw strings, product is not, so these reproduce what MySQL does.
 *
 * The rules below were measured against the live server with temporary tables,
 * not inferred. Each doc comment records the observed values.
 *
 * All three keep post()'s null semantics: a genuinely absent field stays null so
 * it still hits the NOT NULL constraint, exactly as it does in MySQL. Only a
 * present string is coerced.
 * ---------------------------------------------------------------------------
 */

/**
 * String -> INT column, as MySQL does it.
 *
 * MySQL ROUNDS, half away from zero -- it does not truncate. Measured:
 *   '0.00' -> 0    '0.99' -> 1     '10.7' -> 11    '2.5'  -> 3
 *   ''     -> 0    'abc'  -> 0     '-3.9' -> -4    '-1.5' -> -2
 *
 * JavaScript's Math.round breaks halves toward +Infinity (Math.round(-1.5) is
 * -1), so the sign is factored out to round the magnitude instead.
 *
 * Used for product.CurrentStock and product.OrderLimit, which the ERP populates
 * with "0.00" on 254 of the 255 calls in the logs.
 */
export function mysqlInt(value: string | null): number | null {
  if (value === null) return null;
  const n = Number(value);
  if (!Number.isFinite(n)) return 0; // MySQL yields 0 for unparseable input
  return Math.sign(n) * Math.round(Math.abs(n));
}

/**
 * String -> BIT(1) column, as MySQL does it.
 *
 * MySQL treats the string as a binary value: anything longer than one bit is
 * truncated to the maximum, which is 1. Measured:
 *   ''      -> 0
 *   '0'     -> 1   (the byte 0x30, not the number zero)
 *   '1'     -> 1    'false' -> 1    'true' -> 1    'no' -> 1
 *
 * So only the empty string yields 0. This is why every one of the 87 live
 * products has isVeg = 1 despite the ERP sending isVeg="false" on all 255 calls.
 * Semantically backwards, faithfully reproduced -- "fixing" it would flip every
 * product relative to MySQL.
 */
export function mysqlBit(value: string | null): number | null {
  if (value === null) return null;
  return value === "" ? 0 : 1;
}

/**
 * String -> DATE column, as MySQL does it.
 *
 * pdcdetails.ChequeDate is MySQL's only date column, and this port declares it
 * varchar(10) because the value MySQL actually stores there --  '0000-00-00',
 * in all 32 live rows -- is not representable as a PostgreSQL date. See
 * db/tables/pdcdetails.sql. Holding text means the coercion MySQL used to do
 * on the way in has to happen here instead, or the column would keep the raw
 * '' the ERP sends and the two stacks would disagree on the wire.
 *
 * Measured against the live server, non-strict sql_mode:
 *   ''           -> '0000-00-00'     '2026-07-28' -> '2026-07-28'
 *   '  '         -> '0000-00-00'     '2026-7-8'   -> '2026-07-08'  (zero-padded)
 *   'abc'        -> '0000-00-00'     '2026/07/28' -> '2026-07-28'  (any separator)
 *   '2026-13-01' -> '0000-00-00'     '20260728'   -> '2026-07-28'  (compact form)
 *   '2026-02-31' -> '0000-00-00'     '26-7-8'     -> '2026-07-08'  (2-digit year)
 *   '2026-00-00' -> '0000-00-00'  (NO_ZERO_IN_DATE)      NULL -> NULL
 *
 * So MySQL parses loosely and then validates the calendar strictly, falling
 * back to the zero date rather than erroring. The ERP only ever sends '' or a
 * plain YYYY-MM-DD; the rest is transcribed so the fallback is a rule and not
 * an accident.
 */
export function mysqlDate(value: string | null): string | null {
  if (value === null) return null;
  const text = value.trim();

  // Any run of non-digits separates the parts; 8 bare digits is the compact form.
  const parts = /^\d{8}$/.test(text)
    ? [text.slice(0, 4), text.slice(4, 6), text.slice(6, 8)]
    : text.split(/\D+/);
  if (parts.length !== 3 || parts.some((p) => p === "" || !/^\d+$/.test(p))) {
    return ZERO_DATE;
  }

  let [year] = parts.map(Number);
  const [, month, day] = parts.map(Number);
  // MySQL's two-digit year window: 00-69 is 2000s, 70-99 is 1900s.
  if (parts[0].length <= 2) {
    year += year < 70 ? 2000 : 1900;
  }

  // NO_ZERO_IN_DATE rejects a zero part, and the calendar rejects the rest.
  if (year === 0 || month < 1 || month > 12 || day < 1 || day > 31) {
    return ZERO_DATE;
  }
  const probe = new Date(Date.UTC(year, month - 1, day));
  if (probe.getUTCMonth() !== month - 1 || probe.getUTCDate() !== day) {
    return ZERO_DATE; // e.g. 2026-02-31
  }

  const pad = (n: number, width: number) => String(n).padStart(width, "0");
  return `${pad(year, 4)}-${pad(month, 2)}-${pad(day, 2)}`;
}

const ZERO_DATE = "0000-00-00";

/**
 * String -> DECIMAL column, as MySQL does it.
 *
 * PostgreSQL numeric parses a numeric string happily but rejects '' and 'abc',
 * where MySQL substitutes 0. Measured: '' -> 0, 'abc' -> 0, '0.00' -> 0.00000000,
 * '-1.25' -> -1.25000000. Anything parseable is passed through as the original
 * string so PostgreSQL does the decimal conversion itself, avoiding a round trip
 * through binary floating point.
 */
export function mysqlNumeric(value: string | null): string | null {
  if (value === null) return null;
  return Number.isFinite(Number(value)) && value.trim() !== "" ? value : "0";
}
