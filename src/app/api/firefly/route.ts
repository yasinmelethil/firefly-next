import { HANDLERS } from "@/api/_registry";
import { STATUS_ERROR, phpEmpty, phpJson } from "@/lib/response";

// node-postgres cannot run on the Edge runtime.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Replacement for firefly_api.php: one endpoint, dispatching on the POST field
 * `api`. The PHP original is a single switch with 203 cases; each is ported as a
 * handler in src/api/<domain>.ts and registered in src/api/_registry.ts, so this
 * file does not grow as cases are added.
 */
export async function POST(req: Request): Promise<Response> {
  let fd: FormData;
  try {
    fd = await req.formData();
  } catch {
    // Unparseable body -- PHP would leave $_POST empty and write nothing.
    return phpEmpty();
  }

  // PHP: if (isset($_POST['api'])) { ... } with no else branch.
  const api = fd.get("api");
  if (typeof api !== "string") {
    return phpEmpty();
  }

  const handler = HANDLERS.get(api);
  if (!handler) {
    // firefly_api.php lines 3279-3280, the switch's default case.
    return phpJson({
      STATUS: STATUS_ERROR,
      MESSAGE: "API CASE NOT FOUND",
      DATA: null,
    });
  }

  return handler(fd);
}

// PHP guards everything behind REQUEST_METHOD == 'POST', so any other verb gets
// the CORS headers and an empty 200 body. That also serves as the preflight reply.
export async function GET(): Promise<Response> {
  return phpEmpty();
}

export async function OPTIONS(): Promise<Response> {
  return phpEmpty();
}
