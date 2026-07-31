import { insertOrganization } from "@/api/organization";
import { str } from "@/lib/params";
import {
  MESSAGE_ERROR,
  NULL_JSON_ARRAY,
  STATUS_ERROR,
  STATUS_SUCCESS,
  phpEmpty,
  phpJson,
} from "@/lib/response";

// node-postgres cannot run on the Edge runtime.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Replacement for firefly_api.php: one endpoint, dispatching on the POST field
 * `api`. The PHP original is a single switch with 203 cases; each is ported here
 * as its own case, transcribed from the corresponding PHP block so the response
 * bytes match exactly.
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

  switch (api) {
    // firefly_api.php lines 666-684.
    case "insert_organization": {
      let STATUS = STATUS_ERROR;
      let MESSAGE = MESSAGE_ERROR;
      let DATA: unknown = null;

      const ACTION = await insertOrganization(fd);

      if (ACTION) {
        if (ACTION.startsWith("ERROR:")) {
          STATUS = STATUS_ERROR;
          // substring(6) leaves the space after "ERROR:", so the rendered
          // message has two spaces after "Failed!" -- as the PHP does.
          MESSAGE =
            "Insertion/Updation of Organization Failed! " + ACTION.substring(6);
        } else if (ACTION === "TRUE") {
          STATUS = STATUS_SUCCESS;
          MESSAGE =
            "Succesfully Inserted/Updated Organization with Code : " +
            str(fd, "OrganizationCode");
          DATA = NULL_JSON_ARRAY;
        }
      } else {
        STATUS = STATUS_ERROR;
        MESSAGE = "Unknown error occurred.";
      }

      return phpJson({ STATUS, MESSAGE, DATA });
    }

    // firefly_api.php lines 3279-3280.
    default:
      return phpJson({
        STATUS: STATUS_ERROR,
        MESSAGE: "API CASE NOT FOUND",
        DATA: null,
      });
  }
}

// PHP guards everything behind REQUEST_METHOD == 'POST', so any other verb gets
// the CORS headers and an empty 200 body. That also serves as the preflight reply.
export async function GET(): Promise<Response> {
  return phpEmpty();
}

export async function OPTIONS(): Promise<Response> {
  return phpEmpty();
}
