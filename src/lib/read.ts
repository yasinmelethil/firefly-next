import { STATUS_ERROR, STATUS_SUCCESS, phpJson } from "@/lib/response";

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
