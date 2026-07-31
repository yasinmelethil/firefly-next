import type { Cases, Handler } from "@/api/_types";
import { cases as billtype } from "@/api/billtype";
import { cases as category } from "@/api/category";
import { cases as customer } from "@/api/customer";
import { cases as ledger } from "@/api/ledger";
import { cases as order } from "@/api/order";
import { cases as organization } from "@/api/organization";
import { cases as pdc } from "@/api/pdc";
import { cases as product } from "@/api/product";
import { cases as purchase } from "@/api/purchase";
import { cases as sale } from "@/api/sale";
import { cases as taxdetails } from "@/api/taxdetails";
import { cases as user } from "@/api/user";
import { cases as voucher } from "@/api/voucher";

/**
 * Every ported api name, in one place. Adding an endpoint means adding it to its
 * domain module's `cases` array -- and a new module here -- rather than editing
 * the route, which stays a fixed-size dispatcher no matter how many of the 203
 * PHP cases get ported.
 *
 * Modules are grouped the way firefly_api.php groups its helper functions, not
 * the way its switch orders the cases; the switch order carries no meaning.
 */
const MODULES: readonly Cases[] = [
  organization,
  product,
  billtype,
  category,
  taxdetails,
  ledger,
  user,
  // The ERP's sync loop: the documents it pulls, and the status writes that
  // acknowledge each one. customer belongs with them rather than with the master
  // data above -- get_newcustomers is a queue drained by update_customerledgerId,
  // not a ledger editor.
  customer,
  order,
  sale,
  purchase,
  voucher,
  pdc,
];

function build(): ReadonlyMap<string, Handler> {
  const map = new Map<string, Handler>();
  for (const domain of MODULES) {
    for (const [name, handler] of domain) {
      // Two modules claiming one api name would mean the later import silently
      // wins, which is exactly the kind of thing that survives to production.
      if (map.has(name)) {
        throw new Error(`Duplicate api case registered: ${name}`);
      }
      map.set(name, handler);
    }
  }
  return map;
}

/**
 * A Map rather than an object literal, deliberately: an object would resolve
 * `api=__proto__` or `api=constructor` to an inherited property and dispatch to
 * something that is not a handler. A Map has no such keys.
 */
export const HANDLERS = build();
