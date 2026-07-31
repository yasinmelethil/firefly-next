import { query } from "@/lib/db";
import { post } from "@/lib/params";

/**
 * The 25 fields insert_organization reads from $_POST, in the order the PHP
 * INSERT lists them. Column names in PostgreSQL are quoted CamelCase mirroring
 * MySQL, so this one array drives both the payload keys and the SQL identifiers.
 *
 * Note DefCustSIBillType / DefCustSRBillType carry a capital "T" here. The MySQL
 * table spells those columns "...Billtype" while the PHP code writes "...BillType";
 * MySQL's case-insensitive identifiers hide the mismatch, but PostgreSQL's quoted
 * identifiers are case-sensitive, so the API's spelling is the one we adopt.
 */
const FIELDS = [
  "OrganizationCode",
  "Type",
  "Name",
  "RegionalName",
  "Address",
  "CityId",
  "ZipCode",
  "CountryCode",
  "Phone1",
  "Phone2",
  "Fax",
  "EmailId",
  "Url",
  "Description",
  "ImagePath",
  "Longitude",
  "Latitude",
  "StartTime",
  "EndTime",
  "TINNumber",
  "DefCustSOBillType",
  "DefCustSIBillType",
  "DefCustSRBillType",
  "DefCustBank",
  "DefCustRate",
] as const;

/**
 * Replaces the PHP "SELECT IF(EXISTS(...))" probe followed by a branch into
 * either UPDATE or INSERT. ON CONFLICT collapses that into one atomic statement,
 * closing the check-then-write race the original has (it is unguarded by any
 * unique index -- the MySQL table has no primary key at all). The caller cannot
 * observe the difference: the PHP response says "Inserted/Updated" either way.
 */
const UPSERT_SQL = `INSERT INTO organization (${FIELDS.map((f) => `"${f}"`).join(", ")})
VALUES (${FIELDS.map((_, i) => `$${i + 1}`).join(", ")})
ON CONFLICT ("OrganizationCode") DO UPDATE SET
  ${FIELDS.slice(1)
    .map((f) => `"${f}" = EXCLUDED."${f}"`)
    .join(",\n  ")}`;

/**
 * Port of insert_organization($dbh) from firefly_api.php line 6176.
 *
 * Keeps the original's string return contract -- 'TRUE' or 'ERROR: <message>' --
 * so the route handler can stay a literal transcription of the PHP case block.
 * Like the original it performs no validation and no authentication.
 */
export async function insertOrganization(fd: FormData): Promise<string> {
  try {
    await query(
      UPSERT_SQL,
      FIELDS.map((field) => post(fd, field)),
    );
    return "TRUE";
  } catch (e) {
    return "ERROR: " + (e instanceof Error ? e.message : String(e));
  }
}
