import type { Cases } from "@/api/_types";
import { mysqlInt, post } from "@/lib/params";
import { trueFalseJson, type TrueFalse } from "@/lib/response";
import { binds, checkedSql, cols, paramOf, setList, upsertByKey } from "@/lib/sql";

/**
 * The 9 fields insert_billtype reads from $_POST, in the order the PHP INSERT
 * lists them. Unusually for this API the UPDATE names exactly the same nine in
 * the same order, so one array drives both statements.
 */
const FIELDS = [
  "OrganizationCode",
  "BillTypeId",
  "BillTypeName",
  "StartNumber",
  "Prefix",
  "Suffix",
  "TaxType",
  "VoucherType",
  "CreatedByUser",
] as const;

/** StartNumber is the table's only non-varchar column. */
const COERCE: Partial<Record<(typeof FIELDS)[number], (v: string | null) => unknown>> = {
  StartNumber: mysqlInt, // int(11)
};

function values(fd: FormData): unknown[] {
  return FIELDS.map((field) => {
    const raw = post(fd, field);
    const coerce = COERCE[field];
    return coerce ? coerce(raw) : raw;
  });
}

// The PHP UPDATE assigns BillTypeId to itself and then filters on it -- one
// named parameter used twice, which only works because PDO emulates prepares.
// node-postgres is positional, so the same $n is written in both places.
const UPDATE_SQL = checkedSql(
  "billtype UPDATE",
  `UPDATE billtype SET ${setList(FIELDS)}
WHERE "BillTypeId" = ${paramOf(FIELDS, "BillTypeId")}`,
  FIELDS.length,
);

const INSERT_SQL = checkedSql(
  "billtype INSERT",
  `INSERT INTO billtype (${cols(FIELDS)})
VALUES (${binds(FIELDS)})`,
  FIELDS.length,
);

/**
 * Port of insert_billtype($dbh), firefly_api.php line 5018.
 *
 * Note there is a *commented-out* earlier version directly above it in the PHP
 * (lines 4970-5014) that defaults TaxType to 'OP' when the field is absent. The
 * live function has no such default: it reads $_POST['TaxType'] unguarded, so a
 * missing field binds null and the write fails. billtype.TaxType carries
 * DEFAULT '' but a bound NULL does not fall back to a default on either engine.
 */
export async function insertBillType(fd: FormData): Promise<TrueFalse> {
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
  // firefly_api.php lines 1495-1510.
  [
    "insert_billtype",
    async (fd) =>
      trueFalseJson(
        await insertBillType(fd),
        "BillType Insertion/Updation Failed!",
        "BillType Insertion/Updation Success!",
      ),
  ],
];
