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
 * The global exception envelope, firefly_api.php lines 3282-3296.
 *
 * PHP's try wraps the entire switch, so any case whose helper does not catch
 * for itself lands here and gets a **fourth** key alongside the usual three:
 *
 *     catch (Exception $e) {
 *         $exception = new stdClass();
 *         $exception->errorCode = $e->getCode();
 *         ... errorLine, message, stackTrace, fileName ...
 *         echo json_encode(array("STATUS"=>..., "MESSAGE"=>..., "DATA"=>null, "ERROR"=>$exception));
 *     }
 *
 * The write endpoints ported so far never reach it -- each swallows its own
 * exception, because the PHP helper does -- but the 'EMPTY' sentinel getters
 * have no try/catch at all, so for them this is the DB-error path.
 *
 * Divergence, deliberate: errorCode carries the SQLSTATE on both stacks (PDO's
 * getCode(), node-postgres's err.code), but errorLine, fileName and stackTrace
 * are coordinates into firefly_api.php and frames of a PHP call stack. There is
 * nothing here to reproduce them from, and inventing TypeScript equivalents
 * would be misleading rather than compatible, so the keys are present with
 * empty values -- a client reading ERROR.message still gets the driver's text.
 *
 * PHP catches Exception, not Throwable, so a PHP TypeError would be a fatal
 * with no JSON at all. Not reproduced: there is no useful analogue.
 */
export function globalErrorJson(e: unknown): Response {
  return phpJson({
    STATUS: STATUS_ERROR,
    MESSAGE: MESSAGE_ERROR,
    DATA: null,
    ERROR: {
      errorCode: (e as { code?: unknown })?.code ?? "",
      errorLine: 0,
      message: e instanceof Error ? e.message : String(e),
      stackTrace: [],
      fileName: "",
    },
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

/**
 * PHP's die($message): the message becomes the entire body, and it is not JSON.
 *
 * Only one ported case can reach this. change_ledgerusernameandpassword
 * (firefly_api.php 5218-5236) catches its driver exception and calls
 * `die($e->getMessage())` with no return and no json_encode, so the case's own
 * `echo` at line 1637 never runs and the client receives raw driver text with a
 * Content-Type promising JSON.
 *
 * The headers are still the usual ones: firefly_api.php sends them at lines 4-6
 * and line 91, both before the switch, and middleware.php's shutdown function
 * reads its output buffer without cleaning it, so what die() wrote flushes
 * unchanged -- no trailing newline, nothing appended.
 *
 * die() is a script exit rather than an exception, so it does NOT fall through
 * to the global handler above; a helper that dies must return this Response
 * rather than throw. That works because both die() sites in firefly_api.php sit
 * in single-helper cases that echo immediately afterwards. A future case calling
 * two helpers where the first can die would need a thrown sentinel caught in
 * route.ts ahead of globalErrorJson.
 */
export function phpDie(message: string): Response {
  return new Response(message, {
    status: 200,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}
