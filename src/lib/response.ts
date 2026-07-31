// Wire-format constants transcribed verbatim from firefly_api.php lines 18-33.
// These strings are part of the contract with the ERP client -- do not "fix"
// them (including the misspelled "Succesfully" used at the call sites).
export const EMPTY = "EMPTY";
export const FALSE = "FALSE";
export const TRUE = "TRUE";
export const NULL_JSON_OBJECT = "{}";
export const NULL_JSON_ARRAY = "[]";
export const STATUS_ERROR = "ERROR";
export const STATUS_SUCCESS = "SUCCESS";
export const STATUS_WARNING = "WARNING";
export const MESSAGE_ERROR = "Something Went Wrong!!!";
export const MESSAGE_SUCCESS = "COMPLETED";

// firefly_api.php lines 1-4.
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
} as const;

// Matches any character outside ASCII, i.e. everything PHP would escape to \uXXXX.
const NON_ASCII = /[^\x00-\x7F]/g;

/**
 * Mimics PHP's json_encode() default flags, which differ from JSON.stringify()
 * in two ways that show up on the wire:
 *   - forward slashes are escaped ("http:\/\/..."),
 *   - non-ASCII is escaped to \uXXXX rather than emitted as literal UTF-8.
 * Both matter for endpoints echoing URLs or RegionalName, so the whole
 * migration standardises on this encoder rather than JSON.stringify.
 *
 * Post-processing the stringified output is safe: JSON.stringify only emits a
 * backslash as part of an escape sequence, and "/" never appears inside one.
 * Non-BMP characters are already surrogate pairs in a JS string, and PHP emits
 * them as surrogate pairs too, so escaping per UTF-16 code unit matches.
 */
export function phpJsonEncode(value: unknown): string {
  return JSON.stringify(value)
    .replace(/\//g, "\\/")
    .replace(NON_ASCII, (c) =>
      "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0"),
    );
}

/**
 * Some PHP handlers echo their SQL into the response body before the JSON --
 * insert_productwtimage does it unconditionally at firefly_api.php line 5761 --
 * which makes the live response body invalid JSON. Verified in production logs.
 *
 * We emit clean JSON by default and gate the prefix behind FFAPI_ECHO_SQL, so
 * the ERP can be tested against a well-formed response and switched back
 * instantly if anything turns out to depend on the old shape.
 */
export function echoSqlPrefix(sql: string): string {
  return process.env.FFAPI_ECHO_SQL === "1" ? sql : "";
}

/**
 * The PHP endpoint never sets an HTTP status code, so every response -- success,
 * validation failure, DB error, unknown action -- is a 200. Clients branch on
 * the STATUS field in the body, so returning a real 4xx/5xx here would break them.
 *
 * `prefix` is the raw text a handler echoes ahead of the JSON; see echoSqlPrefix.
 */
export function phpJson(body: unknown, prefix = ""): Response {
  return new Response(prefix + phpJsonEncode(body), {
    status: 200,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

/** What the PHP insert_* helpers return: the string 'TRUE' or the string 'FALSE'. */
export type TrueFalse = typeof TRUE | typeof FALSE;

/**
 * The response shape most write endpoints share, verbatim from the PHP:
 *
 *     if (!empty($ACTION)) {
 *         if ($ACTION == $FALSE)      { $STATUS = $STATUS_ERROR;   $MESSAGE = ...; }
 *         else if ($ACTION == $TRUE)  { $STATUS = $STATUS_SUCCESS; $MESSAGE = ...;
 *                                       $DATA = $NULL_JSON_ARRAY; }
 *     }
 *
 * The `!empty($ACTION)` guard can never fail -- both branches of every such
 * helper return a non-empty string -- so it collapses away. DATA stays null on
 * the failure path because PHP never assigns it there, and is the *string* "[]"
 * on success.
 *
 * Cases that combine several helpers (insert_ledger, insert_user) compute the
 * combined verdict the way PHP does, with ||, and pass the result here.
 */
export function trueFalseJson(
  action: TrueFalse,
  failMessage: string,
  okMessage: string,
): Response {
  if (action === FALSE) {
    return phpJson({ STATUS: STATUS_ERROR, MESSAGE: failMessage, DATA: null });
  }
  return phpJson({
    STATUS: STATUS_SUCCESS,
    MESSAGE: okMessage,
    DATA: NULL_JSON_ARRAY,
  });
}

/**
 * firefly_api.php only acts on POST requests carrying an `api` field; anything
 * else falls off the end of the script with headers sent and no body written.
 */
export function phpEmpty(): Response {
  return new Response("", {
    status: 200,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}
