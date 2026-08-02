import { query } from "@/lib/db";
import { isPhpEmpty } from "@/lib/params";

/*
 * ---------------------------------------------------------------------------
 * getBaseUrlWithPort() and the five image path prefixes, firefly_api.php lines
 * 36-90.
 *
 * The API serves image *URLs*, not image bytes: two endpoints (get_organization
 * and get_product_with_category_withstock) concatenate a base URL onto the
 * stored ImagePath and put the result on the wire. The base comes from the
 * settings_common row the ERP also uses to find this API, so repointing the ERP
 * repoints the image URLs with it.
 *
 * Nothing here serves the files. They live under c:\xampp\htdocs\ffapi\*_Image\
 * and stay there; whether those URLs resolve after a repoint is a deployment
 * question (leave the setting on XAMPP, or front both with one proxy), not a
 * porting one. Same scope line the README already draws around uploadImage.
 * ---------------------------------------------------------------------------
 */

const FALLBACK_URL = "http://localhost:8090/ffapi/firefly_api.php";

const SETTING_SQL = `SELECT "value" FROM settings_common WHERE "key" = 'firefly_api_url' LIMIT 1`;

export interface ImagePaths {
  OrgImagePath: string;
  CatImagePath: string;
  CatThumpnailPath: string;
  ProdImagePath: string;
  ProdThumpnailPath: string;
}

/**
 * The stored endpoint URL, or the hardcoded fallback.
 *
 * PHP reads it as `trim((string) ($stmt->fetchColumn() ?: ''))` and keeps it
 * only `if ($val !== '')`. Two PHP-isms in that one line, both reproduced:
 * `?:` tests truthiness, so a stored value of "0" is discarded exactly as a
 * missing row is; and the trim runs after, so a whitespace-only value also
 * falls back. The whole read is wrapped in `catch (Throwable)` and falls back
 * silently -- a settings_common that does not exist yet must not take the two
 * endpoints down with it.
 */
async function endpointUrl(): Promise<string> {
  try {
    const result = await query(SETTING_SQL);
    const raw: unknown = result.rows[0]?.value;
    const value = (isPhpEmpty(raw) ? "" : String(raw)).trim();
    return value !== "" ? value : FALLBACK_URL;
  } catch {
    return FALLBACK_URL;
  }
}

/**
 * scheme://host[:port] from the endpoint URL, or '' when it does not parse.
 *
 * PHP requires parse_url to yield both a scheme and a host, and returns the
 * empty string otherwise -- note that is '' and *not* the fallback URL, so a
 * garbage setting makes every path below a site-relative "/ffapi/Org_Image/"
 * rather than reverting to localhost:8090. Verified against PHP 8.2 for
 * "not a url", "", "//host/x" and "localhost:8090/ffapi/x.php" -- all four give
 * '' -- and new URL() rejects or blanks the host on exactly the same four.
 *
 * The port is read off the raw authority rather than from URL.port, which
 * normalises a default port away: PHP's parse_url reports 80 for
 * "http://host:80/x" and so must this, or the two stacks disagree on any
 * setting that spells its default port out.
 */
function baseUrlOf(endpoint: string): string {
  let url: URL;
  try {
    url = new URL(endpoint);
  } catch {
    return "";
  }
  if (url.hostname === "") {
    return "";
  }

  const authority = endpoint
    .slice(endpoint.indexOf("://") + 3)
    .split(/[/?#]/, 1)[0];
  // Userinfo may contain ':' and an IPv6 literal is bracketed, so the port is
  // whatever follows the last ':' that comes after both.
  const hostStart = authority.lastIndexOf("@") + 1;
  const bracketEnd = authority.indexOf("]", hostStart);
  const colon = authority.indexOf(":", bracketEnd < 0 ? hostStart : bracketEnd);
  const port = colon < 0 ? "" : authority.slice(colon + 1);

  const base = `${url.protocol}//${url.hostname}`;
  return /^\d+$/.test(port) ? `${base}:${port}` : base;
}

/**
 * The five prefixes, firefly_api.php lines 86-90. Note Thumpnail is misspelled
 * in both the variable names and the JSON keys they end up under; keep it.
 *
 * Not cached across requests. PHP caches in a `static`, which lives for one
 * request and no longer, so a module-level cache here would be a behaviour
 * change: it would pin whatever firefly_api_url said at boot and ignore an ERP
 * repoint until the server restarted. Two endpoints, one indexed primary-key
 * lookup -- not worth the staleness.
 */
export async function imagePaths(): Promise<ImagePaths> {
  const base = baseUrlOf(await endpointUrl());
  return {
    OrgImagePath: `${base}/ffapi/Org_Image/`,
    CatImagePath: `${base}/ffapi/Cat_Image/`,
    CatThumpnailPath: `${base}/ffapi/Cat_Thumbnail/`,
    ProdImagePath: `${base}/ffapi/Product_Image/`,
    ProdThumpnailPath: `${base}/ffapi/Product_Thumbnail/`,
  };
}
