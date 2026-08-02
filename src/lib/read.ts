import {
  EMPTY,
  MESSAGE_ERROR,
  MESSAGE_SUCCESS,
  STATUS_ERROR,
  STATUS_SUCCESS,
  phpJson,
} from "@/lib/response";

/**
 * The response envelope every "$data_array" style get_* case shares.
 *
 * All eleven of them are transcribed from the same PHP block:
 *
 *     try {
 *         $masterdata = get_<thing>($dbh);
 *         $masters = json_decode(json_encode($masterdata, true));
 *         foreach ($masters as $item) { $data_array[] = array(...); }
 *         $STATUS = $STATUS_SUCCESS; $MESSAGE = "Succes !";
 *     } catch (Exception $e) {
 *         $STATUS = $STATUS_ERROR;   $MESSAGE = "Failed !";
 *     }
 *     echo json_encode(array("STATUS"=>..., "MESSAGE"=>..., "DATA"=>$data_array));
 *
 * DATA is **null rather than []** when nothing matched, and STATUS is still
 * SUCCESS. The master getters return the *string* 'EMPTY' on zero rows, foreach
 * over a string only raises a warning (error_reporting(0) at line 8 swallows it),
 * and $data_array is never initialised anywhere in firefly_api.php -- so the key
 * serialises as null. Same shape get_userprivilegeslist already relies on.
 *
 * Note this applies to the *masters* only. The detail fetchers
 * (get_orderDetailsByMasterId and friends) return fetchAll() directly with no
 * 'EMPTY' sentinel, so a master with no detail rows carries an empty array.
 *
 * The messages are "Succes !" and "Failed !", misspelling and spacing included.
 */
export async function dataArrayJson(
  build: () => Promise<unknown[]>,
): Promise<Response> {
  try {
    const rows = await build();
    return phpJson({
      STATUS: STATUS_SUCCESS,
      MESSAGE: "Succes !",
      DATA: rows.length > 0 ? rows : null,
    });
  } catch {
    return phpJson({ STATUS: STATUS_ERROR, MESSAGE: "Failed !", DATA: null });
  }
}

/*
 * ---------------------------------------------------------------------------
 * The other three get_* envelopes.
 *
 * dataArrayJson above is the "$data_array" shape: the case block rebuilds every
 * item key by key, so it controls what reaches the wire. The POS billing reads
 * do not do that. They echo $DATA -- whatever the getter returned -- straight
 * into json_encode, so the SELECT's column list *is* the JSON key list, in
 * SELECT order, and the three envelopes below differ only in what happens when
 * the getter found nothing.
 *
 * Which one a case uses is decided by the getter, not by the case block, and
 * the two disagree often enough that it is worth checking the getter every
 * time -- see get_stock under untouchedDefaultsJson.
 * ---------------------------------------------------------------------------
 */

/**
 * (A) The 'EMPTY' sentinel envelope. Roughly forty cases share it; eleven of the
 * POS billing reads do.
 *
 *     $DATA = get_x($dbh);          // fetchAll(FETCH_OBJ), or the string 'EMPTY'
 *     if (!empty($DATA)) {
 *         if ($DATA == $EMPTY) { $STATUS = $STATUS_ERROR;   $MESSAGE = 'No Sales found!!'; }
 *         else                 { $STATUS = $STATUS_SUCCESS; $MESSAGE = $MESSAGE_SUCCESS; }
 *     }
 *     echo json_encode(array("STATUS"=>..., "MESSAGE"=>..., "DATA"=>$DATA));
 *
 * On zero rows the getter's sentinel is echoed as-is, so DATA is the *string*
 * "EMPTY" -- not null, not [] -- and STATUS is ERROR. That is the difference
 * from dataArrayJson, which nulls it and stays SUCCESS.
 *
 * There is no try/catch in these getters, so a DB error is not caught here
 * either: it propagates to the route, which reproduces the global handler at
 * firefly_api.php lines 3282-3296. Swallowing it here would turn a four-key
 * error body into a three-key one.
 */
export async function emptySentinelJson(
  emptyMessage: string,
  build: () => Promise<unknown[]>,
): Promise<Response> {
  const rows = await build();
  if (rows.length === 0) {
    return phpJson({ STATUS: STATUS_ERROR, MESSAGE: emptyMessage, DATA: EMPTY });
  }
  return phpJson({
    STATUS: STATUS_SUCCESS,
    MESSAGE: MESSAGE_SUCCESS,
    DATA: rows,
  });
}

/**
 * (B) No sentinel, so on zero rows *no branch runs at all*.
 *
 * These getters end `return $results;` with none of the 'EMPTY' handling above.
 * An empty fetchAll() is `[]`, `!empty([])` is false, the whole if-block is
 * skipped, and the values $STATUS and $MESSAGE were initialised to at
 * firefly_api.php lines 32-33 survive to the echo:
 *
 *     {"STATUS":"ERROR","MESSAGE":"Something Went Wrong!!!","DATA":[]}
 *
 * So a detail read with no lines reports a generic error, and DATA is a real
 * empty array. Deliberately takes no message argument: every one of these case
 * blocks carries a 'No ... found!!' string that can never be reached.
 *
 * get_stock is the trap. Its case block (firefly_api.php lines 371-384) is
 * written in the (A) shape, but its getter (4325-4356) returns fetchAll()
 * directly, so `$DATA == $EMPTY` is never evaluated and 'No Stock found!!' at
 * line 376 is dead code. It belongs here, not in emptySentinelJson.
 */
export async function untouchedDefaultsJson(
  build: () => Promise<unknown[]>,
): Promise<Response> {
  const rows = await build();
  if (rows.length === 0) {
    return phpJson({ STATUS: STATUS_ERROR, MESSAGE: MESSAGE_ERROR, DATA: [] });
  }
  return phpJson({
    STATUS: STATUS_SUCCESS,
    MESSAGE: MESSAGE_SUCCESS,
    DATA: rows,
  });
}

/**
 * (C) get_product_with_category_withstock alone, firefly_api.php lines 344-369.
 *
 * The only case block in the file that normalises the sentinel away:
 *
 *     if ($DATA === 'EMPTY' || empty($DATA)) {
 *         $STATUS = $STATUS_ERROR; $MESSAGE = 'No Product found!!'; $DATA = [];
 *     } else { ... }
 *
 * Both conditions collapse to "no rows" here, since the port returns an array
 * either way. DATA is a real [], unlike (A)'s "EMPTY" string.
 */
export async function emptyArrayJson(
  emptyMessage: string,
  build: () => Promise<unknown[]>,
): Promise<Response> {
  const rows = await build();
  if (rows.length === 0) {
    return phpJson({ STATUS: STATUS_ERROR, MESSAGE: emptyMessage, DATA: [] });
  }
  return phpJson({
    STATUS: STATUS_SUCCESS,
    MESSAGE: MESSAGE_SUCCESS,
    DATA: rows,
  });
}

/**
 * PHP's json_decode(json_encode($x)) round trip on a payload field, as the
 * batch updaters use it.
 *
 * json_decode returns null for a missing or malformed value, foreach then warns
 * (suppressed), and the function still returns 'TRUE'. So a bad blob is not an
 * error, it is a no-op. Shared by update_pdcdetailsstatus and
 * update_ledgersCurrentBalances; insert_productwithwarehousestock and the user
 * privilege writers each carry their own typed copy of the same shape.
 */
export function decodeItems<T>(raw: string | null): T[] {
  if (!raw) return [];
  try {
    const decoded: unknown = JSON.parse(raw);
    return Array.isArray(decoded) ? (decoded as T[]) : [];
  } catch {
    return [];
  }
}
