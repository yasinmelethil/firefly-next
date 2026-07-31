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
 * The PHP endpoint never sets an HTTP status code, so every response -- success,
 * validation failure, DB error, unknown action -- is a 200. Clients branch on
 * the STATUS field in the body, so returning a real 4xx/5xx here would break them.
 */
export function phpJson(body: unknown): Response {
  return new Response(phpJsonEncode(body), {
    status: 200,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
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
