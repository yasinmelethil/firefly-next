import type { Cases } from "@/api/_types";
import { mysqlNumeric, post } from "@/lib/params";
import { trueFalseJson, type TrueFalse } from "@/lib/response";
import { binds, checkedSql, cols, paramOf, setList, upsertByKey } from "@/lib/sql";

/**
 * The 5 fields insert_taxdetails reads from $_POST. As with billtype the UPDATE
 * and the INSERT name the same set in the same order.
 */
const FIELDS = ["TaxId", "TaxName", "Rate", "CalculatingMode", "TaxType"] as const;

/** Rate is decimal(10,3); the ERP sends it as a string like "5.000". */
const COERCE: Partial<Record<(typeof FIELDS)[number], (v: string | null) => unknown>> = {
  Rate: mysqlNumeric,
};

function values(fd: FormData): unknown[] {
  return FIELDS.map((field) => {
    const raw = post(fd, field);
    const coerce = COERCE[field];
    return coerce ? coerce(raw) : raw;
  });
}

// Same self-assigning key as billtype: SET TaxId=:TaxId ... WHERE TaxId=:TaxId.
const UPDATE_SQL = checkedSql(
  "taxdetails UPDATE",
  `UPDATE taxdetails SET ${setList(FIELDS)}
WHERE "TaxId" = ${paramOf(FIELDS, "TaxId")}`,
  FIELDS.length,
);

const INSERT_SQL = checkedSql(
  "taxdetails INSERT",
  `INSERT INTO taxdetails (${cols(FIELDS)})
VALUES (${binds(FIELDS)})`,
  FIELDS.length,
);

/**
 * Port of insert_taxdetails($dbh), firefly_api.php line 5499.
 *
 * TaxId is the business key here but carries no unique constraint -- MySQL
 * tolerates duplicates and db/tables/taxdetails.sql keeps it that way, so this
 * is an UPDATE-then-INSERT rather than ON CONFLICT. If duplicate TaxIds do
 * exist, the UPDATE rewrites all of them, exactly as the PHP does.
 */
export async function insertTaxDetails(fd: FormData): Promise<TrueFalse> {
  try {
    await upsertByKey({
      updateSql: UPDATE_SQL,
      updateParams: values(fd),
      insertSql: INSERT_SQL,
      insertParams: values(fd),
    });
    return "TRUE";
  } catch {
    return "FALSE";
  }
}

export const cases: Cases = [
  // firefly_api.php lines 1847-1861. Note the success message is worded
  // differently from every other endpoint, misspelling included.
  [
    "insert_taxdetails",
    async (fd) =>
      trueFalseJson(
        await insertTaxDetails(fd),
        "Tax Insertion/Updation Failed!",
        "Tax Insertion/Updation Completed Succesfully!",
      ),
  ],
];
