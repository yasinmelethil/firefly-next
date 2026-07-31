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
