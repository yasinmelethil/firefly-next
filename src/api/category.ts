import type { Cases } from "@/api/_types";
import { isPhpEmpty, post } from "@/lib/params";
import { trueFalseJson, type TrueFalse } from "@/lib/response";
import { binds, checkedSql, cols, paramOf, setList, upsertByKey } from "@/lib/sql";

/*
 * Inventory groups, written by two endpoints that differ only in whether they
 * touch ImagePath. category is all varchar, so nothing needs coercing.
 */

/**
 * insert_categorywtimage. As with insert_productwtimage, "wtimage" means
 * *without* image: ImagePath is never read from $_POST, never bound and named in
 * neither statement, so that saving a category leaves its existing image alone.
 * On insert the column falls to its default -- 'no_image.jpg', declared
 * explicitly in db/tables/category.sql because MySQL supplies it implicitly
 * under non-strict mode.
 */
const FIELDS = [
  "OrganizationCode",
  "InventoryGroupId",
  "GroupName",
  "ParentGroup",
  "Colour",
] as const;

/** insert_category is the same list plus the column the other one omits. */
const FIELDS_WITH_IMAGE = [...FIELDS, "ImagePath"] as const;

// InventoryGroupId is bound (it is the WHERE key) but not assigned, so the SET
// list is the field array minus that one column.
const UPDATE_SET = FIELDS.filter((f) => f !== "InventoryGroupId");
const UPDATE_SET_WITH_IMAGE = FIELDS_WITH_IMAGE.filter(
  (f) => f !== "InventoryGroupId",
);

// InventoryGroupId is dropped from the SET list but still bound -- it is the
// WHERE key -- so the numbering stays gap-free and checkedSql passes.
const UPDATE_SQL = checkedSql(
  "category UPDATE",
  `UPDATE category SET ${setList(FIELDS, UPDATE_SET)}
WHERE "InventoryGroupId" = ${paramOf(FIELDS, "InventoryGroupId")}`,
  FIELDS.length,
);

const INSERT_SQL = checkedSql(
  "category INSERT",
  `INSERT INTO category (${cols(FIELDS)})
VALUES (${binds(FIELDS)})`,
  FIELDS.length,
);

const UPDATE_SQL_WITH_IMAGE = checkedSql(
  "category UPDATE (with image)",
  `UPDATE category SET ${setList(FIELDS_WITH_IMAGE, UPDATE_SET_WITH_IMAGE)}
WHERE "InventoryGroupId" = ${paramOf(FIELDS_WITH_IMAGE, "InventoryGroupId")}`,
  FIELDS_WITH_IMAGE.length,
);

const INSERT_SQL_WITH_IMAGE = checkedSql(
  "category INSERT (with image)",
  `INSERT INTO category (${cols(FIELDS_WITH_IMAGE)})
VALUES (${binds(FIELDS_WITH_IMAGE)})`,
  FIELDS_WITH_IMAGE.length,
);

/**
 * Port of insert_categorywtimage($dbh), firefly_api.php line 5579.
 */
export async function insertCategoryWtImage(fd: FormData): Promise<TrueFalse> {
  const params = FIELDS.map((field) => post(fd, field));
  try {
    await upsertByKey({
      updateSql: UPDATE_SQL,
      updateParams: params,
      insertSql: INSERT_SQL,
      insertParams: params,
    });
    return "TRUE";
  } catch {
    return "FALSE";
  }
}

/**
 * Port of insert_category($dbh), firefly_api.php line 5535 -- the variant that
 * does write ImagePath.
 *
 * Both branches substitute 'no_image.jpg' when the posted value is empty(), so
 * a caller clearing the image gets the placeholder rather than ''. Note empty()
 * also catches the string "0", which is a legal-if-odd filename; reproduced.
 */
export async function insertCategory(fd: FormData): Promise<TrueFalse> {
  const imagePath = post(fd, "ImagePath");
  const params = [
    ...FIELDS.map((field) => post(fd, field)),
    isPhpEmpty(imagePath) ? "no_image.jpg" : imagePath,
  ];
  try {
    await upsertByKey({
      updateSql: UPDATE_SQL_WITH_IMAGE,
      updateParams: params,
      insertSql: INSERT_SQL_WITH_IMAGE,
      insertParams: params,
    });
    return "TRUE";
  } catch {
    return "FALSE";
  }
}

// Both cases carry byte-identical MESSAGE strings in the PHP.
const FAILED = "Category Insertion/Updation Failed!";
const SUCCESS = "Category Insertion/Updation Success!";

export const cases: Cases = [
  // firefly_api.php lines 1575-1589.
  [
    "insert_categorywtimage",
    async (fd) => trueFalseJson(await insertCategoryWtImage(fd), FAILED, SUCCESS),
  ],
  // firefly_api.php lines 1560-1574.
  [
    "insert_category",
    async (fd) => trueFalseJson(await insertCategory(fd), FAILED, SUCCESS),
  ],
];
